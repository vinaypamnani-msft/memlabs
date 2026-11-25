#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('start_vm', 'stop_vm')][string]$Action,
    [Parameter(Mandatory)][guid]$VmId,
    [Parameter(Mandatory)][guid]$RequestId,
    [Parameter(Mandatory)][string]$ClientSid,
    [Parameter(Mandatory)][string]$PackageHash
)

$ErrorActionPreference = 'Stop'
$system = [Environment]::GetFolderPath('System')
$env:PATH = $system + ';' + [Environment]::GetFolderPath('Windows')
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') + ';' +
    [IO.Path]::Combine($system, 'WindowsPowerShell\v1.0\Modules') + ';' +
    [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'WindowsPowerShell\Modules')
. (Join-Path $PSScriptRoot 'Common.Control.ps1')
Assert-MemLabsControlPackage -Path $PSScriptRoot -Hash $PackageHash
Import-MemLabsControlHyperV
$context = [pscustomobject]@{ Failure = $null; Observed = $null; Desired = $(if ($Action -eq 'start_vm') { 'Running' } else { 'Off' }) }
$vm = Get-VM -Id $VmId -ErrorAction Stop
$operation = {
    $job = $null
    try {
        $current = Get-VM -Id $VmId -ErrorAction Stop
        if ("$($current.State)" -eq $context.Desired) { return }
        if ($Action -eq 'start_vm') {
            if ("$($current.State)" -ne 'Off') { throw "Start requires an Off VM, not '$($current.State)'." }
            $job = Start-VM -VM $current -AsJob -ErrorAction Stop
        }
        else {
            if ("$($current.State)" -ne 'Running') { throw "Graceful stop requires a Running VM, not '$($current.State)'." }
            $job = Stop-VM -VM $current -AsJob -Confirm:$false -ErrorAction Stop
        }
        if (-not (Wait-Job -Job $job -Timeout 120 -ErrorAction Stop)) {
            throw 'The VM operation exceeded 120 seconds; inspect its current state before retrying.'
        }
        $null = Receive-Job -Job $job -ErrorAction Stop
        if ($job.State -ne 'Completed') { throw "VM operation ended in job state '$($job.State)'." }
    }
    catch {
        $context.Failure = $_.Exception.Message
        throw
    }
    finally {
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted', 'Blocked')) { Stop-Job -Job $job -ErrorAction Stop }
            Remove-Job -Job $job -Force -ErrorAction Stop
        }
    }
}.GetNewClosure()
$postcondition = {
    $context.Observed = Get-VM -Id $VmId -ErrorAction Stop | Select-Object Id, Name, State
    return [bool]("$($context.Observed.State)" -eq $context.Desired)
}.GetNewClosure()
$diagnostics = {
    [pscustomobject]@{
        Failure = $context.Failure
        VM = Get-VM -Id $VmId -ErrorAction Stop | Select-Object Id, Name, State, Status
    }
}.GetNewClosure()
try {
    $result = & (Join-Path $PSScriptRoot 'Invoke-MemLabsLiveOperation.ps1') `
        -Mode Mutate -Intent "Copilot Control $Action requested by $ClientSid for $($vm.Name)" `
        -TargetType HostResource -Target @("VM:$($VmId.ToString('D'))") `
        -SessionId ("mcp-" + $RequestId.ToString('D')) `
        -Operation $operation -Postcondition $postcondition -FailureDiagnostics $diagnostics
    [pscustomobject]@{
        success = $true
        operationId = $RequestId.ToString('D')
        journalOperationId = $result.OperationId
        journalPath = $result.JournalPath
        vmId = $VmId.ToString('D')
        name = $context.Observed.Name
        state = "$($context.Observed.State)"
        postconditionPassed = $result.PostconditionPassed
    }
}
catch {
    $failure = Get-MemLabsControlFailure -Exception $_.Exception -Phase 'VmOperation'
    $message = if ($context.Failure) { $context.Failure } else { $failure.message }
    [pscustomobject]@{
        success = $false
        operationId = $RequestId.ToString('D')
        error = $message
        remediation = $failure.remediation
        code = $failure.code
        journalOperationId = $_.Exception.Data['OperationId']
        journalPath = $_.Exception.Data['JournalPath']
    }
}
