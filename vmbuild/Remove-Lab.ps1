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

# Validate Common.ps1 has UTF-8 BOM before dot-sourcing (PS5.1 needs BOM for non-ASCII chars)
$commonPath = Join-Path $PSScriptRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. PS5.1 will fail to parse non-ASCII characters." -ForegroundColor Red
    Write-Host "Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Yellow
    exit 1
}

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