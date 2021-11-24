[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ParameterSetName = "Domain")]
    [Parameter(Mandatory = $false, ParameterSetName = "InProgress")]
    [string] $DomainName,
    [Parameter(Mandatory = $true, ParameterSetName = "Orphaned")]
    [switch] $Orphaned,
    [Parameter(Mandatory = $true, ParameterSetName = "InProgress")]
    [switch] $InProgress,
    [Parameter(Mandatory = $true, ParameterSetName = "VmName")]
    [string] $VmName,
    [Parameter(Mandatory = $true, ParameterSetName = "All")]
    [switch] $All,
    [Parameter()]
    [switch] $WhatIf
)

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

# Set Verbose
$enableVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Dot source common
. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

if ($Orphaned.IsPresent) {
    Remove-Orphaned -WhatIf:$WhatIf
    return
}

if ($InProgress.IsPresent) {

    if ($DomainName) {
        Remove-InProgress -DomainName $DomainName -WhatIf:$WhatIf
    }
    else {
        Remove-InProgress -WhatIf:$WhatIf
    }
    return
}

if ($VmName) {
    Write-Log "Remove-Lab called for VM $VmName." -Activity -HostOnly
    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest) {
        Remove-VirtualMachine -VmName $VmName -WhatIf:$WhatIf
    }

    Write-Host
    return
}

if ($All.IsPresent) {
    Remove-All -WhatIf:$WhatIf
    return
}

if ($DomainName) {
    Remove-Domain -DomainName $DomainName -WhatIf:$WhatIf
    return
}