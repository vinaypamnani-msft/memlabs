[CmdletBinding()]
param([switch]$Watch)

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'Internet policy recovery requires PowerShell 7.4 or newer.'
}
$library = Join-Path $PSScriptRoot 'Common.Internet.ps1'
if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
    $library = Join-Path (Split-Path $PSScriptRoot -Parent) 'common\Common.Internet.ps1'
}
. $library
$ErrorActionPreference = 'Stop'
$signature = Get-MemLabsInternetRuntimeSignature -Library $library -EntryPoint $PSCommandPath
$process = Get-Process -Id $PID
do {
    try {
        Repair-MemLabsInternetPolicies
        if ($Watch) {
            Write-MemLabsInternetJson -Path (Join-Path (Get-MemLabsInternetStateRoot) 'recovery.ready.json') -Value @{
                Signature = $signature; BootId = (Get-MemLabsInternetBootId); Tick = [Environment]::TickCount64
                Owner = @{ Id = $PID; StartTicks = $process.StartTime.ToUniversalTime().Ticks.ToString() }
            }
        }
    }
    catch {
        Write-Warning "Internet policy recovery failed; VMs are not stopped or disconnected: $($_.Exception.Message)"
        if (-not $Watch) { throw }
    }
    if ($Watch) { Start-Sleep -Seconds 5 }
} while ($Watch)
