<#
.SYNOPSIS
    Verifies that VM teardown distinguishes confirmed absence from Hyper-V lookup failures.
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

    $functionAsts = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($functionAsts.Count -ne 1) {
        throw "Expected one $Name function; found $($functionAsts.Count)."
    }
    return $functionAsts[0]
}

foreach ($functionName in @('Get-VirtualMachineForRemoval', 'Get-DomainHyperVVM')) {
    Invoke-Expression (Get-FunctionAst -Name $functionName).Extent.Text
}

$script:EnumeratedVMs = @()
$script:VMsById = @{}
$script:VMQueryMode = 'Normal'

function Get-VM {
    [CmdletBinding(DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'ById')]
        [guid] $Id,
        [Parameter(ParameterSetName = 'ByName')]
        [string[]] $Name
    )

    if ($script:VMQueryMode -eq 'TransientFailure') {
        throw [System.InvalidOperationException]::new('synthetic VMMS query failure')
    }
    if ($script:VMQueryMode -eq 'EmptyWithoutError') {
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $key = $Id.ToString()
        if ($script:VMsById.ContainsKey($key)) {
            return $script:VMsById[$key]
        }
        Write-Error -Message "Synthetic VM '$Id' was not found." -Category ObjectNotFound `
            -ErrorId 'ObjectNotFound,Microsoft.HyperV.PowerShell.Commands.GetVM'
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $nameMatches = @($script:EnumeratedVMs | Where-Object { $_.Name -in $Name })
        if ($nameMatches.Count -eq 0) {
            Write-Error -Message "Synthetic VM '$($Name -join ', ')' was not found." -Category InvalidArgument `
                -ErrorId 'InvalidParameter,Microsoft.HyperV.PowerShell.Commands.GetVM'
            return
        }
        return $nameMatches
    }

    return $script:EnumeratedVMs
}

$targetId = [guid]::NewGuid()
$targetRecord = [pscustomobject]@{ vmName = 'TARGET01'; vmID = $targetId }
$targetVm = [pscustomobject]@{
    Name  = 'TARGET01'
    VMId  = $targetId
    Id    = $targetId
    Path  = $null
    Notes = $null
    State = 'Off'
}

$script:VMsById[$targetId.ToString()] = $targetVm
$resolved = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName -VmRecord $targetRecord
if (-not $resolved -or $resolved.VMId -ne $targetId) {
    throw 'An existing VM was not resolved by its authoritative VM id.'
}

$script:EnumeratedVMs = @($targetVm)
$resolved = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName
if (-not $resolved -or $resolved.VMId -ne $targetId) {
    throw 'An existing VM was not resolved by name when no inventory record was available.'
}

$threw = $false
try {
    $null = Get-VirtualMachineForRemoval -VmName 'OTHER01' -VmRecord $targetRecord
}
catch {
    $threw = $_.Exception.Message -like '*does not match removal target*'
}
if (-not $threw) {
    throw 'A mismatched VM record was allowed to resolve a different removal target.'
}

$script:EnumeratedVMs = @()
$resolved = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName
if ($resolved) {
    throw 'A confirmed missing-name result was not treated as an absent VM.'
}

$script:VMsById.Clear()
$resolved = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName -VmRecord $targetRecord
if ($resolved) {
    throw 'A confirmed ObjectNotFound result was not treated as an absent VM.'
}

$script:VMQueryMode = 'TransientFailure'
$threw = $false
try {
    $null = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName -VmRecord $targetRecord
}
catch {
    $threw = $_.Exception.Message -like '*Could not query Hyper-V*'
}
if (-not $threw) {
    throw 'A transient Hyper-V query failure was incorrectly treated as VM absence.'
}

$script:VMQueryMode = 'EmptyWithoutError'
$threw = $false
try {
    $null = Get-VirtualMachineForRemoval -VmName $targetRecord.vmName -VmRecord $targetRecord
}
catch {
    $threw = $_.Exception.Message -like '*absence is unconfirmed*'
}
if (-not $threw) {
    throw 'An empty Hyper-V result without a not-found error was incorrectly treated as VM absence.'
}

$script:VMQueryMode = 'Normal'
$script:EnumeratedVMs = @($targetVm)
$survivors = @(Get-DomainHyperVVM -DomainName 'example.test' -ExpectedVMRecords @($targetRecord))
if ($survivors.Count -ne 1 -or $survivors[0].VMId -ne $targetId) {
    throw 'Domain verification ignored a known target whose transitional VM object lacked Path and Notes.'
}

$script:EnumeratedVMs = @()
$script:VMsById[$targetId.ToString()] = $targetVm
$survivors = @(Get-DomainHyperVVM -DomainName 'example.test' -ExpectedVMRecords @($targetRecord))
if ($survivors.Count -ne 1 -or $survivors[0].VMId -ne $targetId) {
    throw 'Domain verification trusted an empty bulk enumeration without probing the expected VM id.'
}

$script:VMsById.Clear()
$survivors = @(Get-DomainHyperVVM -DomainName 'example.test' -ExpectedVMRecords @($targetRecord))
if ($survivors.Count -ne 0) {
    throw 'Domain verification reported a VM after both bulk and exact-id lookups confirmed it absent.'
}

$removeVirtualMachineAst = Get-FunctionAst -Name 'Remove-VirtualMachine'
$removeLookupCommands = @($removeVirtualMachineAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-VirtualMachineForRemoval'
        }, $true))
if ($removeLookupCommands.Count -ne 1) {
    throw 'Remove-VirtualMachine does not use the strict removal lookup exactly once.'
}

$removeDomainAst = Get-FunctionAst -Name 'Remove-Domain'
$domainVerificationCommands = @($removeDomainAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-DomainHyperVVM'
        }, $true))
if ($domainVerificationCommands.Count -ne 3) {
    throw "Expected three Remove-Domain verification calls; found $($domainVerificationCommands.Count)."
}
foreach ($command in $domainVerificationCommands) {
    $parameterNames = @($command.CommandElements |
        Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
        ForEach-Object { $_.ParameterName })
    if ('ExpectedVMRecords' -notin $parameterNames) {
        throw 'A Remove-Domain verification call does not include the original VM records.'
    }
}

Write-Host 'PASS -- teardown requires confirmed VM absence and verifies original VM identities.'
