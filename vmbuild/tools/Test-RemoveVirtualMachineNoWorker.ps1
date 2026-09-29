<#
.SYNOPSIS
    Verifies that teardown treats an absent Hyper-V worker as safe for removal.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$removePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Remove.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($removePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Remove.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$waitFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Wait-VMStopped'
        }, $true))
if ($waitFunctions.Count -ne 1) {
    throw "Expected one Wait-VMStopped function; found $($waitFunctions.Count)."
}

# The production type annotation is irrelevant to this isolated control-flow test.
$waitFunctionText = $waitFunctions[0].Extent.Text -replace '\[Microsoft\.HyperV\.PowerShell\.VirtualMachine\]\s+\$VM', '[object] $VM'
Invoke-Expression $waitFunctionText

$script:RemoveLogs = [System.Collections.Generic.List[object]]::new()
function Write-Log {
    param(
        [Parameter(Position = 0)] [string] $Message,
        [switch] $SubActivity,
        [switch] $LogOnly,
        [switch] $Warning
    )
    $script:RemoveLogs.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}

function Stop-VM {
    param(
        [Parameter(ValueFromPipeline)] $VM,
        [switch] $TurnOff,
        [switch] $Force,
        [switch] $AsJob,
        $WarningAction
    )
    process {
        [pscustomobject]@{
            State        = 'Running'
            ChildJobs    = @()
            JobStateInfo = [pscustomobject]@{ Reason = [pscustomobject]@{ Message = $null } }
        }
    }
}

function Wait-Job {
    param([Parameter(ValueFromPipeline)] $Job, [int] $Timeout)
    process { $Job }
}

function Stop-Job {
    param($Job, $ErrorAction)
}

function Remove-CompletedHyperVJob {
    param($Job, [string] $Context)
}

function Get-CimInstance {
    param([string] $ClassName, [string] $Filter, $ErrorAction)
    if ($script:CimQueryFails) { throw 'synthetic process-enumeration failure' }
    return $null
}

$script:CimQueryFails = $false
$vm = [pscustomobject]@{ Name = 'TEST-VM'; State = 'Running'; Id = [guid]::NewGuid() }
$stopped = Wait-VMStopped -VM $vm -TimeoutSeconds 1

if (-not $stopped) {
    throw 'Wait-VMStopped rejected a VM after confirming that no worker process remained.'
}
if (@($script:RemoveLogs | Where-Object Message -like '*could not be forced Off*').Count -ne 0) {
    throw 'Wait-VMStopped emitted the stale terminal failure after confirming that no worker remained.'
}

$script:RemoveLogs.Clear()
$script:CimQueryFails = $true
$stopped = Wait-VMStopped -VM $vm -TimeoutSeconds 1
if ($stopped) {
    throw 'Wait-VMStopped treated a failed worker-process query as proof that no worker remained.'
}
if (@($script:RemoveLogs | Where-Object { $_.Warning -and $_.Message -like '*worker-process enumeration/escalation failed*' }).Count -ne 1) {
    throw 'A worker-process query failure did not retain an actionable warning.'
}

Write-Host 'PASS -- an absent vmwp process is accepted as safe for removal.'
