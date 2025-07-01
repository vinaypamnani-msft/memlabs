function Add-ValidationMessage {
    param (
        [string]$Message,
        [object]$ReturnObject,
        [switch]$Failure,
        [switch]$Warning
    )
    Write-Log -Verbose $Message
    $ReturnObject.Problems += 1
    [void]$ReturnObject.Message.AppendLine($Message)


    if ($Failure.IsPresent) {
        $ReturnObject.Failures += 1
    }

    if ($Warning.IsPresent) {
        $ReturnObject.Warnings += 1
    }
}

function Write-ValidationMessages {

    param (
        [object]$TestObject
    )

    $messages = $($TestObject.Message) -split "\r\n"
    foreach ($msg in $messages.Trim()) {
        Write-RedX $msg
    }
}
function Convert-ValidationMessages {

    param (
        [object]$TestObject
    )

    $messages = $($TestObject.Message) -split "\r\n"
    foreach ($msg in $messages.Trim()) {
        if (-not [string]::isnullorwhitespace($msg)) {
            Add-ErrorMessage -message $msg
        }
    }
}

function Test-ValidVmOptions {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    # prefix
    if (-not $ConfigObject.vmOptions.prefix) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.prefix not present in vmOptions. You must specify the prefix that will be added to name of Virtual Machine(s)." -ReturnObject $ReturnObject -Failure
    }

    $ExistingPrefixes = Get-list -type Prefix | where-object { $_.Domain -ne $ConfigObject.vmOptions.DomainName } | Select-Object -ExpandProperty Prefix

    if ($ConfigObject.vmOptions.prefix -in $ExistingPrefixes) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.prefix value [$($ConfigObject.vmOptions.prefix)] is already in use by another domain. You must specify a different prefix." -ReturnObject $ReturnObject -Failure
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

        #$netBiosDomain = $ConfigObject.vmOptions.domainName.Split(".")[0]
        $netBiosDomain = $ConfigObject.vmOptions.domainNetBiosName
        if ($netBiosDomain.Length -gt 15) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName [$($ConfigObject.vmOptions.domainName)] is too long. Netbios domain name [$netBiosDomain] must be less than 15 chars." -ReturnObject $ReturnObject -Failure
        }

        if ($netBiosDomain.Length -lt 1) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName  [$($ConfigObject.vmOptions.domainName)] is too short. Must be at least 1 chars." -ReturnObject $ReturnObject -Failure
        }
    }

    # adminName
    if (-not $ConfigObject.vmOptions.adminName) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.adminName not present in vmOptions. You must specify the Domain Admin user name that will be created." -ReturnObject $ReturnObject -Failure
    }
    else {

        Test-ValidUserName -name $ConfigObject.vmoptions.adminName -vmName "VM Options"
    }

    # network
    if (-not $ConfigObject.vmOptions.network) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.network not present in vmOptions. You must specify the Network subnet for the environment." -ReturnObject $ReturnObject -Failure
    }
    else {
        $pattern1 = "^(192.168)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]).0)$"
        $pattern2 = "^(10)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){2,2}.0$"
        $pattern3 = "^(172).(1[6-9]|2[0-9]|3[0-1])(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])).0$"

        

        if ($ConfigObject.vmOptions.network -eq "10.250.250.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'Cluster'. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }

        if ($ConfigObject.vmOptions.network -eq "10.1.0.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'External'. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }


        if ($ConfigObject.vmOptions.network -eq "172.31.250.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'Internet' clients. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }


        $networks = @($ConfigObject.vmOptions.network)

        foreach ($vm in $($ConfigObject.virtualMachines)) {
            if ($vm.network) {
                #write-log "Adding $($vm.network)"
                $networks += $vm.network
            }
        }
        $existingSubnets = Get-List -Type Network -SmartUpdate 
        foreach ($testNetwork in $networks) {
            write-log "testing $testNetwork" -Verbose
            if (-not ($testNetwork -match $pattern1 -or $testNetwork -match $pattern2 -or $testNetwork -match $pattern3)) {
                Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] value is invalid. You must specify a valid Class C Subnet. For example: 192.168.1.0" -ReturnObject $ReturnObject -Failure
            }

            $existingSubnet = $existingSubnets | Where-Object { $_.Network -eq $($testNetwork) }
            if ($existingSubnet) {
                if (-not ($($ConfigObject.vmoptions.domainName) -in $($existingSubnet.Domain))) {
                    Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] with vmOptions.domainName [$($ConfigObject.vmoptions.domainName)] is in use by existing Domain [$($existingSubnet.Domain)]. You must specify a different network" -ReturnObject $ReturnObject -Failure
                }

                $CASorPRIorSEC = ($ConfigObject.virtualMachines | where-object { $_.role -in "CAS", "Primary", "Secondary" -and (-not $_.Network) -and (-not $_.Hidden) })
                if ($CASorPRIorSEC) {
                    $existingCASorPRIorSEC = @()
                    $existingCASorPRIorSEC += Get-List -Type VM -SmartUpdate | Where-Object { $_.Network -eq $($testNetwork) } | Where-Object { ($_.Role -in "CAS", "Primary", "Secondary") }
                    if ($existingCASorPRIorSEC.Count -gt 0) {
                        if ($ConfigObject.vmOptions.domainName -ne $existingSubnet.Domain) {
                            Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] is in use by an existing SiteServer in [$($existingSubnet.Domain)]. You must specify a different network" -ReturnObject $ReturnObject -Warning
                        }
                    }

                }
            }
        }


    }
}

