<#
.SYNOPSIS
    Verifies resumable retries are prepared by Phase 0 without human reboots.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$newLab = Get-Content -LiteralPath (Join-Path $RootPath 'New-Lab.ps1') -Raw
$startTest = Get-Content -LiteralPath (Join-Path $RootPath 'Start-Test.ps1') -Raw
$phases = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
$scriptBlocks = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
$childLauncher = Get-Content -LiteralPath (Join-Path $RootPath 'tools\Invoke-PinnedChildScript.ps1') -Raw
$mixedRunner = Get-Content -LiteralPath (Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1') -Raw

foreach ($path in @(
        (Join-Path $RootPath 'New-Lab.ps1'),
        (Join-Path $RootPath 'Start-Test.ps1'),
        (Join-Path $RootPath 'common\Common.Phases.ps1'),
        (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'),
        (Join-Path $RootPath 'tools\Invoke-PinnedChildScript.ps1'),
        (Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1')
    )) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
}

if ($newLab -notmatch
    '(?s)NewLabResumeInfo.+?Configuration\s*=\s*\$Configuration.+?Phase\s*=\s*\$Phase.+?Restore\s*=\s*\[bool\]\$Restore\.IsPresent') {
    throw 'New-Lab does not publish structured resume metadata.'
}
if ($newLab -notmatch
    '(?s)\$resumePreparation\s*=\s*\[bool\]\(\$StartPhase -gt 0 -and -not \$Restore\.IsPresent\).+?ResumePreparation.+?\$containsHidden -or \$resumePreparation.+?Start-Phase -Phase 0') {
    throw 'A StartPhase resume does not force Phase 0 preparation.'
}
if ($phases -notmatch
    '(?s)\$Phase -eq 0 -and -not \$currentItem\.hidden.+?ResumePreparation.+?\$currentItem\.vmName -notin @\(\$existingVMs\.vmName\)') {
    throw 'Phase 0 cannot include retained VMs that were originally non-hidden.'
}
if ($scriptBlocks -notmatch
    '(?s)\$resumePreparation.+?resumeRebootProbeBlock.+?PendingFileRenameOperations.+?resumeRebootReasons\.Count -eq 0.+?no reboot needed.+?Restart-VM2Smart.+?Wait-ForVM') {
    throw 'Phase 0 does not conditionally own reboot/readiness for resumes.'
}
if ($scriptBlocks -match
    '(?s)elseif \(\$resumePreparation\).{0,300}Restart-VM2Smart') {
    throw 'Phase 0 still contains an unconditional resume reboot.'
}
if ($startTest -notmatch
    '(?s)function Invoke-NewLab.+?\[int\]\$StartPhase.+?\[switch\]\$Restore.+?StartPhase = \$StartPhase.+?Restore = \$true') {
    throw 'Start-Test cannot invoke a structured StartPhase/restore retry.'
}
if ($startTest -notmatch
    '(?s)\$automatedResumeAttempts\s*=\s*0.+?\$automatedResumeAttempts -lt 1.+?\$automatedResumeAttempts\+\+.+?Automatically resuming at Phase.+?-StartPhase.+?-Restore:') {
    throw 'Unattended Start-Test does not perform exactly one bounded automatic resume.'
}
if ($startTest -notmatch
    '(?s)function Invoke-NewLab.+?Invoke-PinnedChildScript\.ps1.+?Export-Clixml.+?-InvocationToken \$token -ResultPath \$resultPath.+?result token does not match') {
    throw 'Standard Start-Test deployments are not isolated behind a token-verified child process.'
}
if ($startTest -match '&\s+\./New-Lab\.ps1') {
    throw 'Start-Test still loads New-Lab directly into its long-lived launcher process.'
}
if ($startTest -match 'Repair or resume it from another window') {
    throw 'Failure UX still delegates resumable recovery to a human.'
}
if ($childLauncher -notmatch
    '(?s)\[string\]\s*\$ResultPath.+?NewLabResumeInfo.+?InvocationToken.+?ResumeInfo.+?WriteAllText\(\$ResultPath') {
    throw 'Pinned child launcher does not publish structured resume metadata.'
}
foreach ($mixedRunnerContract in @(
        'child-result-',
        '-ResultPath $resultPath',
        'result token does not match',
        '$script:LastChildResult = $childResult',
        '$resumeParameters.StartPhase',
        '-resume-phase'
    )) {
    if (-not $mixedRunner.Contains($mixedRunnerContract)) {
        throw "Mixed-revision runner is missing structured resume contract '$mixedRunnerContract'."
    }
}

$tokens = $null
$errors = $null
$scriptBlocksAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'),
    [ref]$tokens,
    [ref]$errors
)
$probeAssignments = @($scriptBlocksAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$resumeRebootProbeBlock'
        }, $true))
