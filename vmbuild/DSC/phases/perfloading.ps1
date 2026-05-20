# perfloading.ps1
# Pre-populates a ConfigMgr environment with applications, packages, task sequences,
# baselines, device collections, ADRs, and related configuration.

param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[perfloading]"
$flagFile = "C:\staging\DSC\perfloading.flag"

#region Helper Functions

function New-DPGroup {
    <#
    .SYNOPSIS
        Creates the "ALL DPS" distribution point group and adds all DPs to it.
    #>
    param(
        [string]$DPGroupName = "ALL DPS"
    )

    $existingGroups = Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name

    if ($DPGroupName -in $existingGroups) {
        Write-DscStatus "$Tag DP group: $DPGroupName already exists"
        return
    }

    New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue
    Write-DscStatus "$Tag DP group: $DPGroupName created successfully"

    # Add all Distribution Points to the group
    $DistributionPoints = Get-CMDistributionPoint -AllSite

    $DistributionPoints | ForEach-Object {
        $DPPath = $_.NetworkOSPath
        $DPName = ($DPPath -replace "^\\\\", "") -split "\\" | Select-Object -First 1
        Write-DscStatus "$Tag Distribution Point Name: $DPName"
        try {
            Add-CMDistributionPointToGroup -DistributionPointGroupName $DPGroupName -DistributionPointName $DPName
            Write-DscStatus "$Tag Successfully added Distribution Point: $DPName to Group: $DPGroupName"
        }
        catch {
            Write-DscStatus "$Tag Failed to add Distribution Point: $DPName to Group: $DPGroupName. Error: $_"
        }
    }
}

function Install-Applications {
    <#
    .SYNOPSIS
        Creates applications (app model + package model) from Tools config and deploys them.
    #>
    param(
        [array]$Apps,
        [string]$ThisMachineName
    )

    $Apps | ForEach-Object {
        $appEntry = $_
        $appName = "MEMLABS-$($appEntry.Name)"

        # Create source directory
        Write-DscStatus "$Tag Creating directory c:\Apps\$($appEntry.Name)"
        New-Item -ItemType Directory -Path "c:\Apps\$($appEntry.Name)" -Force | Out-Null

        # Create hardlink for source file (saves disk space)
        Write-DscStatus "$Tag Creating hardlink for $($appEntry.Name)"
        New-Item -ItemType HardLink -Value "c:\tools\$($appEntry.AppMsi)" -Path "C:\Apps\$($appEntry.Name)\$($appEntry.AppMsi)" -Force | Out-Null

        # Create CM Application (App Model)
        Write-DscStatus "$Tag Creating application: $appName (App Model)"
        New-CMApplication -Name $appName -Description $appEntry.Description -Publisher $appEntry.Publisher -SoftwareVersion $appEntry.SoftwareVersion -ErrorAction SilentlyContinue

        # Add MSI deployment type
        Add-CMMsiDeploymentType -ApplicationName $appName `
            -DeploymentTypeName $appEntry.AppMsi `
            -ContentLocation "\\$ThisMachineName\c$\Apps\$($appEntry.Name)\$($appEntry.AppMsi)" `
            -Comment "$($appEntry.Name) MSI deployment type" `
            -Force -ErrorAction SilentlyContinue

        # Distribute and deploy the application
        Start-CMContentDistribution -ApplicationName $appName -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
        New-CMApplicationDeployment -ApplicationName $appName -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Deployed application: $appName to All Systems"

        # Create CM Package (Package Model)
        Write-DscStatus "$Tag Creating package: $appName (Package Model)"
        $Package = New-CMPackage -Name $appName -Path "\\$ThisMachineName\c$\Apps\$($appEntry.Name)" -Description "Package for $($appEntry.Description)"

        $CommandLine = "msiexec.exe /i $($appEntry.AppMsi) /qn"
        New-CMProgram -PackageId $Package.PackageID -StandardProgramName $appEntry.AppMsi -CommandLine $CommandLine

        # Distribute and deploy the package
        Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
        New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $appEntry.AppMsi -CollectionName "All Systems" -DeployPurpose Available
        Write-DscStatus "$Tag Deployed package: $appName to All Systems"
    }
}

function Set-TwoKeyApproval {
    <#
    .SYNOPSIS
        Disables the TwoKeyApproval (self-approval for author) setting in hierarchy settings.
    #>
    param(
        [string]$SiteCode,
        [string]$Namespace
    )

    $className = "SMS_SCI_SiteDefinition"

    $instance = Get-CimInstance -ClassName $className -Namespace $Namespace -Filter "SiteCode like '$SiteCode'"

    if ($null -eq $instance) {
        Write-DscStatus "$Tag Instance not found. Manually approve the scripts."
        return
    }

    Write-DscStatus "$Tag Instance found: modifying TwoKeyApproval setting."
    $propsArray = $instance.Props
    $propertyFound = $false

    for ($i = 0; $i -lt $propsArray.Length; $i++) {
        if ($propsArray[$i].PropertyName -eq "TwoKeyApproval") {
            $propertyFound = $true
            Write-DscStatus "$Tag Current TwoKeyApproval value: $($propsArray[$i].Value). Setting to 0."
            $propsArray[$i].Value = 0
            $instance.Props = $propsArray
            Set-CimInstance -InputObject $instance
            Write-DscStatus "$Tag TwoKeyApproval value updated successfully."
            break
        }
    }

    if (-not $propertyFound) {
        Write-DscStatus "$Tag Property 'TwoKeyApproval' not found. Adding it."
        $class = Get-CimClass -ClassName "SMS_EmbeddedProperty" -Namespace $Namespace
        $newProp = New-CimInstance -CimClass $class -Property @{
            PropertyName = "TwoKeyApproval"
            Value        = "0"
            Value1       = $null
            Value2       = $null
        }
        $propsArray += $newProp
        $instance.Props = $propsArray
        Set-CimInstance -InputObject $instance
        Write-DscStatus "$Tag TwoKeyApproval property added and value set successfully."
    }
}

