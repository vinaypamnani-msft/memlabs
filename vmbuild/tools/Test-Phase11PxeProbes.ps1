<#
.SYNOPSIS
    Exercises protected DP transport, scoped TFTP replies and paired failure captures without guest changes.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production blocks and mocked socket methods consume fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$path parse errors: $($errors -join '; ')" }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestFunction {
    param([string]$Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name definition."
    return $definitions[0]
}

$systemDefinition = Get-TestFunction 'Invoke-Phase11LocalSystemProbe'
. ([scriptblock]::Create($systemDefinition.Extent.Text))
foreach ($name in @('Get-Phase11TftpNetworkState', 'Invoke-Phase11TftpTraceCommand',
        'Invoke-Phase11TftpCapture', 'Save-Phase11TftpFailureDiagnostics', 'Invoke-TftpReadProbe',
        'Invoke-TftpReadProbeWithRetry')) {
    . ([scriptblock]::Create((Get-TestFunction $name).Extent.Text))
}

& {
    $state = [pscustomobject]@{
        Mode = 'Success'; Request = $null; WorkDir = ''; TaskName = ''
        Stopped = 0; Unregistered = 0; Removed = [System.Collections.Generic.List[string]]::new()
        Command = ''
    }
    function New-Item {
        param($ItemType, $Path, $ErrorAction)
        $state.WorkDir = $Path
        Assert-True ($ItemType -eq 'Directory' -and $Path -like '*\Temp\MemLabs-Phase11Pxe-*') 'The probe does not own an isolated temporary directory.'
    }
    function Set-Acl {
        param($LiteralPath, $AclObject, $ErrorAction)
        $rules = @($AclObject.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $sids = ($rules.IdentityReference.Value | Sort-Object) -join ','
        Assert-True ($LiteralPath -eq $state.WorkDir -and $AclObject.AreAccessRulesProtected -and
            $rules.Count -eq 2 -and $sids -eq 'S-1-5-18,S-1-5-32-544') 'SYSTEM request files are not restricted to SYSTEM and Administrators.'
    }
    function Export-Clixml {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline = $true)]$InputObject, $LiteralPath, $Depth)
        process { $state.Request = $InputObject }
    }
    function Import-Clixml {
        param($LiteralPath, $ErrorAction)
        $probeId = $state.Request.ProbeId
        $sid = 'S-1-5-18'
        $succeeded = $true
        if ($state.Mode -eq 'WrongProbe') { $probeId = 'stale-probe' }
        if ($state.Mode -eq 'WrongIdentity') { $sid = 'S-1-5-19' }
        if ($state.Mode -eq 'BadBoolean') { $succeeded = 'true' }
        if ($state.Mode -eq 'WorkerFailure') { $succeeded = $false }
        [pscustomobject]@{
            ProbeId = $probeId; IdentitySid = $sid; Succeeded = $succeeded
            Output = @{ Passed = $true; Details = [System.Collections.ArrayList]::new() }
            Error = 'synthetic SYSTEM payload access denied'
        }
    }
    function New-ScheduledTaskAction {
        param($Execute, $Argument, $ErrorAction)
        Assert-True ($Execute -like '*\WindowsPowerShell\v1.0\powershell.exe' -and
            $Argument -match '-NonInteractive.*-EncodedCommand (\S+)$') 'The SYSTEM probe is not a noninteractive Windows PowerShell task.'
        $state.Command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        $parseTokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($state.Command, [ref]$parseTokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0 -and $state.Command.Contains('response.pending.clixml')) 'The shipped worker command is malformed or publishes a partial response.'
        [pscustomobject]@{ Execute = $Execute }
    }
    function New-ScheduledTaskPrincipal {
        param($UserId, $LogonType, $RunLevel, $ErrorAction)
        Assert-True ($UserId -eq 'S-1-5-18' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest') 'The task is not configured for SYSTEM.'
        [pscustomobject]@{ UserId = $UserId }
    }
    function New-ScheduledTaskSettingsSet {
        param($ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ErrorAction)
        Assert-True ($ExecutionTimeLimit.TotalSeconds -eq 1) 'The scheduler has no matching execution deadline.'
        [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit }
    }
    function Register-ScheduledTask {
        param($TaskName, $Action, $Principal, $Settings, $ErrorAction)
        $state.TaskName = $TaskName
        if ($state.Mode -eq 'RegisterFailure') { throw 'synthetic task registration failure' }
    }
    function Start-ScheduledTask {
        param($TaskName, $ErrorAction)
        if ($state.Mode -eq 'StartFailure') { throw 'synthetic task start failure' }
    }
    function Get-ScheduledTask {
        param($TaskName, $ErrorAction)
        $status = if ($state.Mode -eq 'Timeout' -and $state.Stopped -eq 0) { 'Running' } else { 'Ready' }
        [pscustomobject]@{ State = $status }
    }
    function Get-ScheduledTaskInfo {
        param($TaskName, $ErrorAction)
        $code = if ($state.Mode -eq 'TaskFailure') { 1 } else { 267009 }
        [pscustomobject]@{ LastRunTime = Get-Date; LastTaskResult = $code }
    }
    function Stop-ScheduledTask { param($TaskName, $ErrorAction) $state.Stopped++ }
    function Unregister-ScheduledTask {
        param($TaskName, [switch]$Confirm, $ErrorAction)
        if ($state.Mode -eq 'CleanupFailure') { throw 'synthetic task cleanup failure' }
        $state.Unregistered++
    }
    function Test-Path {
        param($LiteralPath, $ErrorAction)
        if ($LiteralPath -like '*\response.clixml') { return $state.Mode -notin @('Timeout', 'TaskFailure') }
        return $LiteralPath -notlike '*\response.pending.clixml'
    }
    function Remove-Item {
        param($LiteralPath, $ErrorAction)
        $state.Removed.Add($LiteralPath)
    }
    foreach ($mode in @('Success', 'WorkerFailure', 'WrongProbe', 'WrongIdentity', 'BadBoolean',
            'TaskFailure', 'Timeout', 'RegisterFailure', 'StartFailure', 'CleanupFailure')) {
        $state.Mode = $mode
        $state.Stopped = 0
        $state.Unregistered = 0
        $state.Removed.Clear()
        $caught = ''
        $result = $null
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try { $result = Invoke-Phase11LocalSystemProbe -ScriptBlock { param($flag) $flag } -ArgumentList @('True') -TimeoutSeconds 1 }
        catch { $caught = $_.Exception.Message }
        if ($mode -eq 'Success') {
            Assert-True ($result.Passed -and -not $caught -and $state.Request.ArgumentList[0] -eq 'True') 'The SYSTEM transport changed the result or dropped its argument.'
        }
        else { Assert-True ([bool]$caught) "$mode returned a success-shaped result." }
        if ($mode -eq 'WorkerFailure') { Assert-True ($caught -match 'synthetic SYSTEM payload access denied') 'The original worker failure was lost.' }
        if ($mode -eq 'Timeout') {
            Assert-True ($caught -match 'timed out after 1 seconds' -and $timer.Elapsed.TotalSeconds -ge 1 -and
                $timer.Elapsed.TotalSeconds -lt 4 -and $state.Stopped -eq 1) 'The probe timeout is not bounded or its worker was not stopped.'
        }
        if ($mode -eq 'CleanupFailure') {
            Assert-True ($caught -match 'cleanup failed' -and $state.Removed.Count -eq 0) 'A cleanup failure was hidden or active worker files were deleted.'
        }
        else {
            Assert-True ($state.Removed.Contains($state.WorkDir) -and
                $state.Unregistered -eq [int]($mode -ne 'RegisterFailure')) "$mode left owned task/request resources behind."
        }
    }

    $state.Mode = 'Success'
    $localAssignments = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$localDpScript'
            }, $true))
    $wrapperAssignments = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$localDpProbe' -and $node.Extent.Text.Contains('Invoke-Phase11LocalSystemProbe')
            }, $true))
    Assert-True ($localAssignments.Count -eq 1 -and $wrapperAssignments.Count -eq 1) 'The required DP-local physical check is not wired through SYSTEM.'
    $localDpScript = & ([scriptblock]::Create("$($localAssignments[0].Extent.Text)`n`$localDpScript"))
    $localDpProbe = & ([scriptblock]::Create("$($wrapperAssignments[0].Extent.Text)`n`$localDpProbe"))
    function New-ScheduledTaskSettingsSet {
        param($ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ErrorAction)
        Assert-True ($ExecutionTimeLimit.TotalSeconds -eq 270) 'DP validation does not retain its bounded SYSTEM deadline.'
        [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit }
    }
    $outputs = @(& $localDpProbe 'True')
    Assert-True ($outputs.Count -eq 1 -and $outputs[0].Passed -and
        ($outputs[0].Details -join ' ') -match 'checked as SYSTEM' -and
        $state.Request.ScriptText.Trim() -eq $localDpScript.ToString().Trim()) "The shipped DP wrapper changes the physical check or emits extra objects after CLIXML collection deserialization (outputs=$($outputs.Count), passed=$($outputs[0].Passed), details=$($outputs[0].Details -join '; '))."
}

