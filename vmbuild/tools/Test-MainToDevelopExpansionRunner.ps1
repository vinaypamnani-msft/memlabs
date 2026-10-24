<#
.SYNOPSIS
    Tests expansion scopes, workflow failures and diagnostic recovery without changing Hyper-V.
#>
[CmdletBinding()]
param([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$repoRoot = Split-Path -Parent $RootPath
$runnerPath = Join-Path $PSScriptRoot 'Invoke-MainToDevelopExpansionTest.ps1'
$startTestPath = Join-Path $RootPath 'Start-Test.ps1'
$childLauncherPath = Join-Path $PSScriptRoot 'Invoke-PinnedChildScript.ps1'
$newLabPath = Join-Path $RootPath 'New-Lab.ps1'
$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$functionalValidationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$script:Failures = 0
$script:MockVms = @{}
$script:MockDisks = @{}
$script:MockVhds = @{}
$script:MockDomainSid = 'S-1-5-21-100-200-300'
$script:LastCredentialUser = $null
$script:CredentialAttempts = [System.Collections.Generic.List[string]]::new()
$script:RejectedCredentialUsers = @()
$script:MockIdentityDnsDomain = 'nocm.com'
$script:MockIdentityUser = $null
$script:MockGetVmFailure = $false
Write-Host 'Initial defect coverage: complete maintenance scopes, terminal workflow failures, and timeline sharing recovery.'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $true
    NltestExitCode = 0; TrustedDc = 'NOC-DC1.nocm.com'; LogonServer = '\\NOC-DC1'
    DnsAddresses = @('10.220.201.20')
}
$script:MockDomainHealthSequence = [System.Collections.Generic.Queue[object]]::new()

function Write-TestResult {
    param([bool] $Passed, [string] $What, [string] $Detail = '')

    if (-not $Passed) { $script:Failures++ }
    $state = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("{0}  {1}" -f $state, $What) -ForegroundColor $color
    if (-not $Passed -and $Detail) { Write-Host "      $Detail" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    Write-TestResult -Passed ("$Expected" -eq "$Actual") -What $What -Detail "expected=[$Expected] actual=[$Actual]"
}

function Assert-True {
    param([bool] $Condition, [string] $What, [string] $Detail = '')
    Write-TestResult -Passed $Condition -What $What -Detail $Detail
}

function Assert-ThrowsLike {
    param([scriptblock] $Action, [string] $Pattern, [string] $What)

    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    Write-TestResult -Passed ([bool]($message -like $Pattern)) -What $What -Detail "actual=[$message]"
}

$childLauncherText = Get-Content -LiteralPath $childLauncherPath -Raw
Assert-True ($childLauncherText -match 'Console\.CancelKeyPress' -and
    $childLauncherText -match 'Environment\.Exit\(130\)' -and
    $childLauncherText -match 'InstallImmediateCancelExit') `
    'pinned child launcher converts Ctrl-C into immediate Job Object teardown'

$functionalValidationText = Get-Content -LiteralPath $functionalValidationPath -Raw
Assert-True ($functionalValidationText -match
    '(?s)\$scStableSamples\s*=\s*0.+?nltest\.exe\s+"/sc_query:\$expectedDomain".+?\$scStableSamples\s*-ge\s*2') `
    'Phase 11 requires consecutive cmdlet and nltest secure-channel samples'
Assert-True ($functionalValidationText -match
    '(?s)\$repairStableSamples\s*=\s*0.+?\$repairStableSamples\s*-ge\s*2') `
    'Phase 11 repair is revalidated with consecutive healthy samples'

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s)." }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Get-VM {
    param([string] $Name, [object] $ErrorAction)
    if ($script:MockGetVmFailure) { throw 'simulated Hyper-V provider failure' }
    if ($Name) { return $script:MockVms[$Name] }
    return @($script:MockVms.Values)
}

function Get-VMHardDiskDrive {
    param([string] $VMName, [object] $ErrorAction)
    return @($script:MockDisks[$VMName])
}

function Get-VHD {
    param([string] $Path, [object] $ErrorAction)
    if ($script:MockVhds.ContainsKey($Path)) {
        return $script:MockVhds[$Path]
    }
    return [pscustomobject]@{ Path = $Path; ParentPath = $null }
}

function Invoke-Command {
    param([string] $VMName, [pscredential] $Credential, [scriptblock] $ScriptBlock, [object[]] $ArgumentList, [object] $ErrorAction)
    $script:LastCredentialUser = $Credential.UserName
    $script:CredentialAttempts.Add($Credential.UserName)
    if ($script:RejectedCredentialUsers -contains $Credential.UserName) {
        throw 'The credential is invalid.'
    }
    $identityUser = if ($Credential.UserName -match '\\([^\\]+)$') {
        $Matches[1]
    }
    elseif ($Credential.UserName -match '^([^@]+)@') {
        $Matches[1]
    }
    else {
        'admin2'
    }
    if ($script:MockIdentityUser) { $identityUser = $script:MockIdentityUser }
    if ("$ScriptBlock" -like '*Get-CimInstance Win32_ComputerSystem*') {
        $script:LastDomainProbeScript = $ScriptBlock
        $health = if ($script:MockDomainHealthSequence.Count -gt 0) {
            $script:MockDomainHealthSequence.Dequeue()
        }
        else {
            $script:MockDomainHealth
        }
        return [pscustomobject]@{
            PartOfDomain = $health.PartOfDomain
            Domain = $health.Domain
            SecureChannel = $health.SecureChannel
            SecureChannelError = "$($health.SecureChannelError)"
            NltestHealthy = $health.NltestHealthy
            NltestExitCode = $health.NltestExitCode
            NltestOutput = "$($health.NltestOutput)"
            TrustedDc = "$($health.TrustedDc)"
            LogonServer = "$($health.LogonServer)"
            DnsAddresses = @($health.DnsAddresses)
            _MemLabsIdentity = "NOCM\$identityUser"
            _MemLabsUserDnsDomain = $script:MockIdentityDnsDomain
            _MemLabsUserName = $identityUser
        }
    }
    return [pscustomobject]@{
        DomainSid = $script:MockDomainSid
        _MemLabsIdentity = "NOCM\$identityUser"
        _MemLabsUserDnsDomain = $script:MockIdentityDnsDomain
        _MemLabsUserName = $identityUser
    }
}

if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
    Write-Host "SETUP FAIL: runner not found at $runnerPath" -ForegroundColor Red
    exit 2
}

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-plan-$PID"
Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source

$allOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $runnerPath `
        -RepositoryRoot $repoRoot -All -PlanOnly -StateRoot $stateRoot 2>&1 | ForEach-Object { "$_" })
$allExit = $LASTEXITCODE
$allText = $allOutput -join [Environment]::NewLine
$mutationFixtureGitPath = 'vmbuild/config/tests/mutations/CSTest3-D-MutateExistingSiteSystem.json'
$legacyMutationFixtureGitPath = 'vmbuild/config/tests/CSTest3-D-MutateExistingSiteSystem.json'
$proxyLinuxFixtureGitPath = 'vmbuild/config/tests/CSTest5-C-AddProxyLinux.json'
$pullDpFixtureGitPath = 'vmbuild/config/tests/PSTest2-F-AddPullDP.json'
function Test-FixtureInHead {
    param([string] $GitPath)
    $null = & git -C $repoRoot cat-file -e "HEAD`:$GitPath" 2>$null
    return $LASTEXITCODE -eq 0
}
$mutationFixtureInHead = (Test-FixtureInHead $mutationFixtureGitPath) -or
    (Test-FixtureInHead $legacyMutationFixtureGitPath)
$proxyLinuxFixtureInHead = Test-FixtureInHead $proxyLinuxFixtureGitPath
$pullDpFixtureInHead = Test-FixtureInHead $pullDpFixtureGitPath
$expectedFollowOns = 37 + [int]$mutationFixtureInHead + [int]$proxyLinuxFixtureInHead + [int]$pullDpFixtureInHead
$expectedPasses = 2 * $expectedFollowOns
Assert-Equal 0 $allExit 'all-family plan exits successfully'
Assert-True ($allText -like "*10 family/families, $expectedFollowOns follow-on fixture(s), $expectedPasses develop deployment pass(es).*") 'all-family plan has the expected revision matrix'
Assert-True ($allText -like '*CSTEST8-B-Other Domain and more.json*') 'all-family plan includes the multi-domain follow-on'
if ($mutationFixtureInHead) {
    Assert-True ($allText.Contains('CSTest3-D-MutateExistingSiteSystem.json [existing-VM mutation]')) 'all-family plan includes the live existing-VM mutation lane'
}
else {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $mutationFixtureGitPath)) 'uncommitted mutation fixture exists for the pending publication'
}
if ($proxyLinuxFixtureInHead) {
    Assert-True ($allText.Contains('CSTest5-C-AddProxyLinux.json')) 'all-family plan includes the Proxy/Linux upgrade fixture'
}
else {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $proxyLinuxFixtureGitPath)) 'uncommitted Proxy/Linux fixture exists for the pending publication'
}
if ($pullDpFixtureInHead) {
    Assert-True ($allText.Contains('PSTest2-F-AddPullDP.json')) 'all-family plan includes the pull-DP upgrade fixture'
}
else {
    Assert-True (Test-Path -LiteralPath (Join-Path $repoRoot $pullDpFixtureGitPath)) 'uncommitted pull-DP fixture exists for the pending publication'
}
Assert-Equal $false (Test-Path -LiteralPath $stateRoot) 'plan-only mode creates no state or worktree directory'

$singleOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $runnerPath `
        -RepositoryRoot $repoRoot -Test NOCM -PlanOnly -StateRoot $stateRoot 2>&1 | ForEach-Object { "$_" })
$singleExit = $LASTEXITCODE
$singleText = $singleOutput -join [Environment]::NewLine
Assert-Equal 0 $singleExit 'single-family plan exits successfully'
Assert-True ($singleText -like '*1 family/families, 7 follow-on fixture(s), 14 develop deployment pass(es).*') 'single-family plan selects NOCM only'
Assert-True ($singleText -notlike '*CSTest1-A-CSPS.json*') 'single-family plan excludes unrelated families'
Assert-Equal $false (Test-Path -LiteralPath $stateRoot) 'single-family plan remains non-mutating'

$newLabText = [IO.File]::ReadAllText($newLabPath)
$phasesText = [IO.File]::ReadAllText($phasesPath)
$runnerText = [IO.File]::ReadAllText($runnerPath)
$startTestText = [IO.File]::ReadAllText($startTestPath)
Assert-True ($newLabText -notmatch '\$global:StartPhase\s*=') 'New-Lab does not reassign its validated StartPhase parameter in global scope'
Assert-True ($newLabText -match '\$global:MemLabsStartPhase\s*=\s*\[int\]\$StartPhase') 'New-Lab publishes the phase mode under a non-parameter global name'
Assert-True ($phasesText -match '\$global:MemLabsStartPhase') 'phase preparation consumes the non-parameter start-phase flag'
Assert-True ($newLabText -match 'AdditionalInfo\s+\(\$deployConfig\s+\|\s+ConvertTo-Json\s+-Depth\s+12\)') 'New-Lab crash details serialize the complete deployment config'
Assert-True ($runnerText -match '\[switch\]\s*\$PauseAtFamilyBoundary' -and
    $runnerText -match '(?s)FAMILY BOUNDARY:.+?exit 56') 'runner checkpoints and returns only at a completed family boundary'
Assert-True ($startTestText -match "Invoke-MixedRevisionGitRefresh -Context 'between mixed-revision families'" -and
    $startTestText -match '\$exitCode -ne 56' -and
    $startTestText -match 'Restarting mixed-revision runner at develop') 'Start-Test pulls and relaunches the runner between families'
$mixedCycleText = (Import-TestFunction -Path $startTestPath -Name 'Invoke-MainToDevelopExpansionCycle').ToString()
$allSelectorIndex = $mixedCycleText.IndexOf("`$arguments += '-All'")
$testSelectorIndex = $mixedCycleText.IndexOf("`$arguments += @('-Test', `$TestPrefix)")
$boundarySwitchIndex = $mixedCycleText.IndexOf("`$arguments += '-PauseAtFamilyBoundary'")
Assert-True ($allSelectorIndex -ge 0 -and $testSelectorIndex -ge 0 -and
    $boundarySwitchIndex -gt $allSelectorIndex -and $boundarySwitchIndex -gt $testSelectorIndex) `
    'all and multi-family prefix selections both enable family-boundary refresh'
Assert-True ($startTestText -match '\$forwardResetState\s*=\s*\$ResetState\.IsPresent' -and
    $startTestText -match 'if \(\$forwardResetState\) \{ \$arguments \+= ''-ResetState'' \}' -and
    $startTestText -match '\$forwardResetState\s*=\s*\$false') 'cross-revision reset is forwarded only to the first runner process'
Assert-True ($startTestText -match "Invoke-MixedRevisionGitRefresh -Context 'before mixed-revision cycle'") 'live mixed cycle refreshes develop before pinning its first family'
Assert-True ($startTestText -match 'Mixed-revision plan-only mode uses the current committed HEAD without pulling') 'plan-only mixed cycle remains non-mutating'
$branchGuardIndex = $startTestText.IndexOf("A live main-to-develop cycle must run from the develop branch")
$mixedPullIndex = $startTestText.IndexOf("Invoke-MixedRevisionGitRefresh -Context 'before mixed-revision cycle'")
Assert-True ($branchGuardIndex -ge 0 -and $mixedPullIndex -gt $branchGuardIndex) 'mixed-mode branch validation runs before git pull'
Assert-True ($startTestText -match "(?s)function Invoke-MixedRevisionGitRefresh.+?Global\\MemLabsTestMutationLock.+?Invoke-TestGitPull.+?rev-parse HEAD.+?ReleaseMutex") `
    'mixed-mode pull and revision pin are serialized by the host mutation lock'

$scopeTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-child-scope-$PID"
$legacyScriptPath = Join-Path $scopeTestRoot 'Legacy-New-Lab.ps1'
$parameterPath = Join-Path $scopeTestRoot 'parameters.clixml'
$resultPath = Join-Path $scopeTestRoot 'result.txt'
$exitScriptPath = Join-Path $scopeTestRoot 'Exit-Code.ps1'
$continueScriptPath = Join-Path $scopeTestRoot 'Continue-Error.ps1'
$resumeScriptPath = Join-Path $scopeTestRoot 'Resume-Metadata.ps1'
$launcherResultPath = Join-Path $scopeTestRoot 'launcher-result.json'
$launcherPidPath = Join-Path $scopeTestRoot 'launcher.pid'
try {
    $null = New-Item -ItemType Directory -Path $scopeTestRoot -Force
    [IO.File]::WriteAllText($legacyScriptPath, @'
[CmdletBinding()]
param(
    [ValidateRange(2, 11)]
    [int] $StartPhase,
    [Parameter(Mandatory = $true)]
    [string] $ResultPath
)
$ErrorActionPreference = 'Stop'
$global:StartPhase = $StartPhase
[IO.File]::WriteAllText($ResultPath, "$StartPhase|$global:StartPhase")
'@)

    $directOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $legacyScriptPath -ResultPath $resultPath 2>&1 |
            ForEach-Object { "$_" })
    $directExit = $LASTEXITCODE
    Assert-True ($directExit -ne 0 -and ($directOutput -join "`n") -like '*not a valid value for the StartPhase variable*') `
        'legacy direct-file invocation reproduces the omitted StartPhase validation failure'

    [ordered]@{ ResultPath = $resultPath } | Export-Clixml -LiteralPath $parameterPath
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $childLauncherPath `
        -ScriptPath $legacyScriptPath -ParameterPath $parameterPath -PidPath $launcherPidPath
    Assert-Equal 0 $LASTEXITCODE 'child launcher isolates the legacy validated parameter from global scope'
    Assert-Equal '0|0' (Get-Content -LiteralPath $resultPath -Raw) 'child launcher preserves omitted StartPhase semantics'
    $launcherIdentity = Get-Content -LiteralPath $launcherPidPath -Raw | ConvertFrom-Json
    Assert-True ([int]$launcherIdentity.ProcessId -gt 0 -and $launcherIdentity.StartTimeUtc) `
        'child launcher publishes its process identity for cancellation cleanup'

    [ordered]@{ StartPhase = 5; ResultPath = $resultPath } | Export-Clixml -LiteralPath $parameterPath
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $childLauncherPath `
        -ScriptPath $legacyScriptPath -ParameterPath $parameterPath
    Assert-Equal 0 $LASTEXITCODE 'child launcher accepts an explicit valid StartPhase'
    Assert-Equal '5|5' (Get-Content -LiteralPath $resultPath -Raw) 'child launcher forwards named parameters without coercion'

    [IO.File]::WriteAllText($exitScriptPath, '[CmdletBinding()] param([int] $Code) exit $Code')
    [ordered]@{ Code = 55 } | Export-Clixml -LiteralPath $parameterPath
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $childLauncherPath `
        -ScriptPath $exitScriptPath -ParameterPath $parameterPath
    Assert-Equal 55 $LASTEXITCODE 'child launcher preserves restart exit codes'

    [IO.File]::WriteAllText($resumeScriptPath, @'
[CmdletBinding()]
param()
$global:NewLabResumeCommand = './New-Lab.ps1 -Configuration "fixture.json" -startPhase 8 -restore'
$global:NewLabResumeInfo = [pscustomobject]@{
    Configuration = 'fixture.json'
    Phase = 8
    Restore = $true
}
exit 2
'@)
    [ordered]@{} | Export-Clixml -LiteralPath $parameterPath
    $resultToken = [guid]::NewGuid().ToString('N')
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $childLauncherPath `
        -ScriptPath $resumeScriptPath -ParameterPath $parameterPath `
        -InvocationToken $resultToken -ResultPath $launcherResultPath
    Assert-Equal 2 $LASTEXITCODE 'child launcher preserves failed deployment exit code while publishing a result'
    $launcherResult = Get-Content -LiteralPath $launcherResultPath -Raw | ConvertFrom-Json
    Assert-Equal $resultToken $launcherResult.InvocationToken 'child result is bound to its invocation token'
    Assert-Equal 8 $launcherResult.ResumeInfo.Phase 'child result carries structured resume phase'
    Assert-Equal $true $launcherResult.ResumeInfo.Restore 'child result carries structured restore mode'

    [IO.File]::WriteAllText($continueScriptPath, @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ResultPath)
Get-Item -LiteralPath (Join-Path $env:TEMP 'memlabs-intentionally-missing') -ErrorAction Continue
[IO.File]::WriteAllText($ResultPath, 'continued')
'@)
    [ordered]@{ ResultPath = $resultPath } | Export-Clixml -LiteralPath $parameterPath
    $continueOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $childLauncherPath `
            -ScriptPath $continueScriptPath -ParameterPath $parameterPath 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'child launcher preserves the default non-terminating error behavior'
    Assert-Equal 'continued' (Get-Content -LiteralPath $resultPath -Raw) 'child launcher does not abort after a non-terminating child error'
    Assert-True (($continueOutput -join "`n") -like '*memlabs-intentionally-missing*') 'child launcher still reports non-terminating child errors'
}
finally {
    Remove-Item -LiteralPath $scopeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

. (Import-TestFunction -Path $runnerPath -Name Invoke-Git)
. (Import-TestFunction -Path $runnerPath -Name Test-CrossRevisionStateProgress)
. (Import-TestFunction -Path $runnerPath -Name Get-ActiveCrossRevisionCheckpoint)
. (Import-TestFunction -Path $runnerPath -Name Test-GitCommitAncestor)
. (Import-TestFunction -Path $runnerPath -Name Assert-CrossRevisionCheckpointCanAdvance)
. (Import-TestFunction -Path $runnerPath -Name Move-CrossRevisionCheckpoint)
. (Import-TestFunction -Path $runnerPath -Name Write-CrossRevisionStateFile)
. (Import-TestFunction -Path $runnerPath -Name Reset-CrossRevisionFamilyState)
. (Import-TestFunction -Path $runnerPath -Name Resolve-CrossRevisionResetFamily)
. (Import-TestFunction -Path $runnerPath -Name Resolve-CrossRevisionActiveResetFamily)
. (Import-TestFunction -Path $runnerPath -Name ConvertTo-CrossRevisionNormalizedPath)
. (Import-TestFunction -Path $runnerPath -Name Assert-CrossRevisionPathLayout)
. (Import-TestFunction -Path $runnerPath -Name Initialize-PinnedWorktree)
. (Import-TestFunction -Path $runnerPath -Name Initialize-WorktreeLogPath)
. (Import-TestFunction -Path $runnerPath -Name Initialize-ExistingCrossRevisionLogPaths)
. (Import-TestFunction -Path $runnerPath -Name Publish-CrossRevisionSshCacheFromWorktree)
. (Import-TestFunction -Path $runnerPath -Name Initialize-WorktreeSshCache)
. (Import-TestFunction -Path $runnerPath -Name Initialize-WorktreeRuntime)
. (Import-TestFunction -Path $runnerPath -Name Set-CrossRevisionCanonicalVmBuildShortcut)
$stopLauncherFunction = Import-TestFunction -Path $runnerPath -Name Stop-CrossRevisionLauncher
$invokeChildFunction = Import-TestFunction -Path $runnerPath -Name Invoke-ChildScript
. $stopLauncherFunction
. $invokeChildFunction
. (Import-TestFunction -Path $runnerPath -Name Get-OrderedCrossRevisionPlan)
. (Import-TestFunction -Path $runnerPath -Name Get-FullVmName)
. (Import-TestFunction -Path $runnerPath -Name Get-ExpectedVmNames)
. (Import-TestFunction -Path $runnerPath -Name Get-DomainVms)
. (Import-TestFunction -Path $runnerPath -Name Get-ExistingNamedVms)
. (Import-TestFunction -Path $runnerPath -Name Resolve-CrossRevisionVhdBasePath)
. (Import-TestFunction -Path $runnerPath -Name Get-CrossRevisionVmDiskIdentity)
. (Import-TestFunction -Path $runnerPath -Name Test-CrossRevisionLegacySnapshotDiskMatch)
. (Import-TestFunction -Path $runnerPath -Name Get-VmIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-BaselineIdentity)
. (Import-TestFunction -Path $runnerPath -Name Save-CrossRevisionExpansionIdentity)
. (Import-TestFunction -Path $runnerPath -Name Get-CrossRevisionMaintenanceTargets)
. (Import-TestFunction -Path $runnerPath -Name Assert-DevelopStageComplete)
. (Import-TestFunction -Path $runnerPath -Name Resolve-CrossRevisionDomainNetBiosName)
. (Import-TestFunction -Path $runnerPath -Name New-DomainCredentials)
. (Import-TestFunction -Path $runnerPath -Name New-DomainCredential)
. (Import-TestFunction -Path $runnerPath -Name Invoke-CrossRevisionDomainProbe)
. (Import-TestFunction -Path $runnerPath -Name Wait-CrossRevisionRetainedVmReady)
. (Import-TestFunction -Path $runnerPath -Name Get-DomainIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainJoinedVmHealth)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainsAbsent)
. (Import-TestFunction -Path $runnerPath -Name Assert-MainBaselineCanStart)
. (Import-TestFunction -Path $runnerPath -Name Repair-InterruptedMainBaseline)
. (Import-TestFunction -Path $runnerPath -Name Get-CrossRevisionAncestorProcessIds)
. (Import-TestFunction -Path $runnerPath -Name Save-State)
. (Import-TestFunction -Path $runnerPath -Name Test-StepComplete)
. (Import-TestFunction -Path $runnerPath -Name Test-StepInProgress)
. (Import-TestFunction -Path $runnerPath -Name Start-Step)
. (Import-TestFunction -Path $runnerPath -Name Complete-Step)

$shortcutTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-shortcut-$PID"
try {
    $shortcutRepo = Join-Path $shortcutTestRoot 'repo'
    $shortcutVmbuild = Join-Path $shortcutRepo 'vmbuild'
    $shortcutPath = Join-Path $shortcutTestRoot 'MEMLABS - VMBuild.lnk'
    $null = New-Item -ItemType Directory -Path $shortcutVmbuild -Force
    [IO.File]::WriteAllText((Join-Path $shortcutVmbuild 'VMBuild.cmd'), '@echo off')

    Set-CrossRevisionCanonicalVmBuildShortcut -RepositoryRoot $shortcutRepo -ShortcutPath $shortcutPath
    $shortcutShell = New-Object -ComObject WScript.Shell
    $shortcut = $shortcutShell.CreateShortcut($shortcutPath)
    try {
        Assert-Equal (Join-Path $shortcutVmbuild 'VMBuild.cmd') $shortcut.TargetPath `
            'cross-revision shortcut repair targets the canonical launcher'
        Assert-Equal $shortcutVmbuild $shortcut.WorkingDirectory `
            'cross-revision shortcut repair restores the canonical working directory'
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcutShell)
    }
    $shortcutBytes = [IO.File]::ReadAllBytes($shortcutPath)
    Assert-True (($shortcutBytes[0x15] -band 0x20) -ne 0) `
        'cross-revision shortcut repair preserves run-as-administrator'
}
finally {
    Remove-Item -LiteralPath $shortcutTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$newLabText = Get-Content -LiteralPath $newLabPath -Raw
Assert-True ($newLabText -match 'MEMLABS_CANONICAL_REPOSITORY_ROOT' -and
    $newLabText -match '\$shortcut\.WorkingDirectory\s*=\s*\$scriptDirectory') `
    'New-Lab honors the canonical repository root supplied by the runner'
$invokeChildText = (Import-TestFunction -Path $runnerPath -Name Invoke-ChildScript).ToString()
Assert-True ($invokeChildText -match 'MEMLABS_CANONICAL_REPOSITORY_ROOT' -and
    $invokeChildText -match 'Set-CrossRevisionCanonicalVmBuildShortcut') `
    'pinned child invocation propagates and restores the canonical shortcut target'

$processMap = @{
    100 = [pscustomobject]@{ ProcessId = 100; ParentProcessId = 200 }
    200 = [pscustomobject]@{ ProcessId = 200; ParentProcessId = 300 }
    300 = [pscustomobject]@{ ProcessId = 300; ParentProcessId = 0 }
}
$ancestorIds = @(Get-CrossRevisionAncestorProcessIds -ProcessId 100 -ProcessResolver {
        param($Id)
        return $processMap[$Id]
    })
Assert-Equal '100,200,300' ($ancestorIds -join ',') `
    'competing-runner guard excludes the complete launching process chain'

$cancelRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-cancel-$PID"
$cancelSource = Join-Path $cancelRoot 'source'
$cancelState = Join-Path $cancelRoot 'state'
$cancelWorktree = Join-Path $cancelRoot 'worktree'
$cancelMarker = Join-Path $cancelRoot 'started.txt'
$cancelPids = Join-Path $cancelRoot 'pids.txt'
$cancelConsole = Join-Path $cancelRoot 'console.txt'
$cancelCheckpoint = Join-Path $cancelRoot 'checkpoint.txt'
$cancelLocationResult = Join-Path $cancelRoot 'location.txt'
$cancelPs = $null
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $cancelSource 'vmbuild\logs') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $cancelWorktree 'vmbuild') -Force
    $cancelChild = Join-Path $cancelWorktree 'vmbuild\CancelChild.ps1'
    $cancelDescendant = Join-Path $cancelWorktree 'vmbuild\Cancel Descendant.ps1'
    [IO.File]::WriteAllText($cancelDescendant, @'
param([string] $ConsolePath)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class CancellationConsoleNative { [DllImport("kernel32.dll", ExactSpelling=true)] public static extern IntPtr GetConsoleWindow(); }' -ErrorAction Stop
[IO.File]::WriteAllText($ConsolePath, [CancellationConsoleNative]::GetConsoleWindow().ToInt64().ToString())
Start-Sleep -Seconds 120
'@)
    [IO.File]::WriteAllText($cancelChild, @'
param([string] $MarkerPath, [string] $PidPath, [string] $DescendantPath, [string] $ConsolePath)
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $DescendantPath, '-ConsolePath', $ConsolePath)) {
    $null = $startInfo.ArgumentList.Add($argument)
}
$descendant = [Diagnostics.Process]::Start($startInfo)
[IO.File]::WriteAllText($PidPath, "$PID|$($descendant.Id)")
[IO.File]::WriteAllText($MarkerPath, 'started')
Start-Sleep -Seconds 120
'@)
    [IO.File]::WriteAllText($cancelCheckpoint, 'preserve-me')

    $cancelScript = {
        param(
            [string] $StopFunctionText,
            [string] $InvokeFunctionText,
            [string] $Repository,
            [string] $State,
            [string] $Worktree,
            [string] $Launcher,
            [string] $Pwsh,
            [string] $Marker,
            [string] $Pids,
            [string] $Descendant,
            [string] $Console,
            [string] $LocationResult
        )
        . ([scriptblock]::Create($StopFunctionText))
        . ([scriptblock]::Create($InvokeFunctionText))
        $global:RepositoryRoot = $Repository
        $StateRoot = $State
        $script:ChildLauncherPath = $Launcher
        $pwshPath = $Pwsh
        $initialLocation = (Get-Location).Path
        try {
            Invoke-ChildScript -WorktreePath $Worktree -ScriptName 'CancelChild.ps1' `
                -Parameters ([ordered]@{ MarkerPath = $Marker; PidPath = $Pids; DescendantPath = $Descendant; ConsolePath = $Console }) -Label 'cancel-test'
        }
        finally {
            [IO.File]::WriteAllText($LocationResult, "$(Get-Location)")
            if ((Get-Location).Path -ne $initialLocation) { throw 'Invoke-ChildScript did not restore the caller location.' }
        }
    }
    $cancelPs = [powershell]::Create()
    $null = $cancelPs.AddScript($cancelScript).
        AddArgument($stopLauncherFunction.ToString()).
        AddArgument($invokeChildFunction.ToString()).
        AddArgument($cancelSource).
        AddArgument($cancelState).
        AddArgument($cancelWorktree).
        AddArgument($childLauncherPath).
        AddArgument($pwshPath).
        AddArgument($cancelMarker).
        AddArgument($cancelPids).
        AddArgument($cancelDescendant).
        AddArgument($cancelConsole).
        AddArgument($cancelLocationResult)
    $cancelAsync = $cancelPs.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((-not (Test-Path -LiteralPath $cancelMarker -PathType Leaf) -or
            -not (Test-Path -LiteralPath $cancelConsole -PathType Leaf)) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    $publishedPids = if (Test-Path -LiteralPath $cancelPids) {
        @((Get-Content -LiteralPath $cancelPids -Raw).Trim() -split '\|' | ForEach-Object { [int]$_ })
    }
    else {
        @()
    }
    Assert-Equal 2 $publishedPids.Count 'cancellation fixture publishes launcher and descendant IDs'
    $consoleHandle = if (Test-Path -LiteralPath $cancelConsole -PathType Leaf) {
        (Get-Content -LiteralPath $cancelConsole -Raw).Trim()
    } else { '<missing>' }
    Assert-Equal '0' $consoleHandle 'cancellation descendant starts without a console or Terminal window'
    if ($publishedPids.Count -eq 2) {
        Assert-True ($null -ne (Get-Process -Id $publishedPids[1] -ErrorAction SilentlyContinue)) `
            'windowless cancellation descendant is alive before teardown'
    }
    $cancelPs.Stop()
    try { $null = $cancelPs.EndInvoke($cancelAsync) } catch [Management.Automation.PipelineStoppedException] { }
    Start-Sleep -Seconds 1
    Assert-Equal $null (Get-Process -Id $publishedPids[0] -ErrorAction SilentlyContinue) 'cancellation cleanup stops the launcher process'
    Assert-Equal $null (Get-Process -Id $publishedPids[1] -ErrorAction SilentlyContinue) 'launcher Job Object stops descendant workers'
    Assert-Equal 'preserve-me' (Get-Content -LiteralPath $cancelCheckpoint -Raw) 'cancellation preserves checkpoint state'
    Assert-True (Test-Path -LiteralPath $cancelLocationResult -PathType Leaf) 'cancellation executes location-restoration finally blocks'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $cancelState -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '.child-*' }).Count 'cancellation removes temporary launcher artifacts'
}
finally {
    if ($cancelPs) { $cancelPs.Dispose() }
    foreach ($processId in @($publishedPids)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $cancelRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$global:RepositoryRoot = $repoRoot
try {
    Assert-CrossRevisionPathLayout -Repository $repoRoot -Root (Join-Path $env:ProgramData 'MemLabs\CrossRevision')
    Write-TestResult -Passed $true -What 'default state root is outside the source log tree'
}
catch {
    Write-TestResult -Passed $false -What 'default state root is outside the source log tree' -Detail $_.Exception.Message
}
Assert-ThrowsLike -Action {
    Assert-CrossRevisionPathLayout -Repository $repoRoot -Root (Join-Path $repoRoot 'vmbuild\logs')
} -Pattern '*cannot be inside the source repository*' -What 'state root cannot be inside the source repository'
Assert-ThrowsLike -Action {
    Assert-CrossRevisionPathLayout -Repository $repoRoot -Root ("\\?\" + (Join-Path $repoRoot 'vmbuild\logs\CrossRevision\state'))
} -Pattern '*cannot be inside the source repository*' -What 'extended paths cannot bypass source-repository containment'

$pathAliasRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-state-alias-$PID"
$pathAliasTarget = Join-Path $pathAliasRoot 'target'
$pathAlias = Join-Path $pathAliasRoot 'alias'
try {
    $null = New-Item -ItemType Directory -Path $pathAliasTarget -Force
    $null = New-Item -ItemType Junction -Path $pathAlias -Target $pathAliasTarget
    Assert-ThrowsLike -Action {
        Assert-CrossRevisionPathLayout -Repository $repoRoot -Root (Join-Path $pathAlias 'state')
    } -Pattern '*cannot traverse reparse point*' -What 'state root cannot traverse a junction alias'
}
finally {
    if (Test-Path -LiteralPath $pathAlias) { Remove-Item -LiteralPath $pathAlias -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $pathAliasRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$transcriptTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-transcripts-$PID"
$transcriptSource = Join-Path $transcriptTestRoot 'source'
$transcriptWorktree = Join-Path $transcriptTestRoot 'worktree'
$transcriptState = Join-Path $transcriptTestRoot 'state'
$transcriptMarker = Join-Path $transcriptTestRoot 'child-ran.txt'
$transcriptPriorRepositoryRoot = $global:RepositoryRoot
$transcriptPriorStateRoot = $StateRoot
$transcriptPriorLauncherPath = $script:ChildLauncherPath
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $transcriptSource 'vmbuild\logs') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $transcriptWorktree 'vmbuild') -Force
    $childScript = Join-Path $transcriptWorktree 'vmbuild\Child.ps1'
    [IO.File]::WriteAllText($childScript, @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $MarkerPath)
[IO.File]::WriteAllText($MarkerPath, 'ran')
Write-Output 'TRANSCRIPT:runner-output'
'@)
    $global:RepositoryRoot = $transcriptSource
    $StateRoot = $transcriptState
    $script:ChildLauncherPath = $childLauncherPath

    $childExit = Invoke-ChildScript -WorktreePath $transcriptWorktree -ScriptName 'Child.ps1' `
        -Parameters ([ordered]@{ MarkerPath = $transcriptMarker }) -Label 'runner-output'
    $sharedTranscript = Join-Path $transcriptSource 'vmbuild\logs\CrossRevision\Runner\runner-output.log'
    Assert-Equal 0 $childExit 'runner transcript preserves successful child exit code'
    Assert-Equal 'ran' (Get-Content -LiteralPath $transcriptMarker -Raw) 'child runs after the normal log path is writable'
    Assert-True ((Get-Content -LiteralPath $sharedTranscript -Raw) -like '*TRANSCRIPT:runner-output*') `
        'runner transcript is written under the normal log directory'

    $nativeExitScript = Join-Path $transcriptWorktree 'vmbuild\NativeExit.ps1'
    [IO.File]::WriteAllText($nativeExitScript, '[CmdletBinding()] param([int] $Code) exit $Code')
    $oldNativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $true
        foreach ($expectedExit in @(55, 23)) {
            $actualExit = Invoke-ChildScript -WorktreePath $transcriptWorktree -ScriptName 'NativeExit.ps1' `
                -Parameters ([ordered]@{ Code = $expectedExit }) -Label "native-exit-$expectedExit"
            Assert-Equal $expectedExit $actualExit "native error promotion does not reclassify exit $expectedExit as cancellation"
        }
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $oldNativePreference
    }

    Remove-Item -LiteralPath $transcriptMarker -Force
    $blockedSharedPath = Join-Path $transcriptSource 'vmbuild\logs\CrossRevision\Runner\blocked-transcript.log'
    $null = New-Item -ItemType Directory -Path $blockedSharedPath -Force
    Assert-ThrowsLike -Action {
        Invoke-ChildScript -WorktreePath $transcriptWorktree -ScriptName 'Child.ps1' `
            -Parameters ([ordered]@{ MarkerPath = $transcriptMarker }) -Label 'blocked-transcript'
    } -Pattern '*Access to the path*is denied*' -What 'unwritable shared transcript prevents a successful child invocation'
    Assert-Equal $false (Test-Path -LiteralPath $transcriptMarker) 'child is not run when shared transcript preflight fails'
}
finally {
    $global:RepositoryRoot = $transcriptPriorRepositoryRoot
    $StateRoot = $transcriptPriorStateRoot
    $script:ChildLauncherPath = $transcriptPriorLauncherPath
    Remove-Item -LiteralPath $transcriptTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$checkpointTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-checkpoints-$PID"
$checkpointMain = '1111111111111111111111111111111111111111'
$requestedDevelop = '2222222222222222222222222222222222222222'
$activeDevelop = '3333333333333333333333333333333333333333'
$secondActiveDevelop = '4444444444444444444444444444444444444444'
try {
    $null = New-Item -ItemType Directory -Path $checkpointTestRoot -Force
    $emptyFailedPath = Join-Path $checkpointTestRoot 'state-11111111-to-22222222.json'
    [IO.File]::WriteAllText($emptyFailedPath, ([ordered]@{
                MainRevision = $checkpointMain
                DevelopRevision = $requestedDevelop
                Status = 'Failed'
                CurrentStep = $null
                CompletedSteps = @()
                Baselines = @{}
            } | ConvertTo-Json -Depth 6))
    Assert-Equal $null (Get-ActiveCrossRevisionCheckpoint -Root $checkpointTestRoot -MainCommit $checkpointMain) `
        'empty failed checkpoint does not claim an existing baseline'

    $activePath = Join-Path $checkpointTestRoot 'state-11111111-to-33333333.json'
    [IO.File]::WriteAllText($activePath, ([ordered]@{
                MainRevision = $checkpointMain
                DevelopRevision = $activeDevelop
                Status = 'Failed'
                CurrentStep = 'nocm|develop|1|NOCM-B-AddWin11.json'
                CompletedSteps = @('nocm|main|A')
                Baselines = @{ nocm = @(@{ Name = 'NOC-DC1' }) }
            } | ConvertTo-Json -Depth 6))

    $checkpoint = Get-ActiveCrossRevisionCheckpoint -Root $checkpointTestRoot -MainCommit $checkpointMain
    Assert-Equal $activeDevelop $checkpoint.DevelopRevision 'active checkpoint keeps its original develop revision'
    Assert-Equal $activePath $checkpoint.Path 'empty failed state for newer develop is not adopted'

    $secondActivePath = Join-Path $checkpointTestRoot 'state-11111111-to-44444444.json'
    [IO.File]::WriteAllText($secondActivePath, ([ordered]@{
                MainRevision = $checkpointMain
                DevelopRevision = $secondActiveDevelop
                Status = 'Running'
                CurrentStep = $null
                CompletedSteps = @('cstest1|main|A')
                Baselines = @{ cstest1 = @(@{ Name = 'CS1-DC1' }) }
            } | ConvertTo-Json -Depth 6))
    Assert-ThrowsLike -Action {
        Get-ActiveCrossRevisionCheckpoint -Root $checkpointTestRoot -MainCommit $checkpointMain
    } -Pattern '*Multiple active checkpoints*' -What 'multiple active revision pairs fail closed'

    Remove-Item -LiteralPath $secondActivePath -Force
    $activeState = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json -AsHashtable
    $migratedPath = Move-CrossRevisionCheckpoint -ActivePath $activePath -State $activeState `
        -Root $checkpointTestRoot -MainCommit $checkpointMain -NewDevelopCommit $requestedDevelop
    Assert-Equal $emptyFailedPath $migratedPath 'rolling checkpoint replaces the empty failed state for requested develop'
    $migratedState = Get-Content -LiteralPath $migratedPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal $requestedDevelop $migratedState.DevelopRevision 'rolling checkpoint records requested develop'
    Assert-Equal 'nocm|develop|1|NOCM-B-AddWin11.json' $migratedState.CurrentStep 'rolling checkpoint preserves the failed follow-on step'
    Assert-Equal 'NOC-DC1' $migratedState.Baselines.nocm[0].Name 'rolling checkpoint preserves exact-main VM identity'
    Assert-Equal 'RollingDevelop' $migratedState.QualificationMode 'rolling checkpoint is not labeled as a pinned qualification'
    Assert-Equal 2 @($migratedState.DevelopRevisionHistory).Count 'rolling checkpoint records both develop revisions'
    Assert-Equal $false (Test-Path -LiteralPath $activePath) 'superseded active state no longer competes for resume'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $checkpointTestRoot -Filter '*.superseded-by-*' -File).Count `
        'superseded checkpoint is retained outside active-state discovery'
    $migratedCheckpoint = Get-ActiveCrossRevisionCheckpoint -Root $checkpointTestRoot -MainCommit $checkpointMain
    Assert-Equal $requestedDevelop $migratedCheckpoint.DevelopRevision 'active checkpoint discovery follows the migrated state'
}
finally {
    Remove-Item -LiteralPath $checkpointTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$rollingOldDevelop = (& git -C $repoRoot rev-parse 30389976).Trim()
$rollingNewDevelop = (& git -C $repoRoot rev-parse HEAD).Trim()
$rollingState = [ordered]@{
    MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf'
    DevelopRevision = $rollingOldDevelop
    Status = 'Failed'
    CurrentStep = 'nocm|develop|1|NOCM-B-AddWin11.json'
    CompletedSteps = @('nocm|main|A')
    Baselines = @{ nocm = @(@{ Name = 'NOC-DC1' }) }
    DomainIdentities = @{ nocm = @{ Domain = 'nocm.com'; Sid = $script:MockDomainSid } }
}
$rollingPlan = @([pscustomobject]@{
        Family = 'NOCM'
        Domains = @('nocm.com')
        FollowOns = @([pscustomobject]@{ Name = 'NOCM-B-AddWin11.json' })
    })
try {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
    Write-TestResult -Passed $true -What 'fast-forward develop can retry a failed follow-on over the saved main baseline'
}
catch {
    Write-TestResult -Passed $false -What 'fast-forward develop can retry a failed follow-on over the saved main baseline' -Detail $_.Exception.Message
}
$rollingState.CurrentStep = 'nocm|main|A'
try {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
    Write-TestResult -Passed $true -What 'interrupted exact-main checkpoint advances to current develop recovery code'
}
catch {
    Write-TestResult -Passed $false -What 'interrupted exact-main checkpoint advances to current develop recovery code' -Detail $_.Exception.Message
}
$rollingState.CurrentStep = "nocm|maintenance|post|2|NOCM-B-AddWin11.json|$rollingOldDevelop"
Assert-ThrowsLike {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
} -Pattern "*cannot advance candidates*current runner checkout*-DevelopRevision $rollingOldDevelop*" `
    -What 'interrupted maintenance preserves the candidate and explains how to use the updated runner with the old pin'
Assert-Equal $rollingOldDevelop $rollingState.DevelopRevision 'rejected maintenance advance preserves the pinned candidate'
Assert-Equal "nocm|maintenance|post|2|NOCM-B-AddWin11.json|$rollingOldDevelop" $rollingState.CurrentStep `
    'rejected maintenance advance preserves the exact interrupted qualification step'

$familyResetState = [ordered]@{
    MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf'
    DevelopRevision = $rollingOldDevelop
    Status = 'Failed'
    CurrentStep = 'cstest2|main|A'
    LastError = 'interrupted'
    CompletedSteps = @('cstest1|complete', 'cstest2|main|A')
    Baselines = @{ cstest1 = @(@{ Name = 'CT1-DC1' }); cstest2 = @(@{ Name = 'CT2-DC1' }) }
    DomainIdentities = @{ cstest1 = @{ Sid = 'sid1' }; cstest2 = @{ Sid = 'sid2' } }
    DevelopIdentities = @{
        'cstest1|fixture.json' = @(@{ Name = 'CT1-X' })
        'cstest2|fixture.json' = @(@{ Name = 'CT2-X' })
    }
    DevelopDomainIdentities = @{
        'cstest1|fixture.json' = @{ Sid = 'sid1' }
        'cstest2|fixture.json' = @{ Sid = 'sid2' }
    }
}
Assert-Equal 'CSTest2' (Resolve-CrossRevisionActiveResetFamily `
        -Plan @([pscustomobject]@{ Family = 'CSTest1' }, [pscustomobject]@{ Family = 'CSTest2' }) `
        -State $familyResetState) 'suite reset resolves only the in-progress family'
Reset-CrossRevisionFamilyState -State $familyResetState -Family 'CSTest2'
Assert-Equal $null $familyResetState.CurrentStep 'family reset clears the interrupted CSTest2 main baseline step'
Assert-Equal 'cstest1|complete' ($familyResetState.CompletedSteps -join ',') 'family reset preserves completed CSTest1 progress'
Assert-Equal $false $familyResetState.Baselines.Contains('cstest2') 'family reset removes only the interrupted baseline identity'
Assert-Equal $true $familyResetState.Baselines.Contains('cstest1') 'family reset preserves another family baseline identity'
Assert-Equal $false $familyResetState.DevelopIdentities.Contains('cstest2|fixture.json') 'family reset removes interrupted family develop identities'
Assert-Equal $true $familyResetState.DevelopIdentities.Contains('cstest1|fixture.json') 'family reset preserves other family develop identities'
Assert-Equal 'CSTest2' (Resolve-CrossRevisionResetFamily `
        -Plan @([pscustomobject]@{ Family = 'CSTest1' }, [pscustomobject]@{ Family = 'CSTest2' }) `
        -TestPrefix 'CSTest2') 'family reset resolves an exact selected family'
Assert-ThrowsLike -Action {
    Resolve-CrossRevisionResetFamily `
        -Plan @([pscustomobject]@{ Family = 'CSTest1' }, [pscustomobject]@{ Family = 'CSTest2' }) `
        -TestPrefix 'CSTest'
} -Pattern '*must resolve to exactly one family*matched 2*' -What 'family reset rejects an ambiguous test prefix'
$familyResetPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-family-reset-$PID.json"
try {
    Write-CrossRevisionStateFile -Path $familyResetPath -State $familyResetState
    $familyResetReadback = Get-Content -LiteralPath $familyResetPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal $null $familyResetReadback.CurrentStep 'family reset persists a restartable checkpoint'
    Assert-Equal 'cstest1|complete' ($familyResetReadback.CompletedSteps -join ',') 'family reset persistence keeps other family progress'
}
finally {
    Remove-Item -LiteralPath $familyResetPath -Force -ErrorAction SilentlyContinue
}
try {
    Assert-CrossRevisionCheckpointCanAdvance -State $familyResetState `
        -Plan @([pscustomobject]@{ Family = 'CSTest2'; FollowOns = @() }) `
        -NewDevelopCommit $rollingNewDevelop
    Write-TestResult -Passed $true -What 'family reset permits a fast-forward develop advance after lab removal'
}

catch {
    Write-TestResult -Passed $false -What 'family reset permits a fast-forward develop advance after lab removal' -Detail $_.Exception.Message
}

$runnerTokens = $null
$runnerErrors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$runnerTokens, [ref]$runnerErrors)
foreach ($helperName in @('Write-CrossRevisionStateFile', 'Reset-CrossRevisionFamilyState', 'Resolve-CrossRevisionResetFamily', 'Resolve-CrossRevisionActiveResetFamily')) {
    $definition = @($runnerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName
            }, $true))
    $nested = $false
    if ($definition.Count -eq 1) {
        $parent = $definition[0].Parent
        while ($parent) {
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }
            $parent = $parent.Parent
        }
    }
    Assert-True ($definition.Count -eq 1 -and -not $nested) "$helperName is callable from runner script scope"
}
$mainLockIndex = $runnerText.LastIndexOf('$script:MutationMutex = [Threading.Mutex]::new')
$processGuardIndex = $runnerText.LastIndexOf('Assert-NoOtherMemLabsRunner')
$familyResetCallIndex = $runnerText.IndexOf('Reset-CrossRevisionFamilyState -State $checkpointState')
Assert-True ($mainLockIndex -ge 0 -and $familyResetCallIndex -gt $mainLockIndex) `
    'mutation lock is acquired before checkpoint family-reset writes'
Assert-True ($processGuardIndex -gt $mainLockIndex -and
    $processGuardIndex -lt $familyResetCallIndex) `
    'competing-process guard runs before checkpoint family-reset writes'
Assert-True ($runnerText -notmatch 'Move-Item -LiteralPath \$activeCheckpoint\.Path' -and
    $runnerText -match 'refusing to archive completed family progress') `
    'repeated reset cannot archive a checkpoint after its active family was already cleared'
Assert-True ($runnerText.LastIndexOf('Assert-CrossRevisionCheckpointCanAdvance -State $checkpointState') -lt
    $runnerText.LastIndexOf('Write-Host "ROLLING RESUME: preserving')) `
    'rolling resume is announced only after candidate advancement has been permitted'
$rollingState.CurrentStep = 'nocm|cleanup|nocm.com'
try {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
    Write-TestResult -Passed $true -What 'rolling cleanup adopts fast-forward develop fixes'
}
catch {
    Write-TestResult -Passed $false -What 'rolling cleanup adopts fast-forward develop fixes' -Detail $_.Exception.Message
}
$rollingState.CurrentStep = 'nocm|cleanup|renamed.example'
Assert-ThrowsLike -Action {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
} -Pattern '*cleanup domain*not present exactly once*' -What 'rolling cleanup requires the same domain in the new plan'
$rollingState.CurrentStep = 'nocm|develop|1|Renamed-Fixture.json'
Assert-ThrowsLike -Action {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingNewDevelop
} -Pattern '*in-progress fixture*not present*' -What 'rolling develop requires the failed fixture to remain in the new plan'
$rollingState.CurrentStep = 'nocm|develop|1|NOCM-B-AddWin11.json'
$rollingState.DevelopRevision = $rollingNewDevelop
Assert-ThrowsLike -Action {
    Assert-CrossRevisionCheckpointCanAdvance -State $rollingState -Plan $rollingPlan -NewDevelopCommit $rollingOldDevelop
} -Pattern '*not an ancestor*Rolling resume only supports fast-forward*' -What 'rolling develop rejects backward or divergent revision changes'

$resumePlan = @(
    [pscustomobject]@{ Family = 'CSTest1' }
    [pscustomobject]@{ Family = 'NOCM' }
)
$orderedResumePlan = @(Get-OrderedCrossRevisionPlan -Plan $resumePlan -CurrentStep 'nocm|develop|1|NOCM-B-AddWin11.json')
Assert-Equal 'NOCM' $orderedResumePlan[0].Family 'in-progress family is resumed before other selected families'
Assert-ThrowsLike -Action {
    Get-OrderedCrossRevisionPlan -Plan @([pscustomobject]@{ Family = 'CSTest1' }) -CurrentStep 'nocm|main|A'
} -Pattern '*not in this selection*' -What 'selection cannot bypass an in-progress family'

Assert-Equal 'NOC-DC1' (Get-FullVmName -Prefix 'NOC-' -VmName 'DC1') 'fixture VM names receive their prefix'
Assert-Equal 'NOC-DC1' (Get-FullVmName -Prefix 'NOC-' -VmName 'NOC-DC1') 'already-prefixed VM names are not doubled'

$sourceRepoRoot = $repoRoot
$gitTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-git-$PID"
$gitTestRepo = Join-Path $gitTestRoot 'repo'
$gitTestWorktree = Join-Path $gitTestRoot 'develop-worktree'
$priorStateRoot = $StateRoot
$priorRequireCleanSource = $RequireCleanSource
try {
    $null = New-Item -ItemType Directory -Path $gitTestRepo -Force
    & git -C $gitTestRepo init -q
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize temporary Git repository.' }
    foreach ($directory in @(
            (Join-Path $gitTestRepo 'vmbuild\config'),
            (Join-Path $gitTestRepo 'vmbuild\azureFiles'),
            (Join-Path $gitTestRepo 'vmbuild\cache'),
            (Join-Path $gitTestRepo 'vmbuild\logs')
        )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText((Join-Path $gitTestRepo '.gitignore'), "/vmbuild/azureFiles`n/vmbuild/cache`n/vmbuild/logs`n")
    [IO.File]::WriteAllText((Join-Path $gitTestRepo 'vmbuild\config\placeholder.txt'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $gitTestRepo 'fixture.txt'), 'fixture')
    & git -C $gitTestRepo add .gitignore fixture.txt vmbuild/config/placeholder.txt
    & git -C $gitTestRepo -c user.name=MemLabsTest -c user.email=memlabs-test@example.invalid commit -q -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not create temporary Git commit.' }
    $gitTestCommit = (& git -C $gitTestRepo rev-parse HEAD).Trim()
    $global:RepositoryRoot = $gitTestRepo
    Initialize-PinnedWorktree -Path $gitTestWorktree -Commit $gitTestCommit -BranchName 'memlabs-cross-develop-test'
    $gitTestBranch = (& git -C $gitTestWorktree branch --show-current).Trim()
    Assert-Equal 'memlabs-cross-develop-test' $gitTestBranch 'pinned develop worktree retains a develop-named branch'
    Assert-True ($gitTestBranch -notmatch 'main') 'develop worktree branch selects develop media mode'

    $StateRoot = Join-Path $gitTestRoot 'state'
    $RequireCleanSource = $true
    $strictLogRoot = Join-Path $gitTestWorktree 'vmbuild\logs\crashlogs'
    $null = New-Item -ItemType Directory -Path $strictLogRoot -Force
    [IO.File]::WriteAllText((Join-Path $strictLogRoot 'failure.txt'), 'strict-clean recovery')
    Initialize-WorktreeRuntime -WorktreePath $gitTestWorktree
    Initialize-PinnedWorktree -Path $gitTestWorktree -Commit $gitTestCommit -BranchName 'memlabs-cross-develop-test'
    Assert-Equal 0 @(& git -C $gitTestWorktree status --porcelain --untracked-files=all).Count `
        'external log backup keeps a strict-clean pinned worktree clean on resume'
}
finally {
    $StateRoot = $priorStateRoot
    $RequireCleanSource = $priorRequireCleanSource
    if (Test-Path -LiteralPath $gitTestWorktree) {
        & git -C $gitTestRepo worktree remove --force $gitTestWorktree 2>$null
    }
    $global:RepositoryRoot = $sourceRepoRoot
    Remove-Item -LiteralPath $gitTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$runtimeTestRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-runtime-$PID"
$runtimeSource = Join-Path $runtimeTestRoot 'source'
$runtimeWorktree = Join-Path $runtimeTestRoot 'worktree'
$wrongAssets = Join-Path $runtimeTestRoot 'wrong-assets'
$runtimePriorStateRoot = $StateRoot
try {
    foreach ($directory in @(
            (Join-Path $runtimeSource 'vmbuild\azureFiles'),
            (Join-Path $runtimeSource 'vmbuild\cache'),
            (Join-Path $runtimeSource 'vmbuild\config'),
            (Join-Path $runtimeSource 'vmbuild\logs'),
            (Join-Path $runtimeWorktree 'vmbuild\cache\ssh'),
            (Join-Path $runtimeWorktree 'vmbuild\config'),
            $wrongAssets
        )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText((Join-Path $runtimeSource 'vmbuild\cache\ssh-source-placeholder'), 'source cache exists')
    [IO.File]::WriteAllText((Join-Path $runtimeWorktree 'vmbuild\cache\ssh\memlabs_ed25519'), 'active-private-key')
    [IO.File]::WriteAllText((Join-Path $runtimeWorktree 'vmbuild\cache\ssh\memlabs_ed25519.pub'), 'active-public-key')
    [IO.File]::WriteAllText((Join-Path $runtimeWorktree 'vmbuild\cache\git-branch-context.json'), '{"CurrentBranch":"main"}')
    $global:RepositoryRoot = $runtimeSource
    $StateRoot = Join-Path $runtimeTestRoot 'state'
    Assert-Equal $true (Publish-CrossRevisionSshCacheFromWorktree -WorktreePath $runtimeWorktree) `
        'active develop worktree SSH key is promoted before revision migration'
    Assert-Equal 'active-private-key' (Get-Content (Join-Path $runtimeSource 'vmbuild\cache\ssh\memlabs_ed25519') -Raw) `
        'shared cache receives the active private key bytes'
    Assert-Equal 'active-public-key' (Get-Content (Join-Path $runtimeSource 'vmbuild\cache\ssh\memlabs_ed25519.pub') -Raw) `
        'shared cache receives the active public key bytes'
    Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    $runtimeLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\azureFiles') -Force
    Assert-Equal ([IO.Path]::GetFullPath((Join-Path $runtimeSource 'vmbuild\azureFiles')).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeLink.Target).TrimEnd('\')) 'runtime worktree media link targets the source media directory'
    $runtimeLogLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\logs') -Force
    $runtimeSharedLogs = Join-Path $runtimeSource 'vmbuild\logs\CrossRevision\worktree'
    Assert-Equal ([IO.Path]::GetFullPath($runtimeSharedLogs).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeLogLink.Target).TrimEnd('\')) 'runtime worktree log link targets its folder under normal logs'
    $runtimeSshLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\cache\ssh') -Force
    Assert-Equal 'Junction' $runtimeSshLink.LinkType 'runtime worktree uses a shared SSH cache junction'
    Assert-Equal ([IO.Path]::GetFullPath((Join-Path $runtimeSource 'vmbuild\cache\ssh')).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeSshLink.Target).TrimEnd('\')) 'runtime SSH junction targets the shared source key'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\cache\git-branch-context.json')) 'runtime initialization clears stale branch context'

    Remove-Item -LiteralPath $runtimeLogLink.FullName -Force
    $legacyLogRoot = Join-Path $runtimeWorktree 'vmbuild\logs'
    $legacyLogNested = Join-Path $legacyLogRoot 'crashlogs'
    $null = New-Item -ItemType Directory -Path $legacyLogNested -Force
    [IO.File]::WriteAllText((Join-Path $legacyLogRoot 'VMBuild.test.log'), 'main log')
    [IO.File]::WriteAllText((Join-Path $legacyLogNested 'failure.txt'), 'crash log')
    Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    $runtimeLogLink = Get-Item -LiteralPath $legacyLogRoot -Force
    Assert-Equal 'Junction' $runtimeLogLink.LinkType 'existing worktree log directory is replaced by a junction'
    $recoveredLogs = @(Get-ChildItem -LiteralPath $runtimeSharedLogs -Recurse -File)
    Assert-Equal 2 $recoveredLogs.Count 'existing worktree logs are copied into the normal log tree before linking'
    Assert-True (@($recoveredLogs | Where-Object { $_.Name -eq 'VMBuild.test.log' }).Count -eq 1) 'recovered main log keeps its filename'
    Assert-True (@($recoveredLogs | Where-Object { $_.Name -eq 'failure.txt' }).Count -eq 1) 'recovered nested crash log keeps its filename'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'worktree-log-backups') -Directory).Count `
        'original worktree logs remain in an external recovery backup'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $runtimeWorktree 'vmbuild') -Directory -Filter 'logs.recovered-*').Count `
        'worktree contains no untracked recovery backup'

    $oldWorktree = Join-Path $StateRoot 'worktrees\develop-old'
    $oldLogs = Join-Path $oldWorktree 'vmbuild\logs'
    $null = New-Item -ItemType Directory -Path $oldLogs -Force
    [IO.File]::WriteAllText((Join-Path $oldLogs 'VMBuild.old.log'), 'old worktree failure')
    Initialize-ExistingCrossRevisionLogPaths -WorktreeRoot (Join-Path $StateRoot 'worktrees')
    $oldLogLink = Get-Item -LiteralPath $oldLogs -Force
    Assert-Equal 'Junction' $oldLogLink.LinkType 'existing superseded worktree log directory is swept and linked'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $runtimeSource 'vmbuild\logs\CrossRevision\develop-old') `
            -Recurse -File -Filter 'VMBuild.old.log').Count 'superseded worktree failure log is recovered before revision migration'

    Remove-Item -LiteralPath $runtimeLink.FullName -Force
    $null = New-Item -ItemType Junction -Path $runtimeLink.FullName -Target $wrongAssets
    Assert-ThrowsLike -Action {
        Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    } -Pattern '*targets*expected*Remove the stale worktree*' -What 'runtime initialization rejects a stale media junction target'
}
finally {
    $global:RepositoryRoot = $sourceRepoRoot
    $StateRoot = $runtimePriorStateRoot
    $runtimeAssets = Join-Path $runtimeWorktree 'vmbuild\azureFiles'
    if (Test-Path -LiteralPath $runtimeAssets) { Remove-Item -LiteralPath $runtimeAssets -Force -ErrorAction SilentlyContinue }
    $runtimeLogs = Join-Path $runtimeWorktree 'vmbuild\logs'
    if (Test-Path -LiteralPath $runtimeLogs) { Remove-Item -LiteralPath $runtimeLogs -Force -ErrorAction SilentlyContinue }
    $runtimeSsh = Join-Path $runtimeWorktree 'vmbuild\cache\ssh'
    if (Test-Path -LiteralPath $runtimeSsh) { Remove-Item -LiteralPath $runtimeSsh -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $runtimeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$recoverCliRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-recover-cli-$PID"
$recoverCliSource = Join-Path $recoverCliRoot 'source'
$recoverCliState = Join-Path $recoverCliRoot 'state'
$recoverCliWorktree = Join-Path $recoverCliState 'worktrees\develop-recover'
$recoverCliLogs = Join-Path $recoverCliWorktree 'vmbuild\logs'
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $recoverCliSource 'vmbuild\logs') -Force
    $null = New-Item -ItemType Directory -Path $recoverCliLogs -Force
    [IO.File]::WriteAllText((Join-Path $recoverCliLogs 'VMBuild.recover.log'), 'recover-only')
    # Qualification runs in a child of the real host-lock owner. Recovery must
    # refuse that context rather than moving evidence during an active cycle.
    $recoverLockProbe = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
    $recoverLockAvailable = $false
    try {
        try { $recoverLockAvailable = $recoverLockProbe.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $recoverLockAvailable = $true }
    }
    finally {
        if ($recoverLockAvailable) { $recoverLockProbe.ReleaseMutex() }
        $recoverLockProbe.Dispose()
    }
    $recoverOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $runnerPath `
            -RecoverLogsOnly -RepositoryRoot $recoverCliSource -StateRoot $recoverCliState 2>&1 |
            ForEach-Object { "$_" })
    $recoverExitCode = $LASTEXITCODE
    $recoverText = $recoverOutput -join "`n"
    $recoveredEvidence = Join-Path $recoverCliSource 'vmbuild\logs\CrossRevision\develop-recover\VMBuild.recover.log'
    if ($recoverLockAvailable) {
        Assert-True ($recoverExitCode -eq 0) 'recover-logs-only mode exits successfully without a test selection' `
            -Detail "exit=[$recoverExitCode] output=[$recoverText]"
        Assert-True ($recoverText -like '*PASS: cross-revision logs now write under*') `
            'recover-logs-only mode reports the normal log destination' -Detail $recoverText
        Assert-Equal 'Junction' (Get-Item -LiteralPath $recoverCliLogs -Force).LinkType `
            'recover-logs-only mode links an existing pinned worktree'
        Assert-Equal 'recover-only' (Get-Content -LiteralPath $recoveredEvidence -Raw) `
            'recover-logs-only mode moves stranded evidence under normal logs'
    }
    else {
        Assert-Equal 1 $recoverExitCode 'recover-logs-only mode refuses a parent-held host mutation lock'
        Assert-True ($recoverText -like '*Another MemLabs test cycle owns the host mutation lock; recover logs after it stops.*') `
            'recover-logs-only mode reports host-lock contention explicitly' -Detail $recoverText
        Assert-True (-not ((Get-Item -LiteralPath $recoverCliLogs -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) `
            'blocked log recovery does not replace the original log directory'
        Assert-Equal 'recover-only' (Get-Content -LiteralPath (Join-Path $recoverCliLogs 'VMBuild.recover.log') -Raw) `
            'blocked log recovery preserves stranded evidence in place'
        Assert-True (-not (Test-Path -LiteralPath $recoveredEvidence)) 'blocked log recovery does not publish moved evidence'
    }
}
finally {
    if (Test-Path -LiteralPath $recoverCliLogs) {
        $recoverLogItem = Get-Item -LiteralPath $recoverCliLogs -Force
        if ($recoverLogItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Remove-Item -LiteralPath $recoverCliLogs -Force -ErrorAction Stop
        }
    }
    Remove-Item -LiteralPath $recoverCliRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$resumeConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ prefix = 'RES-'; domainName = 'resume.test' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'DC1'; role = 'DC' }
        [pscustomobject]@{ vmName = 'MEM1'; role = 'DomainMember' }
    )
}
try {
    Assert-MainBaselineCanStart -Config $resumeConfig -Domains @('resume.test') -WasStarted $false
    Write-TestResult -Passed $true -What 'fresh exact-main baseline with no VMs is safe to start'
}
catch {
    Write-TestResult -Passed $false -What 'fresh exact-main baseline with no VMs is safe to start' -Detail $_.Exception.Message
}
Assert-ThrowsLike -Action {
    Assert-MainBaselineCanStart -Config $resumeConfig -Domains @('resume.test') -WasStarted $true
} -Pattern '*mutation began*Automatic replay or adoption is unsafe*' -What 'interrupted exact-main baseline cannot replay even when no VMs survive'
$script:MockVms['RES-DC1'] = [pscustomobject]@{
    Name = 'RES-DC1'; Id = [guid]::NewGuid(); Notes = '{"domain":"resume.test","success":true,"inProgress":false}'
}
Assert-ThrowsLike -Action {
    Assert-MainBaselineCanStart -Config $resumeConfig -Domains @('resume.test') -WasStarted $true
} -Pattern '*mutation began*Automatic replay or adoption is unsafe*' -What 'partial interrupted exact-main baseline cannot be replayed'
$script:MockVms['RES-MEM1'] = [pscustomobject]@{
    Name = 'RES-MEM1'; Id = [guid]::NewGuid(); Notes = '{"domain":"resume.test","success":true,"inProgress":false}'
}
Assert-ThrowsLike -Action {
    Assert-MainBaselineCanStart -Config $resumeConfig -Domains @('resume.test') -WasStarted $true
} -Pattern '*mutation began*Automatic replay or adoption is unsafe*' -What 'completed-looking exact-main baseline cannot be adopted without pre-crash identity'
$script:MockVms.Remove('RES-DC1')
$script:MockVms.Remove('RES-MEM1')

$interruptedState = [ordered]@{
    Status = 'Failed'
    CurrentStep = 'resume|main|A'
    LastError = 'The pipeline has been stopped.'
    Interrupted = $true
    CompletedSteps = @('nocm|complete')
    Baselines = @{ nocm = @([pscustomobject]@{ Name = 'NOC-DC1' }) }
    DomainIdentities = @{ nocm = [pscustomobject]@{ Sid = 'S-1-5-21-1' } }
    DevelopIdentities = @{}
    DevelopDomainIdentities = @{}
}
$script:MockVms['RES-DC1'] = [pscustomobject]@{
    Name = 'RES-DC1'; Id = [guid]::NewGuid(); Notes = '{"domain":"resume.test","success":false,"inProgress":true}'
}
$recoveryCalls = [Collections.Generic.List[object]]::new()
$recovered = Repair-InterruptedMainBaseline -State $interruptedState `
    -Plan @([pscustomobject]@{
            Family = 'Resume'
            Domains = @('resume.test')
            BaselineConfig = $resumeConfig
        }) `
    -DevelopWorktree 'develop-current' `
    -CleanupInvoker {
        param($WorktreePath, $Parameters, $Label)
        $recoveryCalls.Add([pscustomobject]@{
                WorktreePath = $WorktreePath
                Parameters = $Parameters
                Label = $Label
            })
        if ($Parameters.DomainName -eq 'resume.test' -or $Parameters.VmName -eq 'RES-DC1') {
            $script:MockVms.Remove('RES-DC1')
            $script:MockVms.Remove('RES-MEM1')
        }
        return 0
    }
Assert-Equal $true $recovered 'interrupted exact-main baseline is recovered automatically'
Assert-Equal 'develop-current' $recoveryCalls[0].WorktreePath 'interrupted baseline cleanup uses current develop worktree'
Assert-Equal $null $interruptedState.CurrentStep 'interrupted family checkpoint is cleared after verified cleanup'
Assert-Equal 'nocm|complete' ($interruptedState.CompletedSteps -join ',') 'automatic recovery preserves completed family progress'
Assert-Equal $false $interruptedState.Interrupted 'automatic recovery clears the interruption marker'
Assert-Equal 0 @($script:MockVms.Keys | Where-Object { $_ -like 'RES-*' }).Count `
    'automatic recovery removes planned family VMs before replay'

$failedRecoveryState = [ordered]@{
    Status = 'Failed'
    CurrentStep = 'resume|main|A'
    LastError = 'interrupted'
    Interrupted = $true
    CompletedSteps = @('nocm|complete')
    Baselines = @{ nocm = @([pscustomobject]@{ Name = 'NOC-DC1' }) }
    DomainIdentities = @{ nocm = [pscustomobject]@{ Sid = 'S-1-5-21-1' } }
    DevelopIdentities = @{}
    DevelopDomainIdentities = @{}
}
Assert-ThrowsLike -Action {
    Repair-InterruptedMainBaseline -State $failedRecoveryState `
        -Plan @([pscustomobject]@{
                Family = 'Resume'
                Domains = @('resume.test')
                BaselineConfig = $resumeConfig
            }) `
        -DevelopWorktree 'develop-current' `
        -CleanupInvoker { return 9 }
} -Pattern '*recovery cleanup*failed with exit code 9*' `
    -What 'failed automatic cleanup remains an explicit recovery failure'
Assert-Equal 'resume|main|A' $failedRecoveryState.CurrentStep `
    'failed automatic cleanup preserves the interrupted checkpoint for retry'
