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
        $sampleConfigPath = Join-Path $Common.ConfigPath "tests\$Configuration"
        if (-not (Test-Path $sampleConfigPath)) {
            $return.Message = "Get-UserConfiguration: $Configuration not found in $configPath or $sampleConfigPath. Please create the config manually or use genconfig.ps1, and try again."
            return $return
        }
        $configPath = $sampleConfigPath
    }

    try {
        Write-Log "Loading $configPath." -LogOnly
        $config = Get-Content $configPath -Force | ConvertFrom-Json
        $return.Loaded = $true
        $return.Config = $config
        return $return
    }
    catch {
        $return.Message = "Get-UserConfiguration: Failed to load $configPath. $_"
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
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
            $allSuccess = $false
        }
    }

    foreach ($file in $Common.AzureFileList.ISO) {
        if (-not $DownloadAll -and $sqlVersionsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
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

        $scenario = "Standalone"

        # add prefix to vm names
        $virtualMachines = $configObject.virtualMachines
        foreach ($item in $virtualMachines) {
            $item.vmName = $configObject.vmOptions.prefix + $item.vmName
        }

        $PSVM = $virtualMachines | Where-Object { $_.role -eq "Primary" } | Select-Object -First 1 # Bypass failures, validation would fail if we had multiple
        if ($PSVM) {
            # Add prefix to remote SQL
            if ($PSVM.remoteSQLVM -and -not $PSVM.remoteSQLVM.StartsWith($configObject.vmOptions.prefix)) {
                $PSVM.remoteSQLVM = $configObject.vmOptions.prefix + $PSVM.remoteSQLVM
            }

            if ($PSVM.parentSiteCode) {
                $scenario = "Hierarchy"
            }
        }

        $SQLAOPriVMs = $virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode }
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
                if ($SQLAO.AlwaysOnName -and -not $SQLAO.AlwaysOnName.StartsWith($configObject.vmOptions.prefix)) {
                    $SQLAO.AlwaysOnName = $configObject.vmOptions.prefix + $SQLAO.AlwaysOnName
                }
            }
        }

        $PassiveVMs = $virtualMachines | Where-Object { $_.role -eq "PassiveSite" }
        if ($PassiveVMs) {
            foreach ($PassiveVM in $PassiveVMs) {
                # Add prefix to FS
                if ($PassiveVM.remoteContentLibVM -and -not $PassiveVM.remoteContentLibVM.StartsWith($configObject.vmOptions.prefix)) {
                    $PassiveVM.remoteContentLibVM = $configObject.vmOptions.prefix + $PassiveVM.remoteContentLibVM
                }
            }
        }

        $CSVM = $virtualMachines | Where-Object { $_.role -eq "CAS" } | Select-Object -First 1 # Bypass failures, validation would fail if we had multiple
        if ($CSVM) {
            # Add prefix to remote SQL
            if ($CSVM.remoteSQLVM -and -not $CSVM.remoteSQLVM.StartsWith($configObject.vmOptions.prefix)) {
                $CSVM.remoteSQLVM = $configObject.vmOptions.prefix + $CSVM.remoteSQLVM
            }

            $scenario = "Hierarchy"
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
            Scenario        = $scenario
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
function Add-RemoteSQLVMToDeployConfig{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true
    )
    Add-ExistingVMToDeployConfig -vmName $vmName -configToModify $configToModify -hidden:$hidden
    $remoteSQLVM = Get-VMObjectFromConfigOrExisting -deployConfig $configToModify -vmName $vmName
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

    # Add exising DC to list
    $existingDC = $config.parameters.ExistingDCName
    if ($existingDC) {
        # create a dummy VM object for the existingDC
        Add-ExistingVMToDeployConfig -vmName $existingDC -configToModify $config
    }

    # Add CAS to list, when adding primary
    $PriVMS = $config.virtualMachines | Where-Object { $_.role -eq "Primary" }
    foreach ($PriVM in $PriVMS) {
        if ($PriVM.parentSiteCode) {
            $CAS = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PriVM.parentSiteCode -type VM
            if ($CAS) {
                Add-ExistingVMToDeployConfig -vmName $CAS.vmName -configToModify $config
                if ($CAS.RemoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $CAS.RemoteSQLVM -configToModify $config
                }
            }
        }
    }

    # Add Primary to list, when adding DPMP
    $DPMPs = $config.virtualMachines | Where-Object { $_.role -eq "DPMP" }
    foreach ($dpmp in $DPMPS) {
        $DPMPPrimary = Get-PrimarySiteServerForSiteCode -deployConfig $config -siteCode $dpmp.siteCode
        if ($DPMPPrimary) {
            Add-ExistingVMToDeployConfig -vmName $DPMPPrimary -configToModify $config
        }
    }

    # Add FS to list, when adding SQLAO
    $SQLAOVMs = $config.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode }
    foreach ($SQLAOVM in $SQLAOVMs) {
        if ($SQLAOVM.FileServerVM) {
            Add-ExistingVMToDeployConfig -vmName $SQLAOVM.FileServerVM -configToModify $config
        }
        Add-ExistingVMsToDeployConfig -vmName $SQLAOVM.OtherNode -configToModify $config
    }


    # Add Primary to list, when adding Passive
    $PassiveVMs = $config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }
    foreach ($PassiveVM in $PassiveVMs) {
        $ActiveNode = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PassiveVM.siteCode
        if ($ActiveNode) {
            $ActiveNodeVM = Get-VMObjectFromConfigOrExisting -deployConfig $config -vmName $ActiveNode
            if ($ActiveNodeVM) {
                if ($ActiveNodeVM.remoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $ActiveNodeVM.remoteSQLVM -configToModify $config
                }
                Add-ExistingVMToDeployConfig -vmName $ActiveNode -configToModify $config
            }
        }
    }

    # Add Primary to list, when adding Secondary
    $Secondaries = $config.virtualMachines | Where-Object { $_.role -eq "Secondary" }
    foreach ($Secondary in $Secondaries) {
        $primary = Get-SiteServerForSiteCode -deployConfig $config -sitecode $Secondary.parentSiteCode -type VM
        if ($primary) {
            Add-ExistingVMToDeployConfig -vmName $primary.vmName -configToModify $config
            if ($primary.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $primary.RemoteSQLVM -configToModify $config
            }
        }
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
        [bool] $hidden = $true
    )

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
        "domain",
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

    $configToModify.virtualMachines += $newVMObject
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

    if ($thisVM.vmName -eq $VM.vmName) {
        return
    }

    $DomainName = $deployConfig.parameters.domainName
    $DName = $DomainName.Split(".")[0]

    if ($SQLSysAdminAccounts) {
        $accountLists.SQLSysAdminAccounts += "$DNAME\$($VM.vmName)$"
    }
    if ($LocalAdminAccounts) {
        $accountLists.LocalAdminAccounts += "$($VM.vmName)$"
    }
    if ($WaitOnDomainJoin) {
        if (-not $VM.hidden) {
            $accountLists.WaitOnDomainJoin += $VM.vmName
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
    $ServiceAccount = "$($ClusterNameNoPrefix)Svc"
    $AgentAccount = "$($ClusterNameNoPrefix)Agent"

    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
    $cnUsersName = "CN=Users,DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"
    $cnComputersName = "CN=Computers,DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"
    $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]

    if (-not ($PrimaryAO.ClusterIPAddress)) {
        $vm = Get-List2 -deployConfig $deployConfig | where-object { $_.vmName -eq $PrimaryAO.vmName }
        if ($vm.ClusterIPAddress) {
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "ClusterIPAddress" -Value $vm.ClusterIPAddress -Force
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "AGIPAddress" -Value $vm.AGIPAddress -Force
        }
    }

    $config = [PSCustomObject]@{
        GroupName                  = $ClusterName
        GroupMembers               = @("$($PrimaryAO.vmName)$", "$($SecondAO)$", "$($ClusterName)$")
        SqlServiceAccount          = $ServiceAccount
        SqlServiceAccountFQ        = $netbiosName + "\" + $ServiceAccount
        SqlAgentServiceAccount     = $AgentAccount
        SqlAgentServiceAccountFQ   = $netbiosName + "\" + $AgentAccount
        OULocationUser             = $cnUsersName
        OULocationDevice           = $cnComputersName
        ClusterNodes               = @($PrimaryAO.vmName, $SecondAO)
        WitnessLocalPath           = "F:\$($ClusterNameNoPrefix)-Witness"
        BackupLocalPath            = "F:\$($ClusterNameNoPrefix)-Backup"
        AlwaysOnName               = $PrimaryAO.AlwaysOnName
        PrimaryNodeName            = $PrimaryAO.vmName
        SecondaryNodeName          = $SecondAO
        FileServerName             = $FSAO.vmName
        ClusterIPAddress           = $PrimaryAO.ClusterIPAddress + "/24"
        AGIPAddress                = $PrimaryAO.AGIPAddress + "/255.255.255.0"
        PrimaryReplicaServerName   = $PrimaryAO.vmName + "." + $deployConfig.vmOptions.DomainName
        SecondaryReplicaServerName = $PrimaryAO.OtherNode + "." + $deployConfig.vmOptions.DomainName
        ClusterNameAoG             = $PrimaryAO.AlwaysOnName
        ClusterNameAoGFQDN         = $PrimaryAO.AlwaysOnName + "." + $deployConfig.vmOptions.DomainName
        WitnessShareFQ             = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Witness"
        BackupShareFQ              = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Backup"
        WitnessShare               = "$($ClusterNameNoPrefix)-Witness"
        BackupShare                = "$($ClusterNameNoPrefix)-Backup"

    }

    return $config
}

