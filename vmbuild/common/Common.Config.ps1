########################
### Config Functions ###
########################

function Get-UserConfiguration {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Configuration Name/File")]
        [string]$Configuration
    )

    $return = [PSCustomObject]@{
        Loaded     = $false
        Config     = $null
        Message    = $null
        ConfigPath = $null
    }

    # Add extension
    if (-not $Configuration.ToLowerInvariant().EndsWith(".json")) {
        if (-not $Configuration.ToLowerInvariant().EndsWith(".memlabs")) {
            $Configuration = "$Configuration.json"
        }
    }

    $configPath = $Configuration
    if (-not (Test-Path $configPath)) {
        # Get deployment configuration
        $configPath = Join-Path $Common.ConfigPath $Configuration
        if (-not (Test-Path $configPath)) {
            $testConfigPath = Join-Path $Common.ConfigPath "tests\$Configuration"
            if (-not (Test-Path $testConfigPath)) {
                $return.Message = "Get-UserConfiguration: $Configuration not found in $configPath or $testConfigPath. Please create the config manually or use genconfig.ps1, and try again."
                return $return
            }
            $configPath = $testConfigPath
        }
    }
    try {
        Write-Log "Loading $configPath." -LogOnly
        $return.ConfigPath = $configPath
        $config = Get-Content $configPath -Force | ConvertFrom-Json

        #Apply Fixes to Config

        if ($config.cmOptions) {
            if ($null -eq ($config.cmOptions.EVALVersion)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "EVALVersion" -Value $false
            }
            if ($null -eq ($config.cmOptions.UsePKI)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "UsePKI" -Value $false
            }
        }
        if ($null -ne $config.vmOptions.domainAdminName) {
            if ($null -eq ($config.vmOptions.adminName)) {
                $config.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $config.vmOptions.domainAdminName
            }
            $config.vmOptions.PsObject.properties.Remove('domainAdminName')
        }

        foreach ($vm in $config.VirtualMachines) {

            if ($null -ne $vm.SQLInstanceName) {
                if ($null -eq $vm.sqlPort) {
                    if ($vm.SQLInstanceName -eq "MSSQLSERVER") {
                        $vm | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value "1433"
                    }
                    else {
                        $vm | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value "2433"
                    }
                }
            }
            if ($null -ne $vm.AlwaysOnName ) {
                if ($null -eq ($vm.AlwaysOnGroupName)) {
                    $vm | Add-Member -MemberType NoteProperty -Name "AlwaysOnGroupName" -Value $vm.AlwaysOnName
                }
                if ($null -eq ($vm.AlwaysOnListenerName)) {
                    $vm | Add-Member -MemberType NoteProperty -Name "AlwaysOnListenerName" -Value $vm.AlwaysOnName
                }
                $vm.PsObject.properties.Remove('AlwaysOnName')

            }

            if ($vm.role -eq "DPMP") {
                $vm.role = "SiteSystem"
            }

            #add missing Properties
            if ($vm.Role -in "SiteSystem", "CAS", "Primary") {
                if ($null -eq $vm.InstallRP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
                }
                if ($null -eq $vm.InstallSUP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $false -Force
                }
                if ($vm.Role -eq "SiteSystem") {
                    if ($null -eq $vm.InstallMP) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallMP" -Value $false -Force
                    }
                    if ($null -eq $vm.InstallDP) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallDP" -Value $false -Force
                    }
                }
            }

            if ($vm.SqlVersion) {
                foreach ($listVM in $config.VirtualMachines) {
                    if ($listVM.RemoteSQLVM -eq $vm.VmName) {
                        if ($null -eq $vm.InstallRP) {
                            $vm | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
                        }
                    }
                }
            }
        }

        if ($null -ne $config.cmOptions.updateToLatest ) {
            if ($config.cmOptions.updateToLatest -eq $true) {
                $config.cmOptions.version = Get-CMLatestVersion
            }
            $config.cmOptions.PsObject.properties.Remove('updateToLatest')
        }

        if ($null -eq $config.vmOptions.domainNetBiosName ) {
            $netbiosName = $config.vmOptions.domainName.Split(".")[0]
            $config.vmOptions | Add-Member -MemberType NoteProperty -Name "domainNetBiosName" -Value $netbiosName
        }

        if ($null -ne $config.cmOptions.installDPMPRoles) {
            $config.cmOptions.PsObject.properties.Remove('installDPMPRoles')
            foreach ($vm in $config.virtualMachines) {
                if ($vm.Role -eq "SiteSystem") {
                    $vm | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                    $vm | Add-Member -MemberType NoteProperty -Name "installMP" -Value $true -Force
                }
            }
        }




        $return.Loaded = $true
        $return.Config = $config
        return $return
    }
    catch {
        $return.Message = "Get-UserConfiguration: Failed to load $configPath. $_"
        Write-Log "Get-UserConfiguration Trace: $($_.ScriptStackTrace)" -LogOnly
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
        [Parameter(Mandatory = $false, HelpMessage = "Skip Hash Testing of downloaded files.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the image, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    # Load config file
    if ($Configuration -and -not $DownloadAll) {
        $result = Get-UserConfiguration -Configuration $Configuration
        if ($result.Loaded) {
            $config = $result.Config
            $Global:ConfigFile = $ConfigPath
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

    Write-Log "Downloading/Verifying Files required by specified config..." -Activity

    $allSuccess = $true

    foreach ($file in $Common.AzureFileList.OS) {

        if ($file.id -eq "vmbuildadmin") { continue }
        if (-not $DownloadAll -and $operatingSystemsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
            $allSuccess = $false
        }
    }

    foreach ($file in $Common.AzureFileList.ISO) {
        if (-not $DownloadAll -and $sqlVersionsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
            $allSuccess = $false
        }
    }

    foreach ($file in (Get-LinuxImages).Name) {
        if (-not $DownloadAll -and $operatingSystemsToGet -notcontains $file) { continue }
        $worked = Download-LinuxImage $file
        if (-not $worked) {
            Write-Log -Verbose "$file Failed to download via Download-LinuxImage"
            $allSuccess = $false
        }
    }

    return $allSuccess
}

function New-DeployConfig {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object] $configObject
    )
    try {

        # domainAdminName was renamed, this is here for backward compat
        if ($null -ne ($configObject.vmOptions.domainAdminName)) {
            if ($null -eq ($configObject.vmOptions.adminName)) {
                $configObject.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $configObject.vmOptions.domainAdminName
            }
            $configObject.vmOptions.PsObject.properties.Remove('domainAdminName')
        }

        # add prefix to vm names
        $virtualMachines = $configObject.virtualMachines
        foreach ($item in $virtualMachines | Where-Object { -not $_.Hidden -and $_.vmName } ) {
            $item.vmName = $configObject.vmOptions.prefix + $item.vmName
            if ($item.pullDPSourceDP -and -not $item.pullDPSourceDP.StartsWith($configObject.vmOptions.prefix)) {
                $item.pullDPSourceDP = $configObject.vmOptions.prefix + $item.pullDPSourceDP
            }

            if ($item.remoteSQLVM -and -not $item.remoteSQLVM.StartsWith($configObject.vmOptions.prefix)) {
                $item.remoteSQLVM = $configObject.vmOptions.prefix + $item.remoteSQLVM
            }

            if ($item.domainUser) {
                $item.domainUser = $configObject.vmOptions.prefix + $item.domainUser
            }
        }

        $SQLAOPriVMs = $virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not $_.Hidden }
        foreach ($SQLAO in $SQLAOPriVMs) {
            if ($SQLAO) {
                if ($SQLAO.fileServerVM -and -not $SQLAO.fileServerVM.StartsWith($configObject.vmOptions.prefix)) {
                    $SQLAO.fileServerVM = $configObject.vmOptions.prefix + $SQLAO.fileServerVM
                }
                if ($SQLAO.OtherNode -and -not $SQLAO.OtherNode.StartsWith($configObject.vmOptions.prefix)) {
                    $SQLAO.OtherNode = $configObject.vmOptions.prefix + $SQLAO.OtherNode
                }
                if ($SQLAO.ClusterName -and -not $SQLAO.ClusterName.StartsWith($configObject.vmOptions.prefix)) {
                    $SQLAO.ClusterName = $configObject.vmOptions.prefix + $SQLAO.ClusterName
                }
                if ($SQLAO.AlwaysOnListenerName -and -not $SQLAO.AlwaysOnListenerName.StartsWith($configObject.vmOptions.prefix)) {
                    $SQLAO.AlwaysOnListenerName = $configObject.vmOptions.prefix + $SQLAO.AlwaysOnListenerName
                }
            }
        }

        $PassiveVMs = $virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and -not $_.Hidden }
        if ($PassiveVMs) {
            foreach ($PassiveVM in $PassiveVMs) {
                # Add prefix to FS
                if ($PassiveVM.remoteContentLibVM -and -not $PassiveVM.remoteContentLibVM.StartsWith($configObject.vmOptions.prefix)) {
                    $PassiveVM.remoteContentLibVM = $configObject.vmOptions.prefix + $PassiveVM.remoteContentLibVM
                }
            }
        }

        # create params object

        $DCName = ($virtualMachines | Where-Object { $_.role -eq "DC" }).vmName
        $existingDCName = Get-ExistingForDomain -DomainName $configObject.vmOptions.domainName -Role "DC"
        if (-not $DCName) {
            $DCName = $existingDCName
        }

        $params = [PSCustomObject]@{
            DomainName      = $configObject.vmOptions.domainName
            DCName          = $DCName
            ExistingDCName  = $existingDCName
            ThisMachineName = $null
        }

        $sysCenterId = "SysCenterId"
        $sysCenterIdPath = "E:\$sysCenterId.txt"
        if (Test-Path $sysCenterIdPath) {
            $id = Get-Content $sysCenterIdPath -ErrorAction SilentlyContinue
            if ($id) {
                $params | Add-Member -MemberType NoteProperty -Name $sysCenterId -Value $id.Trim() -Force
            }
        }

        $productID = "productID"
        $productIdPath = "E:\$productID.txt"
        if (Test-Path $productIdPath) {
            $prodid = Get-Content $productIdPath -ErrorAction SilentlyContinue
            if ($prodid) {
                $params | Add-Member -MemberType NoteProperty -Name $productID -Value $prodid.Trim() -Force
            }
        }

        $deploy = [PSCustomObject]@{
            cmOptions       = $configObject.cmOptions
            vmOptions       = $configObject.vmOptions
            virtualMachines = $virtualMachines
            parameters      = $params
        }

        return $deploy
    }
    catch {
        Write-Exception -ExceptionInfo $_ -AdditionalInfo ($configObject | ConvertTo-Json)
    }
}
#Add-ExistingVMToDeployConfig -vmName $ActiveNodeVM.remoteSQLVM -configToModify $config
function Add-RemoteSQLVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true
    )
    Write-Log -Verbose "Adding Hidden SQL to config $vmName"
    Add-ExistingVMToDeployConfig -vmName $vmName -configToModify $configToModify -hidden:$hidden
    $remoteSQLVM = Get-VMFromList2 -deployConfig $configToModify -vmName $vmName -SmartUpdate:$true -Global:$true
    if (-not $remoteSQLVM) {
        Write-Log "Could not get $vmName from List2.  Please make sure this VM exists in Hyper-V, and if it doesnt, please modify the hyper-v config to reflect the new name" -Failure
        return
    }
    Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.VmName -configToModify $configToModify -hidden:$hidden
    if ($remoteSQLVM.OtherNode) {
        Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.OtherNode -configToModify $configToModify -hidden:$hidden
    }
    if ($remoteSQLVM.fileServerVM) {
        Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.fileServerVM -configToModify $configToModify -hidden:$hidden
    }
}
function Add-ExistingVMsToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $config
    )

    #Update Cache
    get-list -type vm -SmartUpdate | out-null

    # Add exising DC to list
    if ($config.virtualMachines | Where-Object { $_.role -notin ("OSDClient") }) {
        $existingDC = $config.parameters.ExistingDCName
        if ($existingDC) {
            # create a dummy VM object for the existingDC
            Add-ExistingVMToDeployConfig -vmName $existingDC -configToModify $config
        }
    }

    # Add DCs from other domains, if needed
    $dc = $config.virtualMachines | Where-Object { $_.role -eq "DC" }

    if ($dc) {
        if ($null -ne $dc.ForestTrust -and $dc.ForestTrust -ne "NONE") {
            $OtherDC = get-list -Type vm -DomainName $dc.ForestTrust | Where-Object { $_.Role -eq "DC" }
            Add-ExistingVMToDeployConfig -vmName $OtherDC.vmName -configToModify $config -OtherDC:$true
            if ($null -ne $dc.externalDomainJoinSiteCode -and $dc.externalDomainJoinSiteCode -ne "NONE") {
                $RemoteSiteServer = Get-SiteServerForSiteCode -deployConfig $config -SiteCode $dc.externalDomainJoinSiteCode -DomainName $dc.ForestTrust -type VM
                Add-ExistingVMToDeployConfig -vmName $RemoteSiteServer.vmName -configToModify $config
            }

        }
    }

    # Add Primary to list, when adding SiteSystem, also add the current site server to the list.
    $systems = $config.virtualMachines | Where-Object { $_.role -eq "SiteSystem" }
    #$systems = $config.virtualMachines | Where-Object { $_.role -eq "SiteSystem" -and -not $_.Hidden }
    foreach ($system in $systems) {
        $systemSite = Get-PrimarySiteServerForSiteCode -deployConfig $config -siteCode $system.siteCode -type VM -SmartUpdate:$false
        if ($systemSite) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.vmName -configToModify $config
            if ($systemSite.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $systemSite.RemoteSQLVM -configToModify $config
            }
        }
        $systemSite = Get-SiteServerForSiteCode -deployConfig $config -siteCode $system.siteCode -type VM -SmartUpdate:$false
        if ($systemSite) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.vmName -configToModify $config
            if ($systemSite.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $systemSite.RemoteSQLVM -configToModify $config
            }
        }
        if ($systemSite.pullDPSourceDP) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.pullDPSourceDP -configToModify $config
        }
    }

    # Add Primary to list, when adding Secondary
    $Secondaries = $config.virtualMachines | Where-Object { $_.role -eq "Secondary" -and -not $_.Hidden }
    foreach ($Secondary in $Secondaries) {
        $primary = Get-SiteServerForSiteCode -deployConfig $config -sitecode $Secondary.parentSiteCode -type VM -SmartUpdate:$false
        if ($primary) {
            Add-ExistingVMToDeployConfig -vmName $primary.vmName -configToModify $config
            if ($primary.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $primary.RemoteSQLVM -configToModify $config
            }
        }
    }

    # Add Primary to list, when adding Passive
    $PassiveVMs = $config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and -not $_.Hidden }
    foreach ($PassiveVM in $PassiveVMs) {
        $ActiveNode = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PassiveVM.siteCode -SmartUpdate:$false
        if ($ActiveNode) {
            $ActiveNodeVM = Get-VMFromList2 -deployConfig $config -vmName $ActiveNode -SmartUpdate:$false
            if ($ActiveNodeVM) {
                if ($ActiveNodeVM.remoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $ActiveNodeVM.remoteSQLVM -configToModify $config
                }
                Add-ExistingVMToDeployConfig -vmName $ActiveNode -configToModify $config
            }
        }
    }

    # Add CAS to list, when adding primary
    $PriVMS = $config.virtualMachines | Where-Object { $_.role -eq "Primary" -and -not $_.Hidden }
    foreach ($PriVM in $PriVMS) {
        if ($PriVM.parentSiteCode) {
            $CAS = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PriVM.parentSiteCode -type VM -SmartUpdate:$false
            if ($CAS) {
                Add-ExistingVMToDeployConfig -vmName $CAS.vmName -configToModify $config
                if ($CAS.RemoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $CAS.RemoteSQLVM -configToModify $config
                }
            }
        }
    }


    # If any machine has a RemoteSQLVM, add it.  This will also add the OtherNode
    $vms = $config.virtualMachines
    foreach ($vm in $vms) {
        if ($vm.RemoteSQLVM) {
            Add-RemoteSQLVMToDeployConfig -vmName $vm.RemoteSQLVM -configToModify $config
        }
    }


    # Add FS to list, when adding SQLAO
    $SQLAOVMs = $config.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not $_.Hidden }
    foreach ($SQLAOVM in $SQLAOVMs) {
        if ($SQLAOVM.FileServerVM) {
            Add-ExistingVMToDeployConfig -vmName $SQLAOVM.FileServerVM -configToModify $config
        }
        if ($SQLAOVM.OtherNode) {
            Add-ExistingVMToDeployConfig -vmName $SQLAOVM.OtherNode -configToModify $config
        }
    }






    $wsus = $config.virtualMachines | Where-Object { $_.role -eq "WSUS" -and -not $_.Hidden }
    foreach ($sup in $wsus) {
        if ($sup.InstallSUP) {
            $ss = Get-SiteServerForSiteCode -deployConfig $config -sitecode $sup.siteCode -type VM -SmartUpdate:$false
            if ($ss) {
                Add-ExistingVMToDeployConfig -vmName $ss.vmName -configToModify $config
                if ($ss.RemoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $ss.RemoteSQLVM -configToModify $config
                }
            }
        }
    }
    # Check if any new VM's need remote SQL VM added
    $vms = $config.virtualMachines
    foreach ($vm in $vms) {
        if ($vm.RemoteSQLVM) {
            Add-RemoteSQLVMToDeployConfig -vmName $vm.RemoteSQLVM -configToModify $config
        }
    }
}

