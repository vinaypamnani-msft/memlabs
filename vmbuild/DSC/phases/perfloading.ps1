#perfloading.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[perfloading]"

$flagFile = "C:\staging\DSC\perfloading.flag"

# Check if the flag file exists
if (Test-Path $flagFile) {
    Write-DscStatus "$Tag Flag file exists. Skipping execution."
}
else {

    Write-DscStatus "$Tag Flag file does not exists. start execution."

    if ( -not $ConfigFilePath) {
        $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
    }

    # Read config json
    $deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json


    if ($deployConfig.cmOptions.PrePopulateObjects -ne $true) {
        return
    }

    # dot source functions
    . $PSScriptRoot\ScriptFunctions.ps1

    # Get required values from config
    $DomainFullName = $deployConfig.parameters.domainName
    $DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')   
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
    $DCVM = ($deployConfig.virtualMachine | Where-Object { $_.Role -eq "DC" })
    $DCName = $DCVM.vmName
    # Read Site Code from registry
    #Write-DscStatus "$Tag Setting PS Drive for ConfigMgr" -NoStatus
    $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
    $ProviderMachineName = $ThisMachineName + "." + $DomainFullName # SMS Provider machine name

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
            Write-DscStatus "$Tag Failed to get the PS Drive for site $SiteCode.  Install may have failed. Check C:\ConfigMgrSetup.log" -NoStatus
            return
        }
        Write-DscStatus "$Tag Retry in 10s to Set PS Drive" -NoStatus
        Start-Sleep -Seconds 10
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
    }

    # Set the current location to be the site code.
    Set-Location "$($SiteCode):\" @initParams

    #create all DPs group to distribute the content (its easier to distribute the content to a DP group than enumerating all DPs)
    $DPGroupName = "ALL DPS"
    $checkDP = Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name 

    if ($DPGroupName -eq $checkDP) {

        Write-DscStatus "$Tag DP group: $DPGroupName already exists"

    }
    else { 
        $DPGroup = New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag DP group: $DPGroup created successfully"

        # Get all Distribution Points
        $DistributionPoints = Get-CMDistributionPoint -AllSite

        # Display each Distribution Point's name without the leading '\\'
        $DistributionPoints | ForEach-Object {
            $DPPath = $_.NetworkOSPath
            $DPName = ($DPPath -replace "^\\\\", "") -split "\\" | Select-Object -First 1
            Write-DscStatus "$Tag Distribution Point Name: $DPName"
            try {
                Add-CMDistributionPointToGroup -DistributionPointGroupName "ALL DPS" -DistributionPointName $DPName 
                Write-DscStatus "$Tag Successfully added Distribution Point: $DPName to Group: $($DPGroupName)"
            }
            catch {
                Write-DscStatus "$Tag Failed to add Distribution Point: $DPName to Group: $($DPGroupName). Error: $_"
            }
        }
    }

    #Applications and packages


    $apps = $deployconfig.Tools | where-object { $_.Appinstall -eq $True }
    $apps | ForEach-Object {
    
        Write-DscStatus "$Tag Creating a directory under c:\apps for the application $($_.Name)"
        #create a directory for the application source files
        new-item -ItemType Directory -Path "c:\Apps\$($_.Name)" -force
        Write-DscStatus "$Tag Successfully created directory under c:\apps for the application $($_.Name)"


        Write-DscStatus "$Tag Creating a Hardlink under c:\apps for the application $($_.Name) "
        #create a hardlink for the source file (this is to save space on the C drive)
        new-item -ItemType HardLink -Value "c:\tools\$($_.AppMsi)" -Path "C:\Apps\$($_.Name)\$($_.AppMsi)" -force
        Write-DscStatus "$Tag Successfully created Hardlink under c:\apps for the application $($_.Name)"

        #creating an application
        $appname = "MEMLABS-" + "$($_.Name)" 
        Write-DscStatus "$Tag Creating an MEMLBAS application for $($_.Name) as App model"
        New-CMApplication -Name "$appname" -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Successfully created an MEMLBAS application for $($_.Name) as App model"
        #remove an application
        #Remove-CMApplication -Name "MEMLABS-*" -Force

        Write-DscStatus "$Tag Creating an MEMLBAS application deployment for $($_.Name) as App model"
        #create a deployment for each application (tim help on pulling the site server name)
        Add-CMMSiDeploymentType -ApplicationName "$appname" -DeploymentTypeName $($_.AppMsi) -ContentLocation "\\$ThisMachineName\c$\Apps\$($_.Name)\$($_.AppMsi)" -Comment "$($_.Name) MSI deployment type" -Force -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Sucessfully an MEMLBAS application deployment for $($_.Name) as App model"

        Write-DscStatus "$Tag Distributing MEMLBAS application $($_.Name) to all DPs"
        #distribute the content to All DPs
        Start-CMContentDistribution -ApplicationName "$appname" -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Successfully distributed MEMLBAS application $($_.Name) to all DPs"

        Write-DscStatus "$Tag Deploying MEMLBAS application $($_.Name) to all Systems as available deployment"
        #deploy apps to all systems
        New-CMApplicationDeployment -ApplicationName "$appname" -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag successfully deployed MEMLBAS application $($_.Name) to all Systems as available deployment"

        Write-DscStatus "$Tag Creating an MEMLBAS application deployment for $($_.Name) as Package model"
        # Create the Package
        $Package = New-CMPackage -Name "MEMLABS-$($_.Name)" -Path "\\$ThisMachineName\c$\Apps\$($_.Name)" -Description "Package for $($_.Description)"
        Write-DscStatus "$Tag Sucessfully created a MEMLBAS application deployment for $($_.Name) as Package model"
        #Remove a package
        #Remove-CMPackage -Id "CS100023" -Force

        Write-DscStatus "$Tag Creating an MEMLBAS pacakage deployment for $($_.Name) as Package model"
        $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn"
        # Create a Program for the Package
        New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 
        Write-DscStatus "$Tag Sucessfully created a MEMLBAS pacakage deployment for $($_.Name) as Package model"

        Write-DscStatus "$Tag Distributing MEMLBAS pacakage $($_.Name) to all DPs"
        #Distribute all packages to ALL DPs group
        Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Successfully distributed MEMLBAS package $($_.Name) to all DPs"

        Write-DscStatus "$Tag Deploying MEMLBAS package $($_.Name) to all Systems as available deployment"
        #Deploy all packages to all systems
        New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
        Write-DscStatus "$Tag successfully deployed MEMLBAS package $($_.Name) to all Systems as available deployment"
    }


    ## Changing the auto-approval setting on Hierarchy settings

    $namespace = "ROOT\SMS\site_$SiteCode"
    $classname = "SMS_SCI_SiteDefinition"

    Write-DscStatus "$Tag Current namespace is: $namespace and class name is: $classname"

    # Fetch the instance of the class
    $instance = Get-CimInstance -ClassName $className -Namespace $namespace -Filter "SiteCode like '$SiteCode'"

    if ($instance -ne $null) {
        Write-DscStatus "$Tag Instance found: modifying existing instance."

        # Get the Props array
        $propsArray = $instance.Props

        # Locate the TwoKeyApproval property
        $propertyFound = $false
        for ($i = 0; $i -lt $propsArray.Length; $i++) {
            if ($propsArray[$i].PropertyName -eq "TwoKeyApproval") {
                $propertyFound = $true
                Write-DscStatus "$Tag Current property name is: $propsArray[$i].PropertyName and its value is $propsArray[$i].Value"
                Write-DscStatus "$Tag Setting the value to 0 to override the self-approval for author."
                $propsArray[$i].Value = 0 # Set your desired value here

                # Update the Props array in the instance
                $instance.Props = $propsArray

                # Save the modified instance back to the class
                Set-CimInstance -InputObject $instance

                Write-DscStatus "$Tag TwoKeyApproval value updated successfully."
                break
            }
        }

        if (-not $propertyFound) {
            Write-DscStatus "$Tag Property 'TwoKeyApproval' not found in existing instance. Adding it."
      
            $class = Get-CimClass -ClassName "SMS_EmbeddedProperty" -Namespace $namespace
            $i = New-CimInstance -CimClass $class -Property @{PropertyName = "TwoKeyApproval"; Value = "0"; Value1 = $null; Value2 = $null }
            $propsArray += $i
            $instance.Props = $propsArray
            Set-CimInstance -InputObject $instance
            Write-DscStatus "$Tag TwoKeyApproval property added and value set successfully."

        }
        
    }
    else {
        Write-DscStatus "$Tag Instance not found. Manually approve the scripts"
    }
    Write-DscStatus "$Tag New instance created with TwoKeyApproval set to 0."


    ## Scripts ( used our scripts from Wiki)

    # Get all PowerShell script files (.ps1) in the folder and its sub folders
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
                Write-DscStatus "$Tag Successfully imported: $ScriptName"
                # Approve the script by Guid, this is not working as it requires a diff author or the checkmark to be removed (set-cmheirarchysettings doesnt have that feature yet) Tim help needed here
                Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved" 

                ##for testing if you want to remove all the scripts
                #Remove-CMScript -ForceWildcardHandling -ScriptName * -Force
            }
        }
        catch {
            Write-DscStatus "$Tag Failed to import: $ScriptName. Error: $_"
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
            Write-DscStatus "$Tag Successfully started distribution for boot image: $($BootImage.Name)"
        }
        catch {
            Write-DscStatus "$Tag Failed to start distribution for boot image: $($BootImage.Name). Error: $_"
        }
    }


    #Tim is copying the iso directly at phase 1
    Write-DscStatus "$Tag ISO files are already copied from phase 1"

    $DriveLetter = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" | Select-Object -ExpandProperty "Installation Directory" | Split-Path -Qualifier

    Write-DscStatus "$Tag SCCM is installed on the drive -  $DriveLetter"

    # Define the folder path and share name
    $folderPath = "$DriveLetter\OSD"
    $shareName = "OSD"

    Write-DscStatus "$Tag sharing the OSD folder as - $folderPath"

    # Create the folder if it doesn't exist
    if (-not (Test-Path -Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath
        Write-DscStatus "$Tag OSD folder does not exist and creating one"
    }

    # Create the share with read access for "Everyone"
    New-SmbShare -Name $shareName -Path $folderPath -FullAccess "Administrators" -ReadAccess "Everyone"

    Write-DscStatus "$Tag $shareName share successfully shared with Administrators"

    # Verify the share was created
    #Get-SmbShare -Name $shareName


    #get OS upgrade package 
    New-CMOperatingSystemInstaller -Name "Windows 11 upgrade" -Path "\\$ThisMachineName\OSD\Windows 11 24h2" -Version 10.0.26100 
    New-CMOperatingSystemInstaller -Name "Windows 10 upgrade" -Path "\\$ThisMachineName\OSD\Windows 10 22h2" -Version 10.0.19041 
    Write-DscStatus "$Tag Windows 10 and 11 OS upgrade packages created"

    #get OS package
    if (!(Get-CMOperatingSystemImage -Name "windows 11")) { New-CMOperatingSystemImage -Name "Windows 11" -Path "\\$ThisMachineName\OSD\Windows 11 24h2\sources\install.wim" -Version 10.0.26100 }
    if (!(Get-CMOperatingSystemImage -Name "windows 10")) { New-CMOperatingSystemImage -Name "Windows 10" -Path "\\$ThisMachineName\OSD\Windows 10 22h2\sources\install.wim" -Version 10.0.19041 }

    Write-DscStatus "$Tag Windows 10 and 11 OS packages created"

    # Get all Task Sequences with names starting with the specified prefix
    $taskSequences = Get-CMTaskSequence | Where-Object { $_.Name -like "MEMLABS-*" }

    if (!$taskSequences) {

        # Define variables for TS
        #$TaskSequenceName = "Windows 11 In-Place Upgrade Task Sequence"
        $win11UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 11 upgrade" | Select-Object -ExpandProperty PackageID
        $win10UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 10 upgrade" | Select-Object -ExpandProperty PackageID
        $BootImagePackageID = Get-CMBootImage | Where-Object { $_.Name -eq "Boot image (x64)" }  | Select-Object -ExpandProperty PackageID
        $win11OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 11" | Select-Object -ExpandProperty PackageID
        $win10OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 10" | Select-Object -ExpandProperty PackageID
        $ClientPackagePackageId = Get-CMPackage -Fast -Name "Configuration Manager Client Package" | Select-Object -ExpandProperty PackageID
        $UserStateMigrationToolPackageId = Get-CMPackage -Fast -Name "User State Migration Tool for Windows" | Select-Object -ExpandProperty PackageID
        $win11UpgradeOperatingSystempath = "\\$ThisMachineName\osd\Windows 11 24h2"  
        $win11UpgradeOperatingSystemWim = "\\$ThisMachineName\osd\Windows 11 24h2\sources\install.wim"
        $win10UpgradeOperatingSystemWim = "\\$ThisMachineName\osd\Windows 10 22h2\sources\install.wim"
        $clientProps = 'CCMDEBUGLOGGING="1" CCMLOGGINGENABLED="TRUE" CCMLOGLEVEL="0" CCMLOGMAXHISTORY="5" CCMLOGMAXSIZE="10000000" SMSCACHESIZE="15000"'
        $cm_svc_file = "C:\Staging\DSC\cm_svc.txt"
        $domainshortname = $deployConfig.parameters.domainName -replace "\.com$", ""

        $tstimezone = [System.TimeZoneInfo]::FindSystemTimeZoneById($deployconfig.vmOptions.timeZone)
        if (Test-Path $cm_svc_file) {
            # Add cm_svc user as a CM Account
            $unencrypted = Get-Content $cm_svc_file
        }
        #distribute the OS packages and upgrade packages 
        Start-CMContentDistribution -PackageId $UserStateMigrationToolPackageId -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
        Start-CMContentDistribution -OperatingSystemImageIds @($win11OSimagepackageID, $win10OSimagepackageID) -DistributionPointGroupName  "ALL DPS"
        Start-CMContentDistribution -OperatingSystemInstallerIds @($win11UpgradePackageID, $win10UpgradePackageID) -DistributionPointGroupName "ALL DPS"
        Write-DscStatus "$Tag Successfully distributed for OS Image and upgrade packages"
     

        # Create the in-place upgrade task sequence
        New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w11-In-Place Upgrade Task Sequence" -UpgradePackageId $win11UpgradePackageID -SoftwareUpdateStyle All
        Write-DscStatus "$Tag Successfully created windows 11 in-place upgrade TS"
        New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w10-In-Place Upgrade Task Sequence" -UpgradePackageId $win10UpgradePackageID -SoftwareUpdateStyle All
        Write-DscStatus "$Tag Successfully created windows 10 in-place upgrade TS"
        $AdminName = $deployConfig.vmOptions.adminName
        ## Build and capture TS

        $buildandcapturewin11 = @{
            BuildOperatingSystemImage          = $true
            Name                               = "MEMLABS-w11-Build and capture"
            Description                        = "MEMLABS auto created"
            BootImagePackageId                 = $BootImagePackageID
            HighPerformance                    = $true
            ApplyAll                           = $false
            OperatingSystemImagePackageId      = $win11OSimagepackageID
            OperatingSystemImageIndex          = 3
            ProductKey                         = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
            GeneratePassword                   = $true
            TimeZone                           = $tstimezone
            JoinDomain                         = "WorkgroupType"
            WorkgroupName                      = "Workgroup"
            ClientPackagePackageId             = $ClientPackagePackageId
            InstallationProperty               = $clientProps
            ApplicationName                    = "Admin Console"
            IgnoreInvalidApplication           = $true
            SoftwareUpdateStyle                = "All"
            OperatingSystemFilePath            = $win11UpgradeOperatingSystemWim
            ImageDescription                   = "MEMLABS autocreated"
            ImageVersion                       = "image version 1"
            CreatedBy                          = "MEMLABS"
            OperatingSystemFileAccount         = "$DomainFullName\$AdminName" 
            OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        }

        New-CMTaskSequence @buildandcapturewin11
        Write-DscStatus "$Tag Successfully created MEMLABS-w11-Build and capture TS"

        $buildandcapturewin10 = @{
            BuildOperatingSystemImage          = $true
            Name                               = "MEMLABS-w10-Build and capture"
            Description                        = "MEMLABS auto created"
            BootImagePackageId                 = $BootImagePackageID
            HighPerformance                    = $true
            ApplyAll                           = $false
            OperatingSystemImagePackageId      = $win10OSimagepackageID
            OperatingSystemImageIndex          = 3
            ProductKey                         = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
            GeneratePassword                   = $true
            TimeZone                           = $tstimezone
            JoinDomain                         = "WorkgroupType"
            WorkgroupName                      = "workgroup"
            ClientPackagePackageId             = $ClientPackagePackageId
            InstallationProperty               = $clientProps
            ApplicationName                    = "Admin Console"
            IgnoreInvalidApplication           = $true
            SoftwareUpdateStyle                = "All"
            OperatingSystemFilePath            = $win10UpgradeOperatingSystemWim
            ImageDescription                   = "image description"
            ImageVersion                       = "image version 1"
            CreatedBy                          = "MEMLABS"
            OperatingSystemFileAccount         = "$DomainFullName\$AdminName" 
            OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        }
        New-CMTaskSequence @buildandcapturewin10
        Write-DscStatus "$Tag Successfully created MEMLABS-w10-Build and capture TS"
        ##Create a task sequence to install an OS image

        $installw11OSimage = @{
            InstallOperatingSystemImage     = $true
            Name                            = "MEMLABS-w11-Install OS image"
            Description                     = "MEMLABS auto created"
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
            OperatingSystemImagePackageId   = $win11OSimagepackageID
            OperatingSystemImageIndex       = 3
            ProductKey                      = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
            GeneratePassword                = $true
            TimeZone                        = $tstimezone
            JoinDomain                      = "DomainType"
            DomainAccount                   = "$DomainFullName\$AdminName"
            DomainName                      = "$DomainFullName"
            DomainOrganizationUnit          = "LDAP://CN=Computers,$DN"
            DomainPassword                  = ConvertTo-SecureString -String $unencrypted -AsPlainText -Force
            ClientPackagePackageId          = $ClientPackagePackageId
            InstallationProperty            = $clientProps
            SoftwareUpdateStyle             = "All"
        }

        New-CMTaskSequence @installw11OSimage
        Write-DscStatus "$Tag Successfully created MEMLABS-w11-Install OS image TS"

        $installw10OSimage = @{
            InstallOperatingSystemImage     = $true
            Name                            = "MEMLABS-w10-Install OS image"
            Description                     = "MEMLABS auto created"
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
            OperatingSystemImagePackageId   = $win10OSimagepackageID
            OperatingSystemImageIndex       = 3
            ProductKey                      = "6NMRW-2C8FM-D24W7-TQWMY-CWH2D"
            GeneratePassword                = $true
            TimeZone                        = $tstimezone
            JoinDomain                      = "DomainType"
            DomainAccount                   = "$DomainFullName\$AdminName"
            DomainName                      = "$DomainFullName"
            DomainOrganizationUnit          = "LDAP://CN=Computers,$DN"
            DomainPassword                  = ConvertTo-SecureString -String $unencrypted -AsPlainText -Force
            ClientPackagePackageId          = $ClientPackagePackageId
            InstallationProperty            = $clientProps
            SoftwareUpdateStyle             = "All"
        }

        New-CMTaskSequence @installw10OSimage
        Write-DscStatus "$Tag Successfully created MEMLABS-w10-Install OS image TS"

        $customTS = @{
            CustomTaskSequence = $true
            Name               = "MEMLABS-Custom TS Example"
            Description        = "MEMLABS auto created"
            HighPerformance    = $false
            BootImagePackageId = $BootImagePackageID
        }

        New-CMTaskSequence @customTS
        Write-DscStatus "$Tag Successfully created MEMLABS-Custom TS Example"

    }
    else {

        Write-DscStatus "$Tag Task sequences were already created, skipping the duplicate creation"

    }

    ### CI and baselines 

    #expand archive for importing cab files
    Expand-Archive -Path "C:\tools\baselines.zip" -DestinationPath "C:\tools\" -Force

    # Define the path to the CAB files
    $baselineFolder = "C:\tools\baselines"

    # Get all .cab files in the folder
    $ConfigNames = Get-ChildItem -Path $baselineFolder -Filter "*.cab"

    ForEach ($ConfigName in $ConfigNames) {


        $baselinename = [System.IO.Path]::GetFileNameWithoutExtension($ConfigName.Name)

        if (!(Get-CMBaseline -Fast -Name $baselinename)) {

            # Create a configuration item (we are importing the cab files directly here)
            $filename = $baselineFolder + "\" + $ConfigName.Name
            Write-DscStatus "$Tag Importing cab from $filename location"
            Import-CMConfigurationItem -FileName $filename -Force
            Write-DscStatus "$Tag Succesfully created Configuration Item for $baselinename"
    
            # Create the configuration baseline
            New-CMBaseline -Name $baselinename -Description "MEMLABS auto imported" 
            Write-DscStatus "$Tag Succesfully created Configuration Baseline for $baselinename"

            # Link the configuration item to the configuration baseline (we are using the same name for CI and baseline so using the same name here)
            $ciinfo = Get-CMConfigurationItem -Name $baselinename -Fast
            Set-CMBaseline -Name $baselinename -AddOSConfigurationItem $ciinfo.CI_ID 
            Write-DscStatus "$Tag Succesfully linked CI and CB for $baselinename"

            # Deploy the configuration baseline to a collection

            New-CMBaselineDeployment -Name $baselinename -CollectionName "All Systems" -EnableEnforcement $true
            Write-DscStatus "$Tag Succesfully deployed the baseline $baselinename to All systems"

        }
        else {
            Write-DscStatus "Baseline $baselinename are already in place"

        }
    }

    #we have to make powershell bypass for the baselines to work as expected
    $customclientsetting = "MEMLABS-powershellbypass"
 
    if (!(Get-CMClientSetting -Name $customclientsetting)) {
        New-CMClientSetting -Name $customclientsetting -Description "Client settings for making powershell execution policy as bypass" -Type Device -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag $customclientsetting client setting created"

        # Enable the PowerShell Execution Policy setting
        Set-CMClientSettingComputerAgent -PowerShellExecutionPolicy Bypass -Name $customclientsetting
        Write-DscStatus "$Tag Powershell policy succesfully changed for $customclientsetting client setting "

        New-CMClientSettingDeployment -Name $customclientsetting -CollectionId SMS00001
        Write-DscStatus "$Tag Deployed the client setting to all systems collection"
    }
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
WHERE SMS_R_SYSTEM.DistinguishedName LIKE '%OU=MEMLABS,$DN%'
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
            Name  = "MEMLABS-Windows 10 21H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.19044'
"@
        },
        @{
            Name  = "MEMLABS-Windows 10 22H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.19045'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 23H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22631'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 24H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.26100'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 21H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22000'
"@
        },
        @{
            Name  = "MEMLABS-Windows 11 22H2"
            Query = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
FROM SMS_R_System
INNER JOIN SMS_G_System_OPERATING_SYSTEM ON SMS_G_System_OPERATING_SYSTEM.ResourceID = SMS_R_System.ResourceId
WHERE SMS_G_System_OPERATING_SYSTEM.Version = '10.0.22621'
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

            Write-DscStatus "$Tag Created collection: $CollectionName"

            # Add a query rule to the collection
            Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName "$CollectionName Rule" -ErrorAction Stop
    
            Write-DscStatus "$Tag Created collection query: $CollectionName Rule"

            New-CMFolder -Name "MEMLABS" -ParentFolderPath "Devicecollection"

            Write-DscStatus "$Tag Created collection Folder MEMLABS under device collections"

            Move-CMObject -FolderPath "$SiteCode`:\Devicecollection\MEMLABS" -ObjectId $NewCollection.CollectionID

            Write-DscStatus "$Tag Moved collection under the folder MEMLABS"

        }
    }

    #install Endpoint protection role in heirarchy to support defender updates
    if (!(Get-CMEndpointProtectionPoint -AllSite)) {
    
        # this is needed for defender updates and management
        Add-CMEndpointProtectionPoint -ProtectionService AdvancedMembership -SiteCode $SiteCode -SiteSystemServerName $ProviderMachineName
        Write-DscStatus "$Tag Endpoint protection role to support defender patching is installed"
    }
    
    if (!(Get-CMClientSetting -Name MEMLABS-Defender)) {
        New-CMClientSetting -Name MEMLABS-Defender -Description "Defender execution policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingEndpointProtection -Name MEMLABS-Defender -Enable $true -DisableFirstSignatureUpdate $true -ForceRebootHr $true -InstallEndpointProtectionClient $true -OverrideMaintenanceWindow $true -DefenderAgent MdeDownlevel -SuppressReboot $true -PersistInstallation $true 
        New-CMClientSettingDeployment -Name MEMLABS-Defender -CollectionId SMS00001
        Write-DscStatus "$Tag Client setting to support Defender patching is enabled"   
    }
    
    if (!(Get-CMClientSetting -Name MEMLABS-Updates)) {
        New-CMClientSetting -Name MEMLABS-Updates -Description "Updates M365 policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingSoftwareUpdate -EnableInstallation $true -Name MEMLABS-Updates -EnableThirdPartyUpdates $true -Office365ManagementType $true -EnableDeltaDownload $true -EnableDynamicUpdate $true -Enable $true
        New-CMClientSettingDeployment -Name MEMLABS-Updates -CollectionId SMS00001
        Write-DscStatus "$Tag Client setting to support O365 patching is enabled"
    }
    
    $Sups = $deployConfig.VirtualMachines | Where-Object { $_.InstallSup -and $_.SiteCode -eq $siteCode }

    if ($Sups) {

        # Get the Software Update Point Component
        $productclassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object LocalizedCategoryInstanceName
    
        # Get unique operating systems
        $products = ($deployConfig.virtualMachines.operatingSystem | Select-Object -Unique ) + ($deployConfig.virtualMachines.sqlversion | Select-Object -Unique)

        Write-DscStatus "$Tag the OS for this SCCM site are $products"
    
        # Rename products based on conditions
        $products = $products -replace "^Server 2016$", "Windows Server 2016"
        $products = $products -replace "^Server 2019$", "Windows Server 2019"
        $products = $products -replace "^Server 2022.*$", "Microsoft Server operating system-21H2"
        $products = $products -replace "^Server 2025$", "Microsoft Server operating system-24H2"
        $products = $products -replace "^Windows 10.*$", "Windows 10, version 1903 and later"
        $products = $products -replace "^Windows 11.*$", "Windows 11"
        $products = $products -replace "^Sql Server 2016$", "Microsoft SQL server 2016"
        $products = $products -replace "^Sql Server 2017$", "Microsoft SQL server 2017"
        $products = $products -replace "^Sql Server 2019$", "Microsoft SQL server 2019"
        $products = $products -replace "^Sql Server 2022$", "Microsoft SQL server 2022"
    
        # Add additional products for defender and Office 365
        $products += "Microsoft 365 Apps/Office 2019/Office LTSC"
        $products += "Microsoft Defender for Endpoint"
    
        # Add double quotes around each product name as few products have commans in their name
        $products = @($products | ForEach-Object { "$_" })

        Write-DscStatus "$Tag modified OS names to match with SUP naming convention are $products"
    
        $missingproducts = $products -notmatch { $_ -notin $productclassifications }

        Write-DscStatus "$Tag Are there any products not checked on SUP product? $missingproducts - if yes, please continue"
        function Check-SyncSucceeded {
            param (
                [string]$SiteCode
            )
     
            $syncFinished = $syncTimeout = $false
            $i = 0
     
            do {                    
                $syncState = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode } | Select-Object -First 1
    
                if (-not $syncState.LastSyncState -or $syncState.LastSyncState -eq 6703) {
                    Write-DscStatus "$Tag SUM Sync not detected as running on $($syncState.WSUSServerName). Running Sync to refresh products."
                    Sync-CMSoftwareUpdate
                    Start-Sleep -Seconds 120
                } 
                else {
                    $syncStateString = "Unknown"
                    switch ($($syncState.LastSyncState)) {
                        "6700" { $syncStateString = "WSUS Sync Manager Error" }
                        "6701" { $syncStateString = "WSUS Synchronization Started" }
                        "6702" { $syncStateString = "WSUS Synchronization Done" }
                        "6703" { $syncStateString = "WSUS Synchronization Failed" }
                        "6704" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing WSUS Server" }
                        "6705" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing SMS Database" }
                        "6706" { $syncStateString = "WSUS Synchronization In Progress Phase Synchronizing Internet facing WSUS Server" }
                        "6707" { $syncStateString = "Content of WSUS Server is out of sync with upstream server" }
                        "6709" { $syncStateString = "SMS Legacy Update Synchronization started" }
                        "6710" { $syncStateString = "SMS Legacy Update Synchronization done" }
                        "6711" { $syncStateString = "SMS Legacy Update Synchronization failed" }
                    }
                    Write-DscStatus "SUM Sync: Current State: $($syncState.LastSyncState) $syncStateString [$($syncState.WSUSServerName)]"
     
                    if ($syncState.LastSyncState -eq 6702) {
                        Write-DscStatus "SUM Sync finished successfully."
                        return $true
                    }
     
                    if (-not $syncFinished) {
                        $i++
                        Start-Sleep -Seconds 60
                    }
     
                    if ($i -gt 60) {
                        $syncTimeout = $true
                        Write-DscStatus "SUM Sync timed out. Skipping Set-CMSoftwareUpdatePointComponent"
                        return $false
                    }
                }
            }  until ($syncFinished -or $syncTimeout)
     
            return $false
        }

        function finalfullsync {
            $folderPath = "$DriveLetter':\ConfigMgr\inboxes\wsyncmgr.box"
            $filePath = Join-Path $folderPath "full.syn"
    
            # Ensure the folder exists; create it if it doesn't
            if (Test-Path $folderPath) {
           
                try {
                    # Create the "full.syn" file (overwrites if it exists)
                    New-Item -Path $filePath -ItemType File -Force | Out-Null
                    Write-DscStatus "$Tag File 'full.syn' created successfully at $folderPath"
                }
                catch {
                    Write-DscStatus "$Tag Error creating 'full.syn': $_"
                }
            }

        }

    
        # Check if product classifications are already enabled for Critical updates or definition updates
        if (!$missingproducts) {
            Write-DscStatus "$Tag SUP products and classifications are already enabled. Skipping the update."
        }
        else {
            Write-DscStatus "$Tag trying second time to see if 429 product classifications are enabled or not"
            Sync-CMSoftwareUpdate
            $syncSuccess = Check-SyncSucceeded -SiteCode $SiteCode

            if ($syncSuccess) {

                Write-DscStatus "$Tag Found missing $products, enabling them now"
                $supComp = Get-CMSoftwareUpdatePointComponent -SiteCode $SiteCode
                $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2024/1/7 12:00:00"
    
                # Get the language setting
                $lang = $deployConfig.vmOptions.locale
    
                # Define language mappings
                switch ($lang) {
                    "en-us" { $addLang = "English" }
                    "ja-jp" { $addLang = "Japanese" }
                    "es-es" { $addLang = "Spanish" }
                    "de-de" { $addLang = "German" }
                    "fr-fr" { $addLang = "French" }
                    default { $addLang = "English" }  # Fallback for unsupported languages is English and will add more languages as per adhoc request here
                }
    
                # Output the result
                Write-DscStatus "$Tag the locale language is $addLang"
    
                $parameters = @{
                    InputObject                   = $supComp
                    #DefaultWsusServer            = 'sup.contoso.com'
                    SynchronizeAction             = 'SynchronizeFromMicrosoftUpdate'
                    #ReportingEvent               = 'CreateAllWsusReportingEvents'
                    #RemoveUpdateClassification   = "Update Rollups"
                    AddUpdateClassification       = "Critical Updates", "Definition updates", "Security Updates", "Upgrades", "updates"
                    Schedule                      = $schedule
                    EnableSyncFailureAlert        = $true
                    ImmediatelyExpireSupersedence = $false
                    AddLanguageUpdateFile         = $addLang
                    AddLanguageSummaryDetails     = $addLang
                    #RemoveLanguageUpdateFile     = $removeLang
                    #RemoveLanguageSummaryDetails = $removeLang
                    EnableCallWsusCleanupWizard   = $true
                    WaitMonth                     = 3
                    EnableThirdPartyUpdates       = $true
                    EnableManualCertManagement    = $false
                    AddProduct                    = $products
                }
    
                Set-CMSoftwareUpdatePointComponent @parameters
    
    
                #there is an additional windows 10 component under Developer tools which gets enabled by above method, so we are removing the product family to avoid it explicitly
                Set-CMSoftwareUpdatePointComponent -RemoveProductFamily "Developer Tools, Runtimes, and Redistributables"
                Write-DscStatus "$Tag $productclassifications before enabling"
                $productclassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object LocalizedCategoryInstanceName
                Write-DscStatus "$Tag $productclassifications after enabling"
                Write-DscStatus "$Tag !!Final !! sync after enabling products and classfications" 
                finalfullsync

            }
            else {

                Write-DscStatus "$Tag we were not able to sync the products and classifications so ADRs will not be created"
                finalfullsync
            }
        }
       
        # Define the collection where the updates will be deployed
        $TargetCollection = Get-CMDeviceCollection -Name "All systems"
    
        # Define ADR Names
        $ADRNames = @{
            "Client"   = "MEMLABS-ADR-Windows-10/11"
            "Server"   = "MEMLABS-ADR-Windows-Servers"
            "Defender" = "MEMLABS-ADR-Windows-defender"
            "office"   = "MEMLABS-ADR-O365patching"
        }

        # Define the folder path and share name
        $folderPath1 = "$DriveLetter\updatePkgs"
        $shareName1 = "updatePkgs"

        Write-DscStatus "$Tag sharing the updatePkgs folder as - $folderPath1"

        # Create the folder if it doesn't exist
        if (-not (Test-Path -Path $folderPath1)) {
            New-Item -ItemType Directory -Path $folderPath1
            Write-DscStatus "$Tag updatePkgs folder does not exist and creating one"
        }

        # Create the share with read access for "Everyone"
        New-SmbShare -Name $shareName1 -Path $folderPath1 -FullAccess "Administrators" -ReadAccess "Everyone"

        Write-DscStatus "$Tag $shareName1 share successfully shared with Administrators"

        # Define Deployment Packages
        $Packages = @(
            @{ Name = "MEMLABS-W10-11-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows10-11"; Description = "Windows 10 and 11 Security Updates" },
            @{ Name = "MEMLABS-Win-Server-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windowsserver"; Description = "Windows Server Security Updates" },
            @{ Name = "MEMLABS-Defender-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows_defender"; Description = "Windows Defender Updates" },
            @{ Name = "MEMLABS-ADR-O365patching-pkg"; Path = "\\$ThisMachineName\updatePkgs\O365"; Description = "O365 Updates" }
        )
    
        # Function to Create Software Update Deployment Package
        function New-SCCMUpdatePackage {
            param (
                [string]$PackageName,
                [string]$PackagePath,
                [string]$PackageDescription
            )
    
            if (!(Get-CMSoftwareUpdateDeploymentPackage -Name $PackageName)) {
                Write-DscStatus "$Tag Creating package: $PackageName"
                try {
                    New-CMSoftwareUpdateDeploymentPackage -Name $PackageName -Path $PackagePath -Description $PackageDescription
                    Write-DscStatus "$Tag Successfully created package: $PackageName"
                    Start-CMContentDistribution -DeploymentPackageName $PackageName -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
                    Write-DscStatus "$Tag Successfully distributed MEMLB  $PackageName to all DPs"
                    New-CMSoftwareUpdateGroup -Name $PackageName -Description $PackageDescription
                    Write-DscStatus "$Tag Successfully created SUG $PackageName"
                
                }
                catch {
                    Write-DscStatus "$Tag Failed to create package: $PackageName. Error: $_"
                }
            }
            else {
                Write-DscStatus "$Tag Package already exists: $PackageName"
            }
        }
    
        # Loop through each package and create it if it doesn't exist
        foreach ($pkg in $Packages) {
            New-SCCMUpdatePackage -PackageName $pkg.Name -PackagePath $pkg.Path -PackageDescription $pkg.Description
        }
    
        # Create the ADR schedules
        $patchTueSchedule = New-CMSchedule -Start (Get-Date) -DayOfWeek Tuesday -WeekOrder Second -RecurCount 1 -OffsetDay 2
        $dailySchedule = New-CMSchedule -DurationInterval Days -DurationCount 0 -RecurInterval Days -RecurCount 1
    
        if (!(Get-CMSoftwareUpdateAutoDeploymentRule -Fast | Select-Object Name)) {
    
            $maxAttempts = 3
            $attempt = 0
            $success = $false
        
            while (-not $success -and $attempt -lt $maxAttempts) {
                try {
                    New-CMSoftwareUpdateAutoDeploymentRule -CollectionId $TargetCollection.CollectionID -Name $ADRNames.Client `
                        -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false `
                        -Product "windows 11", "Windows 10, version 1903 and later" -Architecture X64 `
                        -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                        -DeploymentPackageName $Packages[0].Name -Description "MEMLABS autocreated ADR for win 10/11 patching" `
                        -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                    Write-DscStatus "$Tag ADR created successfully for Windows 10 and 11 Security Updates"
                    $success = $true
                }
                catch {
                    Write-DscStatus "$Tag An error occurred while creating the ADR for Windows 10 and 11 Security Updates"
                    Check-SyncSucceeded -SiteCode $SiteCode
                    $attempt++
                    Write-DscStatus "$Tag Retrying ADR creation, attempt $attempt of $maxAttempts"
                    Start-Sleep -Seconds 10  # Pause before retrying
                }
            }
        
            if (-not $success) {
                Write-DscStatus "$Tag ADR creation failed after $maxAttempts attempts."
            }
        
            New-CMSoftwareUpdateAutoDeploymentRule -CollectionId $TargetCollection.CollectionID -Name $ADRNames.Server `
                -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false -Product "Windows Server 2016", "Windows Server 2019", "Microsoft Server operating system-21H2", "Microsoft Server operating system-24H2" -Architecture X64 `
                -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                -DeploymentPackageName $Packages[1].Name -Description "MEMLABS autocreated ADR for win server patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
    
            Write-DscStatus "$Tag ADR created successfully for Windows server Updates"
    
            New-CMSoftwareUpdateAutoDeploymentRule -CollectionId $TargetCollection.CollectionID -Name $ADRNames.Defender `
                -DateReleasedOrRevised Last7Days -UpdateClassification "Definition updates" -Superseded $false -Product $products -Architecture X64 `
                -Schedule $dailySchedule -RunType RunTheRuleOnSchedule `
                -DeploymentPackageName $Packages[2].Name -Description "MEMLABS autocreated ADR for definition updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
            Write-DscStatus "$Tag ADR created successfully for Defender Security Updates"
    
            New-CMSoftwareUpdateAutoDeploymentRule -CollectionId $TargetCollection.CollectionID -Name $ADRNames.office `
                -DateReleasedOrRevised Last7Days -Titles "-preview", "Microsoft 365 Apps Update" -Superseded $false -Product "Microsoft 365 Apps/Office 2019/Office LTSC" `
                -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                -DeploymentPackageName $Packages[3].Name -Description "MEMLABS autocreated ADR for O365 updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
            Write-DscStatus "$Tag ADR created successfully for O365 Updates"

            ##this sync will take a long time as it will almost pull 3k-5k updates down so dont wait for the process to finish
            finalfullsync
        }

    }
    

    # Create the flag file
    New-Item -ItemType File -Path $flagFile -Force | Out-Null
    Write-DscStatus "$Tag $flagFile the perf loading the environment created"

    Write-DscStatus "$Tag Completed the perf loading the environment"
    Write-DscStatus "$Tag ******************************************" -NoStatus
    Write-DscStatus "$Tag ******************************************" -NoStatus



}