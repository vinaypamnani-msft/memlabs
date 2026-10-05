<#
.SYNOPSIS
    Tests the main-to-develop expansion runner without changing Hyper-V.
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
$script:Failures = 0
$script:MockVms = @{}
$script:MockDisks = @{}
$script:MockDomainSid = 'S-1-5-21-100-200-300'
$script:LastCredentialUser = $null
$script:CredentialAttempts = [System.Collections.Generic.List[string]]::new()
$script:RejectedCredentialUsers = @()
$script:MockIdentityDnsDomain = 'nocm.com'
$script:MockIdentityUser = $null
$script:MockGetVmFailure = $false
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; DnsAddresses = @('10.220.201.20')
}

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
    if ("$ScriptBlock" -like '*Test-ComputerSecureChannel*') {
        return [pscustomobject]@{
            PartOfDomain = $script:MockDomainHealth.PartOfDomain
            Domain = $script:MockDomainHealth.Domain
            SecureChannel = $script:MockDomainHealth.SecureChannel
            DnsAddresses = @($script:MockDomainHealth.DnsAddresses)
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
$pwshPath = Join-Path $PSHOME 'pwsh.exe'

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
. (Import-TestFunction -Path $runnerPath -Name Get-VmIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-BaselineIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DevelopStageComplete)
. (Import-TestFunction -Path $runnerPath -Name Resolve-CrossRevisionDomainNetBiosName)
. (Import-TestFunction -Path $runnerPath -Name New-DomainCredentials)
. (Import-TestFunction -Path $runnerPath -Name New-DomainCredential)
. (Import-TestFunction -Path $runnerPath -Name Invoke-CrossRevisionDomainProbe)
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
$cancelCheckpoint = Join-Path $cancelRoot 'checkpoint.txt'
$cancelLocationResult = Join-Path $cancelRoot 'location.txt'
$cancelPs = $null
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $cancelSource 'vmbuild\logs') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $cancelWorktree 'vmbuild') -Force
    $cancelChild = Join-Path $cancelWorktree 'vmbuild\CancelChild.ps1'
    [IO.File]::WriteAllText($cancelChild, @'
param([string] $MarkerPath, [string] $PidPath)
$descendant = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -PassThru
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
                -Parameters ([ordered]@{ MarkerPath = $Marker; PidPath = $Pids }) -Label 'cancel-test'
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
        AddArgument($cancelLocationResult)
    $cancelAsync = $cancelPs.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $cancelMarker -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    $publishedPids = if (Test-Path -LiteralPath $cancelPids) {
        @((Get-Content -LiteralPath $cancelPids -Raw).Trim() -split '\|' | ForEach-Object { [int]$_ })
    }
    else {
        @()
    }
    Assert-Equal 2 $publishedPids.Count 'cancellation fixture publishes launcher and descendant IDs'
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
            (Join-Path $runtimeWorktree 'vmbuild\cache'),
            (Join-Path $runtimeWorktree 'vmbuild\config'),
            $wrongAssets
        )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText((Join-Path $runtimeWorktree 'vmbuild\cache\git-branch-context.json'), '{"CurrentBranch":"main"}')
    $global:RepositoryRoot = $runtimeSource
    $StateRoot = Join-Path $runtimeTestRoot 'state'
    Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    $runtimeLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\azureFiles') -Force
    Assert-Equal ([IO.Path]::GetFullPath((Join-Path $runtimeSource 'vmbuild\azureFiles')).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeLink.Target).TrimEnd('\')) 'runtime worktree media link targets the source media directory'
    $runtimeLogLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\logs') -Force
    $runtimeSharedLogs = Join-Path $runtimeSource 'vmbuild\logs\CrossRevision\worktree'
    Assert-Equal ([IO.Path]::GetFullPath($runtimeSharedLogs).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeLogLink.Target).TrimEnd('\')) 'runtime worktree log link targets its folder under normal logs'
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
    $recoverOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $runnerPath `
            -RecoverLogsOnly -RepositoryRoot $recoverCliSource -StateRoot $recoverCliState 2>&1 |
            ForEach-Object { "$_" })
    Assert-Equal 0 $LASTEXITCODE 'recover-logs-only mode exits successfully without a test selection'
    Assert-True (($recoverOutput -join "`n") -like '*PASS: cross-revision logs now write under*') `
        'recover-logs-only mode reports the normal log destination'
    Assert-Equal 'Junction' (Get-Item -LiteralPath $recoverCliLogs -Force).LinkType `
        'recover-logs-only mode links an existing pinned worktree'
    Assert-Equal 'recover-only' (Get-Content -LiteralPath (Join-Path $recoverCliSource `
                'vmbuild\logs\CrossRevision\develop-recover\VMBuild.recover.log') -Raw) `
        'recover-logs-only mode moves stranded evidence under normal logs'
}
finally {
    if (Test-Path -LiteralPath $recoverCliLogs) { Remove-Item -LiteralPath $recoverCliLogs -Force -ErrorAction SilentlyContinue }
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

$baselineId = [guid]::NewGuid()
$script:MockVms['NOC-DC1'] = [pscustomobject]@{
    Name = 'NOC-DC1'; Id = $baselineId; Notes = '{"success":true,"inProgress":false,"lastPhaseComplete":11}'
}
$script:MockDisks['NOC-DC1'] = @([pscustomobject]@{
        ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0; Path = 'E:\VirtualMachines\NOC-DC1.vhdx'
    })
$identity = @(Get-VmIdentity -VmNames @('NOC-DC1'))
Assert-Equal "$baselineId" $identity[0].Id 'baseline identity captures the Hyper-V VM ID'
Assert-Equal 'E:\VirtualMachines\NOC-DC1.vhdx' $identity[0].VhdPaths[0] 'baseline identity captures disk attachment paths'

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
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath
    Write-TestResult -Passed $true -What 'domain member independently passes join, secure-channel, and DNS checks'
}
catch {
    Write-TestResult -Passed $false -What 'domain member independently passes join, secure-channel, and DNS checks' -Detail $_.Exception.Message
}
$script:CredentialAttempts.Clear()
$script:RejectedCredentialUsers = @('admin2@nocm.com')
try {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath
    Write-TestResult -Passed $true -What 'Server 2019-style UPN rejection falls back to the exact NetBIOS domain principal'
}
catch {
    Write-TestResult -Passed $false -What 'Server 2019-style UPN rejection falls back to the exact NetBIOS domain principal' -Detail $_.Exception.Message
}
Assert-Equal 'admin2@nocm.com|NOCM\admin2' ($script:CredentialAttempts -join '|') 'domain probe tries UPN then NetBIOS in order'
Assert-Equal 'NOCM\admin2' $script:LastCredentialUser 'successful fallback uses the NetBIOS domain principal'
$script:RejectedCredentialUsers = @()
$script:MockIdentityDnsDomain = 'fabrikam.com'
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath
} -Pattern '*Identity mismatch*' -What 'runner rejects a credential that authenticates into the wrong DNS domain'
$script:MockIdentityDnsDomain = 'nocm.com'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $false; DnsAddresses = @('10.220.201.20')
}
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath
} -Pattern '*broken secure channel*' -What 'independent secure-channel failure stops the cycle'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; DnsAddresses = @()
}
Assert-ThrowsLike -Action {
    Assert-DomainJoinedVmHealth -Config $stageConfig -FixtureName 'NOCM-B-AddWin11.json' -AdminCachePath $credentialPath
} -Pattern '*without an A record*' -What 'missing DNS registration stops the cycle'
$script:MockDomainHealth = [pscustomobject]@{
    PartOfDomain = $true; Domain = 'nocm.com'; SecureChannel = $true; DnsAddresses = @('10.220.201.20')
}
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

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'PASS: main-to-develop expansion runner guardrails behave as expected.' -ForegroundColor Green
exit 0