function Import-CMScripts {
    <#
    .SYNOPSIS
        Imports PowerShell scripts from C:\tools\Scripts into ConfigMgr and auto-approves them.
    #>
    $ScriptFiles = Get-ChildItem -Path C:\tools\Scripts -Recurse -Filter *.ps1

    foreach ($ScriptFile in $ScriptFiles) {
        $ScriptName = "MEMLABS-" + [System.IO.Path]::GetFileNameWithoutExtension($ScriptFile.FullName)
        $ScriptContent = Get-Content -Path $ScriptFile.FullName -Raw

        try {
            if (-not (Get-CMScript -ScriptName $ScriptName -Fast)) {
                $script = New-CMScript -ScriptName $ScriptName -ScriptText $ScriptContent -Fast
                Write-DscStatus "$Tag Successfully imported: $ScriptName"
                Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved"
            }
        }
        catch {
            Write-DscStatus "$Tag Failed to import: $ScriptName. Error: $_"
        }
    }
}

function Install-BootImagesAndOSD {
    <#
    .SYNOPSIS
        Enables command support on boot images, distributes them, and sets up OSD share.
    #>
    param(
        [string]$DomainFullName,
        [string]$ThisMachineName
    )

    # Custom domain branding in WinPE
    Set-CMClientSettingComputerAgent -DefaultSetting -BrandingTitle $DomainFullName

    # Enable command support and distribute boot images
    $BootImages = Get-CMBootImage
    foreach ($BootImage in $BootImages) {
        try {
            $BootImage | Set-CMBootImage -EnableCommandSupport $true
            Start-CMContentDistribution -BootImageId $BootImage.PackageID -DistributionPointGroupName "ALL DPS"
            Write-DscStatus "$Tag Successfully distributed boot image: $($BootImage.Name)"
        }
        catch {
            Write-DscStatus "$Tag Failed to distribute boot image: $($BootImage.Name). Error: $_"
        }
    }

    # Create and share OSD folder
    Write-DscStatus "$Tag ISO files are already copied from phase 1"

    $DriveLetter = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" |
        Select-Object -ExpandProperty "Installation Directory" | Split-Path -Qualifier
    Write-DscStatus "$Tag SCCM is installed on drive: $DriveLetter"

    $folderPath = "$DriveLetter\OSD"
    $shareName = "OSD"

    if (-not (Test-Path -Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath | Out-Null
        Write-DscStatus "$Tag Created OSD folder: $folderPath"
    }

    New-SmbShare -Name $shareName -Path $folderPath -FullAccess @("Administrators", "Everyone") -ErrorAction SilentlyContinue
    Write-DscStatus "$Tag Shared $folderPath as $shareName"

    return $DriveLetter
}

function New-OSPackages {
    <#
    .SYNOPSIS
        Creates OS upgrade packages and OS images for Windows 10 and 11.
    #>
    param(
        [string]$ThisMachineName
    )

    New-CMOperatingSystemInstaller -Name "Windows 11 upgrade" -Path "\\$ThisMachineName\OSD\Windows 11 24h2" -Version 10.0.26100 -ErrorAction SilentlyContinue
    New-CMOperatingSystemInstaller -Name "Windows 10 upgrade" -Path "\\$ThisMachineName\OSD\Windows 10 22h2" -Version 10.0.19041 -ErrorAction SilentlyContinue
    Write-DscStatus "$Tag Windows 10 and 11 OS upgrade packages created"

    if (!(Get-CMOperatingSystemImage -Name "windows 11")) {
        New-CMOperatingSystemImage -Name "Windows 11" -Path "\\$ThisMachineName\OSD\Windows 11 24h2\sources\install.wim" -Version 10.0.26100
    }
    if (!(Get-CMOperatingSystemImage -Name "windows 10")) {
        New-CMOperatingSystemImage -Name "Windows 10" -Path "\\$ThisMachineName\OSD\Windows 10 22h2\sources\install.wim" -Version 10.0.19041
    }
    Write-DscStatus "$Tag Windows 10 and 11 OS images created"
}

function New-TaskSequences {
    <#
    .SYNOPSIS
        Creates all MEMLABS task sequences (in-place upgrade, build/capture, install OS, custom).
    #>
    param(
        [object]$DeployConfig,
        [string]$ThisMachineName,
        [string]$DomainFullName,
        [string]$DN
    )

    # Gather package IDs
    $win11UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 11 upgrade" | Select-Object -ExpandProperty PackageID
    $win10UpgradePackageID = Get-CMOperatingSystemUpgradePackage -Name "Windows 10 upgrade" | Select-Object -ExpandProperty PackageID
    $BootImagePackageID = Get-CMBootImage | Where-Object { $_.Name -eq "Boot image (x64)" } | Select-Object -ExpandProperty PackageID
    $win11OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 11" | Select-Object -ExpandProperty PackageID
    $win10OSimagepackageID = Get-CMOperatingSystemImage -Name "windows 10" | Select-Object -ExpandProperty PackageID
    $ClientPackagePackageId = Get-CMPackage -Fast -Name "Configuration Manager Client Package" | Select-Object -ExpandProperty PackageID
    $UserStateMigrationToolPackageId = Get-CMPackage -Fast -Name "User State Migration Tool for Windows" | Select-Object -ExpandProperty PackageID

    $clientProps = 'CCMDEBUGLOGGING="1" CCMLOGGINGENABLED="TRUE" CCMLOGLEVEL="0" CCMLOGMAXHISTORY="5" CCMLOGMAXSIZE="10000000" SMSCACHESIZE="15000"'
    $cm_svc_file = "C:\Staging\DSC\cm_svc.txt"
    $AdminName = $DeployConfig.vmOptions.adminName
    $tstimezone = [System.TimeZoneInfo]::FindSystemTimeZoneById($DeployConfig.vmOptions.timeZone)

    $unencrypted = $null
    if (Test-Path $cm_svc_file) {
        $unencrypted = Get-Content $cm_svc_file
    }

    # Distribute OS content
    Start-CMContentDistribution -PackageId $UserStateMigrationToolPackageId -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
    Start-CMContentDistribution -OperatingSystemImageIds @($win11OSimagepackageID, $win10OSimagepackageID) -DistributionPointGroupName "ALL DPS"
    Start-CMContentDistribution -OperatingSystemInstallerIds @($win11UpgradePackageID, $win10UpgradePackageID) -DistributionPointGroupName "ALL DPS"
    Write-DscStatus "$Tag Successfully distributed OS Image and upgrade packages"

    # In-Place Upgrade Task Sequences
    New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w11-In-Place Upgrade Task Sequence" -UpgradePackageId $win11UpgradePackageID -SoftwareUpdateStyle All
    Write-DscStatus "$Tag Created Windows 11 in-place upgrade TS"

    New-CMTaskSequence -UpgradeOperatingSystem -Name "MEMLABS-w10-In-Place Upgrade Task Sequence" -UpgradePackageId $win10UpgradePackageID -SoftwareUpdateStyle All
    Write-DscStatus "$Tag Created Windows 10 in-place upgrade TS"

    # Build and Capture - Windows 11
    $buildandcapturewin11 = @{
        BuildOperatingSystemImage          = $true
        Name                               = "MEMLABS-w11-Build and capture"
        Description                        = "MEMLABS auto created"
        BootImagePackageId                 = $BootImagePackageID
        HighPerformance                    = $true
        ApplyAll                           = $false
        OperatingSystemImagePackageId      = $win11OSimagepackageID
        OperatingSystemImageIndex          = 3
        ProductKey                         = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        GeneratePassword                   = $false
        LocalAdminPassword                 = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        TimeZone                           = $tstimezone
        JoinDomain                         = "WorkgroupType"
        WorkgroupName                      = "Workgroup"
        ClientPackagePackageId             = $ClientPackagePackageId
        InstallationProperty               = $clientProps
        ApplicationName                    = "Admin Console"
        IgnoreInvalidApplication           = $true
        SoftwareUpdateStyle                = "All"
        OperatingSystemFilePath            = "\\$ThisMachineName\osd\Windows 11 24h2\sources\install.wim"
        ImageDescription                   = "MEMLABS autocreated"
        ImageVersion                       = "image version 1"
        CreatedBy                          = "MEMLABS"
        OperatingSystemFileAccount         = "$DomainFullName\$AdminName"
        OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
    }
    New-CMTaskSequence @buildandcapturewin11
    Write-DscStatus "$Tag Created MEMLABS-w11-Build and capture TS"

    # Build and Capture - Windows 10
    $buildandcapturewin10 = @{
        BuildOperatingSystemImage          = $true
        Name                               = "MEMLABS-w10-Build and capture"
        Description                        = "MEMLABS auto created"
        BootImagePackageId                 = $BootImagePackageID
        HighPerformance                    = $true
        ApplyAll                           = $false
        OperatingSystemImagePackageId      = $win10OSimagepackageID
        OperatingSystemImageIndex          = 3
        ProductKey                         = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        GeneratePassword                   = $false
        LocalAdminPassword                 = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        TimeZone                           = $tstimezone
        JoinDomain                         = "WorkgroupType"
        WorkgroupName                      = "Workgroup"
        ClientPackagePackageId             = $ClientPackagePackageId
        InstallationProperty               = $clientProps
        ApplicationName                    = "Admin Console"
        IgnoreInvalidApplication           = $true
        SoftwareUpdateStyle                = "All"
        OperatingSystemFilePath            = "\\$ThisMachineName\osd\Windows 10 22h2\sources\install.wim"
        ImageDescription                   = "MEMLABS autocreated"
        ImageVersion                       = "image version 1"
        CreatedBy                          = "MEMLABS"
        OperatingSystemFileAccount         = "$DomainFullName\$AdminName"
        OperatingSystemFileAccountPassword = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
    }
    New-CMTaskSequence @buildandcapturewin10
    Write-DscStatus "$Tag Created MEMLABS-w10-Build and capture TS"

    # Install OS Image - Windows 11
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
        ProductKey                      = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        GeneratePassword                = $false
        LocalAdminPassword              = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        TimeZone                        = $tstimezone
        JoinDomain                      = "DomainType"
        DomainAccount                   = "$DomainFullName\$AdminName"
        DomainName                      = "$DomainFullName"
        DomainOrganizationUnit          = "LDAP://OU=MEMLABS-OSDComputers,$DN"
        DomainPassword                  = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        ClientPackagePackageId          = $ClientPackagePackageId
        InstallationProperty            = $clientProps
        SoftwareUpdateStyle             = "All"
    }
    New-CMTaskSequence @installw11OSimage
    Write-DscStatus "$Tag Created MEMLABS-w11-Install OS image TS"

    # Install OS Image - Windows 10
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
        ProductKey                      = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        GeneratePassword                = $false
        LocalAdminPassword              = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        TimeZone                        = $tstimezone
        JoinDomain                      = "DomainType"
        DomainAccount                   = "$DomainFullName\$AdminName"
        DomainName                      = "$DomainFullName"
        DomainOrganizationUnit          = "LDAP://OU=MEMLABS-OSDComputers,$DN"
        DomainPassword                  = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
        ClientPackagePackageId          = $ClientPackagePackageId
        InstallationProperty            = $clientProps
        SoftwareUpdateStyle             = "All"
    }
    New-CMTaskSequence @installw10OSimage
    Write-DscStatus "$Tag Created MEMLABS-w10-Install OS image TS"

    # Custom Task Sequence
    $customTS = @{
        CustomTaskSequence = $true
        Name               = "MEMLABS-Custom TS Example"
        Description        = "MEMLABS auto created"
        HighPerformance    = $false
        BootImagePackageId = $BootImagePackageID
    }
    New-CMTaskSequence @customTS
    Write-DscStatus "$Tag Created MEMLABS-Custom TS Example"

    # Deploy all MEMLABS task sequences to "All Unknown Computers"
    $taskSequences = Get-CMTaskSequence -Fast | Where-Object { $_.Name -like "MEMLABS*" }
    $unknownCollection = Get-CMDeviceCollection -Name "All Unknown Computers"

    foreach ($ts in $taskSequences) {
        $existingDeployment = Get-CMDeployment -CollectionName $unknownCollection.Name |
            Where-Object { $_.PackageID -eq $ts.PackageID }

        if ($existingDeployment) {
            Write-DscStatus "$Tag Skipping $($ts.Name) - already deployed to $($unknownCollection.Name)"
        }
        else {
            Write-DscStatus "$Tag Deploying Task Sequence: $($ts.Name)"
            New-CMTaskSequenceDeployment `
                -TaskSequencePackageId $ts.PackageID `
                -CollectionId $unknownCollection.CollectionID `
                -DeployPurpose Available `
                -MakeAvailableTo ClientsMediaAndPxe
        }
    }
}

