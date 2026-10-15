#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guestPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
$hostPath = Join-Path $root 'common\Common.ScriptBlocks.ps1'

function Get-TestAst {
    param([string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    return $ast
}

function Import-TestFunction {
    param($Ast, [string] $Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$guestAst = Get-TestAst $guestPath
$hostAst = Get-TestAst $hostPath
. (Import-TestFunction $guestAst 'Test-MemLabsOutOfMemoryError')
. (Import-TestFunction $guestAst 'Request-MemLabsGuestMemoryRecovery')
. (Import-TestFunction $guestAst 'Get-MemLabsProjectedCimRows')
. (Import-TestFunction $hostAst 'Invoke-MemLabsGuestMemoryRecovery')

$script:Statuses = [Collections.Generic.List[string]]::new()
function Write-DscStatus {
    param($Status, [switch] $Failure, [switch] $Warning, [switch] $NoStatus)
    $script:Statuses.Add("$Status")
}
function Write-Log {
    param($Message, [switch] $Failure, [switch] $Warning, [switch] $OutputStream)
    if ($Failure) { $script:HostFailed = $true }
}
function Start-Sleep { param([int] $Seconds) }

$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-cim-recovery-$PID"
function Join-Path {
    param([string] $Path, [string] $ChildPath)
    if ($Path -eq 'C:\staging\DSC') { $Path = $script:TestRoot }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}

try {
    $null = New-Item -ItemType Directory -Path $script:TestRoot
    $expectedPath = Join-Path $script:TestRoot 'ScriptWorkflow.expected.runid'
    $requestPath = Join-Path $script:TestRoot 'ScriptWorkflow.memory-recovery.json'
    Set-Content -LiteralPath $expectedPath -Value 'fixture-run'

    foreach ($message in @('Out of memory', 'OutOfMemoryException', '0x80041006', '0x8007000E', 'not enough storage')) {
        try { throw $message }
        catch { Assert-True (Test-MemLabsOutOfMemoryError $_) "Did not recognize '$message'." }
    }
    try { throw [InvalidOperationException]::new('wrapper', [OutOfMemoryException]::new('inner')) }
    catch { Assert-True (Test-MemLabsOutOfMemoryError $_) 'Did not recognize an inner OOM exception.' }
    try { throw 'Access denied' }
    catch { Assert-True (-not (Test-MemLabsOutOfMemoryError $_)) 'Access denied was classified as memory exhaustion.' }

    $script:QueryCalls = 0
    $script:QueryFailures = 2
    $script:QueryError = 'Out of memory'
    function Get-CimInstance {
        param($Namespace, $ClassName, $Property, $OperationTimeoutSec, $ErrorAction)
        $script:QueryCalls++
        if ($script:QueryCalls -le $script:QueryFailures) { throw $script:QueryError }
        return [pscustomobject]@{ ServerNALPath = '\\fixture'; Unrequested = 'discard' }
    }
    $rows = @(Get-MemLabsProjectedCimRows -Namespace 'root\SMS\site_PRI' -ClassName SMS_DistributionPoint -Property ServerNALPath -RetrySeconds 0)
    Assert-True ($script:QueryCalls -eq 3 -and $rows.Count -eq 1 -and
        $rows[0].PSObject.Properties.Name -notcontains 'Unrequested') 'Transient OOM did not retry and project rows.'
    Assert-True (-not (Test-Path -LiteralPath $requestPath)) 'Successful local retries requested a reboot.'

    $script:QueryCalls = 0
    $script:QueryFailures = 10
    $threw = $false
    try { Get-MemLabsProjectedCimRows -Namespace 'root\SMS\site_PRI' -ClassName SMS_DistributionPoint -Property ServerNALPath -RetrySeconds 0 }
    catch { $threw = $_.Exception.Message -eq 'Out of memory' }
    Assert-True ($threw -and $script:QueryCalls -eq 3) 'Exhaustion did not preserve the original error after exactly three attempts.'
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
    Assert-True ($request.RunId -eq 'fixture-run' -and $request.Reason -eq 'OutOfMemory' -and
        $request.Context -eq 'root\SMS\site_PRI/SMS_DistributionPoint') 'Recovery request lost its run or query identity.'
    Assert-True ($request.Origin.ProcessId -eq $PID -and $request.Origin.Error -eq 'Out of memory' -and
        $request.Origin.PrivateMB -gt 0 -and $request.Origin.ManagedMB -gt 0) 'Recovery request lost the failing process memory snapshot.'
    Assert-True (-not (Test-Path -LiteralPath "$requestPath.tmp")) 'Atomic request left its temporary file behind.'
    Remove-Item -LiteralPath $requestPath

    $script:QueryCalls = 0
    $script:QueryError = 'Access denied'
    $threw = $false
    try { Get-MemLabsProjectedCimRows -Namespace fixture -ClassName fixture -Property Name -RetrySeconds 0 }
    catch { $threw = $_.Exception.Message -eq 'Access denied' }
    Assert-True ($threw -and $script:QueryCalls -eq 1 -and -not (Test-Path -LiteralPath $requestPath)) 'Non-memory error was hidden, retried or requested reboot.'

    $script:RestartCalls = 0
    $script:RestartSucceeds = $true
    $script:ProbeCalls = 0
    $script:NeverReady = $false
    $script:ResumeFails = $false
    $script:GuestBlocks = [Collections.Generic.List[scriptblock]]::new()
    function Restart-VM2Smart {
        param($Name, $Reason, [switch] $AllowTurnOff)
        Assert-True (-not $AllowTurnOff) 'Memory recovery enabled hard power-off.'
        $script:RestartCalls++
        return $script:RestartSucceeds
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, [switch] $AsJob, $TimeoutSeconds, [switch] $SuppressLog, [scriptblock] $ScriptBlock, $ArgumentList)
        $script:GuestBlocks.Add($ScriptBlock)
        if ($ScriptBlock.ToString() -match 'Win32_OperatingSystem') {
            $script:ProbeCalls++
            return [pscustomobject]@{ ScriptBlockFailed = ($script:NeverReady -or $script:ProbeCalls -eq 1); ScriptBlockOutput = 'Ready'; ErrorDetails = 'booting' }
        }
        return [pscustomobject]@{ ScriptBlockFailed = $script:ResumeFails; ScriptBlockOutput = 'Resumed'; ErrorDetails = 'resume fixture failure' }
    }
    Invoke-MemLabsGuestMemoryRecovery -VmName fixture -DomainName fixture.test -RunId fixture-run
    Assert-True ($script:RestartCalls -eq 1 -and $script:ProbeCalls -eq 2) 'Host did not wait for readiness after exactly one graceful restart.'
    $resumeBlock = $script:GuestBlocks[$script:GuestBlocks.Count - 1]
    $resumeText = $resumeBlock.ToString()
    Assert-True ($resumeText -match 'actualRunId -ne \$expectedRunId' -and
        $resumeText -match 'Stop-DscConfiguration -Force' -and
        $resumeText -match 'Start-DscConfiguration -UseExisting -Force' -and
        $resumeText -notmatch 'Restore-') 'Recovery does not guard its RunId and resume existing DSC state.'

    $script:DscStops = 0
    $script:TaskStops = 0
    $script:DscStarts = 0
    function Stop-DscConfiguration { param([switch] $Force); $script:DscStops++ }
    function Get-ScheduledTask { param($TaskName); [pscustomobject]@{ State = 'Running' } }
    function Stop-ScheduledTask { param($TaskName); $script:TaskStops++ }
    function Start-DscConfiguration {
        param([switch] $UseExisting, [switch] $Force)
        Assert-True ($UseExisting -and $Force) 'Resume did not use the existing configuration.'
        $script:DscStarts++
    }
    $workflowPath = Join-Path $script:TestRoot 'ScriptWorkflow.json'
    Set-Content -LiteralPath $workflowPath -Value '{"InstallSCCM":{"Status":"Completed"}}'
    $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath
    $null = & $resumeBlock fixture-run
    Assert-True ($script:DscStops -eq 1 -and $script:TaskStops -eq 1 -and $script:DscStarts -eq 1 -and
        -not (Test-Path -LiteralPath $requestPath)) 'Guest did not stop old work, consume the request and resume DSC.'
    Assert-True ((Get-Content -LiteralPath $workflowPath -Raw | ConvertFrom-Json).InstallSCCM.Status -eq 'Completed') 'Resume discarded completed workflow steps.'
    $threw = $false
    try { $null = & $resumeBlock stale-run }
    catch { $threw = $_.Exception.Message -match 'RunId changed' }
    Assert-True ($threw -and $script:DscStarts -eq 1) 'A changed RunId resumed the wrong deployment.'

    $script:RestartSucceeds = $false
    $threw = $false
    try { Invoke-MemLabsGuestMemoryRecovery -VmName fixture -DomainName fixture.test -RunId fixture-run }
    catch { $threw = $_.Exception.Message -match 'could not restart.*gracefully' }
    Assert-True $threw 'Graceful reboot failure was hidden.'
    $script:RestartSucceeds = $true
    $script:ResumeFails = $true
    $threw = $false
    try { Invoke-MemLabsGuestMemoryRecovery -VmName fixture -DomainName fixture.test -RunId fixture-run }
    catch { $threw = $_.Exception.Message -match 'resuming.*failed' }
    Assert-True $threw 'DSC resume failure was hidden.'
    $script:ResumeFails = $false
    $script:NeverReady = $true
    $threw = $false
    try { Invoke-MemLabsGuestMemoryRecovery -VmName fixture -DomainName fixture.test -RunId fixture-run -ReadyTimeoutSeconds 1 }
    catch { $threw = $_.Exception.Message -match 'timed out waiting' }
    Assert-True $threw 'Guest readiness timeout was hidden.'

    # Execute the production monitor branch, not a separate copy of its policy.
    $branches = @($hostAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -match '^\$Phase -eq 8 -and \$expectedRunId -and \$memoryRequest'
            }, $true))
    Assert-True ($branches.Count -eq 1) 'Could not locate the monitor recovery policy.'
    $policy = [scriptblock]::Create("param(`$Phase, `$expectedRunId, `$memoryRequest)`n" +
        '$memoryRecoveryCount = 0; $currentItem = [pscustomobject]@{ vmName = "fixture" }; $domainName = "fixture.test"; $invocations = 0' +
        "`nforeach (`$poll in 1..2) { $($branches[0].Extent.Text); `$invocations++ }; return `$memoryRecoveryCount")
    function Invoke-MemLabsGuestMemoryRecovery { param($VmName, $DomainName, $RunId) }
    $script:DiagnosticTriggers = [Collections.Generic.List[string]]::new()
    function Save-MemLabsGuestMemoryDiagnostics {
        param($VmName, $DomainName, $Request, $Trigger)
        $script:DiagnosticTriggers.Add($Trigger)
    }
    $script:HostFailed = $false
    $policyResult = & $policy 8 fixture-run ([pscustomobject]@{ RunId = 'fixture-run'; Reason = 'OutOfMemory'; Context = 'fixture' })
    Assert-True ($policyResult -eq 1 -and $script:HostFailed) 'A repeated request did not fail after one recovery.'
    Assert-True (($script:DiagnosticTriggers -join ',') -eq 'BeforeRecovery,RecoveryExhausted') 'Memory evidence was not captured before reboot and again on terminal exhaustion.'
    foreach ($case in @(
            @{ Phase = 9; RunId = 'fixture-run'; Reason = 'OutOfMemory' },
            @{ Phase = 8; RunId = 'stale-run'; Reason = 'OutOfMemory' },
            @{ Phase = 8; RunId = 'fixture-run'; Reason = 'AccessDenied' }
        )) {
        $script:HostFailed = $false
        $policyResult = & $policy $case.Phase fixture-run ([pscustomobject]@{ RunId = $case.RunId; Reason = $case.Reason })
        Assert-True ($policyResult -eq 0 -and -not $script:HostFailed) 'Wrong-phase, stale or non-memory request triggered recovery.'
    }
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}

Write-Host 'PASS -- guest CIM memory retries and bounded host reboot recovery.'
