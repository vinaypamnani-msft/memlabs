<#
.SYNOPSIS
    Verifies that VMBuild.cmd survives being replaced while it is running.
.DESCRIPTION
    Builds a sandbox launcher from the production snapshot bootstrap, runs it with
    an argument containing spaces, and atomically replaces the live launcher from
    inside the stable copy. The test fails if execution continues in the stale
    snapshot, loses the argument, skips the replacement, or leaves a snapshot behind.
#>
[CmdletBinding()]
param(
    [string]$LauncherPath,
    [ValidateRange(0, 255)]
    [int]$ReplacementExitCode = 0,
    [switch]$ComparatorError,
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
$handoffStartIndex = -1
$handoffEndIndex = -1
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
for ($lineIndex = $stableLabelIndex; $lineIndex -lt $sourceLines.Count; $lineIndex++) {
    if ($sourceLines[$lineIndex] -eq 'git diff --no-index --quiet -- "%~f0" "%MEMLABS_VMBUILD_ROOT%VMBuild.cmd" >NUL 2>&1') {
        $handoffStartIndex = $lineIndex
        continue
    }
    if ($handoffStartIndex -ge 0 -and $sourceLines[$lineIndex] -eq ':LauncherCurrent') {
        $handoffEndIndex = $lineIndex
        break
    }
}
if ($handoffStartIndex -lt 0 -or $handoffEndIndex -lt $handoffStartIndex) {
    Write-Host "FAIL: '$resolvedLauncher' has no self-update handoff block." -ForegroundColor Red
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

    $handoffLines = @($sourceLines[$handoffStartIndex..$handoffEndIndex])
    if ($ComparatorError) {
        $handoffLines[0] = 'cmd.exe /D /C EXIT 2'
    }

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
        ':ReplacementConfirmed'
    ) + $handoffLines + @(
        '>>"%MEMLABS_TEST_RESULT%" ECHO STALE_BODY_CONTINUED',
        'EXIT /B 0'
    )
    Write-AsciiBatchFile -Path $fixturePath -Lines $fixtureLines
    Write-AsciiBatchFile -Path $replacementPath -Lines @(
        '@ECHO OFF',
        'IF /I "%~f0"=="%MEMLABS_VMBUILD_SNAPSHOT%" GOTO ReplacementSnapshot',
        'SET "MEMLABS_VMBUILD_ROOT=%~dp0"',
        'SET "MEMLABS_VMBUILD_SNAPSHOT=%TEMP%\MemLabs-VMBuild-%RANDOM%-%RANDOM%.cmd"',
        'FOR %%I IN ("%MEMLABS_VMBUILD_SNAPSHOT%") DO SET "MEMLABS_VMBUILD_SNAPSHOT=%%~fI"',
        'COPY /Y "%~f0" "%MEMLABS_VMBUILD_SNAPSHOT%" >NUL',
        'CALL "%MEMLABS_VMBUILD_SNAPSHOT%" %*',
        'SET "REPLACEMENT_EXIT=%ERRORLEVEL%"',
        'DEL /Q "%MEMLABS_VMBUILD_SNAPSHOT%" >NUL 2>&1',
        'EXIT /B %REPLACEMENT_EXIT%',
        ':ReplacementSnapshot',
        '>>"%MEMLABS_TEST_RESULT%" ECHO REPLACEMENT_RAN:%~1',
        "EXIT /B $ReplacementExitCode"
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

    $expectedLauncherExit = if ($ComparatorError -or $ReplacementExitCode -ne 0) { 1 } else { 0 }
    if ($process.ExitCode -ne $expectedLauncherExit) {
        throw "Sandbox launcher exited $($process.ExitCode), expected $expectedLauncherExit after the updated launcher returned $ReplacementExitCode."
    }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'The stable launcher body produced no result file.'
    }

    $observedLines = @(Get-Content -LiteralPath $resultPath)
    if (@($observedLines | Where-Object { $_ -eq 'ARGUMENT_OK:configuration with spaces.memlabs' }).Count -ne 1) {
        throw "The configuration argument was not preserved: $($observedLines -join '; ')"
    }
    $replacementMarkers = @($observedLines | Where-Object { $_ -eq 'REPLACEMENT_RAN:configuration with spaces.memlabs' })
    if ($ComparatorError) {
        if ($replacementMarkers.Count -ne 0) {
            throw "A comparator error launched the replacement: $($observedLines -join '; ')"
        }
    }
    elseif ($replacementMarkers.Count -ne 1) {
        throw "The updated launcher did not run with the original argument: $($observedLines -join '; ')"
    }

    $snapshotMarkers = @($observedLines | Where-Object { $_ -like 'SNAPSHOT_BODY:*' })
    if ($snapshotMarkers.Count -ne 1 -or $snapshotMarkers[0] -notlike "SNAPSHOT_BODY:$snapshotDirectory\MemLabs-VMBuild-*.cmd") {
        throw "The body did not run from the expected snapshot: $($snapshotMarkers -join '; ')"
    }

    $badMarkers = @($observedLines | Where-Object { $_ -match '^(LIVE_BODY_EXECUTED|ARGUMENT_MISMATCH:|MOVE_FAILED|STALE_BODY_CONTINUED)' })
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

if ($ComparatorError) {
    Write-Host 'PASS: VMBuild.cmd failed closed without relaunching when launcher comparison returned an error.' -ForegroundColor Green
}
else {
    Write-Host "PASS: VMBuild.cmd handed off to the updated launcher and propagated its success/failure state (child exit $ReplacementExitCode)." -ForegroundColor Green
}
if ($KeepArtifact) { Write-Host "artifact: $sandbox" }
exit 0