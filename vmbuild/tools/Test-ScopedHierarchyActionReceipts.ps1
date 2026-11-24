#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'common\Common.ExistingHierarchy.ps1')
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Read-TestAst {
    param($Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse '$Path': $($errors -join '; ')" }
    return $ast
}
$template = Read-TestAst (Join-Path $root 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1')
$ensure = $template.Find({
        param($node)
        $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'Ensure'
    }, $true)
$class = $template.Find({
        param($node)
        $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'WaitForWorkflowReceipt'
    }, $true)
if (-not $ensure -or -not $class) { throw 'Workflow receipt resource types were not found.' }
$factory = [scriptblock]::Create($ensure.Extent.Text + "`n" + $class.Extent.Text + "`n[WaitForWorkflowReceipt]::new()")
$resource = & $factory
$resource.MachineName = 'EXISTING-PRI'
$resource.LogFolder = 'DSC'
$resource.ScopedActionOwnerVMName = 'EXISTING-PRI'
$resource.ScopedActionTargetVMName = 'NEW1'
$runId = [guid]::NewGuid().ToString()
$resource.ScopedActionRunId = $runId
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-scoped-receipts-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
$previousDrive = $env:SystemDrive
$previousComputer = $env:COMPUTERNAME
$env:SystemDrive = $testRoot
$env:COMPUTERNAME = 'NEW1'
function Write-Status { param($Message) }
try {
    $staging = Join-Path $testRoot 'staging\DSC'
    $folder = Join-Path $staging 'ScopedHierarchyActions'
    $null = New-Item -ItemType Directory -Path $folder -Force
    $path = Join-Path $folder "$runId.json"
    Assert-True (-not $resource.Test()) 'Missing current action receipt incorrectly satisfied the barrier.'
    $baseline = @{
        SchemaVersion = 1; Kind = 'SiteRoles'; RunId = $runId
        OwnerVMName = 'EXISTING-PRI'; TargetVMName = 'NEW1'; Status = 'Completed'; Message = ''
    }
    foreach ($case in @('Completed', 'Failed', 'WrongRun', 'WrongOwner', 'WrongTarget', 'WrongKind', 'ArrayStatus', 'Malformed')) {
        $receipt = $baseline.Clone()
        switch ($case) {
            Failed { $receipt.Status = 'Failed'; $receipt.Message = 'Existing provider was deliberately broken.' }
            WrongRun { $receipt.RunId = [guid]::NewGuid().ToString() }
            WrongOwner { $receipt.OwnerVMName = 'UNRELATED' }
            WrongTarget { $receipt.TargetVMName = 'UNRELATED' }
            WrongKind { $receipt.Kind = 'ClientPush' }
            ArrayStatus { $receipt.Status = @('Completed') }
        }
        $json = if ($case -eq 'Malformed') { '{invalid' } else { $receipt | ConvertTo-Json -Compress }
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8
        $failure = ''
        $ready = $false
        try { $ready = $resource.Test() }
        catch { $failure = $_.Exception.Message }
        if ($case -eq 'Completed') {
            Assert-True ($ready -and -not $failure) 'Exact current-target action receipt did not release its own barrier.'
        }
        else {
            Assert-True (-not $ready -and $failure) "Invalid/failed receipt '$case' was silently retried or accepted."
            if ($case -eq 'Failed') { Assert-True ($failure -like '*deliberately broken*') 'The specific existing-prerequisite failure was lost.' }
        }
    }
    Remove-Item -LiteralPath $path
    $core = Read-TestAst (Join-Path $root 'common\Common.ExistingHierarchy.ps1')
    $publisher = $core.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-MemLabsScopedHierarchyActionReceipt'
        }, $true)
    $command = $publisher.Body.Find({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-VmCommand'
        }, $true)
    $argument = @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })
    if ($argument.Count -ne 1) { throw 'Scoped receipt producer block was not found uniquely.' }
    $producer = $argument[0].ScriptBlock.GetScriptBlock()
    $json = $baseline | ConvertTo-Json -Compress
    $notPrepared = & $producer $json $staging
    Assert-True ($notPrepared -eq 'WAITING_FOR_CURRENT_TARGET_PREPARATION' -and -not (Test-Path -LiteralPath $path)) `
        'Producer wrote a success receipt before the target finished its own current-run preparation.'
    $earlyFailure = $baseline.Clone()
    $earlyFailure.Status = 'Failed'
    Assert-True ((& $producer ($earlyFailure | ConvertTo-Json -Compress) $staging) -eq 'WAITING_FOR_CURRENT_TARGET_PREPARATION' -and
        -not (Test-Path -LiteralPath $path)) 'An early failed receipt could be erased by the target preparation race instead of surfacing through owner-job failure.'
    Set-Content -LiteralPath (Join-Path $staging 'RunGuid.txt') -Value ([guid]::NewGuid().ToString()) -Encoding ASCII
    Assert-True ((& $producer $json $staging) -eq 'WAITING_FOR_CURRENT_TARGET_PREPARATION') `
        'A stale target-preparation token satisfied the current action.'
    Set-Content -LiteralPath (Join-Path $staging 'RunGuid.txt') -Value $runId -Encoding ASCII
    Assert-True ((& $producer $json $staging) -eq 'PUBLISHED' -and $resource.Test()) `
        'Actual producer-to-DSC-consumer completion did not validate the current target.'
    Assert-True (@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count -eq 0) 'Atomic receipt publication leaked temporary files.'
    $failed = $baseline.Clone()
    $failed.Status = 'Failed'
    $failed.Message = 'Required existing SQL prerequisite is deliberately broken.'
    Assert-True ((& $producer ($failed | ConvertTo-Json -Compress) $staging) -eq 'PUBLISHED') 'Failed prerequisite receipt was not published.'
    $failure = ''
    try { $null = $resource.Test() } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*SQL prerequisite is deliberately broken*') 'Producer/consumer lost the actionable dependency failure.'

    function Get-MemLabsRequestedDeploymentVMs { param($DeployConfig); $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } }
    function Test-MemLabsContextOnlyVM { param($VM); return $VM.hidden -eq $true }
    $config = [pscustomobject]@{
        virtualMachines = @(
            [pscustomobject]@{ vmName = 'NEW1'; role = 'Secondary' },
            [pscustomobject]@{ vmName = 'EXISTING-PRI'; role = 'Primary'; hidden = $true }
        )
    }
    $action = [pscustomobject]@{ Kind = 'SiteRoles'; OwnerVMName = 'EXISTING-PRI'; TargetVMNames = @('NEW1') }
    Initialize-MemLabsScopedHierarchyActionRun -DeployConfig $config -Actions @($action) -RunId $runId
    Assert-True ($action.RunId -eq $runId -and $config.virtualMachines[0].phase8ScopedHierarchyAction.RunId -eq $runId -and
        $config.virtualMachines[0].phase8ScopedHierarchyAction.Kind -eq 'SiteRoles' -and
        -not $config.virtualMachines[1].PSObject.Properties['phase8ScopedHierarchyAction']) `
        'Runtime scoped identity was not limited to the requested target.'
    $markerBefore = $config.virtualMachines[0].phase8ScopedHierarchyAction | ConvertTo-Json -Compress
    Assert-True ((Get-MemLabsScopedRoleRetryRunId -DeployConfig $config -VMNames @('NEW1')) -eq $runId -and
        ($config.virtualMachines[0].phase8ScopedHierarchyAction | ConvertTo-Json -Compress) -eq $markerBefore) `
        'Requested target recovery replaced the outstanding actor identity instead of preserving its preparation token.'
    $config.virtualMachines += [pscustomobject]@{ vmName = 'OTHER'; role = 'SiteSystem' }
    Assert-True (-not (Get-MemLabsScopedRoleRetryRunId -DeployConfig $config -VMNames @('OTHER')) -and
        ($config.virtualMachines[0].phase8ScopedHierarchyAction | ConvertTo-Json -Compress) -eq $markerBefore) `
        'An unrelated requested retry cleared another target''s outstanding action.'
    foreach ($case in @('EmptyMarker', 'MissingRun', 'EmptyGuid', 'WrongMachine', 'WrongLocalTarget')) {
        $resource.ScopedActionRequired = $true
        $resource.ScopedActionRunId = $runId
        $resource.ScopedActionOwnerVMName = 'EXISTING-PRI'
        $resource.ScopedActionTargetVMName = 'NEW1'
        $resource.MachineName = 'EXISTING-PRI'
        switch ($case) {
            EmptyMarker {
                $resource.ScopedActionRunId = ''
                $resource.ScopedActionOwnerVMName = ''
                $resource.ScopedActionTargetVMName = ''
            }
            MissingRun { $resource.ScopedActionRunId = '' }
            EmptyGuid { $resource.ScopedActionRunId = [guid]::Empty.ToString() }
            WrongMachine { $resource.MachineName = 'UNRELATED' }
            WrongLocalTarget { $resource.ScopedActionTargetVMName = 'UNRELATED' }
        }
        $failure = ''
        try { $null = $resource.Test() } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*Invalid scoped*identity*') "Malformed scoped metadata '$case' silently fell back to an old workflow receipt."
    }
}
finally {
    $env:SystemDrive = $previousDrive
    $env:COMPUTERNAME = $previousComputer
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}
$phaseSource = Get-Content -LiteralPath (Join-Path $root 'DSC\phases\Phase8.ps1') -Raw
$validationStart = $phaseSource.IndexOf('$compileVMNames =')
$validationEnd = $phaseSource.IndexOf('$DomainAdminName =', $validationStart)
if ($validationStart -lt 0 -or $validationEnd -le $validationStart) { throw 'Actual pre-declaration scoped metadata validation was not found.' }
$validation = [scriptblock]::Create($phaseSource.Substring($validationStart, $validationEnd - $validationStart))
foreach ($role in @('SiteSystem', 'DomainMember', 'WSUS')) {
    foreach ($case in @('Valid', 'Null', 'Empty', 'MissingOwner', 'EmptyOwner')) {
        $marker = [pscustomobject]@{ Kind = 'SiteRoles'; RunId = [guid]::NewGuid().ToString(); OwnerVMName = 'OWNER'; TargetVMName = 'TARGET' }
        switch ($case) {
            Null { $marker = $null }
            Empty { $marker = [pscustomobject]@{} }
            MissingOwner { $marker.PSObject.Properties.Remove('OwnerVMName') }
            EmptyOwner { $marker.OwnerVMName = '' }
        }
        $AllNodes = @(@{ NodeName = 'TARGET'; Role = $role }, @{ NodeName = '*' })
        $deployConfig = [pscustomobject]@{ virtualMachines = @(
                [pscustomobject]@{ vmName = 'TARGET'; role = $role; phase8ScopedHierarchyAction = $marker }
            ) }
        $failure = ''
        try { . $validation } catch { $failure = $_.Exception.Message }
        Assert-True ((-not $failure) -eq ($case -eq 'Valid')) `
            "Actual '$role' declaration accepted malformed '$case' metadata and could omit its required barrier."
    }
}
Write-Host "PASS -- $script:Assertions current-target scoped action receipt assertions on PowerShell $($PSVersionTable.PSVersion)."
