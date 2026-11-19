<#
.SYNOPSIS
    Verifies exact console-provider shutdown detection and single-reboot recovery.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'common\Common.Maintenance.ps1')

function Assert-ProviderRecovery {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$healthBlock = Get-VMConsoleProviderHealthScriptBlock
Assert-ProviderRecovery ($healthBlock.ToString() -notmatch 'Restart-Service|Stop-Service|Stop-Process|Restart-Computer|Restart-VM') `
    'The guest health probe can mutate service or VM state.'

function Invoke-ConsoleHealthFixture {
    param([string]$Mode)
    & {
        param($Mode, $HealthBlock)
        $fixture = @{
            Mode = $Mode; LogReads = 0
            Calls = [Collections.Generic.List[object]]::new()
            ShutdownLine = 'CDynamicClass::Initialize() failed for class SMS_ConsoleSetupInfo. Error - 0x80041033~ <10-30-2026 02:00:31.239+600>'
        }
        function Get-ItemProperty {
            param($LiteralPath, $ErrorAction)
            if ($LiteralPath -like '*Identification') { return [pscustomobject]@{ 'Site Code' = 'CS1' } }
            [pscustomobject]@{ 'Installation Directory' = 'C:\fixture\ConfigMgr' }
        }
        function Test-Path {
            param($LiteralPath, $PathType, $ErrorAction)
            return $fixture.Mode -ne 'MissingLog'
        }
        function Get-Content {
            param($LiteralPath, $Tail, $ErrorAction)
            $fixture.LogReads++
            Assert-ProviderRecovery ($Tail -eq 120) 'Provider-log inspection is not bounded.'
            if ($fixture.Mode -eq 'UnreadableLog') { throw [UnauthorizedAccessException]::new('synthetic log access denied') }
            if ($fixture.Mode -eq 'MissingLog') { throw [IO.FileNotFoundException]::new('synthetic missing provider log') }
            'older unrelated provider entry'
            if ($fixture.Mode -eq 'StaleLog' -or ($fixture.LogReads -gt 1 -and $fixture.Mode -eq 'FreshLog')) {
                $fixture.ShutdownLine
            }
            if ($fixture.LogReads -gt 1 -and $fixture.Mode -eq 'WrongClass') {
                $fixture.ShutdownLine.Replace('SMS_ConsoleSetupInfo', 'SMS_OtherClass')
            }
            if ($fixture.LogReads -gt 1 -and $fixture.Mode -eq 'WrongCode') {
                $fixture.ShutdownLine.Replace('0x80041033', '0x80041001')
            }
        }
        function Get-CimInstance {
            param($Namespace, $Query, $OperationTimeoutSec, $ErrorAction)
            $fixture.Calls.Add([pscustomobject]@{
                    Namespace = $Namespace; Query = $Query; Timeout = $OperationTimeoutSec; ErrorAction = "$ErrorAction"
                })
            switch ($fixture.Mode) {
                'Healthy' { return [pscustomobject]@{ FileVersion = ' 5.0.9141.1002 ' } }
                'EmptyVersion' { return [pscustomobject]@{ FileVersion = '' } }
                'DirectHResult' { throw [Runtime.InteropServices.COMException]::new('The server threw an exception.', -2147217357) }
                'InnerHResult' {
                    throw [InvalidOperationException]::new('wrapped failure',
                        [Runtime.InteropServices.COMException]::new('The server threw an exception.', -2147217357))
                }
                'ErrorId' {
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('The server threw an exception.'), 'WBEM_E_SHUTTING_DOWN',
                        [Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
                }
                'SymbolMessage' { throw 'WBEM_E_SHUTTING_DOWN' }
                'OtherError' { throw [UnauthorizedAccessException]::new('access denied') }
                default { throw 'The server threw an exception.' }
            }
        }
        $states = @(& $HealthBlock)
        Assert-ProviderRecovery ($states.Count -eq 1) 'The health probe did not return exactly one state.'
        [pscustomobject]@{ Result = $states[0]; State = $fixture }
    } $Mode $healthBlock
}

foreach ($mode in @('Healthy', 'EmptyVersion', 'DirectHResult', 'InnerHResult', 'ErrorId', 'SymbolMessage',
        'OtherError', 'FreshLog', 'StaleLog', 'WrongClass', 'WrongCode', 'UnreadableLog', 'MissingLog')) {
    $probe = Invoke-ConsoleHealthFixture -Mode $mode
    $expectedShutdown = $mode -in @('DirectHResult', 'InnerHResult', 'ErrorId', 'SymbolMessage', 'FreshLog')
    Assert-ProviderRecovery ($probe.Result.Ready -eq ($mode -eq 'Healthy') -and
        $probe.Result.ShutdownDetected -eq $expectedShutdown) "Incorrect shutdown detection for $mode."
    Assert-ProviderRecovery ($probe.Result.Ready -is [bool] -and $probe.Result.ShutdownDetected -is [bool]) `
        "Health flags lost their Boolean contract for $mode."
    Assert-ProviderRecovery ($probe.State.Calls.Count -eq 1) "The health check did not run the failing query exactly once for $mode."
    $call = $probe.State.Calls[0]
    Assert-ProviderRecovery ($call.Namespace -eq 'root\sms\Site_CS1' -and
        $call.Query -ceq 'SELECT FileVersion FROM SMS_ConsoleSetupInfo WHERE FileName = "ConfigMgr.AC_Extension.i386.cab"' -and
        $call.Timeout -eq 15 -and $call.ErrorAction -eq 'Stop') "The health query diverged from console maintenance for $mode."
    if ($expectedShutdown) {
        Assert-ProviderRecovery (-not [string]::IsNullOrWhiteSpace($probe.Result.Evidence)) "Shutdown detection has no evidence for $mode."
    }
    if ($mode -in @('UnreadableLog', 'MissingLog')) {
        Assert-ProviderRecovery ($probe.Result.Diagnostics.Count -gt 0) "Log collection failure was silent for $mode."
    }
}

