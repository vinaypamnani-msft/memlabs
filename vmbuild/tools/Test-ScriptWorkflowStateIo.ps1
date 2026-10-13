#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

function Import-TestFunction {
    param([string]$Name)
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $Name definition, found $($definition.Count)."
    }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Write-DscStatus {
    param($Status, [switch]$NoStatus)
    $script:Statuses.Add("$Status")
}

$script:Statuses = [System.Collections.Generic.List[string]]::new()
foreach ($functionName in @(
        'Invoke-WithScriptWorkflowJsonMutex',
        'Write-ScriptWorkflowJsonAtomic',
        'Read-ScriptWorkflowData',
        'Write-ScriptWorkFlowData'
    )) {
    . (Import-TestFunction -Name $functionName)
}

function New-WorkflowFixture {
    param([string]$Status)
    [pscustomobject]@{
        ScriptWorkflow = [pscustomobject]@{
            Status    = $Status
            StartTime = '2026-10-13 09:00:00'
            EndTime   = ''
        }
        UpgradeSCCM = [pscustomobject]@{
            Status    = $Status
            StartTime = '2026-10-13 09:00:00'
            EndTime   = ''
        }
    }
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) "memlabs-scriptworkflow-$PID"
$target = Join-Path $workDir 'ScriptWorkflow.json'
try {
    $null = New-Item -ItemType Directory -Path $workDir -Force

    Write-ScriptWorkFlowData -Configuration (New-WorkflowFixture -Status 'Running') -ConfigurationFile $target
    $running = Read-ScriptWorkflowData -ConfigurationFile $target -RequiredSteps @('ScriptWorkflow', 'UpgradeSCCM')
    if ($running.ScriptWorkflow.Status -ne 'Running') {
        throw 'Initial workflow state did not round-trip.'
    }

    $contentBefore = [IO.File]::ReadAllText($target)
    $blockedWriteThrew = $false
    $lock = [IO.File]::Open($target, 'Open', 'ReadWrite', 'None')
    try {
        Write-ScriptWorkflowJsonAtomic -Configuration (New-WorkflowFixture -Status 'Completed') `
            -ConfigurationFile $target -MaximumAttempts 2 -RetryMilliseconds 1
    }
    catch {
        $blockedWriteThrew = $_.Exception.Message -match 'Could not atomically persist ScriptWorkflow state'
    }
    finally {
        $lock.Dispose()
    }
    if (-not $blockedWriteThrew) {
        throw 'A blocked workflow replacement did not throw.'
    }
    if ([IO.File]::ReadAllText($target) -ne $contentBefore) {
        throw 'A blocked workflow replacement damaged the prior valid state.'
    }
    if (@(Get-ChildItem -LiteralPath $workDir -Force | Where-Object FullName -ne $target).Count -ne 0) {
        throw 'A blocked workflow replacement left a temp or backup file.'
    }

    [IO.File]::WriteAllText($target, '{ invalid json')
    $invalidReadThrew = $false
    try {
        $null = Read-ScriptWorkflowData -ConfigurationFile $target -MaximumAttempts 2 -RetryMilliseconds 1
    }
    catch {
        $invalidReadThrew = $_.Exception.Message -match 'Could not read valid ScriptWorkflow state'
    }
    if (-not $invalidReadThrew) {
        throw 'Invalid workflow JSON was accepted.'
    }
    if ($script:Statuses.Count -ne 1 -or $script:Statuses[0] -notmatch 'Read attempt 1/2 failed') {
        throw 'A transient workflow read failure did not record its bounded retry.'
    }
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- ScriptWorkflow state writes are atomic and reads fail with bounded diagnostics.'
