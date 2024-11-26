#perfloading.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

if ( -not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}
if ( -not $LogPath) {
    $LogPath = "C:\staging\DSC\DSC_Log.txt"
}
# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

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


#Tim help on copying the msi
# Sample data 
$Apps = @(
    @{
        AppName         = "MEMLABS-orca"
        AppMsi          = "Orca.Msi"
        Description     = "MEMLABS-applications"
        Publisher       = "MS"
        SoftwareVersion = "1.0"
    },
    @{
        AppName         = "MEMLABS-LibreOffice_24.8.0_Win_x86-64r"
        AppMsi          = "LibreOffice_24.8.0_Win_x86-64.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "MS"
        SoftwareVersion = "24.8.0"
    },
    @{
        AppName         = "MEMLABS-googlechromestandaloneenterprise64"
        AppMsi          = "googlechromestandaloneenterprise64.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Google"
        SoftwareVersion = "128.0"
    },
    @{
        AppName         = "MEMLABS-Firefox Setup 129.0.2"
        AppMsi          = "Firefox Setup 129.0.2.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Mozilla"
        SoftwareVersion = "129.0.2"
    },
    @{
        AppName         = "MEMLABS-Wireshark-4.2.6-x64"
        AppMsi          = "Wireshark-4.2.6-x64.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Wireshark"
        SoftwareVersion = "4.2.6"
    },
    @{
        AppName         = "MEMLABS-vlc-3.0.9.2-win64"
        AppMsi          = "vlc-3.0.9.2-win64.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "VLC"
        SoftwareVersion = "3.0.9.2"
    },
    @{
        AppName         = "MEMLABS-7zip"
        AppMsi          = "7zip.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "MS"
        SoftwareVersion = "1.0"
    },
    @{
        AppName         = "MEMLABS-WinSCP-6.3.4"
        AppMsi          = "WinSCP-6.3.4.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "WinSCP"
        SoftwareVersion = "6.3.4"
    },
    @{
        AppName         = "MEMLABS-KeePass-2.57"
        AppMsi          = "KeePass-2.57.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "KeePass"
        SoftwareVersion = "2.57"
    },
    @{
        AppName         = "MEMLABS-putty-64bit-0.81-installer"
        AppMsi          = "putty-64bit-0.81-installer.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Putty"
        SoftwareVersion = "0.81"
    },
    @{
        AppName         = "MEMLABS-putty-0.81-installer"
        AppMsi          = "putty-0.81-installer.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Putty"
        SoftwareVersion = "0.81"
    },
    @{
        AppName         = "MEMLABS-7z2408-x64"
        AppMsi          = "7z2408-x64.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Igor"
        SoftwareVersion = "2408"
    },
    @{
        AppName         = "MEMLABS-7z2408"
        AppMsi          = "7z2408.msi"
        Description     = "MEMLABS-applications"
        Publisher       = "Igor"
        SoftwareVersion = "2408.0"
    }
)



#create all DPs group to distribute the content (its easier to distribute the content to a DP group than enumurating all DPs)
$DPGroupName = "ALL DPS"
$checkDP = Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name 

if ($DPGroupName -eq $checkDP) {

    Write-Host "DP group: $DPGroupName already exisits"

}
else { 
    $DPGroup = New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue

    # Get all Distribution Points
    $DistributionPoints = Get-CMDistributionPoint -AllSite

    # Display each Distribution Point's name without the leading '\\'
    $DistributionPoints | ForEach-Object {
        $DPPath = $_.NetworkOSPath
        $DPName = ($DPPath -replace "^\\\\", "") -split "\\" | Select-Object -First 1
        Write-Host "Distribution Point Name: $DPName"
        try {
            Add-CMDistributionPointToGroup -DistributionPointGroupName "ALL DPS" -DistributionPointName $DPName 
            Write-Host "Successfully added Distribution Point: $DPName to Group: $($DPGroupName)"
        }
        catch {
            Write-Host "Failed to add Distribution Point: $DPName to Group: $($DPGroupName). Error: $_"
        }
    }
}

#Applications and packages

##parameters before creating apps, pakcages, scripts and TS 

#create shares 


#give permissions


#copy the content to the folders



$Apps | ForEach-Object {
    
    #creating an application
    New-CMApplication -Name $($_.AppName) -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue

    #create a deployment for each application (tim help on pulling the site server name)
    Add-CMMSiDeploymentType -ApplicationName $($_.AppName) -DeploymentTypeName $($_.AppName) -ContentLocation "\\$ThisMachineName\E$\apps\$($_.AppName)\$($_.AppMsi)" -Comment "$($_.AppName) MSI deployment type" -Force -ErrorAction SilentlyContinue

    #distribute the content to All DPs
    Start-CMContentDistribution -ApplicationName $($_.AppName) -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
 
    #deploy apps to all systems
    New-CMApplicationDeployment -ApplicationName $($_.AppName) -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue

    # Create the Package
    $Package = New-CMPackage -Name $($_.AppName) -Path "\\$ThisMachineName\E$\apps\$($_.AppName)\$($_.AppMsi)" -Description "Package for $($_.Description)"

    $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn /l*v c:\windows\temp\$($_.AppName).log"
    # Create a Program for the Package
    New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 

    #Distribute all packages to ALL DPs group
    Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue

    #Deploy all packages to all systems
    New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
      
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
            Write-Host "Successfully imported: $ScriptName"
            # Approve the script by Guid, this is not working as it requires a diff author or the checkmark to be removed (set-cmheirarchysettings doesnt have that feature yet) Tim help needed here
            #Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved" 

            ##for testing if you want to remove all the scripts
            #Remove-CMScript -ForceWildcardHandling -ScriptName * -Force
        }
    }
    catch {
        Write-Host "Failed to import: $ScriptName. Error: $_"
    }
}


## Task sequences 

# Get all boot images
$BootImages = Get-CMBootImage

# Loop through each boot image and distribute it
foreach ($BootImage in $BootImages) {
    try {
        $packageId = $BootImage.PackageID
        # Distribute the boot image
        Start-CMContentDistribution -BootImageId $packageId -DistributionPointGroupName "ALL DPS"        
        Write-Host "Successfully started distribution for boot image: $($BootImage.Name)"
    }
    catch {
        Write-Host "Failed to start distribution for boot image: $($BootImage.Name). Error: $_"
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
    
        Write-Host "Created collection: $CollectionName"
    }
}