$workerAssignments = @($systemDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$worker'
        }, $true))
Assert-True ($workerAssignments.Count -eq 1) 'Expected one shipped SYSTEM worker.'
$worker = & ([scriptblock]::Create("$($workerAssignments[0].Extent.Text)`n`$worker"))
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-PxeProbeTest-$([guid]::NewGuid().ToString('N'))"
$inputPath = Join-Path $fixtureDir 'request.clixml'
$outputPath = Join-Path $fixtureDir 'response.clixml'
$pendingPath = Join-Path $fixtureDir 'response.pending.clixml'
$job = $null
try {
    $null = New-Item -ItemType Directory -Path $fixtureDir
    $fixtureProbe = {
        param($first, $second)
        @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new(); Arguments = "$first,$second" }
    }
    $request = [pscustomobject]@{
        ProbeId = 'worker-fixture'
        ScriptText = $fixtureProbe.ToString()
        ArgumentList = @('one', 'two')
    }
    $request | Export-Clixml -LiteralPath $inputPath -Depth 10
    & $worker $inputPath $outputPath $pendingPath
    $response = Import-Clixml -LiteralPath $outputPath
    Assert-True ($response.Succeeded -is [bool] -and $response.Succeeded -and $response.Output -is [hashtable] -and
        $response.Output.Arguments -eq 'one,two' -and $response.Output.Details -is [System.Collections.IList] -and
        -not (Test-Path -LiteralPath $pendingPath)) 'The executed worker does not preserve the real validation/collector output shape or publish atomically.'
    Remove-Item -LiteralPath $outputPath
    $request.ScriptText = "throw 'synthetic protected payload denial'"
    $request | Export-Clixml -LiteralPath $inputPath -Depth 10
    $job = Start-Job -ScriptBlock $worker -ArgumentList $inputPath, $outputPath, $pendingPath
    Assert-True ([bool](Wait-Job -Job $job -Timeout 20)) 'The failure worker did not terminate.'
    $response = Import-Clixml -LiteralPath $outputPath
    Assert-True (-not $response.Succeeded -and $response.Error -eq 'synthetic protected payload denial' -and
        $null -eq $response.Output) 'A real worker exception was lost or converted to successful output.'
}
finally {
    if ($job) {
        if ($job.State -eq 'Running') { Stop-Job -Job $job }
        Remove-Job -Job $job
    }
    foreach ($file in @($inputPath, $pendingPath, $outputPath, $fixtureDir)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
}

& {
    $state = [pscustomobject]@{
        Mode = 'Served'; RuleName = ''; Created = 0; Removed = 0; Closed = 0; NetworkCalls = 0
        Requests = [System.Collections.Generic.List[object]]::new()
        RuleReads = 0; Sleeps = [System.Collections.Generic.List[int]]::new()
    }
    $socket = [pscustomobject]@{
        Client = [pscustomobject]@{ ReceiveTimeout = 0; LocalEndPoint = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 53000) }
    }
    $socket | Add-Member -MemberType ScriptMethod -Name Send -Value {
        param($Bytes, $Length, $Endpoint)
        $state.Requests.Add([pscustomobject]@{ Bytes = $Bytes; Endpoint = $Endpoint })
        if ($state.Mode -eq 'SendFailure') { throw [Net.Sockets.SocketException]::new(10065) }
        if ($Bytes[1] -eq 5 -and $state.Mode -eq 'AbortFailure') { throw [IO.IOException]::new('synthetic abort failure') }
        return $Length
    }
    $socket | Add-Member -MemberType ScriptMethod -Name Receive -Value {
        param([ref]$Endpoint)
        if ($state.Mode -in @('Timeout', 'NetworkFailure', 'RuleLookupFailure', 'InactiveReplyRule')) { throw [Net.Sockets.SocketException]::new(10060) }
        $address = if ($state.Mode -eq 'WrongSender') { '127.0.0.2' } else { '127.0.0.1' }
        $Endpoint.Value = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($address), 1069)
        $bytes = [byte[]]@(0, 3, 0, 1, 1, 2, 3)
        if ($state.Mode -eq 'Missing') { $bytes = [byte[]]@(0, 5, 0, 1, 0) }
        if ($state.Mode -eq 'Denied') { $bytes = [byte[]]@(0, 5, 0, 2, 0) }
        if ($state.Mode -eq 'Truncated') { $bytes = [byte[]]@(0, 3) }
        if ($state.Mode -eq 'WrongBlock') { $bytes = [byte[]]@(0, 3, 0, 2, 1) }
        if ($state.Mode -eq 'EmptyData') { $bytes = [byte[]]@(0, 3, 0, 1) }
        return ,$bytes
    }
    $socket | Add-Member -MemberType ScriptMethod -Name Close -Value {
        $state.Closed++
        if ($state.Mode -eq 'CloseFailure') { throw [IO.IOException]::new('synthetic close failure') }
    }
    function New-Object {
        param($TypeName, $ArgumentList)
        switch ($TypeName) {
            'System.Net.Sockets.UdpClient' {
                Assert-True ($ArgumentList -eq 0) 'The socket was not bound before the inbound rule was created.'
                return $socket
            }
            'System.Collections.Generic.List[byte]' { return ,([System.Collections.Generic.List[byte]]::new()) }
            'System.Net.IPEndPoint' { return [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0) }
            default { throw "Unexpected fixture construction: $TypeName" }
        }
    }
    function New-NetFirewallRule {
        param($Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort, $RemoteAddress, $Program, [Alias('Profile')]$FirewallProfile, $PolicyStore, $ErrorAction)
        Assert-True ($Direction -eq 'Inbound' -and $Action -eq 'Allow' -and $Protocol -eq 'UDP' -and
            $LocalPort -eq 53000 -and $RemoteAddress -eq '127.0.0.1' -and $Program -and $FirewallProfile -eq 'Any' -and
            $PolicyStore -eq 'PersistentStore' -and $state.Requests.Count -eq 0) 'The TFTP allowance is broad, targets UDP/69 instead of the client socket, or is created too late.'
        if ($state.Mode -eq 'RuleFailure') { throw 'synthetic firewall setup failure' }
        $state.RuleName = $Name
        $state.Created++
        [pscustomobject]@{ Name = $Name }
    }
    function Remove-NetFirewallRule {
        param($Name, $PolicyStore, $ErrorAction)
        Assert-True ($Name -eq $state.RuleName -and $PolicyStore -eq 'PersistentStore') 'Cleanup targets unrelated firewall rules.'
        $state.Removed++
        if ($state.Mode -eq 'RemoveFailure') { throw 'synthetic firewall cleanup failure' }
    }
    function Get-NetFirewallRule {
        param($Name, $PolicyStore, [switch]$TracePolicyStore, $ErrorAction)
        Assert-True ($state.Requests.Count -eq 0 -and $Name -eq $state.RuleName -and
            $PolicyStore -eq 'ActiveStore' -and $TracePolicyStore) 'Reply-rule enforcement was not observed before the first RRQ.'
        if ($state.Mode -eq 'RuleLookupFailure') { throw 'synthetic ActiveStore lookup failure' }
        $enforcement = 'Full'
        $state.RuleReads++
        if ($state.Mode -eq 'InactiveReplyRule') { $enforcement = 'LocalFirewallRulesDisallowed' }
        if ($state.Mode -eq 'DelayedReplyRule' -and $state.RuleReads -eq 1) { $enforcement = 'PolicyDisabled' }
        [pscustomobject]@{ Name = $Name; Enabled = 'True'; EnforcementStatus = $enforcement }
    }
    function Start-Sleep {
        param($Milliseconds)
        $state.Sleeps.Add([int]$Milliseconds)
    }
    function Get-Phase11TftpNetworkState {
        param($PeerAddress, $LocalPort, $ProbeRuleName, $Context, $SinceUtc)
        $state.NetworkCalls++
        Assert-True ($state.Removed -eq 0 -and $state.Closed -eq 0 -and
            $LocalPort -eq 53000 -and ($state.Created -eq 0 -or $ProbeRuleName -eq $state.RuleName) -and
            $Context -eq 'FailureBeforeProbeCleanup') 'Original failure evidence was collected after the socket/rule was removed.'
        if ($state.Mode -eq 'NetworkFailure') { throw 'synthetic network evidence failure' }
        @{ Route = @([pscustomobject]@{ IPAddress = '127.0.0.1' }); ActiveProbeRule = $ProbeRuleName }
    }
    foreach ($mode in @('Served', 'Missing', 'Denied', 'Truncated', 'WrongBlock', 'EmptyData', 'WrongSender',
            'Timeout', 'NetworkFailure', 'RuleLookupFailure', 'InactiveReplyRule', 'DelayedReplyRule', 'RuleFailure',
            'SendFailure', 'AbortFailure', 'CloseFailure', 'RemoveFailure')) {
        $state.Mode = $mode
        $state.Created = 0
        $state.Removed = 0
        $state.Closed = 0
        $state.RuleReads = 0
        $state.Sleeps.Clear()
        $state.Requests.Clear()
        $probe = Invoke-TftpReadProbe -Server '127.0.0.1' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' `
            -RuleActivationTimeoutMs $(if ($mode -eq 'DelayedReplyRule') { 500 } else { 0 }) `
            -RuleSettleMs $(if ($mode -eq 'DelayedReplyRule') { 10 } else { 0 })
        $expected = switch ($mode) {
            'Served' { 'Served' }
            'DelayedReplyRule' { 'Served' }
            'Missing' { 'FileNotFound' }
            'Timeout' { 'NoResponse' }
            'NetworkFailure' { 'NoResponse' }
            'RuleLookupFailure' { 'Error' }
            'InactiveReplyRule' { 'Error' }
            default { 'Error' }
        }
        Assert-True ($probe.Result -eq $expected -and $probe.Detail) "$mode produced an incorrect or unexplained TFTP result: $($probe.Result) $($probe.Detail)"
        Assert-True ($state.Closed -eq 1 -and $state.Removed -eq $state.Created) "$mode did not close the socket and clean up its owned firewall rule."
        if ($mode -eq 'Served') {
            Assert-True ($probe.Bytes -eq 3 -and $probe.Detail -match '1069.*53000' -and
                $state.Requests.Count -eq 2 -and $state.Requests[0].Endpoint.Port -eq 69 -and
                $state.Requests[1].Endpoint.Port -eq 1069 -and $state.Requests[1].Bytes[1] -eq 5) 'The probe did not accept DATA from the transfer port or abort that exact transfer.'
        }
        if ($mode -eq 'RuleFailure') { Assert-True ($state.Requests.Count -eq 0 -and $probe.Detail -match 'firewall setup failure') 'An unconfigured reply path was reported as a dead responder.' }
        if ($mode -eq 'RemoveFailure') { Assert-True ($probe.Detail -match 'firewall cleanup failure') 'A residual firewall rule was hidden behind Served.' }
        if ($mode -eq 'Timeout') {
            Assert-True ($probe.RequestSent -and $probe.RequestBytes -gt 4 -and $probe.NativeErrorCode -eq 10060 -and
                $probe.SocketErrorCode -eq 'TimedOut' -and $probe.ServerAddress -eq '127.0.0.1' -and
                $probe.LocalPort -eq 53000 -and $probe.RouteSourceAddress -eq '127.0.0.1' -and
                $probe.NetworkStateJson -and $probe.StartedAtUtc -and $probe.CompletedAtUtc) 'The timeout lost its original socket, UTC window, native error or before-cleanup evidence.'
        }
        if ($mode -eq 'SendFailure') { Assert-True (-not $probe.RequestSent -and $probe.NativeErrorCode -eq 10065) 'A failed send claims a transmitted request or loses its native error.' }
        if ($mode -eq 'NetworkFailure') { Assert-True ($probe.Detail -match 'network evidence failure' -and $state.Removed -eq 1) 'A diagnostic failure hid the original timeout or prevented firewall cleanup.' }
        if ($mode -eq 'RuleLookupFailure') {
            $before = $probe.RuleBeforeSendJson | ConvertFrom-Json
            Assert-True (-not $before.ReadSucceeded -and $before.Error -match 'ActiveStore lookup failure' -and
                -not $probe.RequestSent -and $probe.Detail -match 'before sending') 'An unavailable pre-send rule was treated as a responder timeout.'
        }
        if ($mode -eq 'InactiveReplyRule') {
            $before = $probe.RuleBeforeSendJson | ConvertFrom-Json
            Assert-True ($before.Rules[0].EnforcementStatus -eq 'LocalFirewallRulesDisallowed' -and
                -not $before.Ready -and -not $probe.RequestSent) "The inactive rule was sent through or mislabeled as a network timeout: rule=$($probe.RuleBeforeSendJson)"
        }
        if ($mode -eq 'DelayedReplyRule') {
            Assert-True ($probe.Result -eq 'Served' -and $state.RuleReads -eq 2 -and
                $state.Sleeps.Count -eq 2 -and $state.Sleeps[0] -eq 100 -and $state.Sleeps[1] -eq 10 -and
                $state.Requests.Count -eq 2) 'Delayed ActiveStore enforcement was not polled, settled, then sent in that order.'
        }
        if ($mode -eq 'Denied') { Assert-True ($probe.TftpErrorCode -eq 2) 'The service file-access error was flattened into a generic failure.' }
    }
    $state.Mode = 'Timeout'; $state.Created = 0; $state.Removed = 0; $state.Closed = 0; $state.NetworkCalls = 0
    $state.Requests.Clear()
    $probe = Invoke-TftpReadProbe -Server '127.0.0.1' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' `
        -RuleActivationTimeoutMs 0 -RuleSettleMs 0 -DeferFailureNetworkState
    Assert-True ($probe.Result -eq 'NoResponse' -and $probe.NetworkStateDeferred -and
        $state.NetworkCalls -eq 0 -and $state.Removed -eq 1 -and $state.Closed -eq 1) 'The diagnostic replay performed slow inventory before its completion boundary or skipped socket/rule cleanup.'
}

