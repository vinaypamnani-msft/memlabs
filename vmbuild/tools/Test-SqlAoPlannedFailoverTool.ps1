#requires -Version 5.1
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture locals are consumed by AST-extracted production scriptblocks.')]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-FailoverTool {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

$path = Join-Path $RootPath 'tools\Test-SqlAoPlannedFailover.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
Assert-FailoverTool ($parseErrors.Count -eq 0) 'planned failover tool parses'
$source = Get-Content -LiteralPath $path -Raw
$codeTokens = @($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment } | ForEach-Object { $_.Text }) -join ' '

Assert-FailoverTool ($source -match 'SupportsShouldProcess' -and $source -match "ConfirmImpact = 'High'") 'tool requires high-impact ShouldProcess confirmation'
Assert-FailoverTool ($source -match 'synchronization_state_desc' -and $source -match 'is_failover_ready') 'preflight measures synchronization and failover readiness'
Assert-FailoverTool ($source -match 'Get-ClusterQuorum' -and $source -match 'Test-ClusterPrimaryOwnership') 'preflight requires quorum and SQL/WSFC current-primary consistency'
Assert-FailoverTool (-not ($source -match 'OwnerPolicyValid|Run Phase 5 owner convergence')) 'preflight does not require MemLabs-managed owner sets'
Assert-FailoverTool ($source -match 'SYNCHRONOUS_COMMIT' -and $source -match 'SYNCHRONIZED') 'tool requires synchronous synchronized target'
Assert-FailoverTool ($source -match '(?s)availability_databases_cluster.+?LEFT JOIN sys\.dm_hadr_database_replica_states.+?LEFT JOIN sys\.dm_hadr_database_replica_cluster_states') 'database readiness preserves configured databases with missing runtime rows'
Assert-FailoverTool ($source -match 'replica_server_name = @@SERVERNAME' -and -not ($source -match 'replica_server_name LIKE')) 'local replica lookup is exact for default and named instances'
Assert-FailoverTool ($source -match '\[Convert\]::IsDBNull\(\$_\.is_failover_ready\)') 'missing database runtime readiness normalizes to not ready'
Assert-FailoverTool ($source -match 'ALTER AVAILABILITY GROUP \[\$escapedAgName\] FAILOVER') 'tool performs planned SQL failover'
Assert-FailoverTool (-not ($codeTokens -match 'FORCE_FAILOVER_ALLOW_DATA_LOSS|Stop-VM|Restart-VM|Stop-ClusterGroup|Move-ClusterGroup')) 'tool has no forced failover, VM power, or WSFC move path'
Assert-FailoverTool ($source -match 'MultiSubnetFailover=True') 'tool validates client connectivity with MultiSubnetFailover'
Assert-FailoverTool ($source -match 'Wait-ForRoleConvergence -ExpectedPrimary \$targetSecondary' -and
    $source -match 'Wait-ForRoleConvergence -ExpectedPrimary \$originalPrimary') 'tool validates failover and failback role transitions'
Assert-FailoverTool ($source -match '\[string\]::Equals.+?ReplicaServer' -and $source -match 'DatabaseInAg') 'listener validation requires exact AG replica and AG database membership'
Assert-FailoverTool ($source -match 'refusing (planned )?failback') 'tool refuses unsafe failback'
Assert-FailoverTool ($source -match 'NoFailback') 'tool supports intentionally retaining the new primary'
Assert-FailoverTool ($source -match 'Get-Credential' -and -not ($source -match 'ConvertTo-SecureString.+?-AsPlainText')) 'credential is prompted securely'
Assert-FailoverTool ($source -match 'Authoritative final primary after test' -and $source -match 'Reconciliation: performing planned failback') 'error path records final primary and attempts only safe reconciliation'
Assert-FailoverTool ($source -match 'Invoke-Command.+?-AsJob' -and $source -match 'remaining.*deadline') 'PowerShell Direct operations honor the remaining deadline'
Assert-FailoverTool ($source -match 'ThrowTerminatingError\(\$testError\)' -and $source -match 'SqlAoFinalPrimaryPostconditionFailed') 'final-primary mismatch terminates while preserving the captured error record'
Assert-FailoverTool ($source -match 'Wait-ForClusterPrimaryOwnership -PrimaryNode \$finalPrimary' -and
    $source -match 'Final WSFC owner postcondition failed') 'final success requires settled WSFC ownership for the final SQL primary'
Assert-FailoverTool ([regex]::Matches($source, "Save-HealthSnapshot -Label 'startup'").Count -eq 1 -and
    [regex]::Matches($source, "Save-HealthSnapshot -Label 'after-failover'").Count -eq 1 -and
    [regex]::Matches($source, "Save-HealthSnapshot -Label 'after-failback'").Count -eq 1) 'tool requests one labeled health snapshot at each transition stage'
