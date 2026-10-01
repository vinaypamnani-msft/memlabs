<#
.SYNOPSIS
    Verifies that multi-VM teardown powers off removable VMs concurrently before deletion.
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

function Get-FunctionAst {
    param([Parameter(Mandatory = $true)][string] $Name)

    $matches = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($matches.Count -ne 1) {
        throw "Expected one $Name function; found $($matches.Count)."
    }
    return $matches[0]
}

$bulkStopFunction = Get-FunctionAst -Name 'Stop-VirtualMachinesForRemoval'
Invoke-Expression $bulkStopFunction.Extent.Text

$script:Events = [System.Collections.Generic.List[string]]::new()
$script:StopCalls = [System.Collections.Generic.List[object]]::new()
$script:GetVMCalls = 0
$script:HyperVVMs = @(
    [pscustomobject]@{ Name = 'LINUX01'; State = 'Running' },
    [pscustomobject]@{ Name = 'WIN01'; State = 'Running' },
    [pscustomobject]@{ Name = 'OFF01'; State = 'Off' },
    [pscustomobject]@{ Name = 'FOREIGN01'; State = 'Running' }
)

function Write-Log {
    param(
        [Parameter(Position = 0)] [string] $Message,
        [switch] $Activity,
        [switch] $SubActivity,
        [switch] $Warning
    )
}

function Get-VM {
    [CmdletBinding()]
    param()

    $script:GetVMCalls++
    return $script:HyperVVMs
}

function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $VM)

    process {
        if ($VM.Name -ne 'LINUX01') {
            throw "Unexpected adapter lookup for $($VM.Name)."
        }
        [pscustomobject]@{
            IPAddresses = @('192.168.50.10', 'fe80::1', '169.254.10.20', '192.168.50.10')
        }
    }
}

function Stop-VM {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)] $VM,
        [switch] $TurnOff,
        [switch] $Force,
        [switch] $AsJob,
        [switch] $WhatIf
    )

    process {
        $script:Events.Add("stop:$($VM.Name)")
        $script:StopCalls.Add([pscustomobject]@{
                VMName  = $VM.Name
                TurnOff = $TurnOff.IsPresent
                Force   = $Force.IsPresent
                AsJob   = $AsJob.IsPresent
                WhatIf  = $WhatIf.IsPresent
            })
        if ($AsJob) {
            return [pscustomobject]@{
                State        = 'Completed'
                ChildJobs    = @()
                JobStateInfo = [pscustomobject]@{ Reason = [pscustomobject]@{ Message = $null } }
            }
        }
    }
}

function Wait-Job {
    [CmdletBinding()]
    param(
        [object[]] $Job,
        [int] $Timeout
    )

    $script:Events.Add("wait:$($Job.Count)")
    return $Job
}

function Stop-Job {
    [CmdletBinding()]
    param([object] $Job)
}

function Remove-CompletedHyperVJob {
    param([object] $Job, [string] $Context)
    $script:Events.Add("cleanup:$Context")
}

$records = @(
    [pscustomobject]@{ vmName = 'LINUX01'; role = 'Proxy'; osFamily = 'Linux'; vmBuild = $true },
    [pscustomobject]@{ vmName = 'WIN01'; role = 'Client'; osFamily = 'Windows'; vmBuild = $true },
    [pscustomobject]@{ vmName = 'OFF01'; role = 'Client'; osFamily = 'Windows'; vmBuild = $true },
    [pscustomobject]@{ vmName = 'FOREIGN01'; role = 'Client'; osFamily = 'Windows'; vmBuild = $false }
)
$capturedLinuxIPs = @{}

Stop-VirtualMachinesForRemoval -VMRecords $records -CapturedLinuxIPs $capturedLinuxIPs -TimeoutSeconds 5

if ($script:GetVMCalls -ne 1) {
    throw "Expected one Hyper-V enumeration; observed $script:GetVMCalls."
}

$stoppedNames = @($script:StopCalls | Select-Object -ExpandProperty VMName)
if (@($stoppedNames).Count -ne 2 -or 'LINUX01' -notin $stoppedNames -or 'WIN01' -notin $stoppedNames) {
    throw "Expected only LINUX01 and WIN01 to receive TurnOff requests; observed: $($stoppedNames -join ', ')."
}
if ('OFF01' -in $stoppedNames -or 'FOREIGN01' -in $stoppedNames) {
    throw 'The bulk phase tried to stop an already-off or non-removable VM.'
}
if (@($script:StopCalls | Where-Object { -not $_.TurnOff -or -not $_.Force -or -not $_.AsJob }).Count -gt 0) {
    throw 'A bulk power-off request was not submitted as a forced asynchronous TurnOff.'
}

$waitEvents = @($script:Events | Where-Object { $_ -like 'wait:*' })
if ($waitEvents.Count -ne 1 -or $waitEvents[0] -ne 'wait:2') {
    throw "Expected one wait over both jobs; observed: $($waitEvents -join ', ')."
}
$waitIndex = $script:Events.IndexOf('wait:2')
foreach ($name in @('LINUX01', 'WIN01')) {
    $stopIndex = $script:Events.IndexOf("stop:$name")
    if ($stopIndex -lt 0 -or $stopIndex -gt $waitIndex) {
        throw "The $name TurnOff request was not submitted before the shared wait."
    }
}

$captured = @($capturedLinuxIPs['LINUX01'])
if ($captured.Count -ne 1 -or $captured[0] -ne '192.168.50.10') {
    throw "Linux IP capture did not preserve only the usable IPv4 address: $($captured -join ', ')."
}

$script:Events.Clear()
$script:StopCalls.Clear()
$whatIfIPs = @{}
Stop-VirtualMachinesForRemoval -VMRecords $records -CapturedLinuxIPs $whatIfIPs -WhatIf
if (@($script:StopCalls | Where-Object { -not $_.WhatIf -or $_.AsJob }).Count -gt 0) {
    throw 'WhatIf submitted a real asynchronous TurnOff job.'
}
if (@($script:Events | Where-Object { $_ -like 'wait:*' }).Count -gt 0) {
    throw 'WhatIf waited for jobs even though it should not create any.'
}

foreach ($functionName in @('Remove-Domain', 'Remove-All')) {
    $functionAst = Get-FunctionAst -Name $functionName
    $commands = @($functionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true))
    $bulkCommand = $commands | Where-Object { $_.GetCommandName() -eq 'Stop-VirtualMachinesForRemoval' } | Select-Object -First 1
    $deleteCommandName = if ($functionName -eq 'Remove-Domain') { 'Start-NormalJobs' } else { 'Remove-VirtualMachine' }
    $deleteCommand = $commands | Where-Object { $_.GetCommandName() -eq $deleteCommandName } | Select-Object -First 1

    if (-not $bulkCommand -or -not $deleteCommand) {
        throw "$functionName does not contain both the bulk-stop and delete-dispatch commands."
    }
    if ($bulkCommand.Extent.StartOffset -gt $deleteCommand.Extent.StartOffset) {
        throw "$functionName dispatches deletion before its bulk power-off phase."
    }
}

Write-Host 'PASS -- multi-VM teardown submits every power-off before deletion and preserves Linux cleanup data.'
