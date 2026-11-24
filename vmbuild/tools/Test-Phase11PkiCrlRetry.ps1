<#
.SYNOPSIS
    Verifies bounded Phase 11 CRL retrieval retries.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-CertutilRevocationCheckWithRetry'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Invoke-CertutilRevocationCheckWithRetry function; found $($definitions.Count)."
}
Invoke-Expression $definitions[0].Extent.Text

$script:SleepCalls = 0
$script:SleepSeconds = 0
$script:CacheResetCalls = 0
function Start-Sleep {
    param([int]$Seconds)
    $script:SleepCalls++
    $script:SleepSeconds += $Seconds
}
$cacheReset = {
    param($Path)
    $script:CacheResetCalls++
    [pscustomobject]@{ ExitCode = 0; Output = @('cache cleared') }
}

$script:VerifyCalls = 0
$recoveringVerifier = {
    param($Path)
    $script:VerifyCalls++
    if ($script:VerifyCalls -lt 3) {
        return [pscustomobject]@{
            ExitCode = 0
            Output   = @('CERT_TRUST_IS_OFFLINE_REVOCATION')
        }
    }
    [pscustomobject]@{
        ExitCode = 0
        Output   = @('Leaf certificate revocation check passed')
    }
}

$recovered = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 4 -RetrySeconds 15 -Verifier $recoveringVerifier -BeforeRetry $cacheReset
if (-not $recovered.Passed -or $recovered.Attempts -ne 3 -or
    $script:VerifyCalls -ne 3 -or $script:SleepCalls -ne 2 -or $script:SleepSeconds -ne 30) {
    throw "Transient CRL retrieval did not recover with bounded waits: passed=$($recovered.Passed) attempts=$($recovered.Attempts) verifyCalls=$script:VerifyCalls sleepCalls=$script:SleepCalls sleepSeconds=$script:SleepSeconds."
}
if ($script:CacheResetCalls -ne 2) {
    throw "Transient CRL retrieval did not clear the negative CRL cache between attempts: resets=$script:CacheResetCalls."
}

$script:VerifyCalls = 0
$script:SleepCalls = 0
$script:SleepSeconds = 0
$script:CacheResetCalls = 0
$failingVerifier = {
    param($Path)
    $script:VerifyCalls++
    [pscustomobject]@{
        ExitCode = 0
        Output   = @("offline attempt $script:VerifyCalls")
    }
}

$failed = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 4 -RetrySeconds 15 -Verifier $failingVerifier -BeforeRetry $cacheReset
if ($failed.Passed -or $failed.Attempts -ne 4 -or $failed.ExitCode -ne 0 -or
    $failed.Output[-1] -ne 'offline attempt 4' -or $script:SleepCalls -ne 3 -or
    $script:SleepSeconds -ne 45) {
    throw "Exhausted CRL retries did not fail closed with final evidence: passed=$($failed.Passed) attempts=$($failed.Attempts) exit=$($failed.ExitCode) output='$($failed.Output -join '; ')' sleepCalls=$script:SleepCalls sleepSeconds=$script:SleepSeconds."
}
if ($script:CacheResetCalls -ne 3) {
    throw "Exhausted CRL retries did not clear the negative CRL cache between attempts: resets=$script:CacheResetCalls."
}

