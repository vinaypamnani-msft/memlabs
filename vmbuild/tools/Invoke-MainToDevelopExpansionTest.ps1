<#
.SYNOPSIS
    Runs existing-domain expansion tests across pinned main and develop revisions.

.DESCRIPTION
    For each selected test family, deploys the A fixture once with exact-main code,
    then deploys every B-and-later fixture twice with the pinned develop candidate.
    Families without a follow-on fixture are skipped. Each family is removed only
    after every stage and its idempotence pass succeeds.

    Develop failures retain their VMs. Exact-main has no KeepFailedVMs switch and
    may remove Phase 1 VMs when its baseline deployment fails; this runner does not
    patch that historical behavior.

    The runner uses separate Git worktrees and never pulls during one family. State
    is written after every completed stage. Develop commit IDs are retained only as
    provenance; every restart and family boundary advances to current fast-forward
    develop code. Each worktree's vmbuild\logs directory is linked to the source
    checkout's normal log directory so existing log-sync automation captures mixed-test failures.
    Follow-on stages resume without replaying the main baseline. If develop advances
    by fast-forward, an interrupted develop or cleanup step can resume with the newer
    code when the same fixture or cleanup domain still exists in the new plan.
    An interruption while exact-main A itself is running fails closed because no
    pre-mutation VM/domain identity exists to prove what survived; remove that family
    lab and reset its state before retrying. Use -PlanOnly to inspect the revision and
    fixture matrix without creating worktrees, writing state, or touching Hyper-V.

.EXAMPLE
    .\Invoke-MainToDevelopExpansionTest.ps1 -All -PlanOnly

.EXAMPLE
    .\Invoke-MainToDevelopExpansionTest.ps1 -Test NOCM

.EXAMPLE
    .\Invoke-MainToDevelopExpansionTest.ps1 -Test NOCM -ResetState

    Resets checkpoint metadata only. Existing matching VMs still block a new baseline
    and must be deliberately removed first.

.EXAMPLE
    .\Invoke-MainToDevelopExpansionTest.ps1 -RecoverLogsOnly

    Moves logs from existing pinned worktrees into vmbuild\logs\CrossRevision,
    replaces each worktree log directory with a junction, and exits.
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'All')]
    [switch] $All,

    [Parameter(Mandatory = $true, ParameterSetName = 'Test')]
    [string] $Test,

    [Parameter(Mandatory = $true, ParameterSetName = 'Tests')]
    [string] $TestsCsv,

    [Parameter(Mandatory = $true, ParameterSetName = 'RecoverLogs')]
    [switch] $RecoverLogsOnly,

    [string] $RepositoryRoot,

    [string] $MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf',

    [string] $DevelopRevision = 'HEAD',

    [string] $StateRoot = (Join-Path $env:ProgramData 'MemLabs\CrossRevision'),

    [switch] $PlanOnly,

    [switch] $ResetState,

    [switch] $PauseAtFamilyBoundary,

    [switch] $RequireCleanSource
)

if (-not $RepositoryRoot) {
    $vmbuildRoot = Split-Path -Parent $PSScriptRoot
    $RepositoryRoot = Split-Path -Parent $vmbuildRoot
}
. (Join-Path $PSScriptRoot 'Common.TestHistory.ps1')
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$pwshPath = Join-Path $PSHOME 'pwsh.exe'
$script:ChildLauncherPath = Join-Path $PSScriptRoot 'Invoke-PinnedChildScript.ps1'
$script:MutationMutex = $null
$script:MutationMutexHeld = $false
$script:MainBaselineFailureCleanupPossible = $false
$script:HistoryRun = $null
$script:ExactMainClusterAdapterCompatibilityActive = $false
$script:LastChildResult = $null

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = @(& git -C $RepositoryRoot @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode`: $($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { "$_" })
}

function Resolve-GitRevision {
    param([string] $Revision)

    $resolved = @(Invoke-Git -Arguments @('rev-parse', "$Revision^{commit}"))
    if ($resolved.Count -ne 1 -or $resolved[0] -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve '$Revision' to one commit."
    }
    return $resolved[0]
}

function Restore-ExactMainClusterAdapterCompatibility {
    param([switch] $BestEffort)

    $compatAlias = 'MemLabs-HB2-Compat'
    $clusterV2Alias = 'vEthernet (ClusterV2)'
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
        $compat = @($adapters | Where-Object { $_.Name -eq $compatAlias })
        $normal = @($adapters | Where-Object { $_.Name -eq $clusterV2Alias })
        if ($compat.Count -gt 1 -or $normal.Count -gt 1) {
            throw "ClusterV2 adapter alias state is ambiguous (compat=$($compat.Count), normal=$($normal.Count))."
        }
        if ($compat.Count -eq 0) {
            $script:ExactMainClusterAdapterCompatibilityActive = $false
            return $false
        }
        if ($normal.Count -gt 0) {
            throw "Both '$compatAlias' and '$clusterV2Alias' exist; refusing to overwrite either adapter."
        }
        Rename-NetAdapter -Name $compatAlias -NewName $clusterV2Alias -ErrorAction Stop
        $restored = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                $_.Name -eq $clusterV2Alias
            })
        if ($restored.Count -ne 1) {
            throw "ClusterV2 adapter alias restore did not produce exactly one '$clusterV2Alias' adapter."
        }
        $script:ExactMainClusterAdapterCompatibilityActive = $false
        Write-Host "COMPAT: restored host adapter alias '$clusterV2Alias'." -ForegroundColor DarkGray
        return $true
    }
    catch {
        if ($BestEffort) {
            Write-Host "WARNING: Could not restore exact-main ClusterV2 compatibility alias: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
        throw
    }
}

function Enter-ExactMainClusterAdapterCompatibility {
    $compatAlias = 'MemLabs-HB2-Compat'
    $clusterV2Alias = 'vEthernet (ClusterV2)'
    $legacyClusterAlias = 'vEthernet (Cluster)'

    $null = Restore-ExactMainClusterAdapterCompatibility
    $adapters = @(Get-NetAdapter -ErrorAction Stop)
    $clusterV2 = @($adapters | Where-Object { $_.Name -eq $clusterV2Alias })
    if ($clusterV2.Count -eq 0) { return $false }
    if ($clusterV2.Count -ne 1) {
        throw "Expected one '$clusterV2Alias' adapter, found $($clusterV2.Count)."
    }
    if (@($adapters | Where-Object { $_.Name -eq $compatAlias }).Count -gt 0) {
        throw "Compatibility alias '$compatAlias' already exists."
    }

    Rename-NetAdapter -Name $clusterV2Alias -NewName $compatAlias -ErrorAction Stop
    $script:ExactMainClusterAdapterCompatibilityActive = $true

    $legacyMatches = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Name -like '*Cluster*'
        })
    $unexpected = @($legacyMatches | Where-Object { $_.Name -ne $legacyClusterAlias })
    if ($unexpected.Count -gt 0 -or $legacyMatches.Count -gt 1) {
        $names = @($legacyMatches | ForEach-Object { $_.Name }) -join ', '
        throw "Exact-main would still resolve multiple/prefix Cluster adapters after hiding ClusterV2: $names"
    }
    Write-Host "COMPAT: temporarily renamed '$clusterV2Alias' to '$compatAlias' while exact-main runs." -ForegroundColor DarkGray
    return $true
}

function Get-ActiveCrossRevisionCheckpoint {
    param(
        [string] $Root,
        [string] $MainCommit
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }

    $shortMain = $MainCommit.Substring(0, 8)
    $active = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Filter "state-$shortMain-to-*.json" -File -ErrorAction Stop)) {
        try {
            $state = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "Could not read checkpoint '$($file.FullName)': $($_.Exception.Message)"
        }
        if ([string]$state.MainRevision -ne $MainCommit) { continue }

        $hasProgress = Test-CrossRevisionStateProgress -State $state
        $isActive = [string]$state.Status -eq 'Running' -or
            ([string]$state.Status -eq 'Failed' -and $hasProgress)
        if (-not $isActive) { continue }
        if ([string]$state.DevelopRevision -notmatch '^[0-9a-f]{40}$') {
            throw "Active checkpoint '$($file.FullName)' has an invalid develop revision."
        }

        $active += [pscustomobject]@{
            Path            = $file.FullName
            DevelopRevision = [string]$state.DevelopRevision
            CurrentStep     = [string]$state.CurrentStep
            Status          = [string]$state.Status
        }
    }

    if ($active.Count -gt 1) {
        throw "Multiple active checkpoints exist for main $MainCommit`: $($active.Path -join ', '). Resolve them before starting another cycle."
    }
    if ($active.Count -eq 1) { return $active[0] }
    return $null
}

function Test-CrossRevisionStateProgress {
    param([object] $State)

    $completedCount = @($State.CompletedSteps | Where-Object { $_ }).Count
    $baselineCount = if ($State.Baselines -is [Collections.IDictionary]) {
        $State.Baselines.Count
    }
    elseif ($State.Baselines) {
        @($State.Baselines.PSObject.Properties).Count
    }
    else {
        0
    }
    return -not [string]::IsNullOrWhiteSpace([string]$State.CurrentStep) -or
        $completedCount -gt 0 -or $baselineCount -gt 0
}

function Test-GitCommitAncestor {
    param([string] $Ancestor, [string] $Descendant)

    & git -C $RepositoryRoot merge-base --is-ancestor $Ancestor $Descendant
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 1) { return $false }
    throw "git merge-base --is-ancestor $Ancestor $Descendant failed with exit code $exitCode."
}

function Assert-CrossRevisionCheckpointCanAdvance {
    param(
        [Collections.IDictionary] $State,
        [object[]] $Plan,
        [string] $NewDevelopCommit
    )

    $oldDevelopCommit = [string]$State.DevelopRevision
    if (-not (Test-GitCommitAncestor -Ancestor $oldDevelopCommit -Descendant $NewDevelopCommit)) {
        throw "Active checkpoint develop $oldDevelopCommit is not an ancestor of requested develop $NewDevelopCommit. Rolling resume only supports fast-forward develop changes."
    }

    $currentStep = [string]$State.CurrentStep
    if ([string]::IsNullOrWhiteSpace($currentStep)) { return }
    $parts = @($currentStep -split '\|')
    if ($parts.Count -lt 3) { throw "Active checkpoint has an invalid current step: '$currentStep'." }

    $familyKey = $parts[0].ToLowerInvariant()
    $stageType = $parts[1].ToLowerInvariant()
    if ($stageType -eq 'main') {
        if ($parts[2] -ine 'A') {
            throw "Active exact-main checkpoint '$currentStep' is not the recognized A baseline step."
        }
        $familyPlan = @($Plan | Where-Object { $_.Family -ieq $familyKey })
        if ($familyPlan.Count -ne 1) {
            throw "The interrupted exact-main family '$familyKey' is not present exactly once in requested develop $NewDevelopCommit."
        }
        return
    }
    if ($stageType -eq 'cleanup') {
        $familyPlan = @($Plan | Where-Object { $_.Family -ieq $familyKey })
        if ($familyPlan.Count -ne 1) {
            throw "The cleanup family '$familyKey' is not present exactly once in requested develop $NewDevelopCommit."
        }
        $cleanupDomain = $parts[2]
        if (@($familyPlan[0].Domains | Where-Object { $_ -ieq $cleanupDomain }).Count -ne 1) {
            throw "The cleanup domain '$cleanupDomain' is not present exactly once for family '$familyKey' in requested develop $NewDevelopCommit."
        }
        return
    }
    if ($stageType -ne 'develop' -or $parts.Count -lt 4) {
        throw "Active checkpoint step '$currentStep' is not a recognized develop stage."
    }
    if (@($State.CompletedSteps) -notcontains "$familyKey|main|A") {
        throw "Cannot advance develop because '$familyKey' has no completed exact-main baseline checkpoint."
    }
    if (-not $State.Baselines.Contains($familyKey) -or @($State.Baselines[$familyKey]).Count -eq 0) {
        throw "Cannot advance develop because '$familyKey' has no saved baseline VM identity."
    }
    if (-not $State.DomainIdentities.Contains($familyKey) -or -not $State.DomainIdentities[$familyKey]) {
        throw "Cannot advance develop because '$familyKey' has no saved baseline domain identity."
    }

    $familyPlan = @($Plan | Where-Object { $_.Family -ieq $familyKey })
    if ($familyPlan.Count -ne 1) {
        throw "The active family '$familyKey' is not present exactly once in requested develop $NewDevelopCommit."
    }
    $fixtureName = $parts[3]
    if (@($familyPlan[0].FollowOns | Where-Object { $_.Name -eq $fixtureName }).Count -ne 1) {
        throw "The in-progress fixture '$fixtureName' is not present in requested develop $NewDevelopCommit."
    }
}