function Add-ModifiedExistingVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [object] $vm,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true
    )

    $vmName = $vm.vmName

    Write-Log -verbose "Adding Modified $($vmName) to Deploy config"
    if ($configToModify.virtualMachines.vmName -contains $vmName) {
        Write-Log "Not adding $vmName as it already exists in deployConfig" -LogOnly
        return
    }
    $existingVM = (get-list -Type VM | where-object { $_.vmName -eq $vmName })
    if (-not $existingVM) {
        Write-Log "Not adding $vmName as it does not exist as an existing VM" -LogOnly
        return
    }

    Write-Log -Verbose "Adding $vmName as a modified existing VM"
    if ($existingVM.state -ne "Running") {
        Start-VM2 -Name $existingVM.vmName
    }

    $newVMObject = [PSCustomObject]@{
        hidden = $hidden
    }

    $vmNote = $vm
    $propsToExclude = @(
        "LastKnownIP",
        "inProgress",
        "success",
        "deployedOS",
        "domain",
        "network",
        "prefix",
        "memLabsDeployVersion",
        "memLabsVersion",
        "adminName",
        "lastUpdate",
        "source",
        "vmID",
        "switch"
    )
    foreach ($prop in $vmNote.PSObject.Properties) {
        if ($prop.Name -in $propsToExclude) {
            continue
        }

        if ($prop.Name.EndsWith("-Original")) {
            continue
        }
        $newVMObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }

    if (-not $newVMObject.vmName) {
        throw "Could not add hidden VM, because it does not have a vmName property"
    }
    if ($null -eq $configToModify.virtualMachines) {
        $configToModify | Add-Member -MemberType NoteProperty -Name "virtualMachines" -Value @($newVMObject) -Force
    }
    else {
        $configToModify.virtualMachines += $newVMObject
    }
}

