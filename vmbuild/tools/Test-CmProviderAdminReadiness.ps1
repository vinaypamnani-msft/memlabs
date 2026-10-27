<#
.SYNOPSIS
    Verifies Phase 8 grants the validation account local SMS Provider access.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Ensure-CmProviderLocalAdminMembership'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Ensure-CmProviderLocalAdminMembership definition; found $($definitions.Count)."
}
Invoke-Expression $definitions[0].Extent.Text

$script:MemberPresent = $false
$script:AddCalls = 0
$script:SleepCalls = 0
function Get-LocalGroup {
    param([string]$Name, $ErrorAction)
    [pscustomobject]@{ Name = $Name }
}
function Get-LocalGroupMember {
    param([string]$Group, $ErrorAction)
    if ($script:MemberPresent) {
        [pscustomobject]@{ Name = 'CSTEST1\vmbuildadmin' }
    }
}
function Add-LocalGroupMember {
    param([string]$Group, [string]$Member, $ErrorAction)
    $script:AddCalls++
    $script:MemberPresent = $true
}
function Start-Sleep {
    param([int]$Seconds)
    $script:SleepCalls++
}
function Write-DscStatus {
    param([string]$Message, [switch]$Failure)
}

$added = Ensure-CmProviderLocalAdminMembership -AccountName 'CSTEST1\vmbuildadmin' -Attempts 3 -RetrySeconds 1
if (-not $added -or $script:AddCalls -ne 1 -or $script:SleepCalls -ne 1) {
    throw "Missing SMS Admins membership was not added and verified: added=$added addCalls=$script:AddCalls sleepCalls=$script:SleepCalls."
}

$script:AddCalls = 0
$script:SleepCalls = 0
$existing = Ensure-CmProviderLocalAdminMembership -AccountName 'CSTEST1\vmbuildadmin' -Attempts 3 -RetrySeconds 1
if (-not $existing -or $script:AddCalls -ne 0 -or $script:SleepCalls -ne 0) {
    throw "Existing SMS Admins membership was not a fast no-op: existing=$existing addCalls=$script:AddCalls sleepCalls=$script:SleepCalls."
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
if ($sourceText -notmatch 'Ensure-CmProviderLocalAdminMembership -AccountName \$domainUserName') {
    throw 'InstallAndUpdateSCCM does not enforce local SMS Admins membership for vmbuildadmin.'
}
if ($sourceText -notmatch "Phase 11 provider queries would run with no local provider authorization") {
    throw 'InstallAndUpdateSCCM does not fail explicitly when local provider authorization cannot be established.'
}

Write-Host 'PASS -- Phase 8 ensures vmbuildadmin has local SMS Provider authorization.'