Assert-FailoverTool ($source.IndexOf("Save-HealthSnapshot -Label 'startup'") -lt
    $source.IndexOf("Failing over to")) 'startup health snapshot precedes the first mutation'
Assert-FailoverTool ($source.IndexOf("Save-HealthSnapshot -Label 'startup'") -lt
    $source.IndexOf('Confirm-FailoverPreconditions -ExpectedPrimary') -and
    $source.IndexOf('Confirm-FailoverPreconditions -ExpectedPrimary') -lt
    $source.IndexOf('$firstFailoverAttempted = $true')) 'lightweight failover preconditions are refreshed after baseline collection and before mutation'
Assert-FailoverTool ($source -match '(?s)Wait-ForClusterPrimaryOwnership -PrimaryNode \$targetSecondary.+?Save-HealthSnapshot -Label ''after-failover''' -and
    $source -match '(?s)Wait-ForClusterPrimaryOwnership -PrimaryNode \$originalPrimary.+?Save-HealthSnapshot -Label ''after-failback''') 'post-transition snapshots wait for settled SQL and WSFC ownership'
Assert-FailoverTool ($source -match '\[switch\]\$SkipHealthSnapshots' -and
    $source -match 'Credential\s*=\s*\$Credential' -and
    $source -match 'SnapshotLabel\s*=\s*\$Label') 'health snapshots are default-on, reusable-credential, labeled collector calls'
Assert-FailoverTool ($source -match '\$env:USERDNSDOMAIN' -and
    $source -match '\$env:LOGONSERVER' -and $source -match 'param\(\$DomainHint\)' -and
    $source -match 'ArgumentList \$resolvedDomain' -and
    $source -match 'Supply -Domain and -DcVm explicitly') 'snapshot environment supports partial overrides and discovery fallback'
Assert-FailoverTool ($source -match 'CollectionComplete' -and
    $source -match 'preserved incomplete artifacts') 'snapshot acquisition failure is distinct from evidence-only health findings'
Assert-FailoverTool ($source -match 'Get-ExpectedFinalPrimary' -and
    $source -match 'FailoverConverged') 'final-primary expectation depends on verified transition convergence'

$healthSnapshotFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-HealthSnapshot'
        }, $true))
Assert-FailoverTool ($healthSnapshotFunction.Count -eq 1) 'tool defines one health collector invocation helper'
if ($healthSnapshotFunction.Count -eq 1) {
    $invokeSnapshot = $healthSnapshotFunction[0].Body.GetScriptBlock()
    $SkipHealthSnapshots = $false
    $script:healthSnapshotEnvironment = [pscustomobject]@{ Domain = 'fabrikam.com'; DcVm = 'FAB-DC1' }
    $script:snapshotTempRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:snapshotTempRoot -Force
    $healthCollectorPath = Join-Path $script:snapshotTempRoot 'mock-collector.ps1'
    [IO.File]::WriteAllText($healthCollectorPath, '# collector boundary fixture')
    $NodeVm = @('SQL1', 'SQL2')
    $DomainNetbios = 'fabrikam'
    $AdminName = 'admin'
    $AgName = 'AG'
    $SqlInstanceName = 'MSSQLSERVER'
    $ListenerPort = 1500
    $HealthHours = 4
    $Credential = [PSCredential]::new('fabrikam\admin', [Security.SecureString]::new())
    $script:snapshotInvocations = [Collections.Generic.List[object]]::new()
    $healthCollectorInvoker = {
        param($Path, $Parameters)
        $script:snapshotInvocations.Add([pscustomobject]@{ Path = $Path; Parameters = $Parameters })
        $reportPath = Join-Path $script:snapshotTempRoot "$($Parameters.SnapshotLabel).txt"
        $archivePath = Join-Path $script:snapshotTempRoot "$($Parameters.SnapshotLabel).zip"
        [IO.File]::WriteAllText($reportPath, "snapshot=$($Parameters.SnapshotLabel)")
        Compress-Archive -LiteralPath $reportPath -DestinationPath $archivePath -Force -ErrorAction Stop
        [pscustomobject]@{
            SnapshotLabel = $Parameters.SnapshotLabel
            ReportPath = $reportPath
            ArchivePath = $archivePath
            CollectionComplete = $true
            CollectionErrors = @()
            Findings = @('evidence-only finding')
        }
    }
    function Write-TestLog { param([string]$Message) }
    try {
        $artifact = & $invokeSnapshot -Label startup
        $invocation = $script:snapshotInvocations[0]
        Assert-FailoverTool ($artifact.SnapshotLabel -eq 'startup' -and
            @($artifact.Findings).Count -eq 1 -and
            $invocation.Parameters.SnapshotLabel -eq 'startup' -and
            $invocation.Parameters.DcVm -eq 'FAB-DC1' -and
            $invocation.Parameters.Domain -eq 'fabrikam.com' -and
            [object]::ReferenceEquals($invocation.Parameters.Credential, $Credential)) 'health helper reuses discovered environment and the existing credential'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($artifact.ArchivePath)
        try {
            Assert-FailoverTool ($archive.Entries.Count -eq 1 -and
                $archive.Entries[0].Name -eq 'startup.txt') 'health collector boundary produces a real labeled report ZIP'
        }
        finally {
            $archive.Dispose()
        }

        $SkipHealthSnapshots = $true
        $script:snapshotInvocations.Clear()
        $skipped = & $invokeSnapshot -Label startup
        Assert-FailoverTool ($null -eq $skipped -and $script:snapshotInvocations.Count -eq 0) 'SkipHealthSnapshots suppresses collector invocation'

        $SkipHealthSnapshots = $false
        $healthCollectorInvoker = {
            param($Path, $Parameters)
            $reportPath = Join-Path $script:snapshotTempRoot 'incomplete.txt'
            $archivePath = Join-Path $script:snapshotTempRoot 'incomplete.zip'
            [IO.File]::WriteAllText($reportPath, 'collection failed')
            Compress-Archive -LiteralPath $reportPath -DestinationPath $archivePath -Force -ErrorAction Stop
            [pscustomobject]@{
                ReportPath = $reportPath
                ArchivePath = $archivePath
                CollectionComplete = $false
                CollectionErrors = @('SQL1: COLLECTION FAILED')
            }
        }
        $incompleteCollectionRejected = $false
        try { $null = & $invokeSnapshot -Label startup } catch {
            $incompleteCollectionRejected = $_.Exception.Message -match 'preserved incomplete artifacts' -and
                $_.Exception.Message -match 'COLLECTION FAILED'
        }
        Assert-FailoverTool $incompleteCollectionRejected 'health helper preserves artifacts but rejects incomplete remote acquisition'

        $healthCollectorInvoker = { param($Path, $Parameters); return $null }
        $missingArtifactsRejected = $false
        try { $null = & $invokeSnapshot -Label startup } catch {
            $missingArtifactsRejected = $_.Exception.Message -match 'did not produce'
        }
        Assert-FailoverTool $missingArtifactsRejected 'health helper rejects a collector call without report and archive artifacts'
    }
    finally {
        Remove-Item -LiteralPath Function:\Write-TestLog -Force
        if (Test-Path -LiteralPath $script:snapshotTempRoot) {
            Remove-Item -LiteralPath $script:snapshotTempRoot -Recurse -Force
        }
    }
}

$saveSnapshotFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-HealthSnapshot'
        }, $true))
Assert-FailoverTool ($saveSnapshotFunction.Count -eq 1) 'tool defines one snapshot failure-policy helper'
if ($saveSnapshotFunction.Count -eq 1) {
    $saveSnapshot = $saveSnapshotFunction[0].Body.GetScriptBlock()
    $script:healthSnapshotArtifacts = [Collections.Generic.List[object]]::new()
    $script:healthSnapshotFailures = [Collections.Generic.List[string]]::new()
    function Invoke-HealthSnapshot { param($Label); throw "injected $Label failure" }
    function Write-TestLog { param([string]$Message) }
    try {
        $requiredThrows = $false
        try { & $saveSnapshot -Label startup -Required } catch { $requiredThrows = $_.Exception.Message -match 'injected startup failure' }
        Assert-FailoverTool $requiredThrows 'startup snapshot failure aborts before mutation'
        & $saveSnapshot -Label after-failover
        Assert-FailoverTool ($script:healthSnapshotFailures.Count -eq 1 -and
            $script:healthSnapshotFailures[0] -match 'after-failover') 'post-transition snapshot failure is retained without blocking safe failback'
    }
    finally {
        'Invoke-HealthSnapshot', 'Write-TestLog' | ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

$resolveSnapshotEnvironmentFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-HealthSnapshotEnvironment'
        }, $true))