Assert-Equal 'nocm|complete' ($failedRecoveryState.CompletedSteps -join ',') `
    'failed automatic cleanup preserves completed family progress'

& {
    $vmId = [guid]::NewGuid()
    $target = [pscustomobject]@{ Name = 'READY-SITE'; Id = "$vmId"; Domain = 'ready.test' }
    $script:ReadyStates = [Collections.Generic.Queue[string]]::new()
    $script:ReadyState = 'Off'
    $script:ReadyStarts = 0
    $script:ReadyProbes = 0
    $script:ReadyOutcome = 'Completed'
    $script:ReadyId = $vmId
    $script:ReadyComputer = 'READY-SITE'
    $script:ReadyDomain = 'ready.test'
    $script:ReadyIdentity = 'READY\admin'
    $script:ReadyIdentitiesByCredential = @{}
    $script:ReadyIdentitySequence = [Collections.Generic.Queue[string]]::new()
    $script:ReadyEnvironmentUserName = 'admin'
    $script:ReadyProbeScript = $null
    $script:ReadyTimeouts = @()
    $script:ReadyStops = 0
    $script:ReadyRemovals = 0
    $script:ReadyTransientFailures = 0
    $script:ReadyEmptyProbe = $false
    $script:ReadyProbeCopies = 1
    $script:ReadyNotes = '{"domain":"ready.test","adminName":"admin","domainNetBiosName":"READY"}'
    $script:ReadyRejectedUsers = @()
    $script:ReadyCredentialAttempts = @()
    function Get-VM {
        param($Name, $ErrorAction)
        if ($script:ReadyStates.Count) { $script:ReadyState = $script:ReadyStates.Dequeue() }
        [pscustomobject]@{
            Name = $Name; Id = $script:ReadyId; State = $script:ReadyState
            Heartbeat = 'OkApplicationsHealthy'; Status = 'fixture'; Uptime = [timespan]::FromSeconds(15)
            Notes = $script:ReadyNotes
        }
    }
    function Start-VM {
        param($VM, $ErrorAction)
        Assert-Equal "$vmId" "$($VM.Id)" 'retained VM start uses the verified Hyper-V object'
        $script:ReadyStarts++
        $script:ReadyState = 'Running'
    }
    function New-DomainCredentials {
        param($Domain, $AdminName, $DomainNetBiosName, $VmName, $AdminCachePath)
        [pscredential]::new('READY\admin', [securestring]::new())
    }
    function Invoke-Command {
        param($VMId, [pscredential]$Credential, [switch]$AsJob, $ErrorAction, $ScriptBlock)
        Assert-True ($AsJob -and "$VMId" -eq "$($target.Id)") 'boot readiness uses an asynchronous GUID-scoped PSDirect probe'
        $script:ReadyProbes++
        $script:ReadyCredentialAttempts += $Credential.UserName
        if ($Credential.UserName -in $script:ReadyRejectedUsers) {
            throw 'An error has occurred which PowerShell cannot handle. A remote session might have ended.'
        }
        if ($script:ReadyTransientFailures -gt 0) {
            $script:ReadyTransientFailures--
            throw 'fixture: guest transport is still starting'
        }
        $script:ReadyProbeScript = $ScriptBlock
        $job = [pscustomobject]@{ State = $script:ReadyOutcome; CredentialUserName = $Credential.UserName }
        $job | Add-Member ScriptMethod StopJobAsync { $script:ReadyStops++ }
        return $job
    }
    function Wait-Job { param($Job, $Timeout) $script:ReadyTimeouts += $Timeout }
    function Receive-Job {
        param($Job, $ErrorAction)
        if ($script:ReadyEmptyProbe) { return }
        $previousEnvironment = @($env:COMPUTERNAME, $env:USERNAME, $env:USERDNSDOMAIN)
        try {
            $injectedIdentity = $script:ReadyIdentitySequence.Count -gt 0 -or
                $script:ReadyIdentitiesByCredential.ContainsKey("$($Job.CredentialUserName)")
            $probeIdentity = if ($script:ReadyIdentitySequence.Count -gt 0) {
                $script:ReadyIdentitySequence.Dequeue()
            }
            elseif ($script:ReadyIdentitiesByCredential.ContainsKey("$($Job.CredentialUserName)")) {
                $script:ReadyIdentitiesByCredential[$Job.CredentialUserName]
            }
            else { $script:ReadyIdentity }
            $env:COMPUTERNAME = $script:ReadyComputer
            $env:USERNAME = if ($injectedIdentity) { ($probeIdentity -split '\\')[-1] } else { $script:ReadyEnvironmentUserName }
            $env:USERDNSDOMAIN = $script:ReadyDomain
            # Execute the guest probe, substituting only the guest's Windows token.
            $source = $script:ReadyProbeScript.ToString().Replace(
                '[Security.Principal.WindowsIdentity]::GetCurrent().Name', '$probeIdentity')
            for ($copy = 0; $copy -lt $script:ReadyProbeCopies; $copy++) {
                & ([scriptblock]::Create($source))
            }
        }
        finally {
            $env:COMPUTERNAME = $previousEnvironment[0]
            $env:USERNAME = $previousEnvironment[1]
            $env:USERDNSDOMAIN = $previousEnvironment[2]
        }
    }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $script:ReadyRemovals++ }
    function Start-Sleep { param($Seconds) [Threading.Thread]::Sleep(20) }

    Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    Assert-True ($script:ReadyStarts -eq 1 -and $script:ReadyProbes -eq 1) 'retained Off VM starts once and proves PSDirect identity before validation'
    Assert-True ($script:ReadyRemovals -eq 1 -and $script:ReadyTimeouts[0] -le 5) 'readiness probe cleanup and timeout stay within the overall budget'
    Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    Assert-Equal 1 $script:ReadyStarts 'already Running retained VM is not started or rebooted again'
    Assert-Equal 2 $script:ReadyProbes 'already Running retained VM still proves PSDirect identity before domain validation'
    $guestProbeTest = @'
$ErrorActionPreference = 'Stop'
$expectedIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$expectedUser = ($expectedIdentity -split '\\')[-1]
$env:USERNAME = 'MemLabs-Stale-Environment-Fixture'
$env:USERDNSDOMAIN = 'readiness.fixture.test'
$result = @(& {
__GUEST_PROBE__
})
if ($result.Count -ne 1 -or $result[0].Identity -ne $expectedIdentity -or
    $result[0].UserName -ne $expectedUser -or $result[0].UserName -eq $env:USERNAME -or
    $result[0].EnvironmentUserName -ne $env:USERNAME -or
    $result[0].ComputerName -ne $env:COMPUTERNAME -or $result[0].Domain -ne $env:USERDNSDOMAIN) {
    throw 'Guest readiness probe did not return the actual Windows token and environment evidence.'
}
Write-Output 'Guest readiness token verified'
'@
    $guestProbeTest = $guestProbeTest.Replace('__GUEST_PROBE__', $script:ReadyProbeScript.ToString())
    $encodedProbeTest = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guestProbeTest))
    $guestEngine = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $guestProbeOutput = @(& $guestEngine -NoLogo -NoProfile -NonInteractive -EncodedCommand $encodedProbeTest 2>&1)
    Assert-True ($LASTEXITCODE -eq 0 -and ($guestProbeOutput -join "`n") -eq 'Guest readiness token verified') `
        'Windows PowerShell 5.1 executes the actual guest probe with a stale environment username' ($guestProbeOutput -join "`n")
    $script:ReadyEnvironmentUserName = 'Administrator'
    $identityError = $null
    $startsBefore = $script:ReadyStarts
    try {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    }
    catch { $identityError = $_.Exception.Message }
    Assert-True (-not $identityError) 'readiness accepts the authenticated user despite a stale environment username' $identityError
    Assert-Equal $startsBefore $script:ReadyStarts 'stale environment username never restarts the retained VM'
    $script:ReadyEnvironmentUserName = 'admin'
    foreach ($state in @('Stopping', 'Off', 'Starting', 'Running')) { $script:ReadyStates.Enqueue($state) }
    Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    Assert-Equal 2 $script:ReadyStarts 'late completion of the previous shutdown is observed and the Off VM is started once'
    $script:ReadyTransientFailures = 1
    $previousProbes = $script:ReadyProbes
    Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    Assert-True ($script:ReadyProbes -eq $previousProbes + 2 -and $script:ReadyStarts -eq 2) 'transient guest boot transport failure retries without restarting the VM'
    foreach ($state in @('Off', 'Off')) { $script:ReadyStates.Enqueue($state) }
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 5
    } '*returned to Off after its one start request*' 'a guest that powers off again is not restarted in a loop'
    $script:ReadyId = [guid]::NewGuid()
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 1
    } '*replaced*No power action permitted*' 'replacement VM is rejected before power action'
    $script:ReadyId = $vmId
    foreach ($state in @('Saved', 'Paused', 'RunningCritical', 'OffCritical', '')) {
        $script:ReadyState = $state
        Assert-ThrowsLike {
            Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 1
        } '*cannot be prepared automatically*' "retained '$state' VM is not silently resumed or reset"
    }
    $script:ReadyState = 'Stopping'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } '*readiness timed out*state=Stopping*' 'stuck shutdown times out with state evidence without power-off'
    $script:ReadyState = 'Off'
    $script:ReadyComputer = 'WRONG-VM'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 1
    } "*readiness identity mismatch*expected computer='READY-SITE'*actual computer='WRONG-VM'*" `
        'boot readiness rejects a different guest computer identity with expected and actual evidence'
    $script:ReadyComputer = 'READY-SITE'
    $script:ReadyState = 'Off'
    $script:ReadyDomain = 'wrong.test'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } "*readiness identity mismatch*expected*DNS domain='ready.test'*actual*DNS domain='wrong.test'*" `
        'boot readiness rejects a different authenticated domain with expected and actual evidence'
    $script:ReadyDomain = 'ready.test'
    $script:ReadyState = 'Running'
    $script:ReadyIdentity = 'READY\other-admin'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } "*readiness identity mismatch*expected*user='admin'*actual*user='other-admin'*identity='READY\other-admin'*USERNAME='admin'*" `
        'readiness rejects the wrong authenticated user even when the environment username matches'
    $script:ReadyIdentity = ''
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } '*readiness identity mismatch*' 'readiness rejects a missing authenticated Windows identity'
    $script:ReadyIdentity = 'READY\admin'
    $script:ReadyProbeCopies = 2
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 0 -TimeoutSeconds 1
    } '*readiness identity mismatch*results=2*' 'readiness rejects duplicate identity results with the actual result count'
    $script:ReadyProbeCopies = 1
    $script:ReadyEmptyProbe = $true
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } '*readiness timed out*returned no identity*' 'an empty completed probe fails with an explicit diagnostic'
    $script:ReadyEmptyProbe = $false
    $script:ReadyState = 'Off'
    $script:ReadyOutcome = 'Running'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target $target -RetrySeconds 1 -TimeoutSeconds 1
    } '*readiness timed out*PSDirect probe timed out*' 'a hung boot probe is bounded and fails with transport evidence'
    Assert-True ($script:ReadyStops -gt 0) 'timed-out boot jobs are stopped asynchronously without disposing active callbacks'
    Assert-ThrowsLike {
        Wait-CrossRevisionRetainedVmReady -Target ([pscustomobject]@{ Name = 'OTHER'; Id = '' })
    } '*saved VM name and GUID*' 'missing saved identity cannot select an unrelated VM to start'

    & {
        . (Import-TestFunction -Path $runnerPath -Name New-DomainCredentials)
        $savedState = $script:State
        $credentialFile = Join-Path ([IO.Path]::GetTempPath()) "memlabs-readiness-credential-$PID.txt"
        try {
            'fixture-not-a-real-password' | Set-Content -LiteralPath $credentialFile
            $script:State = @{
                DomainIdentities = @{ baseline = @{ Domain = 'ready.test'; DomainNetBiosName = 'EXACT-NB' } }
                DevelopDomainIdentities = @{ other = @{ Domain = 'other.test'; DomainNetBiosName = 'OTHER' } }
            }
            $script:ReadyNotes = '{"domain":"ready.test","adminName":"admin"}'
            $script:ReadyState = 'Running'
            $script:ReadyOutcome = 'Completed'
            $script:ReadyRejectedUsers = @('admin@ready.test')
            $script:ReadyCredentialAttempts = @()
            $startsBefore = $script:ReadyStarts
            Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 0 -TimeoutSeconds 5
            Assert-Equal 'admin@ready.test|EXACT-NB\admin' ($script:ReadyCredentialAttempts -join '|') `
                'missing legacy VM-note NetBIOS name uses the saved exact domain name after UPN transport rejection'
            Assert-Equal $startsBefore $script:ReadyStarts 'credential fallback never reboots the healthy retained VM'
            $script:ReadyRejectedUsers = @()
            $script:ReadyIdentitiesByCredential = @{
                'admin@ready.test' = 'EXACT-NB\vmbuildadmin'
                'EXACT-NB\admin' = 'EXACT-NB\admin'
            }
            foreach ($notes in @(
                    '{"domain":"ready.test","adminName":"admin"}',
                    '{"domain":"ready.test","adminName":"admin","domainNetBiosName":"EXACT-NB"}'
                )) {
                $script:ReadyNotes = $notes
                $script:ReadyCredentialAttempts = @()
                $fallbackError = $null
                $fallbackLog = ''
                try {
                    $fallbackLog = @(Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile `
                            -RetrySeconds 0 -TimeoutSeconds 5 6>&1) -join "`n"
                }
                catch { $fallbackError = $_.Exception.Message }
                Assert-True (-not $fallbackError) 'a UPN job returning vmbuildadmin can recover only through a verified exact-admin alternate' $fallbackError
                Assert-Equal 'admin@ready.test|EXACT-NB\admin' ($script:ReadyCredentialAttempts -join '|') `
                    'authenticated UPN identity mismatch still tries the exact NetBIOS credential from notes or saved state'
                Assert-True ($fallbackLog -like "*REJECT:*identity='EXACT-NB\vmbuildadmin'*credential='admin@ready.test'*" -and
                    $fallbackLog -like "*PASS:*credential='EXACT-NB\admin'*identity='EXACT-NB\admin'*") `
                    'readiness logs the rejected principal and the exact credential and principal that actually passed'
            }
            $script:ReadyNotes = '{"domain":"ready.test","adminName":"admin"}'
            $script:ReadyIdentitiesByCredential.Clear()
            foreach ($identity in @('EXACT-NB\vmbuildadmin', 'EXACT-NB\other-admin', 'EXACT-NB\admin')) {
                $script:ReadyIdentitySequence.Enqueue($identity)
            }
            $script:ReadyCredentialAttempts = @()
            $recoveryError = $null
            try {
                Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 5
            }
            catch { $recoveryError = $_.Exception.Message }
            Assert-True (-not $recoveryError) 'wrong identities on the first poll can recover through a fresh verified session within the existing budget' $recoveryError
            Assert-Equal 'admin@ready.test|EXACT-NB\admin|admin@ready.test' ($script:ReadyCredentialAttempts -join '|') `
                'fresh-session recovery does not accept either rejected first-poll identity'
            $script:ReadyIdentitySequence.Clear()
            $script:ReadyIdentitiesByCredential = @{
                'admin@ready.test' = 'EXACT-NB\vmbuildadmin'
                'EXACT-NB\admin' = 'EXACT-NB\other-admin'
            }
            $script:ReadyCredentialAttempts = @()
            $rejectedLog = [Collections.Generic.List[object]]::new()
            Assert-ThrowsLike {
                Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile `
                    -RetrySeconds 1 -TimeoutSeconds 1 6>&1 | ForEach-Object { $rejectedLog.Add($_) }
            } "*readiness timed out*identity='EXACT-NB\vmbuildadmin'*credential='admin@ready.test'*identity='EXACT-NB\other-admin'*credential='EXACT-NB\admin'*" `
                'all wrong authenticated identities fail with both credential results preserved at the deadline'
            Assert-True (($rejectedLog -join "`n") -notlike '*PASS: retained VM*') 'a wrong authenticated identity is never converted into readiness success'
            Assert-Equal 'admin@ready.test|EXACT-NB\admin' (($script:ReadyCredentialAttempts | Select-Object -Unique) -join '|') `
                'identity retries never guess another account or domain credential'
            $script:ReadyIdentitiesByCredential.Clear()
            $script:ReadyComputer = 'WRONG-VM'
            $script:ReadyCredentialAttempts = @()
            Assert-ThrowsLike {
                Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 1
            } "*readiness identity mismatch*actual computer='WRONG-VM'*" 'a wrong guest identity remains immediately fatal even with alternate credentials available'
            Assert-Equal 'admin@ready.test' ($script:ReadyCredentialAttempts -join '|') 'a wrong guest never triggers credential fallback'
            $script:ReadyComputer = 'READY-SITE'
            $script:ReadyProbeCopies = 2
            $script:ReadyCredentialAttempts = @()
            Assert-ThrowsLike {
                Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 1
            } '*readiness identity mismatch*results=2*' 'malformed duplicate guest replies remain immediately fatal'
            Assert-Equal 'admin@ready.test' ($script:ReadyCredentialAttempts -join '|') 'malformed guest replies never trigger credential fallback'
            $script:ReadyProbeCopies = 1
            Assert-Equal $startsBefore $script:ReadyStarts 'identity fallback and fresh-session retries never restart or reset the retained VM'
            $script:State.DevelopDomainIdentities.expansion = $script:State.DomainIdentities.baseline
            $script:State.DomainIdentities.Clear()
            Assert-Equal 'EXACT-NB' (Resolve-CrossRevisionDomainNetBiosName -Domain 'ready.test' -VmName $target.Name) `
                'expansion-domain checkpoint also supplies the exact legacy credential fallback'
            $script:State.DomainIdentities.conflict = @{ Domain = 'ready.test'; DomainNetBiosName = 'CONFLICT' }
            Assert-ThrowsLike {
                Resolve-CrossRevisionDomainNetBiosName -Domain 'ready.test' -VmName $target.Name
            } '*Conflicting saved NetBIOS*' 'conflicting saved domain names fail instead of guessing credentials'
            $script:State.DomainIdentities.Clear()
            $script:ReadyRejectedUsers = @('admin@ready.test', 'EXACT-NB\admin')
            & {
                $script:ReadyCredentialAttempts = @()
                function New-ReadinessTestClock {
                    $script:ReadyClock = [pscustomobject]@{ Elapsed = [timespan]::Zero }
                    return $script:ReadyClock
                }
                function Start-Sleep {
                    param($Seconds)
                    $script:ReadyClock.Elapsed = [timespan]::FromSeconds(0.5)
                }
                function Invoke-Command {
                    param($VMId, [pscredential]$Credential, [switch]$AsJob, $ErrorAction, $ScriptBlock)
                    Assert-True ($AsJob -and "$VMId" -eq "$($target.Id)") 'boot readiness uses an asynchronous GUID-scoped PSDirect probe'
                    $script:ReadyCredentialAttempts += $Credential.UserName
                    $attempt = $script:ReadyCredentialAttempts.Count
                    if ($attempt -eq 3) { $script:ReadyClock.Elapsed = [timespan]::FromSeconds(1) }
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new("fixture transport failure attempt $attempt"),
                        "ReadinessTransport$attempt", [Management.Automation.ErrorCategory]::ConnectionError, $Credential.UserName)
                }
                $readinessSource = (Import-TestFunction -Path $runnerPath -Name Wait-CrossRevisionRetainedVmReady).ToString()
                if (-not $readinessSource.Contains('[Diagnostics.Stopwatch]::StartNew()')) {
                    throw 'Cannot attach the deterministic readiness test clock.'
                }
                . ([scriptblock]::Create($readinessSource.Replace('[Diagnostics.Stopwatch]::StartNew()', '(New-ReadinessTestClock)')))
                Assert-ThrowsLike {
                    Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 1
                } '*admin@ready.test*attempt 3*errorId=ReadinessTransport3*EXACT-NB\admin*attempt 2*errorId=ReadinessTransport2*' `
                    'readiness timeout preserves every credential transport error and error ID after a partial final poll'
                Assert-Equal 'admin@ready.test|EXACT-NB\admin|admin@ready.test' ($script:ReadyCredentialAttempts -join '|') `
                    'readiness deadline prevents another credential probe after the budget expires'
                $script:ReadyIdentitiesByCredential = @{ 'admin@ready.test' = 'EXACT-NB\vmbuildadmin' }
                $script:ReadyCredentialAttempts = @()
                function Invoke-Command {
                    param($VMId, [pscredential]$Credential, [switch]$AsJob, $ErrorAction, $ScriptBlock)
                    Assert-True ($AsJob -and "$VMId" -eq "$($target.Id)") 'identity retry remains an asynchronous GUID-scoped probe'
                    $script:ReadyCredentialAttempts += $Credential.UserName
                    $attempt = $script:ReadyCredentialAttempts.Count
                    if ($attempt -eq 3) { $script:ReadyClock.Elapsed = [timespan]::FromSeconds(1) }
                    if ($Credential.UserName -eq 'admin@ready.test') {
                        $script:ReadyProbeScript = $ScriptBlock
                        return [pscustomobject]@{ State = 'Completed'; CredentialUserName = $Credential.UserName }
                    }
                    throw [Management.Automation.ErrorRecord]::new(
                        [InvalidOperationException]::new('fixture alternate transport failure'),
                        'AlternateReadinessTransport', [Management.Automation.ErrorCategory]::ConnectionError, $Credential.UserName)
                }
                Assert-ThrowsLike {
                    Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 1
                } "*readiness timed out*identity='EXACT-NB\vmbuildadmin'*credential='admin@ready.test'*EXACT-NB\admin*fixture alternate transport failure*errorId=AlternateReadinessTransport*" `
                    'mixed identity and transport failures retain both results when the final credential poll is cut short'
                Assert-Equal 'admin@ready.test|EXACT-NB\admin|admin@ready.test' ($script:ReadyCredentialAttempts -join '|') `
                    'an identity mismatch cannot start another probe after the readiness deadline'
                $script:ReadyIdentitiesByCredential.Clear()
            }
            $script:State.DevelopDomainIdentities.Clear()
            Assert-True ($null -eq (Resolve-CrossRevisionDomainNetBiosName -Domain 'ready.test' -VmName $target.Name)) `
                'missing saved NetBIOS metadata does not guess from the DNS label'
            $script:ReadyRejectedUsers = @()
            $script:ReadyIdentitiesByCredential = @{ 'admin@ready.test' = 'EXACT-NB\vmbuildadmin' }
            $script:ReadyCredentialAttempts = @()
            Assert-ThrowsLike {
                Wait-CrossRevisionRetainedVmReady -Target $target -AdminCachePath $credentialFile -RetrySeconds 1 -TimeoutSeconds 1
            } "*readiness identity mismatch*identity='EXACT-NB\vmbuildadmin'*" 'a mismatched UPN cannot pass when no exact alternate domain credential exists'
            Assert-Equal 'admin@ready.test' (($script:ReadyCredentialAttempts | Select-Object -Unique) -join '|') `
                'missing NetBIOS metadata does not invent an identity fallback'
            $script:ReadyIdentitiesByCredential.Clear()
        }
        finally {
            $script:State = $savedState
            Remove-Item -LiteralPath $credentialFile -Force
        }
    }
}

