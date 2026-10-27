[CmdletBinding()]
param(
    [string] $RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-True {
    param([bool] $Condition, [string] $What)

    if ($Condition) {
        Write-Host "PASS  $What" -ForegroundColor Green
        return
    }

    $script:Failures++
    Write-Host "FAIL  $What" -ForegroundColor Red
}

function Invoke-RdcManRecoveryCase {
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath,
        [switch] $OverWrite,
        [ValidateSet('None', 'Graceful', 'Delayed', 'Dialog', 'CloseFailure', 'WaitFailure', 'StopFailure', 'Timeout', 'Remaining', 'ExitRace', 'ScanFailure')]
        [string] $Shutdown = 'None',
        [switch] $UseRealSettings,
        [switch] $WhatIf,
        [switch] $StartDuringWarmup,
        [switch] $RestartRDCMan
    )

    Set-StrictMode -Off
    . $SourcePath

    $state = [pscustomobject]@{
        InstallCalled = $false
        Logs          = [System.Collections.ArrayList]::new()
        Shutdown      = $Shutdown
        TargetPath    = $TargetPath
        InitialContent = $(if (Test-Path -LiteralPath $TargetPath) { [IO.File]::ReadAllText($TargetPath) } else { $null })
        SettingsRoot  = Join-Path (Split-Path -Parent $SourcePath) "settings-$([guid]::NewGuid().ToString('N'))"
        SettingsPath  = $null
        ExePath       = Join-Path (Split-Path -Parent $SourcePath) 'RDCMan.exe'
        Processes     = @()
        ProcessesVisible = -not $StartDuringWarmup
        CloseIds      = [System.Collections.Generic.List[int]]::new()
        StopIds       = [System.Collections.Generic.List[int]]::new()
        WaitIds       = [System.Collections.Generic.List[int]]::new()
        WaitTimeouts  = [System.Collections.Generic.List[int]]::new()
        WroteBeforeExit = $false
        Restarted     = $false
        SuccessMessages = [System.Collections.Generic.List[string]]::new()
    }
    $state.SettingsPath = Join-Path $state.SettingsRoot 'Microsoft\Remote Desktop Connection Manager\RDCMan.settings'
    if ($Shutdown -ne 'None') {
        $state.Processes = @(foreach ($id in @(101, 102)) {
            $process = [pscustomobject]@{
                Id          = $id
                ProcessName = 'RDCMan'
                Path        = $state.ExePath
                HasExited   = $false
                State       = $state
            }
            $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {
                $this.State.CloseIds.Add($this.Id)
                if ($this.State.Shutdown -eq 'CloseFailure') {
                    throw [System.InvalidOperationException]::new('Synthetic RDCMan close request failure.')
                }
                return ($this.State.Shutdown -ne 'Dialog')
            }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param([int] $Milliseconds)

                $this.State.WaitIds.Add($this.Id)
                $this.State.WaitTimeouts.Add($Milliseconds)
                $exists = Test-Path -LiteralPath $this.State.TargetPath
                if ($exists -ne ($null -ne $this.State.InitialContent) -or
                    ($exists -and [IO.File]::ReadAllText($this.State.TargetPath) -cne $this.State.InitialContent) -or
                    (Test-Path -LiteralPath $this.State.SettingsPath)) {
                    $this.State.WroteBeforeExit = $true
                }
                if ($Milliseconds -eq 5000) {
                    if ($this.State.Shutdown -eq 'WaitFailure') {
                        throw [System.InvalidOperationException]::new('Synthetic RDCMan clean-exit wait failure.')
                    }
                    if ($this.State.Shutdown -ne 'Graceful') { return $false }
                }
                if ($this.State.Shutdown -eq 'Timeout') { return $false }

                # Model a closing error dialog writing stale data on its eventual exit.
                if (-not $this.HasExited -and $null -ne $this.State.InitialContent) {
                    [IO.File]::WriteAllText($this.State.TargetPath, $this.State.InitialContent)
                }
                $this.HasExited = $true
                return $true
            }
            $process
        })
    }

    function Write-Log {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)] [string] $Message,
            [switch] $Activity,
            [switch] $Failure,
            [switch] $LogOnly,
            [switch] $Success,
            [switch] $Warning
        )

        [void]$state.Logs.Add([pscustomobject]@{
                Message = $Message
                Failure = $Failure.IsPresent
                Warning = $Warning.IsPresent
                LogOnly = $LogOnly.IsPresent
                Verbose = $PSBoundParameters.ContainsKey('Verbose')
            })
    }

    function Get-RDCSettings {
        return [pscustomobject]@{
            DefaultGrouping = $true
            AllVMsGroup     = $false
            RoleGroups      = $false
            OSGroups        = $false
            SubnetGroups    = $false
            SiteCodeGroups  = $false
        }
    }

    function Get-Process {
        [CmdletBinding()]
        param([string] $Name)

        if ($state.Shutdown -eq 'ScanFailure') { throw 'Synthetic process enumeration failure.' }
        if (-not $Name) { [pscustomobject]@{ Id = 999; ProcessName = 'UnrelatedProcess' } }
        if (-not $state.ProcessesVisible) { return }
        $state.Processes | Where-Object { -not $_.HasExited }
        if ($state.Shutdown -eq 'Remaining' -and $state.WaitIds.Count -ge 2) {
            [pscustomobject]@{ Id = 103; ProcessName = 'RDCMan'; Path = $state.ExePath; HasExited = $false }
        }
    }

    function Stop-Process {
        [CmdletBinding()]
        param(
            [int] $Id,
            [switch] $Force,
            [Parameter(ValueFromPipeline = $true)] $InputObject
        )

        process {
            $processId = $Id
            if ($InputObject) { $processId = $InputObject.Id }
            if (-not $Force -or $processId -notin @(101, 102)) { throw 'Unexpected process stop in RDCMan test.' }
            $state.StopIds.Add($processId)
            if ($state.Shutdown -eq 'StopFailure') { throw 'Synthetic RDCMan access denied.' }
            if ($state.Shutdown -eq 'ExitRace') {
                ($state.Processes | Where-Object Id -eq $processId).HasExited = $true
                throw 'Synthetic process exited before Stop-Process.'
            }
        }
    }

    function Start-Process {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)] [string] $FilePath,
            $ArgumentList,
            $WindowStyle,
            $WorkingDirectory,
            [switch] $PassThru
        )

        if ($FilePath -ne $state.ExePath -or @($state.Processes | Where-Object { -not $_.HasExited }).Count -gt 0) {
            throw 'RDCMan restarted from the wrong path or before shutdown completed.'
        }
        $state.Restarted = $true
        return [pscustomobject]@{ Id = 201 }
    }

    function Get-List {
        param(
            [string] $Type,
            [string] $Domain,
            [switch] $SmartUpdate
        )
    }

    function Invoke-VMNetworkBulkWarmup { $state.ProcessesVisible = $true }
    function Install-RDCman { $state.InstallCalled = $true }
    function Get-RDCManExePath { return $state.ExePath }
    function Test-RDCManCertTrustSupported { return $false }
    if (-not $UseRealSettings) {
        function Save-RdcManSettingsFile { return $false }
    }
    function Start-Sleep { param([int] $Seconds) }
    function Set-RdcManMin {}
    function Write-GreenCheck { param([string] $Message, $ForegroundColor) $state.SuccessMessages.Add($Message) }
    function Write-RedX { param([string] $Message) }
    function Out-Host { process {} }

    $previousLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $state.SettingsRoot
        $caughtError = $null
        try {
            New-RDCManFileFromHyperV -rdcmanfile $TargetPath -OverWrite:$OverWrite -WhatIf:$WhatIf -RestartRDCMan:$RestartRDCMan | Out-Null
        }
        catch {
            $caughtError = $_.Exception.Message
        }

        $content = $null
        $result = $null
        if (Test-Path -LiteralPath $TargetPath) {
            $content = [IO.File]::ReadAllText($TargetPath)
            [xml]$result = $content
        }
        if (@($state.Processes | Where-Object { -not $_.HasExited }).Count -gt 0 -and
            ($content -cne $state.InitialContent -or (Test-Path -LiteralPath $state.SettingsPath))) {
            $state.WroteBeforeExit = $true
        }
        return [pscustomobject]@{
            InstallCalled = $state.InstallCalled
            Logs          = @($state.Logs)
            FileName      = "$($result.RDCMan.file.properties.name)"
            GroupCount    = $(if ($result) { $result.SelectNodes('/RDCMan/file/group').Count } else { 0 })
            Content       = $content
            CaughtError   = $caughtError
            CloseIds      = $state.CloseIds.ToArray()
            StopIds       = $state.StopIds.ToArray()
            WaitIds       = $state.WaitIds.ToArray()
            WaitTimeouts  = $state.WaitTimeouts.ToArray()
            WroteBeforeExit = $state.WroteBeforeExit
            Restarted     = $state.Restarted
            SuccessCount  = $state.SuccessMessages.Count
            SettingsExist = Test-Path -LiteralPath $state.SettingsPath
        }
    }
    finally {
        $env:LOCALAPPDATA = $previousLocalAppData
    }
}