Assert-FailoverTool ($resolveSnapshotEnvironmentFunction.Count -eq 1) 'tool defines one health snapshot environment resolver'
if ($resolveSnapshotEnvironmentFunction.Count -eq 1) {
    $resolveSnapshotEnvironment = $resolveSnapshotEnvironmentFunction[0].Body.GetScriptBlock()
    $SkipHealthSnapshots = $false
    $NodeVm = @('SQL1', 'SQL2')
    $TimeoutSeconds = 60
    $script:discoveryArgument = $null
    $script:dcVmState = 'Running'
    function Invoke-NodeCommand {
        param($VmName, $ScriptBlock, $ArgumentList, $Deadline)
        $script:discoveryArgument = $ArgumentList
        [pscustomobject]@{
            Domain = if ($ArgumentList) { [string]$ArgumentList } else { 'discovered.test' }
            DcVm = 'DISCOVERED-DC'
        }
    }
    function Get-VM {
        param($Name, $ErrorAction)
        [pscustomobject]@{ Name = $Name; State = $script:dcVmState }
    }
    try {
        $Domain = 'fabrikam.com'
        $DcVm = ''
        $resolved = & $resolveSnapshotEnvironment
        Assert-FailoverTool ($resolved.Domain -eq 'fabrikam.com' -and
            $resolved.DcVm -eq 'DISCOVERED-DC' -and
            [string]$script:discoveryArgument -eq 'fabrikam.com') 'explicit Domain is passed as the guest nltest discovery hint'

        $Domain = ''
        $DcVm = 'FAB-DC1'
        $resolved = & $resolveSnapshotEnvironment
        Assert-FailoverTool ($resolved.Domain -eq 'discovered.test' -and
            $resolved.DcVm -eq 'FAB-DC1') 'explicit DC is preserved while the missing domain is discovered'

        $Domain = 'fabrikam.com'
        $DcVm = 'FAB-DC1'
        $script:dcVmState = 'Off'
        $stoppedDcRejected = $false
        try { $null = & $resolveSnapshotEnvironment } catch {
            $stoppedDcRejected = $_.Exception.Message -match "DC VM 'FAB-DC1' is 'Off'"
        }
        Assert-FailoverTool $stoppedDcRejected 'snapshot resolver rejects a stopped DC VM'
    }
    finally {
        'Invoke-NodeCommand', 'Get-VM' | ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

$confirmPreconditionsFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-FailoverPreconditions'
        }, $true))
Assert-FailoverTool ($confirmPreconditionsFunction.Count -eq 1) 'tool defines one post-baseline precondition refresh'
if ($confirmPreconditionsFunction.Count -eq 1) {
    $confirmPreconditions = $confirmPreconditionsFunction[0].Body.GetScriptBlock()
    $NodeVm = @('SQL1', 'SQL2')
    $AgName = 'AG'
    $ListenerName = 'LISTENER'
    $ListenerPort = 1500
    $Database = 'CM_DB'
    $clusterPreflightScript = { 'cluster' }
    $listenerScript = { 'listener' }
    $script:primaryReady = $true
    $script:targetReady = $true
    $script:clusterReady = $true
    $script:listenerReady = $true
    function Get-PairState {
        param($Deadline)
        @{
            SQL1 = [pscustomobject]@{ Replica = [pscustomobject]@{ ReplicaServer = 'SQL1' } }
            SQL2 = [pscustomobject]@{ Replica = [pscustomobject]@{ ReplicaServer = 'SQL2' } }
        }
    }
    function Test-PrimaryReady { param($State, $ExpectedDatabases); return $script:primaryReady }
    function Test-TargetReady { param($State, $ExpectedDatabases); return $script:targetReady }
    function Test-ClusterPrimaryOwnership { param($ClusterState, $PrimaryNode); return $script:clusterReady }
    function Test-ListenerState { param($State, $ExpectedReplica); return $script:listenerReady }
    function Invoke-NodeCommand {
        param($VmName, $ScriptBlock, $ArgumentList, $Deadline)
        if ([object]::ReferenceEquals($ScriptBlock, $script:clusterPreflightScript)) {
            return [pscustomobject]@{ GroupOwner = 'SQL1'; PossibleOwners = @('SQL1') }
        }
        return [pscustomobject]@{ ReplicaServer = 'SQL1'; Role = 'PRIMARY'; DatabaseInAg = $true }
    }
    try {
        $null = & $confirmPreconditions -ExpectedPrimary SQL1 -ExpectedSecondary SQL2 `
            -ExpectedDatabases CM_DB -Deadline (Get-Date).AddSeconds(5)
        Assert-FailoverTool $true 'post-baseline precondition refresh accepts unchanged healthy state'

        $script:targetReady = $false
        $staleTargetRejected = $false
        try {
            $null = & $confirmPreconditions -ExpectedPrimary SQL1 -ExpectedSecondary SQL2 `
                -ExpectedDatabases CM_DB -Deadline (Get-Date).AddSeconds(5)
        }
        catch { $staleTargetRejected = $_.Exception.Message -match 'no longer synchronized' }
        Assert-FailoverTool $staleTargetRejected 'post-baseline refresh rejects a target that became unsafe'

        $script:targetReady = $true
        $script:clusterReady = $false
        $staleOwnerRejected = $false
        try {
            $null = & $confirmPreconditions -ExpectedPrimary SQL1 -ExpectedSecondary SQL2 `
                -ExpectedDatabases CM_DB -Deadline (Get-Date).AddSeconds(5)
        }
        catch { $staleOwnerRejected = $_.Exception.Message -match 'ownership changed' }
        Assert-FailoverTool $staleOwnerRejected 'post-baseline refresh rejects changed WSFC ownership'
    }
    finally {
        'Get-PairState', 'Test-PrimaryReady', 'Test-TargetReady', 'Test-ClusterPrimaryOwnership',
        'Test-ListenerState', 'Invoke-NodeCommand' |
            ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

$expectedFinalPrimaryFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ExpectedFinalPrimary'
        }, $true))
Assert-FailoverTool ($expectedFinalPrimaryFunction.Count -eq 1) 'tool defines one convergence-aware final-primary selector'
if ($expectedFinalPrimaryFunction.Count -eq 1) {
    $getExpectedFinalPrimary = $expectedFinalPrimaryFunction[0].Body.GetScriptBlock()
    Assert-FailoverTool ((& $getExpectedFinalPrimary -OriginalPrimary SQL1 -TargetSecondary SQL2 `
                -FailoverConverged $false -NoFailbackRequested $true) -eq 'SQL1') 'NoFailback startup abort expects the unchanged original primary'
    Assert-FailoverTool ((& $getExpectedFinalPrimary -OriginalPrimary SQL1 -TargetSecondary SQL2 `
                -FailoverConverged $true -NoFailbackRequested $true) -eq 'SQL2') 'NoFailback converged failover expects the target primary'
    Assert-FailoverTool ((& $getExpectedFinalPrimary -OriginalPrimary SQL1 -TargetSecondary SQL2 `
                -FailoverConverged $true -NoFailbackRequested $false) -eq 'SQL1') 'normal run always expects failback to the original primary'
}

$clusterOwnershipFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ClusterPrimaryOwnership'
        }, $true))
Assert-FailoverTool ($clusterOwnershipFunction.Count -eq 1) 'tool defines one current-primary cluster ownership predicate'
if ($clusterOwnershipFunction.Count -eq 1) {
    $testClusterOwnership = $clusterOwnershipFunction[0].Body.GetScriptBlock()
    $manualSingleton = [pscustomobject]@{
        NodesUp = $true
        GroupState = 'Online'
        ResourceState = 'Online'
        GroupOwner = 'SQL1'
        PossibleOwners = @('SQL1')
    }
    Assert-FailoverTool (& $testClusterOwnership -ClusterState $manualSingleton -PrimaryNode SQL1) 'preflight accepts SQL-managed singleton owner for MANUAL mode'
    $automaticPair = $manualSingleton.PSObject.Copy()
    $automaticPair.PossibleOwners = @('SQL1', 'SQL2')
    Assert-FailoverTool (& $testClusterOwnership -ClusterState $automaticPair -PrimaryNode SQL1) 'preflight accepts multiple SQL-managed possible owners'
    $missingPrimary = $manualSingleton.PSObject.Copy()
    $missingPrimary.PossibleOwners = @('SQL2')
    Assert-FailoverTool (-not (& $testClusterOwnership -ClusterState $missingPrimary -PrimaryNode SQL1)) 'preflight rejects current primary missing from possible owners'
    $wrongGroupOwner = $manualSingleton.PSObject.Copy()
    $wrongGroupOwner.GroupOwner = 'SQL2'
    Assert-FailoverTool (-not (& $testClusterOwnership -ClusterState $wrongGroupOwner -PrimaryNode SQL1)) 'preflight rejects WSFC owner differing from SQL primary'
    $offlineResource = $manualSingleton.PSObject.Copy()
    $offlineResource.ResourceState = 'Offline'
    Assert-FailoverTool (-not (& $testClusterOwnership -ClusterState $offlineResource -PrimaryNode SQL1)) 'preflight rejects an offline AG resource'
}

$clusterWaitFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-ForClusterPrimaryOwnership'
        }, $true))