$baselineId = [guid]::NewGuid()
$script:MockVms['NOC-DC1'] = [pscustomobject]@{
    Name = 'NOC-DC1'; Id = $baselineId; Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":11}'
}
$script:MockDisks['NOC-DC1'] = @([pscustomobject]@{
        ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0; Path = 'E:\VirtualMachines\NOC-DC1.vhdx'
    })
$identity = @(Get-VmIdentity -VmNames @('NOC-DC1'))
foreach ($invalidIdentity in @(@(), @($null), @(@{ Id = 'id-only' }), @(@{ Name = 'name-only' }))) {
    Assert-ThrowsLike -Action { Assert-BaselineIdentity -Identity $invalidIdentity } `
        -Pattern '*identity checkpoint*' -What 'invalid saved identity fails explicitly before Hyper-V parameter binding'
    Assert-ThrowsLike -Action { Get-CrossRevisionMaintenanceTargets -Identity $invalidIdentity } `
        -Pattern '*Maintenance scope*' -What 'invalid maintenance scope fails explicitly before Hyper-V parameter binding'
}
& {
    $scopeVms = @{}
    foreach ($entry in @(
            @{ Name = 'SCOPE-DC'; Role = 'DC'; OS = 'Server 2022' },
            @{ Name = 'SCOPE-PRI'; Role = 'Primary'; OS = 'Server 2022' },
            @{ Name = 'SCOPE-SQL'; Role = 'DomainMember'; OS = 'Server 2019' },
            @{ Name = 'SCOPE-PROXY'; Role = 'Proxy'; OS = 'Server 2022' },
            @{ Name = 'SCOPE-LINUX'; Role = 'DomainMember'; OS = 'Ubuntu' }
        )) {
        $scopeVms[$entry.Name] = [pscustomobject]@{
            Name = $entry.Name; Id = [guid]::NewGuid()
            Notes = (@{ role = $entry.Role; operatingSystem = $entry.OS; domain = 'scope.test' } | ConvertTo-Json -Compress)
        }
    }
    function Get-VM {
        param($Name, $ErrorAction)
        if (-not $scopeVms.ContainsKey($Name)) { throw "Unexpected maintenance target '$Name'." }
        return $scopeVms[$Name]
    }
    function Get-CrossRevisionVmDiskIdentity { param($VmName) return @() }
    $saved = @(Get-VmIdentity -VmNames @($scopeVms.Keys))
    $plain = @($saved | ForEach-Object { @{ Name = $_.Name; Id = $_.Id } })
    foreach ($shape in @(
            @{ Label = 'fresh ordered dictionaries'; Values = $saved },
            @{ Label = 'plain hashtables'; Values = $plain },
            @{ Label = 'checkpoint objects'; Values = @($saved | ConvertTo-Json -Depth 12 | ConvertFrom-Json) },
            @{ Label = 'checkpoint hashtables'; Values = @($saved | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) },
            @{ Label = 'overlapping baseline and expansion'; Values = @($saved) + @($saved) }
        )) {
        $scoped = @(Get-CrossRevisionMaintenanceTargets -Identity $shape.Values)
        Assert-Equal 'SCOPE-DC,SCOPE-PRI,SCOPE-SQL' ($scoped.Name -join ',') `
            "maintenance retains the complete independently expected supported scope for $($shape.Label)"
        Assert-Equal 1 @($scoped | Where-Object Role -eq 'Primary').Count `
            "maintenance cannot turn a CM family into N/A for $($shape.Label)"
        foreach ($vm in $scoped) {
            Assert-Equal "$($scopeVms[$vm.Name].Id)" $vm.Id "maintenance preserves the saved GUID for $($vm.Name)"
        }
    }
    $conflict = [ordered]@{ Name = 'scope-pri'; Id = [guid]::NewGuid().ToString() }
    Assert-ThrowsLike {
        Get-CrossRevisionMaintenanceTargets -Identity (@($saved) + @($conflict))
    } '*conflicting saved identities*' 'maintenance rejects conflicting duplicates before deduplication can hide replacement'
}
$savedTestState = $script:State
try {
    & {
        $script:State = @{ DevelopIdentities = @{}; DevelopDomainIdentities = @{} }
        $script:ExpansionIdentitySaves = 0
        function Save-State { $script:ExpansionIdentitySaves++ }
        function Get-DomainIdentity { param($Config, $AdminCachePath) return @{ Sid = 'first-domain-sid' } }
        function Assert-DomainIdentity {
            param($Identity, $AdminCachePath)
            if ($Identity.Sid -ne 'first-domain-sid') { throw 'Domain SID changed.' }
        }
        $config = [pscustomobject]@{ virtualMachines = @([pscustomobject]@{ role = 'DC' }) }
        $key = 'nocm|followon.json'
        Save-CrossRevisionExpansionIdentity -IdentityKey $key -VmNames @('NOC-DC1') -Config $config
        Assert-Equal "$baselineId" $script:State.DevelopIdentities[$key][0].Id 'fresh first pass persists VM identity before marking the stage complete'
        Assert-Equal 'first-domain-sid' $script:State.DevelopDomainIdentities[$key].Sid 'fresh first pass persists domain identity'
        $persisted = $script:State | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        Assert-BaselineIdentity -Identity @($persisted.DevelopIdentities.$key)
        Assert-Equal "$baselineId" $persisted.DevelopIdentities.$key[0].Id 'first-pass identity survives checkpoint JSON round trip for pass two'
        Save-CrossRevisionExpansionIdentity -IdentityKey $key -VmNames @('NOC-DC1') -Config $config
        Assert-Equal 2 $script:ExpansionIdentitySaves 'unchanged resumed stage revalidates the original saved identity'
        $script:MockVms['NOC-DC1'].Id = [guid]::NewGuid()
        Assert-ThrowsLike -Action {
            Save-CrossRevisionExpansionIdentity -IdentityKey $key -VmNames @('NOC-DC1') -Config $config
        } -Pattern '*was replaced*' -What 'resume never overwrites first-pass identity with a replacement VM'
        Assert-Equal "$baselineId" $script:State.DevelopIdentities[$key][0].Id 'failed resume preserves first-pass identity'
        $script:MockVms['NOC-DC1'].Id = $baselineId
    }
}
finally {
    $script:State = $savedTestState
    $script:MockVms['NOC-DC1'].Id = $baselineId
}
$runnerTokens = $null
$runnerErrors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$runnerTokens, [ref]$runnerErrors)
$captureCalls = @($runnerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Save-CrossRevisionExpansionIdentity'
        }, $true))