function Write-CrossRevisionStateFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State
    )

    $State.LastUpdateUtc = [DateTime]::UtcNow.ToString('o')
    $tempPath = "$Path.$PID.tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Reset-CrossRevisionFamilyState {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][string]$Family
    )

    $familyKey = $Family.ToLowerInvariant()
    $State.CompletedSteps = @($State.CompletedSteps | Where-Object {
            "$_".ToLowerInvariant() -notlike "$familyKey|*"
        })
    if ("$($State.CurrentStep)".ToLowerInvariant() -like "$familyKey|*") {
        $State.CurrentStep = $null
    }

    foreach ($propertyName in @('Baselines', 'DomainIdentities')) {
        $map = $State[$propertyName]
        if ($map -is [Collections.IDictionary] -and $map.Contains($familyKey)) {
            $map.Remove($familyKey)
        }
    }
    foreach ($propertyName in @('DevelopIdentities', 'DevelopDomainIdentities')) {
        $map = $State[$propertyName]
        if ($map -isnot [Collections.IDictionary]) { continue }
        foreach ($key in @($map.Keys)) {
            if ("$key".ToLowerInvariant() -like "$familyKey|*") { $map.Remove($key) }
        }
    }
    $State.Status = 'Failed'
    $State.LastError = $null
}

function Resolve-CrossRevisionResetFamily {
    param(
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][string]$TestPrefix
    )

    $matches = @($Plan | Where-Object { $_.Family -like "$TestPrefix*" })
    if ($matches.Count -ne 1) {
        $names = @($matches | ForEach-Object { $_.Family })
        $detail = if ($names.Count -gt 0) { $names -join ', ' } else { '<none>' }
        throw "-ResetState with -Test '$TestPrefix' must resolve to exactly one family; matched $($matches.Count): $detail."
    }
    return [string]$matches[0].Family
}

function Resolve-CrossRevisionActiveResetFamily {
    param(
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$State
    )

    $currentStep = [string]$State.CurrentStep
    if ([string]::IsNullOrWhiteSpace($currentStep)) { return $null }

    $parts = @($currentStep -split '\|')
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        throw "Active checkpoint has an invalid current step: '$currentStep'."
    }

    $familyPlans = @($Plan | Where-Object { $_.Family -ieq $parts[0] })
    if ($familyPlans.Count -ne 1) {
        $detail = if ($familyPlans.Count -gt 0) {
            @($familyPlans | ForEach-Object { $_.Family }) -join ', '
        }
        else {
            '<none>'
        }
        throw "The in-progress family '$($parts[0])' must resolve exactly once in the requested plan; matched $($familyPlans.Count): $detail."
    }

    return [string]$familyPlans[0].Family
}

function Move-CrossRevisionCheckpoint {
    param(
        [string] $ActivePath,
        [Collections.IDictionary] $State,
        [string] $Root,
        [string] $MainCommit,
        [string] $NewDevelopCommit
    )

    $shortMain = $MainCommit.Substring(0, 8)
    $shortDevelop = $NewDevelopCommit.Substring(0, 8)
    $targetPath = Join-Path $Root "state-$shortMain-to-$shortDevelop.json"
    if ([IO.Path]::GetFullPath($ActivePath) -ieq [IO.Path]::GetFullPath($targetPath)) { return $targetPath }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    if (Test-Path -LiteralPath $targetPath) {
        $targetState = Get-Content -LiteralPath $targetPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
        if ([string]$targetState.Status -eq 'Running' -or (Test-CrossRevisionStateProgress -State $targetState)) {
            throw "Requested develop checkpoint '$targetPath' already contains progress and cannot be replaced."
        }
        Move-Item -LiteralPath $targetPath -Destination "$targetPath.abandoned-$timestamp" -Force
    }

    $oldDevelopCommit = [string]$State.DevelopRevision
    $history = [Collections.Generic.List[object]]::new()
    if ($State.Contains('DevelopRevisionHistory')) {
        foreach ($entry in @($State.DevelopRevisionHistory)) { $history.Add($entry) }
        if ($history.Count -gt 0) {
            $currentHistory = $history[$history.Count - 1]
            if ($currentHistory -is [Collections.IDictionary]) {
                $currentHistory['SupersededUtc'] = [DateTime]::UtcNow.ToString('o')
                $currentHistory['LastError'] = $State.LastError
            }
            else {
                $currentHistory | Add-Member -NotePropertyName SupersededUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                $currentHistory | Add-Member -NotePropertyName LastError -NotePropertyValue $State.LastError -Force
            }
        }
    }
    else {
        $history.Add([ordered]@{
                Revision    = $oldDevelopCommit
                BeganUtc    = $State.StartedUtc
                SupersededUtc = [DateTime]::UtcNow.ToString('o')
                LastError   = $State.LastError
            })
    }
    $history.Add([ordered]@{
        Revision      = $NewDevelopCommit
        BeganUtc      = [DateTime]::UtcNow.ToString('o')
        SupersededUtc = $null
        LastError     = $null
    })

    $State.SchemaVersion = 2
    $State.DevelopRevision = $NewDevelopCommit
    $State.DevelopRevisionHistory = @($history.ToArray())
    $State.QualificationMode = 'RollingDevelop'
    $State.LastUpdateUtc = [DateTime]::UtcNow.ToString('o')

    $tempPath = "$targetPath.$PID.tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $targetPath -Force
        Move-Item -LiteralPath $ActivePath -Destination "$ActivePath.superseded-by-$shortDevelop-$timestamp" -Force
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    return $targetPath
}

function Get-GitText {
    param([string] $Revision, [string] $Path)

    $lines = @(Invoke-Git -Arguments @('show', "$Revision`:$Path"))
    return [string]::Join([Environment]::NewLine, $lines)
}

function Get-GitJson {
    param([string] $Revision, [string] $Path)

    try {
        return (Get-GitText -Revision $Revision -Path $Path) | ConvertFrom-Json
    }
    catch {
        throw "Could not parse $Revision`:$Path as JSON. $($_.Exception.Message)"
    }
}

function Test-ExistingVmMutationFixture {
    param([object] $Config)

    return $Config.PSObject.Properties['existingVmMutationVersion'] -and
        [int]$Config.existingVmMutationVersion -eq 1
}

function Get-FixtureRecords {
    param([string] $Revision)

    $paths = @(Invoke-Git -Arguments @('ls-tree', '-r', '--name-only', $Revision, '--', 'vmbuild/config/tests'))
    $records = @()
    foreach ($path in $paths) {
        $trimmedPath = $path.Trim()
        $name = [IO.Path]::GetFileName($trimmedPath)
        if ($name -notmatch '^(?<Family>.+?)-(?<Stage>[A-Z])(?:-|\.json$)') { continue }
        $records += [pscustomobject]@{
            Family = $Matches.Family
            Stage  = $Matches.Stage
            Name   = $name
            Path   = $trimmedPath
        }
    }
    return @($records)
}

