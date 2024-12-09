#perfloading.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

if ( -not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json


if ($deployConfig.cmOptions.PrePopulateObjects -eq $false) {
    return
}

# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$DCName = ($deployConfig.virtualMachine | Where-Object { $_.Role -eq "DC" }).vmName
# Read Site Code from registry
#Write-DscStatus "Setting PS Drive for ConfigMgr" -NoStatus
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
$ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name

# Get CM module path
$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
$subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
$uiInstallPath = $subKey.GetValue("UI Installation Directory")
$modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
$initParams = @{}

# Import the ConfigurationManager.psd1 module
if ($null -eq (Get-Module ConfigurationManager)) {
    Import-Module $modulePath
}

# Connect to the site's drive if it is not already present
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
$psDriveFailcount = 0
while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    $psDriveFailcount++
    if ($psDriveFailcount -gt 20) {
        Write-DscStatus "Failed to get the PS Drive for site $SiteCode.  Install may have failed. Check C:\ConfigMgrSetup.log" -NoStatus
        return
    }
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoStatus
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams



#create all DPs group to distribute the content (its easier to distribute the content to a DP group than enumurating all DPs)
$DPGroupName = "ALL DPS"
$checkDP = Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name 

if ($DPGroupName -eq $checkDP) {

    Write-DscStatus "DP group: $DPGroupName already exists"

}
else { 
    $DPGroup = New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue

    # Get all Distribution Points
    $DistributionPoints = Get-CMDistributionPoint -AllSite

    # Display each Distribution Point's name without the leading '\\'
    $DistributionPoints | ForEach-Object {
        $DPPath = $_.NetworkOSPath
        $DPName = ($DPPath -replace "^\\\\", "") -split "\\" | Select-Object -First 1
        Write-DscStatus "Distribution Point Name: $DPName"
        try {
            Add-CMDistributionPointToGroup -DistributionPointGroupName "ALL DPS" -DistributionPointName $DPName 
            Write-DscStatus "Successfully added Distribution Point: $DPName to Group: $($DPGroupName)"
        }
        catch {
            Write-DscStatus "Failed to add Distribution Point: $DPName to Group: $($DPGroupName). Error: $_"
        }
    }
}

#Applications and packages


$apps = $deployconfig.Tools | where-object { $_.Appinstall -eq $True }
$apps | ForEach-Object {
    
    Write-DscStatus "Creating a directory under c:\apps for the application $($_.Name)"
    #create a directory for the application source files
    new-item -ItemType Directory -Path "c:\Apps\$($_.Name)" -force
    Write-DscStatus "Successfully created directory under c:\apps for the application $($_.Name)"


    Write-DscStatus "Creating a Hardlink under c:\apps for the application $($_.Name) "
    #create a hardlink for the source file (this is to save space on the C drive)
    new-item -ItemType HardLink -Value "c:\tools\$($_.AppMsi)" -Path "C:\Apps\$($_.Name)\$($_.AppMsi)" -force
    Write-DscStatus "Successfully created Hardlink under c:\apps for the application $($_.Name)"

    #creating an application
    $appname = "MEMLABS-" + "$($_.Name)" 
    Write-DscStatus "Creating an MEMLBAS application for $($_.Name) as App model"
    New-CMApplication -Name "$appname" -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue
    Write-DscStatus "Successfully created an MEMLBAS application for $($_.Name) as App model"
    #remove an application
    #Remove-CMApplication -Name "MEMLABS-*" -Force

    Write-DscStatus "Creating an MEMLBAS application deployment for $($_.Name) as App model"
    #create a deployment for each application (tim help on pulling the site server name)
    Add-CMMSiDeploymentType -ApplicationName "$appname" -DeploymentTypeName $($_.AppMsi) -ContentLocation "\\$ThisMachineName\c$\Apps\$($_.Name)\$($_.AppMsi)" -Comment "$($_.Name) MSI deployment type" -Force -ErrorAction SilentlyContinue
    Write-DscStatus "Sucessfully an MEMLBAS application deployment for $($_.Name) as App model"

    Write-DscStatus "Distributing MEMLBAS application $($_.Name) to all DPs"
    #distribute the content to All DPs
    Start-CMContentDistribution -ApplicationName "$appname" -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
    Write-DscStatus "Successfully distributed MEMLBAS application $($_.Name) to all DPs"

    Write-DscStatus "Deploying MEMLBAS application $($_.Name) to all Systems as available deployment"
    #deploy apps to all systems
    New-CMApplicationDeployment -ApplicationName "$appname" -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue
    Write-DscStatus "Succesfully deployed MEMLBAS application $($_.Name) to all Systems as available deployment"

    Write-DscStatus "Creating an MEMLBAS application deployment for $($_.Name) as Package model"
    # Create the Package
    $Package = New-CMPackage -Name "MEMLABS-$($_.Name)" -Path "\\$ThisMachineName\c$\Apps\$($_.Name)" -Description "Package for $($_.Description)"
    Write-DscStatus "Sucessfully created a MEMLBAS application deployment for $($_.Name) as Package model"
    #Remove a package
    #Remove-CMPackage -Id "CS100023" -Force

    Write-DscStatus "Creating an MEMLBAS pacakage deployment for $($_.Name) as Package model"
    $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn /l*v c:\windows\temp\$($_.Name).log"
    # Create a Program for the Package
    New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 
    Write-DscStatus "Sucessfully created a MEMLBAS pacakage deployment for $($_.Name) as Package model"

    Write-DscStatus "Distributing MEMLBAS pacakage $($_.Name) to all DPs"
    #Distribute all packages to ALL DPs group
    Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
    Write-DscStatus "Successfully distributed MEMLBAS package $($_.Name) to all DPs"

    Write-DscStatus "Deploying MEMLBAS package $($_.Name) to all Systems as available deployment"
    #Deploy all packages to all systems
    New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
    Write-DscStatus "Succesfully deployed MEMLBAS package $($_.Name) to all Systems as available deployment"
}


## Changing the auto-approval setting on Heirarchy settings

$namespace = "ROOT\SMS\site_$SiteCode"
$classname = "SMS_SCI_SiteDefinition"

Write-Dscstatus "Current namespace is: $namespace and class name is: $classname"

# Fetch the instance of the class
$instance = Get-CimInstance -ClassName $className -Namespace $namespace -Filter "SiteCode like '$SiteCode'"

if ($instance -ne $null) {
    Write-Dscstatus "Instance found: modifying existing instance."

    # Get the Props array
    $propsArray = $instance.Props

    # Locate the TwoKeyApproval property
    $propertyFound = $false
    for ($i = 0; $i -lt $propsArray.Length; $i++) {
        if ($propsArray[$i].PropertyName -eq "TwoKeyApproval") {
            $propertyFound = $true
            Write-Dscstatus "Current property name is: $propsArray[$i].PropertyName and its value is $propsArray[$i].Value"
            Write-Dscstatus "Setting the value to 0 to override the self-approval for author."
            $propsArray[$i].Value = 0 # Set your desired value here

            # Update the Props array in the instance
            $instance.Props = $propsArray

            # Save the modified instance back to the class
            Set-CimInstance -InputObject $instance

            Write-DscStatus "TwoKeyApproval value updated successfully."
            break
        }
    }

    if (-not $propertyFound) {
        Write-DscStatus "Property 'TwoKeyApproval' not found in existing instance. Adding it."
      
     $class = Get-CimClass -ClassName "SMS_EmbeddedProperty" -Namespace $namespace
     $i = New-CimInstance -CimClass $class -Property @{PropertyName="TwoKeyApproval";Value="0";Value1=$null;Value2=$null}
     $propsArray += $i
        $instance.Props = $propsArray
        Set-CimInstance -InputObject $instance
        Write-DscStatus "TwoKeyApproval property added and value set successfully."

    }
        
}
else {
    Write-Dscstatus "Instance not found. Manually approve the scripts"
}
Write-DscStatus "New instance created with TwoKeyApproval set to 0."


## Scripts ( used our scripts from Wiki)

# Get all PowerShell script files (.ps1) in the folder and its subfolders
$ScriptFiles = Get-ChildItem -Path C:\tools\Scripts -Recurse -Filter *.ps1

# Loop through each script file and import it into SCCM
foreach ($ScriptFile in $ScriptFiles) {
    $ScriptName = "MEMLABS-" + [System.IO.Path]::GetFileNameWithoutExtension($ScriptFile.FullName)
    $ScriptContent = Get-Content -Path $ScriptFile.FullName -Raw

    # Create a new script in SCCM using New-CMScript
    try {

        #check if script already exists or else create it
        if (-not (Get-CMScript -ScriptName $ScriptName -Fast)) {
            $script = New-CMScript -ScriptName "$ScriptName" -ScriptText $ScriptContent -Fast
            Write-DscStatus "Successfully imported: $ScriptName"
            # Approve the script by Guid, this is not working as it requires a diff author or the checkmark to be removed (set-cmheirarchysettings doesnt have that feature yet) Tim help needed here
            Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved" 

            ##for testing if you want to remove all the scripts
            #Remove-CMScript -ForceWildcardHandling -ScriptName * -Force
        }
    }
    catch {
        Write-DscStatus "Failed to import: $ScriptName. Error: $_"
    }
}


<## Task sequences 

# Get all boot images
$BootImages = Get-CMBootImage

# Loop through each boot image and distribute it
foreach ($BootImage in $BootImages) {
    try {
        $packageId = $BootImage.PackageID
        # Distribute the boot image
        Start-CMContentDistribution -BootImageId $packageId -DistributionPointGroupName "ALL DPS"        
        Write-DscStatus "Successfully started distribution for boot image: $($BootImage.Name)"
    }
    catch {
        Write-DscStatus "Failed to start distribution for boot image: $($BootImage.Name). Error: $_"
    }
}


#Tim help here to copy the images locally

#get OS upgrade package 
New-CMOperatingSystemInstaller -Name "Windows 11 latest" -Path "\\$ThisMachineName\osd\windows11" -Version 10.0.22621.1 -Index 6

#get OS pacakge
New-CMOperatingSystemImage -Name "Windows 11 " -Path "\\$ThisMachineName\osd\windows11\sources\install.wim" -Version 10.0.22621.2861



# Define variables for TS
#$TaskSequenceName = "Windows 11 In-Place Upgrade Task Sequence"
$UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 11" | Select-Object -ExpandProperty PackageID
$BootImagePackageID = Get-CMBootImage | Where-Object { $_.Name -eq "Boot image (x64)" }  | Select-Object -ExpandProperty PackageID
$OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 11" | Select-Object -ExpandProperty PackageID
$ClientPackagePackageId = Get-CMPackage -Fast -Name "Configuration Manager Client Package" | Select-Object -ExpandProperty PackageID
$UserStateMigrationToolPackageId = Get-CMPackage -Fast -Name "User State Migration Tool for Windows" | Select-Object -ExpandProperty PackageID
#tim help here for calling the cas or primary site
$UpgradeOperatingSystempath = "\\$ThisMachineName\osd\windows11"  
$UpgradeOperatingSystemWim = "\\$ThisMachineName\osd\sources\install.wim"
$clientProps = '/mp:mp01.contoso.com CCMDEBUGLOGGING="1" CCMLOGGINGENABLED="TRUE" CCMLOGLEVEL="0" CCMLOGMAXHISTORY="5" CCMLOGMAXSIZE="10000000" SMSCACHESIZE="15000" SMSMP=mp01.contoso.com'


# Create the inplace upgrade task sequence
New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS - In-Place Upgrade Task Sequence" -UpgradePackageId $UpgradePackageID -SoftwareUpdateStyle All


## Build and capture TS

$buildandcapture = @{
    BuildOperatingSystemImage          = $true
    Name                               = "MEMLABS - Build and capture"
    Description                        = "NewBuildOSImage parameter set"
    BootImagePackageId                 = $BootImagePackageID
    HighPerformance                    = $true
    ApplyAll                           = $false
    OperatingSystemImagePackageId      = $OSimagepackageID
    OperatingSystemImageIndex          = 1
    ProductKey                         = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
    GeneratePassword                   = $true
    TimeZone                           = Get-TimeZone -Name "Eastern Standard Time"
    JoinDomain                         = "WorkgroupType"
    WorkgroupName                      = "groupwork"
    ClientPackagePackageId             = $ClientPackagePackageId
    InstallationProperty               = $clientProps
    ApplicationName                    = "Admin Console"
    IgnoreInvalidApplication           = $true
    SoftwareUpdateStyle                = "All"
    OperatingSystemFilePath            = $UpgradeOperatingSystemWim
    ImageDescription                   = "image description"
    ImageVersion                       = "image version 1"
    CreatedBy                          = "MEMLABS"
    OperatingSystemFileAccount         = "contoso\jqpublic" 
    OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "w%1H6EoxjQ&70^W" -AsPlainText -Force
}

New-CMTaskSequence @buildandcapture


##Create a task sequence to install an OS image

$installOSimage = @{
    InstallOperatingSystemImage     = $true
    Name                            = "MEMLABS - Install OS image"
    Description                     = "NewInstallOSImage parameter set"
    BootImagePackageId              = $BootImagePackageID
    HighPerformance                 = $true
    CaptureNetworkSetting           = $true
    CaptureUserSetting              = $true
    SaveLocally                     = $true
    CaptureLocallyUsingLink         = $true
    UserStateMigrationToolPackageId = $UserStateMigrationToolPackageId
    CaptureWindowsSetting           = $true
    ConfigureBitLocker              = $true
    PartitionAndFormatTarget        = $true
    ApplyAll                        = $false
    OperatingSystemImagePackageId   = $OSimagepackageID
    OperatingSystemImageIndex       = 1
    ProductKey                      = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
    GeneratePassword                = $true
    TimeZone                        = Get-TimeZone -Name "Eastern Standard Time"
    JoinDomain                      = "DomainType"
    DomainAccount                   = "contoso\jqpublic"
    DomainName                      = "contoso"
    DomainOrganizationUnit          = "LDAP://OU=Workstations,OU=Devices,DC=na,DC=contoso,DC=com"
    DomainPassword                  = ConvertTo-SecureString -String "w%1H6EoxjQ&70^W" -AsPlainText -Force
    ClientPackagePackageId          = $ClientPackagePackageId
    InstallationProperty            = $clientProps
    SoftwareUpdateStyle             = "All"
}

New-CMTaskSequence @installOSimage

$customTS = @{
    CustomTaskSequence = $true
    Name               = "MEMLABS - Custom Task sequence"
    Description        = "NewCustom parameter set"
    HighPerformance    = $false
    BootImagePackageId = $BootImagePackageID
}

New-CMTaskSequence @customTS




### CI and baselines 


# Define variables
$ConfigNames = @(
    @{
        configbaselinename = "MEMLABS-Check .NET Framework 4.8"
        Description        = "Checks if the .NET Framework 4.8 feature is installed"
    },
    @{
        configbaselinename = "MEMLABS-Check Disk Space on C Drive"
        Description        = "Checks if there is more than 10GB free space on the C drive"
    },
    @{
        configbaselinename = "MEMLABS-Check Last Reboot Time"
        Description        = "Checks if a Machine was rebooted in last 7 days"
    },
    @{
        configbaselinename = "MEMLABS-Check Windows Firewall"
        Description        = "Checks if defender service is running"
    },
    @{
        configbaselinename = "MEMLABS-Check Windows Update Service"
        Description        = "Checks if the Windows Update service is running"
    }
)


$ConfigNames | ForEach-Object {

    # Create a configuration item (we are importing the cab files directly here)
    Import-CMConfigurationItem -FileName "C:\Users\admin\Documents\$($_.configbaselinename).cab" -Force


    # Create the configuration baseline
    New-CMBaseline -Name $($_.configbaselinename) -Description $($_.Description) 

    # Link the configuration item to the configuration baseline
    $ciinfo = Get-CMConfigurationItem -Name "$($_.configbaselinename)" -Fast
    Set-CMBaseline -Name $($_.configbaselinename) -AddOSConfigurationItem  $ciinfo.CI_ID 

    # Deploy the configuration baseline to a collection

    New-CMBaselineDeployment -Name "$($_.configbaselinename)" -CollectionName "All Systems" 

}

#>

# Define additional device collection information
$Collections += @(
    @{
        Name  = "MEMLABS-Windows 7 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '6.1%'
"@
    },
    @{
        Name  = "MEMLABS-Windows 8.1 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '6.3%'
"@
    },
    @{
        Name  = "MEMLABS-Devices Without Antivirus"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_Installed_Software ON SMS_G_System_Installed_Software.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_Installed_Software.ProductName NOT LIKE '%Antivirus%'
"@
    },
    @{
        Name  = "MEMLABS-Laptops Only"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes IN ('8', '9', '10', '14', '18', '21')
"@
    },
    @{
        Name  = "MEMLABS-Desktop Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes IN ('3', '4', '6', '7', '15')
"@
    },
    @{
        Name  = "MEMLABS-Virtual Machines"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_SYSTEM_ENCLOSURE ON SMS_G_System_SYSTEM_ENCLOSURE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_SYSTEM_ENCLOSURE.ChassisTypes = '12'
"@
    },
    @{
        Name  = "MEMLABS-Devices Without SCCM Client"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.Client IS NULL OR SMS_R_SYSTEM.Client = 0
"@
    },
    @{
        Name  = "MEMLABS-Devices With Less Than 4GB RAM"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_PHYSICAL_MEMORY ON SMS_G_System_PHYSICAL_MEMORY.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_PHYSICAL_MEMORY.Capacity < 4294967296
"@
    },
    @{
        Name  = "MEMLABS-All MacOS Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.OperatingSystemNameAndVersion LIKE '%MacOS%'
"@
    },
    @{
        Name  = "MEMLABS-All Linux Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.OperatingSystemNameAndVersion LIKE '%Linux%'
"@
    },
    @{
        Name  = "MEMLABS-All Devices with Office- Microsoft 365 Apps"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%Microsoft 365 Apps%'
"@
    },
    @{
        Name  = "MEMLABS-All Devices with Disk Space < 20GB"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_LOGICAL_DISK ON SMS_G_System_LOGICAL_DISK.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_LOGICAL_DISK.FreeSpace < 20000000000
"@
    },
    @{
        Name  = "MEMLABS-All Devices in Domain XYZ"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_System.ResourceDomainORWorkgroup = 'XYZ'
"@
    },
    @{
        Name  = "MEMLABS-All Devices with BitLocker Disabled"
        Query = @"
select SMS_R_System.Name, SMS_G_System_ENCRYPTABLE_VOLUME.DriveLetter, SMS_G_System_ENCRYPTABLE_VOLUME.ProtectionStatus 
from SMS_R_System inner join SMS_G_System_ENCRYPTABLE_VOLUME on SMS_G_System_ENCRYPTABLE_VOLUME.ResourceId = SMS_R_System.ResourceId
where SMS_G_System_ENCRYPTABLE_VOLUME.DriveLetter = "C:" and SMS_G_System_ENCRYPTABLE_VOLUME.ProtectionStatus = 1 order by SMS_R_System.Name
"@
    },
    @{
        Name  = "MEMLABS-All Devices with Google Chrome Installed"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%Google Chrome%'
"@
    },
    @{
        Name  = "MEMLABS-All Devices with Last Logon Older Than 90 Days"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE DATEDIFF(day, SMS_R_SYSTEM.LastLogonTimestamp, GETDATE()) > 90
"@
    }
    @{
        Name  = "MEMLABS-Devices Missing Critical Updates"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_UPDATE_STATUS ON SMS_G_System_UPDATE_STATUS.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_UPDATE_STATUS.Status = 2 AND SMS_G_System_UPDATE_STATUS.UpdateType = 'Critical'
"@
    },
    @{
        Name  = "MEMLABS-Devices Online Now"
        Query = @"
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,
SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.ResourceId in
(select resourceid from SMS_CollectionMemberClientBaselineStatus where SMS_CollectionMemberClientBaselineStatus.CNIsOnline = 1)
"@
    },
    @{
        Name  = "MEMLABS-Devices Offline for Over 30 Days"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE DATEDIFF(day, SMS_R_SYSTEM.LastLogonTimestamp, GETDATE()) > 30
"@
    },
    @{
        Name  = "MEMLABS-High CPU Usage Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_PROCESSOR ON SMS_G_System_PROCESSOR.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_PROCESSOR.LoadPercentage > 90
"@
    },
    @{
        Name  = "MEMLABS-All Workgroup Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.ResourceDomainORWorkgroup NOT LIKE '%DOMAIN%'
"@
    },
    @{
        Name  = "MEMLABS-Devices Running SQL Server"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_INSTALLED_SOFTWARE ON SMS_G_System_INSTALLED_SOFTWARE.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_INSTALLED_SOFTWARE.ProductName LIKE '%SQL Server%'
"@
    },
    @{
        Name  = "MEMLABS-All Domain Controllers"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.Name LIKE '%DC%'
"@
    },
    @{
        Name  = "MEMLABS-All Devices in Specific OU"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
WHERE SMS_R_SYSTEM.DistinguishedName LIKE '%OU=MEMLABS,DC=Domain,DC=com%'
"@
    },
    @{
        Name  = "MEMLABS-All Devices Missing a Default Gateway"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_NETWORK_ADAPTER_CONFIGURATION ON SMS_G_System_NETWORK_ADAPTER_CONFIGURATION.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_NETWORK_ADAPTER_CONFIGURATION.DefaultIPGateway IS NULL
"@
    }

    @{
        Name  = "MEMLABS-Windows 10 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '10.0.1%'
"@
    },
    @{
        Name  = "MEMLABS-Windows 11 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version LIKE '10.0.22%'
"@
    },
    @{
        Name  = "MEMLABS-Windows Server 2016 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.14393'
"@
    },
    @{
        Name  = "MEMLABS-Windows Server 2019 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.17763'
"@
    },
    @{
        Name  = "MEMLABS-Windows Server 2022 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.20348'
"@
    },
    @{
        Name  = "MEMLABS-Windows Server 2025 Devices"
        Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.26100'
"@
    },
    @{
        Name  = "MEMLABS-All Non client Devices"
        Query = @"
select Name, SMSAssignedSites, IPAddresses, IPSubnets, OperatingSystemNameandVersion, ResourceDomainORWorkgroup, LastLogonUserDomain, LastLogonUserName, SMSUniqueIdentifier, ResourceId, ResourceType, NetbiosName 
from sms_r_system where Client = 0 or Client is null
"@
    }
)


# Loop through each collection and create it in SCCM
foreach ($Collection in $Collections) {
    $CollectionName = $Collection.Name
    $Query = $Collection.Query
    
    if (-not (Get-CMDeviceCollection -Name $CollectionName)) {
        # Create the device collection
        $NewCollection = New-CMDeviceCollection -Name $CollectionName -LimitingCollectionName "All Systems" -Comment "Collection for $CollectionName"

        Write-DscStatus "Created collection: $CollectionName"

        # Add a query rule to the collection
        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName "$CollectionName Rule" -ErrorAction Stop
    
        Write-DscStatus "Created collection query: $CollectionName Rule"
    }
}

Write-DscStatus "Completed the perf loading the environment"