Assert-Equal 2 $captureCalls.Count 'fresh and resumed expansion paths both checkpoint first-pass identity'
$readinessCalls = @($runnerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Wait-CrossRevisionRetainedVmReady'
        }, $true))
Assert-Equal 4 $readinessCalls.Count 'baseline, skipped-stage, pass-two and maintenance paths all prepare retained VM power readiness'
$skipCheck = $runnerText.IndexOf('Write-Host "SKIP: completed $step"')
$skipEnd = $runnerText.IndexOf('if ($cleanupStarted)', $skipCheck)
$skipText = $runnerText.Substring($skipCheck, $skipEnd - $skipCheck)
Assert-True ($skipText.IndexOf('Assert-BaselineIdentity -Identity $readinessIdentity') -lt
    $skipText.IndexOf('Wait-CrossRevisionRetainedVmReady') -and
    $skipText.IndexOf('Wait-CrossRevisionRetainedVmReady') -lt
    $skipText.IndexOf('Assert-DomainJoinedVmHealth')) `
    'skipped-stage resume verifies saved disk/VM identity and readies power before the domain probe'
$freshCapture = $captureCalls | Select-Object -Last 1
$captureGuard = $freshCapture.Parent
while ($captureGuard -and $captureGuard -isnot [Management.Automation.Language.IfStatementAst]) {
    $captureGuard = $captureGuard.Parent
}
Assert-Equal '$pass -eq 1' $captureGuard.Clauses[0].Item1.Extent.Text 'fresh identity is recorded only on the first pass'
$stageStatements = @($captureGuard.Parent.Statements)
$captureIndex = [array]::IndexOf($stageStatements, $captureGuard)
Assert-True ($captureIndex -gt 0 -and
    $stageStatements[$captureIndex - 1].Extent.Text -like 'Assert-DomainJoinedVmHealth*' -and
    $stageStatements[$captureIndex + 1].Extent.Text -like '*Invoke-CrossRevisionMaintenanceGate*' -and
    $stageStatements[-1].Extent.Text -like 'Complete-Step*') `
    'fresh identity is persisted after guest validation and before maintenance gates and stage completion'