function Get-CrossRevisionPlan {
    param(
        [string] $MainCommit,
        [string] $DevelopCommit,
        [string[]] $TestPrefixes,
        [switch] $ExactTestNames
    )

    $mainFixtures = @(Get-FixtureRecords -Revision $MainCommit)
    $developFixtures = @(Get-FixtureRecords -Revision $DevelopCommit)
    $families = @($mainFixtures | Where-Object { $_.Stage -eq 'A' } | Select-Object -ExpandProperty Family -Unique | Sort-Object)
    if ($TestPrefixes.Count -gt 0) {
        if ($ExactTestNames.IsPresent) {
            $families = @($families | Where-Object { $_ -in $TestPrefixes })
        }
        else {
            $families = @($families | Where-Object {
                    $familyName = $_
                    @($TestPrefixes | Where-Object {
                            $familyName.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
                        }).Count -gt 0
                })
        }
    }

    $plan = @()
    foreach ($family in $families) {
        $baseline = @($mainFixtures | Where-Object { $_.Family -eq $family -and $_.Stage -eq 'A' })
        $followOns = @($developFixtures |
                Where-Object { $_.Family -eq $family -and $_.Stage -ne 'A' } |
                Sort-Object Stage, Name)
        if ($baseline.Count -ne 1 -or $followOns.Count -eq 0) { continue }

        $baselineConfig = Get-GitJson -Revision $MainCommit -Path $baseline[0].Path
        $baselineDomain = [string]$baselineConfig.vmOptions.domainName
        $domains = @($baselineDomain)
        $expectedVmNames = @(Get-ExpectedVmNames -Config $baselineConfig)
        $vmNamesByDomain = @{}
        $vmNamesByDomain[$baselineDomain.ToLowerInvariant()] = @($expectedVmNames)
        foreach ($followOn in $followOns) {
            $followOnConfig = Get-GitJson -Revision $DevelopCommit -Path $followOn.Path
            $followOn | Add-Member -NotePropertyName IsExistingVmMutation `
                -NotePropertyValue (Test-ExistingVmMutationFixture -Config $followOnConfig) -Force
            $followOnDomain = [string]$followOnConfig.vmOptions.domainName
            $followOnVmNames = @(Get-ExpectedVmNames -Config $followOnConfig)
            $domains += $followOnDomain
            $expectedVmNames += $followOnVmNames
            $domainKey = $followOnDomain.ToLowerInvariant()
            $combinedNames = @($vmNamesByDomain[$domainKey]) + $followOnVmNames
            $vmNamesByDomain[$domainKey] = @($combinedNames | Select-Object -Unique)
        }

        $plan += [pscustomobject]@{
            Family         = $family
            Baseline       = $baseline[0]
            FollowOns      = $followOns
            Domains        = @($domains | Where-Object { $_ } | Select-Object -Unique)
            ExpectedVmNames = @($expectedVmNames | Select-Object -Unique)
            VmNamesByDomain = $vmNamesByDomain
            BaselineConfig = $baselineConfig
        }
    }
    return @($plan)
}

function Write-CrossRevisionPlan {
    param([object[]] $Plan, [string] $MainCommit, [string] $DevelopCommit)

    Write-Host 'Main-to-develop expansion plan' -ForegroundColor Magenta
    Write-Host "  main    : $MainCommit"
    Write-Host "  develop : $DevelopCommit"
    Write-Host '  cycle   : main A once; develop B+ twice; validate; cleanup'
    Write-Host ''
    foreach ($item in $Plan) {
        Write-Host ("{0}: {1}" -f $item.Family, $item.Baseline.Name) -ForegroundColor Cyan
        foreach ($followOn in $item.FollowOns) {
            $kind = if ($followOn.IsExistingVmMutation) { ' [existing-VM mutation]' } else { '' }
            Write-Host ("  {0}: {1}{2}" -f $followOn.Stage, $followOn.Name, $kind)
        }
        Write-Host ("  domains: {0}" -f ($item.Domains -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ("{0} family/families, {1} follow-on fixture(s), {2} develop deployment pass(es)." -f `
            $Plan.Count,
            (@($Plan | ForEach-Object { $_.FollowOns.Count }) | Measure-Object -Sum).Sum,
            (2 * (@($Plan | ForEach-Object { $_.FollowOns.Count }) | Measure-Object -Sum).Sum))
    Write-Host 'Mutation fixtures materialize through the pinned develop existing-domain GenConfig model; menu keystroke handling itself remains outside this runner.' -ForegroundColor Yellow
    Write-Host 'The VM-note preflight remains the gate for legacy NetBIOS and PKI reconstruction.' -ForegroundColor Yellow
}

function Get-OrderedCrossRevisionPlan {
    param([object[]] $Plan, [string] $CurrentStep)

    if ([string]::IsNullOrWhiteSpace($CurrentStep)) { return @($Plan) }
    $activeFamily = ($CurrentStep -split '\|', 2)[0]
    $active = @($Plan | Where-Object { $_.Family -ieq $activeFamily })
    if ($active.Count -ne 1) {
        throw "Checkpoint '$CurrentStep' belongs to family '$activeFamily', which is not in this selection. Resume that family or remove its labs and use -ResetCrossRevisionState."
    }
    $remaining = @($Plan | Where-Object { $_.Family -ine $activeFamily })
    Write-Host "RESUME: '$activeFamily' has an in-progress checkpoint and will run before other selected families." -ForegroundColor Yellow
    return @($active + $remaining)
}

function Get-FullVmName {
    param([string] $Prefix, [string] $VmName)

    if ($VmName.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { return $VmName }
    return "$Prefix$VmName"
}

function Get-ExpectedVmNames {
    param([object] $Config)

    $prefix = [string]$Config.vmOptions.prefix
    return @($Config.virtualMachines | ForEach-Object { Get-FullVmName -Prefix $prefix -VmName ([string]$_.vmName) })
}

function Get-DomainVms {
    param([string[]] $Domains)

    $domainVms = @()
    $inventory = @(Get-VM -ErrorAction Stop)
    foreach ($vm in $inventory) {
        if ([string]::IsNullOrWhiteSpace([string]$vm.Notes)) { continue }
        try { $note = $vm.Notes | ConvertFrom-Json } catch { continue }
        if ($note.domain -and $Domains -contains [string]$note.domain) {
            $domainVms += $vm
        }
    }
    return @($domainVms)
}

function Get-ExistingNamedVms {
    param([string[]] $VmNames)

    $inventory = @(Get-VM -ErrorAction Stop)
    return @($inventory | Where-Object { $VmNames -contains $_.Name })
}

function Get-VmIdentity {
    param([string[]] $VmNames)

    $identities = @()
    foreach ($vmName in $VmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { throw "Expected baseline VM '$vmName' was not found after main deployment." }
        $paths = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop |
                Sort-Object ControllerType, ControllerNumber, ControllerLocation |
                Select-Object -ExpandProperty Path)
        $identities += [ordered]@{
            Name     = $vmName
            Id       = "$($vm.Id)"
            VhdPaths = @($paths)
        }
    }
    return @($identities)
}

function Assert-BaselineIdentity {
    param([object[]] $Identity)

    foreach ($expected in $Identity) {
        $vm = Get-VM -Name $expected.Name -ErrorAction SilentlyContinue
        if (-not $vm) { throw "Baseline VM '$($expected.Name)' disappeared during expansion." }
        if ("$($vm.Id)" -ne "$($expected.Id)") {
            throw "Baseline VM '$($expected.Name)' was replaced: expected ID $($expected.Id), found $($vm.Id)."
        }
        $actualPaths = @(Get-VMHardDiskDrive -VMName $expected.Name -ErrorAction Stop |
                Sort-Object ControllerType, ControllerNumber, ControllerLocation |
                Select-Object -ExpandProperty Path)
        if (($actualPaths -join '|') -ne (@($expected.VhdPaths) -join '|')) {
            throw "Baseline VM '$($expected.Name)' disk attachment paths changed during expansion."
        }
    }
}

function Resolve-CrossRevisionDomainNetBiosName {
    param(
        [string] $Domain,
        [string] $DomainNetBiosName,
        [string] $VmName
    )

    $candidate = "$DomainNetBiosName".Trim()
    if (-not $candidate -and $VmName) {
        try {
            $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
            $note = if ($vm -and $vm.Notes) { $vm.Notes | ConvertFrom-Json -ErrorAction Stop } else { $null }
            if ($note -and $note.domain -ieq $Domain -and $note.domainNetBiosName) {
                $candidate = "$($note.domainNetBiosName)".Trim()
            }
        }
        catch { }
    }
    if (-not $candidate) { return $null }
    if ($candidate.Length -gt 15 -or $candidate -match '[\\/:*?"<>|]') {
        throw "Invalid NetBIOS domain name '$candidate' for '$Domain'."
    }
    return $candidate
}

function New-DomainCredentials {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'MemLabs already stores this deployment credential as plaintext in its local ignored cache; this process-local PSCredential is required for PowerShell Direct.')]
    param(
        [string] $Domain,
        [string] $AdminName,
        [string] $AdminCachePath,
        [string] $DomainNetBiosName,
        [string] $VmName
    )

    if (-not (Test-Path -LiteralPath $AdminCachePath -PathType Leaf)) {
        throw "Cached VM credential not found: $AdminCachePath"
    }
    $password = (Get-Content -LiteralPath $AdminCachePath -Raw -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($password)) { throw "Cached VM credential is empty: $AdminCachePath" }
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credentials = [System.Collections.Generic.List[Management.Automation.PSCredential]]::new()
    $credentials.Add([Management.Automation.PSCredential]::new("$AdminName@$Domain", $securePassword))
    $netBiosName = Resolve-CrossRevisionDomainNetBiosName -Domain $Domain `
        -DomainNetBiosName $DomainNetBiosName -VmName $VmName
    if ($netBiosName) {
        $credentials.Add([Management.Automation.PSCredential]::new("$netBiosName\$AdminName", $securePassword))
    }
    return $credentials.ToArray()
}

function New-DomainCredential {
    param([string] $Domain, [string] $AdminName, [string] $AdminCachePath)

    return @(New-DomainCredentials -Domain $Domain -AdminName $AdminName -AdminCachePath $AdminCachePath)[0]
}

function Invoke-CrossRevisionDomainProbe {
    param(
        [string] $VmName,
        [Management.Automation.PSCredential[]] $Credentials,
        [string] $ExpectedDomain,
        [string] $ExpectedUser,
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($credential in @($Credentials)) {
        try {
            $values = @(Invoke-Command -VMName $VmName -Credential $credential `
                    -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop)
            if ($values.Count -ne 1) {
                throw "Probe returned $($values.Count) value(s); expected exactly one."
            }
            $value = $values[0]
            $identity = "$($value._MemLabsIdentity)"
            $userDnsDomain = "$($value._MemLabsUserDnsDomain)"
            $userName = "$($value._MemLabsUserName)"
            if (-not $identity -or $userDnsDomain -ine $ExpectedDomain -or $userName -ine $ExpectedUser) {
                throw "Identity mismatch: expected $ExpectedUser@$ExpectedDomain, actual $identity (USERDNSDOMAIN=$userDnsDomain)."
            }
            return $value
        }
        catch {
            $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
            $errors.Add("$($credential.UserName): $message")
        }
    }
    throw "PowerShell Direct domain probe failed for '$VmName' using [$(@($Credentials.UserName) -join ', ')]: $($errors -join '; ')"
}