function Add-ExistingVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Is This a DC from another domain?")]
        [bool] $OtherDC = $false
    )

    Write-Log -verbose "Adding $vmName to Deploy config"
    if ($configToModify.virtualMachines.vmName -contains $vmName) {
        Write-Log "Not adding $vmName as it already exists in deployConfig" -LogOnly
        return
    }

    $existingVM = (get-list -Type VM | where-object { $_.vmName -eq $vmName })
    if (-not $existingVM) {
        Write-Log "Not adding $vmName as it does not exist as an existing VM" -LogOnly
        return
    }

    Write-Log -Verbose "Adding $vmName as an existing VM"
    if ($existingVM.state -ne "Running") {
        Start-VM2 -Name $existingVM.vmName
    }

    $newVMObject = [PSCustomObject]@{
        hidden = $hidden
    }

    $vmNote = Get-VMNote -VMName $vmName
    $propsToExclude = @(
        "LastKnownIP",
        "inProgress",
        "success",
        "deployedOS",
        #"domain",
        "network",
        "prefix",
        "memLabsDeployVersion",
        "memLabsVersion",
        "adminName",
        "lastUpdate"
    )
    foreach ($prop in $vmNote.PSObject.Properties) {
        if ($prop.Name -in $propsToExclude) {
            continue
        }
        $newVMObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }

    if (-not $newVMObject.vmName) {
        throw "Could not add hidden VM, because it does not have a vmName property"
    }
    if ($OtherDC) {
        $newVMObject.role = "OtherDC"
    }
    if ($null -eq $configToModify.virtualMachines) {
        $configToModify | Add-Member -MemberType NoteProperty -Name "virtualMachines" -Value @($newVMObject) -Force
    }
    else {
        $configToModify.virtualMachines += $newVMObject
    }
}

function Add-VMToAccountLists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Current Item")]
        [object] $thisVM,
        [Parameter(Mandatory = $true, HelpMessage = "VMToAdd")]
        [object] $VM,
        [Parameter(Mandatory = $true, HelpMessage = "Account Lists")]
        [object] $accountLists,
        [Parameter(Mandatory = $true, HelpMessage = "Deploy Config")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SQLSysAdminAccounts")]
        [switch] $SQLSysAdminAccounts,
        [Parameter(Mandatory = $false, HelpMessage = "LocalAdminAccounts")]
        [switch]$LocalAdminAccounts,
        [Parameter(Mandatory = $false, HelpMessage = "WaitOnDomainJoin")]
        [switch] $WaitOnDomainJoin

    )

    if (($thisVM.vmName).Count -gt 1 -or (($thisVM.vmName).ToCharArray() -contains ' ')) {
        Write-Log "$(thisVM.vmName) contains invalid data"
        return
    }

    foreach ($vmToAdd in $VM) {
        if ($thisVM.vmName -eq $vmToAdd.vmName) {
            continue
        }

        $DomainName = $deployConfig.vmOptions.domainName
        #$DName = $DomainName.Split(".")[0]

        $DName = $deployConfig.vmOptions.domainNetBiosName
        if ($SQLSysAdminAccounts) {
            $accountLists.SQLSysAdminAccounts += "$DNAME\$($vmToAdd.vmName)$"
        }
        if ($LocalAdminAccounts) {
            $accountLists.LocalAdminAccounts += "$($vmToAdd.vmName)$"
        }
        if ($WaitOnDomainJoin) {
            if (-not $vmToAdd.hidden) {
                $accountLists.WaitOnDomainJoin += $vmToAdd.vmName
            }
        }
    }
}


function Get-SQLAOConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config to Modify")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SQLAONAME")]
        [object] $vmName
    )
    Write-Log "Running Get-SQLAOConfig for $vmName" -LogOnly
    $PrimaryAO = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }

    if (-not $PrimaryAO) {
        Write-Log -Failure "Could not find Primary SQLAO VM $vmName"
        return $null
    }
    if (-not ($PrimaryAO.OtherNode)) {
        #ignore this.. We run this on all SQLAO nodes,and dont care about 2ndary
        return $null
    }

    $SecondAO = $PrimaryAO.OtherNode
    $FSAO = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "FileServer" -and $_.vmName -eq $PrimaryAO.FileServerVM }
    #$DC = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "DC" }

    $ClusterName = $PrimaryAO.ClusterName
    $ClusterNameNoPrefix = $ClusterName.Replace($deployConfig.vmOptions.prefix, "")

    $ServiceAccount = $PrimaryAO.SqlServiceAccount
    $AgentAccount = $PrimaryAO.SqlAgentAccount

    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
    $cnUsersName = "CN=Users,DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"
    $cnComputersName = "CN=Computers,DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"
    #$netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $netbiosName = $deployConfig.vmOptions.domainNetBiosName
    if (-not ($PrimaryAO.ClusterIPAddress)) {
        $vm = Get-List -SmartUpdate -Type VM | where-object { $_.vmName -eq $PrimaryAO.vmName }
        if ($vm.ClusterIPAddress) {
            write-log "Setting Cluster IP from vmNotes" -verbose
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "ClusterIPAddress" -Value $vm.ClusterIPAddress -Force
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "AGIPAddress" -Value $vm.AGIPAddress -Force
        }
        else {
            write-log "Cluster IP not found in VMNotes" -verbose

        }
    }
    if (-not ($PrimaryAO.ClusterIPAddress)) {
        write-log "Cluster IP is not yet set. Skipping SQLAO Config for $vmName" -LogOnly
        return
        #throw "Primary SQLAO $($PrimaryAO.vmName) does not have a ClusterIP assigned."
    }

    $config = [PSCustomObject]@{
        GroupName                  = $ClusterName + "Group"
        GroupMembers               = @("$($PrimaryAO.vmName)$", "$($SecondAO)$", "$($ClusterName)$")
        GroupMembersFQ             = @("$($netbiosName + "\" + $PrimaryAO.vmName)$", "$($netbiosName + "\" + $SecondAO)$", "$($netbiosName + "\" + $ClusterName)$")
        SqlServiceAccount          = $ServiceAccount
        SqlServiceAccountFQ        = $netbiosName + "\" + $ServiceAccount
        SqlAgentServiceAccount     = $AgentAccount
        SqlAgentServiceAccountFQ   = $netbiosName + "\" + $AgentAccount
        OULocationUser             = $cnUsersName
        OULocationDevice           = $cnComputersName
        ClusterNodes               = @($PrimaryAO.vmName, $SecondAO)
        WitnessLocalPath           = "F:\$($ClusterNameNoPrefix)-Witness"
        BackupLocalPath            = "F:\$($ClusterNameNoPrefix)-Backup"
        AlwaysOnGroupName          = $PrimaryAO.AlwaysOnGroupName
        PrimaryNodeName            = $PrimaryAO.vmName
        SecondaryNodeName          = $SecondAO
        FileServerName             = $FSAO.vmName
        ClusterIPAddress           = $PrimaryAO.ClusterIPAddress + "/24"
        AGIPAddress                = $PrimaryAO.AGIPAddress + "/255.255.255.0"
        PrimaryReplicaServerName   = $PrimaryAO.vmName + "." + $deployConfig.vmOptions.DomainName
        SecondaryReplicaServerName = $PrimaryAO.OtherNode + "." + $deployConfig.vmOptions.DomainName
        AlwaysOnListenerName       = $PrimaryAO.AlwaysOnListenerName
        AlwaysOnListenerNameFQDN   = $PrimaryAO.AlwaysOnListenerName + "." + $deployConfig.vmOptions.DomainName
        WitnessShareFQ             = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Witness"
        BackupShareFQ              = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Backup"
        WitnessShare               = "$($ClusterNameNoPrefix)-Witness"
        BackupShare                = "$($ClusterNameNoPrefix)-Backup"
        SQLAOPort                  = 1500
    }

    Write-Log "SQLAO Config Generated for $vmName" -LogOnly
    return $config
}