Assert-Equal "$baselineId" $identity[0].Id 'baseline identity captures the Hyper-V VM ID'
Assert-Equal 'E:\VirtualMachines\NOC-DC1.vhdx' $identity[0].VhdPaths[0] 'baseline identity captures stable base-VHD lineage'
Assert-Equal 2 $identity[0].DiskIdentityVersion 'baseline identity records stable disk schema version'
Assert-Equal 'SCSI' $identity[0].Disks[0].ControllerType 'baseline identity captures disk controller slot'

try {
    Assert-BaselineIdentity -Identity $identity
    Write-TestResult -Passed $true -What 'unchanged baseline identity is accepted'
}
catch {
    Write-TestResult -Passed $false -What 'unchanged baseline identity is accepted' -Detail $_.Exception.Message
}

$originalId = $script:MockVms['NOC-DC1'].Id
$script:MockVms['NOC-DC1'].Id = [guid]::NewGuid()
Assert-ThrowsLike -Action { Assert-BaselineIdentity -Identity $identity } -Pattern '*was replaced*' -What 'baseline VM replacement fails the cycle'
$script:MockVms['NOC-DC1'].Id = $originalId

$script:MockDisks['NOC-DC1'][0].Path = 'E:\VirtualMachines\replacement.vhdx'
Assert-ThrowsLike -Action { Assert-BaselineIdentity -Identity $identity } -Pattern '*disk attachment paths changed*' -What 'baseline disk replacement fails the cycle'
$script:MockDisks['NOC-DC1'][0].Path = 'E:\VirtualMachines\NOC-DC1.vhdx'
$script:MockDisks['NOC-DC1'][0].ControllerLocation = 1
Assert-ThrowsLike -Action {
    Assert-BaselineIdentity -Identity $identity
} -Pattern '*disk attachment paths changed*' `
    -What 'baseline disk controller-slot replacement fails the cycle'
$script:MockDisks['NOC-DC1'][0].ControllerLocation = 0

$snapshotPath = 'E:\VirtualMachines\NOC-DC1_11111111-2222-3333-4444-555555555555.avhdx'
$script:MockDisks['NOC-DC1'][0].Path = $snapshotPath
$script:MockVhds[$snapshotPath] = [pscustomobject]@{
    Path = $snapshotPath
    ParentPath = 'E:\VirtualMachines\NOC-DC1.vhdx'
}
$snapshotIdentity = @(Get-VmIdentity -VmNames @('NOC-DC1'))
Assert-Equal 'E:\VirtualMachines\NOC-DC1.vhdx' $snapshotIdentity[0].VhdPaths[0] `
    'checkpoint attachment resolves to stable base-VHD lineage'
$script:MockDisks['NOC-DC1'][0].Path = 'E:\VirtualMachines\NOC-DC1.vhdx'
try {
    Assert-BaselineIdentity -Identity $snapshotIdentity
    Write-TestResult -Passed $true -What 'snapshot merge preserves stable disk identity'
}
catch {
    Write-TestResult -Passed $false -What 'snapshot merge preserves stable disk identity' -Detail $_.Exception.Message
}

$legacySnapshotIdentity = @([pscustomobject]@{
        Name = 'NOC-DC1'
        Id = "$baselineId"
        VhdPaths = @($snapshotPath)
    })
try {
    Assert-BaselineIdentity -Identity $legacySnapshotIdentity
    Write-TestResult -Passed $true -What 'legacy AVHDX identity accepts matching snapshot merge'
}
catch {
    Write-TestResult -Passed $false -What 'legacy AVHDX identity accepts matching snapshot merge' -Detail $_.Exception.Message
}
$legacySnapshotIdentity[0].VhdPaths = @(
    'E:\VirtualMachines\replacement_11111111-2222-3333-4444-555555555555.avhdx')
