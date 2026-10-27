<#
.SYNOPSIS
    Verifies that VMBuild.cmd survives being replaced while it is running.
.DESCRIPTION
    Builds a sandbox launcher from the production snapshot bootstrap, runs it with
    an argument containing spaces, and atomically replaces the live launcher from
    inside the stable copy. The test fails if execution stays in the live file,
    loses the argument, runs the replacement, or leaves a snapshot behind.
#>
[CmdletBinding()]
param(
    [string]$LauncherPath,
    [switch]$KeepArtifact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $LauncherPath) {
    $LauncherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VMBuild.cmd'
}

function Write-AsciiBatchFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $content = ($Lines -join "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::ASCII)
}

$resolvedLauncher = (Resolve-Path -LiteralPath $LauncherPath).Path
$sourceLines = [System.IO.File]::ReadAllLines($resolvedLauncher)
$stableLabelIndex = -1
for ($lineIndex = 0; $lineIndex -lt $sourceLines.Count; $lineIndex++) {
    if ($sourceLines[$lineIndex] -eq ':RunStableLauncher') {
        $stableLabelIndex = $lineIndex
        break
    }
}
if ($stableLabelIndex -lt 0) {
    Write-Host "FAIL: '$resolvedLauncher' has no :RunStableLauncher bootstrap label." -ForegroundColor Red
    exit 2
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("MemLabs VMBuild test {0}" -f [guid]::NewGuid().ToString('N'))
$snapshotDirectory = Join-Path $sandbox 'stable snapshots'
$fixturePath = Join-Path $sandbox 'VMBuild.cmd'
$replacementPath = Join-Path $sandbox 'replacement.cmd'
$resultPath = Join-Path $sandbox 'result.txt'
$environmentNames = @('TEMP', 'TMP', 'MEMLABS_TEST_RESULT', 'MEMLABS_VMBUILD_ROOT', 'MEMLABS_VMBUILD_SNAPSHOT')
$savedEnvironment = @{}
foreach ($environmentName in $environmentNames) {
    $savedEnvironment[$environmentName] = [System.Environment]::GetEnvironmentVariable($environmentName, 'Process')
}

$standardOutput = ''
$standardError = ''
$observedLines = @()
$testFailure = $null
$process = $null

try {
    $null = New-Item -Path $snapshotDirectory -ItemType Directory -Force

    $fixtureLines = @($sourceLines[0..$stableLabelIndex]) + @(
        'IF /I NOT "%~f0"=="%MEMLABS_VMBUILD_ROOT%VMBuild.cmd" GOTO SnapshotConfirmed',
        '>>"%MEMLABS_TEST_RESULT%" ECHO LIVE_BODY_EXECUTED',
        'EXIT /B 40',
        ':SnapshotConfirmed',
        'IF /I "%~1"=="configuration with spaces.memlabs" GOTO ArgumentConfirmed',
        '>>"%MEMLABS_TEST_RESULT%" ECHO ARGUMENT_MISMATCH:%~1',
        'EXIT /B 41',
        ':ArgumentConfirmed',
        '>>"%MEMLABS_TEST_RESULT%" ECHO ARGUMENT_OK:%~1',
        '>>"%MEMLABS_TEST_RESULT%" ECHO SNAPSHOT_BODY:%~f0',
        'MOVE /Y "%MEMLABS_VMBUILD_ROOT%replacement.cmd" "%MEMLABS_VMBUILD_ROOT%VMBuild.cmd" >NUL',
        'IF NOT ERRORLEVEL 1 GOTO ReplacementConfirmed',
        '>>"%MEMLABS_TEST_RESULT%" ECHO MOVE_FAILED',
        'EXIT /B 42',
        ':ReplacementConfirmed',
        '>>"%MEMLABS_TEST_RESULT%" ECHO STABLE_BODY_COMPLETED',
        'EXIT /B 0'
    )
    Write-AsciiBatchFile -Path $fixturePath -Lines $fixtureLines
    Write-AsciiBatchFile -Path $replacementPath -Lines @(
        '@ECHO OFF',
        '>>"%MEMLABS_TEST_RESULT%" ECHO REPLACEMENT_RAN',
        'EXIT /B 99'
    )

    # The trailing separator exercises the canonicalization in the real bootstrap.
    $env:TEMP = $snapshotDirectory + '\'
    $env:TMP = $env:TEMP
    $env:MEMLABS_TEST_RESULT = $resultPath
    $env:MEMLABS_VMBUILD_ROOT = $null
    $env:MEMLABS_VMBUILD_SNAPSHOT = $null

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $env:ComSpec
    $processInfo.WorkingDirectory = $sandbox
    $processInfo.Arguments = '/D /C CALL VMBuild.cmd "configuration with spaces.memlabs"'
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    if (-not $process.Start()) {
        throw 'cmd.exe did not start.'
    }
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Sandbox launcher exited $($process.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'The stable launcher body produced no result file.'
    }

    $observedLines = @(Get-Content -LiteralPath $resultPath)
    if (@($observedLines | Where-Object { $_ -eq 'ARGUMENT_OK:configuration with spaces.memlabs' }).Count -ne 1) {
        throw "The configuration argument was not preserved: $($observedLines -join '; ')"
    }
    if (@($observedLines | Where-Object { $_ -eq 'STABLE_BODY_COMPLETED' }).Count -ne 1) {
        throw "The stable body did not complete: $($observedLines -join '; ')"
    }

    $snapshotMarkers = @($observedLines | Where-Object { $_ -like 'SNAPSHOT_BODY:*' })
    if ($snapshotMarkers.Count -ne 1 -or $snapshotMarkers[0] -notlike "SNAPSHOT_BODY:$snapshotDirectory\MemLabs-VMBuild-*.cmd") {
        throw "The body did not run from the expected snapshot: $($snapshotMarkers -join '; ')"
    }

    $badMarkers = @($observedLines | Where-Object { $_ -match '^(LIVE_BODY_EXECUTED|ARGUMENT_MISMATCH:|MOVE_FAILED|REPLACEMENT_RAN)' })
    if ($badMarkers.Count -gt 0) {
        throw "A forbidden execution path ran: $($badMarkers -join '; ')"
    }
    if ([System.IO.File]::ReadAllText($fixturePath) -notmatch 'REPLACEMENT_RAN') {
        throw 'The test never replaced the live launcher.'
    }

    $remainingSnapshots = @(Get-ChildItem -LiteralPath $snapshotDirectory -Filter 'MemLabs-VMBuild-*.cmd' -File)
    if ($remainingSnapshots.Count -gt 0) {
        throw "Snapshot cleanup failed: $($remainingSnapshots.FullName -join '; ')"
    }
}
catch {
    $testFailure = $_.Exception.Message
}
finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
    foreach ($environmentName in $environmentNames) {
        [System.Environment]::SetEnvironmentVariable($environmentName, $savedEnvironment[$environmentName], 'Process')
    }
    if (-not $KeepArtifact) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($null -ne $testFailure) {
    Write-Host "FAIL: $testFailure" -ForegroundColor Red
    if ($standardOutput) { Write-Host "stdout:`n$standardOutput" }
    if ($standardError) { Write-Host "stderr:`n$standardError" }
    if ($observedLines.Count -gt 0) { Write-Host "markers: $($observedLines -join '; ')" }
    if ($KeepArtifact) { Write-Host "artifact: $sandbox" }
    exit 1
}

Write-Host 'PASS: VMBuild.cmd completed from a stable snapshot after the live file was replaced.' -ForegroundColor Green
if ($KeepArtifact) { Write-Host "artifact: $sandbox" }
exit 0