function Test-ValidCmOptions {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    # version
    if ($Common.Supported.CMVersions -notcontains $ConfigObject.cmOptions.version) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions contains invalid CM Version [$($ConfigObject.cmOptions.version)]. Must be one of [$($Common.Supported.CMVersions -join ',')]." -ReturnObject $ReturnObject -Failure
    }

    # install
    if ($ConfigObject.cmOptions.install -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.install has an invalid value [$($ConfigObject.cmOptions.install)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # pushClientToDomainMembers
    if ($ConfigObject.cmOptions.pushClientToDomainMembers -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.pushClientToDomainMembers has an invalid value [$($ConfigObject.cmOptions.pushClientToDomainMembers)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # pushClientToDomainMembers
    if ($ConfigObject.cmOptions.usePKI -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.usePKI has an invalid value [$($ConfigObject.cmOptions.usePKI)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    if ($ConfigObject.cmOptions.usePKI) {
        foreach ($vm in $ConfigObject.virtualMachines) {
            if ($vm.role -eq "DC" ) {
                if (-not $vm.InstallCA) {
                    Add-ValidationMessage -Message "CM Options Validation: cmOptions.usePKI is enabled but no CA is specified for DC [$($vm.vmName)]." -ReturnObject $ReturnObject -Failure
                }
            }            
        }
    }

}
function Test-MachineNameExists {
    param (
        [string] $name,
        [object] $ReturnObject,
        [object] $config

    )

    if (-not $name) {
        throw "Test-ValidMachineName called without a VMName"
    }

    write-log "Testing $name" -Verbose

    $nameWithPrefix = $config.vmOptions.prefix + $name
    $vm = Get-List2 -deployConfig $config -SmartUpdate | where-object { $_.vmName -eq $name -or $_.vmName -eq $nameWithPrefix }

    if (-not $vm) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid reference VM: $name. VM does not exist." -ReturnObject $ReturnObject -Warning
    }
}

function Test-ValidMachineName {
    param (
        [string] $name,
        [object] $ReturnObject
    )

    if (-not $name) {
        throw "Test-ValidMachineName called without a VMName"
    }

    write-log "Testing $name" -Verbose
    $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>_') + '\]' + '\"'+'\s')]"

    if ($name.Length -gt 15) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid name: $name. Windows computer name cannot be more than 15 characters long (Currently $($name.Length))." -ReturnObject $ReturnObject -Warning
    }

    if ($name -match $pattern) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] contains invalid characters in $name." -ReturnObject $ReturnObject -Failure
    }

    if ($name.EndsWith(".")) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] can not end with '.'." -ReturnObject $ReturnObject -Failure
    }
    
    if ($name -eq $env:COMPUTERNAME) {
        Add-ValidationMessage -Message "VM Validation: Domain Name [$name] is invalid. Can not be the same name as the Host VM [$($env:COMPUTERNAME)]." -ReturnObject $ReturnObject -Warning
    }
}

function Test-ValidUserName {
    param (
        [string] $name,
        [string] $vmName
    )

    if (-not $name) {
        return
    }
    if ($name -in "Administrator", "vmBuildAdmin" , "default" , "cm_svc" , "guest") {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] can not be a Reserved Name, as these accounts exist by default and can not be added" -ReturnObject $return -Warning
    }
    $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>') + '\]' + '\"'+'\s')]"
    if ($name -match $pattern) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] contains invalid characters. You must specify a valid domain username. For example: bob" -ReturnObject $return -Failure
    }

    if ($name.Length -gt 64) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] is too long. Must be less than 64 chars" -ReturnObject $return -Failure
    }

    if ($name.Length -lt 3) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] is too short. Must be at least 3 chars" -ReturnObject $return -Failure
    }
}

function Test-ValidVmSupported {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw "No VM provided"
    }

    $vmName = $VM.vmName

    if (-not ($vmName.StartsWith( $($ConfigObject.vmOptions.prefix) ) ) ) {
        $vmName = $($ConfigObject.vmOptions.prefix) + $vmName
    }
    Test-ValidMachineName $vmName -ReturnObject $ReturnObject

    if ($VM.remoteSQLVM) {
        Test-ValidMachineName $VM.remoteSQLVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.remoteSQLVM -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.fileServerVM) {
        Test-ValidMachineName $VM.fileServerVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.fileServerVM -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.pullDPSourceDP) {
        Test-ValidMachineName $VM.pullDPSourceDP -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.pullDPSourceDP -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.OtherNode) {
        Test-ValidMachineName $VM.OtherNode -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.OtherNode -ReturnObject $ReturnObject -config $ConfigObject        
    }

    if ($VM.AlwaysOnListenerName) {
        Test-ValidMachineName $VM.AlwaysOnListenerName -ReturnObject $ReturnObject
    }

    if ($VM.remoteContentLibVM) {
        Test-ValidMachineName $VM.remoteContentLibVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.remoteContentLibVM -ReturnObject $ReturnObject -config $ConfigObject
    }
    if ($VM.PatchMyPCFileServer) {
        Test-ValidMachineName $VM.PatchMyPCFileServer -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.PatchMyPCFileServer -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.ClusterName) {
        Test-ValidMachineName $VM.ClusterName -ReturnObject $ReturnObject
    }

    if ($VM.SqlInstanceName) {
        Test-ValidMachineName $VM.SqlInstanceName -ReturnObject $ReturnObject
    }


    # Supported OS
    if ($VM.role -ne "OSDClient") {
        if ($Common.Supported.OperatingSystems -notcontains $vm.operatingSystem) {
            if ((Get-LinuxImages).Name -notcontains $vm.operatingSystem) {
                Add-ValidationMessage -Message "VM Validation: [$vmName] does not contain a supported operatingSystem [$($vm.operatingSystem)]." -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # Windows 11 TPM
    if ($vm.operatingSystem -like "Windows 11*" -and $vm.tpmEnabled -eq $false) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] does not have TPM enabled (required for Windows 11)." -ReturnObject $ReturnObject -Failure
    }

    # Supported DSC Roles for Existing scenario
    if ($configObject.parameters.ExistingDCName) {
        # Supported DSC Roles for Existing Scenario
        if ($Common.Supported.RolesForExisting -notcontains $vm.role -and $vm.role -ne "DC") {
            # DC is caught in Test-ValidDC
            if ($vm.role -ne "Linux") {
                $supportedRoles = $Common.Supported.RolesForExisting -join ", "
                Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)] for existing environment. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
            }
        }
    }
    else {
        # Supported DSC Roles
        if ($Common.Supported.Roles -notcontains $vm.role) {
            if ($vm.role -ne "Linux") {
                $supportedRoles = $Common.Supported.Roles -join ", "
                Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)] for a new environment. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
            }
        }
    }

}