function Add-PerVMSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config to Modify")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "Current Item")]
        [object] $thisVM
    )
    # This function is defunct. Please remove.
    return

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
        [ValidateSet("DC", "CAS", "Primary", "DPMP", "DomainMember", "Secondary")]
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
                        Subnet   = $vm.Subnet
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
                        Subnet   = $vm.Subnet
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

function Get-ExistingForSubnet {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Subnet")]
        [string]$Subnet,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "DPMP", "DomainMember", "Secondary")]
        [string]$Role
    )

    try {

        $existingValue = @()
        $vmList = Get-List -Type VM | Where-Object { $_.Subnet -eq $Subnet }
        foreach ($vm in $vmList) {
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
        [string] $type = "Name"
    )
    if (-not $SiteCode) {
        return $null
    }
    $SiteServerRoles = @("Primary", "Secondary", "CAS")
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
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return $existingVMs | Select-Object -First 1
        }
    }
    return $null
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

function Get-VMObjectFromConfigOrExisting {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [object] $vmName
    )

    $vm = Get-List -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.vmName -eq $vmName -and -not $_.hidden }
    if ($vm) {
        return $vm
    }

    $vm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }
    if ($vm) {
        return $vm
    }
}

function Get-PrimarySiteServerForSiteCode {
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
    $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode
    $roleforSite = get-RoleForSitecode -ConfigToCheck $deployConfig -siteCode $SiteCode
    if ($roleforSite -eq "Primary") {
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -type VM
        }
    }
    if ($roleforSite -eq "Secondary") {
        $SiteServerVM = Get-VMObjectFromConfigOrExisting -deployConfig $deployConfig -vmName $SiteServer
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteServerVM.parentSiteCode
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-VMObjectFromConfigOrExisting -deployConfig $deployConfig -vmName $SiteServer
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

function Get-SubnetList {

    param(
        [Parameter(Mandatory = $false)]
        [string] $DomainName
    )
    try {

        if ($DomainName) {
            return (Get-List -Type Subnet -DomainName $DomainName)
        }

        return (Get-List -Type Subnet)

    }
    catch {
        Write-Log "Failed to get subnet list. $_" -Failure -LogOnly
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
            return $vmCacheEntry
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

    ConvertTo-Json $vmCacheEntry | Out-File $cacheFile -Force
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
        $vmNoteObject = $vm.Notes | convertFrom-Json
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
        if ($vmNoteObject.role -eq "DPMP") {
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

    $vmNet = Get-VMNetworkCached -vm $vm

    #VmState is now updated  in Update-VMFromHyperV
    #$vmState = $vm.State.ToString()

    $vmObject = [PSCustomObject]@{
        vmName          = $vm.Name
        vmId            = $vm.Id
        subnet          = $vmNet.SwitchName
        memoryGB        = $vm.MemoryAssigned / 1GB
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
            $vmNoteObject = $vm.Notes | convertFrom-Json
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
            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
        }
    }
    else {
        $vmObject | Add-Member -MemberType NoteProperty -Name "vmBuild" -Value $false -Force
    }

}

$global:vm_List = $null
function Get-List {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "Type")]
        [ValidateSet("VM", "Subnet", "Prefix", "UniqueDomain", "UniqueSubnet", "UniquePrefix")]
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

    $mtx = New-Object System.Threading.Mutex($false, "GetList")
    $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    write-log "[$tid] Attempting to acquire 'GetList' Mutex" -LogOnly -Verbose
    [void]$mtx.WaitOne()
    write-log "[$tid] acquired 'GetList' Mutex" -LogOnly -Verbose
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

        if ($SmartUpdate.IsPresent) {
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

        if (-not $global:vm_List) {

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

        if ($null -ne $DeployConfigClone) {
            foreach ($vm in $return) {
                $vm | Add-Member -MemberType NoteProperty -Name "source" -Value "hyperv" -Force
            }
            $domain = $DeployConfigClone.vmoptions.domainName
            $network = $DeployConfigClone.vmoptions.network

            $prefix = $DeployConfigClone.vmoptions.prefix
            foreach ($vm in $DeployConfigClone.virtualMachines) {
                $found = $false
                if ($vm.hidden) {
                    continue
                }
                if ($vm.network){
                    $network = $vm.network
                }
                foreach ($vm2 in $return) {
                    if ($vm2.vmName -eq $vm.vmName) {
                        $vm2.source = "config"
                        $found = $true
                    }
                }
                if ($found) {
                    continue
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

        $return = $return | Sort-Object -Property * -Unique

        if ($Type -eq "VM") {
            return $return
        }

        # Include Internet subnets, filtering them out as-needed in Common.Remove
        if ($Type -eq "Subnet") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Subnet, Domain | Sort-Object -Property * -Unique
        }

        if ($Type -eq "Prefix") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Prefix, Domain | Sort-Object -Property * -Unique
        }

        if ($Type -eq "UniqueDomain") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Domain -Unique -ErrorAction SilentlyContinue
        }

        if ($Type -eq "UniqueSubnet") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Subnet -Unique -ErrorAction SilentlyContinue
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
        [void]$mtx.ReleaseMutex()
        [void]$mtx.Dispose()
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


Function Write-GreenCheck {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [string] $ForegroundColor
    )
    $CHECKMARK = ([char]8730)
    $text = $text.Replace("SUCCESS: ", "")
    Write-Host "  [" -NoNewLine
    Write-Host -ForeGroundColor Green "$CHECKMARK" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        while (-not [string]::IsNullOrWhiteSpace($text)) {
            #write-host $text
            $indexLeft = $text.IndexOf('[')
            $indexRight = $text.IndexOf(']')
            if ($indexRight -eq -1 -and $indexLeft -eq -1) {
                Write-Host -ForegroundColor $ForegroundColor "$text" -NoNewline
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
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "]" -NoNewline
                    $text = $text.Substring($indexRight)
                    $text = $text.Substring(1)
                }
                if ($indexLeft -lt $indexRight) {
                    $text2Display = $text.Substring(0, $indexLeft)
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "[" -NoNewline
                    $text = $text.Substring($indexLeft)
                    $text = $text.Substring(1)
                }
            }

        }
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
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
        [string] $ForegroundColor
    )
    $text = $text.Replace("ERROR: ", "")
    Write-Host "  [" -NoNewLine
    Write-Host -ForeGroundColor Red "x" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        while (-not [string]::IsNullOrWhiteSpace($text)) {
            #write-host $text
            $indexLeft = $text.IndexOf('[')
            $indexRight = $text.IndexOf(']')
            if ($indexRight -eq -1 -and $indexLeft -eq -1) {
                Write-Host -ForegroundColor $ForegroundColor "$text" -NoNewline
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
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "]" -NoNewline
                    $text = $text.Substring($indexRight)
                    $text = $text.Substring(1)
                }
                if ($indexLeft -lt $indexRight) {
                    $text2Display = $text.Substring(0, $indexLeft)
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "[" -NoNewline
                    $text = $text.Substring($indexLeft)
                    $text = $text.Substring(1)
                }
            }

        }
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
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
    Write-Host -ForeGroundColor Yellow "!" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        while (-not [string]::IsNullOrWhiteSpace($text)) {
            #write-host $text
            $indexLeft = $text.IndexOf('[')
            $indexRight = $text.IndexOf(']')
            if ($indexRight -eq -1 -and $indexLeft -eq -1) {
                Write-Host -ForegroundColor $ForegroundColor "$text" -NoNewline
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
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "]" -NoNewline
                    $text = $text.Substring($indexRight)
                    $text = $text.Substring(1)
                }
                if ($indexLeft -lt $indexRight) {
                    $text2Display = $text.Substring(0, $indexLeft)
                    Write-Host -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                    Write-Host -ForegroundColor DarkGray "[" -NoNewline
                    $text = $text.Substring($indexLeft)
                    $text = $text.Substring(1)
                }
            }

        }
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