function Invoke-ConsoleRecoveryFixture {
    param([string]$Mode)
    & {
        param($Mode)
        $fixture = @{
            Mode = $Mode
            Calls = [Collections.Generic.List[object]]::new()
            Restarts = [Collections.Generic.List[object]]::new()
            Evidence = [Collections.Generic.List[object]]::new()
            Logs = [Collections.Generic.List[string]]::new()
            Sleeps = [Collections.Generic.List[int]]::new()
        }
        function Write-Log {
            param($Message, [switch]$Warning, [switch]$LogOnly, [switch]$Success)
            $fixture.Logs.Add("$Message")
        }
        function Save-VMFixFailureEvidence {
            param($VMName, $VMDomain, $FixName, $VMDomainAccount, $Stage)
            $fixture.Evidence.Add([pscustomobject]@{
                    VMName = $VMName; Domain = $VMDomain; Account = $VMDomainAccount; FixName = $FixName; Stage = $Stage
                })
        }
        function Start-Sleep {
            param([int]$Seconds)
            $fixture.Sleeps.Add($Seconds)
        }
        function Restart-VM2Smart {
            param($Name, $Reason, $GracefulTimeoutSeconds, $ShutdownNoProgressSeconds, $Stopwatch, $Timespan,
                [switch]$AllowTurnOff)
            $fixture.Restarts.Add([pscustomobject]@{
                    Name = $Name; Reason = $Reason; AllowTurnOff = $AllowTurnOff.IsPresent
                    GracefulTimeout = $GracefulTimeoutSeconds; NoProgress = $ShutdownNoProgressSeconds
                    HasDeadline = $Stopwatch -is [Diagnostics.Stopwatch] -and $Timespan -is [TimeSpan]
                })
            Assert-ProviderRecovery ($fixture.Evidence.Count -eq 1) 'Recovery reboot happened before failure evidence was saved.'
            if ($fixture.Mode -eq 'RestartThrows') { throw 'synthetic graceful restart failure' }
            return $fixture.Mode -ne 'RestartRefused'
        }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $VmDomainAccount, $ScriptBlock, $DisplayName, [switch]$AsJob,
                $TimeoutSeconds, $SessionMaxRetries, [switch]$SuppressLog, [switch]$FailOnRemoteError,
                [switch]$RebootIfUnresponsive)
            $fixture.Calls.Add([pscustomobject]@{
                    VMName = $VmName; Domain = $VmDomainName; Account = $VmDomainAccount
                    AsJob = $AsJob.IsPresent; Timeout = $TimeoutSeconds; Retries = $SessionMaxRetries
                    FailOnRemoteError = $FailOnRemoteError.IsPresent; AutomaticTransportReboot = $RebootIfUnresponsive.IsPresent
                })
            $state = [pscustomobject]@{
                Ready = $false; ShutdownDetected = $true; Error = 'The server threw an exception.'
                Evidence = 'SMS_ConsoleSetupInfo failed with 0x80041033'; Diagnostics = @()
            }
            $failed = $false
            if ($fixture.Calls.Count -eq 1) {
                switch ($fixture.Mode) {
                    'Healthy' { $state.Ready = $true; $state.ShutdownDetected = $false }
                    'Unrelated' {
                        $state.ShutdownDetected = $false
                        $state.Error = 'access denied -Token TEST_SECRET_NOT_FOR_LOGS'
                    }
                    'InitialTransportFailure' { $failed = $true }
                    'InvalidInitial' { $state.Ready = 'false' }
                }
            }
            else {
                switch ($fixture.Mode) {
                    'Timeout' { Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 1050 }
                    'InvalidAfterRestart' { $state.Ready = 'true' }
                    'WarmingUp' {
                        if ($fixture.Calls.Count -eq 2) { $failed = $true }
                        else { $state.Ready = $true; $state.ShutdownDetected = $false }
                    }
                    default { $state.Ready = $true; $state.ShutdownDetected = $false }
                }
            }
            [pscustomobject]@{ ScriptBlockFailed = $failed; ScriptBlockOutput = $state; ErrorDetails = 'synthetic transport failure' }
        }
        $timeout = if ($Mode -eq 'Timeout') { 1 } else { 30 }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Repair-VMConsoleProvider -VMName 'LAB-PRI' -VMDomain 'lab.test' -VMDomainAccount 'setupadmin' -ReadyTimeoutSeconds $timeout
        [pscustomobject]@{ Result = $result; State = $fixture; ElapsedSeconds = $watch.Elapsed.TotalSeconds }
    } $Mode
}