& {
    $state = [pscustomobject]@{ Attempt = 0 }
    function Invoke-TftpReadProbe {
        param($Server, $FileName, $Port, $TimeoutMs)
        $state.Attempt++
        if ($state.Attempt -eq 1) {
            return [pscustomobject]@{ Result = 'NoResponse'; FileName = $FileName; Detail = 'initial timeout' }
        }
        return [pscustomobject]@{ Result = 'Served'; FileName = $FileName; Detail = 'DATA block 1' }
    }
    $probe = Invoke-TftpReadProbeWithRetry -Server 'DP1.test' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' `
        -RetryDelayMs 0
    Assert-True ($probe.Result -eq 'Served' -and $probe.Attempts -eq 2 -and $state.Attempt -eq 2 -and
        $probe.OriginalProbe.Result -eq 'NoResponse') 'A transient NoResponse was not retried once with original evidence.'

    $state.Attempt = 0
    function Invoke-TftpReadProbe {
        param($Server, $FileName, $Port, $TimeoutMs)
        $state.Attempt++
        return [pscustomobject]@{ Result = 'NoResponse'; FileName = $FileName; Detail = 'settled timeout' }
    }
    $probe = Invoke-TftpReadProbeWithRetry -Server 'DP1.test' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' `
        -RetryDelayMs 0
    Assert-True ($probe.Result -eq 'NoResponse' -and $probe.Attempts -eq 2 -and $state.Attempt -eq 2 -and
        $probe.OriginalProbe.Detail -eq 'settled timeout') 'A settled timeout was not bounded to exactly two failing attempts.'
}

