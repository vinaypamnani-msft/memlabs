<#
.SYNOPSIS
    Exercises protected DP probe transport and scoped TFTP replies without guest changes.
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
. ([scriptblock]::Create((Get-TestFunction 'Invoke-TftpReadProbe').Extent.Text))

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
        Mode = 'Served'; RuleName = ''; Created = 0; Removed = 0; Closed = 0
        Requests = [System.Collections.Generic.List[object]]::new()
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
        if ($state.Mode -eq 'Timeout') { throw [Net.Sockets.SocketException]::new(10060) }
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
    foreach ($mode in @('Served', 'Missing', 'Denied', 'Truncated', 'WrongBlock', 'EmptyData', 'WrongSender',
            'Timeout', 'RuleFailure', 'SendFailure', 'AbortFailure', 'CloseFailure', 'RemoveFailure')) {
        $state.Mode = $mode
        $state.Created = 0
        $state.Removed = 0
        $state.Closed = 0
        $state.Requests.Clear()
        $probe = Invoke-TftpReadProbe -Server '127.0.0.1' -FileName 'smsboot\PRI00008\x64\wdsmgfw.efi'
        $expected = switch ($mode) {
            'Served' { 'Served' }
            'Missing' { 'FileNotFound' }
            'Timeout' { 'NoResponse' }
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
    }
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

Write-Host 'PASS -- protected DP checks use a bounded SYSTEM transport; scoped TFTP replies, actual CLIXML output, worker errors, deadlines, and cleanup are verified.'