foreach ($mode in @('Recovered', 'WarmingUp', 'Healthy', 'Unrelated', 'InitialTransportFailure',
        'InvalidInitial', 'RestartRefused', 'RestartThrows', 'Timeout', 'InvalidAfterRestart')) {
    $probe = Invoke-ConsoleRecoveryFixture -Mode $mode
    $expectedAttempt = $mode -in @('Recovered', 'WarmingUp', 'RestartRefused', 'RestartThrows', 'Timeout', 'InvalidAfterRestart')
    $expectedRecovery = $mode -in @('Recovered', 'WarmingUp')
    Assert-ProviderRecovery ($probe.Result.Attempted -eq $expectedAttempt -and
        $probe.Result.Recovered -eq $expectedRecovery) "Incorrect recovery verdict for $mode."
    Assert-ProviderRecovery ($probe.State.Restarts.Count -eq [int]$expectedAttempt) "Recovery exceeded its one-reboot limit for $mode."
    Assert-ProviderRecovery (@($probe.State.Calls | Where-Object {
                $_.VMName -ne 'LAB-PRI' -or $_.Domain -ne 'lab.test' -or $_.Account -ne 'setupadmin' -or
                -not $_.AsJob -or $_.Timeout -lt 1 -or $_.Timeout -gt 45 -or $_.Retries -ne 1 -or
                -not $_.FailOnRemoteError -or $_.AutomaticTransportReboot
            }).Count -eq 0) "Probe identity or timeout policy changed for $mode."
    Assert-ProviderRecovery (@($probe.State.Evidence | Where-Object {
                $_.VMName -ne 'LAB-PRI' -or $_.Domain -ne 'lab.test' -or $_.Account -ne 'setupadmin' -or
                $_.FixName -ne 'Fix-Upgrade-Console'
            }).Count -eq 0) "Recovery evidence used a different identity or target for $mode."
    Assert-ProviderRecovery (($probe.State.Logs -join "`n") -notmatch 'TEST_SECRET_NOT_FOR_LOGS') "Recovery logging leaked a token for $mode."
    if ($expectedAttempt) {
        $restart = $probe.State.Restarts[0]
        Assert-ProviderRecovery ($restart.Name -eq 'LAB-PRI' -and -not $restart.AllowTurnOff -and
            $restart.GracefulTimeout -eq 180 -and $restart.NoProgress -eq 300 -and $restart.HasDeadline) `
            "Recovery did not use a bounded, graceful-only restart of the affected VM for $mode."
    }
    if ($mode -eq 'WarmingUp') {
        Assert-ProviderRecovery ($probe.State.Calls.Count -eq 3 -and $probe.State.Sleeps.Count -eq 1) `
            'Post-reboot transport warm-up did not retry the actual provider query.'
    }
    if ($mode -eq 'Timeout') {
        Assert-ProviderRecovery ($probe.State.Calls.Count -eq 2 -and $probe.State.Calls[1].Timeout -eq 1 -and
            $probe.ElapsedSeconds -ge 1 -and $probe.ElapsedSeconds -lt 5 -and $probe.State.Evidence.Count -eq 2) `
            'Provider readiness exceeded its deadline, rebooted twice, or omitted final failure evidence.'
    }
    if ($mode -eq 'InvalidAfterRestart') {
        Assert-ProviderRecovery ($probe.State.Calls.Count -eq 2 -and $probe.State.Evidence.Count -eq 2) `
            'An invalid post-reboot health result was accepted or retried indefinitely.'
    }
}

$validationText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Raw
Assert-ProviderRecovery ($validationText.Contains("@('Get-ConsoleSetupInfo', 'Get-ConsolePayloadState', 'Get-ConsoleVersionState')")) `
    'Phase 11 does not carry the shared console query dependency into the guest.'

Write-Host 'PASS -- Exact console-provider shutdown detection, fresh evidence, graceful single-VM recovery, and readiness deadlines.'