& {
    $state = [pscustomobject]@{ LocalPort = 0; RuleName = ''; Removed = $false }
    function New-NetFirewallRule {
        param($Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort, $RemoteAddress, $Program, [Alias('Profile')]$FirewallProfile, $PolicyStore, $ErrorAction)
        Assert-True ($LocalPort -gt 0 -and $RemoteAddress -eq '127.0.0.1') 'The real socket was not bound to a scoped reply allowance.'
        $state.LocalPort = $LocalPort
        $state.RuleName = $Name
        [pscustomobject]@{ Name = $Name }
    }
    function Remove-NetFirewallRule {
        param($Name, $PolicyStore, $ErrorAction)
        Assert-True ($Name -eq $state.RuleName) 'The real socket probe removed an unrelated rule.'
        $state.Removed = $true
    }
    function Get-NetFirewallRule {
        param($Name, $PolicyStore, [switch]$TracePolicyStore, $ErrorAction)
        [pscustomobject]@{ Name = $Name; Enabled = 'True'; EnforcementStatus = 'Full' }
    }
    function Get-Phase11TftpNetworkState {
        param($PeerAddress, $LocalPort, $ProbeRuleName, $Context, $SinceUtc)
        Assert-True (-not $state.Removed -and $LocalPort -eq $state.LocalPort) 'Real socket failure evidence is too late.'
        @{ Route = @([pscustomobject]@{ IPAddress = '127.0.0.1' }) }
    }
    $serverJob = $null
    try {
        $serverJob = Start-Job -ScriptBlock {
            $listener = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
            $transfer = $null
            try {
                $listener.Client.ReceiveTimeout = 8000
                [pscustomobject]@{ Port = $listener.Client.LocalEndPoint.Port }
                $client = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                $request = $listener.Receive([ref]$client)
                if ($request.Length -lt 4 -or $request[1] -ne 1) { throw 'Expected a real TFTP RRQ.' }
                $transfer = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
                $transfer.Client.ReceiveTimeout = 8000
                $data = [byte[]]@(0, 3, 0, 1, 88, 89, 90)
                $null = $transfer.Send($data, $data.Length, $client)
                $abortFrom = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                $abort = $transfer.Receive([ref]$abortFrom)
                [pscustomobject]@{
                    TransferPort = $transfer.Client.LocalEndPoint.Port; ClientPort = $client.Port
                    AbortOpcode = ([int]$abort[0] * 256) + [int]$abort[1]; AbortClientPort = $abortFrom.Port
                }
            }
            finally {
                if ($transfer) { $transfer.Close() }
                $listener.Close()
            }
        }
        $readyWait = [Diagnostics.Stopwatch]::StartNew()
        while ($serverJob.ChildJobs[0].Output.Count -eq 0) {
            if ($serverJob.State -eq 'Failed') { Receive-Job -Job $serverJob -ErrorAction Stop }
            if ($readyWait.Elapsed.TotalSeconds -ge 20) { throw 'Loopback TFTP fixture did not become ready.' }
            Start-Sleep -Milliseconds 100
        }
        $listenPort = $serverJob.ChildJobs[0].Output[0].Port
        $probe = Invoke-TftpReadProbe -Server '127.0.0.1' -Port $listenPort `
            -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' -TimeoutMs 2000
        Assert-True ($probe.Result -eq 'Served' -and $probe.Bytes -eq 3 -and $state.Removed) "Real TFTP DATA from a transfer socket was not served and cleaned up: $($probe.Detail)"
        Assert-True ([bool](Wait-Job -Job $serverJob -Timeout 20)) 'The real transfer did not receive the probe abort.'
        $serverOutput = @(Receive-Job -Job $serverJob -ErrorAction Stop)
        $transferResult = $serverOutput[1]
        Assert-True ($transferResult.TransferPort -ne $listenPort -and
            $transferResult.ClientPort -eq $state.LocalPort -and $transferResult.AbortOpcode -eq 5 -and
            $transferResult.AbortClientPort -eq $state.LocalPort) 'The real TFTP flow did not use and abort the server-selected transfer port.'
        $silentListener = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        try {
            $state.Removed = $false
            $probe = Invoke-TftpReadProbe -Server '127.0.0.1' -Port $silentListener.Client.LocalEndPoint.Port `
                -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' -TimeoutMs 100
            Assert-True ($probe.Result -eq 'NoResponse' -and $state.Removed -and
                $probe.Detail -match 'client UDP/') "A native receive timeout lost its endpoint or cleanup: $($probe.Result) $($probe.Detail)"
        }
        finally { $silentListener.Close() }
    }
    finally {
        if ($serverJob) {
            if ($serverJob.State -eq 'Running') { Stop-Job -Job $serverJob }
            Remove-Job -Job $serverJob
        }
    }
}

& {
    $networkFixture = [pscustomobject]@{ UdpFailure = $false; XPath = ''; DisabledPrefix = $false; EndpointNoise = $false }
    function Get-NetIPAddress { param($AddressFamily, $ErrorAction) [pscustomobject]@{ IPAddress = '192.0.2.10'; InterfaceIndex = 7 } }
    function Get-NetConnectionProfile { param($ErrorAction) [pscustomobject]@{ InterfaceIndex = 7; NetworkCategory = 'DomainAuthenticated' } }
    function Get-NetAdapter { param($ErrorAction) [pscustomobject]@{ InterfaceIndex = 7; MacAddress = '00-11-22-33-44-55'; Status = 'Up' } }
    function Get-NetNeighbor {
        param($AddressFamily, $ErrorAction)
        [pscustomobject]@{ IPAddress = '192.0.2.20'; LinkLayerAddress = '00-00-00-00-00-00'; State = 'Incomplete'; InterfaceIndex = 7 }
        [pscustomobject]@{ IPAddress = '192.0.2.1'; LinkLayerAddress = 'AA-BB-CC-DD-EE-FF'; State = 'Reachable'; InterfaceIndex = 7 }
        [pscustomobject]@{ IPAddress = '198.51.100.1'; State = 'Reachable' }
    }
    function Get-Item { param($LiteralPath, $ErrorAction) [pscustomobject]@{ Length = 123; LastWriteTimeUtc = [datetime]::Parse('2026-11-18T20:55:03Z').ToUniversalTime() } }
    function Find-NetRoute { param($RemoteIPAddress, $ErrorAction) [pscustomobject]@{ IPAddress = '192.0.2.10'; NextHop = '192.0.2.1' } }
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($ClassName -eq 'Win32_Service') { [pscustomobject]@{ Name = 'SccmPxe'; State = 'Running'; ProcessId = 4310; PathName = 'E:\SMS_DP$\sms\bin\sccmpxe.exe' } }
        else { [pscustomobject]@{ ProcessId = 4310; Name = 'sccmpxe.exe'; ExecutablePath = 'E:\SMS_DP$\sms\bin\sccmpxe.exe' } }
    }
    function Get-NetUDPEndpoint {
        param($ErrorAction)
        if ($networkFixture.UdpFailure) { throw 'synthetic UDP inventory denial' }
        if ($networkFixture.EndpointNoise) {
            foreach ($port in 40000..40100) { [pscustomobject]@{ LocalPort = $port; LocalAddress = '0.0.0.0'; OwningProcess = 4310 } }
            [pscustomobject]@{ LocalPort = 69; LocalAddress = '192.0.2.20'; OwningProcess = 9999 }
        }
    }
    function Get-NetFirewallProfile {
        param($PolicyStore, $ErrorAction)
        Assert-True ($PolicyStore -eq 'ActiveStore') 'Profiles are not effective policy.'
        [pscustomobject]@{ Name = 'Domain'; Enabled = $true; AllowLocalFirewallRules = $false; LogBlocked = $false }
    }
    function Get-NetFirewallPortFilter {
        param($AssociatedNetFirewallRule, $ErrorAction)
        Assert-True ($AssociatedNetFirewallRule.Enabled -eq 'True') 'Disabled rules are consuming firewall inventory work.'
        $protocol = 'UDP'
        if ($AssociatedNetFirewallRule.Name -eq 'any') { $protocol = 'Any' }
        if ($AssociatedNetFirewallRule.Name -eq 'tcp') { $protocol = 'TCP' }
        [pscustomobject]@{ Protocol = $protocol; LocalPort = 'Any'; RemotePort = 'Any' }
    }
    function Get-NetFirewallRule {
        param($PolicyStore, [switch]$TracePolicyStore, $Name, $Enabled, $ErrorAction)
        Assert-True ($PolicyStore -eq 'ActiveStore' -and $TracePolicyStore) 'Effective rule/GPO provenance was not requested from the native API.'
        if ($Name) {
            [pscustomobject]@{ Name = $Name; Enabled = 'True'; EnforcementStatus = 'LocalFirewallRulesDisallowed' }
        }
        else {
            Assert-True ("$Enabled" -eq 'True') 'Native enabled-rule selection was not requested.'
            if ($networkFixture.DisabledPrefix) {
                foreach ($i in 1..100) { [pscustomobject]@{ Name = "disabled-$i"; Enabled = 'False' } }
                [pscustomobject]@{ Name = 'late-blocker'; DisplayName = 'No PXE keyword'; Enabled = 'True'; Action = 'Block'; PolicyStoreSource = 'domain-policy' }
            }
            else {
                foreach ($name in @('udp', 'any', 'tcp')) {
                    [pscustomobject]@{ Name = $name; DisplayName = 'No PXE keyword'; Enabled = 'True'; Action = 'Block'; PolicyStoreSource = 'domain-policy' }
                }
            }
        }
    }
    function Get-NetFirewallAddressFilter { param($AssociatedNetFirewallRule, $ErrorAction) [pscustomobject]@{ LocalAddress = 'Any'; RemoteAddress = '192.0.2.20' } }
    function Get-NetFirewallApplicationFilter { param($AssociatedNetFirewallRule, $ErrorAction) [pscustomobject]@{ Program = 'Any' } }
    function Get-NetFirewallServiceFilter { param($AssociatedNetFirewallRule, $ErrorAction) [pscustomobject]@{ Service = 'Any' } }
    function Get-WinEvent {
        param($LogName, $FilterXPath, $MaxEvents, $ErrorAction)
        $networkFixture.XPath = $FilterXPath
        $wfpEventFixture = [pscustomobject]@{ Id = 5157; RecordId = 123; TimeCreated = Get-Date }
        $wfpEventFixture | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
            '<Event><EventData><Data Name="Protocol">17</Data><Data Name="SourceAddress">192.0.2.20</Data><Data Name="DestPort">53000</Data><Data Name="FilterRTID">222</Data></EventData></Event>'
        }
        $wfpEventFixture
    }
    $snapshot = Get-Phase11TftpNetworkState -PeerAddress '192.0.2.20' -LocalPort 53000 -ProbeRuleName 'ScopedFixture'
    Assert-True ($snapshot.UdpQuerySucceeded -and $snapshot.UdpEndpoints.Count -eq 0 -and
        $snapshot.Services[0].State -eq 'Running') 'A running service is being substituted for measured UDP listener ownership.'
    Assert-True ($snapshot.ActiveProbeRule[0].EnforcementStatus -eq 'LocalFirewallRulesDisallowed' -and
        -not $snapshot.FirewallProfiles[0].AllowLocalFirewallRules -and $snapshot.FirewallRules.Count -eq 2 -and
        $snapshot.FirewallRules[1].Protocol -eq 'Any') 'Effective policy, non-PXE-named blocks or Any-protocol rules were lost.'
    Assert-True ($snapshot.WfpEvents.Count -eq 1 -and $snapshot.WfpEvents[0].Data.FilterRTID -eq '222' -and
        $networkFixture.XPath -match '5152.*5157.*SystemTime.*192\.0\.2\.20') 'Packet-drop evidence is not UTC/peer-correlated or loses the blocking filter ID.'
    Assert-True ($snapshot.AddressQuerySucceeded -and $snapshot.ServiceQuerySucceeded -and $snapshot.Neighbors.Count -eq 2 -and
        $snapshot.Neighbors[0].State -eq 'Incomplete' -and $snapshot.Adapters[0].MacAddress -and
        $snapshot.PxeLogCandidates[0].Measured -and $snapshot.PxeLogCandidates[0].Source -match 'not an authoritative') 'Wrong-target/ARP/log-freshness theories lack independently labelled evidence.'
    $networkFixture.EndpointNoise = $true
    $noisy = Get-Phase11TftpNetworkState -PeerAddress '192.0.2.20' -LocalPort 69
    Assert-True ($noisy.RequestedPortEndpointCount -eq 1 -and $noisy.RequestedPortEndpoints[0].OwningProcess -eq 9999 -and
        $noisy.UdpEndpoints.Count -eq 100) 'The exact requested-port owner was lost behind unrelated service sockets.'
    $networkFixture.EndpointNoise = $false
    $networkFixture.DisabledPrefix = $true
    $snapshot = Get-Phase11TftpNetworkState -PeerAddress '192.0.2.20'
    Assert-True ($snapshot.FirewallRules.Count -eq 1 -and $snapshot.FirewallRules[0].Name -eq 'late-blocker' -and
        -not $snapshot.FirewallRulesTruncated) 'A disabled-rule prefix exhausted the retained enabled UDP/Any inventory budget.'
    $networkFixture.DisabledPrefix = $false
    $networkFixture.UdpFailure = $true
    $snapshot = Get-Phase11TftpNetworkState -PeerAddress '192.0.2.20'
    Assert-True (-not $snapshot.UdpQuerySucceeded -and ($snapshot.Errors -join ' ') -match 'UDP inventory denial') 'An unreadable endpoint table is reported as a measured absence.'
}

