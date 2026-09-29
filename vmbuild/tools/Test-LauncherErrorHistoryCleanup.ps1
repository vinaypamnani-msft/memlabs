#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'common\Common.HyperV.ps1'
$commonPath = Join-Path $root 'Common.ps1'
$newLabPath = Join-Path $root 'New-Lab.ps1'
$startTestPath = Join-Path $root 'Start-Test.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s): $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $sourcePath -Name 'Invoke-HostMemoryReclaim')
. (Import-TestFunction -Path $commonPath -Name 'Remove-StaleLogBuffers')

$script:Failures = 0
$script:Messages = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Write-Log {
    param(
        [Parameter(Position = 0)]$Message,
        [switch]$LogOnly
    )
    $script:Messages.Add("$Message")
}

function Get-Counter {
    [pscustomobject]@{
        CounterSamples = @([pscustomobject]@{ CookedValue = 1024 })
    }
}

function Flush-LogBuffer {
    param(
        [string]$Path,
        [switch]$All
    )
}

function Add-MarkerErrors {
    param([int]$Count)

    1..$Count | ForEach-Object {
        try { Write-Error "launcher-memory-marker-$_" -ErrorAction Stop }
        catch { }
    }
}

function Test-MarkerPresent {
    return [bool](@($global:Error | ForEach-Object { "$($_.Exception.Message)" }) -match 'launcher-memory-marker-')
}

$global:Error.Clear()
Add-MarkerErrors -Count 3
$null = Invoke-HostMemoryReclaim -CurrentProcessOnly
Assert-True (Test-MarkerPresent) 'mid-run reclaim preserves ErrorRecord history by default'

$script:Messages.Clear()
$null = Invoke-HostMemoryReclaim -CurrentProcessOnly -ClearErrorHistory
Assert-True (-not (Test-MarkerPresent)) 'end-of-run reclaim releases retained ErrorRecords'
Assert-True ([bool]($script:Messages -match 'errorsCleared=3')) 'cleanup log records the exact ErrorRecord count released'

$newLabSource = [System.IO.File]::ReadAllText($newLabPath)
$startTestSource = [System.IO.File]::ReadAllText($startTestPath)
Assert-True ($newLabSource.Contains('[switch]$ClearErrorHistoryOnExit')) 'New-Lab exposes explicit long-lived-launcher opt-in'
Assert-True ($newLabSource.Contains('-ClearErrorHistory:$ClearErrorHistoryOnExit')) 'New-Lab preserves interactive error history by default'
Assert-True (([regex]::Matches($startTestSource, 'New-Lab\.ps1[^\r\n]*-ClearErrorHistoryOnExit')).Count -eq 2) 'Start-Test opts in on initial and DSC-restart deployments'

$activeLog = 'C:\temp\VMBuild.active.test.log'
$global:LogBuffers = @{
    $activeLog = [pscustomobject]@{ Builder = [System.Text.StringBuilder]::new(); LastFlushUtc = [datetime]::UtcNow }
    ([System.IO.Path]::ChangeExtension($activeLog, '.jsonl')) = [pscustomobject]@{ Builder = [System.Text.StringBuilder]::new(); LastFlushUtc = [datetime]::UtcNow }
    'C:\temp\VMBuild.old.test.log' = [pscustomobject]@{ Builder = [System.Text.StringBuilder]::new(); LastFlushUtc = [datetime]::UtcNow }
    'C:\temp\VMBuild.old.test.jsonl' = [pscustomobject]@{ Builder = [System.Text.StringBuilder]::new('retry me'); LastFlushUtc = [datetime]::UtcNow }
}
$removedBuffers = Remove-StaleLogBuffers -KeepPath $activeLog
Assert-True ($removedBuffers -eq 1) 'log-buffer cleanup removes flushed inactive paths'
Assert-True ($global:LogBuffers.ContainsKey($activeLog) -and
    $global:LogBuffers.ContainsKey([System.IO.Path]::ChangeExtension($activeLog, '.jsonl'))) 'log-buffer cleanup retains the active log/JSONL pair'
Assert-True ($global:LogBuffers.ContainsKey('C:\temp\VMBuild.old.test.jsonl')) 'log-buffer cleanup retains nonempty buffers for retry'

$global:Error.Clear()
if ($script:Failures -gt 0) {
    throw "$script:Failures launcher error-history cleanup test(s) failed."
}

Write-Host 'ALL LAUNCHER ERROR-HISTORY CLEANUP TESTS PASSED'
