########################
### Config Functions ###
########################

function Get-UserConfiguration {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Configuration Name/File")]
        [string]$Configuration
    )

    $return = [PSCustomObject]@{
        Loaded  = $false
        Config  = $null
        Message = $null
    }

    # Add extension
    if (-not $Configuration.EndsWith(".json")) {
        $Configuration = "$Configuration.json"
    }

    # Get deployment configuration
    $configPath = Join-Path $Common.ConfigPath $Configuration
    if (-not (Test-Path $configPath)) {
        $sampleConfigPath = Join-Path $Common.ConfigPath "samples\$Configuration"
        if (-not (Test-Path $sampleConfigPath)) {
            $return.Message = "Get-UserConfiguration: $Configuration not found in $configPath or $sampleConfigPath. Please create the config manually or use genconfig.ps1, and try again."
            return $return
        }
        $configPath = $sampleConfigPath
    }

    try {
        Write-Log "Get-UserConfiguration: Loading $configPath." -LogOnly
        $config = Get-Content $configPath -Force | ConvertFrom-Json
        $return.Loaded = $true
        $return.Config = $config
        return $return
    }
    catch {
        $return.Message = "Get-UserConfiguration: Failed to load $configPath. $_"
        return $return
    }

}

# function Get-Files {

#     param (
#         [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile", HelpMessage = "Configuration Name for which to download the files.")]
#         [string]$Configuration,
#         [Parameter(Mandatory = $false, ParameterSetName = "GetAll", HelpMessage = "Get all files.")]
#         [switch]$DownloadAll,
#         [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the image, if it exists.")]
#         [switch]$Force,
#         [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
#         [switch]$WhatIf
#     )

#     # Validate token exists
#     if ($Common.FatalError) {
#         Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
#         return
#     }

#     Write-Host

#     if ($Configuration) {
#         $success = Get-FilesForConfiguration -Configuration $Configuration -Force:$Force -WhatIf:$WhatIf
#     }

#     if ($DownloadAll) {
#         $success = Get-FilesForConfiguration -DownloadAll -Force:$Force -WhatIf:$WhatIf
#     }

#     return $success
# }

function Get-FilesForConfiguration {
    param (
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile", HelpMessage = "Configuration Name for which to download the files.")]
        [string]$Configuration,
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigObject", HelpMessage = "Configuration Object for which to download the files.")]
        [object]$InputObject,
        [Parameter(Mandatory = $false, ParameterSetName = "All", HelpMessage = "Get all files.")]
        [switch]$DownloadAll,
        [Parameter(Mandatory = $false, HelpMessage = "Skip Hash Testing of downloaded files.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the image, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    # Load config file
    if ($Configuration -and -not $DownloadAll) {
        $result = Get-UserConfiguration -Configuration $Configuration
        if ($result.Loaded) {
            $config = $result.Config
        }
    }

    # Config object
    if ($InputObject) {
        $config = $InputObject
    }

    # Get unique items from config
    if ($config) {
        $operatingSystemsToGet = $config.virtualMachines.operatingSystem | Select-Object -Unique
        $sqlVersionsToGet = $config.virtualMachines.sqlVersion | Select-Object -Unique
    }

    Write-Log "Get-FilesForConfiguration: Downloading/Verifying Files required by specified config..." -Activity

    $allSuccess = $true

    foreach ($file in $Common.AzureFileList.OS) {

        if ($file.id -eq "vmbuildadmin") { continue }
        if (-not $DownloadAll -and $operatingSystemsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            $allSuccess = $false
        }
    }

    foreach ($file in $Common.AzureFileList.ISO) {
        if (-not $DownloadAll -and $sqlVersionsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            $allSuccess = $false
        }
    }

    return $allSuccess
}

function Add-ValidationMessage {
    param (
        [string]$Message,
        [object]$ReturnObject,
        [switch]$Failure,
        [switch]$Warning
    )

    $ReturnObject.Problems += 1
    [void]$ReturnObject.Message.AppendLine($Message)

    if ($Failure.IsPresent) {
        $ReturnObject.Failures += 1
    }

    if ($Warning.IsPresent) {
        $ReturnObject.Warnings += 1
    }
}

function Test-ValidVmOptions {
    param (
        [object]
        $ConfigObject,
        [object]
        $ReturnObject
    )

    # prefix
    if (-not $ConfigObject.vmOptions.prefix) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.prefix not present in vmOptions. You must specify the prefix that will be added to name of Virtual Machine(s)." -ReturnObject $ReturnObject -Failure
    }

    # basePath
    if (-not $ConfigObject.vmOptions.basePath) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath not present in vmOptions. You must specify the base path where the Virtual Machines will be created." -ReturnObject $ReturnObject -Failure
    }
    else {
        if (-not $ConfigObject.vmOptions.basepath.Contains(":\")) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify the full path. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
        }
        else {
            $driveLetter = $ConfigObject.vmOptions.basepath.Substring(0, 1)
            if (-not (Test-Path "$driveLetter`:\")) {
                Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify a valid path. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
            }

            if ($driveLetter -in "C", "D", "Z") {
                Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify a drive letter other than C/D/Z. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # domainName
    if (-not $ConfigObject.vmOptions.domainName) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName not present in vmOptions. You must specify the Domain name." -ReturnObject $ReturnObject -Failure
    }
    else {

        # contains .
        if (-not $ConfigObject.vmOptions.domainName.Contains(".")) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName value [$($ConfigObject.vmOptions.domainName)] is invalid. You must specify the Full Domain name. For example: contoso.com" -ReturnObject $ReturnObject -Failure
        }

        # valid domain name
        $pattern = "^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$"
        if (-not ($ConfigObject.vmOptions.domainName -match $pattern)) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName value [$($ConfigObject.vmOptions.domainName)] contains invalid characters, is too long, or too short. You must specify a valid Domain name. For example: contoso.com." -ReturnObject $ReturnObject -Failure
        }

        $netBiosDomain = $ConfigObject.vmOptions.domainName.Split(".")[0]
        if ($netBiosDomain.Length -gt 15) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName [$($ConfigObject.vmOptions.domainName)] is too long. Netbios domain name [$netBiosDomain] must be less than 15 chars." -ReturnObject $ReturnObject -Failure
        }

        if ($netBiosDomain.Length -lt 1) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName  [$($ConfigObject.vmOptions.domainName)] is too short. Must be at least 1 chars." -ReturnObject $ReturnObject -Failure
        }
    }

    # domainAdminName
    if (-not $ConfigObject.vmOptions.domainAdminName) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainAdminName not present in vmOptions. You must specify the Domain Admin user name that will be created." -ReturnObject $ReturnObject -Failure
    }
    else {

        $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>') + '\]' + '\"'+'\s')]"
        if ($ConfigObject.vmOptions.domainAdminName -match $pattern) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainAdminName [$($ConfigObject.vmoptions.domainAdminName)] contains invalid characters. You must specify a valid domain username. For example: bob" -ReturnObject $ReturnObject -Failure
        }

        if ($ConfigObject.vmOptions.domainAdminName.Length -gt 64) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainAdminName [$($ConfigObject.vmoptions.domainAdminName)] is too long. Must be less than 64 chars" -ReturnObject $ReturnObject -Failure
        }

        if ($ConfigObject.vmOptions.domainAdminName.Length -lt 3) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainAdminName [$($ConfigObject.vmoptions.domainAdminName)] is too short. Must be at least 3 chars" -ReturnObject $ReturnObject -Failure
        }
    }

    # network
    if (-not $ConfigObject.vmOptions.network) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.network not present in vmOptions. You must specify the Network subnet for the environment." -ReturnObject $ReturnObject -Failure
    }
    else {
        $pattern1 = "^(192.168)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]).0)$"
        $pattern2 = "^(10)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){2,2}.0$"
        $pattern3 = "^(172).(1[6-9]|2[0-9]|3[0-1])(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])).0$"

        if (-not ($ConfigObject.vmOptions.network -match $pattern1 -or $ConfigObject.vmOptions.network -match $pattern2 -or $ConfigObject.vmOptions.network -match $pattern3)) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is invalid. You must specify a valid Class C Subnet. For example: 192.168.1.0" -ReturnObject $ReturnObject -Failure
        }
    }
}