& {
    $state = [pscustomobject]@{
        Mode = 'Success'; Commands = [Collections.Generic.List[object]]::new()
        Removed = [Collections.Generic.List[string]]::new()
        Directories = [Collections.Generic.HashSet[string]]::new()
        Files = [Collections.Generic.HashSet[string]]::new()
        Active = [Collections.Generic.HashSet[string]]::new()
        InventoryCalls = 0; TestTraceId = ''
    }
    function New-Item {
        param($ItemType, $Path, [switch]$Force, $ErrorAction)
        if ($Force -and $state.Mode -eq 'StopDirectoryFailure') { throw 'synthetic stop directory failure' }
        $created = $state.Directories.Add($Path)
        if (-not $created -and -not $Force) { throw 'synthetic directory already exists' }
    }
    function Set-Content {
        param($LiteralPath, $Value, $Encoding, $ErrorAction)
        if ($state.Mode -eq 'StopIntentWriteFailure' -and $LiteralPath -like '*\Stop.requested') { throw 'synthetic stop intent write failure' }
        if ($state.Mode -eq 'StopConfirmWriteFailure' -and $LiteralPath -like '*\Stop.confirmed') { throw 'synthetic stop confirmation write failure' }
        [void]$state.Files.Add($LiteralPath)
    }
    function Test-Path {
        param($LiteralPath, $PathType, $ErrorAction)
        if ($state.Mode -eq 'MarkerReadFailure' -and $LiteralPath -like '*\Stop.requested') { throw 'synthetic marker read failure' }
        $state.Files.Contains($LiteralPath)
    }
    function Set-Acl {
        param($LiteralPath, $AclObject, $ErrorAction)
        if ($state.Mode -eq 'StopAclFailure') { throw 'synthetic stop ACL failure' }
        Assert-True ($LiteralPath -like '*\Temp\MemLabsTftp-*' -and $AclObject.AreAccessRulesProtected) 'Trace files are not in an owned, protected directory.'
    }
    function Invoke-Phase11TftpTraceCommand {
        param($ArgumentList)
        $state.Commands.Add($ArgumentList)
        $session = @($ArgumentList | Where-Object { $_ -like 'sessionname=*' })[0].Substring(12)
        $code = 0
        if ($state.Mode -eq 'StopFailure' -and $ArgumentList[1] -eq 'stop') { $code = 5 }
        if ($ArgumentList[1] -eq 'start') {
            if ($state.Mode -eq 'InFlightStart') {
                $null = Invoke-Phase11TftpCapture -Action Stop -TraceId $state.TestTraceId -Role Client
            }
            [void]$state.Active.Add($session)
        }
        elseif ($code -eq 0) { [void]$state.Active.Remove($session) }
        @{ ExitCode = $code; StdOut = 'synthetic native output'; StdErr = '' }
    }
    function Get-Item { param($LiteralPath, $ErrorAction) [pscustomobject]@{ Length = 128 } }
    function Get-FileHash { param($LiteralPath, $Algorithm, $ErrorAction) [pscustomobject]@{ Hash = ('A' * 64) } }
    function Remove-Item { param($LiteralPath, $ErrorAction) $state.Removed.Add($LiteralPath) }
    function Get-Phase11TftpNetworkState {
        param($PeerAddress, $LocalPort, $Context, $SinceUtc)
        $state.InventoryCalls++
        if ($state.Mode -eq 'SnapshotFailure') { throw 'synthetic snapshot failure' }
        @{ Context = $Context; LocalPort = $LocalPort }
    }
    $id = [guid]::NewGuid().ToString('N')
    $start = Invoke-Phase11TftpCapture -Action Start -TraceId $id -Role Responder -ServerAddress '192.0.2.20'
    $arguments = $state.Commands[0]
    Assert-True ($start.Succeeded -and $arguments -contains "sessionname=MemLabsTftp-$id-Responder" -and
        $arguments -contains 'IPv4.Address=192.0.2.20' -and $arguments -contains 'Protocol=UDP' -and
        $arguments -contains 'PacketTruncateBytes=128' -and $arguments -contains 'maxSize=8' -and
        $arguments -contains 'provider=Microsoft-Windows-WFP') 'Capture is unscoped, unbounded, or does not include WFP.'
    $stop = Invoke-Phase11TftpCapture -Action Stop -TraceId $id -Role Responder -PeerAddress '192.0.2.10'
    Assert-True ($stop.Succeeded -and $stop.TraceStopped -and $stop.Bytes -eq 0 -and $state.InventoryCalls -eq 0 -and
        ($state.Commands[1] -join ' ') -eq "trace stop sessionname=MemLabsTftp-$id-Responder") 'Trace stop touches another session or performs slow inventory before the peer can stop.'
    $collected = Invoke-Phase11TftpCapture -Action Collect -TraceId $id -Role Responder
    Assert-True ($collected.Succeeded -and $collected.TraceStopped -and $collected.Bytes -eq 128 -and
        $collected.SHA256 -eq ('A' * 64)) 'Stopped artifacts are not independently bounded and verified.'
    $beforeCommands = $state.Commands.Count
    $inspection = Invoke-Phase11TftpCapture -Action Inspect -TraceId $id -Role Responder
    Assert-True ($inspection.Succeeded -and $inspection.NetworkStateJson -match 'BeforeDiagnosticReplay' -and
        $state.Commands.Count -eq $beforeCommands) 'Responder pre-replay inspection changed trace state or failed to label its timing.'
    $state.Mode = 'StopFailure'
    $stop = Invoke-Phase11TftpCapture -Action Stop -TraceId $id -Role Client -PeerAddress '192.0.2.20' -LocalPort 53000
    $collected = Invoke-Phase11TftpCapture -Action Collect -TraceId $id -Role Client -PeerAddress '192.0.2.20' -LocalPort 53000
    Assert-True (-not $stop.Succeeded -and -not $stop.TraceStopped -and $stop.Error -match 'exit code 5' -and
        -not $collected.Succeeded -and $collected.NetworkStateJson -match '53000' -and
        $state.Removed.Count -eq 0) 'A failed stop hides the error, discards independent network evidence or deletes a live trace.'
    $state.Mode = 'SnapshotFailure'
    $collected = Invoke-Phase11TftpCapture -Action Collect -TraceId $id -Role Responder
    Assert-True ($collected.Succeeded -and $collected.TraceStopped -and $collected.SHA256 -and
        $collected.NetworkStateError -match 'snapshot failure') 'A failed network snapshot discarded an independently captured ETL.'
    $state.Mode = 'Success'
    $lateId = [guid]::NewGuid().ToString('N')
    $null = Invoke-Phase11TftpCapture -Action Stop -TraceId $lateId -Role Client
    $beforeStarts = @($state.Commands | Where-Object { $_[1] -eq 'start' }).Count
    $late = Invoke-Phase11TftpCapture -Action Start -TraceId $lateId -Role Client -ServerAddress '192.0.2.20'
    Assert-True (-not $late.Succeeded -and
        @($state.Commands | Where-Object { $_[1] -eq 'start' }).Count -eq $beforeStarts) 'A queued start began a trace after an earlier stop intent.'
    $state.Mode = 'InFlightStart'; $state.TestTraceId = [guid]::NewGuid().ToString('N')
    $late = Invoke-Phase11TftpCapture -Action Start -TraceId $state.TestTraceId -Role Client -ServerAddress '192.0.2.20'
    Assert-True (-not $late.Succeeded -and $late.TraceStopped -and
        -not $state.Active.Contains("MemLabsTftp-$($state.TestTraceId)-Client")) 'A start completing after its stop request left an owned capture running.'
    foreach ($fault in @('StopDirectoryFailure', 'StopAclFailure', 'StopIntentWriteFailure', 'StopConfirmWriteFailure')) {
        $state.Mode = 'Success'
        $faultId = [guid]::NewGuid().ToString('N')
        $started = Invoke-Phase11TftpCapture -Action Start -TraceId $faultId -Role Client -ServerAddress '192.0.2.20'
        Assert-True ($started.Succeeded) 'Stop-metadata fault baseline did not start its synthetic capture.'
        $beforeStops = @($state.Commands | Where-Object { $_[1] -eq 'stop' }).Count
        $state.Mode = $fault
        $stopped = Invoke-Phase11TftpCapture -Action Stop -TraceId $faultId -Role Client
        Assert-True ($stopped.TraceStopped -and -not $stopped.Succeeded -and $stopped.Error -and
            @($state.Commands | Where-Object { $_[1] -eq 'stop' }).Count -eq ($beforeStops + 1) -and
            -not $state.Active.Contains("MemLabsTftp-$faultId-Client")) "$fault suppressed the exact-owned-session native stop or hid the metadata failure."
        $state.Mode = 'Success'
        $collected = Invoke-Phase11TftpCapture -Action Collect -TraceId $faultId -Role Client -StopAcknowledged True
        Assert-True ($collected.Succeeded -and $collected.SHA256) "$fault suppressed independently stopped ETL collection despite a validated in-memory stop acknowledgement."
    }
    $state.Mode = 'MarkerReadFailure'
    $faultId = [guid]::NewGuid().ToString('N')
    $started = Invoke-Phase11TftpCapture -Action Start -TraceId $faultId -Role Client -ServerAddress '192.0.2.20'
    Assert-True (-not $started.Succeeded -and $started.TraceStopped -and $started.Error -match 'marker read failure' -and
        -not $state.Active.Contains("MemLabsTftp-$faultId-Client")) 'An unreadable start/stop marker escaped cleanup or produced a successful start.'
}

