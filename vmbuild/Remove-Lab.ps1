#Remove-lab.ps1

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, ParameterSetName = "Domain")]
    [Parameter(Mandatory = $false, ParameterSetName = "InProgress")]
    [ArgumentCompleter({
        param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
        # Fast path: if Common.ps1 is already loaded and the VM list is cached,
        # use it directly. Otherwise, derive domain names from Hyper-V virtual
        # switch names (single WMI call) instead of loading the full module.
        if ($global:vm_List) {
            $domainlist = @($global:vm_List | Where-Object { $_.Domain } | Select-Object -ExpandProperty Domain -Unique | Sort-Object)
        }
        else {
            $domainlist = @(Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(Default Switch|intSwitch)$' } |
                Select-Object -ExpandProperty Name | Sort-Object)
        }
        return $domainlist | Where-Object { $_ -like "$WordToComplete*" }
    })]
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

# Dot source common — skip expensive init that removal doesn't need
# (env detection, maintenance, VM cache, host prep) but keep storage
# init so $Common.LocalAdmin is available for RDCMan file generation.
. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose -SkipMaintenanceRefresh -SkipVmCacheRefresh -SkipEnvironmentDetection -SkipHostPreparation

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
    Remove-VirtualMachine -VmName $VmName -WhatIf:$WhatIf
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