function Test-ValidCmOptions {
    param (
        [object]
        $ConfigObject,
        [object]
        $ReturnObject
    )

    # version
    if ($Common.Supported.CMVersions -notcontains $ConfigObject.cmOptions.version) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions contains invalid CM Version [$($ConfigObject.cmOptions.version)]. Must be either 'current-branch' or 'tech-preview'." -ReturnObject $ReturnObject -Failure
    }

    # install
    if ($ConfigObject.cmOptions.install -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.install has an invalid value [$($ConfigObject.cmOptions.install)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # updateToLatest
    if ($ConfigObject.cmOptions.updateToLatest -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.updateToLatest has an invalid value [$($ConfigObject.cmOptions.updateToLatest)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # installDPMPRoles
    if ($ConfigObject.cmOptions.installDPMPRoles -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.installDPMPRoles has an invalid value [$($ConfigObject.cmOptions.installDPMPRoles)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # pushClientToDomainMembers
    if ($ConfigObject.cmOptions.pushClientToDomainMembers -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.pushClientToDomainMembers has an invalid value [$($ConfigObject.cmOptions.pushClientToDomainMembers)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

}

function Test-ValidVmSupported {
    param (
        [object]
        $VM,
        [object]
        $ConfigObject,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName

    # vmName characters
    if ($vm.vmName.Length -gt 15) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid name. Windows computer name cannot be more than 15 characters long." -ReturnObject $ReturnObject -Failure
    }

    #prefix + vmName combined name validation
    $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>') + '\]' + '\"'+'\s')]"
    if ($($ConfigObject.vmOptions.prefix + $vm.vmName) -match $pattern) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] contains invalid characters." -ReturnObject $ReturnObject -Failure
    }

    # Supported OS
    if ($Common.Supported.OperatingSystems -notcontains $vm.operatingSystem) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] does not contain a supported operatingSystem [$($vm.operatingSystem)]." -ReturnObject $ReturnObject -Failure
    }

    # Supported DSC Roles for Existing scenario
    if ($configObject.parameters.ExistingDCName) {
        # Supported DSC Roles for Existing Scenario
        if ($Common.Supported.RolesForExisting -notcontains $vm.role) {
            $supportedRoles = $Common.Supported.RolesForExisting -join ", "
            Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)]. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
        }
    }
    else {
        # Supported DSC Roles
        if ($Common.Supported.Roles -notcontains $vm.role) {
            $supportedRoles = $Common.Supported.Roles -join ", "
            Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)]. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
        }
    }

}

function Test-ValidVmMemory {
    param (
        [object]
        $VM,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Memory
    if (-not $VM.memory) {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] does not contain memory value []. Specify desired memory; For example: 4GB" -ReturnObject $ReturnObject -Failure
    }
    else {

        $vmMemory = $VM.memory

        # not string
        if ($vmMemory -isnot [string]) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Specify desired memory; For example: 4GB" -ReturnObject $ReturnObject -Failure
        }

        # memory doesn't contain MB/GB
        if ($vmMemory -is [string] -and -not ($vmMemory.ToUpperInvariant().EndsWith("MB") -or $vmMemory.ToUpperInvariant().EndsWith("GB"))) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Specify desired memory with MB/GB; For example: 4GB" -ReturnObject $ReturnObject -Failure
        }

        # memory less than 512MB
        if ($vmMemory.ToUpperInvariant().EndsWith("MB") -and $([int]$vmMemory.ToUpperInvariant().Replace("MB", "")) -lt 512 ) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Should be more than 512MB" -ReturnObject $ReturnObject -Failure
        }

        # memory greater than 64GB
        if ($vmMemory.ToUpperInvariant().EndsWith("GB") -and $([int]$vmMemory.ToUpperInvariant().Replace("GB", "")) -gt 64 ) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Should be less than 64GB" -ReturnObject $ReturnObject -Failure
        }
    }

}