function Get-ValidCASSiteCodes {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [String]$Domain
    )

    $existingSiteCodes = @()
    $existingSiteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object -ExpandProperty SiteCode

    if ($Config) {
        $containsCS = $Config.virtualMachines.role -contains "CAS"
        if ($containsCS) {
            $CSVM = $Config.virtualMachines | Where-Object { $_.role -eq "CAS" }
            $existingSiteCodes += $CSVM.siteCode
        }
    }

    return ($existingSiteCodes | Select-Object -Unique)
}

function Get-ValidPRISiteCodes {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [String]$Domain
    )

    $existingSiteCodes = @()
    $existingSiteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object -ExpandProperty SiteCode

    if ($Config) {
        $containsPS = $Config.virtualMachines.role -contains "Primary"
        if ($containsPS) {
            $PSVM = $Config.virtualMachines | Where-Object { $_.role -eq "Primary" }
            # We dont support multiple subnets per config yet
            $existingSiteCodes += $PSVM.siteCode
        }
    }

    return ($existingSiteCodes | Select-Object -Unique)
}

function Get-ExistingForDomain {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "SiteSystem", "DomainMember", "Secondary")]
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
        Write-Log "Failed to get existing $Role from $DomainName. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-ExistingSiteServer {
    param(
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [ValidateSet("CAS", "Primary", "Secondary")]
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
            if ($vm.role -in "CAS", "Primary", "Secondary") {
                if ($PSBoundParameters.ContainsKey("SiteCode") -and $vm.siteCode.ToLowerInvariant() -eq $SiteCode.ToLowerInvariant()) {

                    $so = [PSCustomObject]@{
                        VmName   = $vm.VmName
                        Role     = $vm.Role
                        SiteCode = $vm.siteCode
                        Domain   = $vm.domain
                        State    = $vm.State
                        Network  = $vm.Network
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
                        Network  = $vm.Network
                    }
                    $existingValue += $so
                }
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Failed to get existing site servers. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-ExistingForNetwork {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Network")]
        [string]$Network,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "SiteSystem", "DomainMember", "Secondary")]
        [string]$Role,
        [Parameter(Mandatory = $false, HelpMessage = "VMName to exclude")]
        [string] $exclude = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Config To Check")]
        [object] $config
    )

    try {

        $existingValue = @()
        if ($config) {
            $vmList = Get-List2 -DeployConfig $config | Where-Object { $_.network -eq $Network }
        }
        else {
            $vmList = Get-List -Type VM | Where-Object { $_.network -eq $Network }
        }
        foreach ($vm in $vmList) {
            if ($exclude -and $vm.VmName -eq $exclude) {
                continue
            }
            if ($vm.role) {
                if ($vm.Role.ToLowerInvariant() -eq $Role.ToLowerInvariant()) {
                    $existingValue += $vm.VmName
                }
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Failed to get existing $Role from $Subnet. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-SiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName

    )
    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    if ($DomainName) {
        $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) })
        if ($vmList) {
            if ($type -eq "Name") {
                return ($vmList | Select-Object -First 1).vmName
            }
            else {
                return $vmList | Select-Object -First 1
            }
        }
        return
    }


    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return $configVMs | Select-Object -First 1
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return $existingVMs | Select-Object -First 1
        }
    }
    throw "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $DomainName"
    return $null
}


function Get-SqlServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName

    )
    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }


    if ($DomainName) {
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -DomainName $DomainName -type VM
    }
    else {
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -type VM
    }
    if ($SiteServer.RemoteSQLVM) {
        if ($type -eq "Name") {
            Return $SiteServer.RemoteSQLVM
        }
        else {
            if ($DomainName) {
                $remoteSQL = get-list -type VM -domain $DomainName | Where-Object { $_.VmName -eq $SiteServer.RemoteSQLVM }
            }
            else {
                $remoteSQL = $deployConfig.virtualMachines | Where-Object { $_.VmName -eq $SiteServer.RemoteSQLVM }
            }
            if ($type -eq "Name") {
                return $remoteSQL.vmName
            }
            else {
                return $remoteSQL
            }
        }
    }

    if ($type -eq "Name") {
        return $SiteServer.vmName
    }
    else {
        return $SiteServer
    }
}

function get-RoleForSitecode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Sitecode")]
        [string] $siteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToCheck = $global:config
    )

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    $configVMs = @()
    $configVMs += $configToCheck.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs.Count -eq 1) {
        return ($configVMs | Select-Object -First 1).Role
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $ConfigToCheck.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs.Count -eq 1) {
        return ($existingVMs | Select-Object -First 1).Role
    }
    return $null
}

function Get-VMFromList2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [object] $vmName,
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Get VMs from all domains")]
        [bool] $Global = $false
    )

    $vm = Get-List2 -DeployConfig $deployConfig -SmartUpdate:$SmartUpdate | Where-Object { $_.vmName -eq $vmName }
    if ($vm) {
        return $vm
    }
    else {
        if ($Global) {
            $vm = Get-List -Type VM | Where-Object { $_.vmName -eq $vmName }
            if ($vm) {
                return $vm
            }
        }
    }
}

function Get-PrimarySiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -SmartUpdate:$SmartUpdate
    if (-not $SiteServer) {
        throw "Could not find SiteServer for SiteCode: $SiteCode"
    }
    $roleforSite = get-RoleForSitecode -ConfigToCheck $deployConfig -siteCode $SiteCode
    if ($roleforSite -eq "Primary") {
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -type VM -SmartUpdate:$false
        }
    }
    if ($roleforSite -eq "Secondary") {
        $SiteServerVM = Get-VMFromList2 -deployConfig $deployConfig -vmName $SiteServer -SmartUpdate:$false
        if (-not $SiteServer) {
            write-host $SiteServerVM | ConvertTo-Json
            throw "Could not find VM $SiteServer"
        }
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteServerVM.parentSiteCode  -SmartUpdate:$false
        if (-not $SiteServer) {
            write-host $SiteServerVM | ConvertTo-Json
            throw "Secondary: Could not find SiteServer for SiteCode: $($SiteServerVM.parentSiteCode)"
        }
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-VMFromList2 -deployConfig $deployConfig -vmName $SiteServer  -SmartUpdate:$false
        }
    }
}

function Get-PassiveSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServerRoles = @("PassiveSite")
    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return ($configVMs | Select-Object -First 1)
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return ($existingVMs | Select-Object -First 1)
        }
    }
    return $null
}

function Get-ActiveSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServerRoles = @("Primary", "CAS")
    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return ($configVMs | Select-Object -First 1)
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return ($existingVMs | Select-Object -First 1)
        }
    }
    return $null
}

