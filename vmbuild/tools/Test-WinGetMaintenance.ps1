<#
.SYNOPSIS
    Verifies unattended WinGet upgrades for matched host applications.
.DESCRIPTION
    Loads the shipped maintenance function through the PowerShell AST and exercises it
    with a mocked WinGet command. No packages are changed on the test host.
#>
[CmdletBinding()]
param (
    [string] $RootPath,
    [string] $SourceFile = 'Invoke-Maintenance.ps1'
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = ("$Expected" -eq "$Actual")
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Assert-Throws {
    param ([scriptblock] $Action, [string] $What)

    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-Equal $true $threw $What
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref] $tokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wantedFunctions = @(
    'Get-MemLabsUserWinGetTimestampPath',
    'Invoke-MemLabsDueUserWinGetMaintenance',
    'Invoke-WinGetMaintenance',
    'New-MemLabsMaintenanceMutex',
    'Save-WinGetFailureDiagnostics',
    'Test-MemLabsUserWinGetMaintenanceDue'
)
$loadedFunctions = @()
foreach ($functionNode in $ast.FindAll({
            param ($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    if ($wantedFunctions -notcontains $functionNode.Name) { continue }
    . ([scriptblock]::Create($functionNode.Extent.Text))
    $loadedFunctions += $functionNode.Name
}
$missingFunctions = @($wantedFunctions | Where-Object { $loadedFunctions -notcontains $_ })
if ($missingFunctions.Count -gt 0) {
    Write-Host "SETUP FAIL: functions not found in ${SourceFile}: $($missingFunctions -join ', ')" -ForegroundColor Red
    exit 2
}

$script:WingetAvailable = $true
$script:WingetCalls = @()
$script:WingetExitCode = 0
$script:WingetOutput = @()
$script:WingetSource = $null
$script:Logs = @()
$script:StartedProcess = $null

function Get-Command {
    param (
        [string] $Name,
        [string] $CommandType,
        [string] $ErrorAction
    )

    if (-not $script:WingetAvailable) { return $null }

    return [pscustomobject]@{
        Source = $(if ($null -ne $script:WingetSource) { $script:WingetSource } else { {
            $script:WingetCalls += ,@($args)
            $global:LASTEXITCODE = $script:WingetExitCode
            $script:WingetOutput
        } })
    }
}

function Start-Process {
    param (
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WindowStyle
    )

    $script:StartedProcess = [pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        WindowStyle = $WindowStyle
    }
}

function Write-LogMessage {
    param ([string] $Message, [string] $Level = 'INFO')
    $script:Logs += [pscustomobject]@{ Message = $Message; Level = $Level }
}

function Reset-Fixture {
    $script:WingetAvailable = $true
    $script:WingetCalls = @()
    $script:WingetExitCode = 0
    $script:WingetOutput = @()
    $script:WingetSource = $null
    $script:Logs = @()
    $script:StartedProcess = $null
}

function Get-FixtureWinGetLogPath {
    $runId = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    return (Join-Path $fixtureRoot "WinGetUpgrade_$runId.log")
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('MemLabs WinGet maintenance test {0}' -f [guid]::NewGuid().ToString('N'))
$savedTemp = $env:TEMP
$savedLocalAppData = $env:LOCALAPPDATA
$savedFixtureNativeLog = $env:MEMLABS_WINGET_TEST_NATIVE_LOG
$null = New-Item -Path $fixtureRoot -ItemType Directory -Force
$env:TEMP = $fixtureRoot
$env:LOCALAPPDATA = $fixtureRoot
$env:MEMLABS_WINGET_TEST_NATIVE_LOG = $null
$script:logsPath = $fixtureRoot

Reset-Fixture
$script:WingetAvailable = $false
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal 0 $script:WingetCalls.Count 'missing WinGet cannot launch an upgrade'
Assert-Equal 'WARNING' @($script:Logs | Select-Object -Last 1)[0].Level 'missing WinGet is surfaced as a warning'
Assert-Equal $true ($script:Logs[-1].Message -match "maintenance task's user.*Get-AppxPackage") 'missing WinGet diagnoses the scheduled-user registration requirement'

Reset-Fixture
$script:WingetExitCode = -1978335189
$script:WingetOutput = @('No applicable upgrade found.')
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal 1 $script:WingetCalls.Count 'available WinGet is invoked once'
$expectedArguments = 'upgrade --all --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --verbose-logs'
Assert-Equal $expectedArguments ($script:WingetCalls[0] -join ' ') 'WinGet upgrades all matched packages from the community source unattended'
Assert-Equal $true ($script:Logs[-1].Message -like '*already current*') 'WinGet no-update result is treated as current'

Reset-Fixture
$script:WingetOutput = @('Successfully installed')
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal $true ($script:Logs[-1].Message -like '*completed successfully*') 'successful WinGet upgrades are logged'
$scheduledLog = @(Get-ChildItem -LiteralPath $fixtureRoot -Filter 'WinGetUpgrade_*.log' -File | Sort-Object LastWriteTime -Descending)[0]
Assert-Equal $true ($null -ne $scheduledLog) 'scheduled maintenance creates a dedicated WinGet log'
$scheduledLogText = Get-Content -LiteralPath $scheduledLog.FullName -Raw
Assert-Equal $true $scheduledLogText.Contains('Successfully installed') 'scheduled WinGet output is persisted'
Assert-Equal $true $scheduledLogText.Contains('Exit code: 0') 'scheduled WinGet exit code is persisted'
Assert-Equal $true ($script:Logs[-1].Message -like "*$($scheduledLog.FullName)*") 'scheduled maintenance references the dedicated log'
Assert-Equal 0 @(Get-ChildItem -LiteralPath $fixtureRoot -Directory -Filter '*.diagnostics').Count 'successful WinGet runs do not collect native failure diagnostics'

Reset-Fixture
$script:WingetExitCode = -1978335188
$script:WingetOutput = @('One or more package upgrades failed.')
Assert-Throws { Invoke-WinGetMaintenance -WaitForCompletion } 'a partial WinGet upgrade failure is surfaced'

Reset-Fixture
$script:WingetExitCode = 42
$script:WingetOutput = @('simulated failure')
Assert-Throws { Invoke-WinGetMaintenance -WaitForCompletion } 'an unexpected WinGet failure is surfaced'

try {
    $nativeDirectory = Join-Path $fixtureRoot 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
        -Started (Get-Date).AddSeconds(-1) -Finished (Get-Date) -Failure 'original internal error: -1978335231'
    $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
    Assert-Equal 'original internal error: -1978335231' $summary.Failure 'missing native logs do not replace the original WinGet failure'
    Assert-Equal 'fixture-winget.exe' $summary.Executable 'failure diagnostics identify the exact executable'
    Assert-Equal $PSVersionTable.PSVersion.ToString() $summary.PowerShellVersion 'failure diagnostics identify the PowerShell engine'
    Assert-Equal $true (-not [string]::IsNullOrWhiteSpace($summary.Identity)) 'failure diagnostics identify the maintenance user'
    Assert-Equal $fixtureRoot $summary.LocalAppData 'failure diagnostics identify the executing profile'
    Assert-Equal $nativeDirectory $summary.NativeLogDirectory 'failure diagnostics identify the packaged native log location'
    Assert-Equal $false $summary.UpgradeLogFound 'missing native logs cannot look like successful evidence collection'
    Assert-Equal $true (($diagnostics.Warnings -join ' ') -match 'collection failed.+No native upgrade --all log') 'missing native logs produce explicit collection warnings'

    $null = New-Item -Path $nativeDirectory -ItemType Directory -Force
    $sourceListLog = Join-Path $nativeDirectory 'WinGet-source-list.log'
    Set-Content -LiteralPath $sourceListLog -Value 'Command line Args: winget source list' -Encoding utf8
    $oldUpgradeLog = Join-Path $nativeDirectory 'WinGet-old-upgrade.log'
    Set-Content -LiteralPath $oldUpgradeLog -Value 'Command line Args: winget upgrade --all' -Encoding utf8
    [IO.File]::SetLastWriteTimeUtc($oldUpgradeLog, [DateTime]::UtcNow.AddMinutes(-10))
    $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
        -Started (Get-Date).AddSeconds(-1) -Finished (Get-Date) -Failure 'source-list-only failure'
    $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
    Assert-Equal 1 @($summary.Files).Count 'only native logs overlapping the failed run are collected'
    Assert-Equal $false $summary.UpgradeLogFound 'a concurrent successful source-list log is not attributed to the failed upgrade'
    Assert-Equal $false $summary.Files[0].MatchesUpgradeCommand 'native diagnostic command association is explicit'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $diagnostics.Directory 'WinGet-old-upgrade.log')) 'historical upgrade logs are not copied as new failure evidence'

    $upgradeLog = Join-Path $nativeDirectory 'WinGet-upgrade.log'
    Set-Content -LiteralPath $upgradeLog -Value 'Command line Args: "C:\Program Files\winget.exe" upgrade --all --source winget' -Encoding utf8
    $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
        -Started (Get-Date).AddSeconds(-1) -Finished (Get-Date) -Failure 'matched upgrade failure'
    $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
    Assert-Equal $true $summary.UpgradeLogFound 'a matching native upgrade command is recognized'
    Assert-Equal ([IO.File]::ReadAllText($upgradeLog)) ([IO.File]::ReadAllText((Join-Path $diagnostics.Directory 'WinGet-upgrade.log'))) 'native diagnostics are copied without changing their content'
    $lockedLog = [IO.File]::Open($upgradeLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
            -Started (Get-Date).AddSeconds(-1) -Finished (Get-Date) -Failure 'locked log original failure'
        $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
        Assert-Equal 'locked log original failure' $summary.Failure 'a locked native log does not mask the original failure'
        Assert-Equal $true (($diagnostics.Warnings -join ' ') -match 'Could not collect native log') 'native copy failures are explicit'
        Assert-Equal $false $summary.UpgradeLogFound 'an inaccessible upgrade log is not reported as collected'
    }
    finally { $lockedLog.Dispose() }

    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'LimitProfile'
    try {
        $limitNativeDirectory = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
        $null = New-Item -Path $limitNativeDirectory -ItemType Directory -Force
        foreach ($index in 1..12) {
            Set-Content -LiteralPath (Join-Path $limitNativeDirectory "$index.log") -Value 'Command line Args: winget upgrade --all' -Encoding utf8
        }
        $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
            -Started (Get-Date).AddMinutes(-1) -Finished (Get-Date) -Failure 'file-count-limit failure'
        $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
        Assert-Equal 10 @($summary.Files).Count 'native diagnostic collection enforces the ten-file limit'
        Assert-Equal $true (($diagnostics.Warnings -join ' ') -match 'newest 10 of 12') 'excess native diagnostic files are reported'
        foreach ($file in @(Get-ChildItem -LiteralPath $limitNativeDirectory -File)) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
        foreach ($index in 1..10) {
            $largeLog = [IO.File]::Open((Join-Path $limitNativeDirectory "$index.log"), [IO.FileMode]::CreateNew)
            try {
                $header = [Text.Encoding]::UTF8.GetBytes("Command line Args: winget upgrade --all`n")
                $largeLog.Write($header, 0, $header.Length)
                $largeLog.SetLength(4MB + 1)
                [void]$largeLog.Seek(-4, [IO.SeekOrigin]::End)
                $tail = [Text.Encoding]::ASCII.GetBytes('TAIL')
                $largeLog.Write($tail, 0, $tail.Length)
            }
            finally { $largeLog.Dispose() }
        }
        $diagnostics = Save-WinGetFailureDiagnostics -WinGetPath 'fixture-winget.exe' -LogFile (Get-FixtureWinGetLogPath) `
            -Started (Get-Date).AddMinutes(-1) -Finished (Get-Date) -Failure 'byte-limit failure'
        $summary = Get-Content -LiteralPath (Join-Path $diagnostics.Directory 'summary.json') -Raw | ConvertFrom-Json
        $copiedLogs = @(Get-ChildItem -LiteralPath $diagnostics.Directory -Filter '*.log' -File)
        Assert-Equal 32MB ($copiedLogs | Measure-Object Length -Sum).Sum 'native diagnostic copies enforce the exact 32 MiB run limit'
        Assert-Equal 0 @($copiedLogs | Where-Object Length -gt 4MB).Count 'no native diagnostic copy exceeds 4 MiB'
        Assert-Equal 8 $copiedLogs.Count 'copying stops at the aggregate native diagnostic budget'
        Assert-Equal 8 @($summary.Files | Where-Object Truncated).Count 'every truncated native log is identified'
        Assert-Equal $true $summary.UpgradeLogFound 'truncated logs retain command association from their original header'
        $copiedTail = [IO.File]::OpenRead($copiedLogs[0].FullName)
        try {
            [void]$copiedTail.Seek(-4, [IO.SeekOrigin]::End)
            $tailBytes = [byte[]]::new(4)
            [void]$copiedTail.Read($tailBytes, 0, 4)
            Assert-Equal 'TAIL' ([Text.Encoding]::ASCII.GetString($tailBytes)) 'bounded native copies retain the end of oversized logs'
        }
        finally { $copiedTail.Dispose() }
        Assert-Equal (4MB + 1) (Get-Item -LiteralPath (Join-Path $limitNativeDirectory '1.log')).Length 'diagnostic collection never truncates the original native log'
        Assert-Equal $true (($diagnostics.Warnings -join ' ') -match '32 MiB.+not copied') 'aggregate truncation is explicitly reported'
    }
    finally { $env:LOCALAPPDATA = $fixtureRoot }
    Assert-Equal 3 @(Get-ChildItem -LiteralPath $fixtureRoot -Directory -Filter 'WinGetUpgrade_*.diagnostics').Count 'only the newest three WinGet failure directories are retained'

    & {
        function Save-WinGetFailureDiagnostics {
            param($WinGetPath, $LogFile, $Started, $Finished, $Failure)
            throw 'synthetic diagnostic storage failure'
        }
        Reset-Fixture
        $script:WingetExitCode = -1978335231
        $failure = $null
        try { Invoke-WinGetMaintenance -WaitForCompletion }
        catch { $failure = $_.Exception.Message }
        Assert-Equal $true ($failure -match 'exit code -1978335231.+synthetic diagnostic storage failure') 'diagnostic storage failure preserves the original native exit code'
    }
    & {
        function Set-Content {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Encoding, [Parameter(ValueFromPipeline)]$Value)
            process {
                if ($LiteralPath -like '*WinGetUpgrade_*.log') { throw 'synthetic console log storage failure' }
                $Value | Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Encoding $Encoding -ErrorAction Stop
            }
        }
        foreach ($nativeCode in @(-1978335231, 0, -1978335189)) {
            Reset-Fixture
            $script:WingetExitCode = $nativeCode
            $failure = $null
            try { Invoke-WinGetMaintenance -WaitForCompletion }
            catch { $failure = $_.Exception.Message }
            Assert-Equal $true ($failure -match 'synthetic console log storage failure') "console log storage errors remain explicit for native exit code $nativeCode"
            if ($nativeCode -eq -1978335231) {
                Assert-Equal $true ($failure -match 'exit code -1978335231.+Diagnostics:') 'console log storage failure does not mask the failed native invocation or prevent evidence capture'
            }
        }
    }
    Reset-Fixture
    $script:WingetSource = { throw 'synthetic WinGet startup failure' }
    $failure = $null
    try { Invoke-WinGetMaintenance -WaitForCompletion }
    catch { $failure = $_.Exception.Message }
    Assert-Equal $true ($failure -match 'invocation failed.+synthetic WinGet startup failure.+Diagnostics:') 'WinGet startup exceptions also trigger failure evidence capture'

    $nativeFixture = Join-Path $fixtureRoot "winget's fixture.cmd"
    @(
        '@echo off'
        'echo Native fixture stderr 1>&2'
        'if defined MEMLABS_WINGET_TEST_NATIVE_LOG ('
        '    >"%MEMLABS_WINGET_TEST_NATIVE_LOG%" echo Command line Args: winget upgrade --all'
        ')'
        'exit /b 42'
    ) | Set-Content -LiteralPath $nativeFixture -Encoding ascii
    Reset-Fixture
    $script:WingetSource = $nativeFixture
    & {
        $ErrorActionPreference = 'Stop'
        $failure = $null
        try { Invoke-WinGetMaintenance -WaitForCompletion }
        catch { $failure = $_.Exception.Message }
        Assert-Equal $true ($failure -match 'exit code 42.+Diagnostics:.+Native fixture stderr') 'native stderr does not bypass exit-code handling and evidence capture under Stop preference'
        Assert-Equal 'Stop' $ErrorActionPreference 'native capture restores the caller error-action preference'
    }

    Reset-Fixture
    $script:WingetSource = 'C:\Program Files\WindowsApps\winget.exe'
    $mutexName = 'Global\MemLabs_ChocolateyUpgrade_Test_{0}' -f [guid]::NewGuid().ToString('N')
    Invoke-WinGetMaintenance -UpgradeMutexName $mutexName

    Assert-Equal 'powershell' $script:StartedProcess.FilePath 'interactive maintenance launches a separate PowerShell process'
    Assert-Equal 'Normal' $script:StartedProcess.WindowStyle 'interactive upgrades are visible in their own window'
    Assert-Equal $true ($script:Logs[-1].Message -like '*non-blocking*') 'interactive launch is logged as non-blocking'

    $childScriptPath = Join-Path $fixtureRoot 'memlabs_winget_upgrade.ps1'
    Assert-Equal $true (Test-Path -LiteralPath $childScriptPath) 'interactive maintenance writes its child script'
    $childScript = Get-Content -LiteralPath $childScriptPath -Raw
    Assert-Equal $true $childScript.Contains($mutexName) 'interactive child uses the package upgrade mutex'
    Assert-Equal $true $childScript.Contains(${function:New-MemLabsMaintenanceMutex}.ToString()) 'interactive WinGet child embeds the shared cross-account mutex factory'
    Assert-Equal $true $childScript.Contains('$mutex = New-MemLabsMaintenanceMutex -Name ') 'interactive WinGet child uses the shared mutex policy'
    Assert-Equal $true $childScript.Contains('WinGet package maintenance could not run safely: $_') 'interactive WinGet child reports lock errors instead of running unlocked'
    Assert-Equal $true $childScript.Contains(${function:Save-WinGetFailureDiagnostics}.ToString()) 'interactive WinGet child embeds the shared failure collector'
    Assert-Equal $true $childScript.Contains('$diagnostics = Save-WinGetFailureDiagnostics ') 'interactive WinGet failures invoke the shared collector'
    Assert-Equal $true $childScript.Contains('--disable-interactivity --verbose-logs') 'interactive WinGet commands enable verbose native diagnostics'
    Assert-Equal $true $childScript.Contains('winget.exe'' upgrade --all --source winget') 'interactive child runs the same upgrade-all command'
    Assert-Equal $true $childScript.Contains('Start-Transcript -LiteralPath $wingetLogFile') 'interactive child transcripts full console output'
    Assert-Equal $true $childScript.Contains('Stop-Transcript') 'interactive child closes its transcript'
    Assert-Equal $true ($script:Logs[-1].Message -like '*WinGetUpgrade_*.log*') 'interactive maintenance references the dedicated log'
    Assert-Equal $true $childScript.Contains('list --id Microsoft.VisualStudioCode --exact --source winget --upgrade-available') 'aggregate failure checks whether VS Code remains upgradeable'
    Assert-Equal $true $childScript.Contains('$process.CloseMainWindow()') 'VS Code receives a graceful window-close request'
    Assert-Equal $true $childScript.Contains('upgrade --id Microsoft.VisualStudioCode --exact --source winget') 'VS Code is retried after a clean exit'
    Assert-Equal $false $childScript.Contains('Stop-Process') 'generated maintenance never force-kills VS Code'
    Assert-Equal $false $childScript.Contains('.Kill(') 'generated maintenance never calls a process kill method'

    $childTokens = $null
    $childParseErrors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseInput($childScript, [ref] $childTokens, [ref] $childParseErrors)
    Assert-Equal 0 @($childParseErrors).Count 'generated interactive WinGet script parses successfully'

    $savedChildNativeLog = $env:MEMLABS_WINGET_TEST_NATIVE_LOG
    try {
        $env:MEMLABS_WINGET_TEST_NATIVE_LOG = Join-Path $nativeDirectory 'WinGet-child-upgrade.log'
        Reset-Fixture
        $script:WingetSource = $nativeFixture
        Invoke-WinGetMaintenance -UpgradeMutexName $mutexName
        $enginePath = (Get-Process -Id $PID).Path
        $childOutput = @(& $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childScriptPath 2>&1)
        $childExitCode = $LASTEXITCODE
        Assert-Equal 1 $childExitCode 'a generated WinGet upgrade worker exits with failure for a native upgrade failure'
        $childFailureLog = @(Get-ChildItem -LiteralPath $fixtureRoot -Filter 'WinGetUpgrade_*.log' -File | Sort-Object LastWriteTimeUtc -Descending)[0]
        $childFailureText = Get-Content -LiteralPath $childFailureLog.FullName -Raw
        Assert-Equal $true ($childFailureText -match 'exit code: 42') 'generated worker transcripts preserve the original native exit code'
        Assert-Equal $true $childFailureText.Contains('WinGet failure diagnostics:') 'generated workers report the collected evidence directory'
        $childSummaryPath = Join-Path $fixtureRoot "$([IO.Path]::GetFileNameWithoutExtension($childFailureLog.Name)).diagnostics\summary.json"
        $childSummary = Get-Content -LiteralPath $childSummaryPath -Raw | ConvertFrom-Json
        Assert-Equal $true $childSummary.UpgradeLogFound 'generated workers collect native logs created by their failing upgrade'
        Assert-Equal $nativeFixture $childSummary.Executable 'generated workers preserve executable paths containing spaces and apostrophes'
        if ($childExitCode -ne 1) { $childOutput | Write-Host }
    }
    finally { $env:MEMLABS_WINGET_TEST_NATIVE_LOG = $savedChildNativeLog }

    $timestampPath = Join-Path $fixtureRoot 'MemLabs\winget_upgrade.timestamp'
    Reset-Fixture
    $firstRun = Invoke-MemLabsDueUserWinGetMaintenance -TimestampPath $timestampPath
    Assert-Equal $true $firstRun 'first current-user WinGet maintenance run is due'
    Assert-Equal 1 $script:WingetCalls.Count 'first current-user run invokes WinGet'
    Assert-Equal $true (Test-Path -LiteralPath $timestampPath -PathType Leaf) 'successful current-user maintenance records its cadence timestamp'

    Reset-Fixture
    $secondRun = Invoke-MemLabsDueUserWinGetMaintenance -TimestampPath $timestampPath
    Assert-Equal $false $secondRun 'current-user WinGet maintenance is gated for 24 hours'
    Assert-Equal 0 $script:WingetCalls.Count 'daily cadence gate avoids a duplicate WinGet invocation'

    [DateTimeOffset]::Now.AddHours(-25).ToString('o') | Set-Content -LiteralPath $timestampPath -Encoding ascii -NoNewline
    Reset-Fixture
    $overdueRun = Invoke-MemLabsDueUserWinGetMaintenance -TimestampPath $timestampPath
    Assert-Equal $true $overdueRun 'current-user WinGet maintenance runs after the daily gate expires'
    Assert-Equal 1 $script:WingetCalls.Count 'overdue current-user maintenance invokes WinGet'

    $missingTimestampPath = Join-Path $fixtureRoot 'unavailable\winget_upgrade.timestamp'
    Reset-Fixture
    $script:WingetAvailable = $false
    $unavailableRun = Invoke-MemLabsDueUserWinGetMaintenance -TimestampPath $missingTimestampPath
    Assert-Equal $false $unavailableRun 'unavailable WinGet does not report completed user maintenance'
    Assert-Equal $false (Test-Path -LiteralPath $missingTimestampPath) 'unavailable WinGet does not advance the cadence timestamp'

    Reset-Fixture
    $script:WingetExitCode = -1978335231
    $failedTimestampPath = Join-Path $fixtureRoot 'failed\winget_upgrade.timestamp'
    Assert-Throws { Invoke-MemLabsDueUserWinGetMaintenance -TimestampPath $failedTimestampPath } 'failed user WinGet maintenance remains an explicit failure'
    Assert-Equal $false (Test-Path -LiteralPath $failedTimestampPath) 'failure diagnostics never stamp an unsuccessful WinGet upgrade as completed'
}
finally {
    $env:TEMP = $savedTemp
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:MEMLABS_WINGET_TEST_NATIVE_LOG = $savedFixtureNativeLog
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$sourceText = [System.IO.File]::ReadAllText($sourcePath)
Assert-Equal $true $sourceText.Contains('Invoke-MemLabsOrderedPackageMaintenance -IncludeWinGet -UseUserWinGetCadence -IncludeDailyUpgrades:$BackgroundUpgradeWorker') 'user and interactive workers preserve ordered security verification'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAILED: $($script:Failures) assertion(s)" -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: WinGet maintenance checks passed.' -ForegroundColor Green
exit 0
