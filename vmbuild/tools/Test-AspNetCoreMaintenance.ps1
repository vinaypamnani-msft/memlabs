<#
.SYNOPSIS
    Verifies shared ASP.NET Core servicing without changing installed host packages.
.DESCRIPTION
    Loads production functions through the AST, uses isolated runtime directories,
    and mocks Microsoft metadata, downloads, signatures, and installer processes.
#>
[CmdletBinding()]
param (
    [string] $RootPath,
    [string] $SourceFile = 'Invoke-Maintenance.ps1'
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" -ForegroundColor Red }
}

function Assert-Throws {
    param ([scriptblock] $Action, [string] $What)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-Equal $true $threw $What
}

$sourcePath = Join-Path $RootPath $SourceFile
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw "$SourceFile has parse errors: $parseErrors" }
$wantedFunctions = @(
    'Get-InstalledAspNetCoreRuntime', 'Invoke-AspNetCoreInstaller', 'Invoke-AspNetCoreMaintenanceCore',
    'Invoke-AspNetCoreMaintenance', 'ConvertTo-QuietUninstallCommand', 'Split-UninstallCommand', 'Test-ChocoSuccessCode'
)
foreach ($name in $wantedFunctions) {
    $node = $ast.FindAll({
            param ($candidate)
            $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $node) { throw "Missing production function '$name'." }
    . ([scriptblock]::Create($node.Extent.Text))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabs ASP.NET maintenance test {0}' -f [guid]::NewGuid().ToString('N'))
$environmentNames = @('ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'TEMP')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$script:NativeRoot = Join-Path $fixtureRoot 'Program Files\dotnet'
$script:X86Root = Join-Path $fixtureRoot 'Program Files (x86)\dotnet'
$script:logsPath = Join-Path $fixtureRoot 'logs'

function Get-FixtureRuntimePath {
    param ([string] $Version, [string] $Architecture = 'x64')
    $root = if ($Architecture -eq 'x86') { $script:X86Root } elseif ($Architecture -eq 'arm64') { $script:NativeRoot } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { Join-Path $script:NativeRoot 'x64' } else { $script:NativeRoot }
    Join-Path $root "shared\Microsoft.AspNetCore.App\$Version"
}

function Add-FixtureRuntime {
    param ([string] $Version = '10.0.8', [string] $Architecture = 'x64', [switch] $Incomplete)
    $path = Get-FixtureRuntimePath -Version $Version -Architecture $Architecture
    $null = New-Item -Path $path -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $path '.version') -Value $Version -Encoding ascii
    if (-not $Incomplete) {
        foreach ($file in @('Microsoft.AspNetCore.App.deps.json', 'Microsoft.AspNetCore.dll')) {
            Set-Content -LiteralPath (Join-Path $path $file) -Value 'fixture' -Encoding ascii
        }
    }
}

function New-FixtureRelease {
    param ([string] $Version)
    [pscustomobject]@{
        releases = @([pscustomobject]@{
                'aspnetcore-runtime' = [pscustomobject]@{
                    version = $Version
                    files = @('x64', 'x86', 'arm64' | ForEach-Object {
                            [pscustomobject]@{
                                name = "aspnetcore-runtime-win-$_.exe"
                                rid = "win-$_"
                                url = "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/$Version/aspnetcore-runtime-$Version-win-$_.exe"
                                hash = 'A' * 128
                            }
                        })
                }
            })
    }
}

function Reset-Fixture {
    foreach ($path in @($script:NativeRoot, $script:X86Root)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = ''
    $script:Index = [pscustomobject]@{
        'releases-index' = @(
            [pscustomobject]@{ 'channel-version' = '10.0'; 'latest-runtime' = '10.0.13'; 'support-phase' = 'active' },
            [pscustomobject]@{ 'channel-version' = '8.0'; 'latest-runtime' = '8.0.32'; 'support-phase' = 'maintenance' },
            [pscustomobject]@{ 'channel-version' = '7.0'; 'latest-runtime' = '7.0.20'; 'support-phase' = 'eol' }
        )
    }
    $script:Releases = @{ '10.0' = New-FixtureRelease '10.0.13'; '8.0' = New-FixtureRelease '8.0.32' }
    $script:MetadataCalls = @()
    $script:Downloads = @()
    $script:Processes = @()
    $script:Entries = @()
    $script:Logs = @()
    $script:Hash = 'A' * 128
    $script:HashAlgorithm = $null
    $script:SignatureStatus = 'Valid'
    $script:Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    $script:InstallerExitCode = 0
    $script:InstallerCompletes = $true
    $script:InstallerWritesRuntime = $true
    $script:InstallerRemovesOld = $true
    $script:UninstallerRemovesOld = $true
    $script:UninstallerRemovesReplacement = $false
    $script:StoppedProcess = $null
    $script:MetadataFails = $false
    $script:LeaseAllowed = $true
    $script:Lease = $null
}

function Write-LogMessage {
    param ([string] $Message, [string] $Level = 'INFO')
    $script:Logs += [pscustomobject]@{ Message = $Message; Level = $Level }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param ([string] $Uri, [int] $TimeoutSec)
    $script:MetadataCalls += $Uri
    if ($script:MetadataFails) { throw 'simulated metadata outage' }
    if ($Uri -like '*/releases-index.json') { return $script:Index }
    if ($Uri -match '/(?<Channel>\d+\.\d+)/releases\.json$') { return $script:Releases[$Matches.Channel] }
    throw "Unexpected metadata URL '$Uri'."
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param ([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
    $script:Downloads += [pscustomobject]@{ Uri = $Uri; Path = $OutFile }
    Set-Content -LiteralPath $OutFile -Value 'fixture installer' -Encoding ascii
}

function Get-FileHash {
    [CmdletBinding()]
    param ([string] $LiteralPath, [string] $Algorithm)
    $script:HashAlgorithm = $Algorithm
    [pscustomobject]@{ Hash = $script:Hash }
}

function Get-AuthenticodeSignature {
    [CmdletBinding()]
    param ([string] $LiteralPath)
    [pscustomobject]@{ Status = $script:SignatureStatus; SignerCertificate = [pscustomobject]@{ Subject = $script:Signer } }
}

function Get-InstalledEntry {
    param ([string] $NameLike)
    $script:Entries
}

function Stop-ProcessTree {
    param ([int] $ProcessId)
    $script:StoppedProcess = $ProcessId
}

function Start-Process {
    [CmdletBinding()]
    param ([string] $FilePath, [string] $ArgumentList, [switch] $PassThru, [string] $WindowStyle)
    $script:Processes += [pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList }
    if ($FilePath -notmatch 'aspnetcore-(?:runtime-)?(?<Version>\d+\.\d+\.\d+)-(?:win-)?(?<Architecture>x64|x86|arm64)') {
        throw "Unexpected installer path '$FilePath'."
    }
    $version = $Matches.Version
    $architecture = $Matches.Architecture
    $path = Get-FixtureRuntimePath -Version $version -Architecture $architecture
    if ($script:InstallerCompletes -and $script:InstallerExitCode -in @(0, 1641, 3010)) {
        if ($ArgumentList -match '/uninstall') {
            if ($script:UninstallerRemovesOld) { Remove-Item -LiteralPath $path -Recurse -Force }
            if ($script:UninstallerRemovesReplacement) {
                Remove-Item -LiteralPath (Get-FixtureRuntimePath -Version '10.0.13' -Architecture $architecture) -Recurse -Force
            }
        }
        elseif ($script:InstallerWritesRuntime) {
            Add-FixtureRuntime -Version $version -Architecture $architecture
            if ($script:InstallerRemovesOld) {
                foreach ($runtime in @(Get-InstalledAspNetCoreRuntime | Where-Object {
                            $_.Architecture -eq $architecture -and $_.Channel -eq ([version]$version).ToString(2) -and $_.Version -lt [version]$version
                        })) {
                    Remove-Item -LiteralPath $runtime.Path -Recurse -Force
                }
            }
        }
    }
    $process = [pscustomobject]@{ Id = 987654; ExitCode = $script:InstallerExitCode }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param ($Milliseconds) return $script:InstallerCompletes }
    return $process
}

function Invoke-WithMemLabsRuntimeUpgradeLease {
    param ([scriptblock] $ScriptBlock, [object[]] $ArgumentList, [int] $TimeoutSeconds, [string] $Name)
    $script:Lease = [pscustomobject]@{ Name = $Name; Timeout = $TimeoutSeconds }
    if (-not $script:LeaseAllowed) { return $false }
    & $ScriptBlock @ArgumentList
    return $true
}

function Set-FixtureStandaloneEntry {
    param ([string] $Architecture = 'x64', [string] $Version = '10.0.8')
    $script:Entries = @([pscustomobject]@{
            DisplayName = "Microsoft ASP.NET Core $Version - Shared Framework ($Architecture)"
            SystemComponent = 0
            WindowsInstaller = 0
            QuietUninstallString = "`"C:\Package Cache\aspnetcore-runtime-$Version-win-$Architecture.exe`" /uninstall"
        })
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
try {
    $null = New-Item -Path $fixtureRoot -ItemType Directory -Force
    $env:ProgramFiles = Split-Path -Parent $script:NativeRoot
    $env:ProgramW6432 = $env:ProgramFiles
    ${env:ProgramFiles(x86)} = Split-Path -Parent $script:X86Root
    $env:TEMP = $fixtureRoot

    Reset-Fixture
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:MetadataCalls.Count 'hosts without ASP.NET Core do not contact a feed or acquire a new runtime'
    Assert-Equal 0 $script:Processes.Count 'hosts without ASP.NET Core run no installers'
    Assert-Equal 'Global\MemLabsTestMutationLock' $script:Lease.Name 'servicing uses the existing host mutation lease'
    Assert-Equal 0 $script:Lease.Timeout 'servicing does not wait on an active test cycle'

    Reset-Fixture
    Add-FixtureRuntime
    Invoke-AspNetCoreMaintenance
    Assert-Equal 1 $script:Downloads.Count 'reported ASP.NET Core 10.0.8 gets an explicit patch installer'
    Assert-Equal 'SHA512' $script:HashAlgorithm 'installer hash verification uses SHA-512'
    Assert-Equal $true ($script:Downloads[0].Uri -like '*/10.0.13/*win-x64.exe') 'patch and architecture come from Microsoft metadata'
    Assert-Equal $true ($script:Processes[0].Arguments -match '/install /quiet /norestart /log "') 'installer is quiet, never restarts, and retains its log'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'the exact reported vulnerable runtime directory is gone'
    Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.13')) 'replacement stays in the same major/minor branch'
    Assert-Equal $false (Test-Path -LiteralPath $script:Downloads[0].Path) 'temporary installer is removed'
    $firstDownloadCount = $script:Downloads.Count
    Invoke-AspNetCoreMaintenance
    Assert-Equal $firstDownloadCount $script:Downloads.Count 'a second current run does not reinstall the runtime'

    Reset-Fixture
    Add-FixtureRuntime '10.0.8' 'x86'
    Add-FixtureRuntime '8.0.20' 'x64'
    $desktopPath = Join-Path $script:NativeRoot 'shared\Microsoft.WindowsDesktop.App\9.0.1'
    $null = New-Item -Path $desktopPath -ItemType Directory -Force
    Invoke-AspNetCoreMaintenance
    Assert-Equal 2 $script:Downloads.Count 'each installed ASP.NET branch and architecture is patched'
    Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.13' 'x86')) 'x86 runtime is patched even without a dotnet CLI on PATH'
    Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '8.0.32')) 'a supported older major branch is preserved and patched'
    Assert-Equal $true (Test-Path -LiteralPath $desktopPath) 'mRemoteNG Windows Desktop runtime is untouched'

    Reset-Fixture
    Add-FixtureRuntime '10.0.99'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:Downloads.Count 'an installed patch ahead of the feed is never downgraded'

    Reset-Fixture
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Add-FixtureRuntime '10.0.8' 'arm64'
    Add-FixtureRuntime '10.0.8' 'x64'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 2 $script:Downloads.Count 'ARM64 native and emulated x64 roots are serviced separately'

    Reset-Fixture
    Add-FixtureRuntime
    $script:LeaseAllowed = $false
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:MetadataCalls.Count 'an active test cycle defers servicing before network or mutation'
    Assert-Equal 0 $script:Processes.Count 'an active test cycle cannot replace a live runtime'
    Assert-Equal $true ($script:Logs[-1].Message -like '*deferred, not verified*') 'deferral does not claim remediation'

    foreach ($failure in @('metadata', 'hash', 'unsigned', 'publisher', 'exit', 'timeout', 'no-files', 'old-files', 'bad-url', 'bad-metadata')) {
        Reset-Fixture
        Add-FixtureRuntime
        switch ($failure) {
            'metadata' { $script:MetadataFails = $true }
            'hash' { $script:Hash = 'B' * 128 }
            'unsigned' { $script:SignatureStatus = 'NotSigned' }
            'publisher' { $script:Signer = 'CN=Other Publisher, O=Other Publisher, C=US' }
            'exit' { $script:InstallerExitCode = 1603 }
            'timeout' { $script:InstallerCompletes = $false }
            'no-files' { $script:InstallerWritesRuntime = $false }
            'old-files' { $script:InstallerRemovesOld = $false }
            'bad-url' { $script:Releases['10.0'].releases[0].'aspnetcore-runtime'.files[0].url = 'https://example.invalid/installer.exe' }
            'bad-metadata' { $script:Index.'releases-index'[0].'latest-runtime' = '11.0.0' }
        }
        Assert-Throws { Invoke-AspNetCoreMaintenance } "$failure cannot be reported as successful remediation"
        if ($failure -in @('metadata', 'hash', 'unsigned', 'publisher', 'bad-url', 'bad-metadata')) {
            Assert-Equal 0 $script:Processes.Count "$failure cannot launch an installer"
        }
        if ($failure -eq 'timeout') { Assert-Equal 987654 $script:StoppedProcess 'a timed-out installer is stopped by its specific process ID' }
        Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) "$failure preserves the old runtime rather than blindly deleting it"
    }

    Reset-Fixture
    Add-FixtureRuntime
    $script:InstallerExitCode = 3010
    Invoke-AspNetCoreMaintenance
    Assert-Equal $true (@($script:Logs | Where-Object Message -like '*requires a host restart*').Count -gt 0) 'reboot-required success is logged without rebooting'

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    Set-FixtureStandaloneEntry
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:Downloads.Count 'cleanup can remove a stale bundle when the latest patch is already installed'
    Assert-Equal 1 $script:Processes.Count 'only the superseded standalone bundle is uninstalled'
    Assert-Equal $true ($script:Processes[0].FilePath -like 'C:\Package Cache\*.exe') 'quoted uninstall paths are launched directly without a command shell'
    Assert-Equal $true ($script:Processes[0].Arguments -match '/uninstall.*?/quiet.*?/norestart') 'registered uninstall is quiet and cannot request a restart'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'stale files are verified absent after bundle removal'

    foreach ($protected in @('hidden-msi', 'msi', 'other-architecture', 'latest-version', 'missing-replacement', 'ineffective-uninstall', 'removed-replacement')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13' -Incomplete:($protected -eq 'missing-replacement')
        Set-FixtureStandaloneEntry
        switch ($protected) {
            'hidden-msi' { $script:Entries[0].SystemComponent = 1 }
            'msi' { $script:Entries[0].WindowsInstaller = 1 }
            'other-architecture' { Set-FixtureStandaloneEntry 'x86' }
            'latest-version' { Set-FixtureStandaloneEntry -Version '10.0.13' }
            'ineffective-uninstall' { $script:UninstallerRemovesOld = $false }
            'removed-replacement' { $script:UninstallerRemovesReplacement = $true }
        }
        Assert-Throws { Invoke-AspNetCoreMaintenance } "$protected does not produce false remediation"
        if ($protected -notin @('ineffective-uninstall', 'removed-replacement')) {
            Assert-Equal 0 $script:Processes.Count "$protected cannot uninstall an unverified or protected component"
        }
    }

    Reset-Fixture
    Add-FixtureRuntime '7.0.20'
    Assert-Throws { Invoke-AspNetCoreMaintenance } 'an unsupported branch requires an explicit ownership/migration decision'
    Assert-Equal 0 $script:Processes.Count 'unsupported branches are not deleted or silently upgraded to a different major'

    Reset-Fixture
    Add-FixtureRuntime '11.0.0-preview.1'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:MetadataCalls.Count 'prerelease directories are not parsed as stable versions'
    Assert-Equal $true (@($script:Logs | Where-Object Level -eq 'WARNING').Count -gt 0) 'preserving a prerelease runtime is reported'

    $calls = @($ast.FindAll({
                param ($candidate)
                $candidate -is [System.Management.Automation.Language.CommandAst] -and $candidate.GetCommandName() -eq 'Invoke-AspNetCoreMaintenance'
            }, $true))
    Assert-Equal 1 $calls.Count 'the shared interactive/scheduled maintenance pipeline invokes the new phase'
    Assert-Equal $true ($calls[0].Extent.StartLineNumber -gt ($ast.FindAll({
                    param ($candidate)
                    $candidate -is [System.Management.Automation.Language.CommandAst] -and $candidate.GetCommandName() -eq 'Invoke-WeeklyUpgrades'
                }, $true) | Select-Object -Last 1).Extent.StartLineNumber) 'explicit servicing follows existing package-manager upgrades'
}
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Failures: $script:Failures"
if ($script:Failures -gt 0) { exit 1 }
exit 0