function Test-ValidVmMemory {
    param (
        [object] $VM,
        [object] $ReturnObject
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
        [object] $VM,
        [object] $ReturnObject
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
        [object] $VM,
        [object] $ReturnObject
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
        if ([int]$virtualProcs -gt 16 -or [int]$virtualProcs -lt 1) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] virtualProcs value [$virtualProcs] is invalid. Specify a value from 1-16." -ReturnObject $ReturnObject -Failure
        }
    }

}

function Test-ValidVmServerOS {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    if ($VM.operatingSystem -notlike "*Server*") {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid OS [$($VM.operatingSystem)]. OS must be a Server OS for Primary/CAS/SiteSystem roles, or when SQL is selected." -ReturnObject $ReturnObject -Warning
    }

}

function Test-ValidVmPath {
    param (
        [object] $VM,
        [string] $PathProperty,
        [string] $ValidPathExample,
        [object] $ReturnObject
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
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. A/B/D/Z drive letters are not allowed." -ReturnObject $ReturnObject -Failure
        }

        if ($installDrive -ne "C" -and -not $VM.additionalDisks) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must be defined." -ReturnObject $ReturnObject -Warning
        }

        if ($installDrive -ne "C" -and $VM.additionalDisks) {
            $defined = $VM.additionalDisks | Get-Member -Name $installDrive
            if (-not $defined) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $ReturnObject -Warning
            }
        }

    }
}

function Test-ValidRoleDC {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    $DCVM = $configObject.virtualMachines | Where-Object { $_.role -eq "DC" }
    $vmRole = "DC"

    $containsDC = $configObject.virtualMachines.role -contains "DC"
    $existingDC = $configObject.parameters.ExistingDCName
    $domain = $ConfigObject.vmOptions.domainName

    if ($containsDC) {

        if ($DCVM.Count -gt 1) {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple DC roles found in this domain [$domain]. Adding a DC to existing environment is not supported. (Use the BDC role instead)" -ReturnObject $ReturnObject -Warning
        }

        if ($existingDC) {
            if ($DCVM.VmName -ne $existingDC) {
                Add-ValidationMessage -Message "$vmRole Validation: DC Role specified in configuration and existing DC [$existingDC] found in this domain [$domain]. Adding a DC to existing environment is not supported. (Use the BDC role instead)" -ReturnObject $ReturnObject -Warning
            }
        }

        # $MyInvocation.BoundParameters.ConfigObject.VirtualMachines | Out-Host
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
            $vm = Get-List -type VM -SmartUpdate | Where-Object { $_.vmName -eq $existingDC }
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
                    Start-VM2 -Name $vm.vmName
                    $vm = Get-List -type VM -SmartUpdate
                    if ($vm.State -ne "Running") {
                        # VM Not running, cannot validate network
                        Add-ValidationMessage -Message "$vmRole Validation: Existing DC [$existingDC] found but VM is not Running." -ReturnObject $ReturnObject -Warning
                    }
                }

                # Account validation
                $vmProps = Get-List -Type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $_.role -eq "DC" }
                if ($vmProps.AdminName -ne $ConfigObject.vmOptions.adminName) {
                    Add-ValidationMessage -Message "Account Validation: Existing DC [$existingDC] is using a different admin name [$($ConfigObject.vmOptions.adminName)] for deployment. You must use the existing admin user [$($vmProps.AdminName)]." -ReturnObject $ReturnObject -Warning
                    Get-List -type VM -SmartUpdate | Out-Null
                }
            }
        }
    }
}

