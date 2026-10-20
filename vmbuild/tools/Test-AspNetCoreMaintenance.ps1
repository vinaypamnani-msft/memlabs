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
    'Invoke-AspNetCoreMaintenance', 'Get-InstalledAspNetCoreEntry', 'Get-SupersededAspNetCoreEntry', 'Remove-SupersededAspNetCoreRuntime',
    'ConvertTo-QuietUninstallCommand', 'Split-UninstallCommand', 'Test-ChocoSuccessCode'
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
        $files = @(
            'Microsoft.AspNetCore.App.deps.json', 'Microsoft.AspNetCore.App.runtimeconfig.json',
            'Microsoft.AspNetCore.dll', 'System.IO.Pipelines.dll', 'aspnetcorev2_inprocess.dll'
        )
        if ($Version -match '^[89]\.') { $files += 'THIRD-PARTY-NOTICES.txt' }
        foreach ($file in $files) {
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
    $script:EntryQueryFails = $false
    $script:UninstallerUnregisters = $true
    $script:UninstallerLeavesNativeFiles = $false
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
    param ([string] $NameLike, [switch] $Strict)
    if ($script:EntryQueryFails) { throw 'simulated registry access denied' }
    $script:Entries | Where-Object DisplayName -like $NameLike
}

function Stop-ProcessTree {
    param ([int] $ProcessId)
    $script:StoppedProcess = $ProcessId
}