$script:VerifyCalls = 0
$script:SleepCalls = 0
$script:SleepSeconds = 0
$failingCacheReset = {
    param($Path)
    [pscustomobject]@{ ExitCode = 7; Output = @('cache clear failed') }
}
$cacheFailure = Invoke-CertutilRevocationCheckWithRetry -CertificatePath 'test.cer' `
    -Attempts 3 -RetrySeconds 15 -Verifier $failingVerifier -BeforeRetry $failingCacheReset
if ($cacheFailure.Passed -or @($cacheFailure.RetryDiagnostics).Count -ne 2 -or
    @($cacheFailure.RetryDiagnostics | Where-Object { $_ -match 'exit 7.*cache clear failed' }).Count -ne 2) {
    throw "Native CRL cache-clear failures were not preserved: $($cacheFailure.RetryDiagnostics -join '; ')"
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch 'Invoke-CertutilRevocationCheckWithRetry -CertificatePath \$tmpCer') {
    throw 'Phase 11 certificate validation does not use the bounded CRL retry helper.'
}
if ($sourceText -notmatch 'never reported a passing revocation check after \$\(\$verifyResult\.Attempts\) attempts') {
    throw 'Exhausted CRL diagnostics do not report the measured attempt count.'
}
if ($sourceText -notmatch '(?s)finally \{\s*Remove-Item \$tmpCer') {
    throw 'Phase 11 CRL validation does not clean up the exported certificate in a finally block.'
}
if ($sourceText -notmatch 'certutil\.exe -urlcache CRL delete') {
    throw 'Phase 11 CRL retries do not clear CryptNet negative CRL cache entries.'
}
if ($sourceText -notmatch '\[int\]\$cacheReset\.ExitCode -ne 0') {
    throw 'Phase 11 CRL retries do not inspect the native cache-clear exit code.'
}

function Import-PkiFixtureFunction {
    param([string]$Name)
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name." }
    [scriptblock]::Create($definition[0].Extent.Text)
}

& {
    . (Import-PkiFixtureFunction 'Get-Phase11InterruptionEvents')
    $fixture = @{ Events = @(); Denied = $false }
    function Get-WinEvent {
        param($FilterHashtable, $MaxEvents, $ErrorAction)
        if ($MaxEvents -ne 201) { throw 'Lifecycle event capture is not bounded.' }
        if ($fixture.Denied) { throw 'fixture event access denied' }
        $fixture.Events
    }
    function New-LifecycleEvent {
        param([string]$Name = 'CAS1')
        $item = [pscustomobject]@{
            Id = 1074; RecordId = 123; ProviderName = 'fixture'; Level = 4
            TimeCreated = [datetime]::Now; UserId = [pscustomobject]@{ Value = 'S-1-5-18' }
            Xml = "<Event><EventData><Data Name='VmName'>$Name</Data><Data Name='param1'>shutdown.exe</Data><Data Name='param6'>private comment</Data><Data Name='CommandLine'>private command</Data><Data Name='ScriptBlockText'>private script</Data></EventData></Event>"
        }
        $item | Add-Member ScriptMethod ToXml { $this.Xml }
        $item
    }
    $window = @{ StartUtc = [datetime]::UtcNow.AddMinutes(-20); EndUtc = [datetime]::UtcNow }
    $fixture.Events = @((New-LifecycleEvent), (New-LifecycleEvent 'CAS10'), (New-LifecycleEvent 'CAS1.other.test'), (New-LifecycleEvent 'CAS1 (clone)'), (New-LifecycleEvent 'OTHER-VM'))
    $hostEvents = Get-Phase11InterruptionEvents -Channel 'host' -TargetIdentities @('CAS1') @window
    if (-not $hostEvents.Measured -or $hostEvents.Events.Count -ne 1 -or
        ($hostEvents | ConvertTo-Json -Depth 8) -match 'private command|private script|private comment|OTHER-VM') {
        throw 'Lifecycle capture crossed the VM boundary or retained sensitive event fields.'
    }
    $targetGuid = [guid]::NewGuid()
    $guidEvent = New-LifecycleEvent 'renamed VM'
    $guidEvent.Xml = "<Event><EventData><Data Name='VmId'>$targetGuid</Data></EventData></Event>"
    $fixture.Events = @($guidEvent, (New-LifecycleEvent 'OTHER-VM'))
    $byId = Get-Phase11InterruptionEvents -Channel 'host' -TargetIdentities @("$targetGuid") @window
    if ($byId.Events.Count -ne 1 -or $byId.Events[0].Data.VmId -ne "$targetGuid") { throw 'Exact VM-ID lifecycle evidence was not retained.' }
    $fixture.Events = @((New-LifecycleEvent))
    $psEvents = Get-Phase11InterruptionEvents -Channel 'Windows PowerShell' @window
    if ($psEvents.Events[0].Data.Count -ne 0) { throw 'PowerShell event payload/script text was retained.' }
    $userDataEvent = New-LifecycleEvent
    $userDataEvent.Xml = '<Event><UserData><Lifecycle><VmName>CAS1</VmName><Operation>Stop</Operation><CommandLine>private command</CommandLine></Lifecycle></UserData></Event>'
    $fixture.Events = @($userDataEvent)
    $userData = Get-Phase11InterruptionEvents -Channel 'host' -TargetIdentities @('CAS1') @window
    if ($userData.Events[0].Data.Operation -ne 'Stop' -or
        ($userData | ConvertTo-Json -Depth 8) -match 'private command') { throw 'Hyper-V UserData lifecycle fields were lost or unfiltered.' }
    $fixture.Events = @((New-LifecycleEvent))
    $systemEvents = Get-Phase11InterruptionEvents -Channel 'System' @window
    if ($systemEvents.Events[0].Data.param1 -ne 'shutdown.exe' -or
        $systemEvents.Events[0].Data.Contains('param6')) { throw 'Shutdown initiator metadata was lost or its free-text comment was retained.' }
    $fixture.Events = @(1..50 | ForEach-Object { New-LifecycleEvent })
    $exact = Get-Phase11InterruptionEvents -Channel 'System' @window
    if ($exact.Events.Count -ne 50 -or $exact.Truncated) { throw 'Exactly 50 events were incorrectly reported as truncated.' }
    $fixture.Events += New-LifecycleEvent
    $bounded = Get-Phase11InterruptionEvents -Channel 'System' @window
    if ($bounded.Events.Count -ne 50 -or -not $bounded.Truncated) { throw 'The event retention limit was exceeded or silently truncated.' }
    $fixture.Denied = $true
    $denied = Get-Phase11InterruptionEvents -Channel 'System' @window
    if ($denied.Measured -or ($denied.Errors -join ' ') -notmatch 'access denied') { throw 'Unavailable events became a successful empty measurement.' }
}

& {
    . (Import-PkiFixtureFunction 'Save-Phase11VmInterruptionDiagnostics')
    $fixture = @{ State = 'Stopping'; VmReads = 0; GuestCalls = 0; ChangeState = $false; GuestFails = $false; Saved = $null; Redactions = 0 }
    $vmId = [guid]::NewGuid()
    function Get-VM {
        param($Name, $ErrorAction)
        $fixture.VmReads++
        $state = $fixture.State
        if ($fixture.ChangeState -and $fixture.VmReads -gt 1) { $state = 'Stopping' }
        [pscustomobject]@{ Name = 'CAS1'; Id = $vmId; State = $state; Status = 'fixture'; Heartbeat = 'OkApplicationsUnknown'; Uptime = [timespan]::FromMinutes(3) }
    }
    function Get-Phase11InterruptionEvents {
        param($Channel, $StartUtc, $EndUtc, $Id, $TargetIdentities)
        [pscustomobject]@{ Channel = $Channel; Measured = $true; Truncated = $false; Events = @(); Errors = @() }
    }
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($OperationTimeoutSec -ne 10) { throw 'Guest WMI metadata is unbounded.' }
        if ($ClassName -eq 'Win32_Process') {
            1..21 | ForEach-Object { [pscustomobject]@{ Name = 'wsmprovhost.exe'; ProcessId = $_; ParentProcessId = 1; CreationDate = [datetime]::Now; CommandLine = 'must not be saved' } }
        } else { [pscustomobject]@{ Name = 'fixture'; State = 'Running'; LastBootUpTime = [datetime]::Now.AddMinutes(-1) } }
    }
    function Test-Path { param($LiteralPath, $ErrorAction) $false }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries, [switch]$SkipDomainFallback, [switch]$RebootIfUnresponsive)
        $fixture.GuestCalls++
        if (-not $AsJob -or $TimeoutSeconds -ne 90 -or $SessionMaxRetries -ne 1 -or
            -not $SkipDomainFallback -or $RebootIfUnresponsive) { throw 'Guest evidence request can retry indefinitely or reboot the VM.' }
        if ($fixture.GuestFails) { return [pscustomobject]@{ ScriptBlockFailed = $true; ErrorDetails = 'fixture socket closed' } }
        $previousComputer = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'CAS1'
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = (& $ScriptBlock @ArgumentList) }
        }
        finally { $env:COMPUTERNAME = $previousComputer }
    }
    function ConvertTo-ConfigDiagnosticJson { param($Config, $Depth) $fixture.Redactions++; $Config | ConvertTo-Json -Depth $Depth }
    function Save-Phase11GuestLogs {
        param($VMName, $DomainName, $RoleLabel, $CollectedContent)
        $fixture.Saved = $CollectedContent['VmInterruption.json'] | ConvertFrom-Json
        @('fixture.json')
    }
    function Write-Log { param($Message, [switch]$Warning) throw "Unexpected diagnostic save failure: $Message" }
    $arguments = @{ VMName = 'CAS1'; Domain = 'fixture.test'; ProbeStartedUtc = [datetime]::UtcNow }
    $null = Save-Phase11VmInterruptionDiagnostics @arguments
    if ($fixture.GuestCalls -ne 0 -or $fixture.Saved.HostEvents.Count -ne 2 -or $fixture.Saved.Guest.Attempted) { throw 'A stopping VM was connected to, or its host evidence was lost.' }
    $fixture.State = 'Running'; $fixture.VmReads = 0; $fixture.ChangeState = $true
    $null = Save-Phase11VmInterruptionDiagnostics @arguments
    if ($fixture.GuestCalls -ne 0 -or $fixture.Saved.HostVm[-1].State -ne 'Stopping') { throw 'A VM that began stopping during capture still received a guest request.' }
    $fixture.ChangeState = $false; $fixture.GuestFails = $true
    $null = Save-Phase11VmInterruptionDiagnostics @arguments
    if ($fixture.GuestCalls -ne 1 -or $fixture.Saved.Guest.ResultReceived -or
        $fixture.Saved.HostEvents.Count -ne 2 -or $fixture.Saved.Guest.Error -notmatch 'socket closed') { throw 'A second broken channel discarded independent host evidence or hid its failure.' }
    $fixture.GuestFails = $false
    $null = Save-Phase11VmInterruptionDiagnostics @arguments
    if (-not $fixture.Saved.Guest.ResultReceived -or $fixture.Saved.Guest.Evidence.Processes.Count -ne 20 -or
        -not $fixture.Saved.Guest.Evidence.ProcessesTruncated -or
        ($fixture.Saved | ConvertTo-Json -Depth 12) -match 'must not be saved' -or $fixture.Redactions -ne 4) {
        throw 'Guest metadata was not measured, bounded, or passed through diagnostic redaction.'
    }
}

& {
    . (Import-PkiFixtureFunction 'Test-PKICertificatesOnVM')
    $fixture = @{ Calls = 0; Captures = 0; Returned = $null; Result = $null; CaptureThrows = $false; Warnings = 0 }
    function Write-Log { param($Message, [switch]$LogOnly, [switch]$Warning) if ($Warning) { $fixture.Warnings++ } }
    function Add-Phase11Output { param($Message) }
    function Invoke-VmCommand { param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds) $fixture.Calls++; $fixture.Result }
    function Save-Phase11VmInterruptionDiagnostics {
        param($VMName, $Domain, $ProbeStartedUtc)
        $fixture.Captures++
        if ($fixture.CaptureThrows) { throw 'fixture diagnostic failure' }
    }
    function Format-TestResult { param($VMName, $RoleLabel, $Result) $fixture.Returned = $Result; $false }
    $arguments = @{ VMName = 'CAS1'; Domain = 'fixture.test'; CurrentItem = [pscustomobject]@{ role = 'CAS' }; DeployConfig = [pscustomobject]@{} }
    $fixture.Result = [pscustomobject]@{ ScriptBlockFailed = $true; ChannelBroken = $true; TimedOut = $false; ErrorDetails = 'Hyper-V socket target process has ended'; ScriptBlockOutput = $null }
    $null = Test-PKICertificatesOnVM @arguments
    if ($fixture.Calls -ne 1 -or $fixture.Captures -ne 1 -or -not [object]::ReferenceEquals($fixture.Returned, $fixture.Result)) { throw 'PKI interruption capture retried validation or replaced the original failure.' }
    $fixture.CaptureThrows = $true
    $null = Test-PKICertificatesOnVM @arguments
    if ($fixture.Warnings -ne 1 -or -not [object]::ReferenceEquals($fixture.Returned, $fixture.Result)) { throw 'A diagnostic exception hid the original validation failure or was silent.' }
    $fixture.CaptureThrows = $false
    $fixture.Calls = 0; $fixture.Captures = 0
    $fixture.Result = [pscustomobject]@{ ScriptBlockFailed = $false; ChannelBroken = $false; TimedOut = $false; ErrorDetails = $null; ScriptBlockOutput = @{ Passed = $false; Details = @('certificate expired') } }
    $null = Test-PKICertificatesOnVM @arguments
    if ($fixture.Calls -ne 1 -or $fixture.Captures -ne 0) { throw 'An ordinary certificate failure was misclassified as a VM interruption.' }
}

Write-Host 'PASS -- bounded CRL checks and non-rebooting, target-scoped PKI interruption evidence preserve the original validation result.'