Function Show-Summary {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsCustomObject] $deployConfig
    )

    $fixedConfig = $deployConfig.virtualMachines | Where-Object { -not $_.hidden }
    #$CHECKMARK = ([char]8730)
    $containsPS = $fixedConfig.role -contains "Primary"
    $containsSecondary = $fixedConfig.role -contains "Secondary"
    $containsDPMP = $fixedConfig.role -contains "DPMP"
    $containsMember = $fixedConfig.role -contains "DomainMember"
    $containsPassive = $fixedConfig.role -contains "PassiveSite"

    Write-Verbose "ContainsPS: $containsPS ContainsDPMP: $containsDPMP ContainsMember: $containsMember ContainsPassive: $containsPassive"
    if ($null -ne $($deployConfig.cmOptions) -and $deployConfig.cmOptions.install -eq $true) {
        if ($deployConfig.cmOptions.install -eq $true -and ($containsPS -or $containsSecondary)) {
            Write-GreenCheck "ConfigMgr $($deployConfig.cmOptions.version) will be installed."


            if ($deployConfig.cmOptions.updateToLatest -eq $true) {
                Write-GreenCheck "ConfigMgr will be updated to latest"
            }
            else {
                Write-RedX "ConfigMgr will NOT updated to latest"
            }
            $PSVM = $fixedConfig | Where-Object { $_.Role -eq "Primary" }
            if ($PSVM) {
                if ($PSVM.ParentSiteCode) {
                    Write-GreenCheck "ConfigMgr Primary server will join a Hierarchy: $($PSVM.SiteCode) -> $($PSVM.ParentSiteCode)"
                }
                else {
                    Write-GreenCheck "Primary server with Sitecode $($PSVM.SiteCode) will be installed in a standalone configuration"
                }
            }

            $SSVM = $fixedConfig | Where-Object { $_.Role -eq "Secondary" }
            if ($SSVM) {
                Write-GreenCheck "Secondary Site will be installed: $($SSVM.SiteCode) -> $($SSVM.ParentSiteCode)"
            }
            if ($containsPS) {
                if ($containsPassive) {
                    $PassiveVM = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
                    Write-GreenCheck "(High Availability) ConfigMgr site server in passive mode will be installed for SiteCode(s) $($PassiveVM.SiteCode -Join ',')"
                }
                else {
                    Write-RedX "(High Availability) No ConfigMgr site server in passive mode will be installed"
                }
            }
        }
        else {
            Write-RedX "ConfigMgr will not be installed."
        }


        if ($deployConfig.cmOptions.install -eq $true) {
            $foundDP = $false
            $foundMP = $false

            $DPMP = $fixedConfig | Where-Object { $_.Role -eq "DPMP" -and $_.InstallDP -and $_.InstallMP }
            if ($DPMP) {
                Write-GreenCheck "DP and MP roles will be installed on $($DPMP.vmName -Join ",")"
                $foundDP = $true
                $foundMP = $true
            }

            $DPMP = $fixedConfig | Where-Object { $_.Role -eq "DPMP" -and $_.InstallDP -and -not $_.InstallMP }
            if ($DPMP) {
                Write-GreenCheck "DP role will be installed on $($DPMP.vmName -Join ",")"
                $foundDP = $true
            }
            $DPMP = $fixedConfig | Where-Object { $_.Role -eq "DPMP" -and $_.InstallMP -and -not $_.InstallDP }
            if ($DPMP) {
                Write-GreenCheck "MP role will be installed on $($DPMP.vmName -Join ",")"
                $foundMP = $true
            }

            if (-not $foundDP -or -not $foundMP) {
                $PSVM = $fixedConfig | Where-Object { $_.Role -eq "Primary" }
                if ($PSVM) {
                    if (-not $foundDP -and -not $foundMP) {
                        Write-GreenCheck "DP and MP roles will be installed on Primary Site Server $($PSVM.vmName)"
                    }
                    else {
                        if (-not $foundDP) {
                            Write-GreenCheck "DP role will be installed on Primary Site Server $($PSVM.vmName)"
                        }
                        if (-not $foundMP) {
                            Write-GreenCheck "MP role will be installed on Primary Site Server $($PSVM.vmName)"
                        }
                    }
                }
            }

        }
        else {
            Write-RedX "DPMP roles will not be installed"
        }

        if ($containsMember) {
            if ($containsPS -and $deployConfig.cmOptions.pushClientToDomainMembers -and $deployConfig.cmOptions.install -eq $true) {
                $MemberNames = ($fixedConfig | Where-Object { $_.Role -eq "DomainMember" -and $null -eq $($_.SqlVersion) }).vmName
                Write-GreenCheck "Client Push: Yes [$($MemberNames -join ",")]"
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

        Write-Host " [Network $($deployConfig.vmOptions.network)]"
        #Write-GreenCheck "Virtual Machine files will be stored in $($deployConfig.vmOptions.basePath) on host machine"

        $totalMemory = $fixedConfig.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum
        $totalMemory = $totalMemory.Sum / 1GB
        $availableMemory = Get-AvailableMemoryGB
        Write-GreenCheck "This configuration will use $($totalMemory)GB out of $($availableMemory)GB Available RAM on host machine"
    }
    Write-GreenCheck "Domain Admin account: " -NoNewLine
    Write-Host -ForegroundColor Green "$($deployConfig.vmOptions.adminName)" -NoNewline
    Write-Host " Password: " -NoNewLine
    Write-Host -ForegroundColor Green "$($Common.LocalAdmin.GetNetworkCredential().Password)"

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
    @{Label = "AddedDisks"; Expression = { $_.additionalDisks.psobject.Properties.Value.count } },
    @{Label = "Network"; Expression = { $_.Network } },
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
