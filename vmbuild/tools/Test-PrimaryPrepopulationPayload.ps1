<#
.SYNOPSIS
    Verifies idempotent repair of inherited Primary prepopulation payloads.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'AST-extracted production preflight consumes fixture variables dynamically.')]
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$downloadCachePath = Join-Path $RootPath 'common\Common.DownloadCache.ps1'
$scriptBlocksPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$repairDefinition = Import-TestFunction -Path $downloadCachePath -Name 'Repair-PrimaryPrepopulationPayload'
. $repairDefinition

$script:GuestState = @{ Baselines = $true; W11 = $true; W10 = $true }
$script:Mounted = [System.Collections.Generic.List[string]]::new()
$script:Dismounted = [System.Collections.Generic.List[string]]::new()
$script:CopiedOs = [System.Collections.Generic.List[string]]::new()
$script:BaselineCopies = 0
$script:BaselineStrict = $false
$script:StrictCalls = 0

function Get-TestPayloadState {
    $missing = @()
    if (-not $script:GuestState.W11) { $missing += 'Windows 11 24h2' }
    if (-not $script:GuestState.W10) { $missing += 'Windows 10 22h2' }
    [pscustomobject]@{
        BaselinesPresent = $script:GuestState.Baselines
        MissingOs        = [string[]]$missing
    }
}

function Invoke-VmCommand {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [switch]$RequireDomainIdentity,
        [switch]$AsJob,
        [int]$TimeoutSeconds,
        [string]$DisplayName,
        [scriptblock]$ScriptBlock,
        $ArgumentList
    )
    if ($RequireDomainIdentity) { $script:StrictCalls++ }
    if ($DisplayName -like 'Repair Primary OSD media*') {
        if ($DisplayName -match 'Windows 11') { $script:GuestState.W11 = $true; $script:CopiedOs.Add('Windows 11 24h2') }
        elseif ($DisplayName -match 'Windows 10') { $script:GuestState.W10 = $true; $script:CopiedOs.Add('Windows 10 22h2') }
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('copied'); ErrorDetails = @() }
    }
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(Get-TestPayloadState); ErrorDetails = @() }
}

function Copy-ItemSafe {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [string]$Path,
        [string]$Destination,
        [switch]$Recurse,
        [switch]$Container,
        [switch]$Force,
        [switch]$RequireDomainIdentity
    )
    if ($RequireDomainIdentity) { $script:StrictCalls++; $script:BaselineStrict = $true }
    $script:GuestState.Baselines = $true
    $script:BaselineCopies++
    return $true
}

function Mount-IsoOnVm {
    param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase)
    $script:Mounted.Add($IsoPath)
    return $true
}

function Confirm-IsoVisibleInGuest {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [string]$MarkerRelativePath,
        [string]$Context,
        [int]$TimeoutSeconds,
        [int]$Phase
    )
    return $true
}

function Dismount-IsoFromVm {
    param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase)
    $script:Dismounted.Add($IsoPath)
}

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Message,
        [switch]$Failure,
        [switch]$Warning,
        [switch]$Success,
        [switch]$OutputStream,
        [switch]$LogOnly
    )
}

function Write-Progress2 {
    param(
        [string]$Activity,
        [string]$Status,
        [switch]$Force,
        [switch]$Completed
    )
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-prepopulation-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'support') -Force
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'support\baselines.zip') -Force
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'w11.iso') -Force
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'w10.iso') -Force