& {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-TftpEvidence-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $fixture
    $Common = @{ LogPath = Join-Path $fixture 'VMBuild.log' }
    $state = [pscustomobject]@{
        Mode = 'Success'; Replays = 0; Copies = 0; RolledOver = $false; Inspections = 0; LocalControls = 0
        Stops = [Collections.Generic.List[string]]::new()
        Cleanups = [Collections.Generic.List[string]]::new()
        Messages = [Collections.Generic.List[string]]::new()
        Bytes = [Text.Encoding]::ASCII.GetBytes('synthetic captured ETL fixture')
    }
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try { $expectedHash = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($state.Bytes))).Replace('-', '') }
    finally { $hashAlgorithm.Dispose() }
    function Add-Phase11Output { param($Text, $Level) $state.Messages.Add($Text) }
    function Write-Log { param($Message, [switch]$Warning, [switch]$LogOnly) $state.Messages.Add($Message) }
    function Get-VMNetworkAdapter {
        param($VMName, $ErrorAction)
        [pscustomobject]@{ Name = 'test-nic'; SwitchName = '192.0.2.0'; MacAddress = '001122334455' }
    }
    function Get-VMNetworkAdapterAcl {
        param($VMName, $ErrorAction)
        [pscustomobject]@{ ParentAdapter = [pscustomobject]@{ Name = 'test-nic' }; Action = 'Deny'; Direction = 'Inbound'; LocalAddress = 'Any'; RemoteAddress = '192.0.2.10'; RemoteAddressType = 'IPv4' }
    }
    function Get-VMNetworkAdapterExtendedAcl {
        param($VMName, $ErrorAction)
        [pscustomobject]@{ ParentAdapter = [pscustomobject]@{ Name = 'test-nic' }; Action = 'Deny'; Direction = 'Outbound'; RemoteIPAddress = '192.0.2.20'; RemotePort = '69'; Protocol = 'UDP'; Stateful = $false; Weight = 100 }
    }
    function Set-Content {
        [CmdletBinding()]
        param($LiteralPath, [Parameter(ValueFromPipeline = $true)]$Value, $Encoding)
        process {
            $fail = ($state.Mode -eq 'OriginalSnapshotWriteFailure' -and $LiteralPath -like '*-Original-original-one-Network.json') -or
                ($state.Mode -eq 'ReplaySnapshotWriteFailure' -and $LiteralPath -like '*-Replay-Network.json') -or
                ($state.Mode -eq 'ClientSnapshotWriteFailure' -and $LiteralPath -like '*-Client-Network.json') -or
                ($state.Mode -eq 'ResponderSnapshotWriteFailure' -and $LiteralPath -like '*-Responder-Network.json') -or
                ($state.Mode -eq 'BeforeSnapshotWriteFailure' -and $LiteralPath -like '*-Responder-Before-Network.json')
            if ($fail) { throw "synthetic $($state.Mode)" }
            Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop
        }
    }
    function Invoke-TftpReadProbe {
        param($Server, $FileName, $TimeoutMs, [switch]$DeferFailureNetworkState)
        Assert-True ([bool]$DeferFailureNetworkState) 'The replay can perform slow inventory while both circular captures are still recording.'
        $network = ''
        if ($state.Mode -eq 'ReplaySnapshotWriteFailure') { $network = '{"Context":"fixture replay evidence"}' }
        [pscustomobject]@{ Result = 'Served'; LocalPort = 54000; NetworkStateJson = $network }
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds)
        if ($DisplayName -eq 'Phase11-TFTP-DiagnosticReplay') {
            $state.Replays++
            Assert-True ($ArgumentList[1] -eq '192.0.2.20') 'Replay does not pin the original responder address to the capture filter.'
            if ($state.Mode -eq 'ReplayFailure') { throw 'synthetic replay transport failure' }
            return @{ ScriptBlockOutput = (& $ScriptBlock @ArgumentList) }
        }
        if ($DisplayName -eq 'Phase11-TFTP-ResponderLocalControl') {
            $state.LocalControls++
            Assert-True ($VMName -eq 'DP1' -and $state.Stops.Count -eq 2 -and
                $state.Copies -eq 2 -and $ArgumentList[1] -eq '192.0.2.20' -and
                $ArgumentList[2] -eq 'smsboot\PRI00008\x64\wdsmgfw.efi') 'DP-local control used a different target/file, ran on the site, or preceded remote evidence collection.'
            if ($state.Mode -eq 'LocalControlFailure') { throw 'synthetic local control failure' }
            return @{ ScriptBlockOutput = @{ Probe = [pscustomobject]@{ Result = 'NoResponse'; Detail = 'fixture local timeout'; TftpErrorCode = $null } } }
        }
        $action = $ArgumentList[1]; $id = $ArgumentList[2]; $role = $ArgumentList[3]
        $answer = @{
            TraceId = $id; Role = $role; Action = $action; Succeeded = $true; TraceStopped = $false
            Path = "$env:windir\Temp\MemLabsTftp-$id-$role\Tftp.etl"; Bytes = $state.Bytes.Length
            SHA256 = $expectedHash; Error = ''; NetworkStateJson = '{"Context":"AfterDiagnosticCaptureStop"}'
            SessionName = "MemLabsTftp-$id-$role"
        }
        if ($action -eq 'Start' -and $role -eq 'Responder' -and $state.Mode -eq 'StartFailure') { throw 'synthetic start acknowledgement lost' }
        if ($action -eq 'Inspect') {
            $state.Inspections++
            Assert-True ($state.Replays -eq 0 -and $state.Stops.Count -eq 0 -and $role -eq 'Responder') 'Responder baseline was taken after it could be changed by replay/control traffic.'
            if ($state.Mode -eq 'BeforeInspectionFailure') { throw 'synthetic responder inspection failure' }
        }
        if ($action -eq 'Stop') {
            $state.Stops.Add($role)
            $answer.TraceStopped = $true
            $answer.NetworkStateJson = ''
            if ($role -eq 'Responder' -and $state.Mode -eq 'StopFailure') { $answer.TraceStopped = $false; $answer.Succeeded = $false; $answer.Error = 'synthetic stop failure' }
            if ($role -eq 'Client' -and $state.Mode -eq 'StopMetadataFailure') { $answer.Succeeded = $false; $answer.Error = 'synthetic stop metadata failure' }
        }
        if ($action -eq 'Collect') {
            if ($state.Stops.Count -ne 2) { $state.RolledOver = $true; throw 'synthetic rollover: slow inventory started with a peer still recording' }
            $answer.TraceStopped = $true
            if ($role -eq 'Client' -and $state.Mode -eq 'StopMetadataFailure') {
                Assert-True ($ArgumentList[8] -eq 'True') 'A validated native stop acknowledgement was discarded because ancillary marker persistence failed.'
            }
            if ($role -eq 'Responder' -and $state.Mode -eq 'StopFailure') { $answer.TraceStopped = $false; $answer.Succeeded = $false; $answer.Error = 'synthetic unconfirmed stop' }
        }
        if ($action -eq 'Cleanup') { $state.Cleanups.Add($role) }
        @{ ScriptBlockOutput = $answer }
    }
    function Copy-ItemFromVmBounded {
        param($VMName, $VMDomainName, $Path, $Destination, $TimeoutSeconds)
        $state.Copies++
        if ($state.Stops.Count -ne 2) { $state.RolledOver = $true; throw 'synthetic rollover: copying started with a peer still recording' }
        $bytes = $state.Bytes
        if ($Destination -like '*-Client.etl' -and $state.Mode -eq 'HashMismatch') { $bytes = [byte[]]@(1, 2, 3) }
        [IO.File]::WriteAllBytes($Destination, $bytes)
        return $true
    }
    $original = @(
        [pscustomobject]@{ ProbeId = 'original-one'; StartedAtUtc = '2026-11-18T22:34:30Z'; Server = 'DP1.memlabs.test'; ServerAddress = '192.0.2.20'; LocalPort = 53000; RouteSourceAddress = '192.0.2.10'; FileName = 'smsboot\PRI00008\x64\wdsmgfw.efi'; Result = 'NoResponse'; NetworkStateJson = '{"Context":"FailureBeforeProbeCleanup"}' },
        [pscustomobject]@{ ProbeId = 'original-two'; StartedAtUtc = '2026-11-18T22:34:36Z'; Server = 'DP1.memlabs.test'; ServerAddress = '192.0.2.20'; LocalPort = 53001; RouteSourceAddress = '192.0.2.10'; FileName = 'smsboot\PRI00009\x64\wdsmgfw.efi'; Result = 'NoResponse'; NetworkStateJson = '{"Context":"FailureBeforeProbeCleanup"}' }
    )
    try {
        foreach ($mode in @('Success', 'ReplayFailure', 'StartFailure', 'StopFailure', 'HashMismatch',
                'OriginalSnapshotWriteFailure', 'ReplaySnapshotWriteFailure', 'ClientSnapshotWriteFailure', 'ResponderSnapshotWriteFailure',
                'StopMetadataFailure', 'BeforeInspectionFailure', 'BeforeSnapshotWriteFailure', 'LocalControlFailure', 'Recovery')) {
            $state.Mode = $mode; $state.Replays = 0; $state.Copies = 0; $state.RolledOver = $false
            $state.Inspections = 0; $state.LocalControls = 0
            $state.Stops.Clear(); $state.Cleanups.Clear(); $state.Messages.Clear()
            $before = @(Get-ChildItem -LiteralPath $fixture -Filter '*-Evidence.json' -File | ForEach-Object Name)
            $output = @(Save-Phase11TftpFailureDiagnostics -VMName 'SITE1' -DomainName 'memlabs.test' -Probes $original -ProbeDefinition '# fixture')
            $manifest = @(Get-ChildItem -LiteralPath $fixture -Filter '*-Evidence.json' -File | Where-Object Name -notin $before)
            Assert-True ($output.Count -eq 0 -and $manifest.Count -eq 1 -and $state.Replays -eq 1 -and
                $state.Stops.Count -eq 2 -and @($original | Where-Object Result -ne 'NoResponse').Count -eq 0) "$mode changed required validation, replayed per package, emitted extra results, or failed to stop both owned endpoint sessions."
            $document = Get-Content -LiteralPath $manifest[0].FullName -Raw | ConvertFrom-Json
            $expectedNetworks = 2
            if ($mode -eq 'OriginalSnapshotWriteFailure') { $expectedNetworks = 1 }
            Assert-True ($document.OriginalProbes.Count -eq 2 -and $document.OriginalNetworkStateFiles.Count -eq $expectedNetworks -and
                $document.ValidationOutcome -match 'Original failure is preserved') "$mode lost original attempts or the before-cleanup artifacts."
            if ($mode -in @('Success', 'Recovery')) { Assert-True ($document.Errors.Count -eq 0 -and $state.Cleanups.Count -eq 2 -and $document.Replay.Result -eq 'Served') 'A successful diagnostic replay/copy is not correctly separated from the failed original validation.' }
            else { Assert-True ($document.Errors.Count -gt 0 -and ($state.Messages -join ' ') -match 'diagnostics incomplete') "$mode silently claims complete diagnostics." }
            if ($mode -in @('HashMismatch', 'StopFailure')) { Assert-True ($state.Cleanups.Count -eq 1) "$mode deleted an unverified or still-running guest capture." }
            else { Assert-True ($state.Copies -eq 2 -and $state.Cleanups.Count -eq 2) "$mode suppressed an independent ETL copy or its verified cleanup." }
            Assert-True (-not $state.RolledOver) "$mode allowed slow client work to overwrite the responder replay."
            $expectedControls = 1
            if ($mode -eq 'StopFailure') { $expectedControls = 0 }
            Assert-True ($state.Inspections -eq 1 -and $state.LocalControls -eq $expectedControls -and
                $document.HostNetwork.Count -eq 2) "$mode lost a theory control or ran one before trace quiescence."
            Assert-True ($document.HostNetwork[0].'Get-VMNetworkAdapterAcl'[0].RemoteAddress -eq '192.0.2.10' -and
                $document.HostNetwork[0].'Get-VMNetworkAdapterAcl'[0].AdapterName -eq 'test-nic' -and
                $document.HostNetwork[0].'Get-VMNetworkAdapterExtendedAcl'[0].RemotePort -eq '69') "$mode flattened the distinct native standard/extended Hyper-V ACL address and port schemas."
        }
    }
    finally {
        foreach ($file in @(Get-ChildItem -LiteralPath $fixture -File)) { Remove-Item -LiteralPath $file.FullName }
        Remove-Item -LiteralPath $fixture
    }
}