Assert-FailoverTool ($clusterWaitFunction.Count -eq 1) 'tool defines one bounded final WSFC ownership wait'
if ($clusterOwnershipFunction.Count -eq 1 -and $clusterWaitFunction.Count -eq 1) {
    . ([scriptblock]::Create($clusterOwnershipFunction[0].Extent.Text))
    . ([scriptblock]::Create($clusterWaitFunction[0].Extent.Text))
    $NodeVm = @('SQL1', 'SQL2')
    $AgName = 'AG'
    $clusterPreflightScript = { 1 }
    $TimeoutSeconds = 60
    $script:clusterStateQueue = [Collections.Generic.Queue[object]]::new()
    function Invoke-NodeCommand {
        param($VmName, $ScriptBlock, $ArgumentList, $Deadline)
        return $script:clusterStateQueue.Dequeue()
    }
    function Write-TestLog { param([string]$Message) }
    function Start-Sleep { param([int]$Seconds) }
    try {
        $pendingOwner = [pscustomobject]@{
            NodesUp = $true
            GroupState = 'Online'
            ResourceState = 'Online'
            GroupOwner = 'SQL2'
            PossibleOwners = @('SQL1')
            PreferredOwners = @('SQL1')
        }
        $settledOwner = $pendingOwner.PSObject.Copy()
        $settledOwner.PossibleOwners = @('SQL2')
        $settledOwner.PreferredOwners = @('SQL2')
        $script:clusterStateQueue.Enqueue($pendingOwner)
        $script:clusterStateQueue.Enqueue($settledOwner)
        $settled = Wait-ForClusterPrimaryOwnership -PrimaryNode SQL2 -Deadline (Get-Date).AddSeconds(5)
        Assert-FailoverTool ($settled.GroupOwner -eq 'SQL2' -and
            ($settled.PossibleOwners -join ',') -eq 'SQL2') 'final owner wait polls through SQL owner-list settling to reversed singleton'

        $script:clusterStateQueue.Clear()
        $script:clusterStateQueue.Enqueue($pendingOwner)
        $missingFinalOwnerRejected = $false
        try { $null = Wait-ForClusterPrimaryOwnership -PrimaryNode SQL2 -Deadline (Get-Date) } catch {
            $missingFinalOwnerRejected = $_.Exception.Message -match 'did not converge'
        }
        Assert-FailoverTool $missingFinalOwnerRejected 'final owner wait rejects expected SQL primary absent from possible owners'
    }
    finally {
        'Invoke-NodeCommand', 'Write-TestLog', 'Start-Sleep' |
            ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

$nameSetFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-DatabaseNameSet'
        }, $true))
Assert-FailoverTool ($nameSetFunction.Count -eq 1) 'tool defines one database-name set comparator'
if ($nameSetFunction.Count -eq 1) {
    . ([scriptblock]::Create($nameSetFunction[0].Extent.Text))
    Assert-FailoverTool (Test-DatabaseNameSet -Actual TESTDB,CM_PS1 -Expected cm_ps1,testdb) 'database set comparison accepts reorder and case variation'
    Assert-FailoverTool (-not (Test-DatabaseNameSet -Actual A,'B,C' -Expected 'A,B',C)) 'database set comparison rejects comma-delimiter collisions'
    Assert-FailoverTool (-not (Test-DatabaseNameSet -Actual CM_PS1,CM_PS1 -Expected CM_PS1,TESTDB)) 'database set comparison rejects duplicates and missing names'
}

$targetReadyFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-TargetReady'
        }, $true))
Assert-FailoverTool ($targetReadyFunction.Count -eq 1) 'tool defines one target-readiness predicate'
if ($targetReadyFunction.Count -eq 1) {
    $targetReady = $targetReadyFunction[0].Body.GetScriptBlock()
    $replica = [pscustomobject]@{
        AvailabilityMode = 'SYNCHRONOUS_COMMIT'
        Role = 'SECONDARY'
        Connection = 'CONNECTED'
        Health = 'HEALTHY'
    }
    $healthyRows = @(
        [pscustomobject]@{ Name = 'CM_PS1'; Synchronization = 'SYNCHRONIZED'; Health = 'HEALTHY'; Suspended = $false; Joined = $true; FailoverReady = $true },
        [pscustomobject]@{ Name = 'TESTDB'; Synchronization = 'SYNCHRONIZED'; Health = 'HEALTHY'; Suspended = $false; Joined = $true; FailoverReady = $true }
    )
    Assert-FailoverTool (& $targetReady -State ([pscustomobject]@{ Replica = $replica; Databases = $healthyRows }) -ExpectedDatabases CM_PS1,TESTDB) 'readiness accepts the complete healthy configured database set'
    Assert-FailoverTool (-not (& $targetReady -State ([pscustomobject]@{ Replica = $replica; Databases = @() }) -ExpectedDatabases CM_PS1,TESTDB)) 'readiness rejects zero database rows'
    Assert-FailoverTool (-not (& $targetReady -State ([pscustomobject]@{ Replica = $replica; Databases = @($healthyRows[0]) }) -ExpectedDatabases CM_PS1,TESTDB)) 'readiness rejects a missing configured database'
    Assert-FailoverTool (-not (& $targetReady -State ([pscustomobject]@{ Replica = $replica; Databases = $healthyRows }) -ExpectedDatabases CM_PS1,EXTRA)) 'readiness rejects a different equal-count database set'
    $notJoined = @($healthyRows | ForEach-Object { $_.PSObject.Copy() })
    $notJoined[1].Joined = $false
    Assert-FailoverTool (-not (& $targetReady -State ([pscustomobject]@{ Replica = $replica; Databases = $notJoined }) -ExpectedDatabases CM_PS1,TESTDB)) 'readiness rejects an unjoined database'
}

$listenerStateFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ListenerState'
        }, $true))
