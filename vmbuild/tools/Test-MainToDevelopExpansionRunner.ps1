<#
.SYNOPSIS
    Tests the main-to-develop expansion runner without changing Hyper-V.
#>
[CmdletBinding()]
param([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$repoRoot = Split-Path -Parent $RootPath
$runnerPath = Join-Path $PSScriptRoot 'Invoke-MainToDevelopExpansionTest.ps1'
$script:Failures = 0
$script:MockVms = @{}
$script:MockDisks = @{}
$script:MockDomainSid = 'S-1-5-21-100-200-300'
$script:LastCredentialUser = $null
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
    if ("$ScriptBlock" -like '*Test-ComputerSecureChannel*') { return $script:MockDomainHealth }
    return $script:MockDomainSid
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
Assert-Equal 0 $allExit 'all-family plan exits successfully'
Assert-True ($allText -like '*10 family/families, 37 follow-on fixture(s), 74 develop deployment pass(es).*') 'all-family plan has the expected revision matrix'
Assert-True ($allText -like '*CSTEST8-B-Other Domain and more.json*') 'all-family plan includes the multi-domain follow-on'
Assert-Equal $false (Test-Path -LiteralPath $stateRoot) 'plan-only mode creates no state or worktree directory'

$singleOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -File $runnerPath `
        -RepositoryRoot $repoRoot -Test NOCM -PlanOnly -StateRoot $stateRoot 2>&1 | ForEach-Object { "$_" })
$singleExit = $LASTEXITCODE
$singleText = $singleOutput -join [Environment]::NewLine
Assert-Equal 0 $singleExit 'single-family plan exits successfully'
Assert-True ($singleText -like '*1 family/families, 7 follow-on fixture(s), 14 develop deployment pass(es).*') 'single-family plan selects NOCM only'
Assert-True ($singleText -notlike '*CSTest1-A-CSPS.json*') 'single-family plan excludes unrelated families'
Assert-Equal $false (Test-Path -LiteralPath $stateRoot) 'single-family plan remains non-mutating'

. (Import-TestFunction -Path $runnerPath -Name Invoke-Git)
. (Import-TestFunction -Path $runnerPath -Name Initialize-PinnedWorktree)
. (Import-TestFunction -Path $runnerPath -Name Initialize-WorktreeRuntime)
. (Import-TestFunction -Path $runnerPath -Name Get-OrderedCrossRevisionPlan)
. (Import-TestFunction -Path $runnerPath -Name Get-FullVmName)
. (Import-TestFunction -Path $runnerPath -Name Get-ExpectedVmNames)
. (Import-TestFunction -Path $runnerPath -Name Get-DomainVms)
. (Import-TestFunction -Path $runnerPath -Name Get-ExistingNamedVms)
. (Import-TestFunction -Path $runnerPath -Name Get-VmIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-BaselineIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DevelopStageComplete)
. (Import-TestFunction -Path $runnerPath -Name New-DomainCredential)
. (Import-TestFunction -Path $runnerPath -Name Get-DomainIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainIdentity)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainJoinedVmHealth)
. (Import-TestFunction -Path $runnerPath -Name Assert-DomainsAbsent)
. (Import-TestFunction -Path $runnerPath -Name Assert-MainBaselineCanStart)
. (Import-TestFunction -Path $runnerPath -Name Save-State)
. (Import-TestFunction -Path $runnerPath -Name Test-StepComplete)
. (Import-TestFunction -Path $runnerPath -Name Test-StepInProgress)
. (Import-TestFunction -Path $runnerPath -Name Start-Step)
. (Import-TestFunction -Path $runnerPath -Name Complete-Step)

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
try {
    $null = New-Item -ItemType Directory -Path $gitTestRepo -Force
    & git -C $gitTestRepo init -q
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize temporary Git repository.' }
    [IO.File]::WriteAllText((Join-Path $gitTestRepo 'fixture.txt'), 'fixture')
    & git -C $gitTestRepo add fixture.txt
    & git -C $gitTestRepo -c user.name=MemLabsTest -c user.email=memlabs-test@example.invalid commit -q -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Could not create temporary Git commit.' }
    $gitTestCommit = (& git -C $gitTestRepo rev-parse HEAD).Trim()
    $global:RepositoryRoot = $gitTestRepo
    Initialize-PinnedWorktree -Path $gitTestWorktree -Commit $gitTestCommit -BranchName 'memlabs-cross-develop-test'
    $gitTestBranch = (& git -C $gitTestWorktree branch --show-current).Trim()
    Assert-Equal 'memlabs-cross-develop-test' $gitTestBranch 'pinned develop worktree retains a develop-named branch'
    Assert-True ($gitTestBranch -notmatch 'main') 'develop worktree branch selects develop media mode'
}
finally {
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
try {
    foreach ($directory in @(
            (Join-Path $runtimeSource 'vmbuild\azureFiles'),
            (Join-Path $runtimeSource 'vmbuild\cache'),
            (Join-Path $runtimeSource 'vmbuild\config'),
            (Join-Path $runtimeWorktree 'vmbuild\cache'),
            (Join-Path $runtimeWorktree 'vmbuild\config'),
            $wrongAssets
        )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    [IO.File]::WriteAllText((Join-Path $runtimeWorktree 'vmbuild\cache\git-branch-context.json'), '{"CurrentBranch":"main"}')
    $global:RepositoryRoot = $runtimeSource
    Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    $runtimeLink = Get-Item -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\azureFiles') -Force
    Assert-Equal ([IO.Path]::GetFullPath((Join-Path $runtimeSource 'vmbuild\azureFiles')).TrimEnd('\')) `
        ([IO.Path]::GetFullPath([string]$runtimeLink.Target).TrimEnd('\')) 'runtime worktree media link targets the source media directory'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $runtimeWorktree 'vmbuild\cache\git-branch-context.json')) 'runtime initialization clears stale branch context'

    Remove-Item -LiteralPath $runtimeLink.FullName -Force
    $null = New-Item -ItemType Junction -Path $runtimeLink.FullName -Target $wrongAssets
    Assert-ThrowsLike -Action {
        Initialize-WorktreeRuntime -WorktreePath $runtimeWorktree
    } -Pattern '*targets*expected*Remove the stale worktree*' -What 'runtime initialization rejects a stale media junction target'
}
finally {
    $global:RepositoryRoot = $sourceRepoRoot
    $runtimeAssets = Join-Path $runtimeWorktree 'vmbuild\azureFiles'
    if (Test-Path -LiteralPath $runtimeAssets) { Remove-Item -LiteralPath $runtimeAssets -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $runtimeTestRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    vmOptions       = [pscustomobject]@{ prefix = 'NOC-'; domainName = 'nocm.com'; adminName = 'admin2' }
    virtualMachines = @([pscustomobject]@{ vmName = 'DC1'; role = 'DC' })
}
$domainIdentity = Get-DomainIdentity -Config $domainConfig -AdminCachePath $credentialPath
Assert-Equal 'S-1-5-21-100-200-300' $domainIdentity.Sid 'baseline identity captures the AD domain SID'
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
    vmOptions       = [pscustomobject]@{ prefix = 'NOC-'; domainName = 'nocm.com'; adminName = 'admin2' }
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