function Get-NetworkList {

    param(
        [Parameter(Mandatory = $false)]
        [string] $DomainName
    )
    try {

        if ($DomainName) {
            return (Get-List -Type Network -DomainName $DomainName)
        }

        return (Get-List -Type Network)

    }
    catch {
        Write-Log "Failed to get network list. $_" -Failure -LogOnly
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-DomainList {

    try {
        return (Get-List -Type UniqueDomain)
    }
    catch {
        Write-Log "Failed to get domain list. $_" -Failure -LogOnly
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-VMSizeCached {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VM Object")]
        [object] $vm,
        [Parameter(Mandatory = $false, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )

    $jsonFile = $($vm.vmID).toString() + ".disk.json"
    $cacheFile = Join-Path $global:common.CachePath $jsonFile
    Write-Log -hostonly "Cache File $cacheFile" -Verbose
    $vmCacheEntry = $null
    if (Test-Path $cacheFile) {
        try {
            $vmCacheEntry = Get-Content $cacheFile | ConvertFrom-Json
        }
        catch {}
    }


    if ($vmCacheEntry) {
        if (Test-CacheValid -EntryTime $vmCacheEntry.EntryAdded -MaxHours 24) {
            if ($vmCacheEntry.diskSize -and $vmCacheEntry.diskSize -gt 0) {
                return $vmCacheEntry
            }
        }
    }


    #write-host "Making new Entry for $($vm.vmName)"
    # if we didnt return the cache entry, get new data, and add it to cache
    $diskSize = (Get-ChildItem $vm.Path -Recurse | Measure-Object length -sum).sum
    $MemoryStartup = $vm.MemoryStartup
    $vmCacheEntry = [PSCustomObject]@{
        vmId          = $vm.vmID
        diskSize      = $diskSize
        MemoryStartup = $MemoryStartup
        EntryAdded    = (Get-Date -format "MM/dd/yyyy HH:mm")
    }
    ConvertTo-Json  $vmCacheEntry | Out-File $cacheFile -Force
    return $vmCacheEntry
}

$global:vmNetCache = $null
function Get-VMNetworkCached {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VM Object")]
        [object] $vm,
        [Parameter(Mandatory = $false, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )
    $jsonFile = $($vm.vmID).toString() + ".network.json"
    $cacheFile = Join-Path $global:common.CachePath $jsonFile

    $vmCacheEntry = $null
    if (Test-Path $cacheFile) {
        try {
            $vmCacheEntry = Get-Content $cacheFile | ConvertFrom-Json
        }
        catch {}
    }


    if ($vmCacheEntry) {
        if (Test-CacheValid -EntryTime $vmCacheEntry.EntryAdded -MaxHours 24) {
            return $vmCacheEntry
        }
    }


    # if we didnt return the cache entry, get new data, and add it to cache
    $vmNet = ($vm | Get-VMNetworkAdapter)
    $vmCacheEntry = [PSCustomObject]@{
        vmId       = $vm.vmID
        SwitchName = $vmNet.SwitchName
        #IPAddresses = $vmNet.IPAddresses
        EntryAdded = (Get-Date -format "MM/dd/yyyy HH:mm")
    }

    if ($vmNet.SwitchName) {
        ConvertTo-Json $vmCacheEntry | Out-File $cacheFile -Force
    }
    return $vmCacheEntry
}

function Test-CacheValid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $EntryTime,
        [Parameter(Mandatory = $true)]
        [int] $MaxHours
    )
    $LastUpdateTime = [Datetime]::ParseExact($EntryTime, 'MM/dd/yyyy HH:mm', $null)
    $datediff = New-TimeSpan -Start $LastUpdateTime -End (Get-Date)
    if ($datediff.Hours -lt $MaxHours) {
        return $true
    }
    return $false
}

function Update-VMInformation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm
    )

    try {
        if ($vm.Notes) {
            $vmNoteObject = $vm.Notes | convertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Could not convert notes $($vm.Notes) from vm $($vm.Name)" -LogOnly -Failure
        return
    }

    $vmname = $vm.Name
    Write-Log -Verbose -HostOnly "Updating $vmname"
    # Update LastKnownIP, and timestamp
    if (-not [string]::IsNullOrWhiteSpace($vmNoteObject)) {
        $LastUpdateTime = [Datetime]::ParseExact($vmNoteObject.LastUpdate, 'MM/dd/yyyy HH:mm', $null)
        $datediff = New-TimeSpan -Start $LastUpdateTime -End (Get-Date)
        if (($datediff.Hours -gt 12) -or $null -eq $vmNoteObject.LastKnownIP) {
            $IPAddress = ($vm | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($IPAddress) -and $IPAddress -ne $vmNoteObject.LastKnownIP) {
                if ($null -eq $vmNoteObject.LastKnownIP) {
                    $vmNoteObject | Add-Member -MemberType NoteProperty -Name "LastKnownIP" -Value $IPAddress
                }
                else {
                    $vmNoteObject.LastKnownIP = $IPAddress
                }
                Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
            }
            else {
                #Update the Notes LastUpdateTime everytime we scan for it
                if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
                    Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
                }
            }
        }

        $vmDomain = $vmNoteObject.domain
        # Detect if we need to update VM VMName, if VM Note doesn't have vmName prop

        if (-not $vmNoteObject.vmName) {
            $vmNoteObject | Add-Member -MemberType NoteProperty -Name "vmName" -Value $vm.Name
            Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
        }

        # Detect if we need to update VM Note, if VM Note doesn't have siteCode prop
        if ($vmNoteObject.role -in "CAS", "Primary", "PassiveSite") {
            if ($null -eq $vmNoteObject.siteCode -or $vmNoteObject.siteCode.ToString().Length -ne 3) {
                if ($vmState -eq "Running" -and (-not $inProgress)) {
                    try {
                        $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\Identification -Name "Site Code" } -SuppressLog
                        $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        $vmNoteObject | Add-Member -MemberType NoteProperty -Name "siteCode" -Value $siteCode.ToString() -Force
                        Write-Log "Site code for $vmName is missing in VM Note. Adding siteCode $siteCode." -LogOnly
                        Set-VMNote -vmName $vmName -vmNote $vmNoteObject
                    }
                    catch {
                        Write-Log "Failed to obtain siteCode from registry from $vmName" -Warning -LogOnly
                        Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    }
                }
                else {
                    Write-Log "Site code for $vmName is missing in VM Note, but VM is not runnning [$vmState] or deployment is in progress [$inProgress]." -LogOnly
                }
            }
        }

        # Detect if we need to update VM Note, if VM Note doesn't have siteCode prop
        if ($vmNoteObject.installDP -or $vmNoteObject.enablePullDP) {
            if ($vmNoteObject.role -eq "DPMP") {
                # Rename Role to SiteSystem
                $vmNoteObject.role = "SiteSystem"
                Set-VMNote -vmName $vmName -vmNote $vmNoteObject
            }

            if ($null -eq $vmNoteObject.siteCode -or $vmNoteObject.siteCode.ToString().Length -ne 3) {
                if ($vmState -eq "Running" -and (-not $inProgress)) {
                    try {
                        $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\DP -Name "Site Code" } -SuppressLog
                        $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        if (-not $siteCode) {
                            $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\Identification -Name "Site Code" } -SuppressLog
                            $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        }
                        if ($siteCode) {
                            $vmNoteObject | Add-Member -MemberType NoteProperty -Name "siteCode" -Value $siteCode.ToString() -Force
                            Write-Log "Site code for $vmName is missing in VM Note. Adding siteCode $siteCode after reading from registry." -LogOnly
                            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
                        }
                    }
                    catch {
                        Write-Log "Failed to obtain siteCode from registry from $vmName" -Warning -LogOnly
                        Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    }
                }
                else {
                    Write-Log "Site code for $vmName is missing in VM Note, but VM is not runnning [$vmState] or deployment is in progress [$inProgress]." -LogOnly
                }
            }
        }

        # Rename WSUS role to SiteSystem, if SUP
        if ($vmNoteObject.role -eq "WSUS" -and $vmNoteObject.installSUP -eq $true) {
            $vmNoteObject.role = "SiteSystem"
            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
        }

        # Remove installSUP prop if WSUS role, but not SUP
        if ($vmNoteObject.role -eq "WSUS" -and ($null -eq $vmNoteObject.installSUP -or $vmNoteObject.installSUP -eq $false)) {
            $vmNoteObject.PsObject.properties.Remove('installSUP')
            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
        }
    }
}



function Get-VMFromHyperV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm
    )

    #$diskSize = (Get-VHD -VMId $vm.ID | Measure-Object -Sum FileSize).Sum
    $sizeCache = Get-VMSizeCached -vm $vm
    $memoryStartupGB = $sizeCache.MemoryStartup / 1GB
    $diskSizeGB = $sizeCache.diskSize / 1GB

    if (-not $memoryStartupGB) {
        $memoryStartupGB = 0
    }

    if (-not $diskSizeGB) {
        $diskSizeGB = 0
    }

    $memoryGB = $vm.MemoryAssigned / 1GB

    if (-not $memoryGB) {
        $memoryGB = 0
    }
    $vmNet = Get-VMNetworkCached -vm $vm

    #VmState is now updated  in Update-VMFromHyperV
    #$vmState = $vm.State.ToString()

    $vmObject = [PSCustomObject]@{
        vmName          = $vm.Name
        vmId            = $vm.Id
        switch          = $vmNet.SwitchName
        memoryGB        = $memoryGB
        memoryStartupGB = $memoryStartupGB
        diskUsedGB      = [math]::Round($diskSizeGB, 2)
    }

    Update-VMFromHyperV -vm $vm -vmObject $vmObject -vmNoteObject $vmNoteObject
    return $vmObject
}

