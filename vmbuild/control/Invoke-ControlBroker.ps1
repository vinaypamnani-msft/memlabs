#requires -Version 7.4
[CmdletBinding()]
param(
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
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Copilot Control requires an elevated worker; the MCP adapter must remain unelevated.'
    }
}
finally { $identity.Dispose() }
Assert-MemLabsControlPackage -Path $PSScriptRoot -Hash $PackageHash
$paths = Get-MemLabsControlPaths -ClientSid $ClientSid
Assert-MemLabsControlProtectedPath -Path $paths.RuntimeRoot -Boundary $paths.DataRoot
Set-Location -LiteralPath $PSScriptRoot
Import-MemLabsControlHyperV
Initialize-MemLabsControlTransport

$process = Get-Process -Id $PID -ErrorAction Stop
$runtime = [ordered]@{
    version = 1
    ownerSid = $ClientSid
    pid = $PID
    startFileTime = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()
    pipeName = $paths.PipeName
    packagePath = $PSScriptRoot
    packageHash = $PackageHash
    state = 'Starting'
    activeOperation = $null
}
$listener = $null
$serverLock = $null
$state = [pscustomobject]@{
    Active = $null; History = [ordered]@{}; Stopping = $false; Runtime = $runtime
    ClientSid = $ClientSid; PackageHash = $PackageHash; PackagePath = $PSScriptRoot
}
$auditPath = Join-Path $paths.RuntimeRoot 'control.jsonl'

function Write-ControlAudit {
    param([string]$EventName, [string]$Message = '')
    $record = @{ timeUtc = [datetime]::UtcNow.ToString('o'); event = $EventName; message = $Message; ownerSid = $ClientSid; pid = $PID }
    [IO.File]::AppendAllText($auditPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Save-ControlRuntime {
    Write-MemLabsControlJson -Path $paths.RuntimeFile -Value $runtime
}

try {
    $serverLock = [IO.File]::Open((Join-Path $paths.RuntimeRoot 'worker.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $listener = [MemLabs.Control.Listener]::new($paths.PipeName, $ClientSid)
    $runtime.state = 'Ready'
    Save-ControlRuntime
    Write-ControlAudit -EventName 'Started' -Message $PackageHash
    while (-not $state.Stopping) {
        if ($null -ne $state.Active -and $state.Active.Async.IsCompleted) {
            $completion = Complete-MemLabsControlOperation -State $state
            Write-ControlAudit -EventName 'OperationCompleted' -Message ($completion.operationId + ':' + $completion.state)
            Save-ControlRuntime
        }
        if (-not $listener.Ready) {
            Start-Sleep -Milliseconds 50
            continue
        }
        $requestId = $null
        try {
            $request = $listener.ReadRequest() | ConvertFrom-Json -AsHashtable -Depth 12 -ErrorAction Stop
            if ($request -isnot [Collections.IDictionary]) { throw 'Control request must be an object.' }
            Assert-MemLabsControlKeys -Object $request -Allowed @('version', 'id', 'method', 'arguments') -Required @('version', 'id', 'method', 'arguments')
            $parsedId = [guid]::Empty
            if ($request.version -isnot [long] -or $request.version -ne 1 -or $request.id -isnot [string] -or
                -not [guid]::TryParseExact($request.id, 'D', [ref]$parsedId) -or $parsedId -eq [guid]::Empty -or
                $request.method -isnot [string] -or $request.arguments -isnot [Collections.IDictionary]) {
                throw 'Invalid control request envelope.'
            }
            $requestId = $request.id
            Assert-MemLabsControlArguments -Method $request.method -Arguments $request.arguments
            $answer = Invoke-MemLabsControlDispatch -State $state -Method $request.method -Arguments $request.arguments
            if ($request.method -cin @('start_vm', 'stop_vm')) {
                Save-ControlRuntime
                Write-ControlAudit -EventName 'OperationAccepted' -Message "$($answer.operationId) $($request.method) $($request.arguments.vmId) clientPID=$($listener.ClientProcessId)"
            }
            $response = @{ version = 1; id = $requestId; ok = $true; result = $answer }
        }
        catch {
            $failure = Get-MemLabsControlFailure -Exception $_.Exception -Phase 'Request'
            Write-ControlAudit -EventName 'RequestFailed' -Message $failure.message
            $response = @{ version = 1; id = $requestId; ok = $false; error = "$($failure.message) Next step: $($failure.remediation)"; failure = $failure }
        }
        try { $listener.Respond(($response | ConvertTo-Json -Depth 20 -Compress)) }
        catch { Write-ControlAudit -EventName 'ResponseFailed' -Message $_.Exception.Message }
        finally {
            $listener.Dispose()
            $listener = $null
        }
        if (-not $state.Stopping) { $listener = [MemLabs.Control.Listener]::new($paths.PipeName, $ClientSid) }
    }
}
catch {
    $runtime.state = 'Failed'
    $runtime.error = $_.Exception.Message
    if ($serverLock) {
        Save-ControlRuntime
        Write-ControlAudit -EventName 'Failed' -Message $_.Exception.Message
    }
    throw
}
finally {
    if ($listener) { $listener.Dispose() }
    if ($null -ne $state.Active) {
        try { $null = $state.Active.Shell.EndInvoke($state.Active.Async) }
        finally { $state.Active.Shell.Dispose() }
    }
    if ($serverLock) {
        if ($runtime.state -ne 'Failed') {
            $runtime.state = 'Stopped'
            $runtime.activeOperation = $null
            Save-ControlRuntime
            Write-ControlAudit -EventName 'Stopped'
        }
        $serverLock.Dispose()
    }
}
