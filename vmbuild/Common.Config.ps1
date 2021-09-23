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

function Get-FilesForConfiguration {
    param (
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile", HelpMessage = "Configuration Name for which to download the files.")]
        [string]$Configuration,
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigObject", HelpMessage = "Configuration Object for which to download the files.")]
        [object]$InputObject,
        [Parameter(Mandatory = $false, ParameterSetName = "All", HelpMessage = "Get all files.")]
        [switch]$DownloadAll,
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

    foreach ($file in $Common.AzureFileList.OS) {

        if ($file.id -eq "vmbuildadmin") { continue }
        if (-not $DownloadAll -and $operatingSystemsToGet -notcontains $file.id) { continue }
        Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf
    }

    foreach ($file in $Common.AzureFileList.ISO) {
        if (-not $DownloadAll -and $sqlVersionsToGet -notcontains $file.id) { continue }
        Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf

    }
}

function Add-ValidationFailure {
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

    # Contains roles
    $containsDC = $configObject.virtualMachines.role.Contains("DC")
    $containsCS = $configObject.virtualMachines.role.Contains("CS")
    $containsPS = $configObject.virtualMachines.role.Contains("PS")
    $containsDPMP = $configObject.virtualMachines.role.Contains("DPMP")
    $needCMOptions = $containsCS -or $containsPS

    # VM's
    $DCVM = $configObject.virtualMachines | Where-Object { $_.role -eq "DC" }
    $CSVM = $configObject.virtualMachines | Where-Object { $_.role -eq "CS" }
    $PSVM = $configObject.virtualMachines | Where-Object { $_.role -eq "PS" }
    $DPMPVM = $configObject.virtualMachines | Where-Object { $_.role -eq "DPMP" }

    # VM Options
    # ===========

    # prefix
    if (-not $configObject.vmOptions.prefix) {
        Add-ValidationFailure -Message "VM Options Validation: vmOptions.prefix not present in vmOptions. You must specify the prefix that will be added to name of Virtual Machine(s)." -ReturnObject $return -Failure
    }

    # basePath
    if (-not $configObject.vmOptions.basePath) {
        Add-ValidationFailure -Message "VM Options Validation: vmOptions.basePath not present in vmOptions. You must specify the base path where the Virtual Machines will be created." -ReturnObject $return -Failure
    }
    else {
        if (-not $configObject.vmOptions.basepath.Contains(":\")) {
            Add-ValidationFailure -Message "VM Options Validation: vmOptions.basePath value [$($configObject.vmOptions.basePath)] is invalid. You must specify the full path. For example: E:\VirtualMachines" -ReturnObject $return -Failure
        }
    }

    # domainName
    if (-not $configObject.vmOptions.domainName) {
        Add-ValidationFailure -Message "VM Options Validation: vmOptions.domainName not present in vmOptions. You must specify the Domain name." -ReturnObject $return -Failure
    }
    else {

        # contains .
        if (-not $configObject.vmOptions.domainName.Contains(".")) {
            Add-ValidationFailure -Message "VM Options Validation: vmOptions.domainName value [$($configObject.vmOptions.domainName)] is invalid. You must specify the Full Domain name. For example: contoso.com" -ReturnObject $return -Failure
        }

        # valid domain name
        $pattern = "^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$"
        if (-not ($configObject.vmOptions.domainName -match $pattern)) {
            Add-ValidationFailure -Message "VM Options Validation: vmOptions.domainName value [$($configObject.vmOptions.domainName)] is invalid. You must specify a valid Domain name. For example: contoso.com." -ReturnObject $return -Failure
        }
    }

    # domainAdminName
    if (-not $configObject.vmOptions.domainAdminName) {
        Add-ValidationFailure -Message "VM Options Validation: vmOptions.domainAdminName not present in vmOptions. You must specify the Domain Admin user name that will be created." -ReturnObject $return -Failure
    }
    else {

        $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>') + '\]' + '\"')]"
        if ($configObject.vmOptions.domainAdminName -match $pattern) {
            Add-ValidationFailure -Message "VM Options Validation: vmOptions.domainAdminName [$($configObject.vmoptions.domainAdminName)] contains invalid characters. You must specify a valid domain username. For example: bob" -ReturnObject $return -Failure
        }
    }

    # network
    if (-not $configObject.vmOptions.network) {
        Add-ValidationFailure -Message "VM Options Validation: vmOptions.network not present in vmOptions. You must specify the Network subnet for the environment." -ReturnObject $return -Failure
    }
    else {
        $pattern = "^(192.168)(.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]).0)$"
        if (-not ($configObject.vmOptions.network -match $pattern)) {
            Add-ValidationFailure -Message "VM Options Validation: vmOptions.network [$($configObject.vmoptions.network)] value is invalid. You must specify a valid Class C Subnet. For example: 192.168.1.0" -ReturnObject $return -Failure
        }
    }

    # CM Options
    # ===========

    # CM Version
    if ($needCMOptions) {
        if ($Common.Supported.CMVersions -notcontains $configObject.cmOptions.version) {
            Add-ValidationFailure -Message "CM Options Validation: cmOptions contains invalid CM Version [$($configObject.cmOptions.version)]. Must be either 'current-branch' or 'tech-preview'." -ReturnObject $return -Failure
        }

        # install
        if ($configObject.cmOptions.install -isnot [bool]) {
            Add-ValidationFailure -Message "CM Options Validation: cmOptions.install has an invalid value [$($configObject.cmOptions.install)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $return -Failure
        }

        # updateToLatest
        if ($configObject.cmOptions.updateToLatest -isnot [bool]) {
            Add-ValidationFailure -Message "CM Options Validation: cmOptions.updateToLatest has an invalid value [$($configObject.cmOptions.updateToLatest)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $return -Failure
        }

        # installDPMPRoles
        if ($configObject.cmOptions.installDPMPRoles -isnot [bool]) {
            Add-ValidationFailure -Message "CM Options Validation: cmOptions.installDPMPRoles has an invalid value [$($configObject.cmOptions.installDPMPRoles)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $return -Failure
        }

        # pushClientToDomainMembers
        if ($configObject.cmOptions.pushClientToDomainMembers -isnot [bool]) {
            Add-ValidationFailure -Message "CM Options Validation: cmOptions.pushClientToDomainMembers has an invalid value [$($configObject.cmOptions.pushClientToDomainMembers)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $return -Failure
        }
    }

    # Role Conflicts
    # ==============

    # CS/PS must include DC
    if (($containsCS -or $containsPS) -and -not $containsDC) {
        Add-ValidationFailure -Message "Role Conflict: CS or PS role specified in the configuration file without DC; PS/CS roles require a DC to be present in the config file. Adding CS/PS to existing environment is not currently supported." -ReturnObject $return -Failure
    }

    # VM Validations
    # ==============
    foreach ($vm in $configObject.virtualMachines) {

        # vmName characters
        if ($vm.vmName.Length + $configObject.vmOptions.prefix.Length -gt 15) {
            Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] with prefix [$($configObject.vmOptions.prefix)] has invalid name. Windows computer name cannot be more than 15 characters long." -ReturnObject $return -Failure
        }

        # Supported DSC Role
        if ($Common.Supported.Roles -notcontains $vm.role) {
            Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] does not contain a supported role [$($vm.role)]. Supported values are: DC, CS, PS, DPMP and DomainMember" -ReturnObject $return -Failure
        }

        # Supported OS
        if ($Common.Supported.OperatingSystems -notcontains $vm.operatingSystem) {
            Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] does not contain a supported operatingSystem [$($vm.operatingSystem)]. Run Get-AvailableFiles.ps1." -ReturnObject $return -Failure
        }

        # Supported SQL
        if ($vm.sqlVersion) {
            if ($Common.Supported.SqlVersions -notcontains $vm.sqlVersion) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] does not contain a supported sqlVersion [$($vm.sqlVersion)]. Run Get-AvailableFiles.ps1." -ReturnObject $return -Failure
            }

            if ($vm.operatingSystem -notlike "*Server*") {
                Add-ValidationFailure -Message "VM Validation: SQL Server specified in configuration without a Server Operating System." -ReturnObject $return -Failure
            }

        }

        # Memory
        if (-not $vm.memory) {
            Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] does not contain memory value [$($vm.memory)]. Specify desired memory in quotes; For example: ""4GB""" -ReturnObject $return -Failure
        }
        else {

            # not string
            if ($vm.memory -isnot [string]) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] memory value [$($vm.memory)] is invalid. Specify desired memory in quotes; For example: ""4GB""" -ReturnObject $return -Failure
            }

            # memory doesn't contain MB/GB
            if ($vm.memory -is [string] -and -not ($vm.memory.EndsWith("MB") -or $vm.memory.EndsWith("GB"))) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] memory value [$($vm.memory)] is invalid. Specify desired memory in quotes with MB/GB; For example: ""4GB""" -ReturnObject $return -Failure
            }

            # memory less than 512MB
            if ($vm.memory.EndsWith("MB") -and $([int]$vm.memory.Replace("MB", "")) -lt 512 ) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] memory value [$($vm.memory)] is invalid. Should have more than 512MB" -ReturnObject $return -Failure
            }

            # memory greater than 64GB
            if ($vm.memory.EndsWith("GB") -and $([int]$vm.memory.Replace("GB", "")) -gt 64 ) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] memory value [$($vm.memory)] is invalid. Should have less than 64GB" -ReturnObject $return -Failure
            }


        }

        # virtualProcs
        if (-not $vm.virtualProcs -or $vm.virtualProcs -isnot [int]) {
            Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] does not contain valid virtualProcs value [$($vm.virtualProcs)]. Specify desired virtualProcs without quotes; For example: 2" -ReturnObject $return -Failure
        }
        else {
            if ($vm.virtualProcs -gt 16) {
                Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] virtualProcs value [$($vm.virtualProcs)] is invalid. Specify a value from 1-16." -ReturnObject $return -Failure
            }
        }

        # Additional Disks
        if ($vm.additionalDisks) {
            $validLetters = 69..89 | ForEach-Object { [char]$_ }    # Letters E-Y

            $vm.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {

                # valid drive letter
                if ($_.Name.Length -ne 1 -or $validLetters -notcontains $_.Name) {
                    Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] contains invalid additional disks [$($vm.additionalDisks)]; Disks must have a single drive letter between E and Y." -ReturnObject $return -Failure
                }

                $size = $($vm.additionalDisks."$($_.Name)")
                if (-not $size.EndsWith("GB")) {
                    Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] contains invalid additional disks [$($vm.additionalDisks)]; Specify desired size in quotes with GB; For example: ""200GB""" -ReturnObject $return -Failure
                }
                if ($size.EndsWith("GB") -and $([int]$size.Replace("GB", "")) -lt 10 ) {
                    Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] contains invalid additional disks [$($vm.additionalDisks)]; Disks must be larger than 10GB" -ReturnObject $return -Failure
                }
                if ($size.EndsWith("GB") -and $([int]$size.Replace("GB", "")) -gt 1000 ) {
                    Add-ValidationFailure -Message "VM Validation: [$($vm.vmName)] contains invalid additional disks [$($vm.additionalDisks)]; Disks must be less than 1000GB" -ReturnObject $return -Failure
                }
            }
        }

        # sqlInstance dir
        if ($vm.sqlInstanceDir) {

            # path
            if (-not $vm.sqlInstanceDir.Contains(":\")) {
                Add-ValidationFailure -Message "VM Validation: VM [$($vm.vmName)] contains invalid sqlInstanceDir [$($vm.sqlInstanceDir)]. Value must be a valid path; For example: ""F:\SQL""." -ReturnObject $return -Failure
            }

            # valid drive
            $installDrive = $vm.sqlInstanceDir.Substring(0, 1)
            if ($installDrive -ne "C") {
                $defined = $vm.additionalDisks | Get-Member -Name $installDrive
                if (-not $defined) {
                    Add-ValidationFailure -Message "VM Validation: VM [$($vm.vmName)] contains invalid sqlInstanceDir [$($vm.sqlInstanceDir)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $return -Failure
                }
            }
        }

    }

    # DC Validation
    # ==============
    $existingDC = $configObject.vmOptions.existingDCNameWithPrefix
    if ($containsDC) {

        # OS Version
        if ($DCVM.operatingSystem -notlike "*Server*") {
            Add-ValidationFailure -Message "DC Validation: Domain Controller (DC Role) specified in configuration without a Server Operating System." -ReturnObject $return -Failure
        }

        if ($existingDC) {
            Add-ValidationFailure -Message "DC Validation: Domain Controller (DC Role) specified in configuration with vmOptions.existingDCNameWithPrefix. Adding a DC to existing environment is not supported." -ReturnObject $return -Failure
        }

        # DC VM count -eq 1
        if ($DCVM -is [object[]] -and $DCVM.Count -ne 1) {
            Add-ValidationFailure -Message "DC Validation: Multiple DC virtual Machines (DC Role) specified in configuration. Only single DC role is supported." -ReturnObject $return -Failure
        }

    }
    else {

        # Existing Scenario, without existing DC Name
        if (-not $existingDC) {
            Add-ValidationFailure -Message "DC Validation: DC role not specified in the configuration file and vmOptions.existingDCNameWithPrefix not present." -ReturnObject $return -Failure
        }

        if ($existingDC) {

            # Check VM
            $vm = Get-VM -Name $existingDC -ErrorAction SilentlyContinue
            if (-not $vm) {
                Add-ValidationFailure -Message "DC Validation: vmOptions.existingDCNameWithPrefix [$existingDC] specified in the configuration file but VM with the same name was not found in Hyper-V." -ReturnObject $return -Warning
            }

            # Check network
            $vmnet = Get-VM -Name $existingDC -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
            if ($vmnet.SwitchName -ne $configObject.vmOptions.network) {
                Add-ValidationFailure -Message "DC Validation: vmOptions.existingDCNameWithPrefix [$existingDC] specified in the configuration file but VM Switch [$($vmnet.SwitchName)] doesn't match specified network [$($configObject.vmOptions.network)]." -ReturnObject $return -Warning
            }
        }
    }

    # CS Validations
    # ==============
    if ($containsCS) {

        $csName = $CSVM.vmName

        # tech preview and CAS
        if ($configObject.cmOptions.version -eq "tech-preview") {
            Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] specfied along with Tech-Preview version; Tech Preview doesn't support CAS." -ReturnObject $return -Failure
        }

        # CAS without Primary
        if (-not $containsPS) {
            Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] specified without Primary Site (PS Role); When deploying CS Role, you must specify a PS Role as well." -ReturnObject $return -Failure
        }

        # CS must contain SQL
        if (-not $CSVM.sqlVersion) {
            Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] defined without specifying sqlVersion; When deploying CS Role, you must specify the SQL Version." -ReturnObject $return -Failure
        }

        # OS Version
        if ($CSVM.operatingSystem -notlike "*Server*") {
            Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] specified without a Server Operating System." -ReturnObject $return -Failure
        }

        # Site Code
        if ($CSVM.siteCode.Length -ne 3) {
            Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] contains invalid Site Code [$($CSVM.siteCode)]." -ReturnObject $return -Failure
        }

        # install dir
        if ($CSVM.cmInstallDir) {

            # valid drive
            $installDrive = $CSVM.cmInstallDir.Substring(0, 1)
            if ($installDrive -ne "C") {
                $defined = $CSVM.additionalDisks | Get-Member -Name $installDrive
                if (-not $defined) {
                    Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] contains invalid cmInstallDir [$($CSVM.cmInstallDir)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $return -Failure
                }
            }

            # path
            if (-not $CSVM.cmInstallDir.Contains(":\")) {
                Add-ValidationFailure -Message "CS Validation: CAS (CS Role) VM [$csName] contains invalid cmInstallDir [$($CSVM.cmInstallDir)]. Value must be a valid path; For example: ""E:\ConfigMgr""." -ReturnObject $return -Failure
            }
        }

        # CS VM count -eq 1
        if ($CSVM -is [object[]] -and $CSVM.Count -ne 1) {
            Add-ValidationFailure -Message "CS Validation: Multiple CS virtual Machines (CS Role) specified in configuration. Only single CS role is supported." -ReturnObject $return -Failure
        }

    }

    # PS Validations
    # ==============
    if ($containsPS) {

        $psName = $PSVM.vmName

        # PS must contain SQL
        if (-not $PSVM.sqlVersion) {
            Add-ValidationFailure -Message "PS Validation: Primary (PS Role) VM [$psName] specified without specifying sqlVersion; When deploying PS Role, you must specify the SQL Version." -ReturnObject $return -Failure
        }

        # OS Version
        if ($PSVM.operatingSystem -notlike "*Server*") {
            Add-ValidationFailure -Message "PS Validation: Primary (PS Role) VM [$psName] specified without a Server Operating System." -ReturnObject $return -Failure
        }

        # Site Code
        if ($PSVM.siteCode.Length -ne 3) {
            Add-ValidationFailure -Message "PS Validation: Primary (PS Role) VM [$psName] contains invalid Site Code [$($PSVM.siteCode)]." -ReturnObject $return -Failure
        }

        # install dir
        if ($PSVM.cmInstallDir) {

            # valid path
            $installDrive = $PSVM.cmInstallDir.Substring(0, 1)
            if ($installDrive -ne "C") {
                $defined = $PSVM.additionalDisks | Get-Member -Name $installDrive
                if (-not $defined) {
                    Add-ValidationFailure -Message "PS Validation: Primary (PS Role) VM [$psName] contains invalid cmInstallDir [$($PSVM.cmInstallDir)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $return -Failure
                }
            }

            # path
            if (-not $PSVM.cmInstallDir.Contains(":\")) {
                Add-ValidationFailure -Message "VM Validation: Primary (PS Role) VM [$psName] contains invalid cmInstallDir [$($PSVM.cmInstallDir)]. Value must be a valid path; For example: ""E:\ConfigMgr""." -ReturnObject $return -Failure
            }
        }

        # PS VM count -eq 1
        if ($PSVM -is [object[]] -and $PSVM.Count -ne 1) {
            Add-ValidationFailure -Message "PS Validation: Multiple PS virtual Machines (PS Role) specified in configuration. Only single PS role is currently supported." -ReturnObject $return -Failure
        }

    }

    # DPMP Validations
    # =================
    if ($containsDPMP) {

        # DPMP VM count -eq 1
        if ($DPMPVM -is [object[]] -and $DPMPVM.Count -ne 1) {
            Add-ValidationFailure -Message "DPMP Validation: Multiple DPMP virtual Machines (DPMP Role) specified in configuration. Only single DPMP role is currently supported." -ReturnObject $return -Failure
        }

        # OS Version
        if ($DPMPVM.operatingSystem -notlike "*Server*") {
            Add-ValidationFailure -Message "DPMP Validation: VM [$($DPMPVM.vmName)] has DPMP Role specified without a Server Operating System." -ReturnObject $return -Failure
        }

    }

    # Return if validation failed
    if ($return.Problems -ne 0) {
        $return.Message = $return.Message.ToString()
        return $return
    }

    # everything is good, create deployJson

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
    $network = $configObject.vmOptions.network.Substring(0, $configObject.vmOptions.network.LastIndexOf("."))
    $clientsCsv = ($virtualMachines | Where-Object { $_.role -eq "DomainMember" }).vmName -join ","
    $params = [PSCustomObject]@{
        DomainName         = $configObject.vmOptions.domainName
        DCName             = ($virtualMachines | Where-Object { $_.role -eq "DC" }).vmName
        CSName             = ($virtualMachines | Where-Object { $_.role -eq "CS" }).vmName
        PSName             = ($virtualMachines | Where-Object { $_.role -eq "PS" }).vmName
        DPMPName           = ($virtualMachines | Where-Object { $_.role -eq "DPMP" }).vmName
        DomainMembers      = $clientsCsv
        Scenario           = $scenario
        DHCPScopeId        = $configObject.vmOptions.Network
        DHCPDNSAddress     = $network + ".1"
        DHCPDefaultGateway = $network + ".200"
        DHCPScopeStart     = $network + ".20"
        DHCPScopeEnd       = $network + ".199"
        ThisMachineName    = $null
        ThisMachineRole    = $null
    }

    $deploy = [PSCustomObject]@{
        cmOptions       = $configObject.cmOptions
        vmOptions       = $configObject.vmOptions
        virtualMachines = $virtualMachines
        parameters      = $params
    }

    $return.Valid = $true
    $return.DeployConfig = $deploy

    return $return
}