$source = Join-Path $RootPath 'common\Common.RdcMan.ps1'
$template = Join-Path $RootPath 'common\template.rdg'
if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $template)) {
    Write-Host 'SETUP FAIL: RDCMan source or template was not found.' -ForegroundColor Red
    exit 2
}

$groupLessRdg = @'
<?xml version="1.0" encoding="utf-8"?>
<RDCMan programVersion="2.92" schemaVersion="3">
  <file>
    <credentialsProfiles />
    <properties>
      <expanded>True</expanded>
      <name>stale</name>
    </properties>
    <remoteDesktop inherit="None">
      <sameSizeAsClientArea>True</sameSizeAsClientArea>
      <fullScreen>False</fullScreen>
      <colorDepth>24</colorDepth>
    </remoteDesktop>
  </file>
  <connected />
  <favorites />
  <recentlyUsed />
</RDCMan>
'@

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "memlabs-rdcman-test-$([guid]::NewGuid().ToString('N'))"
try {
    $normalRoot = Join-Path $tempRoot 'normal'
    $brokenRoot = Join-Path $tempRoot 'broken'
    $null = New-Item -ItemType Directory -Path $normalRoot, $brokenRoot -Force

    Copy-Item -LiteralPath $source -Destination (Join-Path $normalRoot 'Common.RdcMan.ps1')
    Copy-Item -LiteralPath $template -Destination (Join-Path $normalRoot 'template.rdg')
    Copy-Item -LiteralPath (Join-Path $RootPath 'common\RDCMan.settings.template') -Destination $normalRoot
    Set-Content -LiteralPath (Join-Path $normalRoot 'RDCMan.exe') -Value 'Test fixture; never executed.' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $normalRoot 'target.rdg') -Value $groupLessRdg -Encoding UTF8

    Copy-Item -LiteralPath $source -Destination (Join-Path $brokenRoot 'Common.RdcMan.ps1')
    Set-Content -LiteralPath (Join-Path $brokenRoot 'template.rdg') -Value $groupLessRdg -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $brokenRoot 'target.rdg') -Value $groupLessRdg -Encoding UTF8

    $normal = Invoke-RdcManRecoveryCase `
        -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
        -TargetPath (Join-Path $normalRoot 'target.rdg')
    $normalRecoveryLogs = @($normal.Logs | Where-Object { $_.Message -like 'No groups remain*' })

    Assert-True ($normalRecoveryLogs.Count -eq 1) 'group-less RDG takes one recovery path'
    if ($normalRecoveryLogs.Count -eq 1) {
        Assert-True ($normalRecoveryLogs[0].LogOnly -and $normalRecoveryLogs[0].Verbose -and -not $normalRecoveryLogs[0].Failure) 'expected recovery is log-only and verbose'
    }
    else {
        Write-Host "      captured: $(@($normal.Logs.Message) -join ' | ')" -ForegroundColor Red
        Assert-True $false 'expected recovery is log-only and verbose'
    }
    Assert-True (@($normal.Logs | Where-Object Failure).Count -eq 0) 'expected recovery emits no failure'
    Assert-True ($normal.InstallCalled -and $normal.FileName -eq 'memlabs') 'expected recovery reloads the template and continues'
    Assert-True ($null -eq $normal.CaughtError) 'expected recovery does not throw'

    $broken = Invoke-RdcManRecoveryCase `
        -SourcePath (Join-Path $brokenRoot 'Common.RdcMan.ps1') `
        -TargetPath (Join-Path $brokenRoot 'target.rdg') `
        -OverWrite
    $brokenFailureLogs = @($broken.Logs | Where-Object { $_.Failure -and $_.Message -like 'Could not load group section*' })

    Assert-True ($brokenFailureLogs.Count -eq 1) 'group-less template remains a failure'
    Assert-True (@($broken.Logs | Where-Object { $_.Message -like 'No groups remain*' }).Count -eq 0) 'template failure does not retry'
    Assert-True (-not $broken.InstallCalled) 'template failure stops before installation work'

    $templateContent = [IO.File]::ReadAllText($template)
    [xml]$incrementalXml = $templateContent
    $incrementalXml.RDCMan.file.group.properties.name = 'retired.example'
    $shutdownCases = @(
        [pscustomobject]@{ Name = 'overwrite'; Content = $groupLessRdg; OverWrite = $true; Settings = $false }
        [pscustomobject]@{ Name = 'new-file'; Content = $null; OverWrite = $false; Settings = $false }
        [pscustomobject]@{ Name = 'incremental'; Content = $incrementalXml.OuterXml; OverWrite = $false; Settings = $false }
        [pscustomobject]@{ Name = 'settings'; Content = $templateContent; OverWrite = $false; Settings = $true }
    )
    foreach ($case in $shutdownCases) {
        foreach ($shutdown in @('Delayed', 'StopFailure', 'Timeout', 'Remaining', 'ScanFailure')) {
            $target = Join-Path $normalRoot "$($case.Name)-$shutdown.rdg"
            if ($null -ne $case.Content) { [IO.File]::WriteAllText($target, $case.Content) }
            $actual = Invoke-RdcManRecoveryCase -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
                -TargetPath $target -OverWrite:$case.OverWrite -Shutdown $shutdown -UseRealSettings:$case.Settings
            $label = "$($case.Name) / $shutdown"

            Assert-True (-not $actual.WroteBeforeExit) "$label does not modify files before exit"
            if ($shutdown -eq 'Delayed') {
                Assert-True ($null -eq $actual.CaughtError -and $actual.InstallCalled) "$label completes generation"
                Assert-True ($actual.CloseIds.Count -eq 2 -and $actual.StopIds.Count -eq 2 -and $actual.WaitIds.Count -eq 4) "$label attempts clean shutdown before force-killing every blocked RDCMan process"
                Assert-True (@($actual.WaitTimeouts | Where-Object { $_ -eq 5000 }).Count -eq 2 -and
                    @($actual.WaitTimeouts | Where-Object { $_ -eq 10000 }).Count -eq 2) "$label allows five seconds for clean exit and ten seconds after force-kill"
                Assert-True $actual.Restarted "$label restarts the original RDCMan executable"
                Assert-True ($actual.FileName -eq 'memlabs') "$label leaves a valid RDG"
                if ($case.Name -eq 'incremental') {
                    Assert-True ($actual.GroupCount -eq 0) "$label persists new data after stale shutdown writes"
                }
                if ($case.Settings) {
                    Assert-True $actual.SettingsExist "$label writes RDCMan settings after shutdown"
                }
            }
            else {
                Assert-True (-not [string]::IsNullOrWhiteSpace($actual.CaughtError)) "$label surfaces shutdown failure"
                Assert-True ($actual.Content -ceq $case.Content -and -not $actual.SettingsExist) "$label preserves existing files"
                Assert-True (-not $actual.Restarted -and $actual.SuccessCount -eq 0) "$label does not restart or report success"
            }
        }
    }

    foreach ($shutdown in @('Graceful', 'Delayed', 'Dialog', 'CloseFailure', 'WaitFailure', 'ExitRace')) {
        $target = Join-Path $normalRoot "recovery-$shutdown.rdg"
        [IO.File]::WriteAllText($target, $groupLessRdg)
        $actual = Invoke-RdcManRecoveryCase -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
            -TargetPath $target -Shutdown $shutdown
        $expectedWaitCount = 4
        if ($shutdown -in @('Graceful', 'Dialog', 'CloseFailure')) { $expectedWaitCount = 2 }
        Assert-True ($null -eq $actual.CaughtError -and $actual.FileName -eq 'memlabs' -and $actual.Restarted -and
            $actual.CloseIds.Count -eq 2 -and $actual.WaitIds.Count -eq $expectedWaitCount -and
            -not $actual.WroteBeforeExit) "$shutdown recovery waits for shutdown before replacing the broken RDG"
        if ($shutdown -eq 'Graceful') {
            Assert-True ($actual.StopIds.Count -eq 0 -and
                @($actual.WaitTimeouts | Where-Object { $_ -ne 5000 }).Count -eq 0) 'cleanly closing RDCMan is not force-killed'
        }
        else {
            Assert-True ($actual.StopIds.Count -eq 2 -and
                @($actual.Logs | Where-Object { $_.Warning -and $_.Message -like '*force*' }).Count -eq 2) "$shutdown recovery force-kills blocked RDCMan and reports the fallback"
        }
    }

    $target = Join-Path $normalRoot 'late-start.rdg'
    [IO.File]::WriteAllText($target, $groupLessRdg)
    $actual = Invoke-RdcManRecoveryCase -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
        -TargetPath $target -Shutdown Delayed -OverWrite -StartDuringWarmup
    Assert-True ($null -eq $actual.CaughtError -and $actual.Restarted -and $actual.WaitIds.Count -eq 4 -and
        -not $actual.WroteBeforeExit) 'RDCMan opened during warmup is stopped and restarted from its own executable'

    foreach ($overWrite in @($false, $true)) {
        $target = Join-Path $normalRoot "preclosed-$overWrite.rdg"
        [IO.File]::WriteAllText($target, $groupLessRdg)
        $actual = Invoke-RdcManRecoveryCase -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
            -TargetPath $target -OverWrite:$overWrite -RestartRDCMan
        Assert-True ($null -eq $actual.CaughtError -and $actual.Restarted -and $actual.FileName -eq 'memlabs' -and
            $actual.StopIds.Count -eq 0) "Overwrite=$overWrite restarts RDCMan already stopped by startup preparation"
    }

    foreach ($whatIf in @($false, $true)) {
        $target = Join-Path $normalRoot "unchanged-$whatIf.rdg"
        [IO.File]::WriteAllText($target, $templateContent)
        $actual = Invoke-RdcManRecoveryCase -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
            -TargetPath $target -Shutdown Delayed -OverWrite:$whatIf -WhatIf:$whatIf
        Assert-True ($null -eq $actual.CaughtError -and $actual.CloseIds.Count -eq 0 -and $actual.StopIds.Count -eq 0 -and -not $actual.Restarted -and
            $actual.Content -ceq $templateContent) "WhatIf=$whatIf leaves RDCMan and unchanged files alone"
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: RDCMan recovery waits for complete shutdown and preserves real failures.' -ForegroundColor Green
exit 0