function Start-Process {
    [CmdletBinding()]
    param ([string] $FilePath, [string] $ArgumentList, [switch] $PassThru, [string] $WindowStyle)
    $script:Processes += [pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList }
    $uninstall = $ArgumentList -match '(?:^|\s)/(?:uninstall|x)(?:\s|$)'
    if ([IO.Path]::GetFileName($FilePath) -ieq 'msiexec.exe') {
        if ($ArgumentList -notmatch '/x\s+(?<ProductCode>\{[a-fA-F0-9-]{36}\})') { throw 'MSI removal must use an exact product GUID.' }
        $productCode = $Matches.ProductCode
        $uninstalling = @($script:Entries | Where-Object PSChildName -eq $productCode)
        if ($uninstalling.Count -ne 1 -or $uninstalling[0].DisplayName -notmatch '(?<Version>\d+\.\d+\.\d+).*\((?<Architecture>x64|x86|arm64)\)') {
            throw 'MSI fixture did not match a runtime product.'
        }
    }
    else {
        if ($FilePath -notmatch 'aspnetcore-(?:runtime-)?(?<Version>\d+\.\d+\.\d+)-(?:win-)?(?<Architecture>x64|x86|arm64)') {
            throw "Unexpected installer path '$FilePath'."
        }
        $uninstalling = @($script:Entries | Where-Object { $_.QuietUninstallString -like "*$FilePath*" })
    }
    $version = $Matches.Version
    $architecture = $Matches.Architecture
    $path = Get-FixtureRuntimePath -Version $version -Architecture $architecture
    if ($script:InstallerCompletes -and ($script:InstallerExitCode -in @(0, 1641, 3010) -or ($uninstall -and $script:InstallerExitCode -in @(1605, 1614)))) {
        if ($uninstall) {
            if ($script:UninstallerLeavesNativeFiles) {
                foreach ($file in @(Get-ChildItem -LiteralPath $path -File -Force | Where-Object Name -ne 'aspnetcorev2_inprocess.dll')) {
                    Remove-Item -LiteralPath $file.FullName -Force
                }
            }
            elseif ($script:UninstallerRemovesOld -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force }
            if ($script:UninstallerUnregisters) {
                $script:Entries = @($script:Entries | Where-Object { $uninstalling.PSChildName -notcontains $_.PSChildName })
            }
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
    param ([string] $Architecture = 'x64', [string] $Version = '10.0.8', [switch] $Msi, [switch] $Hidden)
    $productCode = [guid]::NewGuid().ToString('B')
    $script:Entries = @([pscustomobject]@{
            DisplayName = "Microsoft ASP.NET Core $Version - Shared Framework ($Architecture)"
            SystemComponent = [int]$Hidden.IsPresent
            WindowsInstaller = [int]$Msi.IsPresent
            PSChildName = $productCode
            QuietUninstallString = $(if ($Msi) { "MsiExec.exe /X$productCode" } else { "`"C:\Package Cache\aspnetcore-runtime-$Version-win-$Architecture.exe`" /uninstall" })
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
    Set-FixtureStandaloneEntry -Msi -Hidden
    Assert-Throws { Invoke-AspNetCoreMaintenance } 'missing runtime files cannot hide leftover runtime uninstall registrations'
    Assert-Equal 0 $script:Downloads.Count 'leftover registrations without runtime files do not install ASP.NET'
    Assert-Equal 0 $script:Processes.Count 'registration-only unknown patch state requires explicit repair rather than an assumed removal'

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
    Assert-Equal $true ($script:MetadataCalls.Count -gt 0) 'an active test cycle does not defer security remediation'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'an active test cycle does not exempt an old vulnerable patch'
    Assert-Equal $true (@($script:Logs | Where-Object Message -like '*will not be deferred*').Count -gt 0) 'overriding a held test lease is explicit'

    foreach ($failure in @('metadata', 'hash', 'unsigned', 'publisher', 'exit', 'timeout', 'no-files', 'bad-url', 'bad-metadata')) {
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
            'bad-url' { $script:Releases['10.0'].releases[0].'aspnetcore-runtime'.files[0].url = 'https://example.invalid/installer.exe' }
            'bad-metadata' { $script:Index.'releases-index'[0].'latest-runtime' = '11.0.0' }
        }
        Assert-Throws { Invoke-AspNetCoreMaintenance } "$failure cannot be reported as successful remediation"
        if ($failure -in @('metadata', 'hash', 'unsigned', 'publisher', 'bad-url', 'bad-metadata')) {
            Assert-Equal 0 $script:Processes.Count "$failure cannot launch an installer"
        }
        if ($failure -eq 'timeout') { Assert-Equal 987654 $script:StoppedProcess 'a timed-out installer is stopped by its specific process ID' }
        $canIdentifySuperseded = $failure -notin @('metadata', 'bad-metadata')
        Assert-Equal (-not $canIdentifySuperseded) (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) "$failure still removes a superseded patch when the trusted minimum is known"
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

    foreach ($protected in @('missing-replacement', 'ineffective-uninstall', 'removed-replacement')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13' -Incomplete:($protected -eq 'missing-replacement')
        Set-FixtureStandaloneEntry
        switch ($protected) {
            'ineffective-uninstall' { $script:UninstallerRemovesOld = $false; $script:UninstallerUnregisters = $false }
            'removed-replacement' { $script:UninstallerRemovesReplacement = $true }
        }
        Assert-Throws { Invoke-AspNetCoreMaintenance } "$protected does not produce false remediation"
        Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) "$protected does not retain the superseded files"
    }

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:Downloads.Count 'reported coexistence case does not reinstall an already-current patch'
    Assert-Equal 0 $script:Processes.Count 'unregistered leftover cleanup needs no new uninstall utility'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'reported unregistered 10.0.8 directory is actually removed'
    Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.13')) 'unregistered cleanup preserves 10.0.13'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 0 $script:Processes.Count 'unregistered cleanup is idempotent'

    Reset-Fixture
    Add-FixtureRuntime
    $script:InstallerRemovesOld = $false
    Invoke-AspNetCoreMaintenance
    Assert-Equal 1 $script:Downloads.Count 'patching still installs the replacement before orphan cleanup'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'unregistered leftovers from an otherwise successful update are cleaned'

    foreach ($unrelated in @('other-architecture', 'latest-version')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13'
        if ($unrelated -eq 'other-architecture') { Set-FixtureStandaloneEntry 'x86' }
        else { Set-FixtureStandaloneEntry -Version '10.0.13' }
        Invoke-AspNetCoreMaintenance
        Assert-Equal 0 $script:Processes.Count "$unrelated registration is not uninstalled"
        Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) "$unrelated registration does not block an unowned x64 old patch"
    }

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    Set-FixtureStandaloneEntry
    $script:Entries[0].DisplayName = 'ASP.NET Core Runtime - 10.0.8 (x64)'
    Invoke-AspNetCoreMaintenance
    Assert-Equal 1 $script:Processes.Count 'a standalone bundle without the Microsoft name prefix uses its registered uninstaller'

    foreach ($architecture in @('x64', 'x86', 'arm64')) {
        Reset-Fixture
        if ($architecture -eq 'arm64') { $env:PROCESSOR_ARCHITECTURE = 'ARM64' }
        Add-FixtureRuntime '10.0.8' $architecture
        Add-FixtureRuntime '10.0.13' $architecture
        Set-FixtureStandaloneEntry -Architecture $architecture -Msi -Hidden
        $script:UninstallerLeavesNativeFiles = $true
        $oldPath = Get-FixtureRuntimePath '10.0.8' $architecture
        $nativePath = Join-Path $oldPath 'aspnetcorev2_inprocess.dll'
        $targetPath = Get-FixtureRuntimePath '10.0.13' $architecture
        Invoke-AspNetCoreMaintenance
        Assert-Equal 1 $script:Processes.Count "$architecture native-only cleanup follows the registered MSI uninstall"
        Assert-Equal 0 $script:Entries.Count "$architecture native-only cleanup leaves no superseded MSI registration"
        Assert-Equal $false (Test-Path -LiteralPath $nativePath) "$architecture removes the exact aspnetcorev2_inprocess.dll from the reported failure"
        Assert-Equal $false (Test-Path -LiteralPath $oldPath) "$architecture removes the old directory even when uninstall removed its managed files and version marker"
        Assert-Equal 'fixture' (Get-Content -LiteralPath (Join-Path $targetPath 'aspnetcorev2_inprocess.dll') -Raw).Trim() "$architecture preserves the patched native hosting DLL"
        Assert-Equal 0 $script:Downloads.Count "$architecture native-only cleanup does not download or reinstall the current patch"
    }

    Reset-Fixture
    Add-FixtureRuntime '8.0.20'
    Add-FixtureRuntime '8.0.32'
    $noticePath = Join-Path (Get-FixtureRuntimePath '8.0.20') 'THIRD-PARTY-NOTICES.txt'
    Invoke-AspNetCoreMaintenance
    Assert-Equal $false (Test-Path -LiteralPath $noticePath) 'older runtime license notices do not block superseded patch removal'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '8.0.20')) 'a real-shaped older branch runtime directory is fully removed'
    Assert-Equal 'fixture' (Get-Content -LiteralPath (Join-Path (Get-FixtureRuntimePath '8.0.32') 'THIRD-PARTY-NOTICES.txt') -Raw).Trim() 'the supported patch retains its third-party notices'

    foreach ($enforcement in @('hidden-bundle', 'hidden-msi', 'sdk-files', 'sdk-registration', 'unknown-architecture', 'installer-failure', 'registry-error', 'missing-product-code')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13'
        switch ($enforcement) {
            'hidden-bundle' { Set-FixtureStandaloneEntry -Hidden }
            'hidden-msi' { Set-FixtureStandaloneEntry -Msi -Hidden }
            'sdk-files' {
                $null = New-Item -Path (Join-Path $script:NativeRoot 'sdk\10.0.108') -ItemType Directory -Force
            }
            'sdk-registration' {
                $script:Entries = @([pscustomobject]@{ DisplayName = 'Microsoft .NET SDK 10.0.108 (x64)'; DisplayVersion = '10.0.108' })
            }
            'unknown-architecture' {
                Set-FixtureStandaloneEntry
                $script:Entries[0].DisplayName = 'ASP.NET Core Runtime - 10.0.8'
            }
            'installer-failure' { Set-FixtureStandaloneEntry -Msi -Hidden; $script:InstallerExitCode = 1603 }
            'registry-error' { $script:EntryQueryFails = $true }
            'missing-product-code' { Set-FixtureStandaloneEntry -Msi -Hidden; $script:Entries[0].PSChildName = 'not-a-product-guid' }
        }
        $msiProductCode = if ($enforcement -eq 'hidden-msi') { $script:Entries[0].PSChildName } else { '' }
        if ($enforcement -in @('installer-failure', 'registry-error', 'missing-product-code')) {
            Assert-Throws { Invoke-AspNetCoreMaintenance } "$enforcement remains an explicit maintenance failure"
        }
        else {
            Invoke-AspNetCoreMaintenance
        }
        Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) "$enforcement cannot exempt a superseded runtime from removal"
        Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.13')) "$enforcement does not remove the patched runtime"
        if ($enforcement -eq 'hidden-msi') {
            Assert-Equal (Join-Path $env:SystemRoot 'System32\msiexec.exe') $script:Processes[0].FilePath 'hidden runtime MSI is uninstalled through the system installer'
            Assert-Equal $true ($script:Processes[0].Arguments -like "/x $msiProductCode /qn /norestart /log *") 'MSI removal uses the exact superseded product and never requests a restart'
            Assert-Equal 0 $script:Entries.Count 'successful MSI removal leaves no old runtime registration'
        }
        if ($enforcement -eq 'sdk-files') {
            Assert-Equal $true (Test-Path -LiteralPath (Join-Path $script:NativeRoot 'sdk\10.0.108')) 'the SDK itself is not deleted to remove an old shared runtime'
        }
    }

    Reset-Fixture
    Add-FixtureRuntime '10.0.13'
    Set-FixtureStandaloneEntry -Msi -Hidden
    Invoke-AspNetCoreMaintenance
    Assert-Equal 1 $script:Processes.Count 'an old registered runtime is removed even when its files are already absent'
    Assert-Equal 0 $script:Entries.Count 'stale runtime registration cannot resurrect the old runtime through repair'

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    $script:MetadataFails = $true
    Assert-Throws { Invoke-AspNetCoreMaintenance } 'metadata outage prevents a latest-version success claim'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'metadata outage does not retain an older patch beside an installed newer one'

    foreach ($forceable in @('read-only', 'old-marker')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13'
        $oldPath = Get-FixtureRuntimePath '10.0.8'
        if ($forceable -eq 'read-only') {
            [IO.File]::SetAttributes((Join-Path $oldPath 'Microsoft.AspNetCore.dll'), [IO.FileAttributes]::ReadOnly)
        }
        else { Set-Content -LiteralPath (Join-Path $oldPath '.version') -Value '10.0.7' -Encoding ascii }
        Invoke-AspNetCoreMaintenance
        Assert-Equal $false (Test-Path -LiteralPath $oldPath) "$forceable does not preserve a known superseded runtime directory"
    }

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    Set-Content -LiteralPath (Join-Path (Get-FixtureRuntimePath '10.0.13') '.version') -Value '10.0.8' -Encoding ascii
    Assert-Throws { Invoke-AspNetCoreMaintenance } 'an unverified target version marker prevents a success claim'
    Assert-Equal $false (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.8')) 'an invalid replacement marker does not retain the superseded runtime'

    foreach ($unsafe in @('nested-directory', 'unexpected-file', 'locked-file', 'locked-native-file')) {
        Reset-Fixture
        Add-FixtureRuntime
        Add-FixtureRuntime '10.0.13'
        $oldPath = Get-FixtureRuntimePath '10.0.8'
        $dll = Join-Path $oldPath $(if ($unsafe -eq 'locked-native-file') { 'aspnetcorev2_inprocess.dll' } else { 'Microsoft.AspNetCore.dll' })
        $lock = $null
        try {
            switch ($unsafe) {
                'nested-directory' { $null = New-Item -Path (Join-Path $oldPath 'unexpected') -ItemType Directory -Force }
                'unexpected-file' { Set-Content -LiteralPath (Join-Path $oldPath 'customer.txt') -Value 'preserve' -Encoding ascii }
                'locked-file' { $lock = [IO.File]::Open($dll, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
                'locked-native-file' { $lock = [IO.File]::Open($dll, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
            }
            Assert-Throws { Invoke-AspNetCoreMaintenance } "$unsafe prevents direct cleanup"
            Assert-Equal $true (Test-Path -LiteralPath $dll) "$unsafe leaves old runtime files intact"
            Assert-Equal $true (Test-Path -LiteralPath (Join-Path $oldPath '.version')) "$unsafe is detected before deleting any marker"
        }
        finally { if ($lock) { $lock.Dispose() } }
    }

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    $outside = Join-Path $fixtureRoot 'outside-runtime'
    $null = New-Item -Path $outside -ItemType Directory -Force
    $sentinel = Join-Path $outside 'keep.txt'
    Set-Content -LiteralPath $sentinel -Value 'preserve' -Encoding ascii
    $junction = Join-Path (Get-FixtureRuntimePath '10.0.8') 'redirect'
    $null = New-Item -Path $junction -ItemType Junction -Target $outside
    try {
        Assert-Throws { Invoke-AspNetCoreMaintenance } 'a reparse child cannot redirect cleanup outside the runtime'
        Assert-Equal 'preserve' (Get-Content -LiteralPath $sentinel -Raw).Trim() 'reparse target contents are untouched'
    }
    finally { [IO.Directory]::Delete($junction, $false) }

    Reset-Fixture
    Add-FixtureRuntime
    Add-FixtureRuntime '10.0.13'
    $currentRuntime = Get-InstalledAspNetCoreRuntime | Where-Object Version -eq ([version]'10.0.13')
    Assert-Throws {
        Remove-SupersededAspNetCoreRuntime -Runtime $currentRuntime -MinimumVersion ([version]'10.0.8')
    } 'direct cleanup cannot be called to delete the newer runtime'
    Assert-Equal $true (Test-Path -LiteralPath (Get-FixtureRuntimePath '10.0.13')) 'newer runtime remains after a reversed cleanup request'

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
