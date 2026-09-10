#requires -Version 7.4
[CmdletBinding()]
param (
    [Parameter(Mandatory)][string] $Configuration,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $GateName,
    [Parameter(Mandatory)][string] $GateReadyName,
    [int] $StartPhase = 0,
    [int[]] $Phase,
    [switch] $KeepFailedVMs
)

function Assert-MemLabsDeploymentLease {
    $operationId = [Environment]::GetEnvironmentVariable('MEMLABS_LIVEOPS_OPERATION_ID', [EnvironmentVariableTarget]::Process)
    $leasePath = [Environment]::GetEnvironmentVariable('MEMLABS_LIVEOPS_LEASE_PATH', [EnvironmentVariableTarget]::Process)
    $handoffToken = [Environment]::GetEnvironmentVariable('MEMLABS_LIVEOPS_HANDOFF_TOKEN', [EnvironmentVariableTarget]::Process)
    $ownerPid = [Environment]::GetEnvironmentVariable('MEMLABS_LIVEOPS_OWNER_PID', [EnvironmentVariableTarget]::Process)
    $ownerStartUtc = [Environment]::GetEnvironmentVariable('MEMLABS_LIVEOPS_OWNER_START_UTC', [EnvironmentVariableTarget]::Process)
    if (-not $operationId -or -not $leasePath -or -not $handoffToken -or -not $ownerPid -or -not $ownerStartUtc) {
        throw 'Deployment child requires an active Live Ops lease handoff.'
    }

    $owner = Get-Content -LiteralPath $leasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $handoffHash = [Convert]::ToHexString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($handoffToken))) }
    finally { $sha256.Dispose() }
    if ($owner.State -ne 'Active' -or $owner.OperationId -ne $operationId -or $owner.HandoffHash -ne $handoffHash) {
        throw 'Deployment child Live Ops lease handoff does not match the active owner.'
    }

    $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
    $parentProcess = Get-Process -Id $currentProcess.ParentProcessId -ErrorAction Stop
    $expectedStart = [datetimeoffset]::Parse($ownerStartUtc).UtcDateTime
    $actualStart = $parentProcess.StartTime.ToUniversalTime()
    if ([int]$owner.PID -ne $parentProcess.Id -or [int]$ownerPid -ne $parentProcess.Id) {
        throw 'Deployment child parent PID does not match the active Live Ops lease owner.'
    }
    if ([math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 1) {
        throw 'Deployment child parent start time does not match the Live Ops handoff.'
    }
    $leaseOwnerStart = if ($owner.ProcessStartUtc -is [datetime]) {
        ([datetime]$owner.ProcessStartUtc).ToUniversalTime()
    }
    else {
        [datetimeoffset]::Parse([string]$owner.ProcessStartUtc).UtcDateTime
    }
    if ([math]::Abs(($actualStart - $leaseOwnerStart).TotalSeconds) -gt 1) {
        throw 'Deployment child parent start time does not match the active Live Ops lease owner.'
    }
}

try {
    Assert-MemLabsDeploymentLease

    $startGate = [Threading.EventWaitHandle]::OpenExisting($GateName)
    $gateReady = [Threading.EventWaitHandle]::OpenExisting($GateReadyName)
    try {
        if (-not $gateReady.Set()) { throw 'Deployment child could not acknowledge the start gate.' }
        if (-not $startGate.WaitOne([TimeSpan]::FromMinutes(2))) {
            throw 'Deployment child start gate was not released within 2 minutes.'
        }
    }
    finally {
        $gateReady.Dispose()
        $startGate.Dispose()
    }

    $arguments = @{ Configuration = $Configuration; NoWindowResize = $true; NoSnapshot = $true }
    if ($StartPhase) { $arguments.StartPhase = $StartPhase }
    if ($Phase) { $arguments.Phase = $Phase }
    if ($KeepFailedVMs) { $arguments.KeepFailedVMs = $true }

    & (Join-Path (Split-Path -Parent $PSScriptRoot) 'New-Lab.ps1') @arguments *> $OutputPath
    exit $LASTEXITCODE
}
catch {
    $bootstrapError = ($_ | Out-String).Trim()
    "DEPLOYMENT CHILD FAILURE:`r`n$bootstrapError" | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    [Console]::Error.WriteLine($bootstrapError)
    exit 1
}