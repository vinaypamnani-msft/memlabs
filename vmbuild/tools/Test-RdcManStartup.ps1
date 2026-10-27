<#
.SYNOPSIS
    Exercise startup RDCMan pinning without touching installed clients or lab VMs.
#>
[CmdletBinding()]
param([string]$RootPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.RdcMan.ps1'
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:Failures++
        Write-Host "FAIL  $Message" -ForegroundColor Red
    }
}

function Invoke-StartupCase {
    param(
        [string]$CaseRoot,
        [string]$PinnedVersion,
        [string]$CacheVersion,
        [string]$FallbackVersion = '3.21.0.0',
        [string]$StorageVersion,
        [string]$RdgVersion = '2.92',
        [string]$RdgContent,
        [ValidateSet('None', 'Pinned', 'Fallback')][string]$Running = 'None',
        [switch]$MissingRdg,
        [switch]$StopFails,
        [switch]$CopyFails,
        [switch]$AssociationFails,
        [switch]$GenerationFails,
        [switch]$InitFailed,
        [switch]$Repeat,
        [switch]$WhatIf
    )

    . $sourcePath
    $previousPinnedDir = $global:RDCManPinnedDir
    $previousFallbackDir = $global:RDCManFallbackDir
    $global:RDCManPinnedDir = Join-Path $CaseRoot 'pinned'
    $global:RDCManFallbackDir = Join-Path $CaseRoot 'tools'
    $Common = [pscustomobject]@{
        CachePath        = Join-Path $CaseRoot 'cache'
        AzureFilesPath   = Join-Path $CaseRoot 'azure'
        AzureFileList    = [pscustomobject]@{ SupportFiles = @() }
        FatalError       = $(if ($InitFailed) { 'Synthetic initialization failure.' } else { $null })
        RdcManFilePath   = Join-Path $CaseRoot 'memlabs.rdg'
        MRemoteNGFilePath = Join-Path $CaseRoot 'memlabs-mremoteng.xml'
    }
    $null = New-Item -ItemType Directory -Path $global:RDCManPinnedDir, $global:RDCManFallbackDir, $Common.CachePath, $Common.AzureFilesPath -Force
    $pinnedExe = Join-Path $global:RDCManPinnedDir 'RDCMan.exe'
    $fallbackExe = Join-Path $global:RDCManFallbackDir 'RDCMan.exe'
    if ($PinnedVersion) { [IO.File]::WriteAllText($pinnedExe, $PinnedVersion) }
    if ($FallbackVersion) { [IO.File]::WriteAllText($fallbackExe, $FallbackVersion) }
    if ($CacheVersion) { [IO.File]::WriteAllText((Join-Path $Common.CachePath $global:RDCManCacheFileName), $CacheVersion) }
    if ($StorageVersion) {
        $Common.AzureFileList.SupportFiles = @([pscustomobject]@{ id = $global:RDCManStorageFileId; filename = 'downloaded.exe' })
    }
    if (-not $MissingRdg) {
        if (-not $RdgContent) {
            $RdgContent = "<RDCMan programVersion='$RdgVersion'><file><properties><name>original</name></properties></file></RDCMan>"
        }
        [IO.File]::WriteAllText($Common.RdcManFilePath, $RdgContent)
    }
    $state = [pscustomobject]@{
        PinnedExe       = $pinnedExe
        StorageVersion  = $StorageVersion
        StopFails       = $StopFails.IsPresent
        CopyFails       = $CopyFails.IsPresent
        AssociationFails = $AssociationFails.IsPresent
        GenerationFails = $GenerationFails.IsPresent
        Events          = [Collections.Generic.List[string]]::new()
        Logs            = [Collections.Generic.List[object]]::new()
        Processes       = @()
        StopCalls       = 0
        InstallCalls    = 0
        StorageCalls    = 0
        RdcCalls        = 0
        MRemoteCalls    = 0
        RestartRequested = $false
    }
    if ($Running -ne 'None') {
        $runningPath = $fallbackExe
        if ($Running -eq 'Pinned') { $runningPath = $pinnedExe }
        $state.Processes = @([pscustomobject]@{ Id = 101; ProcessName = 'RDCMan'; Path = $runningPath; HasExited = $false })
    }

    function Write-Log {
        [CmdletBinding()]
        param([string]$Message, [switch]$LogOnly, [switch]$Warning, [switch]$Failure)
        $state.Logs.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent; Failure = $Failure.IsPresent })
    }
    function Get-RDCManVersion {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return [version][IO.File]::ReadAllText($Path)
    }
    function Get-Process {
        [CmdletBinding()]
        param()
        $state.Processes | Where-Object { -not $_.HasExited }
    }
    function Stop-RDCMan {
        $state.Events.Add('Stop')
        $state.StopCalls++
        if ($state.StopFails) { throw 'Synthetic RDCMan shutdown failure.' }
        $active = @($state.Processes | Where-Object { -not $_.HasExited })
        foreach ($process in $active) { $process.HasExited = $true }
        return ($active.Count -gt 0)
    }
    function Copy-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($Destination -eq $state.PinnedExe) {
            $state.Events.Add('CopyPinned')
            if (@($state.Processes | Where-Object { -not $_.HasExited }).Count -gt 0) { throw 'Pinned executable was replaced before RDCMan exited.' }
            if ($state.CopyFails) { throw [IO.IOException]::new('Synthetic pinned-executable copy failure.') }
        }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
    }
    function Get-FileFromStorage {
        param($File, [bool]$IgnoreHashFailure)
        if ($File.id -ne $global:RDCManStorageFileId -or $IgnoreHashFailure) { throw 'Startup changed pinned-download verification.' }
        $state.StorageCalls++
        [IO.File]::WriteAllText((Join-Path $Common.AzureFilesPath $File.filename), $state.StorageVersion)
        return $true
    }
    function Install-RDCman {
        $state.Events.Add('Install')
        $state.InstallCalls++
        if ((Get-RDCManVersion -Path (Get-RDCManExePath)) -ne $global:RDCManPinnedVersion) { throw 'Startup registered an unpinned executable.' }
        if ($state.AssociationFails) { throw 'Synthetic RDCMan association failure.' }
    }
    function New-RDCManFileFromHyperV {
        param([string]$rdcmanfile, [bool]$OverWrite, [switch]$NoActivity, [switch]$RestartRDCMan)
        if ($rdcmanfile -ne $Common.RdcManFilePath -or -not $OverWrite -or -not $NoActivity -or
            @($state.Processes | Where-Object { -not $_.HasExited }).Count -gt 0) {
            throw 'Startup did not rebuild the expected RDG after confirmed shutdown.'
        }
        $state.Events.Add('RdcGenerate')
        $state.RdcCalls++
        if ($state.GenerationFails) { throw 'Synthetic RDCMan regeneration failure.' }
        [IO.File]::WriteAllText($rdcmanfile, "<RDCMan programVersion='2.92'><file><properties><name>memlabs</name></properties></file></RDCMan>")
        $state.RestartRequested = $RestartRDCMan.IsPresent
        if ($RestartRDCMan) {
            $state.Processes += [pscustomobject]@{ Id = 201; ProcessName = 'RDCMan'; Path = (Get-RDCManExePath); HasExited = $false }
        }
    }
    function New-MRemoteNGFileFromHyperV {
        param([string]$MRemoteNGFile, [bool]$OverWrite, [switch]$NoActivity)
        if ($MRemoteNGFile -ne $Common.MRemoteNGFilePath -or -not $OverWrite -or -not $NoActivity) { throw 'Startup did not rebuild the expected mRemoteNG file.' }
        $state.Events.Add('MRemoteGenerate')
        $state.MRemoteCalls++
        [IO.File]::WriteAllText($MRemoteNGFile, '<Connections />')
    }

    try {
        $caughtError = $null
        try {
            Initialize-RDCManAtStartup -WhatIf:$WhatIf
            if ($Repeat) { Initialize-RDCManAtStartup -WhatIf:$WhatIf }
        }
        catch {
            $caughtError = $_.Exception.Message
        }
        $actualContent = $null
        if (Test-Path -LiteralPath $Common.RdcManFilePath) { $actualContent = [IO.File]::ReadAllText($Common.RdcManFilePath) }
        return [pscustomobject]@{
            Error            = $caughtError
            PinnedVersion    = Get-RDCManVersion -Path $pinnedExe
            StopCalls        = $state.StopCalls
            InstallCalls     = $state.InstallCalls
            StorageCalls     = $state.StorageCalls
            RdcCalls         = $state.RdcCalls
            MRemoteCalls     = $state.MRemoteCalls
            RestartRequested = $state.RestartRequested
            RunningPaths     = @($state.Processes | Where-Object { -not $_.HasExited } | ForEach-Object Path)
            Events           = $state.Events.ToArray()
            Logs             = $state.Logs.ToArray()
            OriginalContent  = $(if ($MissingRdg) { $null } else { $RdgContent })
            Content          = $actualContent
            PreferredPath    = Get-RDCManExePath
        }
    }
    finally {
        $global:RDCManPinnedDir = $previousPinnedDir
        $global:RDCManFallbackDir = $previousFallbackDir
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-rdcman-startup-$([guid]::NewGuid().ToString('N'))"
try {
    $cases = @(
        @{ Name = 'healthy'; Args = @{ PinnedVersion = '3.12.0.0' }; Refresh = $false }
        @{ Name = 'healthy-running'; Args = @{ PinnedVersion = '3.12.0.0'; Running = 'Pinned' }; Refresh = $false }
        @{ Name = 'cached-downgrade'; Args = @{ PinnedVersion = '3.21.0.0'; CacheVersion = '3.12.0.0'; Running = 'Pinned'; Repeat = $true }; Refresh = $true }
        @{ Name = 'cached-not-running'; Args = @{ CacheVersion = '3.12.0.0' }; Refresh = $true }
        @{ Name = 'rescued-pin'; Args = @{ FallbackVersion = '3.12.0.0'; Running = 'Fallback'; Repeat = $true }; Refresh = $true }
        @{ Name = 'storage-downgrade'; Args = @{ StorageVersion = '3.12.0.0'; Running = 'Fallback' }; Refresh = $true }
        @{ Name = 'launcher-installed'; Args = @{ PinnedVersion = '3.12.0.0'; RdgVersion = '3.21'; Repeat = $true }; Refresh = $true }
        @{ Name = 'newer-running'; Args = @{ PinnedVersion = '3.12.0.0'; Running = 'Fallback'; Repeat = $true }; Refresh = $true }
        @{ Name = 'missing-rdg'; Args = @{ PinnedVersion = '3.12.0.0'; MissingRdg = $true }; Refresh = $true }
        @{ Name = 'broken-rdg'; Args = @{ PinnedVersion = '3.12.0.0'; RdgContent = '<RDCMan'; Repeat = $true }; Refresh = $true }
        @{ Name = 'wrong-root'; Args = @{ PinnedVersion = '3.12.0.0'; RdgContent = '<Other />' }; Refresh = $true }
        @{ Name = 'invalid-version'; Args = @{ PinnedVersion = '3.12.0.0'; RdgVersion = 'broken' }; Refresh = $true }
        @{ Name = 'unavailable-pin'; Args = @{ Running = 'Fallback' }; Refresh = $false }
        @{ Name = 'wrong-download'; Args = @{ StorageVersion = '3.21.0.0'; Running = 'Fallback' }; Refresh = $false }
        @{ Name = 'whatif'; Args = @{ CacheVersion = '3.12.0.0'; Running = 'Fallback'; WhatIf = $true }; Refresh = $false }
        @{ Name = 'init-failed'; Args = @{ CacheVersion = '3.12.0.0'; Running = 'Fallback'; InitFailed = $true }; Refresh = $false }
        @{ Name = 'shutdown-failure'; Args = @{ CacheVersion = '3.12.0.0'; Running = 'Fallback'; StopFails = $true }; Refresh = $false; Error = $true }
        @{ Name = 'copy-failure'; Args = @{ CacheVersion = '3.12.0.0'; Running = 'Fallback'; CopyFails = $true }; Refresh = $false; Error = $true }
        @{ Name = 'association-failure'; Args = @{ CacheVersion = '3.12.0.0'; AssociationFails = $true }; Refresh = $false; Error = $true }
        @{ Name = 'generation-failure'; Args = @{ CacheVersion = '3.12.0.0'; GenerationFails = $true }; Refresh = $false; Error = $true; RdcStarted = $true }
    )
    foreach ($case in $cases) {
        $argsForCase = $case.Args
        $actual = Invoke-StartupCase -CaseRoot (Join-Path $fixtureRoot $case.Name) @argsForCase
        $expectsError = $case.ContainsKey('Error') -and $case.Error
        Assert-True (($null -ne $actual.Error) -eq $expectsError) "$($case.Name) reports the expected startup outcome"
        if ($actual.Error -and -not $expectsError) { Write-Host "      $($actual.Error)" -ForegroundColor Red }
        if ($case.Refresh) {
            Assert-True ($actual.PinnedVersion -eq [version]'3.12.0.0') "$($case.Name) installs or retains the verified pin"
            Assert-True ($actual.RdcCalls -eq 1 -and $actual.MRemoteCalls -eq 1 -and $actual.StopCalls -eq 1) "$($case.Name) regenerates both files exactly once"
            Assert-True (($actual.Events -join ',') -match 'Stop,(CopyPinned,)?Install,RdcGenerate,MRemoteGenerate') "$($case.Name) closes before installation and file generation"
            $expectedRestart = $case.Args.ContainsKey('Running') -and $case.Args.Running -ne 'None'
            Assert-True ($actual.RestartRequested -eq $expectedRestart) "$($case.Name) restarts only a previously running client"
            if ($expectedRestart) {
                Assert-True ($actual.RunningPaths.Count -eq 1 -and $actual.RunningPaths[0] -eq $actual.PreferredPath) "$($case.Name) restarts the pinned executable"
            }
            Assert-True ($actual.Content -match "programVersion='2.92'" -and $actual.Content -match '<name>memlabs</name>') "$($case.Name) writes a compatible regenerated RDG"
        }
        else {
            $expectedRdcCalls = 0
            if ($case.ContainsKey('RdcStarted') -and $case.RdcStarted) { $expectedRdcCalls = 1 }
            Assert-True ($actual.RdcCalls -eq $expectedRdcCalls -and $actual.MRemoteCalls -eq 0) "$($case.Name) does not claim a completed refresh"
            Assert-True ($actual.Content -ceq $actual.OriginalContent -and -not $actual.RestartRequested) "$($case.Name) preserves existing files and restart state"
        }
        if ($case.Name -in @('healthy', 'healthy-running', 'unavailable-pin', 'wrong-download', 'whatif', 'init-failed')) {
            Assert-True ($actual.StopCalls -eq 0) "$($case.Name) leaves the running client alone"
        }
        if ($case.Name -in @('unavailable-pin', 'wrong-download')) {
            Assert-True (@($actual.Logs | Where-Object { $_.Warning -and $_.Message -like '*unchanged*' }).Count -eq 1) "$($case.Name) explicitly reports the unavailable pin"
        }
        if ($case.Name -in @('healthy', 'healthy-running', 'whatif', 'init-failed')) {
            Assert-True ($actual.StorageCalls -eq 0) "$($case.Name) does not download the pin"
        }
        if ($case.Name -eq 'init-failed') {
            Assert-True (@($actual.Logs | Where-Object { $_.Warning -and $_.Message -like '*initialization*' }).Count -eq 1) 'failed initialization explicitly skips client and file changes'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

function Invoke-AssociationCase {
    param([int]$FirstExitCode, [int]$SecondExitCode)
    . $sourcePath
    $state = [pscustomobject]@{ Calls = 0; FirstExitCode = $FirstExitCode; SecondExitCode = $SecondExitCode }
    function Restore-RDCManPinnedVersion { return $true }
    function Get-RDCManExePath { return 'C:\fixture\RDCMan.exe' }
    function Get-RDCManVersion {
        param([string]$Path)
        if ($Path) { return [version]'3.12.0.0' }
    }
    function cmd {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        if ($Arguments[0] -ne '/c' -or $Arguments[1] -notin @('assoc', 'ftype')) { throw 'Unexpected association command.' }
        $state.Calls++
        $global:LASTEXITCODE = $state.SecondExitCode
        if ($state.Calls -eq 1) { $global:LASTEXITCODE = $state.FirstExitCode }
    }
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
    try {
        $caughtError = $null
        try { Install-RDCman } catch { $caughtError = $_.Exception.Message }
        return [pscustomobject]@{ Calls = $state.Calls; Error = $caughtError }
    }
    finally {
        if ($null -eq $previousExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global }
        else { $global:LASTEXITCODE = $previousExitCode.Value }
    }
}

$association = Invoke-AssociationCase -FirstExitCode 0 -SecondExitCode 0
Assert-True ($null -eq $association.Error -and $association.Calls -eq 2) 'successful startup association registers both the extension and pinned executable'
$association = Invoke-AssociationCase -FirstExitCode 1 -SecondExitCode 0
Assert-True ($null -ne $association.Error -and $association.Calls -eq 1) 'extension association failure stops preparation explicitly'
$association = Invoke-AssociationCase -FirstExitCode 0 -SecondExitCode 1
Assert-True ($null -ne $association.Error -and $association.Calls -eq 2) 'executable association failure stops preparation explicitly'

foreach ($entryPoint in @('New-Lab.ps1', 'genconfig.ps1')) {
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath $entryPoint), [ref]$null, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$entryPoint parses"
    $startupCalls = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Initialize-RDCManAtStartup'
    }, $true))
    Assert-True ($startupCalls.Count -eq 1) "$entryPoint invokes RDCMan startup preparation exactly once"
    if ($startupCalls.Count -ne 1) { continue }
    $startup = $startupCalls[0]
    if ($entryPoint -eq 'New-Lab.ps1') {
        $initGuard = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq '$global:init_failed'
        })
        Assert-True ($initGuard.Count -eq 1 -and $startup.Extent.StartOffset -gt $initGuard[0].Extent.EndOffset) 'New-Lab prepares RDCMan only after successful Common initialization'
        Assert-True ($startup.Extent.Text -match '-WhatIf:\$WhatIf') 'New-Lab forwards WhatIf to startup preparation'
    }
    else {
        $internalGuard = $false
        $failureGuard = $false
        $parent = $startup.Parent
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                $condition = $parent.Clauses[0].Item1.Extent.Text
                if ($condition -eq '-not $InternalUseOnly.IsPresent') { $internalGuard = $true }
                if ($condition -eq '-not $global:init_failed') { $failureGuard = $true }
            }
            $parent = $parent.Parent
        }
        Assert-True ($internalGuard -and $failureGuard) 'GenConfig skips preparation for internal calls and failed initialization'
    }
}

if ($script:Failures -gt 0) { throw "$script:Failures RDCMan startup assertion(s) failed." }
Write-Host 'PASS: startup pins RDCMan and regenerates connection files without deployment.' -ForegroundColor Green
