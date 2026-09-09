<#
.SYNOPSIS
    Verifies fatal Hyper-V guest event matching for DSC recovery.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors | Where-Object { $null -ne $_ }).Count -ne 0) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

$sourcePath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
. (Import-TestFunction -Path $sourcePath -Name 'Get-DscFatalGuestEvents')

$now = [datetime]'2026-09-08T22:00:00Z'
$events = @(
    [pscustomobject]@{ Id = 18590; TimeCreated = $now.AddMinutes(-50).ToLocalTime(); Message = 'LPA-BDC1 unrecoverable processor error' }
    [pscustomobject]@{ Id = 18590; TimeCreated = $now.AddMinutes(-25); Message = 'LPA-BDC1 unrecoverable processor error' }
    [pscustomobject]@{ Id = 18590; TimeCreated = $now.AddMinutes(-20); Message = 'OTHER-VM unrecoverable processor error' }
    [pscustomobject]@{ Id = 99999; TimeCreated = $now.AddMinutes(-15); Message = 'LPA-BDC1 unrelated event' }
)
$script:CapturedFilter = $null
$eventQuery = {
    param($Filter)
    $script:CapturedFilter = $Filter
    $events
}

$unchangedEpisode = @(Get-DscFatalGuestEvents -VMName 'LPA-BDC1' -StartTime $now.AddMinutes(-60) -EventQuery $eventQuery)
Assert-Equal 2 $unchangedEpisode.Count 'events 25 minutes apart remain visible in one unchanged-status episode'
Assert-Equal 'Microsoft-Windows-Hyper-V-Worker-Admin' $script:CapturedFilter.LogName 'query uses the Hyper-V Worker Admin log'
Assert-Equal '18560,18590,18602' ($script:CapturedFilter.Id -join ',') 'query requests only fatal guest event IDs'
Assert-Equal $now.AddMinutes(-60).ToString('o') $script:CapturedFilter.StartTime.ToString('o') 'query starts at the last genuine DSC progress'

$afterProgress = @(Get-DscFatalGuestEvents -VMName 'LPA-BDC1' -StartTime $now.AddMinutes(-30) -EventQuery $eventQuery)
Assert-Equal 1 $afterProgress.Count 'genuine DSC progress resets prior fatal-event evidence'

$unrelatedOnly = @(Get-DscFatalGuestEvents -VMName 'MISSING-VM' -StartTime $now.AddMinutes(-60) -EventQuery $eventQuery)
Assert-Equal 0 $unrelatedOnly.Count 'events for other VMs do not trigger recovery failure'

$nameCollision = @(Get-DscFatalGuestEvents -VMName 'BDC1' -StartTime $now.AddMinutes(-60) -EventQuery $eventQuery)
Assert-Equal 0 $nameCollision.Count 'VM name substrings do not attribute another VM fatal event'

$queryFailure = @(Get-DscFatalGuestEvents -VMName 'LPA-BDC1' -StartTime $now.AddMinutes(-60) -EventQuery { throw 'event log unavailable' })
Assert-Equal 0 $queryFailure.Count 'event query failure falls through to bounded recovery'

if ($script:Failures -ne 0) { throw "$script:Failures DSC fatal guest event test(s) failed" }

Write-Host 'ALL DSC FATAL GUEST EVENT TESTS PASSED' -ForegroundColor Green