function Test-ValidVmDisks {
    param (
        [object]
        $VM,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Additional Disks
    if ($VM.additionalDisks) {
        $validLetters = 69..89 | ForEach-Object { [char]$_ }    # Letters E-Y
        $disks = $VM.additionalDisks
        $disks | Get-Member -MemberType NoteProperty | ForEach-Object {

            # valid drive letter
            if ($_.Name.Length -ne 1 -or $validLetters -notcontains $_.Name) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must have a single drive letter between E and Y." -ReturnObject $ReturnObject -Failure
            }

            $size = $($vm.additionalDisks."$($_.Name)")

            if (-not $size.ToUpperInvariant().EndsWith("GB")) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Specify desired size in GB; For example: 200GB" -ReturnObject $ReturnObject -Failure
            }

            if ($size.ToUpperInvariant().EndsWith("GB") -and $([int]$size.ToUpperInvariant().Replace("GB", "")) -lt 10 ) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must be larger than 10GB" -ReturnObject $ReturnObject -Failure
            }

            if ($size.ToUpperInvariant().EndsWith("GB") -and $([int]$size.ToUpperInvariant().Replace("GB", "")) -gt 1000 ) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must be less than 1000GB" -ReturnObject $ReturnObject -Failure
            }
        }
    }

}

function Test-ValidVmProcs {
    param (
        [object]
        $VM,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    if (-not $VM.virtualProcs -or -not $VM.virtualProcs -is [int]) {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid virtualProcs [$($vm.virtualProcs)]. Specify desired virtualProcs; For example: 2" -ReturnObject $ReturnObject -Failure
    }
    else {
        $virtualProcs = $VM.virtualProcs
        if ($virtualProcs -gt 16 -or $virtualProcs -lt 1) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] virtualProcs value [$virtualProcs] is invalid. Specify a value from 1-16." -ReturnObject $ReturnObject -Failure
        }
    }

}

function Test-ValidVmServerOS {
    param (
        [object]
        $VM,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    if ($VM.operatingSystem -notlike "*Server*") {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid OS [$($VM.operatingSystem)]. OS must be a Server OS for Primary/CAS/DPMP roles, or when SQL is selected." -ReturnObject $ReturnObject -Warning
    }

}

function Test-ValidVmPath {
    param (
        [object]
        $VM,
        [string]
        $PathProperty,
        [string]
        $ValidPathExample,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    if (-not $VM.$PathProperty) {
        return
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # path
    if (-not $VM.$PathProperty.Contains(":\") -or $VM.$PathProperty.EndsWith(":") -or $VM.$PathProperty.EndsWith("\")) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. Value must be a valid path; For example: ""$ValidPathExample""." -ReturnObject $ReturnObject -Failure
    }
    else {

        # valid drive
        $installDrive = $VM.$PathProperty.Substring(0, 1)

        if ($installDrive -in "A", "B", "D", "Z") {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid sqlInstanceDir [$($VM.$PathProperty)]. A/B/D/Z drive letters are not allowed." -ReturnObject $ReturnObject -Failure
        }

        if ($installDrive -ne "C" -and -not $VM.additionalDisks) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid sqlInstanceDir [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must be defined." -ReturnObject $ReturnObject -Warning
        }

        if ($installDrive -ne "C" -and $VM.additionalDisks) {
            $defined = $VM.additionalDisks | Get-Member -Name $installDrive
            if (-not $defined) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid sqlInstanceDir [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $ReturnObject -Warning
            }
        }

    }
}

function Test-ValidRoleDC {
    param (
        [object]
        $ConfigObject,
        [object]
        $ReturnObject
    )

    $DCVM = $configObject.virtualMachines | Where-Object { $_.role -eq "DC" }
    $vmRole = "DC"

    $containsDC = $configObject.virtualMachines.role.Contains("DC")
    $existingDC = $configObject.parameters.ExistingDCName
    $domain = $ConfigObject.vmOptions.domainName

    if ($containsDC) {

        if ($existingDC) {
            Add-ValidationMessage -Message "$vmRole Validation: DC Role specified in configuration and existing DC [$existingDC] found in this domain [$domain]. Adding a DC to existing environment is not supported." -ReturnObject $ReturnObject -Warning
        }

        if (Test-SingleRole -VM $DCVM -ReturnObject $ReturnObject) {

            # Server OS
            Test-ValidVmServerOS -VM $DCVM -ReturnObject $ReturnObject

            # No SQL on DC
            if ($DCVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: Adding SQL on Domain Controller is not supported." -ReturnObject $ReturnObject -Warning
            }

        }
    }
    else {

        # Existing Scenario, without existing DC Name
        if (-not $existingDC) {
            Add-ValidationMessage -Message "$vmRole Validation: DC role not specified in the configuration file and existing DC not found." -ReturnObject $ReturnObject -Warning
        }

        if ($existingDC) {

            # Check VM exists in Hyper-V
            $vm = Get-VM -Name $existingDC -ErrorAction SilentlyContinue
            if (-not $vm) {
                Add-ValidationMessage -Message "$vmRole Validation: Existing DC found [$existingDC] but VM with the same name was not found in Hyper-V." -ReturnObject $ReturnObject -Warning
            }
            else {
                if ($vm.State -eq "Running") {
                    # Check network in Hyper-V
                    # $vmnet = Get-VM -Name $existingDC -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
                    # if ($vmnet.SwitchName -ne $configObject.vmOptions.network) {
                    #     Add-ValidationMessage -Message "$vmRole Validation: Existing DC [$existingDC] found but VM Switch [$($vmnet.SwitchName)] doesn't match specified network [$($configObject.vmOptions.network)]." -ReturnObject $ReturnObject -Warning
                    # }
                }
                else {
                    # VM Not running, cannot validate network
                    Add-ValidationMessage -Message "$vmRole Validation: Existing DC [$existingDC] found but VM is not Running." -ReturnObject $ReturnObject -Warning
                }
            }
        }
    }
}

function Test-ValidRoleCSPS {
    param (
        [object]
        $VM,
        [object]
        $ConfigObject,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Primary/CAS must contain SQL
    if (-not $VM.sqlVersion -and -not $VM.remoteSQLVM) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain sqlVersion; When deploying $vmRole Role, you must specify the SQL Version." -ReturnObject $ReturnObject -Warning
    }

    # Remote SQL
    if ($VM.remoteSQLVM) {
        $sqlServerName = $VM.remoteSQLVM
        $SQLVM = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $sqlServerName }

        # Remote SQL must contain sqlVersion
        if (-not $SQLVM -or -not $SQLVM.sqlVersion) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$sqlServerName] does not contain sqlVersion; When deploying $vmRole Role with remote SQL, you must specify the SQL Version for SQL VM." -ReturnObject $ReturnObject -Warning
        }

        # Minimum Memory
        if ($VM.memory / 1 -lt 4GB) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] must contain a minimum of 4GB memory when using remote SQL." -ReturnObject $ReturnObject -Failure
        }

    }
    else {
        # Local SQL

        # Minimum Memory
        if ($VM.memory / 1 -lt 6GB) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] must contain a minimum of 6GB memory when using local SQL." -ReturnObject $ReturnObject -Failure
        }
    }

    # Site Code
    if ($VM.siteCode.Length -ne 3) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code [$($VM.siteCode)] Must be exactly 3 chars." -ReturnObject $ReturnObject -Failure
    }

    # Parent Site Code
    if ($VM.parentSiteCode -and $VM.parentSiteCode.Length -ne 3) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code [$($VM.parentSiteCode)] Must be exactly 3 chars." -ReturnObject $ReturnObject -Failure
    }

    # invalid site codes
    $pattern = "^[a-zA-Z0-9]+$"
    if (-not ($VM.siteCode -match $pattern)) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code (Must be AlphaNumeric) [$($VM.siteCode)]." -ReturnObject $ReturnObject -Failure
    }

    # reserved site codes
    if ($VM.siteCode.ToUpperInvariant() -in "AUX", "CON", "NUL", "PRN", "SMS", "ENV") {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] reserved for Configuration Manager and Windows." -ReturnObject $ReturnObject -Failure
    }

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    # install dir
    Test-ValidVmPath -VM $VM -PathProperty "cmInstallDir" -ValidPathExample "E:\ConfigMgr" -ReturnObject $ReturnObject

}