function Test-ValidRoleSiteServer {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Primary/CAS must contain SQL
    if (-not $VM.sqlVersion -and -not $VM.remoteSQLVM -and $vmRole -in ("CAS", "Primary")) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain sqlVersion; When deploying $vmRole Role, you must specify the SQL Version." -ReturnObject $ReturnObject -Warning
    }

    # Secondary parentSiteCode must belong to a Primary
    if ($VM.parentSiteCode -and $vmRole -eq "Secondary") {

        $anyPsInConfig = $ConfigObject.virtualMachines | Where-Object { $_.role -eq "Primary" }
        if ($anyPsInConfig) {
            #Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified with Primary Site which is currently not supported. Please add Secondary after building the Primary." -ReturnObject $return -Warning
        }

        $psInConfig = $ConfigObject.virtualMachines | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $VM.parentSiteCode }
        if (-not $psInConfig) {
            $primary = Get-SiteServerForSiteCode -deployConfig $ConfigObject -sitecode $VM.parentSiteCode -type VM
            if (-not $primary) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains parentSiteCode [$($VM.parentSiteCode)], but a primary site with this siteCode was not found." -ReturnObject $ReturnObject -Warning
            }
        }
    }

    # Remote SQL
    if ($VM.remoteSQLVM) {
        $sqlServerName = $VM.remoteSQLVM
        $SQLVM = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $sqlServerName }

        # Remote SQL must contain sqlVersion
        if ($SQLVM) {
            if (-not $SQLVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$sqlServerName] does not contain sqlVersion; When deploying $vmRole Role with remote SQL, you must specify the SQL Version for SQL VM." -ReturnObject $ReturnObject -Warning
            }
        }
        else {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$sqlServerName] does not exist; When deploying $vmRole Role with remote SQL, you must include the remote SQL VM." -ReturnObject $ReturnObject -Warning
            Write-Verbose "VMs are $($ConfigObject.virtualMachines.vmName)"
        }

        # Minimum Memory
        if ($VM.memory / 1 -lt 3GB) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] must contain a minimum of 3GB memory when using remote SQL." -ReturnObject $ReturnObject -Failure
        }

    }
    else {
        if ($VM.SqlVersion) {
            # Local SQL
            $minMem = 6
            if ($vmRole -eq "Secondary") { $minMem = 3 }
            if ($vmRole -eq "SiteSystem") { $minMem = 4 }
            # Minimum Memory
            if ($VM.memory / 1 -lt $minMem * 1GB) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has SQL; must contain a minimum of $($minMem)GB memory." -ReturnObject $ReturnObject -Failure
            }
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

    if ($vm.Role -in "CAS", "Primary", "Secondary" ) {
        $otherVMs = $ConfigObject.VirtualMachines | Where-Object { $_.vmName -ne $VM.vmName } | Where-Object { $null -ne $_.Sitecode } | Where-Object { $_.Role -in "CAS", "Primary", "Secondary" }
        foreach ($vmWithSiteCode in $otherVMs) {
            if ($VM.siteCode.ToUpperInvariant() -eq $vmWithSiteCode.siteCode.ToUpperInvariant() -and ($vmWithSiteCode.role -in "CAS", "Primary", "Secondary")) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] that is already used by another siteserver [$($vmWithSiteCode.vmName)]." -ReturnObject $ReturnObject -Failure
            }
        }

        $otherVMs = Get-List -type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $null -ne $_.siteCode } | Where-Object { $_.Role -in "CAS", "Primary", "Secondary" }
        foreach ($vmWithSiteCode in $otherVMs) {
            if ($VM.siteCode.ToUpperInvariant() -eq $vmWithSiteCode.siteCode.ToUpperInvariant() -and ($vmWithSiteCode.role -in "CAS", "Primary", "Secondary")) {
                if ($vmName -ne $($vmWithSiteCode.vmName)) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] that is already used by another siteserver [$($vmWithSiteCode.vmName)]." -ReturnObject $ReturnObject -Failure
                }
            }
        }
    }

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    # install dir
    Test-ValidVmPath -VM $VM -PathProperty "cmInstallDir" -ValidPathExample "E:\ConfigMgr" -ReturnObject $ReturnObject

}

function Test-ValidRolePassiveSite {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    # install dir
    Test-ValidVmPath -VM $VM -PathProperty "cmInstallDir" -ValidPathExample "E:\ConfigMgr" -ReturnObject $ReturnObject

    if (-not $VM.remoteContentLibVM) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain remoteContentLibVM; When deploying $vmRole Role, you must specify the FileServer where Content Library will be hosted." -ReturnObject $ReturnObject -Warning
    }

    if ($VM.remoteContentLibVM) {
        $fsInConfig = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $VM.remoteContentLibVM }
        if (-not $fsInConfig) {
            $fsVM = Get-List -type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $_.vmName -eq $VM.remoteContentLibVM }
        }
        else {
            $fsVM = $fsInConfig
        }

        if (-not $fsVM) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] configuration contains remoteContentLibVM [$($VM.remoteContentLibVM)] which does not exist in Configuration or Hyper-V." -ReturnObject $ReturnObject -Warning
        }

        if ($fsVM -and $fsVM.role -ne "FileServer") {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] configuration contains remoteContentLibVM [$($VM.remoteContentLibVM)] which currently has role [$($fsVM.role)]. remoteContentLibVM role must be FileServer." -ReturnObject $ReturnObject -Warning
        }
    }

    if (-not $VM.siteCode) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain siteCode; When deploying $vmRole Role, you must specify the siteCode of an Active Site Server." -ReturnObject $ReturnObject -Warning
    }
    else {
        $assInConfig = $ConfigObject.virtualMachines | Where-Object { $_.sitecode -eq $VM.siteCode -and ($_.role -eq "CAS" -or $_.role -eq "Primary") }
        if (-not $assInConfig) {
            $assVM = Get-ExistingSiteServer -DomainName $ConfigObject.vmOptions.DomainName -SiteCode $VM.siteCode

            if (($assVM | Measure-Object).Count -eq 0) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which doesn't belong to an existing Site Server." -ReturnObject $ReturnObject -Warning
            }

            if (($assVM | Measure-Object).Count -gt 1) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which already contains a passive site server." -ReturnObject $ReturnObject -Warning
            }
        }
    }
}

function Test-ValidRoleFileServer {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    if (-not $VM.additionalDisks) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain additionalDisks. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
    }
    else {
        $edrive = $VM.additionalDisks | Get-Member -Name "E"
        $fdrive = $VM.additionalDisks | Get-Member -Name "F"

        if (-not $edrive) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain E drive. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
        }

        if (-not $fdrive) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain F drive. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
        }
    }

}

