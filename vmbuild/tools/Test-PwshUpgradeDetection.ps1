<#
.SYNOPSIS
    Exercise the version detection that stops maintenance re-running a pwsh upgrade the
    MSI can only fail.

.DESCRIPTION
    Chocolatey's record of an installed package goes stale when that package is upgraded
    out of band. A lab had PowerShell 7.6.5 on disk while choco still believed 7.6.3 and
    offered 7.6.4, so every `choco upgrade all` drove the MSI into a downgrade and got
    1603 back. Because that exit code never let the run stamp its timestamp, the upgrade
    window relaunched on every maintenance pass for over a month.

    Invoke-Maintenance now reads the version off pwsh.exe rather than from choco's
    record, compares it against what choco offers, and excludes the package when the MSI
    would install an older or equal build. This checks the three parts that decide that:

      * the choco search parser, against the documented --limit-output row shape
      * the installed-version reader, cross-checked against an independent read
      * the comparison itself, which must be numeric -- a string compare puts .10 below .9

    It also pins the argument quoting choco requires for a list-valued option, which is
    easy to get wrong and silently changes which packages are excluded.

    Nothing here needs Chocolatey present: a local executable supplies fixture output,
    exit codes, and delayed queries with active or stalled logs. This exercises the
    inactivity watchdog, overall cap, and pre-termination evidence collection. The
    installed-version check reports SKIP when PowerShell 7 is not installed.

    Functions are lifted out of the shipped file with the AST, so this exercises the code
    that actually ships rather than a copy that can drift. Preferences are left at their
    defaults so the functions run under the same rules the maintenance script uses.

.PARAMETER RootPath
    The vmbuild folder. Defaults to the parent of this script, so it works from any clone.

.PARAMETER SourceFile
    Path of the maintenance script, relative to RootPath.

.PARAMETER PackageId
    Package id used to build the search fixtures and the exclusion list.

.PARAMETER ExcludedPackages
    Packages the exclusion argument should carry. The metapackage pins its payload to an
    exact version, so excluding one without the other leaves an unsatisfiable constraint.

.EXAMPLE
    .\Test-PwshUpgradeDetection.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-PwshUpgradeDetection.ps1
    Run it under Windows PowerShell 5.1 too; VMBuild.cmd launches maintenance with 5.1.
#>
[CmdletBinding()]
param (
    [string]$RootPath,
    [string]$SourceFile = 'Invoke-Maintenance.ps1',
    [string]$PackageId = 'pwsh',
    [string[]]$ExcludedPackages = @('pwsh', 'powershell-core')
)

# $PSScriptRoot is empty inside a param() default under Windows PowerShell 5.1.
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string]$What)

    $ok = ("$Expected" -eq "$Actual")
    if (-not $ok) { $script:Failures++ }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $color
    if (-not $ok) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wanted = @(
    'Copy-MemLabsDiagnosticLog', 'Get-MemLabsLogFileState', 'Save-ChocoSearchFailureDiagnostics',
    'Test-ChocoSuccessCode', 'Test-ChocoAvailable', 'Get-InstalledPwshVersion',
    'Get-ChocoAvailablePackageVersion', 'Invoke-DailyUpgradesCore',
    'Invoke-MemLabsOrderedPackageMaintenance'
)
$loaded = @()
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -notcontains $node.Name) { continue }
    $loaded += $node.Name
    . ([scriptblock]::Create($node.Extent.Text))
}
$missing = @($wanted | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) {
    Write-Host "SETUP FAIL: not found in ${SourceFile}: $($missing -join ', ')" -ForegroundColor Red
    exit 2
}