function Import-Baselines {
    <#
    .SYNOPSIS
        Imports configuration baselines from CAB files and deploys them.
    #>
    Expand-Archive -Path "C:\tools\baselines.zip" -DestinationPath "C:\tools\" -Force

    $baselineFolder = "C:\tools\baselines"
    $ConfigNames = Get-ChildItem -Path $baselineFolder -Filter "*.cab"

    foreach ($ConfigName in $ConfigNames) {
        $baselineName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigName.Name)

        if (Get-CMBaseline -Fast -Name $baselineName) {
            Write-DscStatus "$Tag Baseline $baselineName already exists, skipping."
            continue
        }

        $filename = Join-Path $baselineFolder $ConfigName.Name
        Write-DscStatus "$Tag Importing cab: $filename"
        Import-CMConfigurationItem -FileName $filename -Force
        Write-DscStatus "$Tag Created Configuration Item: $baselineName"

        New-CMBaseline -Name $baselineName -Description "MEMLABS auto imported"
        Write-DscStatus "$Tag Created Configuration Baseline: $baselineName"

        $ciinfo = Get-CMConfigurationItem -Name $baselineName -Fast
        Set-CMBaseline -Name $baselineName -AddOSConfigurationItem $ciinfo.CI_ID
        Write-DscStatus "$Tag Linked CI to Baseline: $baselineName"

        New-CMBaselineDeployment -Name $baselineName -CollectionName "All Systems" -EnableEnforcement $true
        Write-DscStatus "$Tag Deployed baseline: $baselineName to All Systems"
    }
}

