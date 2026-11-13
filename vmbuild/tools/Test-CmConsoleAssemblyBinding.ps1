#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Initialize-CMConsoleAssemblyResolver'
        }, $true))
if ($definitions.Count -ne 1) { throw 'Expected one console assembly resolver initializer.' }
. ([scriptblock]::Create($definitions[0].Extent.Text))

$script:StatusMessages = [System.Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param($Status, [switch]$NoStatus, [switch]$Warning)
    $script:StatusMessages.Add("$Status")
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Initialize-CMConsoleAssemblyResolver -ModulePath 'Z:\absent\ConfigurationManager.psd1'
    if ($script:StatusMessages.Count -ne 0) { throw 'The Desktop-only resolver changed PowerShell 7 behavior.' }
    Write-Host 'PASS -- console assembly binding bootstrap is inactive on PowerShell 7.'
    return
}

$provider = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-CMSiteProvider'
        }, $true))
if ($provider.Count -ne 1 -or $provider[0].Extent.Text -notmatch
    '(?s)Initialize-CMConsoleAssemblyResolver -ModulePath \$modulePath.+?Import-Module \$modulePath') {
    throw 'The guest site-provider bootstrap does not initialize console dependency binding before import.'
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-console-binding-' + [guid]::NewGuid().ToString('N'))
$dependencyName = 'MemLabsBindingDependency' + [guid]::NewGuid().ToString('N')
$keyPath = Join-Path $workDir 'fixture.snk'
$compiler = $null
try {
    $null = New-Item -ItemType Directory -Path $workDir
    $oldDirectory = Join-Path $workDir 'old'
    $newDirectory = Join-Path $workDir 'new'
    $null = New-Item -ItemType Directory -Path $oldDirectory, $newDirectory

    $keyParameters = [Security.Cryptography.CspParameters]::new()
    $keyParameters.KeyNumber = 2
    $key = [Security.Cryptography.RSACryptoServiceProvider]::new(2048, $keyParameters)
    try {
        $key.PersistKeyInCsp = $false
        [IO.File]::WriteAllBytes($keyPath, $key.ExportCspBlob($true))
    }
    finally { $key.Dispose() }

    $compiler = [Microsoft.CSharp.CSharpCodeProvider]::new()
    function New-FixtureAssembly {
        param([string]$Source, [string]$OutputPath, [string[]]$References = @())
        $parameters = [CodeDom.Compiler.CompilerParameters]::new()
        $parameters.GenerateInMemory = $false
        $parameters.OutputAssembly = $OutputPath
        $parameters.CompilerOptions = '/keyfile:"{0}"' -f $keyPath
        $null = $parameters.ReferencedAssemblies.Add('System.dll')
        foreach ($reference in $References) { $null = $parameters.ReferencedAssemblies.Add($reference) }
        $result = $compiler.CompileAssemblyFromSource($parameters, $Source)
        if ($result.Errors.HasErrors) { throw "Fixture compilation failed: $($result.Errors -join '; ')" }
    }

    $dependencySource = @'
using System.Reflection;
[assembly: AssemblyVersion("__VERSION__")]
namespace MemLabsBindingFixture {
    public static class Dependency {
        public static string Read() { return "__VERSION__"; }
    }
}
'@
    $oldAssembly = Join-Path $oldDirectory "$dependencyName.dll"
    $newAssembly = Join-Path $newDirectory "$dependencyName.dll"
    New-FixtureAssembly -Source $dependencySource.Replace('__VERSION__', '8.0.0.6') -OutputPath $oldAssembly
    New-FixtureAssembly -Source $dependencySource.Replace('__VERSION__', '10.0.0.3') -OutputPath $newAssembly
    $consumerSource = @'
using System.Reflection;
using System.Runtime.CompilerServices;
using System;
using System.Threading;
[assembly: AssemblyVersion("1.0.0.0")]
namespace MemLabsBindingFixture {
    public static class Consumer {
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static string Read() { return ReadCore(); }
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static string ReadCore() { return Dependency.Read(); }
        public static string ReadOnThread() {
            string value = null;
            Exception failure = null;
            var thread = new Thread(delegate() {
                try { value = Read(); } catch (Exception error) { failure = error; }
            });
            thread.IsBackground = true;
            thread.Start();
            if (!thread.Join(10000)) throw new TimeoutException("Background binding did not complete.");
            if (failure != null) throw failure;
            return value;
        }
    }
}
'@
    $consumerAssembly = Join-Path $workDir 'Consumer.dll'
    New-FixtureAssembly -Source $consumerSource -OutputPath $consumerAssembly -References @($oldAssembly)
    $identity = [Reflection.AssemblyName]::GetAssemblyName($newAssembly)
    $publicKeyToken = [BitConverter]::ToString($identity.GetPublicKeyToken()).Replace('-', '').ToLowerInvariant()

    $runnerBody = @'
param([string]$ModulePath, [string]$ConsumerPath, [string]$Mode, [string]$DependencyName)
$ErrorActionPreference = 'Stop'
$script:Warnings = 0
$script:Messages = [Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param($Status, [switch]$NoStatus, [switch]$Warning)
    $script:Messages.Add("$Status")
    if ($Warning) { $script:Warnings++ }
}
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Reflection;
public static class MemLabsBindingTrace {
    public static readonly List<string> Entries = new List<string>();
    public static void Register() {
        AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs args) {
            Entries.Add(args.Name + "; requester=" +
                (args.RequestingAssembly == null ? "<null>" : args.RequestingAssembly.Location));
            return null;
        };
    }
}
"@
[MemLabsBindingTrace]::Register()
__INITIALIZER__

$expectedFailure = $Mode -in @('Baseline', 'External', 'NoCaller', 'OutOfRange', 'WrongToken', 'WrongCulture', 'WrongTarget', 'MissingTarget', 'MalformedPolicy')
$failed = $false
try {
    if ($Mode -ne 'Baseline') {
        Initialize-CMConsoleAssemblyResolver -ModulePath $ModulePath
        if ($Mode -eq 'Repeat') { Initialize-CMConsoleAssemblyResolver -ModulePath $ModulePath }
    }
    if ($Mode -eq 'NoCaller') {
        $target = [Reflection.AssemblyName]::GetAssemblyName((Join-Path (Split-Path $ModulePath) "$DependencyName.dll"))
        $target.Version = [version]'8.0.0.6'
        $null = [Reflection.Assembly]::Load($target.FullName)
    }
    $consumer = [Reflection.Assembly]::LoadFrom($ConsumerPath)
    $methodName = if ($Mode -eq 'Background') { 'ReadOnThread' } else { 'Read' }
    $method = $consumer.GetType('MemLabsBindingFixture.Consumer').GetMethod($methodName)
    $value = $method.Invoke($null, @())
    $expectedVersion = if ($Mode -eq 'Legacy') { '8.0.0.6' } else { '10.0.0.3' }
    if ($value -ne $expectedVersion) { throw "Unexpected resolved assembly version '$value'." }
    $loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $DependencyName })
    if ($loaded.Count -ne 1 -or "$($loaded[0].GetName().Version)" -ne $expectedVersion) {
        throw 'The CLR did not load exactly the expected dependency identity.'
    }
}
catch {
    $failed = $true
    if (-not $expectedFailure) {
        $script:Messages | ForEach-Object { Write-Host $_ }
        [MemLabsBindingTrace]::Entries | ForEach-Object { Write-Host $_ }
        throw
    }
    $cause = $_.Exception.GetBaseException()
    if ($Mode -eq 'MalformedPolicy') {
        if ($cause -isnot [FormatException] -and $cause -isnot [ArgumentException]) { throw }
    }
    else {
        $loadFailure = $_.Exception
        while ($loadFailure -and $loadFailure -isnot [IO.FileNotFoundException] -and
            $loadFailure -isnot [IO.FileLoadException]) {
            $loadFailure = $loadFailure.InnerException
        }
        if (-not $loadFailure) { throw }
    }
    if ($Mode -eq 'Baseline' -and $_.Exception.ToString() -notmatch 'Version=8\.0\.0\.6') {
        throw 'The baseline did not reproduce the requested older assembly version.'
    }
    if ($Mode -eq 'WrongTarget' -and $_.Exception.ToString() -notmatch 'target identity mismatch') {
        throw 'An invalid target identity was not reported explicitly.'
    }
    if ($Mode -eq 'NoCaller' -and @([AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object { $_.GetName().Name -eq $DependencyName }).Count -ne 0) {
        throw 'A caller-less request loaded a console dependency outside console execution.'
    }
}
if ($failed -ne $expectedFailure) { throw "$Mode did not preserve its expected binding outcome." }
if ($Mode -eq 'Legacy' -and $script:Warnings -ne 1) { throw 'Missing legacy policy was not reported.' }
Write-Host "PASS -- CLR binding case $Mode."
'@
    $runnerPath = Join-Path $workDir 'Run-BindingCase.ps1'
    [IO.File]::WriteAllText(
        $runnerPath, $runnerBody.Replace('__INITIALIZER__', $definitions[0].Extent.Text), [Text.Encoding]::ASCII)

    # Failed CLR binds are cached, so each case needs a fresh Windows PowerShell process.
    foreach ($case in @('Baseline', 'Redirect', 'Background', 'Repeat', 'External', 'NoCaller', 'OutOfRange', 'WrongToken', 'WrongCulture', 'WrongTarget', 'MissingTarget', 'MalformedPolicy', 'Legacy')) {
        $caseRoot = Join-Path $workDir $case
        $bin = Join-Path $caseRoot 'bin'
        $null = New-Item -ItemType Directory -Path $bin
        $consumerPath = Join-Path $bin 'Consumer.dll'
        if ($case -eq 'External') {
            $external = Join-Path $caseRoot 'external'
            $null = New-Item -ItemType Directory -Path $external
            $consumerPath = Join-Path $external 'Consumer.dll'
        }
        Copy-Item -LiteralPath $consumerAssembly -Destination $consumerPath
        if ($case -ne 'MissingTarget') {
            $dependency = if ($case -eq 'Legacy') { $oldAssembly } else { $newAssembly }
            Copy-Item -LiteralPath $dependency -Destination (Join-Path $bin "$dependencyName.dll")
        }
        if ($case -ne 'Legacy') {
            $range = if ($case -eq 'OutOfRange') { '0.0.0.0-7.9.9.9' } else { '0.0.0.0-10.0.0.3' }
            if ($case -eq 'MalformedPolicy') { $range = 'invalid-version' }
            $targetVersion = if ($case -eq 'WrongTarget') { '11.0.0.0' } else { '10.0.0.3' }
            $token = if ($case -eq 'WrongToken') { '0000000000000000' } else { $publicKeyToken }
            $culture = if ($case -eq 'WrongCulture') { 'fr-FR' } else { 'neutral' }
            $policy = @"
<configuration><runtime><assemblyBinding xmlns="urn:schemas-microsoft-com:asm.v1">
  <dependentAssembly>
    <assemblyIdentity name="$dependencyName" publicKeyToken="$token" culture="$culture" />
    <bindingRedirect oldVersion="$range" newVersion="$targetVersion" />
  </dependentAssembly>
</assemblyBinding></runtime></configuration>
"@
            [IO.File]::WriteAllText(
                (Join-Path $bin 'Microsoft.ConfigurationManagement.exe.config'), $policy, [Text.Encoding]::ASCII)
        }
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $runnerPath `
            -ModulePath (Join-Path $bin 'ConfigurationManager.psd1') -ConsumerPath $consumerPath `
            -Mode $case -DependencyName $dependencyName
        if ($LASTEXITCODE -ne 0) { throw "CLR binding case '$case' failed with exit code $LASTEXITCODE." }
    }
}
finally {
    if ($compiler) { $compiler.Dispose() }
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
}

Write-Host 'PASS -- console policy resolves the strong-named 8.0.0.6 request to 10.0.0.3 without redirecting unrelated requests.'