# The extracted functions log through the maintenance script's logger.
$script:LogMessages = @()
function Write-LogMessage {
    param ([string]$Message, [string]$Level = 'INFO')
    $script:LogMessages += [pscustomobject]@{ Message = $Message; Level = $Level }
    Write-Verbose "[$Level] $Message"
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

# --- the installed-version reader ------------------------------------------------------
# Cross-checked against a second, independent read of the same fact rather than a
# version literal, so this says nothing about which build happens to be on this machine.
$installed = Get-InstalledPwshVersion
$pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (Test-Path -LiteralPath $pwshExe) {
    $info = (Get-Item -LiteralPath $pwshExe).VersionInfo
    $independent = '{0}.{1}.{2}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart
    Assert-Equal $independent $installed 'installed version matches an independent read of pwsh.exe'
    Assert-Equal 'System.Version' $installed.GetType().FullName 'installed version is a [version], not a string'
}
else {
    Write-Host "SKIP  no PowerShell 7 at $pwshExe - installed-version reader not exercised" -ForegroundColor Yellow
}

# --- the choco search parser -----------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('MemLabs choco search test {0}' -f [guid]::NewGuid().ToString('N'))
$savedProgramData = $env:ProgramData
$savedChocolateyInstall = $env:ChocolateyInstall
$script:FixtureExe = Join-Path $fixtureRoot 'choco.exe'
try {
    New-Item -Path $fixtureRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $fixtureSource = Join-Path $fixtureRoot 'ChocoFixture.cs'
    @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

public static class ChocoFixture {
    public static int Main(string[] args) {
        string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        File.WriteAllText(Path.Combine(root, "pid.txt"), Process.GetCurrentProcess().Id.ToString());
        File.WriteAllText(Path.Combine(root, "arguments.txt"), string.Join(Environment.NewLine, args));
        Console.Write(File.ReadAllText(Path.Combine(root, "rows.txt")));
        Console.Error.Write(File.ReadAllText(Path.Combine(root, "stderr.txt")));
        Console.Out.Flush();
        Console.Error.Flush();
        string mode = File.ReadAllText(Path.Combine(root, "mode.txt")).Trim();
        string nativePath = null;
        foreach (string arg in args) {
            if (arg.StartsWith("--log-file=")) { nativePath = arg.Substring("--log-file=".Length); }
        }
        if (nativePath == null) { return 99; }
        if (mode != "no-native") {
            File.WriteAllText(nativePath, "Command line Args: " + string.Join(" ", args) + Environment.NewLine);
        }
        int delay = int.Parse(File.ReadAllText(Path.Combine(root, "delay.txt")));
        Stopwatch watch = Stopwatch.StartNew();
        int nextUpdate = 200;
        int update = 0;
        while (watch.ElapsedMilliseconds < delay) {
            Thread.Sleep(50);
            if (watch.ElapsedMilliseconds < nextUpdate) { continue; }
            nextUpdate += 200;
            string message = "query progress " + (++update).ToString("D8") + Environment.NewLine;
            if (mode == "native") { File.AppendAllText(nativePath, message); }
            if (mode == "rewrite") { File.WriteAllText(nativePath, message); }
            if (mode == "stdout") { Console.Write(message); Console.Out.Flush(); }
            if (mode == "stderr") { Console.Error.Write(message); Console.Error.Flush(); }
            if (mode == "shared") {
                string shared = Path.Combine(Environment.GetEnvironmentVariable("ChocolateyInstall"), "logs", "chocolatey.log");
                File.AppendAllText(shared, message);
            }
        }
        return int.Parse(File.ReadAllText(Path.Combine(root, "exit.txt")));
    }
}
'@ | Set-Content -LiteralPath $fixtureSource -Encoding utf8 -ErrorAction Stop
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "SETUP FAIL: the Windows .NET Framework compiler is missing at '$compiler'."
    }
    $compilerOutput = @(& $compiler /nologo /target:exe "/out:$script:FixtureExe" $fixtureSource)
    if ($LASTEXITCODE -ne 0) { throw "SETUP FAIL: fixture compilation failed: $($compilerOutput -join ' ')" }

    $env:ChocolateyInstall = Join-Path $fixtureRoot 'chocolatey install'
    $nativeDirectory = Join-Path $env:ChocolateyInstall 'logs'
    New-Item -Path $nativeDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $sharedLog = Join-Path $nativeDirectory 'chocolatey.log'
    Set-Content -LiteralPath $sharedLog -Value 'shared host context' -Encoding utf8 -ErrorAction Stop

    function Get-Command {
        [CmdletBinding()]
        param ([string[]]$Name, [System.Management.Automation.CommandTypes]$CommandType)
        if ($Name.Count -eq 1 -and $Name[0] -eq 'choco') {
            return [pscustomobject]@{ Source = $script:FixtureExe }
        }
        Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
    }

    $sampleVersion = '9.8.7'
    function Set-QueryFixture {
        param (
            [string[]]$Rows = @("$PackageId|$sampleVersion"),
            [string]$Errors = '',
            [int]$ExitCode = 0,
            [int]$DelayMilliseconds = 0,
            [string]$ProgressMode = 'none'
        )
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'rows.txt') -Value ($Rows -join "`n") -Encoding utf8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'stderr.txt') -Value $Errors -Encoding utf8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'exit.txt') -Value $ExitCode -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'delay.txt') -Value $DelayMilliseconds -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'mode.txt') -Value $ProgressMode -Encoding utf8 -ErrorAction Stop
    }

    function Get-LatestQuerySummary {
        $latest = Get-ChildItem -LiteralPath $fixtureRoot -Directory -Filter 'ChocoSearch_*.diagnostics' |
            Sort-Object Name -Descending | Select-Object -First 1
        Get-Content -LiteralPath (Join-Path $latest.FullName 'summary.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    }

    $cases = @(
        @{ Name = 'the documented --limit-output row'; Exit = 0; Rows = @("$PackageId|$sampleVersion"); Expect = $sampleVersion }
        @{ Name = 'a four-part version'; Exit = 0; Rows = @("$PackageId|$sampleVersion.6"); Expect = "$sampleVersion.6" }
        @{ Name = 'a prerelease suffix is trimmed'; Exit = 0; Rows = @("$PackageId|$sampleVersion-preview.2"); Expect = $sampleVersion }
        @{ Name = 'preamble lines are ignored'; Exit = 0; Rows = @('Chocolatey v0.0.0', "$PackageId|$sampleVersion"); Expect = $sampleVersion }
        @{ Name = 'stderr does not bypass exit-code handling'; Exit = 0; Rows = @("$PackageId|$sampleVersion"); Errors = 'native diagnostic'; Expect = $sampleVersion }
        @{ Name = 'large stdout and stderr are drained concurrently'; Exit = 0; Rows = @(('noise' * 20000), "$PackageId|$sampleVersion"); Errors = ('error' * 20000); Expect = $sampleVersion }
        @{ Name = 'a near-miss package id is not accepted'; Exit = 0; Rows = @("${PackageId}extra|$sampleVersion"); Expect = '' }
        @{ Name = 'no results yields no version'; Exit = 0; Rows = @(); Expect = '' }
        @{ Name = 'a failed search yields no version'; Exit = 1; Rows = @("$PackageId|$sampleVersion"); Expect = '' }
    )
    foreach ($case in $cases) {
        Set-QueryFixture -Rows $case.Rows -Errors "$($case.Errors)" -ExitCode $case.Exit
        $actual = Get-ChocoAvailablePackageVersion -PackageId $PackageId -LogDirectory $fixtureRoot -ErrorAction Stop
        Assert-Equal $case.Expect $actual "choco search: $($case.Name)"
    }
    $arguments = @(Get-Content -LiteralPath (Join-Path $fixtureRoot 'arguments.txt'))
    Assert-Equal "search $PackageId --exact --limit-output" ($arguments[0..3] -join ' ') 'the executable receives the exact search arguments'
    Assert-Equal $true ($arguments[4] -like '--log-file=*') 'the query receives its own native log path'
    Assert-Equal $true (Test-Path -LiteralPath $arguments[4].Substring('--log-file='.Length)) 'native log paths containing spaces reach the executable intact'
    Assert-Equal $true (@($script:LogMessages | Where-Object Message -Like '*inactivity timeout: 60s; maximum runtime: 600s*').Count -gt 0) 'production limits are 60 seconds of inactivity and 10 minutes overall'
    Assert-Equal $true (@($script:LogMessages | Where-Object Message -Like '*started (PID *').Count -gt 0) 'the maintenance log identifies the query process'

    foreach ($mode in @('native', 'stdout', 'stderr', 'rewrite')) {
        Set-QueryFixture -DelayMilliseconds 2400 -ProgressMode $mode
        $activeWatch = [Diagnostics.Stopwatch]::StartNew()
        $actual = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -MaxRuntimeSeconds 8 -LogDirectory $fixtureRoot -ErrorAction Stop
        $activeWatch.Stop()
        Assert-Equal $sampleVersion $actual "$mode log movement keeps a healthy query alive"
        Assert-Equal $true ($activeWatch.Elapsed.TotalSeconds -ge 2) "$mode progress is measured beyond the inactivity limit"
    }
    Assert-Equal $true (@($script:LogMessages | Where-Object Message -Like '*no log movement for*last changed log:*').Count -gt 0) 'long-running queries report observed log progress'

    Set-QueryFixture -Errors 'query is waiting' -DelayMilliseconds 15000
    $failure = ''
    $queryWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -TimeoutSeconds 1 -LogDirectory $fixtureRoot -ErrorAction Stop
    }
    catch { $failure = $_.Exception.Message }
    $queryWatch.Stop()
    Assert-Equal $true ($failure -like '*timed out after 1 seconds without log progress*') 'a stalled query throws instead of trusting a partial version row'
    Assert-Equal $true ($queryWatch.Elapsed.TotalSeconds -lt 8) 'the real 15-second query is interrupted within the bounded cleanup budget'
    $queryPid = [int](Get-Content -LiteralPath (Join-Path $fixtureRoot 'pid.txt'))
    Assert-Equal $null (Get-Process -Id $queryPid -ErrorAction SilentlyContinue) 'the timed-out query process is no longer running'
    $lastStdout = Get-ChildItem -LiteralPath $fixtureRoot -Filter 'ChocoSearch_*.stdout.log' | Sort-Object Name -Descending | Select-Object -First 1
    $lastStderr = Get-ChildItem -LiteralPath $fixtureRoot -Filter 'ChocoSearch_*.stderr.log' | Sort-Object Name -Descending | Select-Object -First 1
    Assert-Equal "$PackageId|$sampleVersion" (Get-Content -LiteralPath $lastStdout.FullName -Raw).Trim() 'timeout preserves partial stdout for diagnosis'
    Assert-Equal 'query is waiting' (Get-Content -LiteralPath $lastStderr.FullName -Raw).Trim() 'timeout preserves stderr for diagnosis'
    Assert-Equal $true ($failure.Contains($lastStdout.FullName) -and $failure.Contains($lastStderr.FullName)) 'the failure points to both native output logs'
    $summary = Get-LatestQuerySummary
    Assert-Equal 'NoLogProgress' $summary.TimeoutReason 'the timeout records the observed inactivity reason'
    Assert-Equal $true ($summary.IdleSeconds -ge 1) 'the query is not stopped before the inactivity threshold'
    Assert-Equal $queryPid $summary.QueryProcessId 'timeout evidence records the specific query PID'
    Assert-Equal $false $summary.QueryHasExited 'timeout evidence is gathered before the live query is stopped'
    Assert-Equal 3 @($summary.LogProgress).Count 'progress evidence includes all three attributable query logs'
    Assert-Equal 3 @($summary.Files | Where-Object Scope -EQ 'Query').Count 'the timeout bundle includes native, stdout and stderr logs'
    Assert-Equal 1 @($summary.Files | Where-Object Scope -EQ 'SharedHostContext').Count 'the timeout bundle includes shared Chocolatey context'
    Assert-Equal $false $summary.SharedLogsEstablishQueryProgress 'shared host logs are not treated as query liveness evidence'
    Assert-Equal $true ($failure -like '*Diagnostics: *.diagnostics*') 'the reported timeout identifies its evidence directory'

    Set-QueryFixture -DelayMilliseconds 15000 -ProgressMode 'shared'
    $failure = ''
    try { $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -MaxRuntimeSeconds 8 -LogDirectory $fixtureRoot -ErrorAction Stop }
    catch { $failure = $_.Exception.Message }
    Assert-Equal $true ($failure -like '*without log progress*') 'unrelated shared-log writes cannot keep a stalled query alive'
    Assert-Equal $true ((Get-Content -LiteralPath $sharedLog -Raw) -like '*query progress*') 'the shared-log writer really ran during the stalled query'
    $summary = Get-LatestQuerySummary
    Assert-Equal 0 @($summary.LogProgress | Where-Object Path -EQ $sharedLog).Count 'the shared log is excluded from liveness measurements'

    Set-QueryFixture -DelayMilliseconds 15000 -ProgressMode 'native'
    $failure = ''
    try { $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -MaxRuntimeSeconds 2 -LogDirectory $fixtureRoot -ErrorAction Stop }
    catch { $failure = $_.Exception.Message }
    Assert-Equal $true ($failure -like '*maximum runtime of 2 seconds*') 'an endlessly active query still hits the overall runtime cap'
    $summary = Get-LatestQuerySummary
    Assert-Equal 'MaximumRuntime' $summary.TimeoutReason 'the overall cap is distinguished from inactivity'
    Assert-Equal $true ($summary.ElapsedSeconds -ge 2 -and $summary.ElapsedSeconds -lt 3) 'the overall cap is measured at its configured boundary'
    Assert-Equal $true ($summary.IdleSeconds -lt 1) 'the runtime cap is exercised while the query is actively logging'
    Assert-Equal $true (@($summary.LogProgress | Where-Object { $_.Path -like '*.native.log' -and $_.ChangeCount -gt 1 }).Count -eq 1) 'native log changes are recorded as measured progress'

    Set-QueryFixture -DelayMilliseconds 15000 -ProgressMode 'no-native'
    $failure = ''
    try { $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -LogDirectory $fixtureRoot -ErrorAction Stop }
    catch { $failure = $_.Exception.Message }
    $summary = Get-LatestQuerySummary
    Assert-Equal $true ($failure -like '*without log progress*') 'a query that never initializes native logging still fails explicitly'
    Assert-Equal $true (($summary.Warnings -join ' ') -like '*Could not locate query log*.native.log*') 'missing native query logs are reported in the timeout bundle'

    Set-QueryFixture -DelayMilliseconds 15000
    $lockedLog = [IO.File]::Open($sharedLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $failure = ''
        try { $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -LogDirectory $fixtureRoot -ErrorAction Stop }
        catch { $failure = $_.Exception.Message }
        $summary = Get-LatestQuerySummary
        Assert-Equal $true ($failure -like '*without log progress*') 'a locked native context log does not replace the original timeout'
        Assert-Equal $true (($summary.Warnings -join ' ') -like '*Could not collect native log*chocolatey.log*') 'locked native logs produce explicit collection warnings'
        Assert-Equal 3 @($summary.Files | Where-Object Scope -EQ 'Query').Count 'other query evidence survives a native-log copy failure'
    }
    finally { $lockedLog.Dispose() }

    & {
        function Save-ChocoSearchFailureDiagnostics {
            param($ChocoPath, $LogPrefix, $QueryLogPaths, $RunContext)
            throw 'synthetic diagnostic storage failure'
        }
        $failure = ''
        try { $null = Get-ChocoAvailablePackageVersion -PackageId $PackageId -IdleTimeoutSeconds 1 -LogDirectory $fixtureRoot -ErrorAction Stop }
        catch { $failure = $_.Exception.Message }
        Assert-Equal $true ($failure -like '*without log progress*Diagnostic collection failed:*synthetic diagnostic storage failure*') 'diagnostic storage failure preserves the original timeout'
        $queryPid = [int](Get-Content -LiteralPath (Join-Path $fixtureRoot 'pid.txt'))
        Assert-Equal $null (Get-Process -Id $queryPid -ErrorAction SilentlyContinue) 'failed evidence collection does not leave the timed-out query running'
    }

    $largeLogNames = @('chocolatey.log') + @(1..11 | ForEach-Object { "chocolatey.log.$_" })
    foreach ($name in $largeLogNames) {
        $largeLog = [IO.File]::Open((Join-Path $nativeDirectory $name), [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            $largeLog.SetLength(4MB + 1)
            [void]$largeLog.Seek(-4, [IO.SeekOrigin]::End)
            $tail = [Text.Encoding]::ASCII.GetBytes('TAIL')
            $largeLog.Write($tail, 0, $tail.Length)
        }
        finally { $largeLog.Dispose() }
    }
    $limitPrefix = Join-Path $fixtureRoot ('ChocoSearch_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N').Substring(0, 8))
    $queryPaths = @($lastStdout.FullName, $lastStderr.FullName, ($lastStdout.FullName -replace '\.stdout\.log$', '.native.log'))
    $bundle = Save-ChocoSearchFailureDiagnostics -ChocoPath $script:FixtureExe -LogPrefix $limitPrefix -QueryLogPaths $queryPaths `
        -RunContext @{ Failure = 'byte-limit fixture'; TimeoutReason = 'NoLogProgress' }
    $summary = Get-Content -LiteralPath (Join-Path $bundle.Directory 'summary.json') -Raw | ConvertFrom-Json
    $copiedLogs = @($summary.Files | ForEach-Object { Get-Item -LiteralPath (Join-Path $bundle.Directory $_.File) -ErrorAction Stop })
    Assert-Equal 32MB ($copiedLogs | Measure-Object Length -Sum).Sum 'Chocolatey evidence enforces the exact 32 MiB run budget'
    Assert-Equal 0 @($copiedLogs | Where-Object Length -GT 4MB).Count 'no Chocolatey evidence file exceeds 4 MiB'
    Assert-Equal $true (($summary.Warnings -join ' ') -like '*newest 10 of 12*') 'excess native Chocolatey logs are reported'
    Assert-Equal $true (($summary.Warnings -join ' ') -like '*32 MiB*not copied*') 'the aggregate evidence limit is reported'
    $copiedNative = @($summary.Files | Where-Object Scope -EQ 'SharedHostContext')[0]
    $tailStream = [IO.File]::OpenRead((Join-Path $bundle.Directory $copiedNative.File))
    try {
        [void]$tailStream.Seek(-4, [IO.SeekOrigin]::End)
        $tail = [byte[]]::new(4)
        [void]$tailStream.Read($tail, 0, 4)
        Assert-Equal 'TAIL' ([Text.Encoding]::ASCII.GetString($tail)) 'oversized Chocolatey logs retain their diagnostic tail'
    }
    finally { $tailStream.Dispose() }
    Assert-Equal (4MB + 1) (Get-Item -LiteralPath $sharedLog).Length 'evidence collection never truncates the original Chocolatey log'
    Assert-Equal 3 @(Get-ChildItem -LiteralPath $fixtureRoot -Directory -Filter 'ChocoSearch_*.diagnostics').Count 'only the newest three Chocolatey failure bundles are retained'
    foreach ($name in $largeLogNames) { Remove-Item -LiteralPath (Join-Path $nativeDirectory $name) -Force -ErrorAction Stop }
    Set-Content -LiteralPath $sharedLog -Value 'shared host context' -Encoding utf8 -ErrorAction Stop

    $script:BoundedChocoSearch = ${function:Get-ChocoAvailablePackageVersion}
    function Get-ChocoAvailablePackageVersion {
        param ([string]$PackageId)
        & $script:BoundedChocoSearch -PackageId $PackageId -TimeoutSeconds 1 -LogDirectory $fixtureRoot
    }
    function Invoke-DailyUpgrades {
        param ([switch]$WaitForCompletion)
        Invoke-DailyUpgradesCore -WaitForCompletion:$WaitForCompletion
    }
    $script:UpgradeCalls = 0
    function choco { $script:UpgradeCalls++; throw 'An upgrade must not run after the query times out.' }
    $script:SecurityChecks = 0
    function Invoke-AspNetCoreMaintenance { $script:SecurityChecks++ }
    $env:ProgramData = $fixtureRoot
    $flagDirectory = Join-Path $fixtureRoot 'memlabs'
    New-Item -Path $flagDirectory -ItemType Directory -Force | Out-Null
    $ps7Flag = Join-Path $flagDirectory 'ps7_upgrade.timestamp'
    $chocoFlag = Join-Path $flagDirectory 'choco_all_upgrade.timestamp'
    $previousTimestamp = (Get-Date).AddDays(-2).ToString('o')
    $previousTimestamp | Set-Content -LiteralPath $ps7Flag -Encoding ascii -NoNewline
    $previousTimestamp | Set-Content -LiteralPath $chocoFlag -Encoding ascii -NoNewline
    $script:MaintenanceHadFailure = $false
    Invoke-MemLabsOrderedPackageMaintenance -IncludeDailyUpgrades
    Assert-Equal $true $script:MaintenanceHadFailure 'a timed-out version query fails the maintenance run'
    Assert-Equal 0 $script:UpgradeCalls 'no package upgrades run after the query times out'
    Assert-Equal $previousTimestamp (Get-Content -LiteralPath $ps7Flag -Raw) 'timeout does not stamp PowerShell upgrade completion'
    Assert-Equal $previousTimestamp (Get-Content -LiteralPath $chocoFlag -Raw) 'timeout does not stamp upgrade-all completion'
    Assert-Equal 1 $script:SecurityChecks 'final ASP.NET Core verification still runs after daily upgrades fail'
}
finally {
    $env:ProgramData = $savedProgramData
    $env:ChocolateyInstall = $savedChocolateyInstall
    $pidPath = Join-Path $fixtureRoot 'pid.txt'
    if (Test-Path -LiteralPath $pidPath) {
        $ownedProcess = Get-Process -Id ([int](Get-Content -LiteralPath $pidPath)) -ErrorAction SilentlyContinue
        if ($ownedProcess -and $ownedProcess.Path -eq $script:FixtureExe) {
            Stop-Process -Id $ownedProcess.Id -Force -ErrorAction Stop
        }
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
    }
}

# --- the decision ----------------------------------------------------------------------
# Mirrors the condition in the maintenance script: skip only when both versions are known
# and the installed build is at least what the package carries.
function Test-SkipDecision {
    param ($InstalledVersion, $AvailableVersion)
    return [bool]($InstalledVersion -and $AvailableVersion -and $InstalledVersion -ge $AvailableVersion)
}

Assert-Equal $true (Test-SkipDecision ([version]'2.1.5') ([version]'2.1.4')) 'installed newer than offered -> skip (the 1603 case)'
Assert-Equal $true (Test-SkipDecision ([version]'2.1.4') ([version]'2.1.4')) 'installed equal to offered -> skip'
Assert-Equal $false (Test-SkipDecision ([version]'2.1.4') ([version]'2.1.5')) 'installed older -> the upgrade runs'
Assert-Equal $false (Test-SkipDecision $null ([version]'2.1.4')) 'installed unknown -> the upgrade runs, no skip on a non-measurement'
Assert-Equal $false (Test-SkipDecision ([version]'2.1.5') $null) 'offered unknown -> the upgrade runs, no skip on a non-measurement'

# A string compare reads 2.1.10 as older than 2.1.9, which would skip a real upgrade.
Assert-Equal $false ('2.1.10' -ge '2.1.9') 'a string compare gets two-digit revisions wrong'
Assert-Equal $true ([version]'2.1.10' -ge [version]'2.1.9') '[version] gets two-digit revisions right'

# --- the exclusion argument ------------------------------------------------------------
# choco wants the value single-quoted inside the double quotes; PowerShell strips the
# outer pair and choco strips the inner, leaving one argv token.
$script:SeenArgs = @()
function Invoke-ChocoStub { $script:SeenArgs = $args; $global:LASTEXITCODE = 0 }
$exceptValue = $ExcludedPackages -join ','
$command = '& Invoke-ChocoStub upgrade all -y --except="' + "'$exceptValue'" + '"'
. ([scriptblock]::Create($command))
Assert-Equal "upgrade all -y --except='$exceptValue'" ($script:SeenArgs -join ' ') 'the exclusion reaches choco as one argument with its quotes intact'

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0