function Test-ValidRoleSiteSystem {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Server OS
    if ($VM.installMP -or $VM.installSUP) {
        Test-ValidVmServerOS -VM $VM -ReturnObject $return
    }

    # Role allowed on CAS?
    $allowOnCAS = $true
    if ($VM.installMP -or $VM.installDP) {
        $allowOnCAS = $false
    }

    if (-not $VM.siteCode) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain siteCode; When deploying $vmRole Role, you must specify the siteCode of a Primary Site Server." -ReturnObject $ReturnObject -Warning
    }
    else {
        $ssInConfig = $ConfigObject.virtualMachines | Where-Object { $_.sitecode -eq $VM.siteCode -and ($_.role -in "Primary", "Secondary", "CAS") }
        if (-not $ssInConfig) {
            $ssVM = Get-ExistingSiteServer -DomainName $ConfigObject.vmOptions.DomainName -SiteCode $VM.siteCode
            if (($ssVM | Measure-Object).Count -eq 0) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which doesn't belong to an existing Site Server." -ReturnObject $ReturnObject -Warning
            }
        }
    }
    if (-not $allowOnCAS) {
        $casVM = Get-List2 -DeployConfig $ConfigObject | Where-Object { $_.role -eq "CAS" -and $_.siteCode -eq $VM.siteCode }
        if ($casVM) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a SiteSystem role (DP or MP) that is not allowed on CAS." -ReturnObject $ReturnObject -Warning
        }
    }

    if ($VM.pullDPSourceDP) {
        $source = Get-List2 -DeployConfig $ConfigObject | Where-Object { $_.vmName -eq $VM.pullDPSourceDP }
        if ($VM.SiteCode -ne $source.SiteCode) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which does not match Source DP [$($source.vmName)] sitecode [$($source.siteCode)]" -ReturnObject $ReturnObject -Warning
        }

    }

}