function Test-SingleRole {
    param (
        [object]
        $VM,
        [object]
        $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmRole = $VM.role

    # Single Role
    if ($VM -is [object[]] -and $VM.Count -ne 1) {
        $vmRole = $VM.role | Select-Object -Unique
        if ($vmRole -eq "DC") {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple virtual Machines with $vmRole Role specified in configuration. Only single $vmRole role is supported." -ReturnObject $ReturnObject -Warning
        }
        else {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple machines with $vmRole role can not be deployed at the same time. You can add more $vmRole machines to your domain after it is deployed." -ReturnObject $ReturnObject -Warning
        }
        return $false
    }

    return $true
}

function Test-Configuration {
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "ConfigFile", HelpMessage = "Configuration File")]
        [string]$FilePath,
        [Parameter(Mandatory = $true, ParameterSetName = "ConfigObject", HelpMessage = "Configuration File")]
        [object]$InputObject
    )

    $return = [PSCustomObject]@{
        Valid        = $false
        DeployConfig = $null
        Message      = [System.Text.StringBuilder]::new()
        Failures     = 0
        Warnings     = 0
        Problems     = 0
    }

    if ($FilePath) {
        try {
            $configObject = Get-Content $FilePath -Force | ConvertFrom-Json
        }
        catch {
            $return.Message = "Failed to load $FilePath as JSON. Please check if the config is valid or create a new one using genconfig.ps1"
            $return.Problems += 1
            $return.Failures += 1
            return $return
        }
    }

    if ($InputObject) {
        # Convert to Json and back to make a copy of the object, so the original is not modified
        $configObject = $InputObject | ConvertTo-Json -Depth 3 | ConvertFrom-Json
    }

    $deployConfig = New-DeployConfig -configObject $configObject
    $return.DeployConfig = $deployConfig

    # Contains roles
    if ($deployConfig.virtualMachines) {
        $containsCS = $deployConfig.virtualMachines.role.Contains("CAS")
        $containsPS = $deployConfig.virtualMachines.role.Contains("Primary")
        $containsDPMP = $deployConfig.virtualMachines.role.Contains("DPMP")
    }
    else {
        $containsCS = $containsPS = $containsDPMP = $false
    }

    $needCMOptions = $containsCS -or $containsPS

    # VM Options
    # ===========
    Test-ValidVmOptions -ConfigObject $deployConfig -ReturnObject $return

    # CM Options
    # ===========

    # CM Version
    if ($needCMOptions) {
        Test-ValidCmOptions -ConfigObject $deployConfig -ReturnObject $return
    }

    # VM Validations
    # ==============
    foreach ($vm in $deployConfig.virtualMachines) {

        # Supported values
        Test-ValidVmSupported -VM $vm -ConfigObject $deployConfig -ReturnObject $return

        # Valid Memory
        Test-ValidVmMemory -VM $vm -ReturnObject $return

        # virtualProcs
        Test-ValidVmProcs -VM $vm -ReturnObject $return

        # Valid additionalDisks
        Test-ValidVmDisks -VM $vm -ReturnObject $return

        if ($vm.sqlVersion) {

            # Supported SQL
            if ($Common.Supported.SqlVersions -notcontains $vm.sqlVersion) {
                Add-ValidationMessage -Message "VM Validation: [$($vm.vmName)] does not contain a supported sqlVersion [$($vm.sqlVersion)]." -ReturnObject $return -Failure
            }

            # Server OS
            Test-ValidVmServerOS -VM $vm -ReturnObject $return

            # sqlInstance dir
            Test-ValidVmPath -VM $vm -PathProperty "sqlInstanceDir" -ValidPathExample "F:\SQL" -ReturnObject $return

            # sqlInstanceName
            if (-not $VM.sqlInstanceName) {
                Add-ValidationMessage -Message "VM Validation: [$($vm.vmName)] does not contain sqlInstanceName." -ReturnObject $return -Warning
            }
        }

    }

    # DC Validation
    # ==============
    Test-ValidRoleDC -ConfigObject $deployConfig -ReturnObject $return

    # CAS Validations
    # ==============
    if ($containsCS) {

        $CSVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "CAS" }
        $vmName = $CSVM.vmName
        $vmRole = $CSVM.role

        # Single CAS
        if (Test-SingleRole -VM $CSVM -ReturnObject $return) {

            # CAS without Primary
            if (-not $containsPS) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified without Primary Site; When deploying CAS Role, you must add a Primary Role as well." -ReturnObject $return -Warning
            }

            # Validate CAS role
            Test-ValidRoleCSPS -VM $CSVM -ConfigObject $deployConfig -ReturnObject $return

        }

    }

    # Primary Validations
    # ==============
    if ($containsPS) {

        # Validate Primary role
        $PSVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" }
        $vmName = $PSVM.vmName
        $vmRole = $PSVM.role
        $psParentSiteCode = $PSVM.parentSiteCode

        if (Test-SingleRole -VM $PSVM -ReturnObject $return) {

            Test-ValidRoleCSPS -VM $PSVM -ConfigObject $deployConfig -ReturnObject $return

            # Valid parent Site Code
            if ($psParentSiteCode) {
                $casSiteCodes = Get-ValidCASSiteCodes -Config $deployConfig
                $parentCodes = $casSiteCodes -join ","
                if ($psParentSiteCode -notin $casSiteCodes) {
                    Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] contains parentSiteCode [$psParentSiteCode] which is invalid. Valid Parent Site Codes: $parentCodes" -ReturnObject $return -Warning
                }
            }

            # Other Site servers must be running
            if ($psParentSiteCode -and $deployConfig.parameters.ExistingCASName -and $deployConfig.cmOptions.updateToLatest) {
                $notRunning = Get-ExistingSiteServer -DomainName $deployConfig.vmOptions.domainName | Where-Object { $_.State -ne "Running" }
                $notRunningNames = $notRunning.vmName -join ","
                if ($notRunning.Count -gt 0) {
                    Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] requires other site servers [$notRunningNames] to be running." -ReturnObject $return -Warning
                }
            }

            # CAS with Primary, without parentSiteCode
            if ($containsCS) {
                if ($psParentSiteCode-ne $CSVM.siteCode) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified with CAS, but parentSiteCode [$psParentSiteCode] does not match CAS Site Code [$($CSVM.siteCode)]." -ReturnObject $return -Warning
                }
            }

        }
    }

    # DPMP Validations
    # =================
    if ($containsDPMP) {

        $DPMPVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" }

        if ($containsPS) {
            # DPMP VM count -eq 1
            if (Test-SingleRole -VM $DPMPVM -ReturnObject $return) {

                # Server OS
                Test-ValidVmServerOS -VM $DPMPVM -ReturnObject $return
            }
        }
        else {
            Add-ValidationMessage -Message "Role Conflict: DPMP Role specified without Primary site. DPMP Role can only be deployed with a Primary Site." -ReturnObject $return -Warning
        }

    }

    # Role Conflicts
    # ==============

    # CAS/Primary must include DC
    if (($containsCS -or $containsPS) -and -not $deployConfig.parameters.DCName ) {
        Add-ValidationMessage -Message "Role Conflict: CAS or Primary role specified but a new/existing DC was not found; CAS/Primary roles require a DC." -ReturnObject $return -Warning
    }

    # Primary site without CAS
    if ($deployConfig.parameters.scenario -eq "Hierarchy" -and -not $deployConfig.parameters.CSName) {
        Add-ValidationMessage -Message "Role Conflict: Deployment requires a CAS, which was not found." -ReturnObject $return -Warning
    }

    # tech preview and hierarchy
    if ($deployConfig.parameters.scenario -eq "Hierarchy" -and $deployConfig.cmOptions.version -eq "tech-preview") {
        Add-ValidationMessage -Message "Version Conflict: Tech-Preview specfied with a Hierarchy; Tech Preview doesn't support CAS." -ReturnObject $return -Warning
    }

    # Total Memory
    # =============
    $totalMemory = $deployConfig.virtualMachines.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum
    $totalMemory = $totalMemory.Sum / 1GB
    $availableMemory = Get-WmiObject win32_operatingsystem | Select-Object -Expand FreePhysicalMemory
    $availableMemory = $availableMemory * 1KB / 1GB

    if ($totalMemory -gt $availableMemory) {
        Add-ValidationMessage -Message "Deployment Validation: Total Memory Required [$($totalMemory)GB] is greater than available memory [$($availableMemory)GB]." -ReturnObject $return -Warning
    }

    # Unique Names
    # =============

    # Names in deployment
    $vmInDeployment = $deployConfig.virtualMachines.vmName
    $unique1 = $vmInDeployment | Select-Object -Unique
    $compare = Compare-Object -ReferenceObject $vmInDeployment -DifferenceObject $unique1
    if ($compare) {
        $duplicates = $compare.InputObject -join ","
        Add-ValidationMessage -Message "Name Conflict: Deployment contains duplicate VM names [$duplicates]" -ReturnObject $return -Warning
    }

    # Names in domain
    $allVMs = Get-List -Type VM | Select-Object -Expand VmName
    $all = $allVMs + $vmInDeployment
    $unique2 = $all | Select-Object -Unique
    $compare2 = Compare-Object -ReferenceObject $all -DifferenceObject $unique2
    if (-not $compare -and $compare2) {
        $duplicates = $compare2.InputObject -join ","
        Add-ValidationMessage -Message "Name Conflict: Deployment contains VM names [$duplicates] that are already in Hyper-V. You must add new machines with different names." -ReturnObject $return -Warning
    }

    # Return if validation failed
    if ($return.Problems -ne 0) {
        $return.Message = $return.Message.ToString().Trim()
        return $return
    }

    # everything is good
    $return.Valid = $true

    return $return
}