& {
    $captureFunction = (Get-TestFunction 'Invoke-Phase11TftpCapture').Extent.Text
    $probeFunction = (Get-TestFunction 'Invoke-TftpReadProbe').Extent.Text
    $fixtureScript = {
        . ([scriptblock]::Create($CaptureFunction))
        . ([scriptblock]::Create($ProbeFunction))
        function Wait-CancellationBoundary {
            param($Name)
            if ($Shared.Stage -ne $Name) { return }
            $Shared.Entered.Set()
            if ($Name -in @('Confirmation', 'FailureSnapshot')) { [void]$Shared.Release.Wait(5000) }
            else { Start-Sleep -Seconds 30 }
        }
        function New-Item {
            param($ItemType, $Path, [switch]$Force, $ErrorAction)
            Wait-CancellationBoundary 'Directory'
        }
        function Set-Acl {
            param($LiteralPath, $AclObject, $ErrorAction)
            Wait-CancellationBoundary 'Acl'
        }
        function Set-Content {
            param($LiteralPath, $Value, $Encoding, $ErrorAction)
            if ($LiteralPath -like '*\Stop.requested') {
                Wait-CancellationBoundary 'Intent'
                $Shared.StopRequested = $true
            }
            else { Wait-CancellationBoundary 'Confirmation' }
        }
        function Test-Path {
            param($LiteralPath, $PathType, $ErrorAction)
            if ($LiteralPath -like '*\Stop.requested') {
                $Shared.IntentChecks++
                if ($Shared.Stage -eq 'FinalIntent' -and $Shared.IntentChecks -eq 2) {
                    Wait-CancellationBoundary 'FinalIntent'
                }
                return $Shared.StopRequested
            }
            return $false
        }
        function Invoke-Phase11TftpTraceCommand {
            param($ArgumentList)
            if ($ArgumentList[1] -eq 'start') {
                if ($Shared.Stage -eq 'FinalIntent') {
                    $null = Invoke-Phase11TftpCapture -Action Stop -TraceId $Shared.TraceId -Role Client
                    $Shared.NativeStops = 0
                }
                $Shared.Active = $true
                return @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $Shared.NativeStops++
            $Shared.LastStop = $ArgumentList -join ' '
            $code = 1
            if ($Shared.Active) { $code = 0 }
            $Shared.Active = $false
            @{ ExitCode = $code; StdOut = ''; StdErr = '' }
        }
        function New-NetFirewallRule {
            param($Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort, $RemoteAddress, $Program, [Alias('Profile')]$FirewallProfile, $PolicyStore, $ErrorAction)
            $Shared.RuleName = $Name
            [pscustomobject]@{ Name = $Name }
        }
        function Get-NetFirewallRule {
            param($Name, $PolicyStore, [switch]$TracePolicyStore, $ErrorAction)
            Wait-CancellationBoundary 'RulePeek'
            [pscustomobject]@{ Name = $Name; Enabled = 'True' }
        }
        function Remove-NetFirewallRule {
            param($Name, $PolicyStore, $ErrorAction)
            if ($Name -ne $Shared.RuleName) { throw 'Cancellation removed a foreign firewall rule.' }
            $Shared.RuleRemovals++
        }
        function Get-Phase11TftpNetworkState {
            param($PeerAddress, $LocalPort, $ProbeRuleName, $Context, $SinceUtc)
            Wait-CancellationBoundary 'FailureSnapshot'
            @{ Route = @([pscustomobject]@{ IPAddress = '127.0.0.1' }) }
        }
        function New-Object {
            param($TypeName, $ArgumentList)
            switch ($TypeName) {
                'System.Net.Sockets.UdpClient' {
                    $socket = [pscustomobject]@{ Client = [pscustomobject]@{ ReceiveTimeout = 0; LocalEndPoint = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 53000) } }
                    $socket | Add-Member -MemberType ScriptMethod -Name Send -Value { param($Bytes, $Length, $Endpoint) $Length }
                    $socket | Add-Member -MemberType ScriptMethod -Name Receive -Value {
                        param([ref]$Endpoint)
                        if ($Shared.Stage -eq 'FailureSnapshot') { throw [Net.Sockets.SocketException]::new(10060) }
                        $Endpoint.Value = [Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 1069)
                        return ,([byte[]]@(0, 3, 0, 1, 1))
                    }
                    $socket | Add-Member -MemberType ScriptMethod -Name Close -Value { $Shared.SocketCloses++ }
                    return $socket
                }
                'System.Collections.Generic.List[byte]' { return ,([Collections.Generic.List[byte]]::new()) }
                'System.Net.IPEndPoint' { return [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0) }
                default { throw "Unexpected cancellation fixture object: $TypeName" }
            }
        }
        if ($Shared.Action -eq 'Probe') { Invoke-TftpReadProbe -Server '127.0.0.1' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi' }
        else { Invoke-Phase11TftpCapture -Action $Shared.Action -TraceId $Shared.TraceId -Role Client -ServerAddress '192.0.2.20' }
    }.ToString()
    foreach ($stage in @('None', 'Directory', 'Acl', 'Intent', 'Confirmation', 'FinalIntent', 'RulePeek', 'FailureSnapshot')) {
        $shared = [hashtable]::Synchronized(@{
                Stage = $stage; Action = 'Stop'; TraceId = [guid]::NewGuid().ToString('N')
                Active = $true; NativeStops = 0; LastStop = ''; StopRequested = $false; IntentChecks = 0
                RuleName = ''; RuleRemovals = 0; SocketCloses = 0
                Entered = [Threading.ManualResetEventSlim]::new($false)
                Release = [Threading.ManualResetEventSlim]::new($false)
            })
        if ($stage -eq 'FinalIntent') { $shared.Action = 'Start'; $shared.Active = $false }
        $isProbeCase = $stage -in @('RulePeek', 'FailureSnapshot')
        if ($isProbeCase) { $shared.Action = 'Probe'; $shared.Active = $false }
        $runspace = [runspacefactory]::CreateRunspace()
        $pipeline = [powershell]::Create()
        try {
            $runspace.Open()
            $runspace.SessionStateProxy.SetVariable('Shared', $shared)
            $runspace.SessionStateProxy.SetVariable('CaptureFunction', $captureFunction)
            $runspace.SessionStateProxy.SetVariable('ProbeFunction', $probeFunction)
            $pipeline.Runspace = $runspace
            [void]$pipeline.AddScript($fixtureScript)
            $invocation = $pipeline.BeginInvoke()
            if ($stage -ne 'None') {
                Assert-True ($shared.Entered.Wait(5000)) "$stage cancellation boundary was not reached."
                $stop = $pipeline.BeginStop($null, $null)
                $shared.Release.Set()
                Assert-True ($stop.AsyncWaitHandle.WaitOne(5000)) "$stage pipeline cancellation did not finish its authoritative cleanup."
                $pipeline.EndStop($stop)
            }
            try { $null = $pipeline.EndInvoke($invocation) }
            catch {
                $cancelled = $false
                for ($exception = $_.Exception; $exception; $exception = $exception.InnerException) {
                    if ($exception -is [Management.Automation.PipelineStoppedException]) { $cancelled = $true; break }
                }
                if (-not $cancelled -or $stage -eq 'None') { throw }
            }
            if ($isProbeCase) {
                Assert-True ($shared.SocketCloses -eq 1 -and $shared.RuleRemovals -eq 1) "$stage diagnostic cancellation bypassed original socket/reply-rule cleanup."
            }
            else {
                Assert-True (-not $shared.Active -and $shared.NativeStops -eq 1 -and
                    $shared.LastStop -eq "trace stop sessionname=MemLabsTftp-$($shared.TraceId)-Client") "$stage cancellation bypassed the exact-owned-session native stop."
            }
            $shared.Stage = 'None'; $shared.NativeStops = 0; $shared.RuleRemovals = 0; $shared.SocketCloses = 0
            if ($isProbeCase) { $shared.Action = 'Probe' }
            else { $shared.Action = 'Stop'; $shared.Active = $true }
            $pipeline.Commands.Clear()
            $pipeline.Streams.Error.Clear()
            [void]$pipeline.AddScript($fixtureScript)
            $recovery = @($pipeline.Invoke())
            if ($isProbeCase) {
                Assert-True ($recovery.Count -eq 1 -and $recovery[0].Result -eq 'Served' -and
                    $shared.SocketCloses -eq 1 -and $shared.RuleRemovals -eq 1) "$stage cancellation broke probe recovery."
            }
            else {
                Assert-True ($recovery.Count -eq 1 -and $recovery[0].TraceStopped -and
                    -not $shared.Active -and $shared.NativeStops -eq 1) "$stage cancellation broke same-runspace recovery."
            }
        }
        finally {
            $shared.Release.Set()
            if ($pipeline.InvocationStateInfo.State -eq 'Running') { $pipeline.Stop() }
            $pipeline.Dispose()
            $runspace.Dispose()
            $shared.Entered.Dispose()
            $shared.Release.Dispose()
        }
    }
}

$verdicts = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$probe.Result -eq ''Served'''
        }, $true))
Assert-True ($verdicts.Count -eq 1) 'Expected one required site-side TFTP delivery verdict.'
$verdict = [scriptblock]::Create($verdicts[0].Extent.Text)
& {
    $tftpDp = 'DP1.memlabs.test'
    $tftpPkg = 'PRI00008'
    foreach ($mode in @('Served', 'FileNotFound', 'NoResponse', 'Error')) {
        $probe = [pscustomobject]@{ Result = $mode; FileName = 'smsboot\PRI00008\x64\wdsmgfw.efi'; Detail = 'fixture detail' }
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        . $verdict
        Assert-True ($results.Passed -eq ($mode -eq 'Served') -and $results.Details.Count -eq 1) "$mode was not propagated to required Phase 11 coverage."
        if ($mode -eq 'NoResponse') {
            Assert-True (($results.Details -join ' ') -match 'timeout alone does not prove') 'A site-probe timeout still claims every PXE client is blocked.'
        }
    }
}

Write-Host 'PASS -- protected DP transport, real TFTP replies, before-cleanup policy evidence, paired named captures, failed-replay cleanup, artifact verification and unchanged failure verdicts are verified.'