Assert-ThrowsLike -Action {
    Assert-BaselineIdentity -Identity $legacySnapshotIdentity
} -Pattern '*disk attachment paths changed*' `
    -What 'legacy AVHDX identity still rejects a different base disk'
$script:MockVhds.Remove($snapshotPath)

Assert-ThrowsLike -Action {
    Assert-DomainsAbsent -Domains @('unrelated.test') -VmNames @('NOC-DC1')
} -Pattern '*already exist*' -What 'VM-name collision fails even when domain-note matching cannot help'
$originalNotes = $script:MockVms['NOC-DC1'].Notes
$script:MockVms['NOC-DC1'].Notes = 'not-json'
Assert-Equal 0 @(Get-DomainVms -Domains @('nocm.com')).Count 'domain-note scan cannot see a VM with damaged notes'
Assert-Equal 1 @(Get-ExistingNamedVms -VmNames @('NOC-DC1')).Count 'expected-name cleanup scan still sees a VM with damaged notes'
$script:MockVms['NOC-DC1'].Notes = $originalNotes
$script:MockGetVmFailure = $true
Assert-ThrowsLike -Action { Get-DomainVms -Domains @('nocm.com') } -Pattern '*simulated Hyper-V provider failure*' -What 'domain inventory failure cannot masquerade as zero VMs'
Assert-ThrowsLike -Action { Get-ExistingNamedVms -VmNames @('NOC-DC1') } -Pattern '*simulated Hyper-V provider failure*' -What 'name inventory failure cannot masquerade as cleanup success'
$script:MockGetVmFailure = $false

$credentialPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-credential-$PID.txt"
[IO.File]::WriteAllText($credentialPath, 'not-a-real-password')
$domainConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ prefix = 'NOC-'; domainName = 'nocm.com'; domainNetBiosName = 'NOCM'; adminName = 'admin2' }
    virtualMachines = @([pscustomobject]@{ vmName = 'DC1'; role = 'DC' })
}
$domainIdentity = Get-DomainIdentity -Config $domainConfig -AdminCachePath $credentialPath
Assert-Equal 'S-1-5-21-100-200-300' $domainIdentity.Sid 'baseline identity captures the AD domain SID'
Assert-Equal 'NOCM' $domainIdentity.DomainNetBiosName 'baseline identity captures the authoritative NetBIOS domain name'
Assert-Equal 'admin2@nocm.com' $script:LastCredentialUser 'domain SID probe uses the DNS-domain UPN'
try {
    Assert-DomainIdentity -Identity $domainIdentity -AdminCachePath $credentialPath
    Write-TestResult -Passed $true -What 'unchanged AD domain SID is accepted'
}
catch {
    Write-TestResult -Passed $false -What 'unchanged AD domain SID is accepted' -Detail $_.Exception.Message
}
$script:MockDomainSid = 'S-1-5-21-900-800-700'
Assert-ThrowsLike -Action {
    Assert-DomainIdentity -Identity $domainIdentity -AdminCachePath $credentialPath
} -Pattern '*was replaced*' -What 'AD domain SID replacement fails the cycle'

$stageConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ prefix = 'NOC-'; domainName = 'nocm.com'; domainNetBiosName = 'NOCM'; adminName = 'admin2' }
    virtualMachines = @([pscustomobject]@{ vmName = 'W11CLIENT1'; role = 'DomainMember' })
}
$script:MockVms['NOC-W11CLIENT1'] = [pscustomobject]@{
    Name = 'NOC-W11CLIENT1'; Id = [guid]::NewGuid(); Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":11}'
}
try {
    Assert-DevelopStageComplete -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json'
    Write-TestResult -Passed $true -What 'phase-11 develop VM is accepted'
}
catch {
    Write-TestResult -Passed $false -What 'phase-11 develop VM is accepted' -Detail $_.Exception.Message
}

$script:MockVms['NOC-W11CLIENT1'].Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":10}'
Assert-ThrowsLike -Action {
    Assert-DevelopStageComplete -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json'
} -Pattern '*below phase 11*' -What 'VM below phase 11 fails the cycle'
$script:MockVms['NOC-W11CLIENT1'].Notes = '{"success":"false","inProgress":false,"lastPhaseComplete":11}'
Assert-ThrowsLike -Action {
    Assert-DevelopStageComplete -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json'
} -Pattern '*incomplete*' -What 'string-valued false success cannot pass by truthiness'
$script:MockVms['NOC-W11CLIENT1'].Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":11}'
try {
    $healthyLog = @(Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' `
            -AdminCachePath $credentialPath -MaximumAttempts 2 -RetrySeconds 0 6>&1) -join "`n"
    Write-TestResult -Passed $true -What 'domain member independently passes join, Netlogon-status, and DNS checks'
    Assert-True ($healthyLog -like '*CHECK SCOPE:*does not run Test-ComputerSecureChannel*' -and
        $healthyLog -notlike '*Test-ComputerSecureChannel=*') 'domain readiness explicitly reports its reduced check scope'
    Assert-True ($healthyLog -like '*sample 1/2 passed (1/2 consecutive healthy samples*' -and
        $healthyLog -notlike '*not yet stable*') 'a healthy first sample is logged as passed and awaiting confirmation, not as an unhealthy retry'
    Assert-True ($healthyLog -like "*PASS: NOC-W11CLIENT1 domain convergence confirmed (2/2 consecutive healthy samples) for 'nocm.com'.*") `
        'the final healthy domain sample prints an explicit per-VM confirmation'
}
catch {
    Write-TestResult -Passed $false -What 'domain member independently passes join, Netlogon-status, and DNS checks' -Detail $_.Exception.Message
}
$script:MockDomainHealth.SecureChannel = $false
try {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'removed-cmdlet-gate' `
        -AdminCachePath $credentialPath -MaximumAttempts 2 -RetrySeconds 0
    Write-TestResult -Passed $true -What 'a legacy False secure-channel value cannot block the remaining independent readiness checks'
}
catch {
    Write-TestResult -Passed $false -What 'a legacy False secure-channel value cannot block the remaining independent readiness checks' -Detail $_.Exception.Message
}
finally { $script:MockDomainHealth.SecureChannel = $true }
& {
    $script:RemovedChannelCalls = 0
    function Test-ComputerSecureChannel {
        $script:RemovedChannelCalls++
        throw 'The removed independent secure-channel cmdlet was invoked.'
    }
    function Get-CimInstance {
        param($ClassName, $ErrorAction)
        Assert-Equal 'Win32_ComputerSystem' $ClassName 'domain probe still queries joined-domain membership'
        [pscustomobject]@{ PartOfDomain = $true; Domain = 'nocm.com' }
    }
    function nltest.exe {
        param($Operation)
        Assert-Equal '/sc_query:nocm.com' $Operation 'domain probe still queries Netlogon status'
        $global:LASTEXITCODE = 0
        'Trusted DC Name \\NOC-DC1.nocm.com'
    }
    function Resolve-DnsName {
        param($Name, $Type, $ErrorAction)
        Assert-Equal 'A' $Type 'domain probe still checks DNS registration'
        [pscustomobject]@{ IPAddress = '10.220.201.20' }
    }
    $probeValues = @(& $script:LastDomainProbeScript 'nocm.com')
    Assert-Equal 1 $probeValues.Count 'the reduced guest readiness probe returns exactly one result'
    Assert-Equal 0 $script:RemovedChannelCalls 'the actual guest readiness probe never invokes Test-ComputerSecureChannel'
    Assert-True ($probeValues[0].PartOfDomain -and $probeValues[0].NltestHealthy -and
        $probeValues[0].Domain -eq 'nocm.com' -and $probeValues[0].DnsAddresses.Count -eq 1) `
        'the actual guest probe preserves domain membership, Netlogon status, and DNS evidence'
    Assert-True (-not $probeValues[0].PSObject.Properties['SecureChannel'] -and
        -not $probeValues[0].PSObject.Properties['SecureChannelError']) 'the removed cmdlet result is not emitted by the guest probe'
}
$savedDomainHealth = $script:MockDomainHealth
foreach ($membership in @(
        @{ PartOfDomain = $false; Domain = 'WORKGROUP' },
        @{ PartOfDomain = $true; Domain = 'wrong.test' }
    )) {
    $script:MockDomainHealth = [pscustomobject]@{
        PartOfDomain = $membership.PartOfDomain; Domain = $membership.Domain
        NltestHealthy = $true; NltestExitCode = 0; DnsAddresses = @('10.220.201.20')
    }
    Assert-ThrowsLike {
        Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'invalid-membership' `
            -AdminCachePath $credentialPath -MaximumAttempts 2 -RetrySeconds 0
    } "*outside 'nocm.com'*" 'missing or wrong joined-domain membership still blocks the runner'
}
$script:MockDomainHealth = $savedDomainHealth
$script:CredentialAttempts.Clear()
$script:RejectedCredentialUsers = @('admin2@nocm.com')
try {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath -RetrySeconds 0
    Write-TestResult -Passed $true -What 'Server 2019-style UPN rejection falls back to the exact NetBIOS domain principal'
}
catch {
    Write-TestResult -Passed $false -What 'Server 2019-style UPN rejection falls back to the exact NetBIOS domain principal' -Detail $_.Exception.Message
}
Assert-Equal 'admin2@nocm.com|NOCM\admin2|admin2@nocm.com|NOCM\admin2' ($script:CredentialAttempts -join '|') 'domain probe tries UPN then NetBIOS in order for both stable samples'
Assert-Equal 'NOCM\admin2' $script:LastCredentialUser 'successful fallback uses the NetBIOS domain principal'
$script:RejectedCredentialUsers = @()
$script:MockIdentityDnsDomain = 'fabrikam.com'
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath -MaximumAttempts 2 -RetrySeconds 0
} -Pattern '*Identity mismatch*' -What 'runner rejects a credential that authenticates into the wrong DNS domain'
$script:MockIdentityDnsDomain = 'nocm.com'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $false
    NltestExitCode = 5; TrustedDc = 'NOC-DC2.nocm.com'; LogonServer = '\\NOC-DC2'
    NltestOutput = 'Status = 5 0x5 ERROR_ACCESS_DENIED'; DnsAddresses = @('10.220.201.20')
}
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath -MaximumAttempts 3 -RetrySeconds 0
} -Pattern '*unhealthy Netlogon query status*' -What 'an unhealthy Netlogon query still stops the cycle'
$script:MockDomainHealthSequence.Enqueue([pscustomobject]@{
        PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $false; NltestHealthy = $false
        NltestExitCode = 1355; TrustedDc = 'NOC-DC2.nocm.com'; LogonServer = '\\NOC-DC2'
        DnsAddresses = @('10.220.201.20')
    })
$script:MockDomainHealthSequence.Enqueue([pscustomobject]@{
        PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $true
        NltestExitCode = 0; TrustedDc = 'NOC-DC1.nocm.com'; LogonServer = '\\NOC-DC1'
        DnsAddresses = @('10.220.201.20')
    })
$script:MockDomainHealthSequence.Enqueue([pscustomobject]@{
        PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $true
        NltestExitCode = 0; TrustedDc = 'NOC-DC1.nocm.com'; LogonServer = '\\NOC-DC1'
        DnsAddresses = @('10.220.201.20')
    })
try {
    $transientLog = @(Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'transient-channel' `
            -AdminCachePath $credentialPath -MaximumAttempts 4 -RetrySeconds 0 6>&1) -join "`n"
    Write-TestResult -Passed $true -What 'transient Netlogon-status lag converges before runner failure'
    Assert-True ($transientLog -like '*sample 1/4 is not yet stable*' -and
        $transientLog -like '*sample 2/4 passed (1/2 consecutive healthy samples*' -and
        $transientLog -like '*PASS: NOC-W11CLIENT1 domain convergence confirmed (2/2 consecutive healthy samples)*') `
        'unhealthy retries and healthy confirmation progress remain distinct after a transient failure'
}
catch {
    Write-TestResult -Passed $false -What 'transient Netlogon-status lag converges before runner failure' -Detail $_.Exception.Message
}
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $true
    NltestExitCode = 0; TrustedDc = 'NOC-DC1.nocm.com'; LogonServer = '\\NOC-DC1'
    DnsAddresses = @()
}
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath -MaximumAttempts 2 -RetrySeconds 0
} -Pattern '*without an A record*' -What 'missing DNS registration stops the cycle'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; NltestHealthy = $true
    NltestExitCode = 0; TrustedDc = 'NOC-DC1.nocm.com'; LogonServer = '\\NOC-DC1'
    DnsAddresses = @('10.220.201.20')
}
$shortHealthLog = [Collections.Generic.List[object]]::new()
Assert-ThrowsLike {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'insufficient-confirmation' `
        -AdminCachePath $credentialPath -MaximumAttempts 1 -RetrySeconds 0 6>&1 |
        ForEach-Object { $shortHealthLog.Add($_) }
} -Pattern '*without 2 consecutive healthy domain samples*' -What 'one healthy sample still cannot complete domain validation'
Assert-True (($shortHealthLog -join "`n") -notlike '*PASS: NOC-W11CLIENT1 domain convergence confirmed*') `
    'insufficient healthy samples never print a successful domain confirmation'
Remove-Item -LiteralPath $credentialPath -Force -ErrorAction SilentlyContinue

$specialConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ prefix = 'NOC-' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient' }
        [pscustomobject]@{ vmName = 'W11AAD1'; role = 'AADClient' }
    )
}
$script:MockVms['NOC-OSD1'] = [pscustomobject]@{
    Name = 'NOC-OSD1'; Id = [guid]::NewGuid(); Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":1}'
}
$script:MockVms['NOC-W11AAD1'] = [pscustomobject]@{
    Name = 'NOC-W11AAD1'; Id = [guid]::NewGuid(); Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":3,"oobeComplete":true}'
}
try {
    Assert-DevelopStageComplete -Config $specialConfig -FixtureName 'special-client-fixtures'
    Write-TestResult -Passed $true -What 'OSD and AAD clients use their role-specific completion markers'
}
catch {
    Write-TestResult -Passed $false -What 'OSD and AAD clients use their role-specific completion markers' -Detail $_.Exception.Message
}
try {
    Assert-DomainJoinedVmHealth -Config $specialConfig -FixtureName 'special-client-fixtures' -AdminCachePath $credentialPath
    Write-TestResult -Passed $true -What 'OSD and AAD clients are excluded from domain secure-channel checks'
}
catch {
    Write-TestResult -Passed $false -What 'OSD and AAD clients are excluded from domain secure-channel checks' -Detail $_.Exception.Message
}
$script:MockVms['NOC-W11AAD1'].Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":3}'
Assert-ThrowsLike -Action {
    Assert-DevelopStageComplete -Config $specialConfig -FixtureName 'special-client-fixtures'
} -Pattern '*without oobeComplete=true*' -What 'AAD client without durable OOBE marker fails the cycle'

$script:StatePath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-crossrevision-state-$PID.json"
$script:State = [ordered]@{
    LastUpdateUtc  = $null
    Status         = 'Ready'
    CurrentStep    = $null
    LastError      = $null
    CompletedSteps = @()
}
Start-Step -Step 'nocm|main|A'
$runningState = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
Assert-Equal 'Running' $runningState.Status 'checkpoint records a running step before mutation'
Assert-Equal 'nocm|main|A' $runningState.CurrentStep 'checkpoint identifies the in-progress step'
Assert-Equal $true ([bool](Test-StepInProgress -Step 'nocm|main|A')) 'resume logic recognizes the in-progress baseline step'
Complete-Step -Step 'nocm|main|A'
$completedState = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
Assert-Equal $true ([bool](Test-StepComplete -Step 'nocm|main|A')) 'completed step is visible to resume logic'
Assert-Equal 'nocm|main|A' $completedState.CompletedSteps 'completed step is persisted atomically'
Assert-Equal $false (Test-Path -LiteralPath "$script:StatePath.$PID.tmp") 'atomic checkpoint leaves no temporary file'
Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue

foreach ($regression in @(
        @{ Name = 'Test-RemoteWorkflowDependency'; Engine = (Join-Path $PSHOME 'pwsh.exe'); Label = 'PS7' },
        @{ Name = 'Test-RemoteWorkflowDependency'; Engine = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'); Label = 'PS51' },
        @{ Name = 'Test-Phase8DiagnosticTelemetry'; Engine = (Join-Path $PSHOME 'pwsh.exe'); Label = 'PS7' }
    )) {
    & $regression.Engine -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot "$($regression.Name).ps1")
    Write-TestResult -Passed ($LASTEXITCODE -eq 0) -What "early defect coverage: $($regression.Name) ($($regression.Label))"
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'PASS: main-to-develop expansion runner guardrails behave as expected.' -ForegroundColor Green
exit 0
