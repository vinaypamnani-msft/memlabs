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
    

    #create a directory for the application source files
    new-item -ItemType Directory -Path "c:\Apps\$($_.Name)" -force
 
    #create a hardlink for the source file (this is to save space on the C drive)
    new-item -ItemType HardLink -Value "c:\tools\$($_.AppMsi)" -Path "C:\Apps\$($_.Name)\$($_.AppMsi)" -force


    #creating an application
    $appname = "MEMLABS-" + "$($_.Name)" 
    New-CMApplication -Name $appname -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue
    #remove an application
    #Remove-CMApplication -Name "MEMLABS-7-Zip 64-bit" -Force

    #create a deployment for each application (tim help on pulling the site server name)
    Add-CMMSiDeploymentType -ApplicationName $appname -DeploymentTypeName $($_.AppMsi) -ContentLocation "\\$ThisMachineName\c$\Apps\$($_.Name)\$($_.AppMsi)" -Comment "$($_.Name) MSI deployment type" -Force -ErrorAction SilentlyContinue
    
    #distribute the content to All DPs
    Start-CMContentDistribution -ApplicationName $($_.Name) -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
 
    #deploy apps to all systems
    New-CMApplicationDeployment -ApplicationName $($_.Name) -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue

    # Create the Package
    $Package = New-CMPackage -Name "MEMLABS-$($_.Name)" -Path "\\$ThisMachineName\c$\Apps\$($_.Name)" -Description "Package for $($_.Description)"
    #Remove a package
    #Remove-CMPackage -Id "CS100023" -Force

    $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn /l*v c:\windows\temp\$($_.Name).log"
    # Create a Program for the Package
    New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 

    #Distribute all packages to ALL DPs group
    Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue

    #Deploy all packages to all systems
    New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
      
}


## changing the auto approval setting on Heirarchy settings


$namespace = "ROOT\SMS\site_$SiteCode"
$classname = "SMS_SCI_SiteDefinition"
 
# Fetch the instance of the class

$instance = Get-CimInstance -ClassName $className -Namespace $namespace -Filter "SiteCode like 'CS1'"
 
if ($instance -ne $null) {

    # Get the Props array

    $propsArray = $instance.Props
 
    # Locate the TwoKeyApproval property

    for ($i = 0; $i -lt $propsArray.Length; $i++) {

        if ($propsArray[$i].PropertyName -eq "TwoKeyApproval") {

            # Modify the Value field

            $propsArray[$i].Value = 0 # Set your desired value here
 
            # Update the Props array in the instance

            $instance.Props = $propsArray
 
            # Save the modified instance back to the class

            Set-CimInstance -InputObject $instance
 
            Write-DscStatus "TwoKeyApproval Value updated successfully."

            break

        }

    }

}
else {

    Write-DscStatus "Target instance not found."

}

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

# Define device Collection Information
$Collections = @(
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

        # Add a query rule to the collection
        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName "$CollectionName Rule"
    
        Write-DscStatus "Created collection: $CollectionName"
    }
}