function Update-VMFromHyperV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm,
        [Parameter(Mandatory = $false)]
        [object] $vmObject,
        [Parameter(Mandatory = $false)]
        [object] $vmNoteObject
    )
    if (-not $vmNoteObject) {
        try {
            if ($vm.Notes) {
                $vmNoteObject = $vm.Notes | convertFrom-Json -ErrorAction Stop
                #write-log -verbose $vmNoteObject
            }
        }
        catch {
            Write-Log -LogOnly -Failure "Could not convert Notes Object on $($vm.Name) $vmNoteObject"
        }
    }

    if ($vmNoteObject) {
        if ([String]::isnullorwhitespace($vmNoteObject.role)) {
            # If we dont have a vmName property, this is not one of our VM's
            $vmNoteObject = $null
        }
    }
    if (-not $vmObject) {
        $vmObject = $global:vm_List | Where-Object { $_.vmId -eq $vm.vmID }
    }
    if ($vmNoteObject) {
        $vmState = $vm.State.ToString()
        $adminUser = $vmNoteObject.adminName
        $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }

        $vmObject | Add-Member -MemberType NoteProperty -Name "adminName" -Value $adminUser -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "inProgress" -Value $inProgress -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "state" -Value $vmState -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "vmBuild" -Value $true -Force

        foreach ($prop in $vmNoteObject.PSObject.Properties) {
            $value = if ($prop.Value -is [string]) { $prop.Value.Trim() } else { $prop.Value }
            switch ($prop.Name) {
                "deployedOS" {
                    $vmObject | Add-Member -MemberType NoteProperty -Name "OperatingSystem" -Value $value -Force
                    $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
                }
                "sqlInstanceName" {
                    if (-not $vmObject.sqlPort) {
                        if ($vmObject.sqlInstanceName -eq "MSSQLSERVER") {
                            $vmObject | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 1433 -Force
                        }
                        else {
                            $vmObject | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 2433 -Force
                        }
                    }
                }
                default {
                    $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
                }
            }
        }
    }
    else {
        $vmObject | Add-Member -MemberType NoteProperty -Name "vmBuild" -Value $false -Force
    }

    if ($vmObject.Role -eq "DPMP") {
        $vmObject.Role = "SiteSystem"
    }

    #add missing Properties
    if ($vmObject.Role -in "SiteSystem", "CAS", "Primary") {
        if ($null -eq $vmObject.InstallRP) {
            $vmObject | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
        }
        if ($null -eq $vmObject.InstallSUP) {
            $vmObject | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $false -Force
        }
        if ($vmObject.Role -eq "SiteSystem") {
            if ($null -eq $vmObject.InstallMP) {
                $vmObject | Add-Member -MemberType NoteProperty -Name "InstallMP" -Value $false -Force
            }
            if ($null -eq $vmObject.InstallDP) {
                $vmObject | Add-Member -MemberType NoteProperty -Name "InstallDP" -Value $false -Force
            }
        }
    }

    if ($vmObject.SqlVersion) {
        foreach ($listVM in $global:vm_List) {
            if ($listVM.RemoteSQLVM -eq $vmObject.VmName) {
                if ($null -eq $vmObject.InstallRP) {
                    $vmObject | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
                }
            }
        }
    }

}

$global:vm_List = $null
function Get-List {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "Type")]
        [ValidateSet("VM", "Switch", "Prefix", "UniqueDomain", "UniqueSwitch", "UniquePrefix", "Network", "UniqueNetwork", "ForestTrust")]
        [string] $Type,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [string] $DomainName,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [switch] $ResetCache,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [switch] $SmartUpdate,
        [Parameter(Mandatory = $true, ParameterSetName = "FlushCache")]
        [switch] $FlushCache,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [object] $DeployConfig
    )

    $doSmartUpdate = $SmartUpdate.IsPresent
    $inMutex = $false
    $return = $null
    #Get-PSCallStack | out-host
    if ($global:DisableSmartUpdate -eq $true) {
        $doSmartUpdate = $false
    }
    else {
        $mutexName = "GetList" + $pid
        $mtx = New-Object System.Threading.Mutex($false, $mutexName)
        #write-log "Attempting to acquire '$mutexName' Mutex" -LogOnly -Verbose
        [void]$mtx.WaitOne()
        $inMutex = $true
        #write-log "acquired '$mutexName' Mutex" -LogOnly -Verbose
    }
    try {

        if ($FlushCache.IsPresent) {
            $global:vm_List = $null
            return
        }

        if ($DeployConfig) {
            try {
                $DepoloyConfigJson = $DeployConfig | ConvertTo-Json -Depth 5
                $DeployConfigClone = $DepoloyConfigJson | ConvertFrom-Json
            }
            catch {
                write-log "Failed to convert DeployConfig: $DeployConfig" -Failure
                write-log "Failed to convert DeployConfig: $DepoloyConfigJson" -Failure
                Write-Log "$($_.ScriptStackTrace)" -LogOnly
            }

        }
        if ($ResetCache.IsPresent) {
            $global:vm_List = $null
        }

        if ($doSmartUpdate) {
            if ($global:vm_List) {
                try {
                    $virtualMachines = Get-VM
                    foreach ( $oldListVM in $global:vm_List) {
                        if ($DomainName) {
                            if ($oldListVM.domain -ne $DomainName) {
                                continue
                            }
                        }
                        #Remove Missing VM's
                        if (-not ($virtualMachines.vmId -contains $oldListVM.vmID)) {
                            #write-host "removing $($oldListVM.vmID)"
                            $global:vm_List = $global:vm_List | Where-Object { $_.vmID -ne $oldListVM.vmID }
                        }
                    }
                    foreach ($vm in $virtualMachines) {
                        #if its missing, do a full add
                        $vmFromGlobal = $global:vm_List | Where-Object { $_.vmId -eq $vm.vmID }
                        if ($null -eq $vmFromGlobal) {
                            #    if (-not $global:vm_List.vmID -contains $vmID){
                            #write-host "adding missing vm $($vm.vmName)"
                            $vmObject = Get-VMFromHyperV -vm $vm
                            $global:vm_List += $vmObject
                        }
                        else {
                            if ($DomainName) {
                                if ($vmFromGlobal.domain -ne $DomainName) {
                                    continue
                                }
                            }
                            #else, update the existing entry.
                            Update-VMFromHyperV -vm $vm -vmObject $vmFromGlobal
                        }
                    }
                }
                finally {
                }
            }
        }

        if (-not $global:vm_List -and $inMutex) {

            try {
                #This may have been populated while waiting for mutex
                if (-not $global:vm_List) {
                    Write-Log "Obtaining '$Type' list and caching it." -Verbose
                    $return = @()
                    $virtualMachines = Get-VM
                    foreach ($vm in $virtualMachines) {

                        $vmObject = Get-VMFromHyperV -vm $vm

                        $return += $vmObject
                    }

                    $global:vm_List = $return
                }
            }
            finally {

            }

        }
        $return = $global:vm_List

        foreach ($vm in $return) {
            $vm | Add-Member -MemberType NoteProperty -Name "source" -Value "hyperv" -Force
        }
        if ($null -ne $DeployConfigClone) {

            $domain = $DeployConfigClone.vmoptions.domainName
            $network = $DeployConfigClone.vmoptions.network

            $prefix = $DeployConfigClone.vmoptions.prefix
            foreach ($vm in $DeployConfigClone.virtualMachines) {
                $found = $false
                if ($vm.hidden) {
                    continue
                }
                if ($vm.network) {
                    $network = $vm.network
                }
                else {
                    $network = $DeployConfigClone.vmoptions.network
                }
                foreach ($vm2 in $return) {
                    if ($vm2.vmName -eq $vm.vmName) {
                        $vm2.source = "config"
                        $found = $true
                    }
                }
                if ($found) {
                    $return = $return | where-object { $_.vmName -ne $vm.vmName }
                }
                $newVM = $vm
                $newVM | Add-Member -MemberType NoteProperty -Name "network" -Value $network -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "Domain" -Value $domain -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "prefix" -Value $prefix -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "source" -Value "config" -Force
                $return += $newVM
            }
        }
        if ($DomainName) {
            $return = $return | Where-Object { $_.domain -and ($_.domain.ToLowerInvariant() -eq $DomainName.ToLowerInvariant()) }
        }

        $return = $return | Sort-Object -Property * #-Unique

        if ($Type -eq "VM") {
            return $return
        }

        # Include Internet subnets, filtering them out as-needed in Common.Remove
        if ($Type -eq "Switch") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property 'Switch', Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "Network") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Network, Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "Prefix") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Prefix, Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "UniqueDomain") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Domain -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "ForestTrust") {

            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Where-Object { $_.ForestTrust -ne "NONE" -and $_.ForestTrust } | Select-Object -Property @("ForestTrust", "Domain") -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniqueSwitch") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty 'Switch' -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniqueNetwork") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Network -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniquePrefix") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Prefix -Unique -ErrorAction SilentlyContinue
        }

    }
    catch {
        Write-Log "Failed to get '$Type' list. $_" -Failure -LogOnly
        write-Log "Trace $($_.ScriptStackTrace)" -Failure -LogOnly
        return $null
    }
    finally {
        if ($mtx) {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
            $mtx = $null
        }
    }
}