function Get-DomainIdentity {
    param([object] $Config, [string] $AdminCachePath)

    $dc = @($Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1)
    if ($dc.Count -ne 1) { throw 'The main baseline must contain one DC to capture the AD domain SID.' }

    $domain = [string]$Config.vmOptions.domainName
    $adminName = [string]$Config.vmOptions.adminName
    $dcVmName = Get-FullVmName -Prefix ([string]$Config.vmOptions.prefix) -VmName ([string]$dc[0].vmName)
    $domainNetBiosName = Resolve-CrossRevisionDomainNetBiosName -Domain $domain `
        -DomainNetBiosName ([string]$Config.vmOptions.domainNetBiosName) -VmName $dcVmName
    $credentials = @(New-DomainCredentials -Domain $domain -AdminName $adminName -AdminCachePath $AdminCachePath `
            -DomainNetBiosName $domainNetBiosName -VmName $dcVmName)
    $domainProbe = Invoke-CrossRevisionDomainProbe -VmName $dcVmName -Credentials $credentials `
        -ExpectedDomain $domain -ExpectedUser $adminName -ScriptBlock {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        [pscustomobject]@{
            DomainSid                 = (Get-ADDomain -ErrorAction Stop).DomainSID.Value
            _MemLabsIdentity          = $identity
            _MemLabsUserDnsDomain     = "$env:USERDNSDOMAIN"
            _MemLabsUserName          = if ($identity -match '\\([^\\]+)$') { $Matches[1] } else { "$env:USERNAME" }
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$domainProbe.DomainSid)) {
        throw "The domain SID probe returned an empty SID from '$dcVmName'."
    }
    return [ordered]@{
        Domain            = $domain
        DomainNetBiosName = $domainNetBiosName
        AdminName         = $adminName
        DcVmName          = $dcVmName
        Sid               = "$($domainProbe.DomainSid)"
    }
}

function Assert-DomainJoinedVmHealth {
    param([object] $Config, [string] $FixtureName, [string] $AdminCachePath)

    $domainJoinedRoles = @('DomainMember', 'FileServer', 'PassiveSite', 'Primary', 'Secondary', 'SiteSystem', 'SQLAO', 'WSUS')
    $domain = [string]$Config.vmOptions.domainName
    $domainNetBiosName = [string]$Config.vmOptions.domainNetBiosName
    $adminName = [string]$Config.vmOptions.adminName
    $prefix = [string]$Config.vmOptions.prefix

    foreach ($vmConfig in @($Config.virtualMachines | Where-Object { $_.role -in $domainJoinedRoles })) {
        $vmName = Get-FullVmName -Prefix $prefix -VmName ([string]$vmConfig.vmName)
        $credentials = @(New-DomainCredentials -Domain $domain -AdminName $adminName -AdminCachePath $AdminCachePath `
                -DomainNetBiosName $domainNetBiosName -VmName $vmName)
        $health = Invoke-CrossRevisionDomainProbe -VmName $vmName -Credentials $credentials `
            -ExpectedDomain $domain -ExpectedUser $adminName -ScriptBlock {
            param($ExpectedDomain)
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $secureChannel = Test-ComputerSecureChannel -ErrorAction Stop
            $fqdn = "$env:COMPUTERNAME.$ExpectedDomain"
            $dnsAddresses = @(Resolve-DnsName -Name $fqdn -Type A -ErrorAction Stop |
                    Where-Object { $_.IPAddress } |
                    Select-Object -ExpandProperty IPAddress -Unique)
            [pscustomobject]@{
                PartOfDomain              = [bool]$computerSystem.PartOfDomain
                Domain                    = [string]$computerSystem.Domain
                SecureChannel             = [bool]$secureChannel
                DnsAddresses              = @($dnsAddresses)
                _MemLabsIdentity          = $identity
                _MemLabsUserDnsDomain     = "$env:USERDNSDOMAIN"
                _MemLabsUserName          = if ($identity -match '\\([^\\]+)$') { $Matches[1] } else { "$env:USERNAME" }
            }
        } -ArgumentList $domain
        if (-not $health.PartOfDomain -or $health.Domain -ine $domain) {
            throw "$FixtureName left '$vmName' outside '$domain' (PartOfDomain=$($health.PartOfDomain), Domain=$($health.Domain))."
        }
        if (-not $health.SecureChannel) {
            throw "$FixtureName left '$vmName' with a broken secure channel to '$domain'."
        }
        if (@($health.DnsAddresses | Where-Object { $null -ne $_ }).Count -eq 0) {
            throw "$FixtureName left '$vmName' without an A record for '$vmName.$domain'."
        }
    }
}

function Assert-DomainIdentity {
    param([object] $Identity, [string] $AdminCachePath)

    $config = [pscustomobject]@{
        vmOptions       = [pscustomobject]@{
            domainName = $Identity.Domain
            domainNetBiosName = $Identity.DomainNetBiosName
            adminName = $Identity.AdminName
            prefix = ''
        }
        virtualMachines = @([pscustomobject]@{ role = 'DC'; vmName = $Identity.DcVmName })
    }
    $vm = Get-VM -Name $Identity.DcVmName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "Domain controller '$($Identity.DcVmName)' disappeared during expansion." }
    $actual = Get-DomainIdentity -Config $config -AdminCachePath $AdminCachePath
    if ($actual.Sid -ne $Identity.Sid) {
        throw "Domain '$($Identity.Domain)' was replaced: expected SID $($Identity.Sid), found $($actual.Sid)."
    }
}

function Assert-DevelopStageComplete {
    param([object] $Config, [string] $FixtureName)

    $prefix = [string]$Config.vmOptions.prefix
    foreach ($vmConfig in @($Config.virtualMachines)) {
        $vmName = Get-FullVmName -Prefix $prefix -VmName ([string]$vmConfig.vmName)
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { throw "$FixtureName completed but expected VM '$vmName' does not exist." }
        try { $note = $vm.Notes | ConvertFrom-Json } catch { throw "$FixtureName produced unreadable VM notes on '$vmName'." }
        $successIsTrue = $note.PSObject.Properties['success'] -and $note.success -is [bool] -and $note.success
        $inProgressIsFalse = $note.PSObject.Properties['inProgress'] -and $note.inProgress -is [bool] -and -not $note.inProgress
        if (-not $successIsTrue -or -not $inProgressIsFalse) {
            throw "$FixtureName left '$vmName' incomplete (success=$($note.success), inProgress=$($note.inProgress))."
        }

        if ($vmConfig.role -eq 'OSDClient') {
            continue
        }
        if ($vmConfig.role -eq 'AADClient') {
            if ($note.oobeComplete -isnot [bool] -or -not $note.oobeComplete) {
                throw "$FixtureName left AAD client '$vmName' without oobeComplete=true."
            }
            continue
        }
        if (-not $note.lastPhaseComplete -or [int]$note.lastPhaseComplete -lt 11) {
            throw "$FixtureName left '$vmName' below phase 11 (lastPhaseComplete=$($note.lastPhaseComplete))."
        }
    }
}

function ConvertTo-CrossRevisionNormalizedPath {
    param([string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = "\\$($fullPath.Substring(8))"
    }
    elseif ($fullPath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.Substring(4)
    }
    return $fullPath.TrimEnd('\')
}

function Assert-CrossRevisionPathLayout {
    param(
        [string] $Repository,
        [string] $Root
    )

    $repositoryPath = ConvertTo-CrossRevisionNormalizedPath -Path $Repository
    $statePath = ConvertTo-CrossRevisionNormalizedPath -Path $Root
    if ($statePath -ieq $repositoryPath -or
        $statePath.StartsWith("$repositoryPath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "StateRoot '$statePath' cannot be inside the source repository '$repositoryPath'."
    }

    $existingPath = $statePath
    while (-not (Test-Path -LiteralPath $existingPath)) {
        $parent = Split-Path -Parent $existingPath
        if (-not $parent -or $parent -eq $existingPath) { break }
        $existingPath = $parent
    }
    while ($existingPath -and (Test-Path -LiteralPath $existingPath)) {
        $item = Get-Item -LiteralPath $existingPath -Force -ErrorAction Stop
        if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
            throw "StateRoot '$statePath' cannot traverse reparse point '$($item.FullName)'."
        }
        $parent = Split-Path -Parent $existingPath
        if (-not $parent -or $parent -eq $existingPath) { break }
        $existingPath = $parent
    }
}

function Initialize-WorktreeLogPath {
    param([string] $WorktreePath)

    $worktreeName = Split-Path -Leaf $WorktreePath
    $sourceLogs = Join-Path $RepositoryRoot "vmbuild\logs\CrossRevision\$worktreeName"
    $targetLogs = Join-Path $WorktreePath 'vmbuild\logs'
    $backupRoot = Join-Path $StateRoot 'worktree-log-backups'
    $null = New-Item -ItemType Directory -Path $sourceLogs -Force -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $targetLogs)) {
        $null = New-Item -ItemType Junction -Path $targetLogs -Target $sourceLogs -ErrorAction Stop
        return
    }

    $logItem = Get-Item -LiteralPath $targetLogs -Force -ErrorAction Stop
    if ($logItem.LinkType -in @('Junction', 'SymbolicLink')) {
        $targets = @($logItem.Target | Where-Object { $null -ne $_ })
        if ($targets.Count -ne 1) {
            throw "Pinned worktree log path '$targetLogs' is not a single junction/symbolic link."
        }
        $actualTarget = [string]$targets[0]
        if (-not [IO.Path]::IsPathRooted($actualTarget)) {
            $actualTarget = Join-Path $logItem.Parent.FullName $actualTarget
        }
        $actualTarget = [IO.Path]::GetFullPath($actualTarget).TrimEnd('\')
        $expectedTarget = [IO.Path]::GetFullPath($sourceLogs).TrimEnd('\')
        if ($actualTarget -ine $expectedTarget) {
            throw "Pinned worktree log link '$targetLogs' targets '$actualTarget', expected '$expectedTarget'. Remove the stale worktree before retrying."
        }
        return
    }
    if (-not $logItem.PSIsContainer) {
        throw "Pinned worktree log path '$targetLogs' is not a directory or supported link."
    }

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $backupPath = Join-Path $backupRoot "$worktreeName-$timestamp"
    $entries = @(Get-ChildItem -LiteralPath $targetLogs -Force -ErrorAction Stop)
    if ($entries.Count -gt 0) {
        foreach ($entry in $entries) {
            Copy-Item -LiteralPath $entry.FullName -Destination $sourceLogs -Recurse -Force -ErrorAction Stop
        }
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $targetLogs -Recurse -File -Force)) {
            $relativePath = $sourceFile.FullName.Substring($targetLogs.Length).TrimStart('\')
            $recoveredFile = Join-Path $sourceLogs $relativePath
            if (-not (Test-Path -LiteralPath $recoveredFile -PathType Leaf) -or
                (Get-Item -LiteralPath $recoveredFile -Force).Length -ne $sourceFile.Length) {
                throw "Could not verify recovered mixed-test log '$relativePath' in '$sourceLogs'."
            }
        }
    }

    Move-Item -LiteralPath $targetLogs -Destination $backupPath -ErrorAction Stop
    try {
        $null = New-Item -ItemType Junction -Path $targetLogs -Target $sourceLogs -ErrorAction Stop
    }
    catch {
        $junctionError = $_
        $rollbackError = $null
        if (Test-Path -LiteralPath $targetLogs) {
            $rollbackError = "the failed junction operation left '$targetLogs' occupied"
        }
        elseif (Test-Path -LiteralPath $backupPath) {
            try {
                Move-Item -LiteralPath $backupPath -Destination $targetLogs -ErrorAction Stop
            }
            catch {
                $rollbackError = $_.Exception.Message
            }
        }
        if ($rollbackError) {
            throw "Could not create mixed-test log junction '$targetLogs': $($junctionError.Exception.Message) Rollback also failed ($rollbackError). Original logs remain at '$backupPath'."
        }
        throw $junctionError
    }
    if ($entries.Count -gt 0) {
        Write-Host "Moved existing mixed-test logs into '$sourceLogs'; backup retained at '$backupPath'." -ForegroundColor Yellow
    }
}

function Initialize-ExistingCrossRevisionLogPaths {
    param([string] $WorktreeRoot)

    if (-not (Test-Path -LiteralPath $WorktreeRoot -PathType Container)) { return }
    foreach ($worktree in @(Get-ChildItem -LiteralPath $WorktreeRoot -Directory -Force -ErrorAction Stop)) {
        if (Test-Path -LiteralPath (Join-Path $worktree.FullName 'vmbuild') -PathType Container) {
            Initialize-WorktreeLogPath -WorktreePath $worktree.FullName
        }
    }
}

function Initialize-PinnedWorktree {
    param(
        [string] $Path,
        [string] $Commit,
        [string] $BranchName
    )

    if (Test-Path -LiteralPath $Path) {
        $existingCommit = @(& git -C $Path rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or $existingCommit.Count -ne 1 -or $existingCommit[0].Trim() -ne $Commit) {
            throw "Existing worktree '$Path' is not pinned to $Commit. Remove or rename it before retrying."
        }
    }
    else {
        $parent = Split-Path -Parent $Path
        $null = New-Item -ItemType Directory -Path $parent -Force
        if ($BranchName) {
            $branchExists = $false
            & git -C $RepositoryRoot show-ref --verify --quiet "refs/heads/$BranchName"
            $branchExists = $LASTEXITCODE -eq 0
            if ($branchExists) {
                $null = Invoke-Git -Arguments @('worktree', 'add', $Path, $BranchName)
            }
            else {
                $null = Invoke-Git -Arguments @('worktree', 'add', '-b', $BranchName, $Path, $Commit)
            }
        }
        else {
            $null = Invoke-Git -Arguments @('worktree', 'add', '--detach', $Path, $Commit)
        }
    }

    $actualCommit = @(& git -C $Path rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $actualCommit.Count -ne 1 -or $actualCommit[0].Trim() -ne $Commit) {
        throw "Worktree '$Path' resolved to '$($actualCommit -join '')', expected $Commit."
    }
    if ($BranchName) {
        $actualBranch = @(& git -C $Path branch --show-current 2>$null)
        if ($LASTEXITCODE -ne 0 -or $actualBranch.Count -ne 1 -or $actualBranch[0].Trim() -ne $BranchName) {
            throw "Worktree '$Path' is on branch '$($actualBranch -join '')', expected '$BranchName'. Remove the stale worktree before retrying."
        }
    }

    $untrackedMode = if ($RequireCleanSource) { 'all' } else { 'no' }
    $worktreeChanges = @(& git -C $Path status --porcelain "--untracked-files=$untrackedMode")
    if ($LASTEXITCODE -ne 0 -or $worktreeChanges.Count -gt 0) {
        $scope = if ($RequireCleanSource) { 'tracked or untracked' } else { 'tracked' }
        throw "Pinned worktree '$Path' has $scope changes and cannot be used for this release test."
    }
}

function Publish-CrossRevisionSshCacheFromWorktree {
    param([Parameter(Mandatory = $true)][string] $WorktreePath)

    $sourceSsh = Join-Path (Join-Path (Join-Path $RepositoryRoot 'vmbuild') 'cache') 'ssh'
    $worktreeSsh = Join-Path (Join-Path (Join-Path $WorktreePath 'vmbuild') 'cache') 'ssh'
    if (-not (Test-Path -LiteralPath $worktreeSsh -PathType Container)) { return $false }
    $worktreeItem = Get-Item -LiteralPath $worktreeSsh -Force -ErrorAction Stop
    if ($worktreeItem.LinkType -in @('Junction', 'SymbolicLink')) { return $false }

    $sourcePrivate = Join-Path $sourceSsh 'memlabs_ed25519'
    $sourcePublic = "$sourcePrivate.pub"
    $worktreePrivate = Join-Path $worktreeSsh 'memlabs_ed25519'
    $worktreePublic = "$worktreePrivate.pub"
    if (-not (Test-Path -LiteralPath $worktreePrivate -PathType Leaf) -or
        -not (Test-Path -LiteralPath $worktreePublic -PathType Leaf)) {
        return $false
    }

    $null = New-Item -ItemType Directory -Path $sourceSsh -Force -ErrorAction Stop
    Copy-Item -LiteralPath $worktreePrivate -Destination $sourcePrivate -Force -ErrorAction Stop
    Copy-Item -LiteralPath $worktreePublic -Destination $sourcePublic -Force -ErrorAction Stop
    Write-Host "Promoted the active mixed-test SSH keypair from '$worktreeSsh' into the shared cache before revision migration." -ForegroundColor Yellow
    return $true
}

function Initialize-WorktreeSshCache {
    param([Parameter(Mandatory = $true)][string] $WorktreePath)

    $sourceSsh = Join-Path (Join-Path (Join-Path $RepositoryRoot 'vmbuild') 'cache') 'ssh'
    $targetSsh = Join-Path (Join-Path (Join-Path $WorktreePath 'vmbuild') 'cache') 'ssh'
    $null = New-Item -ItemType Directory -Path $sourceSsh -Force -ErrorAction Stop

    if (Test-Path -LiteralPath $targetSsh) {
        $targetItem = Get-Item -LiteralPath $targetSsh -Force -ErrorAction Stop
        $targets = @($targetItem.Target | Where-Object { $null -ne $_ })
        if ($targetItem.LinkType -in @('Junction', 'SymbolicLink')) {
            if ($targets.Count -ne 1) {
                throw "Pinned worktree SSH cache '$targetSsh' is not a single junction/symbolic link."
            }
            $actualTarget = [string]$targets[0]
            if (-not [IO.Path]::IsPathRooted($actualTarget)) {
                $actualTarget = Join-Path $targetItem.Parent.FullName $actualTarget
            }
            $actualTarget = [IO.Path]::GetFullPath($actualTarget).TrimEnd('\')
            $expectedTarget = [IO.Path]::GetFullPath($sourceSsh).TrimEnd('\')
            if ($actualTarget -ine $expectedTarget) {
                throw "Pinned worktree SSH cache '$targetSsh' targets '$actualTarget', expected '$expectedTarget'. Remove the stale worktree before retrying."
            }
            return
        }
        if (-not $targetItem.PSIsContainer) {
            throw "Pinned worktree SSH cache '$targetSsh' is not a directory or junction."
        }

        $sourcePrivate = Join-Path $sourceSsh 'memlabs_ed25519'
        $sourcePublic = "$sourcePrivate.pub"
        if ((-not (Test-Path -LiteralPath $sourcePrivate -PathType Leaf) -or
                -not (Test-Path -LiteralPath $sourcePublic -PathType Leaf))) {
            $null = Publish-CrossRevisionSshCacheFromWorktree -WorktreePath $WorktreePath
        }
        Remove-Item -LiteralPath $targetSsh -Recurse -Force -ErrorAction Stop
    }

    $null = New-Item -ItemType Junction -Path $targetSsh -Target $sourceSsh -ErrorAction Stop
}

function Initialize-WorktreeRuntime {
    param([string] $WorktreePath)

    $sourceVmbuild = Join-Path $RepositoryRoot 'vmbuild'
    $targetVmbuild = Join-Path $WorktreePath 'vmbuild'
    $sourceAssets = Join-Path $sourceVmbuild 'azureFiles'
    $targetAssets = Join-Path $targetVmbuild 'azureFiles'
    if (-not (Test-Path -LiteralPath $sourceAssets -PathType Container)) {
        throw "Shared media directory not found: $sourceAssets"
    }
    if (Test-Path -LiteralPath $targetAssets) {
        $assetLink = Get-Item -LiteralPath $targetAssets -Force -ErrorAction Stop
        $targets = @($assetLink.Target | Where-Object { $null -ne $_ })
        if ($assetLink.LinkType -notin @('Junction', 'SymbolicLink') -or $targets.Count -ne 1) {
            throw "Pinned worktree media path '$targetAssets' is not a single junction/symbolic link. Remove the stale worktree before retrying."
        }
        $actualTarget = [string]$targets[0]
        if (-not [IO.Path]::IsPathRooted($actualTarget)) {
            $actualTarget = Join-Path $assetLink.Parent.FullName $actualTarget
        }
        $actualTarget = [IO.Path]::GetFullPath($actualTarget).TrimEnd('\')
        $expectedTarget = [IO.Path]::GetFullPath($sourceAssets).TrimEnd('\')
        if ($actualTarget -ine $expectedTarget) {
            throw "Pinned worktree media link '$targetAssets' targets '$actualTarget', expected '$expectedTarget'. Remove the stale worktree before retrying."
        }
    }
    else {
        $null = New-Item -ItemType Junction -Path $targetAssets -Target $sourceAssets -ErrorAction Stop
    }

    Initialize-WorktreeLogPath -WorktreePath $WorktreePath

    $targetCache = Join-Path $targetVmbuild 'cache'
    $null = New-Item -ItemType Directory -Path $targetCache -Force
    $branchCache = Join-Path $targetCache 'git-branch-context.json'
    if (Test-Path -LiteralPath $branchCache) {
        Remove-Item -LiteralPath $branchCache -Force -ErrorAction Stop
    }
    foreach ($cacheItem in @('vmbuildadmin.txt', 'latest-hotfix-version.json', 'supported-options.json')) {
        $source = Join-Path (Join-Path $sourceVmbuild 'cache') $cacheItem
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $targetCache $cacheItem) -Force
        }
    }
    Initialize-WorktreeSshCache -WorktreePath $WorktreePath

    $targetConfig = Join-Path $targetVmbuild 'config'
    foreach ($storageConfig in @(Get-ChildItem (Join-Path $sourceVmbuild 'config') -Filter '_StorageConfig*.json' -File -Force)) {
        Copy-Item -LiteralPath $storageConfig.FullName -Destination (Join-Path $targetConfig $storageConfig.Name) -Force
    }
}

function Save-State {
    $script:State.LastUpdateUtc = [DateTime]::UtcNow.ToString('o')
    $tempPath = "$script:StatePath.$PID.tmp"
    $json = $script:State | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Test-StepComplete {
    param([string] $Step)
    return @($script:State.CompletedSteps) -contains $Step
}

function Test-StepInProgress {
    param([string] $Step)
    return $script:State.CurrentStep -eq $Step
}

function Start-Step {
    param([string] $Step)
    $script:State.Status = 'Running'
    $script:State.CurrentStep = $Step
    $script:State.LastError = $null
    $script:State['Interrupted'] = $false
    Save-State
}

function Complete-Step {
    param([string] $Step)
    $script:State.CompletedSteps = @($script:State.CompletedSteps) + $Step
    $script:State.CompletedSteps = @($script:State.CompletedSteps | Select-Object -Unique)
    $script:State.CurrentStep = $null
    Save-State
}

function Stop-CrossRevisionLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string] $IdentityPath,
        [Parameter(Mandatory = $true)]
        [string] $InvocationToken
    )

    $identity = Get-Content -LiteralPath $IdentityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ("$($identity.InvocationToken)" -ne $InvocationToken) {
        throw "Cancellation identity token mismatch for '$IdentityPath'; refusing to terminate PID $($identity.ProcessId)."
    }
    $processId = [int]$identity.ProcessId
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    try {
        # Force one stable OS process handle now. All verification, termination,
        # and waiting below stays bound to this handle even if the numeric PID is
        # recycled after the launcher exits.
        $null = $process.Handle
        $expectedStart = [DateTime]::Parse("$($identity.StartTimeUtc)").ToUniversalTime()
        if ($process.StartTime.ToUniversalTime() -ne $expectedStart) {
            throw "PID $processId start time changed; refusing to terminate a reused process ID."
        }

        $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$processId" -ErrorAction Stop
        if (-not $cim) {
            if ($process.HasExited) { return }
            throw "Could not verify the command line for active cross-revision launcher PID $processId."
        }
        if ("$($cim.CommandLine)" -notlike "*$InvocationToken*") {
            throw "PID $processId no longer belongs to cross-revision invocation $InvocationToken; refusing to terminate it."
        }

        $process.Kill()
        if (-not $process.WaitForExit(15000)) {
            throw "Cross-revision launcher PID $processId did not exit within 15 seconds after cancellation."
        }
    }
    finally {
        $process.Dispose()
    }
}

function Set-CrossRevisionCanonicalVmBuildShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,
        [string] $ShortcutPath
    )

    $vmbuildPath = Join-Path $RepositoryRoot 'vmbuild'
    $launcherPath = Join-Path $vmbuildPath 'VMBuild.cmd'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "Canonical VMBuild launcher not found: $launcherPath"
    }

    if (-not $ShortcutPath) {
        $desktopPath = [Environment]::GetFolderPath('CommonDesktop')
        if ([string]::IsNullOrWhiteSpace($desktopPath)) {
            throw 'The common desktop path is unavailable.'
        }
        $ShortcutPath = Join-Path $desktopPath 'MEMLABS - VMBuild.lnk'
    }

    $shortcutDirectory = Split-Path -Parent $ShortcutPath
    if ($shortcutDirectory -and -not (Test-Path -LiteralPath $shortcutDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $shortcutDirectory -Force -ErrorAction Stop
    }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $launcherPath
        $shortcut.WorkingDirectory = $vmbuildPath
        $shortcut.IconLocation = '%SystemRoot%\System32\SHELL32.dll,208'
        $shortcut.Save()
    }
    finally {
        if ($shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    $bytes = [IO.File]::ReadAllBytes($ShortcutPath)
    if ($bytes.Length -le 0x15) {
        throw "VMBuild shortcut is unexpectedly short after creation: $ShortcutPath"
    }
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($ShortcutPath, $bytes)
}

function Invoke-ChildScript {
    param(
        [string] $WorktreePath,
        [string] $ScriptName,
        [Collections.IDictionary] $Parameters,
        [string] $Label
    )

    $vmbuildPath = Join-Path $WorktreePath 'vmbuild'
    $scriptPath = Join-Path $vmbuildPath $ScriptName
    if (-not (Test-Path -LiteralPath $script:ChildLauncherPath -PathType Leaf)) {
        throw "Pinned child-script launcher not found: $script:ChildLauncherPath"
    }
    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $sharedLogRoot = Join-Path $RepositoryRoot 'vmbuild\logs\CrossRevision\Runner'
    $null = New-Item -ItemType Directory -Path $StateRoot -Force -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path $sharedLogRoot -Force -ErrorAction Stop
    $logPath = Join-Path $sharedLogRoot "$safeLabel.log"
    $stream = $null
    try {
        $stream = [IO.File]::Open($logPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $null = $stream.Seek(0, [IO.SeekOrigin]::End)
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    $parameterPath = Join-Path $StateRoot ('.child-parameters-{0}-{1}.clixml' -f $PID, [guid]::NewGuid().ToString('N'))
    $pidPath = Join-Path $StateRoot ('.child-pid-{0}-{1}.txt' -f $PID, [guid]::NewGuid().ToString('N'))
    $resultPath = Join-Path $StateRoot ('.child-result-{0}-{1}.json' -f $PID, [guid]::NewGuid().ToString('N'))
    $invocationToken = [guid]::NewGuid().ToString('N')
    $childInvocationCompleted = $false
    $script:LastChildResult = $null
    Write-Host "===== $Label =====" -ForegroundColor Magenta
    Push-Location $vmbuildPath
    try {
        $Parameters | Export-Clixml -LiteralPath $parameterPath -Depth 4 -ErrorAction Stop
        $global:LASTEXITCODE = 0
        $hadNativePreference = $null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue)
        if ($hadNativePreference) { $oldNativePreference = $PSNativeCommandUseErrorActionPreference }
        $canonicalRootVariable = 'MEMLABS_CANONICAL_REPOSITORY_ROOT'
        $priorCanonicalRoot = [Environment]::GetEnvironmentVariable($canonicalRootVariable, 'Process')
        try {
            if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
            [Environment]::SetEnvironmentVariable($canonicalRootVariable, $RepositoryRoot, 'Process')
            & $pwshPath -NoLogo -NoProfile -NonInteractive -File $script:ChildLauncherPath `
                -ScriptPath $scriptPath -ParameterPath $parameterPath -PidPath $pidPath `
                -InvocationToken $invocationToken -ResultPath $resultPath 2>&1 |
                Tee-Object -FilePath $logPath -Append -ErrorAction Stop |
                Out-Host
            $childExitCode = [int]$LASTEXITCODE
            $childInvocationCompleted = $true
        }
        finally {
            [Environment]::SetEnvironmentVariable($canonicalRootVariable, $priorCanonicalRoot, 'Process')
            if ($hadNativePreference) { $PSNativeCommandUseErrorActionPreference = $oldNativePreference }
        }
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            throw "Mixed-test transcript verification failed for '$logPath'."
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Pinned child did not publish its structured result: $resultPath"
        }
        $childResult = Get-Content -LiteralPath $resultPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ("$($childResult.InvocationToken)" -ne $invocationToken) {
            throw "Pinned child result token does not match invocation '$invocationToken'."
        }
        if ([int]$childResult.ExitCode -ne $childExitCode) {
            throw "Pinned child result exit code $($childResult.ExitCode) does not match process exit code $childExitCode."
        }
        $script:LastChildResult = $childResult
        return $childExitCode
    }
    finally {
        if (-not $childInvocationCompleted -and (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
            Stop-CrossRevisionLauncher -IdentityPath $pidPath -InvocationToken $invocationToken
        }
        Remove-Item -LiteralPath $parameterPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
        Pop-Location
        try {
            Set-CrossRevisionCanonicalVmBuildShortcut -RepositoryRoot $RepositoryRoot
        }
        catch {
            Write-Host "WARNING: Could not restore the canonical VMBuild desktop shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Invoke-NewLabFixture {
    param(
        [string] $WorktreePath,
        [string] $FixturePath,
        [string] $Label,
        [switch] $KeepFailedVms
    )

    $parameters = [ordered]@{
        Configuration  = $FixturePath
        NoSnapshot     = $true
        NoWindowResize = $true
    }
    if ($KeepFailedVms.IsPresent) { $parameters.KeepFailedVMs = $true }
    $exitCode = Invoke-ChildScript -WorktreePath $WorktreePath -ScriptName 'New-Lab.ps1' -Parameters $parameters -Label $Label
    if ($exitCode -eq 55) {
        Write-Host "$Label requested one restart after rebuilding DSC.zip; rerunning." -ForegroundColor Yellow
        $exitCode = Invoke-ChildScript -WorktreePath $WorktreePath -ScriptName 'New-Lab.ps1' -Parameters $parameters -Label "$Label-restart"
    }
    $resumeInfo = if ($script:LastChildResult) { $script:LastChildResult.ResumeInfo } else { $null }
    if ($exitCode -ne 0 -and $resumeInfo -and [int]$resumeInfo.Phase -gt 0) {
        $resumeParameters = [ordered]@{}
        foreach ($key in $parameters.Keys) { $resumeParameters[$key] = $parameters[$key] }
        $resumeParameters.StartPhase = [int]$resumeInfo.Phase
        if ([bool]$resumeInfo.Restore) { $resumeParameters.Restore = $true }
        $resumeLabel = "$Label-resume-phase$($resumeInfo.Phase)"
        Write-Host "$Label failed; automatically resuming once at Phase $($resumeInfo.Phase). Phase 0 will reboot only VMs that prove they need it." -ForegroundColor Cyan
        $exitCode = Invoke-ChildScript -WorktreePath $WorktreePath -ScriptName 'New-Lab.ps1' `
            -Parameters $resumeParameters -Label $resumeLabel
        if ($exitCode -eq 55) {
            Write-Host "$resumeLabel requested one restart after rebuilding DSC.zip; rerunning." -ForegroundColor Yellow
            $exitCode = Invoke-ChildScript -WorktreePath $WorktreePath -ScriptName 'New-Lab.ps1' `
                -Parameters $resumeParameters -Label "$resumeLabel-restart"
        }
    }
    return $exitCode
}

function Get-ExistingVmMutationOutputPath {
    param(
        [string] $Family,
        [string] $FixtureName,
        [string] $MainCommit,
        [string] $DevelopCommit
    )

    $pairName = "$($MainCommit.Substring(0, 8))-to-$($DevelopCommit.Substring(0, 8))"
    $safeFamily = $Family -replace '[^A-Za-z0-9_.-]', '_'
    $safeFixture = ([IO.Path]::GetFileNameWithoutExtension($FixtureName)) -replace '[^A-Za-z0-9_.-]', '_'
    $outputDirectory = Join-Path $StateRoot "generated-mutations\$pairName\$safeFamily"
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction Stop
    return Join-Path $outputDirectory "$safeFixture.json"
}

function Invoke-ExistingVmMutationMaterializer {
    param(
        [string] $WorktreePath,
        [string] $ManifestPath,
        [string] $OutputPath,
        [string] $Label
    )

    $exitCode = Invoke-ChildScript -WorktreePath $WorktreePath `
        -ScriptName 'tools\New-ExistingVmMutationConfig.ps1' `
        -Parameters ([ordered]@{ ManifestPath = $ManifestPath; OutputPath = $OutputPath }) `
        -Label $Label
    if ($exitCode -ne 0) {
        throw "Existing-VM mutation materialization failed with exit code $exitCode."
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Existing-VM mutation materializer did not create '$OutputPath'."
    }
}