if ($probeAssignments.Count -ne 1) {
    throw "Expected one resume reboot probe, found $($probeAssignments.Count)."
}
$probeText = $probeAssignments[0].Right.Extent.Text

function Invoke-ResumeProbeFixture {
    param(
        [hashtable] $ExistingPaths = @{},
        [string] $ActiveName = 'NODE1',
        [string] $PendingName = 'NODE1',
        [object[]] $PendingFileRenames = @(),
        [bool] $CcmPending = $false,
        [bool] $CcmSurfaceAbsent = $false
    )

    & {
        function Test-Path {
            [CmdletBinding()]
            param([string] $LiteralPath)
            return [bool]$ExistingPaths[$LiteralPath]
        }
        function Get-ItemProperty {
            [CmdletBinding()]
            param([string] $LiteralPath, [string] $Name)
            switch ($LiteralPath) {
                'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' {
                    return [pscustomobject]@{ ComputerName = $ActiveName }
                }
                'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' {
                    return [pscustomobject]@{ ComputerName = $PendingName }
                }
                'HKLM:\SOFTWARE\Microsoft\Updates' {
                    return [pscustomobject]@{ UpdateExeVolatile = 0 }
                }
                'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' {
                    return [pscustomobject]@{ PendingFileRenameOperations = $PendingFileRenames }
                }
            }
            return $null
        }
        function Invoke-CimMethod {
            [CmdletBinding()]
            param(
                [string] $Namespace,
                [string] $ClassName,
                [string] $MethodName,
                [int] $OperationTimeoutSec
            )
            if ($CcmSurfaceAbsent) {
                $exception = New-Object System.Exception 'localized namespace absence'
                $exception | Add-Member -MemberType NoteProperty `
                    -Name NativeErrorCode -Value InvalidNamespace
                throw $exception
            }
            return [pscustomobject]@{
                RebootPending = $CcmPending
                IsHardRebootPending = $false
            }
        }

        Invoke-Expression ('& ' + $probeText)
    }
}

$noMarkerResult = Invoke-ResumeProbeFixture
$noMarkerReasons = @($noMarkerResult.Reasons |
    Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
if ($noMarkerReasons.Count -ne 0) {
    throw "Healthy fixture incorrectly requested a reboot: $($noMarkerReasons -join ', ')"
}
$cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$cbsResult = Invoke-ResumeProbeFixture -ExistingPaths @{ $cbsPath = $true }
if ('CBS\RebootPending' -notin @($cbsResult.Reasons)) {
    throw 'CBS reboot marker was not classified as actionable.'
}
$renameResult = Invoke-ResumeProbeFixture -ActiveName 'OLDNAME' -PendingName 'NEWNAME'
if (@($renameResult.Reasons | Where-Object { $_ -like 'ComputerRename:*' }).Count -ne 1) {
    throw 'Pending computer rename was not classified as actionable.'
}
$deleteOnlyResult = Invoke-ResumeProbeFixture -PendingFileRenames @(
    '\??\C:\Windows\Temp\delete.tmp', ''
)
$deleteOnlyReasons = @($deleteOnlyResult.Reasons |
    Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
if ($deleteOnlyReasons.Count -ne 0) {
    throw 'Deletion-only PendingFileRenameOperations incorrectly requested a reboot.'
}
$replacementResult = Invoke-ResumeProbeFixture -PendingFileRenames @(
    '\??\C:\Windows\Temp\source.tmp', '\??\C:\Windows\System32\target.dll'
)
if (@($replacementResult.Reasons | Where-Object { $_ -like 'PendingFileRenameOperations*' }).Count -ne 1) {
    throw 'Replacement PendingFileRenameOperations was not classified as actionable.'
}
$ccmResult = Invoke-ResumeProbeFixture -CcmPending $true
if ('ConfigMgrClient\RebootPending' -notin @($ccmResult.Reasons)) {
    throw 'ConfigMgr client reboot marker was not classified as actionable.'
}
$noCcmResult = Invoke-ResumeProbeFixture -CcmSurfaceAbsent $true
$noCcmReasons = @($noCcmResult.Reasons |
    Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
if ($noCcmReasons.Count -ne 0) {
    throw 'Absent ConfigMgr client namespace incorrectly requested a reboot.'
}

if ($mixedRunner -notmatch 'Invoke-NewLabFixture') {
    throw 'Mixed-revision runner does not consume a token-verified structured resume result.'
}

function Get-ResumeTestFunctionText {
    param([string] $Path, [string] $Name)

    $functionTokens = $null
    $functionErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$functionTokens, [ref]$functionErrors)
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        }, $true)
    if (-not $definition) { throw "Function '$Name' was not found in $Path." }
    return $definition.Extent.Text
}

function Write-Log {}
function Add-CmdHistory {}
. ([scriptblock]::Create((Get-ResumeTestFunctionText `
            -Path (Join-Path $RootPath 'New-Lab.ps1') `
            -Name 'Write-NewLabResumeCommand')))
$global:NewLabResumeCommand = $null
$global:NewLabResumeInfo = $null
Write-NewLabResumeCommand -Configuration 'fixture.json' -Phase 8 -Restore
if ($global:NewLabResumeInfo.Configuration -ne 'fixture.json' -or
    [int]$global:NewLabResumeInfo.Phase -ne 8 -or
    -not [bool]$global:NewLabResumeInfo.Restore) {
    throw 'Write-NewLabResumeCommand did not publish complete runtime resume metadata.'
}

. ([scriptblock]::Create((Get-ResumeTestFunctionText `
            -Path (Join-Path $RootPath 'Start-Test.ps1') `
            -Name 'Invoke-NewLab')))
$script:NewLabChildLauncherPath = Join-Path $RootPath 'tools\Invoke-PinnedChildScript.ps1'
function Get-Job { @() }
function Get-CimInstance { @() }
function Write-PowerShellJobLeakDiag {}

$invokeTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-auto-resume-$PID"
$capturePath = Join-Path $invokeTestRoot 'captured.json'
$fakeNewLabPath = Join-Path $invokeTestRoot 'New-Lab.ps1'
try {
    $null = New-Item -ItemType Directory -Path $invokeTestRoot -Force
    [IO.File]::WriteAllText($fakeNewLabPath, @'
[CmdletBinding()]
param(
    [string] $Configuration,
    [switch] $NoSnapshot,
    [switch] $KeepFailedVMs,
    [switch] $ClearErrorHistoryOnExit,
    [switch] $RequireCleanSource,
    [int] $StartPhase,
    [switch] $Restore
)
[IO.File]::WriteAllText($env:MEMLABS_RESUME_CAPTURE, ([ordered]@{
    Configuration = $Configuration
    NoSnapshot = [bool]$NoSnapshot
    KeepFailedVMs = [bool]$KeepFailedVMs
    ClearErrorHistoryOnExit = [bool]$ClearErrorHistoryOnExit
    StartPhase = $StartPhase
    Restore = [bool]$Restore
} | ConvertTo-Json))
if ($env:MEMLABS_RESUME_PID_LOG) {
    Add-Content -LiteralPath $env:MEMLABS_RESUME_PID_LOG -Value $PID
}
$global:NewLabResumeCommand = "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $StartPhase -restore"
$global:NewLabResumeInfo = [pscustomobject]@{
    Configuration = $Configuration
    Phase = $StartPhase
    Restore = [bool]$Restore
}
if ($env:MEMLABS_FAKE_DSC_RESTART -eq '1') {
    $restartCount = 0
    if (Test-Path -LiteralPath $env:MEMLABS_RESUME_RESTART_COUNT) {
        $restartCount = [int](Get-Content -LiteralPath $env:MEMLABS_RESUME_RESTART_COUNT -Raw)
    }
    $restartCount++
    Set-Content -LiteralPath $env:MEMLABS_RESUME_RESTART_COUNT -Value $restartCount
    $global:LASTEXITCODE = if ($restartCount -eq 1) { 55 } else { 0 }
}
else {
    $global:LASTEXITCODE = 2
}
'@)
    $oldCapture = [Environment]::GetEnvironmentVariable('MEMLABS_RESUME_CAPTURE', 'Process')
    [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_CAPTURE', $capturePath, 'Process')
    Push-Location $invokeTestRoot
    try {
        $invokeExit = Invoke-NewLab -ConfigFile 'fixture.json' -StartPhase 7 -Restore
    }
    finally {
        Pop-Location
        [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_CAPTURE', $oldCapture, 'Process')
    }

    $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    if ([int]$invokeExit -ne 2 -or [int]$captured.StartPhase -ne 7 -or
        -not [bool]$captured.Restore -or -not [bool]$captured.KeepFailedVMs) {
        throw 'Start-Test Invoke-NewLab did not forward the structured resume invocation.'
    }
    if ([int]$script:LastNewLabResumeInfo.Phase -ne 7 -or
        -not [bool]$script:LastNewLabResumeInfo.Restore) {
        throw 'Start-Test Invoke-NewLab did not retain structured resume metadata.'
    }

    $restartCountPath = Join-Path $invokeTestRoot 'restart-count.txt'
    $pidLogPath = Join-Path $invokeTestRoot 'child-pids.txt'
    [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_CAPTURE', $capturePath, 'Process')
    [Environment]::SetEnvironmentVariable('MEMLABS_FAKE_DSC_RESTART', '1', 'Process')
    [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_RESTART_COUNT', $restartCountPath, 'Process')
    [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_PID_LOG', $pidLogPath, 'Process')
    Push-Location $invokeTestRoot
    try {
        $restartExit = Invoke-NewLab -ConfigFile 'fixture.json'
    }
    finally {
        Pop-Location
        [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_CAPTURE', $oldCapture, 'Process')
        [Environment]::SetEnvironmentVariable('MEMLABS_FAKE_DSC_RESTART', $null, 'Process')
        [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_RESTART_COUNT', $null, 'Process')
        [Environment]::SetEnvironmentVariable('MEMLABS_RESUME_PID_LOG', $null, 'Process')
    }
    $childPids = @(Get-Content -LiteralPath $pidLogPath | Where-Object { $_ })
    if ([int]$restartExit -ne 0 -or
        [int](Get-Content -LiteralPath $restartCountPath -Raw) -ne 2 -or
        @($childPids | Select-Object -Unique).Count -ne 2) {
        throw 'DSC rebuild exit 55 did not relaunch New-Lab in a second fresh process.'
    }
}
finally {
    Remove-Item -LiteralPath $invokeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    $script:NewLabChildLauncherPath = $null
}

Write-Host 'PASS -- StartPhase retries automatically pass through conditional Phase 0 reboot/readiness preparation.'