function Get-List2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "List")]
        [object] $DeployConfig,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $AllDomains,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $ResetCache,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $SmartUpdate,
        [Parameter(Mandatory = $true, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )

    if ($FlushCache.IsPresent) {
        Get-List -FlushCache
        return
    }

    $return = @()

    if ($AllDomains.IsPresent) {
        $return = Get-List -Type VM -DeployConfig $DeployConfig -ResetCache:$ResetCache -SmartUpdate:$SmartUpdate
    }
    else {
        $return = Get-List -Type VM -DomainName $DeployConfig.vmOptions.domainName -DeployConfig $DeployConfig -ResetCache:$ResetCache -SmartUpdate:$SmartUpdate
    }

    return ($return | Sort-Object -Property source)
}

function Test-InProgress {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $DeployConfig
    )

    $InProgessVMs = @()
    foreach ($thisVM in $deployConfig.virtualMachines) {
        $thisVMObject = Get-VMFromList2 -deployConfig $deployConfig -vmName $thisVM.vmName
        if ($thisVMObject.inProgress -eq $true) {
            $InProgessVMs += $thisVMObject.vmName
        }
    }

    if ($InProgessVMs.Count -gt 0) {
        Write-Host
        write-host2 -ForegroundColor Blue "*************************************************************************************************************************************"
        write-host2 -ForegroundColor Red "ERROR: Virtual Machiness: [ $($InProgessVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE."
        write-log "ERROR: Virtual Machiness: [ $($InProgessVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE." -LogOnly
        write-host
        write-host2 -ForegroundColor Snow "The Previous deployment may be in progress, or may have failed. Please wait for existing deployments to finish, or delete these in-progress VMs"
        write-host2 -ForegroundColor Blue "*************************************************************************************************************************************"
        return $true
    }

    return $false

}

Function Write-ColorizedBrackets {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [string] $BracketColor = $Global:Common.Colors.GenConfigBrackets
    )
    while (-not [string]::IsNullOrWhiteSpace($text)) {
        #write-host $text
        $indexLeft = $text.IndexOf('[')
        $indexRight = $text.IndexOf(']')
        if ($indexRight -eq -1 -and $indexLeft -eq -1) {
            Write-Host2 -ForegroundColor $ForegroundColor "$text" -NoNewline
            break
        }
        else {

            if ($indexRight -eq -1) {
                $indexRight = 100000000
            }
            if ($indexLeft -eq -1) {
                $indexLeft = 10000000
            }

            if ($indexRight -lt $indexLeft) {
                $text2Display = $text.Substring(0, $indexRight)
                Write-Host2 -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                Write-Host2 -ForegroundColor $BracketColor "]" -NoNewline
                $text = $text.Substring($indexRight)
                $text = $text.Substring(1)
            }
            if ($indexLeft -lt $indexRight) {
                $text2Display = $text.Substring(0, $indexLeft)
                Write-Host2 -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                Write-Host2 -ForegroundColor $BracketColor "[" -NoNewline
                $text = $text.Substring($indexLeft)
                $text = $text.Substring(1)
            }
        }

    }
}
Function Write-GreenCheck {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [string] $ForegroundColor
    )
    $CHECKMARK = ([char]8730)
    $text = $text.Replace("SUCCESS: ", "")
    if (-not $NoIndent) {
        Write-Host "  " -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor LimeGreen "$CHECKMARK" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text

    }
    #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline

    else {
        Write-Host $text -NoNewline
    }
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
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [string] $ForegroundColor
    )
    $text = $text.Replace("ERROR: ", "")
    if (-not $NoIndent) {
        Write-Host "  " -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor Red "x" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text

    }
    #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline

    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
}

Function Write-WhiteI {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor
    )
    $text = $text.Replace("Info: ", "")
    if (-not $NoIndent) {
        Write-Host "  " -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor White "i" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Warning -LogOnly
    }
}

Function Write-OrangePoint {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor
    )
    $text = $text.Replace("WARNING: ", "")
    if (-not $NoIndent) {
        Write-Host "  " -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor Orange "⚠ " -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Warning -LogOnly
    }
}


function Convert-vmNotesToOldFormat {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $vmName
    )

    $newNote = [PSCustomObject]@{}

    $propsToInclude = @("success", "role", "deployedOS", "domain", "adminName", "network", "prefix", "siteCode", "parentSiteCode", "cmInstallDir", "sqlVersion" , "sqlInstanceName", "sqlInstanceDir", "lastupdate" )
    $currentNotes = (Get-vm -VMName $vmName).Notes
    Write-Host "`nOld Notes:`n$currentNotes`n"
    $props = ($currentNotes | Convertfrom-json).psobject.members | Where-Object { $_.Name -in $propsToInclude }
    foreach ($prop in $props) {
        switch ($prop.Name) {
            "operatingSystem" {
                $newNote | Add-Member -MemberType NoteProperty -Name "deployedOS" -Value $prop.Value -Force
            }
            default {
                $newNote | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
            }
        }
    }

    $newJson = ($newNote | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
    Write-Host "`nNew Notes:`n$newJson`n"
    Set-VM -Name $vmName -Notes $newJson

}

Function Get-LinuxImages {
    $linuxJson = Join-Path $Global:Common.TempPath "LinuxHyperVGallery.json"

    if (Test-Path $linuxJson -PathType Leaf) {
        #Get a new copy if the existing one is over 5 hours old
        if (Get-Childitem $linuxJson  | Where-Object { $_.LastWriteTime -lt (get-date).AddHours(-5) }) {
            & curl -s -L $($Common.AzureFileList.Urls.Linux) -o $linuxJson
        }
    }
    else {
        # Get a copy if the file doesnt exist
        & curl -s -L $($Common.AzureFileList.Urls.Linux) -o $linuxJson
    }
    $linux = Get-Content $linuxJson | convertfrom-json
    return ($linux.images | Where-Object { $_.config.secureboot -ne $true })
}