Function Show-Summary {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsCustomObject]
        $config
    )

    $CHECKMARK = ([char]8730)

    if (-not $null -eq $($config.DeployConfig.cmOptions)) {
        if ($config.DeployConfig.cmOptions.install -eq $true) {
            Write-Host "[$CHECKMARK] ConfigMgr $($config.DeployConfig.cmOptions.version) will be installed and " -NoNewline
            if ($config.DeployConfig.cmOptions.updateToLatest -eq $true) {
                Write-Host "updated to latest"
            }
            else {
                Write-Host "NOT updated to latest"
            }
        }
        else {
            Write-Host "[x] ConfigMgr will not be installed."
        }

        if ($config.DeployConfig.cmOptions.installDPMPRoles) {
            Write-Host "[$CHECKMARK] DPMP roles will be pushed from the Configmgr Primary Server"
        }
        else {
            Write-Host "[x] DPMP roles will not be installed"
        }

        if ($config.DeployConfig.cmOptions.pushClientToDomainMembers) {
            Write-Host "[$CHECKMARK] ConfigMgr Clients will be installed on domain members"
        }
        else {
            Write-Host "[x] ConfigMgr Clients will NOT be installed on domain members"
        }

    }
    else {
        Write-Host "[x] ConfigMgr will not be installed."
    }

    if (-not $null -eq $($config.DeployConfig.vmOptions)) {

        Write-Host "[$CHECKMARK] Domain: $($config.DeployConfig.vmOptions.domainName) will be created. Admin account: $($config.DeployConfig.vmOptions.domainAdminName)"
        Write-Host "[$CHECKMARK] Network: $($config.DeployConfig.vmOptions.network)"
        Write-Host "[$CHECKMARK] Virtual Machine files will be stored in $($config.DeployConfig.vmOptions.basePath) on host machine"
    }

    $config.DeployConfig.virtualMachines | Format-Table | Out-Host
}

function Copy-SampleConfigs {

    $realConfigPath = $Common.ConfigPath
    $sampleConfigPath = Join-Path $Common.ConfigPath "samples"

    Write-Log "Copy-SampleConfigs: Checking if any sample configs need to be copied to config directory" -LogOnly -VerboseOnly
    foreach ($item in Get-ChildItem $sampleConfigPath -File -Filter *.json) {
        $copyFile = $true
        $sampleFile = $item.FullName
        $fileName = Split-Path -Path $sampleFile -Leaf
        $configFile = Join-Path -Path $realConfigPath $fileName
        if (Test-Path $configFile) {
            $sampleFileHash = Get-FileHash $sampleFile
            $configFileHash = Get-FileHash $configFile
            if ($configFileHash -ne $sampleFileHash) {
                Write-Log "Copy-SampleConfigs: Skip copying $fileName to config directory. File exists, and has different hash." -LogOnly -VerboseOnly
                $copyFile = $false
            }
        }

        if ($copyFile) {
            Write-Log "Copy-SampleConfigs: Copying $fileName to config directory." -LogOnly -VerboseOnly
            Copy-Item -Path $sampleFile -Destination $configFile -Force
        }
    }
}
