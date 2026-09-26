#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s)." }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)." }
    [scriptblock]::Create($definition[0].Extent.Text)
}

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
. (Import-TestFunction -Path $validationPath -Name 'Get-MemLabsDistributionPointGroupValidationState')

$tokens = $null
$errors = $null
$validationAst = [Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$errors)
$helperDefinition = @($validationAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-MemLabsDistributionPointGroupValidationState'
        }, $true))
$helperCalls = @($validationAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-MemLabsDistributionPointGroupValidationState'
        }, $true))
function Get-EnclosingScriptBlockExpression {
    param($Node)

    for ($ancestor = $Node.Parent; $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $ancestor }
    }
    return $null
}
$helperScope = if ($helperDefinition.Count -eq 1) { Get-EnclosingScriptBlockExpression $helperDefinition[0] } else { $null }
$callScope = if ($helperCalls.Count -eq 1) { Get-EnclosingScriptBlockExpression $helperCalls[0] } else { $null }
Assert-Equal 1 $helperDefinition.Count 'validation helper has one production definition'
Assert-Equal 1 $helperCalls.Count 'validation helper has one production call site'
Assert-Equal $true ($null -ne $helperScope -and $null -ne $callScope -and $helperScope.Extent.StartOffset -eq $callScope.Extent.StartOffset) 'validation helper is defined inside the same remoted guest scriptblock that calls it'

$script:Groups = @()
$script:Members = @{}
$script:Filters = New-Object System.Collections.Generic.List[string]
function Get-WmiObject {
    param([string]$Namespace, [string]$Class, [string]$Filter, $ErrorAction)

    $script:Filters.Add("$Class|$Filter")
    if ($Class -eq 'SMS_DistributionPointGroup') { return $script:Groups }
    if ($Class -eq 'SMS_DPGroupMembers' -and $Filter -match "^GroupID='([^']+)'$") {
        return @($script:Members[$Matches[1]] | ForEach-Object {
                [pscustomobject]@{ DPNALPath = "[`"Display=\\$_`"]MSWNET:[`"SMS_SITE=ABC`"]\\$_\" }
            })
    }
}

$script:Groups = @(
    [pscustomobject]@{ GroupID = 'CAS-GROUP'; SourceSite = 'CAS' },
    [pscustomobject]@{ GroupID = 'PRI-GROUP'; SourceSite = 'PRI' }
)
$script:Members = @{
    'CAS-GROUP' = @('CASDP.memlabs.test')
    'PRI-GROUP' = @('PRIDP.memlabs.test')
}
$state = Get-MemLabsDistributionPointGroupValidationState -Namespace 'root\SMS\site_PRI' -SiteCode PRI -GroupName 'OSD DPS'
Assert-Equal 2 $state.GroupCount 'duplicate group rows are retained for validation'
Assert-Equal 1 $state.LocalGroupCount 'local SourceSite count is reported'
Assert-Equal 'CASDP.memlabs.test,PRIDP.memlabs.test' (@($state.MemberNames | Sort-Object) -join ',') 'validation unions membership from every exact GroupID'
Assert-Equal 1 @($script:Filters | Where-Object { $_ -eq "SMS_DPGroupMembers|GroupID='CAS-GROUP'" }).Count 'CAS membership uses its exact GroupID filter'
Assert-Equal 1 @($script:Filters | Where-Object { $_ -eq "SMS_DPGroupMembers|GroupID='PRI-GROUP'" }).Count 'Primary membership uses its exact GroupID filter'

$script:Groups = @()
$script:Members = @{}
$state = Get-MemLabsDistributionPointGroupValidationState -Namespace 'root\SMS\site_PRI' -SiteCode PRI -GroupName 'OSD DPS'
Assert-Equal 0 $state.GroupCount 'missing group returns an explicit empty state'
Assert-Equal 0 $state.MemberNames.Count 'missing group has no inferred members'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All functional DP-group resolution checks passed.'