function Set-PowerShellBypassClientSetting {
    <#
    .SYNOPSIS
        Creates a client setting to set PowerShell execution policy to Bypass (needed for baselines).
    #>
    $customClientSetting = "MEMLABS-powershellbypass"

    if (Get-CMClientSetting -Name $customClientSetting) {
        Write-DscStatus "$Tag Client setting $customClientSetting already exists."
        return
    }

    New-CMClientSetting -Name $customClientSetting -Description "Client settings for making powershell execution policy as bypass" -Type Device -ErrorAction SilentlyContinue
    Set-CMClientSettingComputerAgent -PowerShellExecutionPolicy Bypass -Name $customClientSetting
    New-CMClientSettingDeployment -Name $customClientSetting -CollectionId SMS00001
    Write-DscStatus "$Tag Created and deployed client setting: $customClientSetting"
}

function New-DeviceCollections {
    <#
    .SYNOPSIS
        Creates MEMLABS device collections with query-based membership rules.
    #>
    param(
        [string]$SiteCode
    )

    $Collections = @(
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
        },
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
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier,
SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client from SMS_R_System where SMS_R_System.ResourceId in
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
        },
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
        },
        @{
            Name  = "MEMLABS-All Servers"
            Query = @"
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
from SMS_R_System
where SMS_R_System.OperatingSystemNameandVersion like "%Server%" order by SMS_R_System.Name
"@
        },
        @{
            Name  = "MEMLABS-All Workstations"
            Query = @"
select SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name, SMS_R_SYSTEM.SMSUniqueIdentifier, SMS_R_SYSTEM.ResourceDomainORWorkgroup, SMS_R_SYSTEM.Client
from SMS_R_System
where SMS_R_System.OperatingSystemNameandVersion like "%Workstation%" order by SMS_R_System.Name
"@
        }
    )

    # Create MEMLABS folder under Device Collections
    $folder = Get-CMFolder -FolderPath "\DeviceCollection\MEMLABS"
    if (-not $folder) {
        New-CMFolder -Name "MEMLABS" -ParentFolderPath "\DeviceCollection"
        Write-DscStatus "$Tag Created MEMLABS folder under Device Collections."
    }
    else {
        Write-DscStatus "$Tag MEMLABS folder already exists under Device Collections."
    }

    # Create each collection
    foreach ($Collection in $Collections) {
        $CollectionName = $Collection.Name
        $Query = $Collection.Query

        if (Get-CMDeviceCollection -Name $CollectionName) {
            continue
        }

        $NewCollection = New-CMDeviceCollection -Name $CollectionName -LimitingCollectionName "All Systems" -Comment "Collection for $CollectionName"
        Write-DscStatus "$Tag Created collection: $CollectionName"

        Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName "$CollectionName Rule" -ErrorAction Stop
        Write-DscStatus "$Tag Added query rule: $CollectionName Rule"

        Move-CMObject -FolderPath "$SiteCode`:\DeviceCollection\MEMLABS" -ObjectId $NewCollection.CollectionID
        Write-DscStatus "$Tag Moved collection to MEMLABS folder"
    }
}

