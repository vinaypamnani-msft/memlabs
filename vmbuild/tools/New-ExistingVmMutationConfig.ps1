<#
.SYNOPSIS
    Materializes a declarative existing-VM mutation as a normal MemLabs config.
.DESCRIPTION
    Used by the main-to-develop runner after an exact-main baseline exists.
    Reads authoritative live VM notes through the pinned develop worktree,
    reconstructs the existing-domain GenConfig model, applies only supported
    existing-VM properties, and emits the same hidden-VM shape GenConfig saves.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ManifestPath,
    [Parameter(Mandatory = $true)]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

function Set-MemLabsExistingVmMutation {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Vm,
        [Parameter(Mandatory = $true)]
        [object] $Changes,
        [Parameter(Mandatory = $true)]
        [string[]] $AllowedProperties
    )

    $changeProperties = @($Changes.PSObject.Properties)
    if ($changeProperties.Count -eq 0) { throw "Mutation for '$($Vm.vmName)' contains no changes." }
    foreach ($change in $changeProperties) {
        $propertyName = $AllowedProperties | Where-Object { $_ -ieq $change.Name } | Select-Object -First 1
        if (-not $propertyName) {
            throw "Mutation property '$($change.Name)' is not supported for existing VMs."
        }
        $currentProperty = $Vm.PSObject.Properties[$propertyName]
        $currentValue = if ($currentProperty) { $currentProperty.Value } else { $null }
        $originalName = "$propertyName-Original"
        if (-not $Vm.PSObject.Properties[$originalName]) {
            $Vm | Add-Member -NotePropertyName $originalName -NotePropertyValue $currentValue -Force
        }
        $Vm | Add-Member -NotePropertyName $propertyName -NotePropertyValue $change.Value -Force
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Mutation manifest not found: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if ([int]$manifest.existingVmMutationVersion -ne 1) {
    throw "Unsupported existingVmMutationVersion '$($manifest.existingVmMutationVersion)' in '$ManifestPath'."
}
$domainName = "$($manifest.vmOptions.domainName)".Trim()
if (-not $domainName) { throw "Mutation manifest '$ManifestPath' has no vmOptions.domainName." }
$targets = @($manifest.virtualMachines)
if ($targets.Count -eq 0) { throw "Mutation manifest '$ManifestPath' contains no target VMs." }

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $vmbuildRoot 'Common.ps1')

$inventory = @(Get-List -Type VM -DomainName $domainName -SmartUpdate)
if ($inventory.Count -eq 0) { throw "No existing VMs were found for domain '$domainName'." }
$defaultNetwork = "$($manifest.vmOptions.network)".Trim()
if (-not $defaultNetwork) {
    $defaultNetwork = "$(($inventory | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1).network)".Trim()
}
if (-not $defaultNetwork) { throw "Could not resolve an existing-domain network for '$domainName'." }

$config = New-UserConfig -Domain $domainName -Subnet $defaultNetwork
$allowedProperties = @($Common.Supported.UpdatablePropList)
if ($allowedProperties.Count -eq 0) { throw 'Supported existing-VM mutation properties were not initialized.' }

foreach ($target in $targets) {
    $requestedName = "$($target.vmName)".Trim()
    if (-not $requestedName) { throw 'Mutation target is missing vmName.' }
    $fullName = if ($requestedName.StartsWith("$($config.vmOptions.prefix)", [StringComparison]::OrdinalIgnoreCase)) {
        $requestedName
    }
    else {
        "$($config.vmOptions.prefix)$requestedName"
    }
    $matches = @($inventory | Where-Object {
            $_.vmName -ieq $requestedName -or $_.vmName -ieq $fullName
        })
    if ($matches.Count -ne 1) {
        throw "Mutation target '$requestedName' resolved to $($matches.Count) existing VMs in '$domainName'."
    }
    if ($target.role -and "$($matches[0].role)" -ine "$($target.role)") {
        throw "Mutation target '$($matches[0].vmName)' has role '$($matches[0].role)', expected '$($target.role)'."
    }
    if (-not $target.changes) { throw "Mutation target '$requestedName' has no changes object." }

    $mutableVm = $matches[0] | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
    Set-MemLabsExistingVmMutation -Vm $mutableVm -Changes $target.changes -AllowedProperties $allowedProperties
    Add-ModifiedExistingVMToDeployConfig -Vm $mutableVm -ConfigToModify $config -Hidden $true
}

if (@($config.virtualMachines).Count -ne $targets.Count) {
    throw "Expected $($targets.Count) materialized mutation target(s), produced $(@($config.virtualMachines).Count)."
}
$outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Mutation output directory does not exist: $outputDirectory"
}
Write-ConfigJsonFile -Config $config -Path $OutputPath
$null = Get-Content -LiteralPath $OutputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
Write-Host "PASS: materialized $($targets.Count) existing-VM mutation target(s) for '$domainName' -> $OutputPath"
