#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $RootPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath))
}

$script:Failures = [Collections.Generic.List[string]]::new()
function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    if ("$Expected" -ne "$Actual") {
        $script:Failures.Add("$Name -- expected '$Expected', got '$Actual'")
    }
    else { Write-Host "  PASS: $Name" -ForegroundColor Green }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $functionAst = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Function '$Name' not found in $Path" }
    return [scriptblock]::Create($functionAst.Extent.Text)
}

$newLabPath = Join-Path $RootPath 'vmbuild\New-Lab.ps1'
$configPath = Join-Path $RootPath 'vmbuild\common\Common.Config.ps1'
. (Import-TestFunction -Path $newLabPath -Name 'Initialize-NewLabHyperVPrerequisite')
. (Import-TestFunction -Path $configPath -Name 'Start-VMIPRefreshJob')

$script:VmmsPresent = $true
$script:HyperVCmdletsPresent = $true
$script:PromptResponse = 'y'
$script:PromptCount = 0
$script:InstallCount = 0
$script:StartJobCount = 0
$script:InstallFailure = $null
$script:LogMessages = @()

function Get-Service {
    param([string] $Name)
    if ($Name -eq 'vmms' -and $script:VmmsPresent) { return [pscustomobject]@{ Name = 'vmms' } }
    return $null
}
function Get-Command {
    param([string] $Name, [string] $Module)
    if ($Name -eq 'Start-ThreadJob') { return [pscustomobject]@{ Name = $Name } }
    if ($Name -in @('Get-VM', 'Get-VMNetworkAdapter') -and $script:HyperVCmdletsPresent) {
        return [pscustomobject]@{ Name = $Name; ModuleName = $Module }
    }
    return $null
}
function Read-YesOrNoWithTimeout {
    $script:PromptCount++
    return $script:PromptResponse
}
function Install-HyperV {
    $script:InstallCount++
    if ($script:InstallFailure) { throw $script:InstallFailure }
}
function Write-Log {
    param($Message, [switch] $LogOnly, [switch] $Failure)
    $script:LogMessages += [pscustomobject]@{ Message = "$Message"; Failure = $Failure.IsPresent }
}
function Flush-LogBuffer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Test double must match the production helper name.')]
    param([switch] $All)
}
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)] $Remaining) }
function Start-ThreadJob { $script:StartJobCount++; throw 'Start-ThreadJob must not run when Hyper-V cmdlets are missing.' }

$readyResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $readyResult 'ready host passes prerequisite check'
Assert-Equal 0 $script:PromptCount 'ready host is not prompted'
Assert-Equal 1 $script:InstallCount 'ready host still verifies Hyper-V service readiness'

$script:VmmsPresent = $false
$script:HyperVCmdletsPresent = $false
$script:PromptResponse = 'y'
$acceptedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $acceptedResult 'accepted missing prerequisite runs installer'
Assert-Equal 1 $script:PromptCount 'missing prerequisite prompts once'
Assert-Equal 2 $script:InstallCount 'accepted prompt invokes installer'

$script:PromptResponse = 'n'
$declinedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $declinedResult 'declined prerequisite stops startup'
Assert-Equal 2 $script:PromptCount 'declined prerequisite prompts once more'
Assert-Equal 2 $script:InstallCount 'declined prerequisite does not invoke installer'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*installation was declined*' })) 'decline is logged as failure'

$script:PromptResponse = 'y'
$script:InstallFailure = 'simulated install failure'
$failedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $failedResult 'installer failure stops startup'
Assert-Equal 3 $script:InstallCount 'installer failure was exercised'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*simulated install failure*' })) 'installer failure is logged'

$global:Common = [pscustomobject]@{ InJob = $false; CachePath = $env:TEMP }
$script:InstallFailure = $null
$script:HyperVCmdletsPresent = $false
Start-VMIPRefreshJob
Assert-Equal 0 $script:StartJobCount 'VM IP refresh stays dormant without Hyper-V cmdlets'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Message -like '*Hyper-V cmdlets are unavailable*' })) 'VM IP refresh explains why it was skipped'

$newLabTokens = $null
$newLabErrors = $null
$newLabAst = [Management.Automation.Language.Parser]::ParseFile($newLabPath, [ref] $newLabTokens, [ref] $newLabErrors)
if ($newLabErrors) { throw "Could not parse ${newLabPath}: $($newLabErrors[0].Message)" }
$topLevelCommands = @($newLabAst.EndBlock.Statements | ForEach-Object {
        $_.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
    })
$prerequisiteCall = @($topLevelCommands | Where-Object { $_.GetCommandName() -eq 'Initialize-NewLabHyperVPrerequisite' })
$networkCall = @($topLevelCommands | Where-Object { $_.GetCommandName() -eq 'Test-NoRRAS' })
Assert-Equal 1 $prerequisiteCall.Count 'New-Lab has one prerequisite call'
Assert-Equal 1 $networkCall.Count 'New-Lab has one NAT validation call'
if ($prerequisiteCall.Count -eq 1 -and $networkCall.Count -eq 1) {
    Assert-Equal $true ($prerequisiteCall[0].Extent.StartOffset -lt $networkCall[0].Extent.StartOffset) 'prerequisite check precedes NAT validation'
}

if ($script:Failures.Count -gt 0) {
    Write-Host "FAIL: Test-NewLabHostPrerequisites ($($script:Failures.Count) failure(s))" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'PASS: Test-NewLabHostPrerequisites' -ForegroundColor Green
exit 0