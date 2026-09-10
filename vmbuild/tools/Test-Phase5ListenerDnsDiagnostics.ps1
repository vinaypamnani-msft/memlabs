<#
.SYNOPSIS
    Verifies that Phase 5 preserves per-DC repadmin diagnostics.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-ListenerDns {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Test-ReplicationDiagnosticContract {
    param([string]$Source)

    $capturesOutputAndExit = $Source -match '(?s)\$ErrorActionPreference\s*=\s*''Continue''.*?\$replicationOutput\s*=\s*@\(repadmin /syncall \$dcName /AdeP 2>&1\)\s*\r?\n\s*\$replicationExitCode\s*=\s*\$LASTEXITCODE'
    $returnsTargetResult = $Source -match '(?s)\[pscustomobject\]@\{\s*DC\s*=\s*\$dcName\s*ExitCode\s*=\s*\$replicationExitCode\s*Output\s*=\s*\(\$replicationOutput -join'
    $receiveOffset = $Source.IndexOf('$replicationResults = @(Receive-Job $replJob', [StringComparison]::Ordinal)
    $removeOffset = $Source.IndexOf('Remove-Job $replJob', [StringComparison]::Ordinal)
    $receivesBeforeRemove = $receiveOffset -ge 0 -and $removeOffset -gt $receiveOffset
    $logsTargetEvidence = $Source -match 'repadmin /syncall.*ExitCode.*replicationDetail'

    return $capturesOutputAndExit -and $returnsTargetResult -and $receivesBeforeRemove -and $logsTargetEvidence
}

$phase5Path = Join-Path $RootPath 'DSC\phases\Phase5.ps1'
$phase5Source = Get-Content -LiteralPath $phase5Path -Raw
$legacySource = '$dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }'

Assert-ListenerDns -Condition (Test-ReplicationDiagnosticContract -Source $phase5Source) `
    -What 'VerifyListenerDns captures and logs per-DC repadmin exit code and output'
Assert-ListenerDns -Condition (-not (Test-ReplicationDiagnosticContract -Source $legacySource)) `
    -What 'Legacy discarded-output replication shape fails the diagnostic contract'

$replicationJobMatch = [regex]::Match(
    $phase5Source,
    '(?s)\$replJob\s*=\s*Start-Job\s+-ScriptBlock\s*\{(?<Body>.*?)\}\s*-ArgumentList\s*\(,\$dcShortNames\)'
)
if (-not $replicationJobMatch.Success) { throw 'VerifyListenerDns replication Start-Job block was not found.' }
$replicationJobBlock = [scriptblock]::Create($replicationJobMatch.Groups['Body'].Value)

$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-repadmin-$([guid]::NewGuid().ToString('N'))")
$originalPath = $env:PATH
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $fixturePath = Join-Path $fixtureDirectory 'repadmin.cmd'
    @'
@echo stdout-%2
@echo stderr-%2 1>&2
@if /I "%2"=="DC2" exit /b 7
@exit /b 0
'@ | Set-Content -LiteralPath $fixturePath -Encoding Ascii
    $env:PATH = "$fixtureDirectory;$originalPath"

    $dcNames = @('DC1', 'DC2')
    $replicationResults = @(& $replicationJobBlock -dcNames $dcNames)
    Assert-ListenerDns -Condition ($replicationResults.Count -eq 2) `
        -What 'Replication job returns one result per DC target'
    $dc1Result = @($replicationResults | Where-Object { $_.DC -eq 'DC1' })[0]
    $dc2Result = @($replicationResults | Where-Object { $_.DC -eq 'DC2' })[0]
    Assert-ListenerDns -Condition ($dc1Result.ExitCode -eq 0 -and $dc1Result.Output -match 'stdout-DC1' -and $dc1Result.Output -match 'stderr-DC1') `
        -What 'Successful repadmin target preserves stdout, stderr, and exit code'
    Assert-ListenerDns -Condition ($dc2Result.ExitCode -eq 7 -and $dc2Result.Output -match 'stdout-DC2' -and $dc2Result.Output -match 'stderr-DC2') `
        -What 'Failed repadmin target preserves stdout, stderr, and exit code'
}
finally {
    $env:PATH = $originalPath
    Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) { exit 1 }
exit 0