function Install-EndpointProtectionAndClientSettings {
    <#
    .SYNOPSIS
        Installs the Endpoint Protection role and creates Defender/Updates client settings.
    #>
    param(
        [string]$SiteCode,
        [string]$ProviderMachineName
    )

    # Endpoint Protection Point
    if (!(Get-CMEndpointProtectionPoint -AllSite)) {
        Add-CMEndpointProtectionPoint -ProtectionService AdvancedMembership -SiteCode $SiteCode -SiteSystemServerName $ProviderMachineName
        Write-DscStatus "$Tag Endpoint protection role installed"
    }

    # Defender client setting
    if (!(Get-CMClientSetting -Name MEMLABS-Defender)) {
        New-CMClientSetting -Name MEMLABS-Defender -Description "Defender execution policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingEndpointProtection -Name MEMLABS-Defender -Enable $true -DisableFirstSignatureUpdate $true `
            -ForceRebootHr $true -InstallEndpointProtectionClient $true -OverrideMaintenanceWindow $true `
            -DefenderAgent MdeDownlevel -SuppressReboot $true -PersistInstallation $true
        New-CMClientSettingDeployment -Name MEMLABS-Defender -CollectionId SMS00001
        Write-DscStatus "$Tag Defender client setting created and deployed"
    }

    # Updates client setting
    if (!(Get-CMClientSetting -Name MEMLABS-Updates)) {
        New-CMClientSetting -Name MEMLABS-Updates -Description "Updates M365 policy" -Type Device -ErrorAction SilentlyContinue
        Set-CMClientSettingSoftwareUpdate -EnableInstallation $true -Name MEMLABS-Updates `
            -EnableThirdPartyUpdates $true -Office365ManagementType $true `
            -EnableDeltaDownload $true -EnableDynamicUpdate $true -Enable $true
        New-CMClientSettingDeployment -Name MEMLABS-Updates -CollectionId SMS00001
        Write-DscStatus "$Tag Updates client setting created and deployed"
    }
}

function Test-SyncSucceeded {
    <#
    .SYNOPSIS
        Waits for a WSUS sync to complete successfully, with timeout.
    .OUTPUTS
        $true if sync succeeded, $false otherwise.
    #>
    param(
        [string]$SiteCode
    )

    $syncFinished = $syncTimeout = $syncFailed = $false
    $i = 0

    do {
        $syncState = Get-CMSoftwareUpdateSyncStatus |
            Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode } |
            Select-Object -First 1

        if (-not $syncState.WSUSServerName) {
            Start-Sleep -Seconds 120
            $syncState = Get-CMSoftwareUpdateSyncStatus |
                Where-Object { $_.WSUSSourceServer -like "*Microsoft Update*" -and $_.SiteCode -eq $SiteCode } |
                Select-Object -First 1

            if (-not $syncState.WSUSServerName) {
                Write-DscStatus "$Tag SUM Sync not configured properly on site $SiteCode. WSUS Server not detected."
                $syncFailed = $true
                return $false
            }
        }

        if (-not $syncState.LastSyncState -or $syncState.LastSyncState -eq 6703) {
            Write-DscStatus "$Tag SUM Sync not running on $($syncState.WSUSServerName). Triggering sync."
            Sync-CMSoftwareUpdate
            Start-Sleep -Seconds 120
        }
        else {
            $syncStateString = switch ($syncState.LastSyncState) {
                6700 { "WSUS Sync Manager Error" }
                6701 { "WSUS Synchronization Started" }
                6702 { "WSUS Synchronization Done" }
                6703 { "WSUS Synchronization Failed" }
                6704 { "WSUS Synchronization In Progress - Synchronizing WSUS Server" }
                6705 { "WSUS Synchronization In Progress - Synchronizing SMS Database" }
                6706 { "WSUS Synchronization In Progress - Synchronizing Internet facing WSUS Server" }
                6707 { "Content of WSUS Server is out of sync with upstream server" }
                6709 { "SMS Legacy Update Synchronization started" }
                6710 { "SMS Legacy Update Synchronization done" }
                6711 { "SMS Legacy Update Synchronization failed" }
                default { "Unknown" }
            }
            Write-DscStatus "$Tag SUM Sync: State $($syncState.LastSyncState) - $syncStateString [$($syncState.WSUSServerName)]"

            if ($syncState.LastSyncState -eq 6702) {
                Write-DscStatus "$Tag SUM Sync finished successfully."
                return $true
            }

            $i++
            Start-Sleep -Seconds 60

            if ($i -gt 60) {
                $syncTimeout = $true
                Write-DscStatus "$Tag SUM Sync timed out."
                return $false
            }
        }
    } until ($syncFinished -or $syncTimeout -or $syncFailed)

    return $false
}

function Invoke-FinalFullSync {
    <#
    .SYNOPSIS
        Drops a full.syn file to trigger a full WSUS synchronization.
    #>
    param(
        [string]$CMInstallDir
    )

    $folderPath = "$CMInstallDir\inboxes\wsyncmgr.box"
    $filePath = Join-Path $folderPath "full.syn"
    Write-DscStatus "$Tag Checking $folderPath to drop full.syn for full synchronization"

    if (Test-Path $folderPath) {
        try {
            New-Item -Path $filePath -ItemType File -Force | Out-Null
            Write-DscStatus "$Tag File 'full.syn' created at $folderPath"
        }
        catch {
            Write-DscStatus "$Tag Error creating 'full.syn': $_"
        }
    }
    else {
        Write-DscStatus "$Tag Folder not found: $folderPath"
    }
}

function Set-SUPProductsAndClassifications {
    <#
    .SYNOPSIS
        Configures SUP products, classifications, and creates ADRs for patching.
    #>
    param(
        [object]$DeployConfig,
        [string]$SiteCode,
        [string]$CMInstallDir,
        [string]$ThisMachineName,
        [string]$DriveLetter,
        [string]$ProviderMachineName
    )

    $Sups = $DeployConfig.virtualMachines | Where-Object { $_.InstallSup -and $_.SiteCode -eq $SiteCode }

    if ($DeployConfig.cmOptions.OfflineSUP) {
        $Sups = $false
        Write-DscStatus "$Tag Offline SUP requested, skipping SUP product check"
    }

    if (-not $Sups) {
        Write-DscStatus "$Tag No SUP installed for this site, skipping SUP product check and sync"
        return
    }

    # Determine which products to subscribe to
    $productClassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" |
        Where-Object { $_.IsSubscribed } |
        Select-Object -ExpandProperty LocalizedCategoryInstanceName

    $products = ($DeployConfig.virtualMachines.operatingSystem | Select-Object -Unique) +
                ($DeployConfig.virtualMachines.sqlversion | Select-Object -Unique)

    Write-DscStatus "$Tag OS products for this site: $products"

    # Map product names to SUP naming convention
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

    # Add Defender and Office products
    $products += "Microsoft 365 Apps/Office 2019/Office LTSC"
    $products += "Microsoft Defender for Endpoint"
    $products = @($products | ForEach-Object { "$_" })

    Write-DscStatus "$Tag Mapped product names: $products"

    # Identify missing products
    $missingProducts = $products | Where-Object { $_ -notin $productClassifications }

    Write-DscStatus "$Tag Missing products to enable: $missingProducts"

    if (-not $missingProducts) {
        Write-DscStatus "$Tag SUP products and classifications are already enabled."
    }
    else {
        Write-DscStatus "$Tag Triggering sync to refresh product catalog"
        Invoke-FinalFullSync -CMInstallDir $CMInstallDir
        $syncSuccess = Test-SyncSucceeded -SiteCode $SiteCode

        if ($syncSuccess) {
            Write-DscStatus "$Tag Enabling missing products: $products"
            $supComp = Get-CMSoftwareUpdatePointComponent -SiteCode $SiteCode
            $schedule = New-CMSchedule -RecurCount 1 -RecurInterval Days -Start "2024/1/7 12:00:00"

            # Determine language
            $lang = $DeployConfig.vmOptions.locale
            $addLang = switch ($lang) {
                "en-us" { "English" }
                "ja-jp" { "Japanese" }
                "es-es" { "Spanish" }
                "de-de" { "German" }
                "fr-fr" { "French" }
                default { "English" }
            }
            Write-DscStatus "$Tag Locale language: $addLang"

            $parameters = @{
                InputObject                  = $supComp
                SynchronizeAction            = 'SynchronizeFromMicrosoftUpdate'
                AddUpdateClassification      = "Critical Updates", "Definition updates", "Security Updates", "Upgrades", "updates"
                Schedule                     = $schedule
                EnableSyncFailureAlert       = $true
                ImmediatelyExpireSupersedence = $false
                AddLanguageUpdateFile        = $addLang
                AddLanguageSummaryDetails    = $addLang
                EnableCallWsusCleanupWizard  = $true
                WaitMonth                    = 3
                EnableThirdPartyUpdates      = $true
                EnableManualCertManagement   = $false
                AddProduct                   = $products
            }

            Set-CMSoftwareUpdatePointComponent @parameters

            # Remove unwanted product family
            Set-CMSoftwareUpdatePointComponent -RemoveProductFamily "Developer Tools, Runtimes, and Redistributables"

            $updatedClassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" |
                Where-Object { $_.IsSubscribed } |
                Select-Object -ExpandProperty LocalizedCategoryInstanceName
            Write-DscStatus "$Tag Updated subscribed products: $updatedClassifications"
            Write-DscStatus "$Tag Running final sync after enabling products"
            Invoke-FinalFullSync -CMInstallDir $CMInstallDir
        }
        else {
            Write-DscStatus "$Tag Sync failed - ADRs will not be created"
            Invoke-FinalFullSync -CMInstallDir $CMInstallDir
            return
        }
    }

    # Create ADRs and deployment packages
    New-ADRsAndPackages -DeployConfig $DeployConfig -SiteCode $SiteCode -ThisMachineName $ThisMachineName `
        -DriveLetter $DriveLetter -Products $products -CMInstallDir $CMInstallDir
}

function New-ADRsAndPackages {
    <#
    .SYNOPSIS
        Creates software update deployment packages and Automatic Deployment Rules.
    #>
    param(
        [object]$DeployConfig,
        [string]$SiteCode,
        [string]$ThisMachineName,
        [string]$DriveLetter,
        [array]$Products,
        [string]$CMInstallDir
    )

    $TargetCollection = Get-CMDeviceCollection -Name "All systems"

    $ADRNames = @{
        "Client"   = "MEMLABS-ADR-Windows-10/11"
        "Server"   = "MEMLABS-ADR-Windows-Servers"
        "Defender" = "MEMLABS-ADR-Windows-defender"
        "Office"   = "MEMLABS-ADR-O365patching"
    }

    # Create and share updatePkgs folder
    $folderPath1 = "$DriveLetter\updatePkgs"
    $shareName1 = "updatePkgs"

    if (-not (Test-Path -Path $folderPath1)) {
        New-Item -ItemType Directory -Path $folderPath1 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $folderPath1 "windows10-11") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windowsserver") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windows_defender") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $folderPath1 "O365") | Out-Null
        Write-DscStatus "$Tag Created updatePkgs folder structure"
    }

    New-SmbShare -Name $shareName1 -Path $folderPath1 -FullAccess @("Administrators", "Everyone") -ErrorAction SilentlyContinue
    Write-DscStatus "$Tag Shared $folderPath1 as $shareName1"

    # Define Deployment Packages
    $Packages = @(
        @{ Name = "MEMLABS-W10-11-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows10-11"; Description = "Windows 10 and 11 Security Updates" },
        @{ Name = "MEMLABS-Win-Server-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windowsserver"; Description = "Windows Server Security Updates" },
        @{ Name = "MEMLABS-Defender-CU-pkg"; Path = "\\$ThisMachineName\updatePkgs\Windows_defender"; Description = "Windows Defender Updates" },
        @{ Name = "MEMLABS-ADR-O365patching-pkg"; Path = "\\$ThisMachineName\updatePkgs\O365"; Description = "O365 Updates" }
    )

    # Create each package
    foreach ($pkg in $Packages) {
        if (!(Get-CMSoftwareUpdateDeploymentPackage -Name $pkg.Name)) {
            Write-DscStatus "$Tag Creating package: $($pkg.Name)"
            try {
                New-CMSoftwareUpdateDeploymentPackage -Name $pkg.Name -Path $pkg.Path -Description $pkg.Description
                Start-CMContentDistribution -DeploymentPackageName $pkg.Name -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
                New-CMSoftwareUpdateGroup -Name $pkg.Name -Description $pkg.Description
                Write-DscStatus "$Tag Created and distributed package: $($pkg.Name)"
            }
            catch {
                Write-DscStatus "$Tag Failed to create package: $($pkg.Name). Error: $_"
            }
        }
        else {
            Write-DscStatus "$Tag Package already exists: $($pkg.Name)"
        }
    }

    # Create ADRs
    if (Get-CMSoftwareUpdateAutoDeploymentRule -Fast | Select-Object -ExpandProperty Name) {
        Write-DscStatus "$Tag ADRs already exist, skipping creation"
        return
    }

    $patchTueSchedule = New-CMSchedule -Start (Get-Date) -DayOfWeek Tuesday -WeekOrder Second -RecurCount 1 -OffsetDay 2
    $dailySchedule = New-CMSchedule -DurationInterval Days -DurationCount 0 -RecurInterval Days -RecurCount 1

    # ADR for Windows 10/11
    $maxAttempts = 3
    $attempt = 0
    $success = $false

    while (-not $success -and $attempt -lt $maxAttempts) {
        try {
            New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Client `
                -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false `
                -Product "windows 11", "Windows 10, version 1903 and later" -Architecture X64 `
                -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                -DeploymentPackageName $Packages[0].Name -Description "MEMLABS autocreated ADR for win 10/11 patching" `
                -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
            Write-DscStatus "$Tag ADR created: Windows 10/11 Security Updates"
            $success = $true
        }
        catch {
            $attempt++
            Write-DscStatus "$Tag ADR creation failed for Windows 10/11 (attempt $attempt of $maxAttempts). Error: $_"
            Test-SyncSucceeded -SiteCode $SiteCode
            Start-Sleep -Seconds 10
        }
    }

    if (-not $success) {
        Write-DscStatus "$Tag ADR creation failed after $maxAttempts attempts for Windows 10/11."
    }

    # ADR for Windows Servers
    try {
        New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Server `
            -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false `
            -Product "Windows Server 2016", "Windows Server 2019", "Microsoft Server operating system-21H2", "Microsoft Server operating system-24H2" `
            -Architecture X64 -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
            -DeploymentPackageName $Packages[1].Name -Description "MEMLABS autocreated ADR for win server patching" `
            -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        Write-DscStatus "$Tag ADR created: Windows Server Updates"
    }
    catch {
        Write-DscStatus "$Tag Failed to create ADR for Windows Server. Error: $_"
    }

    # ADR for Defender
    try {
        New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Defender `
            -DateReleasedOrRevised Last7Days -UpdateClassification "Definition updates" -Superseded $false `
            -Product $Products -Architecture X64 -Schedule $dailySchedule -RunType RunTheRuleOnSchedule `
            -DeploymentPackageName $Packages[2].Name -Description "MEMLABS autocreated ADR for definition updates patching" `
            -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        Write-DscStatus "$Tag ADR created: Defender Definition Updates"
    }
    catch {
        Write-DscStatus "$Tag Failed to create ADR for Defender. Error: $_"
    }

    # ADR for Office 365
    try {
        New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Office `
            -DateReleasedOrRevised Last7Days -Titles "-preview", "Microsoft 365 Apps Update" -Superseded $false `
            -Product "Microsoft 365 Apps/Office 2019/Office LTSC" `
            -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
            -DeploymentPackageName $Packages[3].Name -Description "MEMLABS autocreated ADR for O365 updates patching" `
            -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        Write-DscStatus "$Tag ADR created: O365 Updates"
    }
    catch {
        Write-DscStatus "$Tag Failed to create ADR for O365. Error: $_"
    }

    # Final sync (will pull 3k-5k updates - don't wait)
    Invoke-FinalFullSync -CMInstallDir $CMInstallDir
}