function New-DeployConfig {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object]
        $configObject
    )

    $containsCS = $configObject.virtualMachines.role.Contains("CAS")

    # Scenario
    if ($containsCS) {
        $scenario = "Hierarchy"
    }
    else {
        $scenario = "Standalone"
    }

    # add prefix to vm names
    $virtualMachines = $configObject.virtualMachines
    $virtualMachines | foreach-object { $_.vmName = $configObject.vmOptions.prefix + $_.vmName }

    # create params object
    try {
        $network = $configObject.vmOptions.network.Substring(0, $configObject.vmOptions.network.LastIndexOf("."))
    }
    catch {}
    $clientsCsv = ($virtualMachines | Where-Object { $_.role -eq "DomainMember" }).vmName -join ","

    # DCName (prefer name in config over existing)
    $DCName = ($virtualMachines | Where-Object { $_.role -eq "DC" }).vmName
    $existingDCName = Get-ExistingForDomain -DomainName $configObject.vmOptions.domainName -Role "DC"
    if (-not $DCName) {
        $DCName = $existingDCName
    }

    # CSName (prefer name in config over existing)
    $containsPS = $configObject.virtualMachines.role.Contains("Primary")
    if ($containsPS) {
        $PSVM = $virtualMachines | Where-Object { $_.role -eq "Primary" } | Select-Object -First 1 # Bypass failures, validation would fail if we had multiple
        $existingCS = Get-ExistingSiteServer -DomainName $configObject.vmOptions.domainName -SiteCode ($PSVM.parentSiteCode | Select-Object -First 1) # Bypass failures, validation would fail if we had multiple
        $existingCSName = $existingCS.vmName
        $CSName = ($virtualMachines | Where-Object { $_.role -eq "CAS" }).vmName
        if (-not $CSName) {
            $CSName = $existingCSName
        }

        # Add prefix to remote SQL
        if ($PSVM.remoteSQLVM -and -not $PSVM.remoteSQLVM.StartsWith($configObject.vmOptions.prefix)) {
            $PSVM.remoteSQLVM = $configObject.vmOptions.prefix + $PSVM.remoteSQLVM
        }
    }



    if ($containsCS) {
        $CSVM = $virtualMachines | Where-Object { $_.role -eq "CAS" } | Select-Object -First 1 # Bypass failures, validation would fail if we had multiple

        # Add prefix to remote SQL
        if ($CSVM.remoteSQLVM -and -not $CSVM.remoteSQLVM.StartsWith($configObject.vmOptions.prefix)) {
            $CSVM.remoteSQLVM = $configObject.vmOptions.prefix + $CSVM.remoteSQLVM
        }
    }

    if ($existingCSName -and $containsPS) {

        if ($PSVM.parentSiteCode) {
            $scenario = "Hierarchy"
        }
        else {
            $scenario = "Standalone"
        }

    }

    $params = [PSCustomObject]@{
        DomainName         = $configObject.vmOptions.domainName
        DCName             = $DCName
        CSName             = $CSName
        PSName             = ($virtualMachines | Where-Object { $_.role -eq "Primary" }).vmName
        DPMPName           = ($virtualMachines | Where-Object { $_.role -eq "DPMP" }).vmName
        DomainMembers      = $clientsCsv
        Scenario           = $scenario
        DHCPScopeId        = $configObject.vmOptions.Network
        DHCPDNSAddress     = $network + ".1"
        DHCPDefaultGateway = $network + ".200"
        DHCPScopeStart     = $network + ".20"
        DHCPScopeEnd       = $network + ".199"
        ExistingDCName     = $existingDCName
        ExistingCASName    = $existingCSName
        ThisMachineName    = $null
        ThisMachineRole    = $null
    }

    $deploy = [PSCustomObject]@{
        cmOptions       = $configObject.cmOptions
        vmOptions       = $configObject.vmOptions
        virtualMachines = $virtualMachines
        parameters      = $params
    }

    return $deploy
}