Assert-FailoverTool ($listenerStateFunction.Count -eq 1) 'tool defines one exact listener-state predicate'
if ($listenerStateFunction.Count -eq 1) {
    $testListener = $listenerStateFunction[0].Body.GetScriptBlock()
    $listenerState = [pscustomobject]@{ ReplicaServer = 'SQL1'; Role = 'PRIMARY'; DatabaseInAg = $true }
    Assert-FailoverTool (& $testListener -State $listenerState -ExpectedReplica SQL1) 'listener predicate accepts the exact primary AG replica'
    Assert-FailoverTool (-not (& $testListener -State ([pscustomobject]@{ ReplicaServer = 'SQL10'; Role = 'PRIMARY'; DatabaseInAg = $true }) -ExpectedReplica SQL1)) 'listener predicate rejects SQL1 versus SQL10 prefix collisions'
    Assert-FailoverTool (-not (& $testListener -State ([pscustomobject]@{ ReplicaServer = 'SQL1'; Role = 'SECONDARY'; DatabaseInAg = $true }) -ExpectedReplica SQL1)) 'listener predicate rejects the wrong replica role'
    Assert-FailoverTool (-not (& $testListener -State ([pscustomobject]@{ ReplicaServer = 'SQL1'; Role = 'PRIMARY'; DatabaseInAg = $false }) -ExpectedReplica SQL1)) 'listener predicate rejects a non-AG database'
}

$finalPostconditionFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-FinalPrimaryPostcondition'
        }, $true))
Assert-FailoverTool ($finalPostconditionFunction.Count -eq 1) 'tool defines one final-primary postcondition predicate'
if ($finalPostconditionFunction.Count -eq 1) {
    $testFinalPrimary = $finalPostconditionFunction[0].Body.GetScriptBlock()
    Assert-FailoverTool (& $testFinalPrimary -FinalPrimary SQL1 -ExpectedPrimary sql1) 'final-primary postcondition accepts the exact expected primary'
    Assert-FailoverTool (-not (& $testFinalPrimary -FinalPrimary SQL2 -ExpectedPrimary SQL1)) 'final-primary postcondition rejects the wrong unique primary'
    Assert-FailoverTool (-not (& $testFinalPrimary -FinalPrimary 'AMBIGUOUS[]' -ExpectedPrimary SQL1)) 'final-primary postcondition rejects an ambiguous primary'
    Assert-FailoverTool (-not (& $testFinalPrimary -FinalPrimary 'UNKNOWN (probe failed)' -ExpectedPrimary SQL1)) 'final-primary postcondition rejects an unavailable observation'
}

$primaryReadyFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PrimaryReady'
        }, $true))
$reconciliationFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-ForReconciliationDecision'
        }, $true))
