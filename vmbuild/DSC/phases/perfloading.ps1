#perfloading.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[perfloading]"

Write-DscStatus "$Tag Starting perfloading"

    if ( -not $ConfigFilePath) {
        $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
    }

    # Read config json
    $deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

    # Resolve per-VM cmOptions: this runs on a specific top-level site server,
    # so prefer its stamped block over the global mirror (multi-hierarchy safe).
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
    $cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }

    if ($cmo.PrePopulateObjects -ne $true) {
        return
    }

    # dot source functions
    . $PSScriptRoot\ScriptFunctions.ps1

    # Get required values from config
    $DomainFullName = $deployConfig.parameters.domainName
    $DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')   
    # $ThisMachineName / $ThisVM / $cmo already resolved above (before PrePopulateObjects gate).
    $CurrentRole = $ThisVM.role
    # Top-level = CAS or standalone Primary (no parent). Child Primaries in a
    # hierarchy cannot run hierarchy-level cmdlets (site features, default
    # client settings, custom client setting creation/deployment).
    $isTopLevel = ($CurrentRole -eq 'CAS') -or (-not $ThisVM.parentSiteCode)
    $DCVM = ($deployConfig.virtualMachines | Where-Object { $_.Role -eq "DC" })
    $DCName = $DCVM.vmName
    $CMInstallDir = $ThisVM.CMInstallDir
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
    $existingDPGroups = @(Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name)

    if ($DPGroupName -in $existingDPGroups) {

        Write-DscStatus "$Tag DP group: $DPGroupName already exists"

    }
    else { 
        $DPGroup = New-CMDistributionPointGroup -Name $DPGroupName -Description "Group containing all Distribution Points" -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag DP group: $DPGroupName created successfully"

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


    #Enable Site features (hierarchy-level — top-level site only)
    if ($isTopLevel) {
        Write-DscStatus "$Tag Enabling Site features"
        try {
            Get-CMSiteFeature -Production -Fast | Enable-CMSiteFeature -Force
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to enable site features: $_"
        }
    }

    #Applications and packages — Primary only (content sources are local)
    if ($CurrentRole -ne "CAS") {

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

        if (Get-CMApplication -Name "$appname" -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Application '$appname' already exists, skipping"
        }
        else {
            Write-DscStatus "$Tag Creating an MEMLABS application for $($_.Name) as App model"
            New-CMApplication -Name "$appname" -Description $($_.Description) -Publisher $($_.Publisher) -SoftwareVersion $($_.SoftwareVersion) -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully created an MEMLABS application for $($_.Name) as App model"

            Write-DscStatus "$Tag Creating an MEMLABS application deployment for $($_.Name) as App model"
            Add-CMMSiDeploymentType -ApplicationName "$appname" -DeploymentTypeName $($_.AppMsi) -ContentLocation "\\$ThisMachineName\c$\Apps\$($_.Name)\$($_.AppMsi)" -Comment "$($_.Name) MSI deployment type" -Force -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully an MEMLABS application deployment for $($_.Name) as App model"

            Write-DscStatus "$Tag Distributing MEMLABS application $($_.Name) to all DPs"
            Start-CMContentDistribution -ApplicationName "$appname" -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully distributed MEMLABS application $($_.Name) to all DPs"

            Write-DscStatus "$Tag Deploying MEMLABS application $($_.Name) to all Systems as available deployment"
            New-CMApplicationDeployment -ApplicationName "$appname" -CollectionName "All Systems" -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag successfully deployed MEMLABS application $($_.Name) to all Systems as available deployment"
        }

        $pkgName = "MEMLABS-$($_.Name)"

        if (Get-CMPackage -Name "$pkgName" -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Package '$pkgName' already exists, skipping"
        }
        else {
            Write-DscStatus "$Tag Creating an MEMLABS application deployment for $($_.Name) as Package model"
            $Package = New-CMPackage -Name "$pkgName" -Path "\\$ThisMachineName\c$\Apps\$($_.Name)" -Description "Package for $($_.Description)"
            Write-DscStatus "$Tag Successfully created a MEMLABS application deployment for $($_.Name) as Package model"

            Write-DscStatus "$Tag Creating an MEMLABS package deployment for $($_.Name) as Package model"
            $CommandLine = "msiexec.exe /i $($_.AppMsi) /qn"
            New-CMProgram -PackageId $Package.PackageID -StandardProgramName $($_.AppMsi) -CommandLine $CommandLine 
            Write-DscStatus "$Tag Successfully created a MEMLABS package deployment for $($_.Name) as Package model"

            Write-DscStatus "$Tag Distributing MEMLABS package $($_.Name) to all DPs"
            Start-CMContentDistribution -PackageId $Package.PackageID -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Successfully distributed MEMLABS package $($_.Name) to all DPs"

            Write-DscStatus "$Tag Deploying MEMLABS package $($_.Name) to all Systems as available deployment"
            New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID -ProgramName $($_.AppMsi) -CollectionName "All Systems" -DeployPurpose Available
            Write-DscStatus "$Tag successfully deployed MEMLABS package $($_.Name) to all Systems as available deployment"
        }
    }

    #region Microsoft 365 Apps deployment via ODT (background download)
    # Check if any VMs have installOffice configured
    $officeDownloadJob = $null
    $officeVMs = @($deployConfig.virtualMachines | Where-Object { $_.installOffice -and $_.installOffice -ne $false })
    if ($officeVMs.Count -gt 0) {

        $officeAppName = "MEMLABS-Microsoft365Apps"
        $officeSourceRoot = "C:\OfficeSource"
        $officeShareName = "OfficeSource$"
        $odtPath = "C:\tools\odt"

        if (Get-CMApplication -Name $officeAppName -Fast -ErrorAction SilentlyContinue) {
            Write-DscStatus "$Tag Office application '$officeAppName' already exists, skipping Office deployment setup"
        }
        else {
            Write-DscStatus "$Tag Configuring Microsoft 365 Apps deployment for $($officeVMs.Count) VM(s)"

            # Determine unique channels needed
            $channels = @($officeVMs | ForEach-Object { $_.installOffice } | Select-Object -Unique)
            Write-DscStatus "$Tag Office channels requested: $($channels -join ', ')"

            # Channel name to ODT Channel attribute mapping
            $channelMap = @{
                'Current'           = 'Current'
                'MonthlyEnterprise' = 'MonthlyEnterprise'
                'SemiAnnual'        = 'SemiAnnualPreview'
            }

            # Kick off the ODT bootstrapper + Office source download (~2-4 GB per
            # channel) as a background job. This is pure filesystem work with no
            # ConfigMgr dependency, so it overlaps with the boot image / OSD / task
            # sequence / baseline work that follows. The matching join + ConfigMgr
            # application creation happens after the baseline section below.
            $officeDownloadScript = {
                param($jobChannels, $jobChannelMap, $jobSourceRoot, $jobOdtPath)

                $messages = New-Object System.Collections.Generic.List[string]
                $channelResults = @{}
                $odtOk = $false

                try {
                    if (-not (Test-Path "$jobOdtPath\setup.exe")) {
                        $messages.Add("Downloading Office Deployment Tool")
                        New-Item -ItemType Directory -Path $jobOdtPath -Force | Out-Null
                        $odtUrl = "https://officecdn.microsoft.com/pr/wsus/setup.exe"
                        try {
                            Invoke-WebRequest -Uri $odtUrl -OutFile "$jobOdtPath\setup.exe" -UseBasicParsing -ErrorAction Stop
                            $messages.Add("ODT downloaded successfully")
                        }
                        catch {
                            $messages.Add("WARNING: Failed to download ODT: $_. Office deployment will be skipped.")
                        }
                    }

                    if (Test-Path "$jobOdtPath\setup.exe") {
                        $odtOk = $true

                        foreach ($channel in $jobChannels) {
                            $odtChannel = $jobChannelMap[$channel]
                            if (-not $odtChannel) {
                                $messages.Add("WARNING: Unknown Office channel '$channel', defaulting to Current")
                                $odtChannel = 'Current'
                            }

                            $channelSourcePath = Join-Path $jobSourceRoot $channel
                            New-Item -ItemType Directory -Path $channelSourcePath -Force | Out-Null

                            # Generate download configuration.xml
                            $downloadXml = @"
<Configuration>
  <Add SourcePath="$channelSourcePath" OfficeClientEdition="64" Channel="$odtChannel">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
</Configuration>
"@
                            $downloadXmlPath = Join-Path $channelSourcePath "download.xml"
                            $downloadXml | Set-Content -Path $downloadXmlPath -Encoding UTF8 -Force

                            # Generate install configuration.xml
                            $installXml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$odtChannel">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="TRUE" />
  <RemoveMSI />
</Configuration>
"@
                            $installXmlPath = Join-Path $channelSourcePath "install.xml"
                            $installXml | Set-Content -Path $installXmlPath -Encoding UTF8 -Force

                            # Generate uninstall configuration.xml
                            $uninstallXml = @"
<Configuration>
  <Remove>
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
    </Product>
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
                            $uninstallXmlPath = Join-Path $channelSourcePath "uninstall.xml"
                            $uninstallXml | Set-Content -Path $uninstallXmlPath -Encoding UTF8 -Force

                            # Copy ODT setup.exe into the channel source folder
                            Copy-Item "$jobOdtPath\setup.exe" -Destination $channelSourcePath -Force

                            # Download Office source files (this pulls ~2-4 GB from officecdn.microsoft.com)
                            if (-not (Test-Path (Join-Path $channelSourcePath "Office\Data"))) {
                                $messages.Add("Downloading Office source files for channel '$channel' (this may take several minutes)...")
                                $downloadProcess = Start-Process -FilePath "$channelSourcePath\setup.exe" -ArgumentList "/download `"$downloadXmlPath`"" -Wait -PassThru -NoNewWindow
                                if ($downloadProcess.ExitCode -eq 0) {
                                    $messages.Add("Office source download complete for channel '$channel'")
                                    $channelResults[$channel] = $true
                                }
                                else {
                                    $messages.Add("WARNING: ODT download for channel '$channel' exited with code $($downloadProcess.ExitCode)")
                                    $channelResults[$channel] = $false
                                }
                            }
                            else {
                                $messages.Add("Office source files already present for channel '$channel', skipping download")
                                $channelResults[$channel] = $true
                            }
                        }
                    }
                }
                catch {
                    $messages.Add("WARNING: Office download job exception: $_")
                }

                return [PSCustomObject]@{
                    OdtOk          = $odtOk
                    ChannelResults = $channelResults
                    Messages       = $messages
                }
            }

            $officeDownloadJob = Start-Job -Name "OfficeODTDownload" -ScriptBlock $officeDownloadScript -ArgumentList $channels, $channelMap, $officeSourceRoot, $odtPath
            Write-DscStatus "$Tag Started background Office source download job (runs during OSD/TS/baseline setup)"
        }
    }
    #endregion Microsoft 365 Apps deployment via ODT

    } # end Primary-only apps/packages block

    ## Changing the auto-approval setting on Hierarchy settings

    $namespace = "ROOT\SMS\site_$SiteCode"
    $classname = "SMS_SCI_SiteDefinition"

    Write-DscStatus "$Tag Current namespace is: $namespace and class name is: $classname"

    # Fetch the instance of the class
    $instance = Get-CimInstance -ClassName $className -Namespace $namespace -Filter "SiteCode like '$SiteCode'"

    if ($null -ne $instance) {
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
                if ($script -and $script.ScriptGuid) {
                    Write-DscStatus "$Tag Successfully imported: $ScriptName"
                    # Approve the script by Guid, this is not working as it requires a diff author or the checkmark to be removed (set-cmheirarchysettings doesn't have that feature yet) Tim help needed here
                    Approve-CMScript -ScriptGuid $script.ScriptGuid -Comment "MEMLABS auto approved"
                }
                else {
                    Write-DscStatus "$Tag Imported $ScriptName but New-CMScript returned no ScriptGuid — skipping auto-approve"
                }
            }
        }
        catch {
            Write-DscStatus "$Tag Failed to import: $ScriptName. Error: $_"
        }
    }


    ## Task sequences — Primary only (boot images, OSD content, local shares)
    if ($CurrentRole -ne "CAS") {

    #custom domain name in winPE (default client setting — top-level only)
    if ($isTopLevel) {
        try {
            Set-CMClientSettingComputerAgent -DefaultSetting -BrandingTitle $DomainFullName
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to set branding title: $_"
        }
    }

    # Get all boot images. On a child Primary in a hierarchy, boot images
    # are replicated from the CAS and may not be available immediately.
    $BootImages = @(Get-CMBootImage)
    if ($BootImages.Count -eq 0 -and $ThisVM.parentSiteCode) {
        Write-DscStatus "$Tag No boot images found yet (child Primary — waiting for CAS replication)"
        for ($biWait = 1; $biWait -le 12; $biWait++) {
            Start-Sleep -Seconds 30
            $BootImages = @(Get-CMBootImage)
            if ($BootImages.Count -gt 0) {
                Write-DscStatus "$Tag Boot images appeared after ${biWait} wait(s)"
                break
            }
        }
    }
    if ($BootImages.Count -eq 0) {
        Write-DscStatus "$Tag WARNING: No boot images found — skipping boot image configuration"
    }
    else {
        Write-DscStatus "$Tag Found $($BootImages.Count) boot image(s): $(($BootImages | ForEach-Object { $_.Name }) -join ', ')"
    }

    # Loop through each boot image: enable command support, then distribute
    foreach ($BootImage in $BootImages) {
        $biName = $BootImage.Name
        $packageId = $BootImage.PackageID

        # Enable Command Support (F8 debug shell in WinPE)
        try {
            Set-CMBootImage -Id $packageId -EnableCommandSupport $true
            Write-DscStatus "$Tag Enabled command support for boot image: $biName ($packageId)"
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to enable command support for boot image: $biName ($packageId). Error: $_"
        }

        # Distribute the boot image
        try {
            Start-CMContentDistribution -BootImageId $packageId -DistributionPointGroupName "ALL DPS"
            Write-DscStatus "$Tag Successfully started distribution for boot image: $biName ($packageId)"
        }
        catch {
            Write-DscStatus "$Tag Failed to start distribution for boot image: $biName ($packageId). Error: $_"
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
    if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $shareName -Path $folderPath -FullAccess @("Administrators", "Everyone")
    }

    Write-DscStatus "$Tag $shareName share successfully shared with Administrators"

    # OSD ISOs are copied to the top-level site server only (Phase 1).
    # On a child Primary under a CAS the OSD folder exists but is empty,
    # so skip OS-package/task-sequence creation when the media isn't there.
    $win11OsdPath = Join-Path $folderPath "Windows 11 24h2"
    $win10OsdPath = Join-Path $folderPath "Windows 10 22h2"
    $hasOsdMedia = (Test-Path "$win11OsdPath\sources\install.wim") -and (Test-Path "$win10OsdPath\sources\install.wim")

    if (-not $hasOsdMedia) {
        Write-DscStatus "$Tag OSD media not found in $folderPath — skipping OS packages and task sequences (ISOs only copied to top-level site)"
    }
    else {

    #get OS upgrade package 
    try {
        New-CMOperatingSystemInstaller -Name "Windows 11 upgrade" -Path "\\$ThisMachineName\OSD\Windows 11 24h2" -Version 10.0.26100 
        New-CMOperatingSystemInstaller -Name "Windows 10 upgrade" -Path "\\$ThisMachineName\OSD\Windows 10 22h2" -Version 10.0.19041 
        Write-DscStatus "$Tag Windows 10 and 11 OS upgrade packages created"
    }
    catch {
        Write-DscStatus "$Tag WARNING: Failed to create OS upgrade packages: $_"
    }

    #get OS package
    try {
        if (!(Get-CMOperatingSystemImage -Name "windows 11")) { New-CMOperatingSystemImage -Name "Windows 11" -Path "\\$ThisMachineName\OSD\Windows 11 24h2\sources\install.wim" -Version 10.0.26100 }
        if (!(Get-CMOperatingSystemImage -Name "windows 10")) { New-CMOperatingSystemImage -Name "Windows 10" -Path "\\$ThisMachineName\OSD\Windows 10 22h2\sources\install.wim" -Version 10.0.19041 }
        Write-DscStatus "$Tag Windows 10 and 11 OS packages created"
    }
    catch {
        Write-DscStatus "$Tag WARNING: Failed to create OS image packages: $_"
    }

    # Get all Task Sequences with names starting with the specified prefix
    $taskSequences = Get-CMTaskSequence | Where-Object { $_.Name -like "MEMLABS-*" }

    if (!$taskSequences) {
    try {

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
        Start-CMContentDistribution -OperatingSystemImageIds @($win11OSimagepackageID, $win10OSimagepackageID) -DistributionPointGroupName  "ALL DPS" -ErrorAction SilentlyContinue
        Start-CMContentDistribution -OperatingSystemInstallerIds @($win11UpgradePackageID, $win10UpgradePackageID) -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue
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
            ProductKey                         = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
            GeneratePassword                   = $false
            LocalAdminPassword                 = ConvertTo-SecureString -String "$unencrypted" -AsPlainText -Force
            TimeZone                           = $tstimezone
            JoinDomain                         = "WorkgroupType"
            WorkgroupName                      = "workgroup"
            ClientPackagePackageId             = $ClientPackagePackageId
            InstallationProperty               = $clientProps
            ApplicationName                    = "Admin Console"
            IgnoreInvalidApplication           = $true
            SoftwareUpdateStyle                = "All"
            OperatingSystemFilePath            = $win10UpgradeOperatingSystemWim
            ImageDescription                   = "MEMLABS autocreated"
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

        # Get all task sequences with names starting with "MEMLABS"
        $taskSequences = Get-CMTaskSequence -Fast | Where-Object { $_.Name -like "MEMLABS*" }

        # Get the "All Unknown Computers" collection
        $unknownCollection = Get-CMDeviceCollection -Name "All Unknown Computers"

        foreach ($ts in $taskSequences) {
            # Check if a deployment already exists for this task sequence to this collection
            $existingDeployment = Get-CMDeployment -CollectionName $unknownCollection.Name | Where-Object { $_.PackageID -eq $ts.PackageID }

            if ($existingDeployment) {
                Write-DscStatus "Skipping $($ts.Name) already deployed to $($unknownCollection.Name)"
            }
            else {
                try {
                    Write-DscStatus "Deploying Task Sequence: $($ts.Name)"

                    New-CMTaskSequenceDeployment `
                        -TaskSequencePackageId $ts.PackageID `
                        -CollectionId $unknownCollection.CollectionID `
                        -DeployPurpose Available `
                        -MakeAvailableTo ClientsMediaAndPxe
                }
                catch {
                    Write-DscStatus "$Tag WARNING: Failed to deploy TS '$($ts.Name)': $_"
                }
            }

        }


    }
    catch {
        Write-DscStatus "$Tag WARNING: Failed to create task sequences: $_"
    }
    }
    else {

        Write-DscStatus "$Tag Task sequences were already created, skipping the duplicate creation"

    }

    } # end hasOsdMedia

    } # end Primary-only TS/OSD block

    ### CI and baselines 

    #expand archive for importing cab files
    $baselinesZip = "C:\tools\baselines.zip"
    $baselineFolder = "C:\tools\baselines"

    if (Test-Path $baselinesZip) {
        Expand-Archive -Path $baselinesZip -DestinationPath "C:\tools\" -Force
    }
    else {
        Write-DscStatus "$Tag WARNING: baselines.zip not found at $baselinesZip — skipping CI/baseline import"
    }

    # Get all .cab files in the folder
    if (Test-Path $baselineFolder) {
    $ConfigNames = Get-ChildItem -Path $baselineFolder -Filter "*.cab"

    ForEach ($ConfigName in $ConfigNames) {

        $baselinename = [System.IO.Path]::GetFileNameWithoutExtension($ConfigName.Name)

        if (!(Get-CMBaseline -Fast -Name $baselinename)) {
            try {
                # Create a configuration item (we are importing the cab files directly here)
                $filename = $baselineFolder + "\" + $ConfigName.Name
                Write-DscStatus "$Tag Importing cab from $filename location"
                Import-CMConfigurationItem -FileName $filename -Force
                Write-DscStatus "$Tag Successfully created Configuration Item for $baselinename"
    
                # Create the configuration baseline
                New-CMBaseline -Name $baselinename -Description "MEMLABS auto imported" 
                Write-DscStatus "$Tag Successfully created Configuration Baseline for $baselinename"

                # Link the configuration item to the configuration baseline (we are using the same name for CI and baseline so using the same name here)
                $ciinfo = Get-CMConfigurationItem -Name $baselinename -Fast
                Set-CMBaseline -Name $baselinename -AddOSConfigurationItem $ciinfo.CI_ID 
                Write-DscStatus "$Tag Successfully linked CI and CB for $baselinename"

                # Deploy the configuration baseline to a collection
                Write-DscStatus "$Tag Deploying baseline $baselinename to All Systems..."
                New-CMBaselineDeployment -Name $baselinename -CollectionName "All Systems" -EnableEnforcement $true
                Write-DscStatus "$Tag Successfully deployed the baseline $baselinename to All systems"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Failed to import/deploy baseline '$baselinename': $($_.Exception.Message)"
            }
        }
        else {
            Write-DscStatus "Baseline $baselinename are already in place"

        }
    }
    } # end if baselineFolder exists

    #region Microsoft 365 Apps — join background download + create applications
    # The Office source download was started as a background job at the top of the
    # apps/packages section so it could run concurrently with the OSD/TS/baseline
    # work above. Join it now and create the ConfigMgr applications. Guarded to
    # Primary/standalone (non-CAS) — matching where the job was started.
    if ($CurrentRole -ne "CAS" -and $officeDownloadJob) {
        Write-DscStatus "$Tag Waiting for background Office source download job to complete..."
        Wait-Job -Job $officeDownloadJob | Out-Null
        $officeDownloadResult = Receive-Job -Job $officeDownloadJob
        Remove-Job -Job $officeDownloadJob -Force -ErrorAction SilentlyContinue

        # Replay the job's log messages through Write-DscStatus (the job ran silently)
        if ($officeDownloadResult -and $officeDownloadResult.Messages) {
            foreach ($officeMsg in $officeDownloadResult.Messages) {
                Write-DscStatus "$Tag $officeMsg"
            }
        }

        if ($officeDownloadResult -and $officeDownloadResult.OdtOk) {

            # Create SMB share for Office source
            if (-not (Get-SmbShare -Name $officeShareName -ErrorAction SilentlyContinue)) {
                New-SmbShare -Name $officeShareName -Path $officeSourceRoot -FullAccess @("Administrators", "Everyone") -ErrorAction SilentlyContinue
                Write-DscStatus "$Tag Created SMB share \\$ThisMachineName\$officeShareName"
            }

            # Create one CM Application per channel
            foreach ($channel in $channels) {
                $channelSourcePath = Join-Path $officeSourceRoot $channel

                # Only create the application if the source files actually downloaded
                if (-not (Test-Path (Join-Path $channelSourcePath "Office\Data"))) {
                    Write-DscStatus "$Tag WARNING: Office source files missing for channel '$channel' — skipping application creation"
                    continue
                }

                $channelAppName = if ($channels.Count -eq 1) { $officeAppName } else { "$officeAppName-$channel" }
                $contentUNC = "\\$ThisMachineName\$officeShareName\$channel"

                if (Get-CMApplication -Name $channelAppName -Fast -ErrorAction SilentlyContinue) {
                    Write-DscStatus "$Tag Application '$channelAppName' already exists, skipping"
                    continue
                }

                Write-DscStatus "$Tag Creating application '$channelAppName'"
                New-CMApplication -Name $channelAppName -Description "Microsoft 365 Apps ($channel channel)" -Publisher "Microsoft" -SoftwareVersion "Latest" -ErrorAction SilentlyContinue

                # Script deployment type: ODT install/uninstall with registry detection
                $installCmd = "setup.exe /configure install.xml"
                $uninstallCmd = "setup.exe /configure uninstall.xml"
                $detectScript = @'
$ctr = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
if ($ctr -and $ctr.VersionToReport) { Write-Host $ctr.VersionToReport }
'@
                Add-CMScriptDeploymentType -ApplicationName $channelAppName `
                    -DeploymentTypeName "ODT Install ($channel)" `
                    -ContentLocation $contentUNC `
                    -InstallCommand $installCmd `
                    -UninstallCommand $uninstallCmd `
                    -ScriptLanguage PowerShell `
                    -ScriptText $detectScript `
                    -LogonRequirementType WhetherOrNotUserLoggedOn `
                    -UserInteractionMode Hidden `
                    -InstallationBehaviorType InstallForSystem `
                    -MaximumRuntimeMins 120 `
                    -EstimatedRuntimeMins 30 `
                    -Force `
                    -ErrorAction SilentlyContinue

                Write-DscStatus "$Tag Distributing '$channelAppName' to all DPs"
                Start-CMContentDistribution -ApplicationName $channelAppName -DistributionPointGroupName "ALL DPS" -ErrorAction SilentlyContinue

                # Deploy as Required to target VMs
                $officeCollectionName = "MEMLABS-Office Install Targets"
                Write-DscStatus "$Tag Deploying '$channelAppName' as Required to collection '$officeCollectionName'"
                New-CMApplicationDeployment -ApplicationName $channelAppName `
                    -CollectionName $officeCollectionName `
                    -DeployAction Install `
                    -DeployPurpose Required `
                    -UserNotification DisplayAll `
                    -ErrorAction SilentlyContinue

                Write-DscStatus "$Tag Office application '$channelAppName' deployment complete"
            }
        }
        else {
            Write-DscStatus "$Tag WARNING: Office source download did not complete; skipping Office application creation"
        }
    }
    #endregion Microsoft 365 Apps — join background download + create applications

    #we have to make powershell bypass for the baselines to work as expected
    # Custom client settings — top-level site only (replicate to child sites)
    if ($isTopLevel) {
    $customclientsetting = "MEMLABS-powershellbypass"
 
    if (!(Get-CMClientSetting -Name $customclientsetting)) {
        New-CMClientSetting -Name $customclientsetting -Description "Client settings for making powershell execution policy as bypass" -Type Device -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag $customclientsetting client setting created"

        # Enable the PowerShell Execution Policy setting
        Set-CMClientSettingComputerAgent -PowerShellExecutionPolicy Bypass -Name $customclientsetting
        Write-DscStatus "$Tag Powershell policy successfully changed for $customclientsetting client setting "

        New-CMClientSettingDeployment -Name $customclientsetting -CollectionId SMS00001
        Write-DscStatus "$Tag Deployed the client setting to all systems collection"
    }
    } # end top-level client settings

    function Get-WsusDiagnostics {
        # Collect WSUS-native health signals for troubleshooting a stuck sync.
        # Returns an array of human-readable diagnostic lines. Never throws.
        $lines = @()

        # 1. WSUS catalog state — the real "did a sync ever work" signal.
        #    GetStatus().UpdateCount stays 0 until the first full sync completes,
        #    even while CM reports the sync as "running".
        try {
            $wsusSrv = Get-WsusServer -ErrorAction Stop
            $wStatus = $wsusSrv.GetStatus()
            $lines += "WSUS UpdateCount=$($wStatus.UpdateCount), ApprovedUpdates=$($wStatus.ApprovedUpdateCount), Computers=$($wStatus.ComputerTargetCount)"
            try {
                $sub = $wsusSrv.GetSubscription()
                $lastInfo = $sub.GetLastSynchronizationInfo()
                $lines += "WSUS LastSync=$($sub.LastSynchronizationTime), Result=$($lastInfo.Result), Error=$($lastInfo.Error)"
            }
            catch { $lines += "WSUS subscription info unavailable: $($_.Exception.Message)" }
        }
        catch {
            $lines += "WSUS GetStatus failed (server may be unreachable): $($_.Exception.Message)"
        }

        # 2. WsusPool app pool state + configured memory cap + queue length.
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $poolPath = 'IIS:\AppPools\WsusPool'
            if (Test-Path $poolPath) {
                $poolState = (Get-WebAppPoolState -Name WsusPool -ErrorAction SilentlyContinue).Value
                $memCap = (Get-ItemProperty -Path $poolPath -Name recycling.periodicRestart.privateMemory -ErrorAction SilentlyContinue).Value
                $qLen = (Get-ItemProperty -Path $poolPath -Name queueLength -ErrorAction SilentlyContinue).Value
                if ($memCap -eq 0) { $capDesc = 'UNCAPPED' } else { $capDesc = "$([math]::Round($memCap/1024,0)) MB cap" }
                $lines += "WsusPool state=$poolState, privateMemory=$capDesc, queueLength=$qLen"
            }
            else {
                $lines += "WsusPool app pool not found"
            }
        }
        catch {
            $lines += "WsusPool state query failed: $($_.Exception.Message)"
        }

        # 3. Actual w3wp working set for WsusPool (balloon/recycle detection).
        try {
            $w3wp = Get-WmiObject Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -match 'WsusPool' } | Select-Object -First 1
            if ($w3wp) {
                $wsMB = [math]::Round($w3wp.WorkingSetSize / 1MB, 0)
                $lines += "WsusPool worker PID=$($w3wp.ProcessId) WorkingSet=$wsMB MB"
            }
            else {
                $lines += "WsusPool worker process not running (no w3wp for WsusPool)"
            }
        }
        catch {
            $lines += "WsusPool worker query failed: $($_.Exception.Message)"
        }

        # 4. SoftwareDistribution.log tail — surface the real failure reason
        #    (503, ODBC/database connect failures, pool recycles, OOM).
        try {
            $sdLog = 'C:\Program Files\Update Services\LogFiles\SoftwareDistribution.log'
            if (Test-Path $sdLog) {
                $hits = Get-Content $sdLog -Tail 400 -ErrorAction Stop |
                    Where-Object { $_ -match '503|ODBC|unable to connect to its database|recycl|OutOfMemory|System.OutOfMemoryException' } |
                    Select-Object -Last 5
                if ($hits) {
                    $lines += "SoftwareDistribution.log recent issues:"
                    foreach ($h in $hits) { $lines += "  $($h.ToString().Trim())" }
                }
                else {
                    $lines += "SoftwareDistribution.log: no 503/ODBC/recycle errors in last 400 lines"
                }
            }
        }
        catch {
            $lines += "SoftwareDistribution.log read failed: $($_.Exception.Message)"
        }

        return $lines
    }

    function Write-WsusDiagnostics {
        param([string]$Reason = "WSUS diagnostics")
        Write-DscStatus "$Tag --- $Reason ---"
        foreach ($l in (Get-WsusDiagnostics)) {
            Write-DscStatus "$Tag   $l"
        }
        Write-DscStatus "$Tag --- end $Reason ---"
    }

    function Set-WsusPoolHardened {
        # Uncap WsusPool memory + raise the queue so the pool survives a full
        # Microsoft Update sync. Mirrors the install-time hardening in
        # ConfigureWSUS (TemplateHelpDSC.psm1). The reactive repair path MUST
        # reharden BEFORE restarting — otherwise the pool comes back with the
        # default ~1.8 GB cap and the next sync dies the same way.
        try {
            Import-Module WebAdministration -ErrorAction Stop
        }
        catch {
            Write-DscStatus "$Tag WsusPool hardening skipped — WebAdministration unavailable: $_"
            return
        }
        $poolPath = 'IIS:\AppPools\WsusPool'
        if (-not (Test-Path $poolPath)) {
            Write-DscStatus "$Tag WsusPool not found — skipping hardening"
            return
        }
        $settings = @(
            @{ Name = 'recycling.periodicRestart.privateMemory'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.requests'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.time'; Value = [TimeSpan]::Zero }
            @{ Name = 'queueLength'; Value = 25000 }
            @{ Name = 'processModel.idleTimeout'; Value = [TimeSpan]::Zero }
            @{ Name = 'startMode'; Value = 'AlwaysRunning' }
            @{ Name = 'failure.rapidFailProtection'; Value = $false }
        )
        foreach ($s in $settings) {
            try {
                Set-ItemProperty -Path $poolPath -Name $s.Name -Value $s.Value -ErrorAction Stop
            }
            catch {
                Write-DscStatus "$Tag WsusPool: failed to set $($s.Name): $_"
            }
        }
        Write-DscStatus "$Tag WsusPool hardened (privateMemory uncapped, queueLength=25000)"
    }

    function Repair-WsusSync {
        # Remediate a stuck/failed WSUS sync by restarting the IIS app pool
        # and the SMS wsyncmgr component, then triggering a fresh sync.
        # Typical cause: WsusPool hit its default ~1.8 GB private-memory recycle
        # cap during the first full Microsoft Update category sync and recycled
        # mid-sync, returning HTTP 503; wsyncmgr couldn't write the failure to
        # SQL, leaving the sync status frozen at 6704 indefinitely.
        # Capture WSUS-native health BEFORE remediation so the log shows WHY.
        Write-WsusDiagnostics -Reason "WSUS health before repair"
        # Reharden the pool (uncap memory) BEFORE restarting — otherwise it comes
        # back with the default ~1.8 GB cap and the next sync dies the same way.
        Set-WsusPoolHardened
        Write-DscStatus "$Tag Restarting WsusPool app pool..."
        try {
            Import-Module WebAdministration -ErrorAction Stop
            Restart-WebAppPool WsusPool
            Write-DscStatus "$Tag WsusPool restarted"
        }
        catch {
            Write-DscStatus "$Tag Could not restart WsusPool: $_"
        }
        # Give the app pool time to fully initialize before wsyncmgr reconnects
        Start-Sleep -Seconds 15
        # Restart SMS_WSUS_SYNC_MANAGER by cycling SMS_EXECUTIVE. This clears
        # any cached connection state and lets wsyncmgr pick up the fresh app pool.
        Write-DscStatus "$Tag Restarting SMS_EXECUTIVE to cycle wsyncmgr..."
        try {
            Restart-Service SMS_EXECUTIVE -Force -ErrorAction Stop
            Start-Sleep -Seconds 30
            Write-DscStatus "$Tag SMS_EXECUTIVE restarted"
        }
        catch {
            Write-DscStatus "$Tag Could not restart SMS_EXECUTIVE: $_"
        }
        # Now trigger a fresh sync
        Invoke-FullSync
    }

    function Invoke-FullSync {
        # Skip if a sync is genuinely running — dropping full.syn during an
        # active sync is harmless but pointless. However, if the "running" state
        # is stale (>15 min unchanged), the sync is dead and we should proceed.
        $currentSync = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $siteCode } | Select-Object -First 1
        if ($currentSync.LastSyncState -in @(6701, 6704, 6705, 6706)) {
            $syncStateNames = @{ 6701='Started'; 6704='Syncing WSUS'; 6705='Syncing DB'; 6706='Syncing Internet WSUS' }
            $stateName = $syncStateNames[$currentSync.LastSyncState]
            $stateAge = (Get-Date) - $currentSync.LastSyncStateTime
            if ($stateAge.TotalMinutes -le 15) {
                Write-DscStatus "$Tag Sync already in progress ($stateName, $([math]::Round($stateAge.TotalMinutes,1)) min) — skipping full.syn drop"
                return
            }
            Write-DscStatus "$Tag Sync state $stateName is stale ($([math]::Round($stateAge.TotalMinutes,0)) min) — proceeding with full.syn drop"
        }
        $syncFolder = "$CMInstallDir\inboxes\wsyncmgr.box"
        $syncFile = Join-Path $syncFolder "full.syn"
        if (Test-Path $syncFolder) {
            try {
                New-Item -Path $syncFile -ItemType File -Force | Out-Null
                Write-DscStatus "$Tag Triggered full WSUS sync (dropped full.syn)"
            }
            catch {
                Write-DscStatus "$Tag Error creating 'full.syn': $_"
            }
        }
    }

    function Wait-WsusSyncCompletion {
        # Poll sync status up to $MaxAttempts times (30s apart). Returns $true
        # if sync reaches 6702 (completed). On 6703 (failed), retries with
        # Invoke-FullSync and escalates to Repair-WsusSync every 3rd failure.
        # On stale in-progress states (>15 min unchanged), repairs immediately.
        param(
            [string]$Label = "Sync",
            [int]$MaxAttempts = 40,
            [switch]$TriggerFirst   # Drop full.syn before entering the wait loop
        )

        if ($TriggerFirst) {
            Invoke-FullSync
        }

        # Cross-check WSUS-native UpdateCount: CM can report a sync as "running"
        # while the WsusPool underneath is dead (recycled at its memory cap →
        # 503), in which case the catalog never grows. Track consecutive polls
        # where CM says "syncing" but UpdateCount stays 0 — that's a zombie sync.
        $zeroUpdateStreak = 0
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            Start-Sleep -Seconds 30
            $status = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1

            if ($status.LastSyncState -eq 6702) {
                Write-DscStatus "$Tag $Label completed (attempt $attempt)"
                return $true
            }
            elseif ($status.LastSyncState -eq 6703) {
                if ($attempt % 3 -eq 0) {
                    Write-DscStatus "$Tag $Label failed $attempt times. Repairing WSUS services... (attempt $attempt of $MaxAttempts)"
                    Write-WsusDiagnostics -Reason "$Label failed (6703) at attempt $attempt"
                    Repair-WsusSync
                }
                else {
                    Write-DscStatus "$Tag $Label failed (attempt $attempt of $MaxAttempts). Triggering retry..."
                    Invoke-FullSync
                }
                $zeroUpdateStreak = 0
            }
            elseif ($status.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                $age = (Get-Date) - $status.LastSyncStateTime
                $wsusUpdateCount = -1
                try { $wsusUpdateCount = (Get-WsusServer -ErrorAction Stop).GetStatus().UpdateCount } catch { }
                if ($wsusUpdateCount -eq 0) { $zeroUpdateStreak++ } else { $zeroUpdateStreak = 0 }

                if ($age.TotalMinutes -gt 15) {
                    Write-DscStatus "$Tag $Label state $($status.LastSyncState) stale ($([math]::Round($age.TotalMinutes,0)) min). Repairing WSUS... (attempt $attempt of $MaxAttempts)"
                    Repair-WsusSync
                    $zeroUpdateStreak = 0
                }
                elseif ($zeroUpdateStreak -ge 6) {
                    # ~3 min of CM "syncing" with an empty WSUS catalog = zombie
                    # sync (pool recycled mid-sync). Reharden + restart to fix it.
                    Write-DscStatus "$Tag $Label reports running but WSUS UpdateCount stuck at 0 for $zeroUpdateStreak polls — zombie sync. Repairing WSUS... (attempt $attempt of $MaxAttempts)"
                    Write-WsusDiagnostics -Reason "$Label zombie (UpdateCount=0) at attempt $attempt"
                    Repair-WsusSync
                    $zeroUpdateStreak = 0
                }
                else {
                    Write-DscStatus "$Tag $Label running (state $($status.LastSyncState), WSUS UpdateCount=$wsusUpdateCount, attempt $attempt of $MaxAttempts)"
                }
            }
            else {
                Write-DscStatus "$Tag $Label unexpected state $($status.LastSyncState) (attempt $attempt of $MaxAttempts)"
            }
        }
        Write-DscStatus "$Tag $Label did not complete after $MaxAttempts attempts."
        Write-WsusDiagnostics -Reason "$Label final timeout diagnostics"
        return $false
    }

    # Kick off WSUS sync early so it runs in background while we create collections
    $Sups = $deployConfig.VirtualMachines | Where-Object { $_.InstallSup -and $_.SiteCode -eq $siteCode }
    $syncNeeded = $false

    if ($cmo.OfflineSUP) {
        $Sups = $false
        Write-DscStatus "$Tag Offline SUP requested, skipping the SUP product check"
    }

    if ($Sups) {
        $productclassifications = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object -ExpandProperty LocalizedCategoryInstanceName
        $products = ($deployConfig.virtualMachines.operatingSystem | Select-Object -Unique ) + ($deployConfig.virtualMachines.sqlversion | Select-Object -Unique)

        # Filter out Linux OS names — WSUS has no products for Ubuntu/Linux
        $products = @($products | Where-Object { $_ -and $_ -notmatch '^Ubuntu|^CentOS|^RHEL|^Debian|^Linux' })

        # Rename products to match SUP naming convention.
        # OS names may have date/variant suffixes (e.g. "Server 2019 March 2021")
        # so anchors use .* instead of $ to match variants.
        $products = $products -replace "^Server 2016\b.*$", "Windows Server 2016"
        $products = $products -replace "^Server 2019\b.*$", "Windows Server 2019"
        $products = $products -replace "^Server 2022\b.*$", "Microsoft Server operating system-21H2"
        $products = $products -replace "^Server 2025\b.*$", "Microsoft Server operating system-24H2"
        $products = $products -replace "^Windows 10\b.*$", "Windows 10, version 1903 and later"
        $products = $products -replace "^Windows 11\b.*$", "Windows 11"
        $products = $products -replace "^Sql Server 2016\b.*$", "Microsoft SQL server 2016"
        $products = $products -replace "^Sql Server 2017\b.*$", "Microsoft SQL server 2017"
        $products = $products -replace "^Sql Server 2019\b.*$", "Microsoft SQL server 2019"
        $products = $products -replace "^Sql Server 2022\b.*$", "Microsoft SQL server 2022"
        $products = $products -replace "^Sql Server 2025\b.*$", "Microsoft SQL server 2025"
        $products += "Microsoft 365 Apps/Office 2019/Office LTSC"
        $products += "Microsoft Defender for Endpoint"
        $products = @($products | Where-Object { $_ } | Select-Object -Unique)

        $missingproducts = @($products | Where-Object { $_ -notin $productclassifications })

        # Check if the specific products we need exist as categories in the
        # full catalog (not just subscribed). WSUS ships with built-in
        # categories, so a generic count isn't meaningful. If our target
        # products are present, sync 1 has populated the catalog and we can
        # subscribe without waiting for the current sync.
        $allCatalogProducts = @(Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Select-Object -ExpandProperty LocalizedCategoryInstanceName)
        $productsInCatalog = @($products | Where-Object { $_ -in $allCatalogProducts })
        # Gate Sync 1 on the *core* OS/SQL products only. Compound/aliased names
        # (the Office bundle string, Defender) may never match a single catalog
        # category — and Defender ships in the WSUS seed before any real sync —
        # so requiring an exact full-set (13/13) match means the gate is never
        # satisfied and Sync 1 re-waits every build. Core OS/SQL categories only
        # appear after a real Microsoft Update sync, so they're the reliable
        # "catalog is populated" signal.
        $coreProducts = @($products | Where-Object { $_ -notmatch '/' -and $_ -ne 'Microsoft Defender for Endpoint' })
        $coreInCatalog = @($coreProducts | Where-Object { $_ -in $allCatalogProducts })
        $catalogHasOurProducts = ($coreProducts.Count -gt 0) -and ($coreInCatalog.Count -eq $coreProducts.Count)

        if ($missingproducts.Count -gt 0) {
            $syncNeeded = $true
            Write-DscStatus "$Tag SUP products missing ($($missingproducts.Count)): $($missingproducts -join ', ')"
            if ($catalogHasOurProducts) {
                # Our target products exist in the catalog from a previous sync —
                # no need to trigger or wait for sync 1. Skip straight to subscribing.
                Write-DscStatus "$Tag Target products found in catalog ($($productsInCatalog.Count)/$($products.Count)) — skipping sync 1 wait"
            }
            else {
                # First run: catalog doesn't have our products yet, need sync 1.
                $missingFromCatalog = @($products | Where-Object { $_ -notin $allCatalogProducts })
                Write-DscStatus "$Tag Products missing from catalog ($($missingFromCatalog.Count)/$($products.Count)): $($missingFromCatalog -join ', ')"
                # Only trigger early sync if WCM is at SUCCESS — otherwise the sync
                # will fail with 'WSUS server not configured' and block WCM from
                # finishing its subscription setup (deadlock).
                $wcmRegPath = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER'
                try {
                    $wcmEarlyState = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                } catch { $wcmEarlyState = -1 }
                if ($wcmEarlyState -eq 2) {
                    Write-DscStatus "$Tag Triggering WSUS sync now (will finish later while we create collections)"
                    Invoke-FullSync
                }
                else {
                    $wcmStateNames = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
                    $wcmName = if ($wcmStateNames.ContainsKey($wcmEarlyState)) { $wcmStateNames[$wcmEarlyState] } else { "UNKNOWN($wcmEarlyState)" }
                    Write-DscStatus "$Tag WCM state is $wcmName — skipping early sync to avoid blocking WCM"
                }
            }
        }
        else {
            Write-DscStatus "$Tag SUP products and classifications are already enabled ($($productclassifications.Count) subscribed)."
        }
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
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client 
from SMS_R_System 
where SMS_R_System.OperatingSystemNameandVersion like "%Server%" order by SMS_R_System.Name          
"@
        },
        @{
            Name  = "MEMLABS-All Workstations"
            Query = @"
select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client 
from SMS_R_System 
where SMS_R_System.OperatingSystemNameandVersion like "%Workstation%" order by SMS_R_System.Name      
"@
        }
    )


        # Check if MEMLABS folder exists under Device Collections
    $folder = Get-CMFolder -FolderPath "\DeviceCollection\MEMLABS"

    if (-not $folder) {
        # Create MEMLABS folder if it does not exist
        New-CMFolder -Name "MEMLABS" -ParentFolderPath "\DeviceCollection"
        Write-DscStatus "$Tag MEMLABS folder created under Device Collections."
    }
    else {
        Write-DscStatus "$Tag MEMLABS folder already exists under Device Collections."
    }


    # Loop through each collection and create it in SCCM
    foreach ($Collection in $Collections) {
        $CollectionName = $Collection.Name
        $Query = $Collection.Query
    
        if (-not (Get-CMDeviceCollection -Name $CollectionName)) {
            try {
                # Create the device collection
                $NewCollection = New-CMDeviceCollection -Name $CollectionName -LimitingCollectionName "All Systems" -Comment "Collection for $CollectionName"

                Write-DscStatus "$Tag Created collection: $CollectionName"

                # Add a query rule to the collection
                Add-CMDeviceCollectionQueryMembershipRule -CollectionName $CollectionName -QueryExpression $Query -RuleName "$CollectionName Rule" -ErrorAction Stop
    
                Write-DscStatus "$Tag Created collection query: $CollectionName Rule"

                # Force collection membership evaluation so members appear immediately
                Invoke-CMCollectionUpdate -CollectionId $NewCollection.CollectionID -ErrorAction Stop

                Move-CMObject -FolderPath "$SiteCode`:\Devicecollection\MEMLABS" -ObjectId $NewCollection.CollectionID -ErrorAction Stop

                Write-DscStatus "$Tag Moved collection '$CollectionName' under the folder MEMLABS"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Failed to fully configure collection '$CollectionName': $($_.Exception.Message)"
            }
        }
    }

    # Office Install Targets collection: query membership for VMs with installOffice.
    # A query rule (keyed on VM name) auto-evaluates on the collection schedule and
    # tolerates ResourceID changes, so a VM that is re-discovered or that appears in
    # CM after this collection is created still becomes a member without a rebuild.
    # The previous direct-membership-by-ResourceID approach captured each device's
    # ResourceID once at creation time: VMs not yet discovered were silently skipped,
    # and a later delete/re-discover left a stale rule pointing at a gone resource,
    # so the collection never populated and Office never deployed.
    $officeCollectionName = "MEMLABS-Office Install Targets"
    $officeTargetVMs = @($deployConfig.virtualMachines | Where-Object { $_.installOffice -and $_.installOffice -ne $false })
    if ($officeTargetVMs.Count -gt 0 -and -not (Get-CMDeviceCollection -Name $officeCollectionName -ErrorAction SilentlyContinue)) {
        try {
            $officeCol = New-CMDeviceCollection -Name $officeCollectionName -LimitingCollectionName "All Systems" -Comment "VMs targeted for Microsoft 365 Apps install"
            Write-DscStatus "$Tag Created collection: $officeCollectionName"

            # Build a WQL 'Name in (...)' membership query from the office VM names.
            $officeNameList = ($officeTargetVMs | ForEach-Object { "'$($_.vmName)'" }) -join ","
            $officeQuery = "select SMS_R_System.ResourceID from SMS_R_System where SMS_R_System.Name in ($officeNameList)"
            Add-CMDeviceCollectionQueryMembershipRule -CollectionId $officeCol.CollectionID -QueryExpression $officeQuery -RuleName "Office Install Targets Rule" -ErrorAction Stop
            Write-DscStatus "$Tag Added query membership rule for: $(($officeTargetVMs | ForEach-Object { $_.vmName }) -join ', ')"

            Invoke-CMCollectionUpdate -CollectionId $officeCol.CollectionID -ErrorAction SilentlyContinue
            Move-CMObject -FolderPath "$SiteCode`:\Devicecollection\MEMLABS" -ObjectId $officeCol.CollectionID -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Moved collection '$officeCollectionName' under MEMLABS folder"
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to create Office Install Targets collection: $($_.Exception.Message)"
        }
    }

    #install Endpoint protection role in hierarchy to support defender updates
    if (!(Get-CMEndpointProtectionPoint -AllSite)) {
        try {
            # this is needed for defender updates and management
            Add-CMEndpointProtectionPoint -ProtectionService AdvancedMembership -SiteCode $SiteCode -SiteSystemServerName $ProviderMachineName
            Write-DscStatus "$Tag Endpoint protection role to support defender patching is installed"
        }
        catch {
            Write-DscStatus "$Tag WARNING: Failed to install Endpoint Protection Point: $_"
        }
    }

    # Client settings — top-level site only (replicate to child sites)
    if ($isTopLevel) {
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
    } # end top-level client settings
    
    # Now wait for WSUS sync that was triggered earlier (ran during collection creation)
    if (-not $Sups) {
        Write-DscStatus "$Tag No SUP installed for this site, skipping the SUP product check and sync"
    }

    if ($Sups -and $syncNeeded) {
        # Two syncs are needed for WSUS to be fully operational:
        #   Sync 1: Pulls in the product catalog so products can be subscribed
        #   Sync 2: After subscribing to products, downloads update metadata
        # InstallRoles already ran sync 1 and waited for it, plus we may have
        # fired an early background sync above. Verify sync 1 completed before
        # adding products — if not, wait for it (up to ~20 min).
        #
        # On re-run: if the product catalog is already populated (from a
        # previous sync 1), skip the wait entirely — we can subscribe
        # products immediately without waiting for any current sync.
        $sync1Done = $false
        if ($catalogHasOurProducts) {
            Write-DscStatus "$Tag Target products already in catalog ($($productsInCatalog.Count)/$($products.Count)) — skipping sync 1 wait, proceeding to subscribe"
            $sync1Done = $true
        }
        else {
            $syncStatus = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
            if ($syncStatus.LastSyncState -eq 6702) {
                Write-DscStatus "$Tag Sync 1 already completed (last: $($syncStatus.LastSyncStateTime)) — proceeding to add products"
                $sync1Done = $true
            }
            elseif ($syncStatus.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                # Sync appears to be running — but check if the state is stale.
                $syncAge = (Get-Date) - $syncStatus.LastSyncStateTime
                if ($syncAge.TotalMinutes -gt 15) {
                    Write-DscStatus "$Tag Sync 1 state $($syncStatus.LastSyncState) is stale ($([math]::Round($syncAge.TotalMinutes,0)) min old) — treating as failed. Repairing WSUS..."
                    Repair-WsusSync
                }
                else {
                    Write-DscStatus "$Tag Sync 1 is in progress (state $($syncStatus.LastSyncState), age $([math]::Round($syncAge.TotalMinutes,1)) min) — waiting for completion..."
                }
                $sync1Done = Wait-WsusSyncCompletion -Label "Sync 1"
            }
            else {
                # No sync has run or last sync failed — trigger one and wait
                Write-DscStatus "$Tag No completed sync found (state=$($syncStatus.LastSyncState)). Triggering sync 1..."
                $sync1Done = Wait-WsusSyncCompletion -Label "Sync 1" -TriggerFirst
            }
        }
        if (-not $sync1Done) {
            Write-DscStatus "$Tag WARNING: Sync 1 did not complete after 40 attempts. Adding products anyway — sync 2 may fail if catalog is incomplete."
        }

        Write-DscStatus "$Tag Enabling missing products: $($products -join ', ')"
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
            default { $addLang = "English" }
        }

        Write-DscStatus "$Tag the locale language is $addLang"

        $parameters = @{
            InputObject                   = $supComp
            SynchronizeAction             = 'SynchronizeFromMicrosoftUpdate'
            AddUpdateClassification       = "Critical Updates", "Definition updates", "Security Updates", "Upgrades", "updates"
            Schedule                      = $schedule
            EnableSyncFailureAlert        = $true
            ImmediatelyExpireSupersedence = $false
            AddLanguageUpdateFile         = $addLang
            AddLanguageSummaryDetails     = $addLang
            EnableCallWsusCleanupWizard   = $true
            WaitMonth                     = 3
            EnableThirdPartyUpdates       = $true
            EnableManualCertManagement    = $false
            AddProduct                    = $products
        }

        Set-CMSoftwareUpdatePointComponent @parameters

        #there is an additional windows 10 component under Developer tools which gets enabled by above method, so we are removing the product family to avoid it explicitly
        Set-CMSoftwareUpdatePointComponent -RemoveProductFamily "Developer Tools, Runtimes, and Redistributables"
        Write-DscStatus "$Tag Products enabled. Waiting for WCM to reconfigure WSUS with new products..."

        # Adding products triggers WCM reconfiguration (SUBSCRIPTION_PENDING).
        # We must wait for WCM to reach SUCCESS before triggering a sync,
        # otherwise wsyncmgr sees 'WSUS server not configured' and the sync
        # blocks WCM from setting the subscription (deadlock).
        $wcmRegPath = 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER'
        $wcmStateNames = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
        $wcmReady = $false
        for ($wcmWait = 1; $wcmWait -le 20; $wcmWait++) {
            Start-Sleep -Seconds 30
            try {
                $wcmRegVal = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
            } catch { $wcmRegVal = -1 }
            $wcmName = if ($wcmStateNames.ContainsKey($wcmRegVal)) { $wcmStateNames[$wcmRegVal] } else { "UNKNOWN($wcmRegVal)" }
            if ($wcmRegVal -eq 2) {
                Write-DscStatus "$Tag WCM reached SUCCESS after product update (attempt $wcmWait)"
                $wcmReady = $true
                break
            }
            if ($wcmRegVal -eq 3 -and ($wcmWait % 5 -eq 0)) {
                Write-DscStatus "$Tag WCM state is FAILED. Restarting WsusService to trigger reconfiguration (attempt $wcmWait of 20)"
                Restart-Service -Name WsusService -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 30
            }
            else {
                Write-DscStatus "$Tag WCM state: $wcmName (attempt $wcmWait of 20)"
            }
        }
        if ($wcmReady) {
            # Verify products are actually subscribed before triggering sync
            $postProducts = Get-CMSoftwareUpdateCategory -Fast -TypeName "product" | Where-Object { $_.IsSubscribed } | Select-Object -ExpandProperty LocalizedCategoryInstanceName
            $stillMissing = @($products | Where-Object { $_ -notin $postProducts })
            if ($stillMissing.Count -gt 0) {
                Write-DscStatus "$Tag WARNING: Products still not subscribed after WCM SUCCESS ($($stillMissing.Count)): $($stillMissing -join ', ')"
                Write-DscStatus "$Tag Subscribed products ($($postProducts.Count)): $($postProducts -join ', ')"
            }
            else {
                Write-DscStatus "$Tag All $($products.Count) products confirmed subscribed"
            }

            Write-DscStatus "$Tag Requesting sync with new products..."
            Invoke-FullSync

            # Verify the sync is running or completed — if not, log diagnostics
            Start-Sleep -Seconds 15
            $postSync = Get-CMSoftwareUpdateSyncStatus | Where-Object { $_.SiteCode -eq $SiteCode } | Select-Object -First 1
            $syncRunning = $postSync.LastSyncState -in @(6701, 6704, 6705, 6706)
            $syncDone = $postSync.LastSyncState -eq 6702
            if ($syncRunning) {
                Write-DscStatus "$Tag Sync is running (state $($postSync.LastSyncState)) — continuing, it will finish in background"
            }
            elseif ($syncDone -and $postSync.LastSyncStateTime -and ((Get-Date) - $postSync.LastSyncStateTime).TotalMinutes -lt 5) {
                Write-DscStatus "$Tag Sync already completed (finished $([math]::Round(((Get-Date) - $postSync.LastSyncStateTime).TotalMinutes, 1)) min ago)"
            }
            else {
                # Sync didn't start — log diagnostics
                $diag = @()
                $diag += "SyncState=$($postSync.LastSyncState) ErrorCode=$($postSync.LastSyncErrorCode) LastTime=$($postSync.LastSyncStateTime)"
                $wsusSvc = Get-Service -Name WsusService -ErrorAction SilentlyContinue
                $w3svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
                $diag += "WsusService=$($wsusSvc.Status) W3SVC=$($w3svc.Status)"
                try {
                    $wcmRegVal2 = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                    $diag += "WCM=$($wcmStateNames[$wcmRegVal2])"
                } catch { $diag += "WCM=unreadable" }
                $synFile = Join-Path $CMInstallDir 'inboxes\wsyncmgr.box\full.syn'
                $diag += "full.syn=$(if (Test-Path $synFile) { 'present (not yet picked up)' } else { 'gone (picked up or never created)' })"
                Write-DscStatus "$Tag WARNING: Sync did not start after full.syn drop. Diag: $($diag -join ' | ')"
                Write-DscStatus "$Tag Dropping full.syn again as remediation..."
                Invoke-FullSync
            }
        }
        else {
            Write-DscStatus "$Tag WCM did not reach SUCCESS after 20 attempts. Skipping sync trigger — wsyncmgr will sync on schedule."
            # Log diagnostics so we can investigate
            $diag = @()
            try {
                $wcmRegVal2 = [int](Get-ItemPropertyValue -Path $wcmRegPath -Name 'ConfigurationState' -ErrorAction Stop)
                $diag += "WCM=$($wcmStateNames[$wcmRegVal2])"
            } catch { $diag += "WCM=unreadable" }
            $wsusSvc = Get-Service -Name WsusService -ErrorAction SilentlyContinue
            $diag += "WsusService=$($wsusSvc.Status)"
            $wcmLog = Join-Path $CMInstallDir "Logs\WCM.log"
            if (Test-Path $wcmLog) {
                $wcmTail = @(Get-Content $wcmLog -Tail 3 -ErrorAction SilentlyContinue)
                foreach ($line in $wcmTail) {
                    if ($line -match 'LOG\[(.+?)\]LOG') { $diag += "WCM.log: $($Matches[1].Substring(0, [Math]::Min(120, $Matches[1].Length)))" }
                }
            }
            Write-DscStatus "$Tag WCM timeout diag: $($diag -join ' | ')"
        }
    }
    if ($Sups) {
        # Define the collection where the updates will be deployed
        $TargetCollection = Get-CMDeviceCollection -Name "All systems"
    
        # Define ADR Names
        $ADRNames = @{
            "Client"   = "MEMLABS-ADR-Windows-10/11"
            "Server"   = "MEMLABS-ADR-Windows-Servers"
            "Defender" = "MEMLABS-ADR-Windows-defender"
            "office"   = "MEMLABS-ADR-O365patching"
        }

        # Define the folder path and share name — Primary only (local shares)
        if ($CurrentRole -ne "CAS") {
        $folderPath1 = "$DriveLetter\updatePkgs"
        $shareName1 = "updatePkgs"

        Write-DscStatus "$Tag sharing the updatePkgs folder as - $folderPath1"

        # Create the folder if it doesn't exist
        if (-not (Test-Path -Path $folderPath1)) {
            New-Item -ItemType Directory -Path $folderPath1
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "windows10-11")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windowsserver")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "Windows_defender")
            New-Item -ItemType Directory -Path (Join-Path $folderPath1 "O365") 
            Write-DscStatus "$Tag updatePkgs folder does not exist and creating one"
        }

        # Create the share with read access for "Everyone"
        if (-not (Get-SmbShare -Name $shareName1 -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $shareName1 -Path $folderPath1 -FullAccess @("Administrators", "Everyone")
        }

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
                    Write-DscStatus "$Tag Successfully distributed MEMLABS $PackageName to all DPs"
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
                    New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Client `
                        -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false `
                        -Product "windows 11", "Windows 10, version 1903 and later" -Architecture X64 `
                        -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                        -DeploymentPackageName $Packages[0].Name -Description "MEMLABS autocreated ADR for win 10/11 patching" `
                        -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                    Write-DscStatus "$Tag ADR created successfully for Windows 10 and 11 Security Updates"
                    $success = $true
                }
                catch {
                    Write-DscStatus "$Tag An error occurred while creating the ADR for Windows 10 and 11 Security Updates: $_"
                    $attempt++
                    Write-DscStatus "$Tag Retrying ADR creation, attempt $attempt of $maxAttempts"
                    Start-Sleep -Seconds 30
                }
            }
        
            if (-not $success) {
                Write-DscStatus "$Tag ADR creation failed after $maxAttempts attempts."
            }
        
            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Server `
                    -DateReleasedOrRevised Last7Days -Title "cumulative", "security", "malicious" -Superseded $false -Product "Windows Server 2016", "Windows Server 2019", "Microsoft Server operating system-21H2", "Microsoft Server operating system-24H2" -Architecture X64 `
                    -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[1].Name -Description "MEMLABS autocreated ADR for win server patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
    
                Write-DscStatus "$Tag ADR created successfully for Windows server Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for win server patching"
            }
            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.Defender `
                    -DateReleasedOrRevised Last7Days -UpdateClassification "Definition updates" -Superseded $false -Product $products -Architecture X64 `
                    -Schedule $dailySchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[2].Name -Description "MEMLABS autocreated ADR for definition updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                Write-DscStatus "$Tag ADR created successfully for Defender Security Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for Defender Security Updates"
            }

            try {
                New-CMSoftwareUpdateAutoDeploymentRule -CollectionId SMSDM003 -Name $ADRNames.office `
                    -DateReleasedOrRevised Last7Days -Titles "-preview", "Microsoft 365 Apps Update" -Superseded $false -Product "Microsoft 365 Apps/Office 2019/Office LTSC" `
                    -Schedule $patchTueSchedule -RunType RunTheRuleOnSchedule `
                    -DeploymentPackageName $Packages[3].Name -Description "MEMLABS autocreated ADR for O365 updates patching" -AddToExistingSoftwareUpdateGroup $true -UserNotification DisplayAll
        
                Write-DscStatus "$Tag ADR created successfully for O365 Updates"
            }
            catch {
                Write-DscStatus "$Tag An error occurred while creating the ADR for O365 Updates"
            }
            ##this sync will take a long time as it will almost pull 3k-5k updates down so don't wait for the process to finish
            Invoke-FullSync
        }

        } # end Primary-only update packages/ADR block
    }

    $collection = Get-CMCollection -Name "All Unknown Computers"
    if ($Collection -and $Collection.CollectionID) {
        try { Invoke-CMCollectionUpdate -CollectionId $collection.CollectionID } catch {}
    }    

    Write-DscStatus "$Tag Completed the perf loading the environment"
    Write-DscStatus "$Tag ******************************************" -NoStatus
    Write-DscStatus "$Tag ******************************************" -NoStatus