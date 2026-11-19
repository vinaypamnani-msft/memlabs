<#
.SYNOPSIS
    Verify primary encryption using real modern mRemoteNG assemblies.
.DESCRIPTION
    Uses scratch installation copies and isolated workers, without launching the
    application, touching real connection files, or reading real credentials.
    Run the controller from x64 PowerShell 7 with the package's target .NET runtime.
#>
[CmdletBinding()]
param(
    [string]$InstallationPath,
    [ValidateSet('Primary', 'Broken', 'Unsupported', 'Preserve')]
    [string]$Case,
    [string]$TestRoot
)

function Assert-True {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { throw "FAIL: $What" }
    Write-Host "PASS  $What"
}

if (-not $Case) {
    if (-not $InstallationPath) { $InstallationPath = Join-Path $env:ProgramData 'memlabs\mRemoteNG' }
    $runtimePath = Join-Path $InstallationPath 'mRemoteNG.runtimeconfig.json'
    $runtime = Get-Content -LiteralPath $runtimePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($runtime.runtimeOptions.tfm -notmatch '^net(\d+)\.') { throw 'The installed package target framework is unsupported.' }
    if ($PSVersionTable.PSEdition -ne 'Core' -or [Environment]::Version.Major -lt [int]$Matches[1] -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        throw "Run this regression with x64 PowerShell 7 matching $($runtime.runtimeOptions.tfm)."
    }
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-mrng-primary-' + [guid]::NewGuid().ToString('N'))
    $installCopy = Join-Path $workDir 'programdata\memlabs\mRemoteNG'
    $null = New-Item -ItemType Directory -Path $installCopy -Force -ErrorAction Stop
    try {
        foreach ($name in @('mRemoteNG.exe', 'mRemoteNG.dll', 'BouncyCastle.Cryptography.dll', 'mRemoteNG.runtimeconfig.json')) {
            Copy-Item -LiteralPath (Join-Path $InstallationPath $name) -Destination (Join-Path $installCopy $name) -ErrorAction Stop
        }
        [IO.File]::WriteAllBytes((Join-Path $installCopy 'BouncyCastle.Crypto.dll'), [byte[]]@(0))
        $engine = Join-Path $PSHOME 'pwsh.exe'
        & $engine -NoLogo -NoProfile -File $PSCommandPath -Case Primary -TestRoot $workDir
        if ($LASTEXITCODE -ne 0) { throw 'Real primary encryption regression failed.' }
        $winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $winPS -NoLogo -NoProfile -File $PSCommandPath -Case Unsupported -TestRoot $workDir
        if ($LASTEXITCODE -ne 0) { throw 'Unsupported runtime regression failed.' }
        [IO.File]::WriteAllBytes((Join-Path $installCopy 'mRemoteNG.dll'), [byte[]]@(0))
        & $engine -NoLogo -NoProfile -File $PSCommandPath -Case Broken -TestRoot $workDir
        if ($LASTEXITCODE -ne 0) { throw 'Modern loader failure regression failed.' }
        & $engine -NoLogo -NoProfile -File $PSCommandPath -Case Preserve -TestRoot $workDir
        if ($LASTEXITCODE -ne 0) { throw 'Connection preservation regression failed.' }
    }
    finally { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
    Write-Host 'OK - real mRemoteNG primary encryption regressions passed.'
    return
}

function Import-TestFunction {
    param($Ast, [string]$Name)

    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one definition of $Name." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Read-TestAst {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "Parse errors in $Path." }
    return $ast
}

$root = Split-Path -Parent $PSScriptRoot
$commonAst = Read-TestAst (Join-Path $root 'Common.ps1')
. (Import-TestFunction $commonAst 'Protect-MemLabsLogText')
. (Import-TestFunction $commonAst 'Get-JsonLogEscaped')
$mRemoteAst = Read-TestAst (Join-Path $root 'common\Common.mRemoteNG.ps1')
foreach ($name in @(
        'New-MRemoteNGCryptoProvider', 'Get-MRemoteNGPassword', 'New-MRemoteNGFileFromHyperV',
        'New-MRemoteNGXmlDocument', 'Repair-MRemoteNGPasswords', 'Get-MRNGMemberValue',
        'Set-MRNGMemberValue', 'Get-MRNGProviderSnapshot', 'Test-MRNGDecryptWithFileIterations', 'Write-MRNGDiag'
    )) {
    . (Import-TestFunction $mRemoteAst $name)
}

$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:FallbackCalls = 0
function Write-Log {
    [CmdletBinding()]
    param([string]$Text, [switch]$Warning, [switch]$LogOnly, [switch]$Activity)

    if ($Warning) { $script:Warnings.Add((Protect-MemLabsLogText $Text)) }
}
function Get-MRemoteNGPassword32Bit {
    $script:FallbackCalls++
    throw 'A modern installation must never try the 32-bit fallback.'
}

$secret = 'synthetic-primary-' + [guid]::NewGuid().ToString('N')
$secure = New-Object Security.SecureString
foreach ($ch in $secret.ToCharArray()) { $secure.AppendChar($ch) }
$global:Common = [pscustomobject]@{
    LocalAdmin = New-Object System.Management.Automation.PSCredential('synthetic-user', $secure)
    LogPath = Join-Path $TestRoot 'VMBuild.log'
}
$env:ProgramData = Join-Path $TestRoot 'programdata'

try {
    if ($Case -eq 'Preserve') {
        function Invoke-PreservationTest {
            param([string]$Path, [bool]$Overwrite)

            function Get-MRemoteNGPassword { return $null }
            function Invoke-VMNetworkBulkWarmup { throw 'VM queries must not run after encryption failure.' }
            function Get-Process { throw 'Processes must not be inspected after encryption failure.' }
            function Remove-Item { throw 'Files must not be deleted after encryption failure.' }
            New-MRemoteNGFileFromHyperV -MRemoteNGFile $Path -OverWrite:$Overwrite -NoActivity
        }
        $target = Join-Path $TestRoot 'existing-connections.xml'
        $original = '<Connections><Node Password="preserve-existing-encrypted-value" /></Connections>'
        [IO.File]::WriteAllText($target, $original)
        foreach ($overwrite in @($false, $true)) {
            Invoke-PreservationTest -Path $target -Overwrite $overwrite
            Assert-True (([IO.File]::ReadAllText($target)) -eq $original) "encryption failure preserves connection bytes with OverWrite=$overwrite"
        }
        Assert-True ($script:Warnings.Count -eq 2) 'failed updates report explicit warnings'
        return
    }

    $encrypted = Get-MRemoteNGPassword
    Assert-True ($script:FallbackCalls -eq 0) 'modern package never invokes legacy 32-bit fallback'
    if ($Case -ne 'Primary') {
        Assert-True ([string]::IsNullOrEmpty($encrypted)) 'incompatible or broken installations return no fake ciphertext'
        $warnings = $script:Warnings -join "`n"
        Assert-True ($warnings.Contains('primary encryption failed') -and $warnings.Contains('PowerShell') -and
            $warnings.Contains('.NET') -and $warnings.Contains('assembly=')) 'original primary failure retains runtime and assembly context'
        if ($Case -eq 'Unsupported') {
            Assert-True ($warnings.Contains('Run it from x64 PowerShell 7')) 'Windows PowerShell gets an actionable runtime requirement instead of a BadImage retry'
        }
        Assert-True (-not $warnings.Contains($secret)) 'primary error diagnostics do not disclose the credential'
        return
    }

    Assert-True (-not [string]::IsNullOrWhiteSpace($encrypted)) 'real installed provider encrypts on the primary path'
    Assert-True ($script:Warnings.Count -eq 0) 'primary encryption succeeds without any hidden exception or fallback warning'
    $provider = New-Object mRemoteNG.Security.SymmetricEncryption.AeadCryptographyProvider -ErrorAction Stop
    $key = New-Object Security.SecureString
    foreach ($ch in 'mR3m'.ToCharArray()) { $key.AppendChar($ch) }
    try {
        Assert-True ($provider.Decrypt($encrypted, $key) -ceq $secret) 'real mRemoteNG provider decrypts the generated ciphertext to the original value'
        $doc = New-MRemoteNGXmlDocument
        Assert-True ((Get-MRNGMemberValue $provider 'KeyDerivationIterations') -eq [int]$doc.DocumentElement.GetAttribute('KdfIterations')) 'primary provider and generated XML retain matching KDF parameters'
        $node = $doc.CreateElement('Node')
        $node.SetAttribute('Name', 'synthetic-node')
        $node.SetAttribute('Type', 'Connection')
        $node.SetAttribute('Password', $encrypted)
        [void]$doc.DocumentElement.AppendChild($node)
        Assert-True (-not (Repair-MRemoteNGPasswords -Doc $doc -FreshEncryptedPassword $encrypted)) 'password audit accepts a real primary-encrypted connection without repair'
        $node.SetAttribute('Password', 'invalid-ciphertext')
        Assert-True (Repair-MRemoteNGPasswords -Doc $doc -FreshEncryptedPassword $encrypted) 'password audit still repairs corrupt ciphertext'
        Assert-True ($provider.Decrypt($node.GetAttribute('Password'), $key) -ceq $secret) 'repaired connection remains decryptable by the installed application provider'
    }
    finally { $key.Dispose() }
}
finally { $secure.Dispose() }