Function Download-LinuxImage {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $name
    )

    $linux = Get-LinuxImages

    $image = ($linux | Where-Object { $_.name -eq $name })
    #Download the file is hash does not match

    $fileZip = $("os\" + $image.name + ".zip")
    $fileVHDX = $($image.name + ".vhdx")

    #This is where Get-FileWithHash puts the resulting file
    $fullfileZip = Join-Path $Global:Common.AzureFilesPath $fileZip

    #This is where the VHDX is going to end up
    $fullfileVHDX = Join-Path $Global:Common.AzureImagePath $fileVHDX

    $url = $image.disk.uri

    $hashAlg = $($image.disk.hash.split(":")[0])
    $expectedHash = $($image.disk.hash.Split(":")[1])

    $success = Get-FileWithHash -FileName $($fileZip) -FileDisplayName $name -FileUrl $url  -hashAlg $hashAlg -ExpectedHash $expectedHash
    if (-not $success.success) {
        write-log -failure  "Could not download $($url)"
        return $false
    }
    # If we did not download a new file, and the file already exists.. Exit
    if (-not $success.download) {
        if (test-path $fullfileVHDX -PathType Leaf) {
            return $true
        }
    }

    # If we downloaded a new file, or one didnt exist

    # If we downloaded a new file, delete the old one
    if (test-path $fullfileVHDX -PathType Leaf) {
        Remove-Item $fullfileVHDX -force
    }

    # If the intermediate file exists, delete it so we can extract a new one.
    if (test-path $($Global:Common.AzureImagePath + "\" + $image.disk.archiveRelativePath) -PathType Leaf) {
        Remove-Item $($Global:Common.AzureImagePath + "\" + $image.disk.archiveRelativePath) -force
    }

    #Expand the downloaded file
    Expand-Archive -Path $fullfileZip -DestinationPath $($Global:Common.AzureImagePath) -Force
    # Move it to its final name
    move-item $($Global:Common.AzureImagePath + "\" + $image.disk.archiveRelativePath) $fullfileVHDX -Force
    return $true
}

Function Show-Summary {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsCustomObject] $deployConfig
    )

    $fixedConfig = $deployConfig.virtualMachines | Where-Object { -not $_.hidden }
    $DC = $deployConfig.virtualMachines  | Where-Object { $_.role -eq "DC" }

    #$CHECKMARK = ([char]8730)
    $containsPS = $fixedConfig.role -contains "Primary"
    $containsSecondary = $fixedConfig.role -contains "Secondary"
    $containsSiteSystem = $fixedConfig.role -contains "SiteSystem"
    $containsMember = $fixedConfig.role -contains "DomainMember"
    $containsPassive = $fixedConfig.role -contains "PassiveSite"

    Write-Verbose "ContainsPS: $containsPS ContainsSiteSystem: $containsSiteSystem ContainsMember: $containsMember ContainsPassive: $containsPassive"
    if ($DC.ForestTrust -and $DC.ForestTrust -ne "NONE") {
        Write-GreenCheck "Forest Trust: This domain will join a Forest Trust with $($DC.ForestTrust)"
        $remoteDC = Get-List -type VM -DomainName $DC.ForestTrust | Where-Object { $_.Role -eq "DC" }
        if ($remoteDC -and $remoteDC.InstallCA) {
            Write-GreenCheck "Forest Trust: This domain be configured to use the Certificate Authority in $($DC.ForestTrust)"
        }

        if ($DC.externalDomainJoinSiteCode) {
            Write-GreenCheck "Forest Trust: Site code $($DC.externalDomainJoinSiteCode) in domain $($DC.ForestTrust) will be configured to manage client machines in this domain"
        }
    }

    if ($null -ne $($deployConfig.cmOptions) -and $deployConfig.cmOptions.install -eq $true) {

        if ($containsPS -or $containsSecondary) {
            $versionInfoPrinted = $false
            $baselineVersion = (Get-CMBaselineVersion -CMVersion $deployConfig.cmOptions.version).baselineVersion
            if ($deployConfig.cmOptions.OfflineSCP) {
                if ($baselineVersion -ne $deployConfig.cmOptions.version) {
                    Write-RedX "ConfigMgr $($deployConfig.cmOptions.version) selected, but due to Offline SCP $baselineVersion will be installed."
                    $versionInfoPrinted = $true
                }
            }
           
            if (-not $versionInfoPrinted) {
                if ($baselineVersion -ne $deployConfig.cmOptions.version) {
                    Write-OrangePoint "ConfigMgr $baselineVersion will be installed and upgraded to $($deployConfig.cmOptions.version)"
                }
                else {
                    Write-GreenCheck "ConfigMgr $($deployConfig.cmOptions.version) will be installed."
                }

            }
           

            $PS = $fixedConfig | Where-Object { $_.Role -eq "Primary" }
            if ($PS) {
                foreach ($PSVM in $PS) {
                    if ($PSVM.ParentSiteCode) {
                        Write-GreenCheck "ConfigMgr Primary server $($PSVM.VMName) will join a Hierarchy: $($PSVM.SiteCode) -> $($PSVM.ParentSiteCode)"
                    }
                    else {
                        Write-GreenCheck "Primary server $($PSVM.VMName) with Sitecode $($PSVM.SiteCode) will be installed in a standalone configuration"
                    }
                }
            }

            $SSVM = $fixedConfig | Where-Object { $_.Role -eq "Secondary" }
            if ($SSVM) {
                Write-GreenCheck -NoNewLine "Secondary Site(s) will be installed:"
                foreach ($SS in $SSVM) {
                    write-host -NoNewLine " $($SS.SiteCode) -> $($SS.ParentSiteCode)"
                }
                write-host
            }
            if ($containsPS) {
                if ($containsPassive) {
                    $PassiveVMs = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
                    foreach ($PassiveVM in $PassiveVMs) {
                        Write-GreenCheck "(High Availability) ConfigMgr site server in passive mode $($PassiveVM.VMName) will be installed for SiteCode $($PassiveVM.SiteCode -Join ',')"
                    }
                }
                else {
                    Write-RedX "(High Availability) No ConfigMgr site server in passive mode will be installed"
                }
            }
        }
        else {
            Write-RedX "ConfigMgr will not be installed."
        }

        if ($deployConfig.cmOptions.usePKI) {
            Write-GreenCheck "PKI: HTTPS is enforced, this will make the environment HTTPS only including MP/DP/SUP and reporting roles"
        }
        else {
            Write-OrangePoint "PKI: HTTP/EHTTP will be used for all communication"
        }
        if ($deployConfig.cmOptions.OfflineSCP) {
            Write-OrangePoint "SCP: Will be installed in OFFLINE mode"
        }
 
       
        $testSystem = $fixedConfig | Where-Object { $_.InstallDP -or $_.enablePullDP }
        if ($testSystem) {
            Write-GreenCheck "DP role will be installed on $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.InstallMP }
        if ($testSystem) {
            Write-GreenCheck "MP role will be installed on $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.installSUP }
        if ($testSystem) {
            Write-GreenCheck "SUP role will be installed on $($testSystem.vmName -Join ",")"
            if ($deployConfig.cmOptions.OfflineSUP) {
                Write-OrangePoint "SUP: Will be installed in OFFLINE mode for the top-level site"
            }
        }

        $testSystem = $fixedConfig | Where-Object { $_.installRP }
        if ($testSystem) {
            Write-GreenCheck "Reporting Point role will be installed on $($testSystem.vmName -Join ",")"
        }


        if ($containsMember) {
            if ($containsPS -and $deployConfig.cmOptions.pushClientToDomainMembers -and $deployConfig.cmOptions.install -eq $true) {
                $PSVMs = $fixedConfig | Where-Object { $_.Role -eq "Primary" }
                foreach ($PSVM in $PSVMs) {
                    if ($PSVM.thisParams.ClientPush) {
                        Write-GreenCheck "Client Push: Yes $($PSVM.VMname) : [$($PSVM.thisParams.ClientPush -join ",")]"
                    }
                    else {
                        Write-OrangePoint "Client Push is enabled for $($PSVM.VMname) , but no eligible clients found"
                    }
                }
            }
            else {
                Write-RedX "Client Push: No"
            }
        }
        else {
            #Write-Host " [Client Push: N/A]"
        }

    }
    else {
        Write-Verbose "deployConfig.cmOptions.install = $($deployConfig.cmOptions.install)"
        if (($deployConfig.cmOptions.install -eq $true) -and $containsPassive) {
            $PassiveVM = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
        }
        else {
            Write-RedX "ConfigMgr will not be installed."
        }
    }

    #  if (($deployConfig.cmOptions.install -eq $true) -and $containsPassive) {
    #     $PassiveVM = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
    #     Write-GreenCheck "ConfigMgr HA Passive server with Sitecode $($PassiveVM.SiteCode) will be installed"
    # }
    if (-not $null -eq $($deployConfig.vmOptions)) {

        if ($null -eq $deployConfig.parameters.ExistingDCName) {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be created." -NoNewLine
        }
        else {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be joined." -NoNewLine
        }

        Write-Host " [Default Network $($deployConfig.vmOptions.network)]"
        #Write-GreenCheck "Virtual Machine files will be stored in $($deployConfig.vmOptions.basePath) on host machine"

        $totalMemory = $fixedConfig.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum
        $totalMemory = $totalMemory.Sum / 1GB
        $availableMemory = Get-AvailableMemoryGB
        Write-GreenCheck "This configuration will use $($totalMemory)GB out of $($availableMemory)GB Available RAM on host machine [8GB Buffer]"
    }

    if (-not $Common.DevBranch) {
        Write-GreenCheck "Domain Admin account: " -NoNewLine
        Write-Host2 -ForegroundColor DeepPink "$($deployConfig.vmOptions.adminName)" -NoNewline
        Write-Host " Password: " -NoNewLine
        Write-Host2 -ForegroundColor DeepPink "$($Common.LocalAdmin.GetNetworkCredential().Password)"
    }

    $out = $fixedConfig | Format-table vmName, role, operatingSystem, memory,
    @{Label = "Procs"; Expression = { $_.virtualProcs } },
    @{Label = "SiteCode"; Expression = {
            $SiteCode = $_.siteCode
            if ($_.ParentSiteCode) {
                $SiteCode += "->$($_.ParentSiteCode)"
            }
            $SiteCode
        }
    },
    @{Label = "Network"; Expression = {
            if ($_.Network) { $_.Network }
            else {
                $deployConfig.vmOptions.network + " [Default]"
            }
        }
    },
    @{Label = "Roles"; Expression = {
            $roles = @()
            if ($_.InstallCA) { $roles += "CA" }
            if ($_.InstallSUP) { $roles += "SUP" }
            if ($_.InstallRP) { $roles += "RP" }
            if ($_.InstallMP) { $roles += "MP" }
            if ($_.InstallDP) {
                if ($_.pullDPSourceDP) { $roles += "Pull DP" }
                else {
                    $roles += "DP"
                }
            }
            $roles -join ","
        }
    },
    #@{Label = "AddedDisks"; Expression = { $_.additionalDisks.psobject.Properties.Value.count } },
    @{Label = "Disks"; Expression = {
            $Disks = @("C")
            $Disks += $_.additionalDisks.psobject.Properties.Name | Where-Object { $_ }
            $Disks -Join ","
        }
    },
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
    $outIndented = $out.Trim() -split "\r\n"
    foreach ($line in $outIndented) {
        Write-Host "  $line"
    }

}