function Get-ValidCASSiteCodes {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $existingSiteCodes = @()
    $existingSiteCodes += Get-ExistingSiteServer -DomainName $Config.vmOptions.domainName -Role "CAS" | Select-Object -ExpandProperty SiteCode

    $containsCS = $Config.virtualMachines.role.Contains("CAS")
    if ($containsCS) {
        $CSVM = $Config.virtualMachines | Where-Object { $_.role -eq "CAS" }
        $existingSiteCodes += $CSVM.siteCode
    }

    return ($existingSiteCodes | Select-Object -Unique)
}

function Get-ExistingForDomain {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "DPMP", "DomainMember")]
        [string]$Role
    )

    try {

        $existingValue = @()
        $vmList = Get-List -Type VM -DomainName $DomainName
        foreach ($vm in $vmList) {
            if ($vm.Role.ToLowerInvariant() -eq $Role.ToLowerInvariant()) {
                $existingValue += $vm.VmName
            }
        }

        if ($existingValue.Count -gt 0) {
            return $existingValue
        }

        return $null

    }
    catch {
        Write-Log "Get-ExistingForDomain: Failed to get existing $Role from $DomainName. $_" -Failure
        return $null
    }
}

function Get-ExistingSiteServer {
    param(
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [ValidateSet("CAS", "Primary")]
        [string]$Role,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [string]$SiteCode
    )

    try {

        if ($DomainName) {
            $vmList = Get-List -Type VM -DomainName $DomainName
        }
        else {
            $vmList = Get-List -Type VM
        }

        if ($Role) {
            $vmList = $vmList | Where-Object { $_.Role -eq $Role }
        }

        $existingValue = @()
        foreach ($vm in $vmList) {
            $so = $null
            if ($vm.siteCode) {
                if ($PSBoundParameters.ContainsKey("SiteCode") -and $vm.siteCode.ToLowerInvariant() -eq $SiteCode.ToLowerInvariant()) {

                    $so = [PSCustomObject]@{
                        VmName   = $vm.VmName
                        Role     = $vm.Role
                        SiteCode = $vm.siteCode
                        Domain   = $vm.domain
                        State    = $vm.State
                    }
                    $existingValue += $so
                }

                if (-not $PSBoundParameters.ContainsKey("SiteCode")) {

                    $so = [PSCustomObject]@{
                        VmName   = $vm.VmName
                        Role     = $vm.Role
                        SiteCode = $vm.siteCode
                        Domain   = $vm.domain
                        State    = $vm.State
                    }
                    $existingValue += $so
                }
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Get-ExistingSiteServer: Failed to get existing site servers. $_" -Failure
        return $null
    }
}

function Get-ExistingForSubnet {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Subnet")]
        [string]$Subnet,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "DPMP", "DomainMember")]
        [string]$Role
    )

    try {

        $existingValue = @()
        $vmList = Get-List -Type VM | Where-Object { $_.Subnet -eq $Subnet }
        foreach ($vm in $vmList) {
            if ($vm.Role.ToLowerInvariant() -eq $Role.ToLowerInvariant()) {
                $existingValue += $vm.VmName
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Get-ExistingForSubnet: Failed to get existing $Role from $Subnet. $_" -Failure
        return $null
    }
}

function Get-SubnetList {

    param(
        [Parameter(Mandatory = $false)]
        [string]
        $DomainName
    )
    try {

        if ($DomainName) {
            return (Get-List -Type Subnet -DomainName $DomainName)
        }

        return (Get-List -Type Subnet)

    }
    catch {
        Write-Log "Get-SubnetList: Failed to get subnet list. $_" -Failure -LogOnly
        return $null
    }
}

function Get-DomainList {

    try {
        return (Get-List -Type UniqueDomain)
    }
    catch {
        Write-Log "Get-DomainList: Failed to get domain list. $_" -Failure -LogOnly
        return $null
    }
}

$global:vm_List = $null
function Get-List {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("VM", "Subnet", "Prefix", "UniqueDomain", "UniqueSubnet", "UniquePrefix")]
        [string] $Type,
        [Parameter(Mandatory = $false)]
        [string] $DomainName,
        [Parameter(Mandatory = $false)]
        [switch] $ResetCache
    )

    try {

        if ($ResetCache.IsPresent) {
            $global:vm_List = $null
        }

        if ($null -eq $global:vm_List) {

            Write-Log "Get-List: Obtaining '$Type' list and caching it." -Verbose
            $return = @()
            $virtualMachines = Get-VM
            foreach ($vm in $virtualMachines) {

                try {
                    if ($vm.Notes -like "*lastUpdate*") {
                        $vmNoteObject = $vm.Notes | ConvertFrom-Json
                    }
                    else {
                        Write-Log "Get-List: VM Properties for '$($vm.Name) does not contain values. Assume this was not deployed by vmbuild'. $_" -Warning -LogOnly
                        continue
                    }
                }
                catch {
                    Write-Log "Get-List: Failed to get VM Properties for '$($vm.Name)'. $_" -Failure
                    continue
                }

                if ($vmNoteObject) {
                    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }
                    $vmObject = [PSCustomObject]@{
                        VmName          = $vm.Name
                        Role            = $vmNoteObject.role
                        DeployedOS      = $vmNoteObject.deployedOS
                        MemoryGB        = $vm.MemoryAssigned / 1GB
                        State           = $vm.State
                        Domain          = $vmNoteObject.domain
                        DomainAdmin     = $vmNoteObject.domainAdmin
                        Subnet          = $vmNoteObject.network
                        Prefix          = $vmNoteObject.prefix
                        Success         = $vmNoteObject.success
                        SiteCode        = $vmNoteObject.SiteCode
                        ParentSiteCode  = $vmNoteObject.parentSiteCode
                        CMInstallDir    = $vmNoteObject.cmInstallDir
                        SQLVersion      = $vmNoteObject.sqlVersion
                        SQLInstanceName = $vmNoteObject.sqlInstanceName
                        SQLInstanceDir  = $vmNoteObject.sqlInstanceDir
                        RemoteSQLVM     = $vmNoteObject.remoteSQLVM
                        InProgress      = $inProgress
                    }
                }
                else {
                    $vmNet = $vm | Get-VMNetworkAdapter
                    $vmObject = [PSCustomObject]@{
                        VmName          = $vm.Name
                        Subnet          = $vmNet.SwitchName
                        MemoryGB        = $vm.MemoryAssigned / 1GB
                        State           = $vm.State
                        Role            = $null
                        DeployedOS      = $null
                        SiteCode        = $null
                        ParentSiteCode  = $null
                        CMInstallDir    = $null
                        SQLVersion      = $null
                        SQLInstanceName = $null
                        SQLInstanceDir  = $null
                        RemoteSQLVM     = $null
                        Domain          = $null
                        DomainAdmin     = $null
                        Prefix          = $null
                        Success         = $null
                        InProgress      = $null
                    }
                }

                $return += $vmObject
            }

            $global:vm_List = $return
        }

        $return = $global:vm_List

        if ($DomainName) {
            $return = $return | Where-Object { $_.domain -and ($_.domain.ToLowerInvariant() -eq $DomainName.ToLowerInvariant()) }
        }

        $return = $return | Sort-Object -Property * -Unique

        if ($Type -eq "VM") {
            return $return
        }

        if ($Type -eq "Subnet") {
            return $return | Select-Object -Property Subnet, Domain | Sort-Object -Property * -Unique
        }

        if ($Type -eq "Prefix") {
            return $return | Select-Object -Property Prefix, Domain | Sort-Object -Property * -Unique
        }

        if ($Type -eq "UniqueDomain") {
            return $return | Select-Object -ExpandProperty Domain -Unique
        }

        if ($Type -eq "UniqueSubnet") {
            return $return | Select-Object -ExpandProperty Subnet -Unique
        }

        if ($Type -eq "UniquePrefix") {
            return $return | Select-Object -ExpandProperty Prefix -Unique
        }

    }
    catch {
        Write-Log "Get-List: Failed to get '$Type' list. $_" -Failure -LogOnly
        return $null
    }
}

