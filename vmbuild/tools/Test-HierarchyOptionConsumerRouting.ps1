<#
.SYNOPSIS
    Verifies VM-specific hierarchy options win at every mixed-hierarchy consumer.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'

function Import-FunctionDefinition {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-FunctionDefinition -Path $configPath -Name 'Test-PushClientRequested')
. (Import-FunctionDefinition -Path $configPath -Name 'Resolve-VmCmOptions')
. (Import-FunctionDefinition -Path $configPath -Name 'Set-VmCmOptionsResolved')
. (Import-FunctionDefinition -Path $configPath -Name 'Get-LabWsusUrl')
. (Import-FunctionDefinition -Path $phasePath -Name 'Get-Phase8ConfigurationData')

$mixedConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $false; PrePopulateObjects = $false }
    vmOptions = [pscustomobject]@{ domainName = 'mixed.test'; network = '10.0.0.0' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'MX-PRI'; role = 'Primary'; siteCode = 'PRI'; network = '10.0.1.0'
            cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $true; PrePopulateObjects = $true }
        },
        [pscustomobject]@{
            vmName = 'MX-WSUS'; role = 'WSUS'; siteCode = 'PRI'; installSUP = $false
        },
        [pscustomobject]@{
            vmName = 'MX-CLIENT'; role = 'DomainMember'; network = '10.0.1.0'; pushClient = 'PRI'
        }
    )
}

Set-VmCmOptionsResolved -Config $mixedConfig
foreach ($consumerName in @('MX-WSUS', 'MX-CLIENT')) {
    $consumer = $mixedConfig.virtualMachines | Where-Object vmName -eq $consumerName
    if (-not $consumer.cmOptions -or -not $consumer.cmOptions.UsePKI -or -not $consumer.cmOptions.Install) {
        throw "$consumerName did not inherit its owning hierarchy's cmOptions through the production stamping path."
    }
}

$wsus = Get-LabWsusUrl -DeployConfig $mixedConfig -CurrentItem $mixedConfig.virtualMachines[1]
if ($wsus.WsusUrl -ne 'https://MX-WSUS.mixed.test:8531') {
    throw "WSUS routing used root hierarchy PKI options instead of the VM options: $($wsus.WsusUrl)"
}

$global:preparePhasePercent = 0
$phaseData = Get-Phase8ConfigurationData -deployConfig $mixedConfig
if (-not $phaseData -or $phaseData.AllNodes.NodeName -notcontains 'MX-PRI') {
    throw 'Phase 8 excluded a VM whose hierarchy-local cmOptions.Install is true.'
}

$disabledConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $true; PrePopulateObjects = $true }
    vmOptions = [pscustomobject]@{ domainName = 'mixed.test'; network = '10.0.0.0' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'MX-OFF'; role = 'Primary'; siteCode = 'OFF'
            cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $false; PrePopulateObjects = $false }
        }
    )
}
$disabledPhaseData = Get-Phase8ConfigurationData -deployConfig $disabledConfig
if ($disabledPhaseData -and $disabledPhaseData.AllNodes.NodeName -contains 'MX-OFF') {
    throw 'Phase 8 included a VM whose hierarchy-local cmOptions.Install is false.'
}

$combinedConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $false; PrePopulateObjects = $false }
    vmOptions = [pscustomobject]@{ domainName = 'mixed.test'; network = '10.0.0.0' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'NEW-PRI'; role = 'Primary'; siteCode = 'NEW'
            cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $false; PrePopulateObjects = $false }
        },
        [pscustomobject]@{
            vmName = 'OLD-PRI'; role = 'Primary'; siteCode = 'OLD'; hidden = $true
            cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $true; PrePopulateObjects = $true }
        },
        [pscustomobject]@{
            vmName = 'OLD-SEC'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'OLD'; hidden = $true
        },
        [pscustomobject]@{
            vmName = 'OLD-CLIENT'; role = 'DomainMember'; pushClient = 'SEC'
        }
    )
}
Set-VmCmOptionsResolved -Config $combinedConfig
$combinedPhaseData = Get-Phase8ConfigurationData -deployConfig $combinedConfig
$combinedNames = @($combinedPhaseData.AllNodes.NodeName)
if ($combinedNames -notcontains 'NEW-PRI' -or $combinedNames -notcontains 'OLD-PRI') {
    throw "Mixed Phase 8 omitted install or maintenance hierarchy nodes: $($combinedNames -join ', ')"
}
if (@($combinedNames | Where-Object { $_ -eq '*' }).Count -ne 1) {
    throw "Mixed Phase 8 must emit exactly one wildcard DSC node: $($combinedNames -join ', ')"
}

$newOnlyConfig = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $false; PrePopulateObjects = $false }
    vmOptions = [pscustomobject]@{ domainName = 'mixed.test'; network = '10.0.0.0' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'NEW-PRI'; role = 'Primary'; siteCode = 'NEW'
            cmOptions = [pscustomobject]@{ Install = $true; UsePKI = $false; PrePopulateObjects = $false }
        },
        [pscustomobject]@{
            vmName = 'NEW-CLIENT'; role = 'DomainMember'; pushClient = 'NEW'
        },
        [pscustomobject]@{
            vmName = 'OLD-PRI'; role = 'Primary'; siteCode = 'OLD'; hidden = $true
            cmOptions = [pscustomobject]@{ Install = $false; UsePKI = $true; PrePopulateObjects = $true }
        }
    )
}
Set-VmCmOptionsResolved -Config $newOnlyConfig
$newOnlyPhaseData = Get-Phase8ConfigurationData -deployConfig $newOnlyConfig
$newOnlyNames = @($newOnlyPhaseData.AllNodes.NodeName)
if ($newOnlyNames -contains 'OLD-PRI') {
    throw "Phase 8 added unrelated hidden Primary OLD-PRI for a target owned by NEW-PRI: $($newOnlyNames -join ', ')"
}

$forbidden = @{
    'common\Common.GenConfig.ps1' = 'Get-CMBaselineVersion\s+-CMVersion\s+\$deployConfig\.cmOptions\.version'
    'common\Common.ScriptBlocks.ps1' = '\$deployConfig\.cmOptions\.(?:PrePopulateObjects|Install|UsePKI)'
    'common\Common.Validation.Functional.ps1' = '\$DeployConfig\.cmOptions\.UsePKI'
}
foreach ($relativePath in $forbidden.Keys) {
    $text = Get-Content -LiteralPath (Join-Path $RootPath $relativePath) -Raw
    if ($text -match $forbidden[$relativePath]) {
        throw "$relativePath still bypasses hierarchy-local cmOptions: $($Matches[0])"
    }
}

Write-Host 'PASS -- hierarchy-local version, install, prepopulation, WSUS, and PKI options win over root defaults.'
