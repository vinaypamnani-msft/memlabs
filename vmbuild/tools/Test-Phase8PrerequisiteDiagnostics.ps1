<#
.SYNOPSIS
    Verifies Phase 8 prerequisites use physical compliance and emit failure evidence.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$templatePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$collectorPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Get-ClassMethodText {
    param([string] $Path, [string] $ClassName, [string] $MethodName)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $class = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq $ClassName
        }, $true) | Select-Object -First 1
    if (-not $class) { throw "Class '$ClassName' not found." }
    $method = $class.Members | Where-Object {
        $_ -is [Management.Automation.Language.FunctionMemberAst] -and $_.Name -eq $MethodName
    } | Select-Object -First 1
    if (-not $method) { throw "Method '$ClassName.$MethodName' not found." }
    return $method.Extent.Text
}

$adkTest = Get-ClassMethodText -Path $templatePath -ClassName 'InstallADK' -MethodName 'Test'
$reportBuilderTest = Get-ClassMethodText -Path $templatePath -ClassName 'InstallReportBuilder' -MethodName 'Test'
$collector = Get-Content -LiteralPath $collectorPath -Raw

foreach ($physicalPath in @('Deployment Tools', 'Windows Preinstallation Environment', 'User State Migration Tool')) {
    Assert-True ($adkTest.Contains($physicalPath)) "ADK compliance no longer verifies '$physicalPath'."
}
Assert-True ($adkTest -match 'ADK readiness:.+DeploymentTools=.+WinPE=.+USMT=.+Ready=') `
    'ADK compliance no longer logs a structured physical-readiness summary.'
Assert-True ($adkTest -match 'return \$ready') 'ADK compliance does not return its physical readiness decision.'

Assert-True ($reportBuilderTest -notmatch 'Test-Path.+\$this\.Path|Test-Path.+\$_path') `
    'Report Builder compliance still depends on the downloaded installer existing.'
Assert-True ($reportBuilderTest -match "ProductName='.+Version=.+ProductCode=.+Ready=True") `
    'Report Builder compliance no longer logs installed product identity/version.'
Assert-True ($reportBuilderTest -match 'installed product not found') `
    'Missing Report Builder no longer emits an actionable compliance message.'

foreach ($evidence in @(
        'PrerequisiteDiagnostics',
        'reportbuilder.log',
        'odbcinstallation.log',
        'msoledbsql.install.log',
        'PBI.log',
        'Windows\Logs\DISM\dism.log',
        'Windows\Logs\CBS\CBS.log',
        'ConfigMgrPrereq.log',
        'ValidWebServerCertificates',
        'PendingFileRenameOperations'
    )) {
    Assert-True ($collector.Contains($evidence)) "Phase 8 failure collection dropped prerequisite evidence '$evidence'."
}
Assert-True ($collector -match '(?s)PrereqArtifacts.+?BundleName') `
    'Prerequisite logs are not included in the bounded guest bundle.'
Assert-True ($collector -match 'Captured prerequisite state') `
    'Host does not materialize the structured prerequisite snapshot.'
Assert-True ($collector -match 'Pulled prerequisite diagnostic') `
    'Host does not materialize prerequisite installer logs.'

Write-Host 'PASS -- Phase 8 prerequisites use physical compliance and failures capture structured state plus bounded installer logs.'