function Assert-DomainsAbsent {
    param([string[]] $Domains, [string[]] $VmNames)

    $existing = @(Get-DomainVms -Domains $Domains)
    $existing += @(Get-ExistingNamedVms -VmNames $VmNames)
    $existing = @($existing | Sort-Object Name -Unique)
    if ($existing.Count -gt 0) {
        throw "Cannot start a clean main baseline; planned domain VM(s) already exist: $($existing.Name -join ', ')."
    }
}

function Assert-MainBaselineCanStart {
    param([object] $Config, [string[]] $Domains, [bool] $WasStarted)

    if ($WasStarted) {
        throw 'The exact-main baseline mutation began but was not checkpointed complete. Automatic replay or adoption is unsafe because no pre-mutation VM/domain identity exists. Remove every VM and residual lab state for this family, then use -ResetState.'
    }
    Assert-DomainsAbsent -Domains $Domains -VmNames @(Get-ExpectedVmNames -Config $Config)
}

function Repair-InterruptedMainBaseline {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.IDictionary] $State,
        [Parameter(Mandatory = $true)]
        [object[]] $Plan,
        [Parameter(Mandatory = $true)]
        [string] $DevelopWorktree,
        [scriptblock] $CleanupInvoker = {
            param($WorktreePath, $Parameters, $Label)
            Invoke-ChildScript -WorktreePath $WorktreePath -ScriptName 'Remove-Lab.ps1' `
                -Parameters $Parameters -Label $Label
        }
    )

    $currentStep = [string]$State.CurrentStep
    if ([string]::IsNullOrWhiteSpace($currentStep)) { return $false }
    $parts = @($currentStep -split '\|')
    if ($parts.Count -ne 3 -or $parts[1] -ine 'main' -or $parts[2] -ine 'A') {
        return $false
    }

    $familyPlan = @($Plan | Where-Object { $_.Family -ieq $parts[0] })
    if ($familyPlan.Count -ne 1) {
        throw "Interrupted exact-main family '$($parts[0])' is not present exactly once in the current develop plan."
    }

    $family = [string]$familyPlan[0].Family
    $expectedVmNames = @(Get-ExpectedVmNames -Config $familyPlan[0].BaselineConfig)
    Write-Host "RECOVERY: '$family' exact-main baseline was interrupted. Cleaning its partial lab with current develop before restarting the family." -ForegroundColor Yellow

    foreach ($domain in @($familyPlan[0].Domains | Where-Object { $_ } | Select-Object -Unique)) {
        $exitCode = & $CleanupInvoker $DevelopWorktree `
            ([ordered]@{ DomainName = [string]$domain }) `
            "$family-recover-domain-$domain"
        if ($exitCode -ne 0) {
            throw "Interrupted exact-main recovery cleanup of '$domain' failed with exit code $exitCode."
        }
    }

    $namedSurvivors = @(Get-ExistingNamedVms -VmNames $expectedVmNames)
    foreach ($vm in $namedSurvivors) {
        $exitCode = & $CleanupInvoker $DevelopWorktree `
            ([ordered]@{ VmName = [string]$vm.Name }) `
            "$family-recover-vm-$($vm.Name)"
        if ($exitCode -ne 0) {
            throw "Interrupted exact-main recovery cleanup of VM '$($vm.Name)' failed with exit code $exitCode."
        }
    }

    # A VM removed by exact name may have been too incomplete for domain
    # discovery. Re-run domain cleanup so its folder, scope, switch, and NAT
    # receive the same idempotent cleanup as a normally attributed VM.
    foreach ($domain in @($familyPlan[0].Domains | Where-Object { $_ } | Select-Object -Unique)) {
        $exitCode = & $CleanupInvoker $DevelopWorktree `
            ([ordered]@{ DomainName = [string]$domain }) `
            "$family-recover-finalize-$domain"
        if ($exitCode -ne 0) {
            throw "Interrupted exact-main recovery finalization of '$domain' failed with exit code $exitCode."
        }
    }

    $remaining = @(Get-DomainVms -Domains @($familyPlan[0].Domains))
    $remaining += @(Get-ExistingNamedVms -VmNames $expectedVmNames)
    $remaining = @($remaining | Sort-Object Name -Unique)
    if ($remaining.Count -gt 0) {
        throw "Interrupted exact-main recovery left VM(s) registered: $($remaining.Name -join ', ')."
    }

    Reset-CrossRevisionFamilyState -State $State -Family $family
    $State.Status = 'Running'
    $State.LastError = $null
    $State['Interrupted'] = $false
    Write-Host "RECOVERY: '$family' partial baseline was removed and its family checkpoint was reset. Restarting from exact-main A." -ForegroundColor Yellow
    return $true
}

function Get-CrossRevisionAncestorProcessIds {
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId,
        [scriptblock] $ProcessResolver = {
            param($Id)
            Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
        }
    )

    $ancestorIds = [Collections.Generic.List[int]]::new()
    $seen = [Collections.Generic.HashSet[int]]::new()
    $currentId = $ProcessId
    while ($currentId -gt 0 -and $seen.Add($currentId)) {
        $ancestorIds.Add($currentId)
        $process = & $ProcessResolver $currentId
        if (-not $process) { break }
        $currentId = [int]$process.ParentProcessId
    }
    return @($ancestorIds)
}

function Assert-NoOtherMemLabsRunner {
    $ancestorIds = @(Get-CrossRevisionAncestorProcessIds -ProcessId $PID)
    $otherRunners = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop |
            Where-Object {
                $_.ProcessId -notin $ancestorIds -and
                $_.CommandLine -match '(?:Start-Test|New-Lab|Remove-Lab)\.ps1'
            })
    if ($otherRunners.Count -eq 0) { return }

    $details = @($otherRunners | ForEach-Object {
            "PID=$($_.ProcessId) started=$($_.CreationDate) command=$($_.CommandLine)"
        }) -join [Environment]::NewLine
    throw "Another MemLabs test/deployment process is active. Do not share Hyper-V infrastructure between test cycles.$([Environment]::NewLine)$details"
}

try {
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        throw "Repository root not found: $RepositoryRoot"
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git.exe was not found.' }
    Assert-CrossRevisionPathLayout -Repository $RepositoryRoot -Root $StateRoot

    if ($RecoverLogsOnly.IsPresent) {
        $script:MutationMutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
        try { $script:MutationMutexHeld = $script:MutationMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $script:MutationMutexHeld = $true }
        if (-not $script:MutationMutexHeld) {
            throw 'Another MemLabs test cycle owns the host mutation lock; recover logs after it stops.'
        }
        $null = New-Item -ItemType Directory -Path $StateRoot -Force -ErrorAction Stop
        Initialize-ExistingCrossRevisionLogPaths -WorktreeRoot (Join-Path $StateRoot 'worktrees')
        Write-Host "PASS: cross-revision logs now write under '$(Join-Path $RepositoryRoot 'vmbuild\logs\CrossRevision')'." -ForegroundColor Green
        exit 0
    }

    $mainCommit = Resolve-GitRevision -Revision $MainRevision
    $requestedDevelopCommit = Resolve-GitRevision -Revision $DevelopRevision
    $developCommit = $requestedDevelopCommit
    if ($mainCommit -eq $developCommit) { throw 'Main and develop resolved to the same commit.' }
    $testPrefixes = if ($PSCmdlet.ParameterSetName -eq 'Test') {
        @($Test)
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Tests') {
        @($TestsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    else {
        @()
    }
    $plan = @(Get-CrossRevisionPlan -MainCommit $mainCommit -DevelopCommit $developCommit `
            -TestPrefixes $testPrefixes -ExactTestNames:($PSCmdlet.ParameterSetName -eq 'Tests'))
    if ($plan.Count -eq 0) {
        $selection = if ($Test) { " matching '$Test'" } else { '' }
        throw "No main-A/develop-follow-on test families were found$selection."
    }
    if ($PSCmdlet.ParameterSetName -eq 'Tests') {
        $missingFamilies = @($testPrefixes | Where-Object { $_ -notin $plan.Family })
        if ($missingFamilies.Count -gt 0) {
            throw "Selected cross-revision family/families have no pinned main-A/develop-follow-on plan: $($missingFamilies -join ', ')."
        }
    }
    $resetFamily = $null
    if ($ResetState.IsPresent -and $Test) {
        $resetFamily = Resolve-CrossRevisionResetFamily -Plan $plan -TestPrefix $Test
    }

    if (-not $PlanOnly.IsPresent) {
        $script:MutationMutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
        try { $script:MutationMutexHeld = $script:MutationMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $script:MutationMutexHeld = $true }
        if (-not $script:MutationMutexHeld) {
            throw 'Another MemLabs test cycle owns the host mutation lock.'
        }
        Assert-NoOtherMemLabsRunner
    }

    $checkpointToAdvance = $null
    $checkpointState = $null
    $familyResetHandled = $false
    if (-not $PlanOnly.IsPresent) {
        $activeCheckpoint = Get-ActiveCrossRevisionCheckpoint -Root $StateRoot -MainCommit $mainCommit
        if ($activeCheckpoint) {
            $checkpointState = Get-Content -LiteralPath $activeCheckpoint.Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            $activeResetFamily = $resetFamily
            if ($ResetState.IsPresent -and -not $activeResetFamily) {
                $activeResetFamily = Resolve-CrossRevisionActiveResetFamily -Plan $plan -State $checkpointState
            }
            if ($ResetState.IsPresent -and $activeResetFamily) {
                Reset-CrossRevisionFamilyState -State $checkpointState -Family $activeResetFamily
                Write-CrossRevisionStateFile -Path $activeCheckpoint.Path -State $checkpointState
                $activeCheckpoint.CurrentStep = [string]$checkpointState.CurrentStep
                $familyResetHandled = $true
                Write-Host "RESET: cleared checkpoint state for family '$activeResetFamily' after its lab was deliberately removed; preserving other family progress." -ForegroundColor Yellow
            }
            elseif ($ResetState.IsPresent) {
                throw "Reset was requested, but the active checkpoint has no in-progress family. Omit -ResetState to resume; refusing to archive completed family progress."
            }
        }
        if ($activeCheckpoint) {
            $checkpointDevelopCommit = Resolve-GitRevision -Revision $activeCheckpoint.DevelopRevision
            $step = if ($activeCheckpoint.CurrentStep) { $activeCheckpoint.CurrentStep } else { '<between steps>' }
            if ($checkpointDevelopCommit -eq $requestedDevelopCommit) {
                Write-Host "RESUME: active checkpoint '$($activeCheckpoint.Path)' continues develop $developCommit at $step." -ForegroundColor Yellow
            }
            else {
                $checkpointToAdvance = $activeCheckpoint
                Write-Host "ROLLING RESUME: preserving the exact-main baseline while advancing develop $checkpointDevelopCommit -> $requestedDevelopCommit at $step." -ForegroundColor Yellow
            }
        }
    }
    if ($checkpointToAdvance) {
        Assert-CrossRevisionCheckpointCanAdvance -State $checkpointState -Plan $plan -NewDevelopCommit $developCommit
    }

    Write-CrossRevisionPlan -Plan $plan -MainCommit $mainCommit -DevelopCommit $developCommit
    if ($checkpointToAdvance) {
        Write-Host 'Qualification mode: rolling develop revisions (diagnostic burn-in; run one fresh pinned cycle for final release qualification).' -ForegroundColor Yellow
    }
    if ($PlanOnly.IsPresent) { exit 0 }

    $trackedChanges = @(Invoke-Git -Arguments @('status', '--porcelain', '--untracked-files=no'))
    if ($trackedChanges.Count -gt 0) {
        throw "The source worktree has tracked changes. Commit or remove them before running a pinned live cycle: $($trackedChanges -join '; ')"
    }

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'The Hyper-V PowerShell module is unavailable. Run the live cycle on a LabHost.'
    }
    # A host/process interruption can occur after ClusterV2 was hidden but before
    # the exact-main invocation's finally block ran. Restore by alias identity
    # before any resume path, including one that skips the completed main baseline.
    $null = Restore-ExactMainClusterAdapterCompatibility
    if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
        throw "PowerShell 7 executable not found: $pwshPath"
    }

    $null = New-Item -ItemType Directory -Path $StateRoot -Force -ErrorAction Stop
    $worktreeRoot = Join-Path $StateRoot 'worktrees'
    Initialize-ExistingCrossRevisionLogPaths -WorktreeRoot $worktreeRoot
    if ($checkpointToAdvance) {
        $previousDevelopWorktree = Join-Path $worktreeRoot "develop-$($checkpointDevelopCommit.Substring(0, 8))"
        $null = Publish-CrossRevisionSshCacheFromWorktree -WorktreePath $previousDevelopWorktree
        $migratedStatePath = Move-CrossRevisionCheckpoint -ActivePath $checkpointToAdvance.Path -State $checkpointState `
            -Root $StateRoot -MainCommit $mainCommit -NewDevelopCommit $developCommit
        Write-Host "ROLLING RESUME: checkpoint advanced to '$migratedStatePath'." -ForegroundColor Yellow
    }
    $shortMain = $mainCommit.Substring(0, 8)
    $shortDevelop = $developCommit.Substring(0, 8)
    $mainWorktree = Join-Path $worktreeRoot "main-$shortMain"
    $developWorktree = Join-Path $worktreeRoot "develop-$shortDevelop"
    $mainBranch = "memlabs-cross-main-$shortMain"
    $developBranch = "memlabs-cross-develop-$shortDevelop"

    Initialize-PinnedWorktree -Path $mainWorktree -Commit $mainCommit -BranchName $mainBranch
    Initialize-PinnedWorktree -Path $developWorktree -Commit $developCommit -BranchName $developBranch
    Initialize-WorktreeRuntime -WorktreePath $mainWorktree
    Initialize-WorktreeRuntime -WorktreePath $developWorktree

    $mainBranchActual = @(& git -C $mainWorktree branch --show-current)
    if ($LASTEXITCODE -ne 0 -or $mainBranchActual.Count -ne 1 -or $mainBranchActual[0].Trim() -ne $mainBranch) {
        throw "Main worktree branch '$($mainBranchActual -join '')' will not select main media metadata."
    }
    $developBranchActual = @(& git -C $developWorktree branch --show-current)
    if ($LASTEXITCODE -ne 0 -or $developBranchActual.Count -ne 1 -or $developBranchActual[0].Trim() -ne $developBranch) {
        throw "Develop worktree branch '$($developBranchActual -join '')' will not select develop media metadata."
    }

    $script:StatePath = Join-Path $StateRoot "state-$shortMain-to-$shortDevelop.json"
    if ($ResetState.IsPresent -and -not $familyResetHandled -and (Test-Path -LiteralPath $script:StatePath)) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
    if (Test-Path -LiteralPath $script:StatePath) {
        $script:State = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        $script:State = [ordered]@{
            SchemaVersion   = 2
            MainRevision    = $mainCommit
            DevelopRevision = $developCommit
            DevelopRevisionHistory = @([ordered]@{
                    Revision      = $developCommit
                    BeganUtc      = [DateTime]::UtcNow.ToString('o')
                    SupersededUtc = $null
                    LastError     = $null
                })
            QualificationMode = 'Pinned'
            StartedUtc      = [DateTime]::UtcNow.ToString('o')
            LastUpdateUtc   = $null
            Status          = 'Ready'
            CurrentStep     = $null
            LastError       = $null
            Interrupted     = $false
            CompletedSteps  = @()
            Baselines       = @{}
            DomainIdentities = @{}
            DevelopIdentities = @{}
            DevelopDomainIdentities = @{}
        }
        Save-State
    }
    if ($script:State.MainRevision -ne $mainCommit -or $script:State.DevelopRevision -ne $developCommit) {
        throw "State file '$script:StatePath' belongs to different revisions."
    }
    if (-not $script:State.Contains('DomainIdentities')) {
        $script:State.DomainIdentities = @{}
        Save-State
    }
    if (-not $script:State.Contains('DevelopIdentities')) {
        $script:State.DevelopIdentities = @{}
        $script:State.DevelopDomainIdentities = @{}
        Save-State
    }
    if (-not $script:State.Contains('DevelopRevisionHistory')) {
        $script:State.DevelopRevisionHistory = @([ordered]@{
                Revision      = $developCommit
                BeganUtc      = $script:State.StartedUtc
                SupersededUtc = $null
                LastError     = $null
            })
        $script:State.QualificationMode = 'Pinned'
        $script:State.SchemaVersion = 2
        Save-State
    }

    if (Repair-InterruptedMainBaseline -State $script:State -Plan $plan -DevelopWorktree $developWorktree) {
        Save-State
    }
    $plan = @(Get-OrderedCrossRevisionPlan -Plan $plan -CurrentStep ([string]$script:State.CurrentStep))

    $credentialPath = Join-Path $mainWorktree 'vmbuild\cache\vmbuildadmin.txt'

    foreach ($familyPlan in $plan) {
        $family = [string]$familyPlan.Family
        $familyKey = $family.ToLowerInvariant()
        $completeKey = "$familyKey|complete"
        if (Test-StepComplete -Step $completeKey) {
            Write-Host "SKIP: $family already completed for this revision pair." -ForegroundColor DarkGray
            continue
        }

        $familyMetadata = Get-MemLabsFamilyMetadata -VmbuildRoot (Split-Path -Parent $PSScriptRoot) `
            -Family $family -IncludeMutations
        $script:HistoryRun = [pscustomobject]@{
            RunId = [guid]::NewGuid().ToString('N')
            Family = $family
            CandidateKey = "CrossRevision|$family"
            StartedUtc = [DateTime]::UtcNow
            Completed = $false
            Metadata = $familyMetadata
        }
        Write-MemLabsTestHistoryEvent -Event ([pscustomobject]@{
                EventType = 'RunStarted'; RunId = $script:HistoryRun.RunId
                CandidateKey = $script:HistoryRun.CandidateKey; Mode = 'CrossRevision'
                Family = $family; Suite = 'Upgrade'
                StartedUtc = $script:HistoryRun.StartedUtc.ToString('o')
                Commit = $developCommit; MainRevision = $mainCommit
                Domains = @($familyMetadata.Domains); CoverageTags = @($familyMetadata.CoverageTags)
                RequiredMemoryGB = $familyMetadata.EstimatedRequiredGB
            })

        Write-Host "`n######## $family ########" -ForegroundColor Cyan
        $baselineStep = "$familyKey|main|A"
        if (-not (Test-StepComplete -Step $baselineStep)) {
            Assert-MainBaselineCanStart -Config $familyPlan.BaselineConfig -Domains $familyPlan.Domains `
                -WasStarted:(Test-StepInProgress -Step $baselineStep)
            Start-Step -Step $baselineStep
            $mainFixturePath = Join-Path $mainWorktree ($familyPlan.Baseline.Path -replace '/', '\')
            $script:MainBaselineFailureCleanupPossible = $true
            $clusterAliasHidden = $false
            try {
                $clusterAliasHidden = Enter-ExactMainClusterAdapterCompatibility
                $exitCode = Invoke-NewLabFixture -WorktreePath $mainWorktree -FixturePath $mainFixturePath -Label "$family-main-A"
            }
            finally {
                if ($clusterAliasHidden -or $script:ExactMainClusterAdapterCompatibilityActive) {
                    $null = Restore-ExactMainClusterAdapterCompatibility -BestEffort
                }
            }
            if ($exitCode -eq 0) { $script:MainBaselineFailureCleanupPossible = $false }
            if ($exitCode -ne 0) { throw "$family main baseline failed with exit code $exitCode." }
            $baselineNames = @(Get-ExpectedVmNames -Config $familyPlan.BaselineConfig)
            $script:State.Baselines[$familyKey] = @(Get-VmIdentity -VmNames $baselineNames)
            $script:State.DomainIdentities[$familyKey] = Get-DomainIdentity -Config $familyPlan.BaselineConfig -AdminCachePath $credentialPath
            Complete-Step -Step $baselineStep
        }

        $baselineIdentity = @($script:State.Baselines[$familyKey])
        if ($baselineIdentity.Count -eq 0) {
            throw "$family baseline is marked complete but has no saved identity. Use -ResetState after removing its lab."
        }
        $domainIdentity = $script:State.DomainIdentities[$familyKey]
        if (-not $domainIdentity) {
            throw "$family baseline is marked complete but has no saved domain SID. Use -ResetState after removing its lab."
        }

        $cleanupStarted = $script:State.CurrentStep -like "$familyKey|cleanup|*" -or
            @($script:State.CompletedSteps | Where-Object { $_ -like "$familyKey|cleanup|*" }).Count -gt 0
        if (-not $cleanupStarted) {
            Assert-BaselineIdentity -Identity $baselineIdentity
            Assert-DomainIdentity -Identity $domainIdentity -AdminCachePath $credentialPath
        }

        for ($pass = 1; $pass -le 2; $pass++) {
            foreach ($followOn in $familyPlan.FollowOns) {
                $step = "$familyKey|develop|$pass|$($followOn.Name)"
                $identityKey = "$familyKey|$($followOn.Name.ToLowerInvariant())"
                $followOnDefinition = Get-GitJson -Revision $developCommit -Path $followOn.Path
                $isExistingVmMutation = Test-ExistingVmMutationFixture -Config $followOnDefinition
                $fixturePath = Join-Path $developWorktree ($followOn.Path -replace '/', '\')
                if ($isExistingVmMutation) {
                    $fixturePath = Get-ExistingVmMutationOutputPath -Family $family -FixtureName $followOn.Name `
                        -MainCommit $mainCommit -DevelopCommit $developCommit
                }
                $followOnConfig = if ($isExistingVmMutation -and (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
                    Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                }
                else {
                    $followOnDefinition
                }
                $followOnVmNames = @(Get-ExpectedVmNames -Config $followOnConfig)
                $followOnHasDc = @($followOnConfig.virtualMachines | Where-Object { $_.role -eq 'DC' }).Count -gt 0
                if (Test-StepComplete -Step $step) {
                    Write-Host "SKIP: completed $step" -ForegroundColor DarkGray
                    if (-not $cleanupStarted) {
                        Assert-DevelopStageComplete -Config $followOnConfig -FixtureName $followOn.Name
                        Assert-DomainJoinedVmHealth -Config $followOnConfig -FixtureName $followOn.Name -AdminCachePath $credentialPath
                        $savedDevelopIdentity = @($script:State.DevelopIdentities[$identityKey])
                        if ($savedDevelopIdentity.Count -eq 0) {
                            throw "$($followOn.Name) is checkpointed complete without saved first-pass VM identity."
                        }
                        Assert-BaselineIdentity -Identity $savedDevelopIdentity
                        if ($followOnHasDc) {
                            $savedDevelopDomainIdentity = $script:State.DevelopDomainIdentities[$identityKey]
                            if (-not $savedDevelopDomainIdentity) {
                                throw "$($followOn.Name) is checkpointed complete without saved first-pass domain SID."
                            }
                            Assert-DomainIdentity -Identity $savedDevelopDomainIdentity -AdminCachePath $credentialPath
                        }
                    }
                    continue
                }
                if ($cleanupStarted) {
                    throw "$family cleanup was already started before all expansion stages completed. Remove the family labs and use -ResetState."
                }
                if ($pass -eq 2) {
                    $savedDevelopIdentity = @($script:State.DevelopIdentities[$identityKey])
                    if ($savedDevelopIdentity.Count -eq 0) {
                        throw "$($followOn.Name) has no first-pass VM identity for the idempotence check."
                    }
                    Assert-BaselineIdentity -Identity $savedDevelopIdentity
                    if ($followOnHasDc) {
                        $savedDevelopDomainIdentity = $script:State.DevelopDomainIdentities[$identityKey]
                        if (-not $savedDevelopDomainIdentity) {
                            throw "$($followOn.Name) has no first-pass domain SID for the idempotence check."
                        }
                        Assert-DomainIdentity -Identity $savedDevelopDomainIdentity -AdminCachePath $credentialPath
                    }
                }
                Start-Step -Step $step
                if ($isExistingVmMutation) {
                    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
                        $manifestPath = Join-Path $developWorktree ($followOn.Path -replace '/', '\')
                        Invoke-ExistingVmMutationMaterializer -WorktreePath $developWorktree `
                            -ManifestPath $manifestPath -OutputPath $fixturePath `
                            -Label "$family-materialize-$($followOn.Stage)"
                    }
                    $followOnConfig = Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $followOnVmNames = @(Get-ExpectedVmNames -Config $followOnConfig)
                    $followOnHasDc = @($followOnConfig.virtualMachines | Where-Object { $_.role -eq 'DC' }).Count -gt 0
                }
                $exitCode = Invoke-NewLabFixture -WorktreePath $developWorktree -FixturePath $fixturePath -Label "$family-develop-pass$pass-$($followOn.Stage)" -KeepFailedVms
                if ($exitCode -ne 0) { throw "$($followOn.Name) failed on develop pass $pass with exit code $exitCode." }
                Assert-BaselineIdentity -Identity $baselineIdentity
                Assert-DomainIdentity -Identity $domainIdentity -AdminCachePath $credentialPath
                Assert-DevelopStageComplete -Config $followOnConfig -FixtureName $followOn.Name
                Assert-DomainJoinedVmHealth -Config $followOnConfig -FixtureName $followOn.Name -AdminCachePath $credentialPath
                if ($pass -eq 1) {
                    $script:State.DevelopIdentities[$identityKey] = @(Get-VmIdentity -VmNames $followOnVmNames)
                    if ($followOnHasDc) {
                        $script:State.DevelopDomainIdentities[$identityKey] = Get-DomainIdentity -Config $followOnConfig -AdminCachePath $credentialPath
                    }
                }
                else {
                    Assert-BaselineIdentity -Identity @($script:State.DevelopIdentities[$identityKey])
                    if ($followOnHasDc) {
                        Assert-DomainIdentity -Identity $script:State.DevelopDomainIdentities[$identityKey] -AdminCachePath $credentialPath
                    }
                }
                Complete-Step -Step $step
            }
        }

        if (-not $cleanupStarted) {
            foreach ($followOn in $familyPlan.FollowOns) {
                $identityKey = "$familyKey|$($followOn.Name.ToLowerInvariant())"
                Assert-BaselineIdentity -Identity @($script:State.DevelopIdentities[$identityKey])
                if ($script:State.DevelopDomainIdentities[$identityKey]) {
                    Assert-DomainIdentity -Identity $script:State.DevelopDomainIdentities[$identityKey] -AdminCachePath $credentialPath
                }
            }
        }

        foreach ($domain in $familyPlan.Domains) {
            $cleanupStep = "$familyKey|cleanup|$($domain.ToLowerInvariant())"
            if (Test-StepComplete -Step $cleanupStep) { continue }
            Start-Step -Step $cleanupStep
            $exitCode = Invoke-ChildScript -WorktreePath $developWorktree -ScriptName 'Remove-Lab.ps1' `
                -Parameters ([ordered]@{ DomainName = $domain }) -Label "$family-cleanup-$domain"
            if ($exitCode -ne 0) { throw "Cleanup of $domain failed with exit code $exitCode." }
            $remaining = @(Get-DomainVms -Domains @($domain))
            $remaining += @(Get-ExistingNamedVms -VmNames @($familyPlan.VmNamesByDomain[$domain.ToLowerInvariant()]))
            $remaining = @($remaining | Sort-Object Name -Unique)
            if ($remaining.Count -gt 0) { throw "Cleanup of $domain left VM(s): $($remaining.Name -join ', ')." }
            Complete-Step -Step $cleanupStep
        }
        Complete-Step -Step $completeKey
        $familyCompletedUtc = [DateTime]::UtcNow
        Write-MemLabsTestHistoryEvent -Event ([pscustomobject]@{
                EventType = 'RunCompleted'; RunId = $script:HistoryRun.RunId
                CandidateKey = $script:HistoryRun.CandidateKey; Mode = 'CrossRevision'
                Family = $family; Suite = 'Upgrade'
                StartedUtc = $script:HistoryRun.StartedUtc.ToString('o')
                CompletedUtc = $familyCompletedUtc.ToString('o')
                DurationSeconds = [Math]::Round(($familyCompletedUtc - $script:HistoryRun.StartedUtc).TotalSeconds, 1)
                Commit = $developCommit; MainRevision = $mainCommit; Success = $true; ExitCode = 0
                Error = ''; Domains = @($script:HistoryRun.Metadata.Domains)
                CoverageTags = @($script:HistoryRun.Metadata.CoverageTags); NeedsRerun = $false
            })
        $script:HistoryRun.Completed = $true
        $script:HistoryRun = $null
        Write-Host "PASS: $family main-to-develop expansion cycle completed." -ForegroundColor Green

        if ($PauseAtFamilyBoundary.IsPresent) {
            $remainingFamilies = @($plan | Where-Object {
                    -not (Test-StepComplete -Step "$($_.Family.ToLowerInvariant())|complete")
                })
            if ($remainingFamilies.Count -gt 0) {
                $script:State.Status = 'Running'
                $script:State.CurrentStep = $null
                $script:State.LastError = $null
                Save-State
                Write-Host "FAMILY BOUNDARY: $family completed; returning to Start-Test so develop can refresh before $($remainingFamilies[0].Family)." -ForegroundColor Yellow
                exit 56
            }
        }
    }

    $script:State.Status = 'Passed'
    $script:State.CurrentStep = $null
    $script:State.LastError = $null
    Save-State
    Write-Host "`nPASS: all selected main-to-develop expansion cycles completed." -ForegroundColor Green
    if ($script:State.QualificationMode -eq 'RollingDevelop') {
        Write-Host 'NOTE: This burn-in spans multiple develop revisions. Run a fresh pinned cycle before final release qualification.' -ForegroundColor Yellow
    }
    Write-Host "State: $script:StatePath" -ForegroundColor DarkGray
    exit 0
}
catch {
    $runError = $_
    $runInterrupted = $runError.Exception -is [Management.Automation.PipelineStoppedException] -or
        $runError.FullyQualifiedErrorId -like '*PipelineStopped*'
    if ($script:HistoryRun -and -not $script:HistoryRun.Completed) {
        $failedUtc = [DateTime]::UtcNow
        try {
            Write-MemLabsTestHistoryEvent -Event ([pscustomobject]@{
                    EventType = 'RunCompleted'; RunId = $script:HistoryRun.RunId
                    CandidateKey = $script:HistoryRun.CandidateKey; Mode = 'CrossRevision'
                    Family = $script:HistoryRun.Family; Suite = 'Upgrade'
                    StartedUtc = $script:HistoryRun.StartedUtc.ToString('o')
                    CompletedUtc = $failedUtc.ToString('o')
                    DurationSeconds = [Math]::Round(($failedUtc - $script:HistoryRun.StartedUtc).TotalSeconds, 1)
                    Commit = $developCommit; MainRevision = $mainCommit; Success = $false; ExitCode = 1
                    Error = $runError.Exception.Message; Domains = @($script:HistoryRun.Metadata.Domains)
                    CoverageTags = @($script:HistoryRun.Metadata.CoverageTags); NeedsRerun = $true
                    Interrupted = $runInterrupted
                })
            $script:HistoryRun.Completed = $true
        }
        catch {
            Write-Host "WARNING: Could not record cross-revision test history: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($script:State -and $script:StatePath) {
        $script:State.Status = 'Failed'
        $script:State.LastError = $runError.Exception.Message
        $script:State['Interrupted'] = $runInterrupted
        Save-State
    }
    Write-Host "FAIL: $($runError.Exception.Message)" -ForegroundColor Red
    if ($script:MainBaselineFailureCleanupPossible) {
        Write-Host 'Exact-main may have removed failed Phase 1 VMs using its historical cleanup behavior.' -ForegroundColor Yellow
    }
    if ($script:StatePath) { Write-Host "State: $script:StatePath" -ForegroundColor DarkGray }
    exit 1
}
finally {
    if ($script:ExactMainClusterAdapterCompatibilityActive) {
        $null = Restore-ExactMainClusterAdapterCompatibility -BestEffort
    }
    if ($script:MutationMutexHeld) {
        try { $script:MutationMutex.ReleaseMutex() } catch { }
    }
    if ($script:MutationMutex) { $script:MutationMutex.Dispose() }
}