#endregion Helper Functions

#region Main Execution

# Check flag file for idempotency
if (Test-Path $flagFile) {
    Write-DscStatus "$Tag Flag file exists. Skipping execution."
    return
}

Write-DscStatus "$Tag Flag file does not exist. Starting execution."

if (-not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

if ($deployConfig.cmOptions.PrePopulateObjects -ne $true) {
    return
}

# Connect to the CM site (imports module, sets up PS drive, sets location)
. $PSScriptRoot\Connect-CMSite.ps1 -Tag $Tag

# Extract values from config
$DomainFullName = $deployConfig.parameters.domainName
$DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
$DCVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "DC" }
$DCName = $DCVM.vmName
$CMInstallDir = $ThisVM.CMInstallDir

# Step 1: Create DP Group
New-DPGroup

# Step 2: Enable Site Features
Write-DscStatus "$Tag Enabling site features"
Get-CMSiteFeature -Production -Fast | Enable-CMSiteFeature -Force

# Step 3: Applications and Packages
$apps = $deployConfig.Tools | Where-Object { $_.Appinstall -eq $true }
if ($apps) {
    Install-Applications -Apps $apps -ThisMachineName $ThisMachineName
}

# Step 4: Set TwoKeyApproval (auto-approval for scripts)
$namespace = "ROOT\SMS\site_$SiteCode"
Set-TwoKeyApproval -SiteCode $SiteCode -Namespace $namespace