Assert-FailoverTool ($primaryReadyFunction.Count -eq 1 -and $reconciliationFunction.Count -eq 1) 'tool defines testable reconciliation readiness and polling'
if ($primaryReadyFunction.Count -eq 1 -and $targetReadyFunction.Count -eq 1 -and $reconciliationFunction.Count -eq 1) {
    . ([scriptblock]::Create($primaryReadyFunction[0].Extent.Text))
    . ([scriptblock]::Create($targetReadyFunction[0].Extent.Text))
    . ([scriptblock]::Create($reconciliationFunction[0].Extent.Text))
    $NodeVm = @('SQL1', 'SQL2')
    $primaryReplica = [pscustomobject]@{ Role = 'PRIMARY'; Connection = 'CONNECTED'; Health = 'HEALTHY' }
    $secondaryReplica = [pscustomobject]@{ AvailabilityMode = 'SYNCHRONOUS_COMMIT'; Role = 'SECONDARY'; Connection = 'CONNECTED'; Health = 'HEALTHY' }
    $primaryState = [pscustomobject]@{ Replica = $primaryReplica; Databases = $healthyRows }
    $secondaryState = [pscustomobject]@{ Replica = $secondaryReplica; Databases = $healthyRows }
    $resolvingState = [pscustomobject]@{ Replica = [pscustomobject]@{ Role = 'RESOLVING' }; Databases = $healthyRows }
    $script:pairStateQueue = [Collections.Generic.Queue[object]]::new()
    $script:pairStateCalls = 0
    function Get-PairState {
        param([datetime]$Deadline)
        $script:pairStateCalls++
        return $script:pairStateQueue.Dequeue()
    }
    function Write-TestLog { param([string]$Message) }
    function Start-Sleep { param([int]$Seconds) }
    try {
        $script:pairStateQueue.Enqueue(@{ SQL1 = $resolvingState; SQL2 = $resolvingState })
        $script:pairStateQueue.Enqueue(@{ SQL1 = $secondaryState; SQL2 = $primaryState })
        $decision = Wait-ForReconciliationDecision -OriginalPrimary SQL1 -TargetSecondary SQL2 `
            -ExpectedDatabases CM_PS1,TESTDB -Deadline (Get-Date).AddSeconds(5)
        Assert-FailoverTool ($decision.Outcome -eq 'TargetReady' -and $script:pairStateCalls -eq 2) 'reconciliation polls through resolving state until safe target readiness'

        $script:pairStateQueue.Clear()
        $script:pairStateCalls = 0
        $script:pairStateQueue.Enqueue(@{ SQL1 = $primaryState; SQL2 = $secondaryState })
        $decision = Wait-ForReconciliationDecision -OriginalPrimary SQL1 -TargetSecondary SQL2 `
            -ExpectedDatabases CM_PS1,TESTDB -Deadline (Get-Date).AddSeconds(5)
        Assert-FailoverTool ($decision.Outcome -eq 'OriginalPrimary' -and $script:pairStateCalls -eq 1) 'reconciliation stops without mutation when the original primary is restored'

        $script:pairStateQueue.Clear()
        $script:pairStateCalls = 0
        $decision = Wait-ForReconciliationDecision -OriginalPrimary SQL1 -TargetSecondary SQL2 `
            -ExpectedDatabases CM_PS1,TESTDB -Deadline (Get-Date).AddSeconds(5) -NoFailback
        Assert-FailoverTool ($decision.Outcome -eq 'Disabled' -and $script:pairStateCalls -eq 0) 'NoFailback disables reconciliation without probing for a return transition'
    }
    finally {
        'Get-PairState', 'Write-TestLog', 'Start-Sleep' |
            ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

$writeLogFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-TestLog'
        }, $true))
if ($writeLogFunction.Count -eq 1) {
    $writeLog = $writeLogFunction[0].Body.GetScriptBlock()
    $logPath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid())\unwritable.log"
    $loggingContinued = $true
    try { & $writeLog -Message 'simulated log-write failure' } catch { $loggingContinued = $false }
    Assert-FailoverTool $loggingContinued 'log-write failure does not abort the failover workflow'
}

$invokeNodeFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-NodeCommand'
        }, $true))
if ($invokeNodeFunction.Count -eq 1) {
    $invokeNode = $invokeNodeFunction[0].Body.GetScriptBlock()
    $expiredDeadlineRejected = $false
    try { & $invokeNode -VmName SQL1 -ScriptBlock { 1 } -Deadline (Get-Date).AddSeconds(-1) } catch {
        $expiredDeadlineRejected = $_.Exception.Message -match 'Deadline expired'
    }
    Assert-FailoverTool $expiredDeadlineRejected 'expired operation deadline is rejected before remoting'

    $script:deadlineMockJob = [pscustomobject]@{
        State = 'Completed'
        ChildJobs = @([pscustomobject]@{ JobStateInfo = [pscustomobject]@{ Reason = $null } })
    }
    function Invoke-Command {
        [CmdletBinding()]
        param($VMName, [PSCredential]$Credential, $ScriptBlock, $ArgumentList, [switch]$AsJob)
        if ($script:deadlineMockMode -eq 'LaunchDelay') { Microsoft.PowerShell.Utility\Start-Sleep -Seconds 3 }
        return $script:deadlineMockJob
    }
    function Wait-Job {
        [CmdletBinding()]
        param($Job, $Timeout)
        return $Job
    }
    function Stop-Job {
        [CmdletBinding()]
        param($Job)
    }
    function Receive-Job {
        [CmdletBinding()]
        param($Job)
        if ($script:deadlineMockMode -eq 'ReceiveDelay') { Microsoft.PowerShell.Utility\Start-Sleep -Seconds 3 }
        return $true
    }
    function Remove-Job {
        [CmdletBinding()]
        param($Job, [switch]$Force)
        $script:removeJobCalls++
    }
    try {
        $script:deadlineMockMode = 'LaunchDelay'
        $script:removeJobCalls = 0
        $delayedLaunchRejected = $false
        try { & $invokeNode -VmName SQL1 -ScriptBlock { 1 } -Deadline (Get-Date).AddSeconds(2) } catch {
            $delayedLaunchRejected = $_.Exception.Message -match 'exceeded its deadline while starting'
        }
        Assert-FailoverTool ($delayedLaunchRejected -and $script:removeJobCalls -eq 1) 'job-launch delay cannot return success and cleans the job after the operation deadline'

        $script:deadlineMockMode = 'ReceiveDelay'
        $script:removeJobCalls = 0
        $delayedReceiveRejected = $false
        try { & $invokeNode -VmName SQL1 -ScriptBlock { 1 } -Deadline (Get-Date).AddSeconds(2) } catch {
            $delayedReceiveRejected = $_.Exception.Message -match 'exceeded its deadline while receiving results'
        }
        Assert-FailoverTool ($delayedReceiveRejected -and $script:removeJobCalls -eq 1) 'result-receive delay cannot return success and cleans the job after the operation deadline'
    }
    finally {
        'Invoke-Command', 'Wait-Job', 'Stop-Job', 'Receive-Job', 'Remove-Job' |
            ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) planned failover tool assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All planned SQLAO failover tool tests passed.'
