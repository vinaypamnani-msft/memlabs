#requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('Start', 'Stop', 'Status')][string]$Action = 'Start')

$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess -or -not $IsWindows) { throw 'Copilot Control requires 64-bit PowerShell 7.4+ on Windows.' }
. (Join-Path $PSScriptRoot 'Common.Control.ps1')
$paths = Get-MemLabsControlPaths
if ($Action -ne 'Start') {
    if ($Action -eq 'Status') { return (Invoke-MemLabsControlRequest -Method status) }
    if ((Invoke-MemLabsControlRequest -Method status).state -eq 'Stopped') { return [pscustomobject]@{ state = 'Stopped' } }
    $null = Invoke-MemLabsControlRequest -Method shutdown
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        if ($null -eq (Get-MemLabsControlRuntime)) { return [pscustomobject]@{ state = 'Stopped' } }
        Start-Sleep -Milliseconds 50
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'The stop request was accepted, but worker shutdown has not yet been verified.'
}

$package = Get-MemLabsControlPackage
$runtime = Get-MemLabsControlRuntime
$alreadyRunning = $false
if ($null -ne $runtime) {
    $existing = Get-Process -Id $runtime.pid -ErrorAction SilentlyContinue
    if ($existing -and $existing.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $runtime.startFileTime) {
        $status = Invoke-MemLabsControlRequest -Method status
        if ($status.packageHash -cne $package.Hash) { throw 'A different control version is active. Stop it before starting the updated version.' }
        $alreadyRunning = $true
    }
}
if (-not $alreadyRunning) {
    $attempt = [guid]::NewGuid()
    $loader = New-MemLabsControlBootstrap -Package $package -ClientSid $paths.ClientSid -AttemptId $attempt
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $elevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    if ($elevated) {
        # Keep an already-elevated VMBuild UI as the worker's real, persistent ancestor.
        & ([scriptblock]::Create($loader)) | Out-Null
    }
    else {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader))
        if ($encoded.Length -gt 30000) { throw 'The frozen UAC bootstrap exceeds the Windows command-line limit; it was not launched.' }
        $installer = Start-Process -FilePath $paths.PowerShell -Verb RunAs `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -PassThru -ErrorAction Stop
        $installer.WaitForExit()
        $exitCode = $installer.ExitCode
    }
    $attemptPath = Join-Path $paths.RuntimeRoot ("install-" + $attempt.ToString('D') + '.json')
    if (-not (Test-Path -LiteralPath $attemptPath)) {
        throw 'The installer did not publish its protected attempt result. Elevation was cancelled or protected-state setup failed; no worker success is assumed.'
    }
    Assert-MemLabsControlProtectedPath -Path $attemptPath -Boundary $paths.DataRoot
    $installation = Get-Content -LiteralPath $attemptPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($installation.attemptId -cne $attempt.ToString('D') -or -not $installation.success -or (-not $elevated -and $exitCode -ne 0)) {
        throw "Copilot Control installation failed: $($installation.error)"
    }
    $status = Invoke-MemLabsControlRequest -Method status
    if ($status.state -notin @('Ready', 'Busy')) { throw 'The worker exited after installation; MCP registration was not reported as successful.' }
}
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
try {
    $registration = @(Add-MemLabsControlMcpConfiguration -RepositoryRoot $repositoryRoot -AdapterPath (Join-Path $PSScriptRoot 'Invoke-ControlMcp.ps1'))
}
catch { throw "The control worker is $($status.state), but automatic MCP registration failed: $($_.Exception.Message)" }
[pscustomobject]@{
    state = $status.state
    alreadyRunning = $alreadyRunning
    packageHash = $package.Hash
    mcpConfiguration = $registration
    message = 'MCP is registered without changing VS Code trust or tool approvals. Keep VS Code unelevated.'
}