# Step 5: Import Scripts
Import-CMScripts

# Step 6: Task Sequences
$taskSequences = Get-CMTaskSequence | Where-Object { $_.Name -like "MEMLABS-*" }

if (!$taskSequences) {
    # Set up boot images and OSD share
    $DriveLetter = Install-BootImagesAndOSD -DomainFullName $DomainFullName -ThisMachineName $ThisMachineName

    # Create OS packages
    New-OSPackages -ThisMachineName $ThisMachineName

    # Create task sequences
    New-TaskSequences -DeployConfig $deployConfig -ThisMachineName $ThisMachineName -DomainFullName $DomainFullName -DN $DN
}
else {
    Write-DscStatus "$Tag Task sequences already exist, skipping creation"

    # Still need drive letter for later steps
    $DriveLetter = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" |
        Select-Object -ExpandProperty "Installation Directory" | Split-Path -Qualifier
}

# Step 7: Configuration Baselines
Import-Baselines

# Step 8: PowerShell Bypass Client Setting
Set-PowerShellBypassClientSetting

# Step 9: Device Collections
New-DeviceCollections -SiteCode $SiteCode

# Step 10: Endpoint Protection and Client Settings
Install-EndpointProtectionAndClientSettings -SiteCode $SiteCode -ProviderMachineName $ProviderMachineName

# Step 11: SUP Products and ADRs
Set-SUPProductsAndClassifications -DeployConfig $deployConfig -SiteCode $SiteCode `
    -CMInstallDir $CMInstallDir -ThisMachineName $ThisMachineName `
    -DriveLetter $DriveLetter -ProviderMachineName $ProviderMachineName

# Step 12: Refresh Unknown Computers collection
$collection = Get-CMCollection -Name "All Unknown Computers"
if ($collection -and $collection.CollectionID) {
    Invoke-CMCollectionUpdate -CollectionId $collection.CollectionID
}

# Create flag file to prevent re-execution
New-Item -ItemType File -Path $flagFile -Force | Out-Null
Write-DscStatus "$Tag Perf loading completed successfully"
Write-DscStatus "$Tag ******************************************" -NoStatus
Write-DscStatus "$Tag ******************************************" -NoStatus

#endregion Main Execution