try {
    $vm = [pscustomobject]@{ vmName = 'LAB-PRI'; role = 'Primary'; cmInstallDir = 'E:\ConfigMgr' }
    $fileList = [pscustomobject]@{
        OSISO = @(
            [pscustomobject]@{ id = 'Windows 11 24h2'; filename = 'w11.iso' },
            [pscustomobject]@{ id = 'Windows 10 22h2'; filename = 'w10.iso' }
        )
    }

    $healthy = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True $healthy 'Complete payload should pass.'
    Assert-True ($script:Mounted.Count -eq 0 -and $script:BaselineCopies -eq 0) 'Complete payload should be a no-op.'

    $script:GuestState = @{ Baselines = $false; W11 = $false; W10 = $true }
    $script:Mounted.Clear()
    $script:Dismounted.Clear()
    $script:CopiedOs.Clear()
    $script:BaselineCopies = 0
    $script:BaselineStrict = $false
    $repaired = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True $repaired 'Missing inherited payload should be repaired.'
    Assert-True ($script:BaselineCopies -eq 1) 'Missing baselines.zip should be copied once.'
    Assert-True $script:BaselineStrict 'Phase 8 baselines.zip copy should require domain identity.'
    Assert-True ($script:CopiedOs.Count -eq 1 -and $script:CopiedOs[0] -eq 'Windows 11 24h2') 'Only the missing OS media should be copied.'
    Assert-True ($script:Mounted.Count -eq 1 -and $script:Dismounted -contains $script:Mounted[0]) 'Repair ISO should be mounted and ejected.'
    Assert-True ($script:StrictCalls -gt 0) 'Phase 8 repair should require the domain identity.'

    $script:GuestState = @{ Baselines = $true; W11 = $true; W10 = $false }
    Remove-Item -LiteralPath (Join-Path $tempRoot 'w10.iso') -Force
    $missingHostMedia = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True (-not $missingHostMedia) 'Missing host ISO should fail the repair.'

    $source = Get-Content -LiteralPath $scriptBlocksPath -Raw
    Assert-True (($source | Select-String -Pattern 'Repair-PrimaryPrepopulationPayload' -AllMatches).Matches.Count -eq 1) `
        'VM creation should retain repair, but Phase 8 workers must not copy payloads after DC recovery starts.'
    Assert-True ($repairDefinition.ToString() -notmatch '-OutputStream') `
        'Prepopulation helper must not pollute its Boolean return with log output.'
    $failureSignals = @([regex]::Matches(
            $source,
            '(?s)if \(-not \$payloadReady\)\s*\{\s*Write-Log.+?-Failure -OutputStream\s*return'
        ))
    Assert-True ($failureSignals.Count -eq 1) `
        'VM creation must surface helper failure through its job output stream.'
    $diagnostics = (Get-Content -LiteralPath $perfloadingPath -Raw) + "`n" +
        (Get-Content -LiteralPath $validationPath -Raw)
    Assert-True ($diagnostics -notmatch 'rerun will NOT restore') `
        'OSD diagnostics should not claim Phase 8 reruns cannot repair inherited media.'
    Assert-True ($diagnostics -match 'Phase 8 host preflight') `
        'OSD diagnostics should direct operators to the Phase 8 host repair.'

    & {
        $phaseDefinition = Import-TestFunction -Path $phasesPath -Name 'Start-PhaseJobs'
        $preparationGates = @($phaseDefinition.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match '\bRepair-PrimaryPrepopulationPayload\b'
                }, $true))
        Assert-True ($preparationGates.Count -eq 1) 'Expected one Primary preparation preflight.'
        $dispatchCommands = @($phaseDefinition.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')
                }, $true))
        Assert-True ($dispatchCommands.Count -gt 0 -and
            -not @($dispatchCommands | Where-Object { $_.Extent.StartOffset -lt $preparationGates[0].Extent.EndOffset }).Count) `
            'Primary preparation must finish before any Phase 8 worker can be dispatched.'
        $preparationGate = [scriptblock]::Create(
            $preparationGates[0].Extent.Text + "`n`$script:PreflightDispatches++; return `$null")
        function Wait-ForVM {
            param($VmName, $PathToVerify, $VmDomainName)
            $script:PreflightConnections.Add([pscustomobject]@{ Name = $VmName; Domain = $VmDomainName })
            $script:PreflightConnectable
        }
        function Repair-PrimaryPrepopulationPayload {
            param($VirtualMachine, $VmDomainName, $AzureFileList, $AzureFilesPath, $Phase, [switch]$RequireDomainIdentity)
            Assert-True ($script:PreflightDispatches -eq 0) 'DSC dispatch raced Primary preparation.'
            $script:PreparationSeconds += 11 * 60
            Assert-True ($script:PreflightDispatches -eq 0) 'A preparation exceeding ten minutes exposed a DC recovery worker.'
            Assert-True ($RequireDomainIdentity -and $Phase -eq 8) 'Phase 8 preparation lost its domain-identity requirement.'
            $script:PreflightCopies.Add([pscustomobject]@{ Name = $VirtualMachine.vmName; Domain = $VmDomainName })
            if ($script:PreparationMode -eq 'throw') { throw 'Synthetic payload copy failure.' }
            $script:PreparationMode -ne 'false'
        }
        function Write-Log {
            param($Message, [switch]$Failure)
            if ($Failure) { $script:PreflightFailures.Add([string]$Message) }
        }
        $Phase = 8
        $Common = [pscustomobject]@{ AzureFileList = $fileList; AzureFilesPath = $tempRoot }
        $deployConfig = [pscustomobject]@{
            parameters = [pscustomobject]@{ DomainName = 'example.test' }
            cmOptions = [pscustomobject]@{ PrePopulateObjects = $true }
            virtualMachines = @(
                [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; hidden = $true; domain = 'child.example.test'; cmOptions = [pscustomobject]@{ PrePopulateObjects = $true } }
                [pscustomobject]@{ vmName = 'PRI2'; role = 'Primary'; cmOptions = [pscustomobject]@{ PrePopulateObjects = $false } }
                [pscustomobject]@{ vmName = 'PRI3'; role = 'Primary' }
                [pscustomobject]@{ vmName = 'OUTSIDE'; role = 'Primary' }
                [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember' }
            )
        }
        $ConfigurationData = [pscustomobject]@{
            AllNodes = @(
                [pscustomobject]@{ NodeName = '*'; Role = '' }
                [pscustomobject]@{ NodeName = 'PRI1'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'PRI2'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'PRI3'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'SQL1'; Role = 'SqlServer' }
            )
        }
        foreach ($case in @(
                @{ Mode = 'success'; Connected = $true; Expected = 'PRI1,PRI3'; Failed = $false },
                @{ Mode = 'false'; Connected = $true; Expected = 'PRI1'; Failed = $true },
                @{ Mode = 'throw'; Connected = $true; Expected = 'PRI1'; Failed = $true },
                @{ Mode = 'success'; Connected = $false; Expected = ''; Failed = $true },
                @{ Mode = 'success'; Connected = $true; Only = @('PRI3'); Expected = 'PRI3'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; Only = @('SQL1'); Expected = ''; Failed = $false },
                @{ Mode = 'success'; Connected = $true; RootDisabled = $true; Expected = 'PRI1'; Failed = $false }
            )) {
            $script:PreflightDispatches = 0
            $script:PreparationSeconds = 0
            $script:PreparationMode = $case.Mode
            $script:PreflightConnectable = $case.Connected
            $script:PreflightConnections = [Collections.Generic.List[object]]::new()
            $script:PreflightCopies = [Collections.Generic.List[object]]::new()
            $script:PreflightFailures = [Collections.Generic.List[string]]::new()
            $OnlyVMs = $case.Only
            $deployConfig.cmOptions.PrePopulateObjects = -not $case.RootDisabled
            $result = & $preparationGate
            Assert-True (($script:PreflightCopies.Name -join ',') -eq $case.Expected) 'Preparation ignored phase applicability, effective hierarchy options, or OnlyVMs.'
            if ($case.Failed) {
                Assert-True ($result.PreflightFailed -and $result.Failed -eq 1 -and $result.Jobs -eq 0 -and
                    $script:PreflightDispatches -eq 0 -and $script:PreflightFailures.Count -gt 0) `
                    'Failed preparation did not stop dispatch with an explicit phase failure.'
            }
            else {
                Assert-True ($null -eq $result -and $script:PreflightDispatches -eq 1) 'Successful preparation did not permit subsequent dispatch.'
            }
            foreach ($copy in $script:PreflightCopies) {
                $expectedDomain = if ($copy.Name -eq 'PRI1') { 'child.example.test' } else { 'example.test' }
                Assert-True ($copy.Domain -eq $expectedDomain) 'Preparation lost the Primary domain selection.'
                Assert-True ($script:PreparationSeconds -gt 10 * 60) 'The regression did not exercise a copy beyond the recovery threshold.'
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- inherited Primary prepopulation payloads are repaired and verified.'