Function Show-Summary {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsCustomObject]
        $deployConfig
    )

    Function Write-GreenCheck {
        [CmdletBinding()]
        param (
            [Parameter()]
            [string] $text,
            [Parameter()]
            [switch] $NoNewLine
        )
        $CHECKMARK = ([char]8730)

        Write-Host "  [" -NoNewLine
        Write-Host -ForeGroundColor Green "$CHECKMARK" -NoNewline
        Write-Host "] " -NoNewline
        Write-Host $text -NoNewline
        if (!$NoNewLine) {
            Write-Host
        }
    }

    Function Write-RedX {
        [CmdletBinding()]
        param (
            [Parameter()]
            [string] $text,
            [Parameter()]
            [switch] $NoNewLine
        )
        Write-Host "  [" -NoNewLine
        Write-Host -ForeGroundColor Red "x" -NoNewline
        Write-Host "] " -NoNewline
        Write-Host $text -NoNewline
        if (!$NoNewLine) {
            Write-Host
        }
    }

    #$CHECKMARK = ([char]8730)
    $containsPS = $deployConfig.virtualMachines.role.Contains("Primary")
    $containsDPMP = $deployConfig.virtualMachines.role.Contains("DPMP")
    $containsMember = $deployConfig.virtualMachines.role.Contains("DomainMember")

    if ($null -ne $($deployConfig.cmOptions) -and $containsPS -and $deployConfig.cmOptions.install -eq $true) {
        if ($deployConfig.cmOptions.install -eq $true) {
            Write-GreenCheck "ConfigMgr $($deployConfig.cmOptions.version) will be installed."


            if ($deployConfig.cmOptions.updateToLatest -eq $true) {
                Write-GreenCheck "ConfigMgr will be updated to latest"
            }
            else {
                Write-RedX "ConfigMgr will NOT updated to latest"
            }
            $PSVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" }
            if ($PSVM.ParentSiteCode) {
                Write-GreenCheck "ConfigMgr Primary server Will join a Heirarchy: $($PSVM.SiteCode) -> $($PSVM.ParentSiteCode)"
            }
            else {
                Write-GreenCheck "Primary server with Sitecode $($PSVM.SiteCode) will be installed in a standalone configuration"
            }
        }
        else {
            Write-RedX "ConfigMgr will not be installed."
        }


        if (($deployConfig.cmOptions.installDPMPRoles -or $deployConfig.cmOptions.pushClientToDomainMembers) -and $deployConfig.cmOptions.install -eq $true) {

            If ($containsDPMP) {
                $DPMP = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "DPMP" }
                Write-GreenCheck "DP and MP roles will be installed on $($DPMP.vmName)" -NoNewLine
            }
            else {
                $PSVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" }
                Write-GreenCheck "DP and MP roles will be installed on Primary Site Server $($PSVM.vmName)" -NoNewLine
            }
        }
        else {
            Write-RedX "DPMP roles will not be installed" -NoNewLine
        }

        if ($containsMember) {
            if ($deployConfig.cmOptions.pushClientToDomainMembers -and $deployConfig.cmOptions.install -eq $true) {
                Write-Host " [Client Push: Yes]"
            }
            else {
                Write-Host " [Client Push: No]"
            }
        }
        else {
            Write-Host " [Client Push: N/A]"
        }

    }
    else {
        Write-RedX "ConfigMgr will not be installed."
    }

    if (-not $null -eq $($deployConfig.vmOptions)) {

        if ($null -eq $deployConfig.parameters.ExistingDCName) {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be created." -NoNewLine
        }
        else {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be joined." -NoNewLine
        }

        Write-Host " [Network $($deployConfig.vmOptions.network)]"
        Write-GreenCheck "Virtual Machine files will be stored in $($deployConfig.vmOptions.basePath) on host machine"

        $totalMemory = $deployConfig.virtualMachines.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum
        $totalMemory = $totalMemory.Sum / 1GB
        $availableMemory = Get-WmiObject win32_operatingsystem | Select-Object -Expand FreePhysicalMemory
        $availableMemory = $availableMemory * 1KB / 1GB
        Write-GreenCheck "This configuration will use $($totalMemory)GB out of $([math]::Round($availableMemory,2))GB Available RAM on host machine"
    }
    Write-GreenCheck "Domain Admin account: $($deployConfig.vmOptions.domainAdminName)  Password: $($Common.LocalAdmin.GetNetworkCredential().Password)"
    $out = $deployConfig.virtualMachines | Where-Object { -not $_.hidden } `
    | Format-table vmName, role, operatingSystem, memory,
    @{Label = "Procs"; Expression = { $_.virtualProcs } },
    @{Label = "AddedDisks"; Expression = { $_.additionalDisks.psobject.Properties.Value.count } },
    @{Label = "SQL"; Expression = {
            if ($null -ne $_.SqlVersion) {
                $_.SqlVersion
            }
            else {
                if ($null -ne $_.remoteSQLVM) {
                ("Remote -> " + $($_.remoteSQLVM))
                }
            }
        }
    } `
    | Out-String
    Write-Host
    $out.Trim() | Out-Host
}

function Copy-SampleConfigs {

    $realConfigPath = $Common.ConfigPath
    $sampleConfigPath = Join-Path $Common.ConfigPath "samples"

    Write-Log "Copy-SampleConfigs: Checking if any sample configs need to be copied to config directory" -LogOnly -Verbose
    foreach ($item in Get-ChildItem $sampleConfigPath -File -Filter *.json) {
        $copyFile = $true
        $sampleFile = $item.FullName
        $fileName = Split-Path -Path $sampleFile -Leaf
        $configFile = Join-Path -Path $realConfigPath $fileName
        if (Test-Path $configFile) {
            $sampleFileHash = Get-FileHash $sampleFile
            $configFileHash = Get-FileHash $configFile
            if ($configFileHash -ne $sampleFileHash) {
                Write-Log "Copy-SampleConfigs: Skip copying $fileName to config directory. File exists, and has different hash." -LogOnly -Verbose
                $copyFile = $false
            }
        }

        if ($copyFile) {
            Write-Log "Copy-SampleConfigs: Copying $fileName to config directory." -LogOnly -Verbose
            Copy-Item -Path $sampleFile -Destination $configFile -Force
        }
    }
}