function Test-SingleRole {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        # $MyInvocation | Out-Host
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
        [object]$InputObject,
        [Parameter(Mandatory = $false, HelpMessage = "Fast Mode")]
        [switch]$Fast,
        [Parameter(Mandatory = $false, HelpMessage = "Final Test")]
        [switch]$Final
        #[Parameter(Mandatory = $false, ParameterSetName = "ConfigObject", HelpMessage = "Should we flush the cache to get accurate results?")]
        #[bool] $fast = $false
    )
    #Get-PSCallStack | out-host

    $disableSmartUpdateValue = (Get-Variable -Name 'DisableSmartUpdate' -Scope Global -ErrorAction SilentlyContinue).Value
    $OrigSmartUpdateValue = $disableSmartUpdateValue
    if ($null -eq $OrigSmartUpdateValue ) {
        $OrigSmartUpdateValue = $false
    }
    try {

        $return = [PSCustomObject]@{
            Valid        = $false
            DeployConfig = $null
            Message      = [System.Text.StringBuilder]::new()
            Failures     = 0
            Warnings     = 0
            Problems     = 0
        }
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Filepath" -PercentComplete 1
        if ($FilePath) {
            try {
                $configObject = Get-Content $FilePath -Force | ConvertFrom-Json
                #update cache, and then disable re-loading it until we complete
                get-list2 -deployConfig $configObject -SmartUpdate | out-null                                
                $global:DisableSmartUpdate = $true
            }
            catch {
                $return.Message = "Failed to load $FilePath as JSON. Please check if the config is valid or create a new one using genconfig.ps1"
                $return.Problems += 1
                $return.Failures += 1
                Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
                return $return
            }
        }

        if ($InputObject) {
            # Convert to Json and back to make a copy of the object, so the original is not modified
            try {
                $configObject = $InputObject | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            }
            catch {
                $return.Message = "Failed to load Config as JSON. Please check if the config is valid or create a new one using genconfig.ps1"
                $return.Problems += 1
                $return.Failures += 1
                Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
                return $return
            }
        }

        # InputObject could be blank
        # if (-not $InputObject -and -not $FilePath) {
        #     if ($InputObject -isnot [System.Management.Automation.PSCustomObject]) {
        #         $return.Message = "InputObject is invalid. Please check if the config is valid or create a new one using genconfig.ps1"
        #         $return.Problems += 1
        #         $return.Failures += 1
        #         return $return
        #     }
        # }

        # Get deployConfig without existing VM's for validation
        Write-Progress2 -Activity "Validating Configuration" -Status "Creating DeployConfig" -PercentComplete 5
        $deployConfig = New-DeployConfig -configObject $configObject

        #if ($deployConfig.virtualMachines.Count -eq 0) {
        #    $return.Message = "Configuration contains no Virtual Machines. Nothing to deploy."
        #    $return.Problems += 1
        #$return.Failures += 1
        #    Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
        #    return $return
        #}

        $virtualMachinesNoExisting = $deployConfig.virtualMachines | Where-Object { -not $_.Hidden }
        # Contains roles
        if ($deployConfig.virtualMachines) {
            $containsCS = $virtualMachinesNoExisting -contains "CAS"
            $containsPS = $virtualMachinesNoExisting -contains "Primary"
            $containsSiteSystem = $virtualMachinesNoExisting -contains "SiteSystem"
            $containsPassive = $virtualMachinesNoExisting -contains "PassiveSite"
            $containsSecondary = $virtualMachinesNoExisting -contains "Secondary"
        }
        else {
            $containsCS = $containsPS = $containsSiteSystem = $containsPassive = $containsSecondary = $false
        }

        $needCMOptions = $containsCS -or $containsPS -or $containsSiteSystem -or $containsPassive -or $containsSecondary

        # VM Options
        # ===========
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Vm Options" -PercentComplete 7
        Test-ValidVmOptions -ConfigObject $deployConfig -ReturnObject $return

        Test-ValidMachineName $deployConfig.vmOptions.domainNetBiosName -ReturnObject $return
        # CM Options
        # ===========

        # CM Version
        if ($needCMOptions) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing CM Options" -PercentComplete 8
            Test-ValidCmOptions -ConfigObject $deployConfig -ReturnObject $return
        }

        # VM Validations
        # ==============
        $i = 8
        foreach ($vm in $deployConfig.virtualMachines) {
            $vmName = $vm.VmName
            $i++
            if ($i -ge 35) {
                $i = 35
            }
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Vm $($vm.vmName)" -PercentComplete $i
            # Supported values
            Test-ValidVmSupported -VM $vm -ConfigObject $deployConfig -ReturnObject $return

            # Valid Memory
            Test-ValidVmMemory -VM $vm -ReturnObject $return

            # virtualProcs
            Test-ValidVmProcs -VM $vm -ReturnObject $return

            # Valid additionalDisks
            Test-ValidVmDisks -VM $vm -ReturnObject $return


            if ($vm.Role -eq "Primary") {
                $passiveSite = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" -and $_.siteCode -eq $vm.SiteCode }
                if ($passiveSite) {
                    write-log -verbose "Checking Passive Site Server has DP in sitecode"
                    $DPsForSiteCode = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "SiteSystem" -and $_.siteCode -eq $vm.SiteCode -and $_.installDP -eq $true }
                    if (-not $DPsForSiteCode) {
                        Add-ValidationMessage -Message "Passive Validation: [$($vm.vmName)] SiteCode $($vm.SiteCode) does not contain a DP which is needed with remote contentlib." -ReturnObject $return -Failure
                    }
                    else {
                        write-log -verbose "Passive Site has DP $($DPsForSiteCode.vmName)"
                    }
                }
            }

            if ($vm.sqlVersion) {

                # Supported SQL
                if ($Common.Supported.SqlVersions -notcontains $vm.sqlVersion) {
                    Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain a supported sqlVersion [$($vm.sqlVersion)]." -ReturnObject $return -Failure
                }

                # Server OS
                Test-ValidVmServerOS -VM $vm -ReturnObject $return

                # sqlInstance dir
                Test-ValidVmPath -VM $vm -PathProperty "sqlInstanceDir" -ValidPathExample "F:\SQL" -ReturnObject $return

                # sqlInstanceName
                if (-not $vm.sqlInstanceName) {
                    Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain sqlInstanceName." -ReturnObject $return -Warning
                }

                if ($vm.Role -ne "Secondary") {
                    if (-not $vm.sqlport) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain sqlport." -ReturnObject $return -Warning
                    }

                    # Put number first to force numeric comparisons
                    if ((1 -gt $vm.sqlport) -or (65535 -lt $vm.sqlport)) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] sqlport: $($vm.sqlport) Out of range" -ReturnObject $return -Warning
                    }

                    if ($vm.sqlport -in 21, 80, 135, 139, 443, 445, 860, 1434, 2382, 2383, 2393, 2394, 2725, 3260, 3389, 4022, 5022, 7022) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] sqlPort can not use OS reserved port #" -ReturnObject $return -Warning
                    }
                }
                # Minimum SQL Memory
                if ($VM.memory / 1 -lt 4GB) {
                    Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] must contain a minimum of 4GB memory when using SQL." -ReturnObject $return -Failure
                }

                if ($vm.Role -eq "SQLAO") {
                    if ($vm.sqlport -ne 1433) {
                        Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] SQL Port must be 1433 on SQLAO due to issue SqlServerDSC #329" -ReturnObject $return -Failure
                    }
                }
            }

            # WSUS Validations
            # ================
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing WSUS" -PercentComplete 37
            if ($vm.Role -eq "WSUS" -or $vm.InstallSUP) {
                if (-not $vm.wsusContentDir) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not have a wsusContentDir." -ReturnObject $return -Failure
                }
                if ($vm.InstallSup -and -not $vm.SiteCode) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not have a SiteCode." -ReturnObject $return -Failure
                }

                if ($vm.InstallSUP) {                  
                    $property = $vm
                    if ($property.ParentSiteCode -or $property.SiteCode) {
                        $sitecode = $property.SiteCode                    
                        if ($sitecode) {
                            $Parent = Get-ParentSiteServerForSiteCode -deployConfig $deployConfig -siteCode $sitecode -type VM -SmartUpdate:$false
                         
                            if ($Parent.SiteCode) {
                                $list2 = Get-List2 -deployConfig $deployConfig
                                $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $Parent.SiteCode }
                                if (-not $existingSUP) {                                                       
                                    Add-ValidationMessage -Message "$vmName SUP role can not be installed on downlevel sites until the parent site ($($Parent.SiteCode)) has a SUP" -ReturnObject $return -Failure
                                }
                            }
                            else {
                                if ($vm.role -eq "CAS") {                     
                                    #Get a list of child site codes
                                    $childSiteCodes = $deployConfig.virtualMachines | Where-Object { $_.ParentSiteCode -eq $sitecode } | Select-Object -ExpandProperty SiteCode -Unique

                                    # This is the Top Level Site, Child sites should have a SUP role. Validate that.
                                    $childSites = $deployConfig.virtualMachines | Where-Object { $_.SiteCode -in $childSiteCodes -and $_.InstallSUP }
                                    if ($childSites.Count -eq 0) {
                                        Add-ValidationMessage -Message "$vmName SUP role can not be installed on the CAS site ($($sitecode)) without a Primary site having a SUP role." -ReturnObject $return -Failure
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Test-ValidUserName -name $vm.domainUser -vmname $vm.vmName

        }

        # DC Validation
        # ==============
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing DC" -PercentComplete 35
        Test-ValidRoleDC -ConfigObject $deployConfig -ReturnObject $return

       

        # CAS Validations
        # ==============
        if ($containsCS) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing CAS" -PercentComplete 39
            $CSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "CAS" }
            foreach ($CSVM in $CSVMs) {
                $vmName = $CSVM.vmName
                $vmRole = $CSVM.role

                # Single CAS
                #if (Test-SingleRole -VM $CSVM -ReturnObject $return) {

                # CAS without Primary
                if (-not $containsPS) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified without Primary Site; When deploying CAS Role, you must add a Primary Role as well." -ReturnObject $return -Warning
                }

                # Validate CAS role
                #Test-ValidRoleSiteServer -VM $CSVM -ConfigObject $deployConfig -ReturnObject $return

                #}
            }
        }

        #siteName Validations
        # ==============

        foreach ($vm in $deployConfig.virtualMachines) {
            if ($vm.siteName) {
                if ($vm.siteName.Length -gt 127) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$($vm.vmName)] siteName is greater than 127 chars" -ReturnObject $return -Warning
                }
            }
            if ($vm.SiteCode) {
                Test-ValidRoleSiteServer -VM $vm -ConfigObject $deployConfig -ReturnObject $return
            }
        }

        # Primary Validations
        # ==============
        if ($containsPS) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Primary" -PercentComplete 42
            # Validate Primary role
            $PSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" }

            # if (Test-SingleRole -VM $PSVM -ReturnObject $return) {

            foreach ($PSVM in $PSVMs) {

                $vmName = $PSVM.vmName
                $vmRole = $PSVM.role
                $psParentSiteCode = $PSVM.parentSiteCode
                #Test-ValidRoleSiteServer -VM $PSVM -ConfigObject $deployConfig -ReturnObject $return

                # Valid parent Site Code
                if ($psParentSiteCode) {
                    $casSiteCodes = Get-ValidCASSiteCodes -Config $deployConfig -Domain $deployConfig.vmOptions.domainName
                    $parentCodes = $casSiteCodes -join ","
                    if ($psParentSiteCode -notin $casSiteCodes) {
                        Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] contains parentSiteCode [$psParentSiteCode] which is invalid. Valid Parent Site Codes: $parentCodes" -ReturnObject $return -Warning
                    }
                }

                # Other Site servers must be running
                if ($psParentSiteCode -and $deployConfig.cmOptions.updateToLatest) {
                    $notRunning = Get-ExistingSiteServer -DomainName $deployConfig.vmOptions.domainName | Where-Object { $_.State -ne "Running" }
                    $notRunningNames = $notRunning.vmName -join ","
                    if ($notRunning.Count -gt 0) {
                        Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] requires other site servers [$notRunningNames] to be running." -ReturnObject $return -Warning
                        Get-List -type VM -SmartUpdate | Out-Null
                    }
                }

                # CAS with Primary, without parentSiteCode
                if ($containsCS) {
                    if ($psParentSiteCode -notin $CSVMs.siteCode) {
                        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified with CAS, but parentSiteCode [$psParentSiteCode] does not match CAS Site Code [$($CSVM.siteCode)]." -ReturnObject $return -Warning
                    }
                }

            }
        }

        # Secondary Validations
        # ======================
        if ($containsSecondary) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Secondary" -PercentComplete 45
            $SecondaryVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" }

            #if (Test-SingleRole -VM $SecondaryVMs -ReturnObject $return) {

            # Prep for multi-subnet, but blocked right now by Test-SingleRole
            foreach ($SECVM in $SecondaryVMs) {
                #Test-ValidRoleSiteServer -VM $SECVM -ConfigObject $deployConfig -ReturnObject $return
            }

            #}

        }

        # Passive Validations
        # ===================
        if ($containsPassive) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Passive" -PercentComplete 50
            $passiveVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }

            foreach ($VM in $passiveVM) {
                Test-ValidRolePassiveSite -VM $VM -ConfigObject $deployConfig -ReturnObject $return
            }

        }

        # FileServer Validations
        # ======================
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing FileServer" -PercentComplete 55
        $FSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "FileServer" }
        foreach ($FSVM in $FSVMs) {
            Test-ValidRoleFileServer -VM $FSVM -ReturnObject $return
        }

        # Site System Validations
        # ========================
        if ($containsSiteSystem) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Site System" -PercentComplete 60
            $systems = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" }

            foreach ($VM in $systems) {
                Test-ValidRoleSiteSystem -VM $VM -ReturnObject $return
            }
        }

        # Role Conflicts
        # ==============
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Roles" -PercentComplete 65
        # CAS/Primary must include DC
        if (($containsCS -or $containsPS) -and -not $deployConfig.parameters.DCName ) {
            Add-ValidationMessage -Message "Role Conflict: CAS or Primary role specified but a new/existing DC was not found; CAS/Primary roles require a DC." -ReturnObject $return -Warning
        }

        # Primary site without CAS
        $PSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" -and $_.parentSiteCode }
        foreach ($PSVM in $PSVMs) {
            $existingCS = Get-List2 -DeployConfig $deployConfig | Where-Object { $_.role -eq "CAS" -and $_.siteCode -eq $PSVM.parentSiteCode }
            if (-not $existingCS) {
                Add-ValidationMessage -Message "Role Conflict: $($PSVM.vmName) with parentSiteCode $($PSVM.parentSiteCode) requires a CAS, which was not found." -ReturnObject $return -Warning
            }
        }

        # Secondary site without parent
        $SSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" }
        foreach ($SSVM in $SSVMs) {
            $existingPS = Get-List2 -DeployConfig $deployConfig | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $SSVM.parentSiteCode }
            if (-not $existingPS) {
                Add-ValidationMessage -Message "Role Conflict: $($SSVM.vmName) with parentSiteCode [$($SSVM.parentSiteCode)] requires a Primary, which was not found." -ReturnObject $return -Warning
            }
        }

        # tech preview and hierarchy
        if ($deployConfig.cmOptions.version -eq "tech-preview") {
            $anyPS = $deployConfig.VirtualMachines | Where-Object { $_.role -eq "Primary" }
            if ($anyPS.Count -gt 1) {
                Add-ValidationMessage -Message "Version Conflict: Tech-Preview specfied with more than one Primary; Tech Preview doesn't support support multiple sites." -ReturnObject $return -Warning
            }
            if ($anyPS.Count -eq 1) {
                if ($anyPS.parentSiteCode) {
                    Add-ValidationMessage -Message "Version Conflict: Tech-Preview specfied with a parent Site Code [$($anyPS.parentSiteCode)]; Tech Preview doesn't support support a Hierarchy." -ReturnObject $return -Warning
                }
            }
            $anyCS = $deployConfig.VirtualMachines | Where-Object { $_.role -eq "CAS" }
            if ($anyCS) {
                Add-ValidationMessage -Message "Version Conflict: Tech-Preview specfied with a CAS; Tech Preview doesn't support CAS." -ReturnObject $return -Warning
            }
        }

        # Total Memory
        # =============
        if ($final) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Memory" -PercentComplete 75

            $vms = $deployConfig.virtualMachines
            $runningVMs = (get-vm | Where-Object { $_.State -eq "Running" }).Name
            $newvms = @()
            foreach ($vm in $vms) {
                if ($vm.vmName -in $runningVMs) {
                    continue;
                }

                $newvms += $vm
            }
            $totalMemory = $newvms.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum
            $totalMemory = $totalMemory.Sum / 1GB
            $availableMemory = Get-AvailableMemoryGB

            if ($totalMemory -gt $availableMemory) {
                if (-not $enableDebug) {
                    Add-ValidationMessage -Message "Deployment Validation: Total Memory Required [$($totalMemory)GB] is greater than available memory [$($availableMemory)GB] [8GB buffer]." -ReturnObject $return -Warning
                }
            }
        }


        # Test URLS
        # ==========

        if ($final) {
            Write-Progress2 -Activity "Testing URLS" -Status "Testing URLS" -PercentComplete 77
            Write-Host
            Write-Log -SubActivity "Testing URLS"

            if (-not $Common.AzureFileList.Urls) {
                Add-ValidationMessage -Message "Deployment Validation: No URLs found to test." -ReturnObject $return -Error                
            }
            else {
                $Common.AzureFileList.Urls | ForEach-Object {
                    $_.psobject.properties | ForEach-Object {
                        try {
                            if (-not (Test-URL -url $_.value -name $_.name )) {
                                Add-ValidationMessage -Message "Deployment Validation: URL $($_.value) for $($_.name) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                            }
                        }
                        catch {
                            Add-ValidationMessage -Message "Error occurred while testing URL $($_.value) for $($_.name): $($_.Exception.Message)" -ReturnObject $return -Error
                        }
                    }
                }
            }
           

            foreach ($version in $common.AzureFileList.CmVersions) {
                try {
                    if (-not (Test-URL -url $version.downloadurl -name $version.baselineVersion )) {
                        Add-ValidationMessage -Message "Deployment Validation: URL $($version.downloadurl) for CM Version $($version.baselineVersion) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                    }
                }
                catch {
                    Add-ValidationMessage -Message "Error occurred while testing URL $($version.downloadurl) for CM Version $($version.baselineVersion): $($_.Exception.Message)" -ReturnObject $return -Error
                }
            }

            foreach ($sql in $common.AzureFileList.ISO) {
                try {
                    if (-not (Test-URL -url $sql.cuUrl -name $sql.id )) {
                        Add-ValidationMessage -Message "Deployment Validation: CU URL $($sql.cuUrl) for SQL Version $($sql.id) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                    }
                }
                catch {
                    Add-ValidationMessage -Message "Error occurred while testing CU URL $($sql.cuUrl) for SQL Version $($sql.id): $($_.Exception.Message)" -ReturnObject $return -Error
                }
            }

        }

        # Unique Names
        # =============

        # Names in deployment
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Unique Names" -PercentComplete 80
        $vmInDeployment = $virtualMachinesNoExisting.vmName
        if ($vmInDeployment) {
            $unique1 = $vmInDeployment | Select-Object -Unique
            $compare = Compare-Object -ReferenceObject $vmInDeployment -DifferenceObject $unique1
            if ($compare) {
                $duplicates = $compare.InputObject -join ","
                Add-ValidationMessage -Message "Name Conflict: Deployment contains duplicate VM names [$duplicates]" -ReturnObject $return -Warning
            }
        }

        if ($compare) {
            # Names in domain
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Unique Names" -PercentComplete 85
            $allVMs = Get-List -Type VM -SmartUpdate | Select-Object -Expand VmName
            $all = $allVMs + $vmInDeployment
            $unique2 = $all | Select-Object -Unique
            if (($null -ne $unique2) -and ($null -ne $all)) {
                $compare2 = Compare-Object -ReferenceObject $all -DifferenceObject $unique2
                if (-not $compare -and $compare2) {
                    $duplicates = $compare2.InputObject -join ","
                    Add-ValidationMessage -Message "Name Conflict: Deployment contains VM names [$duplicates] that are already in Hyper-V. You must add new machines with different names." -ReturnObject $return -Warning
                    Get-List -type VM -SmartUpdate | Out-Null
                }
            }
        }

        if (-not $fast) {
            # Add existing VM's
            Write-Progress2 -Activity "Validating Configuration" -Status "Adding Existing" -PercentComplete 90
            Add-ExistingVMsToDeployConfig -config $deployConfig

            # Add thisParams
            $deployConfigEx = ConvertTo-DeployConfigEx -deployConfig $deployConfig
            $return.DeployConfig = $deployConfigEx
        }
        else {
            $return.DeployConfig = $deployConfig
        }


        if ($global:SkipValidation) {
            $return.Message = $null
            $return.Valid = $true
            $return.Problems = 0
            $return.Failures = 0
            return $return
        }

        # Return if validation failed
        if ($return.Problems -ne 0) {
            $return.Message = $return.Message.ToString().Trim()
            Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
            return $return
        }

        # everything is good
        $return.Valid = $true
        Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
        return $return
    }
    catch {
        $return.Message = $_
        $return.Problems += 1
        #$return.Failures += 1
        Write-Exception -ExceptionInfo $_
        Write-Progress2 -Activity "Validating Configuration"  -Completed        
        return $return
    }
    finally {        
        $global:DisableSmartUpdate = $OrigSmartUpdateValue
        Write-Progress2 -Activity "Validating Configuration"  -Completed
    }
}
