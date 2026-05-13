# Common.GenConfig.NewDomain.ps1
# "New Domain" wizard helpers used by genconfig.ps1 to author a new lab
# configuration: VM/site-code naming, locale/timezone selection, deployment-
# type picker, and the top-level Select-NewDomainConfig flow.

function Get-NewMachineName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM to rename")]
        [object] $vm,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "ClusterName")]
        [switch] $ClusterName,
        [Parameter(Mandatory = $false, HelpMessage = "AlwaysOnName")]
        [switch] $AOName,
        [Parameter(Mandatory = $false, HelpMessage = "Skip 1 in machine name")]
        [switch] $SkipOne
    )

    #Get-PSCallStack | Out-Host

    $Domain = $vm.vmOptions.DomainName
    $OS = $vm.OperatingSystem
    $SiteCode = $vm.SiteCode
    $CurrentName = $vm.vmName
    $Role = $vm.Role
    $RoleName = $vm.Role
    if ($Role -eq "OSDClient") {
        $RoleName = "OSD"
    }
    if ($Role -eq "BDC") {
        $RoleName = "DC"
    }
    if ($Role -eq "DomainMember" -or [string]::IsNullOrWhiteSpace($Role) -or $Role -eq "WorkgroupMember" -or $Role -eq "AADClient" -or $role -eq "InternetClient") {
        if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
            $RoleName = "Mem"
        }
        else {
            $RoleName = "Member"
        }

        if ($OS -like "*Server*") {
            if ($vm.SqlVersion) {
                $RoleName = "SQL"
            }
            else {
                if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                    $RoleName = "Srv"
                }
                else {
                    $RoleName = "Server"
                }
            }
        }
        else {
            if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                $RoleName = "Cli"
            }
            else {
                $RoleName = "Client"
            }
        }

        if ($Role -eq "WorkgroupMember") {
            $RoleName = "WG"
        }
        if ($Role -eq "InternetClient") {
            $RoleName = "INT"
        }
        if ($Role -eq "AADClient") {
            $RoleName = "AAD"
        }
        if ($Role -eq "FileServer") {
            $RoleName = "FS"
        }
        Write-Verbose "Rolename is now $RoleName"

        if ($OS -like "Windows 10*") {

            $RoleName = "W10" + $RoleName
        }
        if ($OS -like "Windows 11*") {

            $RoleName = "W11" + $RoleName
        }

        switch ($OS) {
            "Server 2025" {

                $RoleName = "W25" + $RoleName
            }
            "Server 2022" {

                $RoleName = "W22" + $RoleName
            }
            "Server 2019" {

                $RoleName = "W19" + $RoleName
            }
            "Server 2016" {

                $RoleName = "W16" + $RoleName
            }
            Default {}
        }
    }

    if (($role -eq "Primary") -or ($role -eq "CAS") -or ($role -eq "PassiveSite") -or ($role -eq "Secondary")) {
        if ([String]::IsNullOrWhiteSpace($SiteCode)) {
            $newSiteCode = Get-NewSiteCode $Domain -Role $Role -ConfigToCheck $ConfigToCheck
        }
        else {
            $newSiteCode = $SiteCode
        }
        $NewName = $newSiteCode + "SITE"
        if ($role -eq "PassiveSite") {
            $NewName = $NewName + "-P"
        }
        return $NewName
    }

    if ($role -eq "DomainMember" -and $vm.SQLVersion) {
        foreach ($existing in $configToCheck.VirtualMachines) {
            if ($existing.RemoteSQLVM -eq $vm.vmName -and $existing.Role -in "CAS", "Primary") {
                $RoleName = $existing.SiteCode + "SQL"
                $SkipOne = $true
            }
        }
    }

    if ($role -eq "WSUS") {
        if ($vm.installSUP) {
            $RoleName = $siteCode + "SUP"
        }
        else {
            $RoleName = $role
        }
    }

    if ($role -eq "SiteSystem") {
        $RoleName = ""

        if ($vm.installDP -or $vm.enablePullDP) {

            if ($vm.enablePullDP) {
                $RoleName = $RoleName + "PDP"
            }
            else {
                $RoleName = $RoleName + "DP"
            }
        }
        if ($vm.installMP) {
            $RoleName = $RoleName + "MP"
        }

        if ($vm.installRP) {
            $RoleName = $RoleName + "RP"
        }

        if ($vm.installSUP) {
            $RoleName = $RoleName + "SUP"
        }

        if ($RoleName -eq "") {
            $RoleName = "SITESYS"
        }

        $RoleName = $siteCode + $RoleName

        if ((($($ConfigToCheck.vmOptions.Prefix) + $RoleName).Length) -gt 14) {
            $RoleName = $SiteCode + "SITESYS"
        }

    }
    if ($Role -eq "FileServer") {
        $RoleName = "FS"

    }

    if ($Role -eq "SQLAO") {
        if ($ClusterName) {
            $RoleName = "SqlCluster"
        }
        if ($AoName) {
            $RoleName = "AlwaysOn"
        }
    }

    if ($Role -eq "StandaloneRootCA") {
        # Default to "OfflineCA" (no number); the loop below will append a
        # numeric suffix only if a duplicate exists.
        $RoleName = "OfflineCA"
        $SkipOne = $true
    }

    [int]$i = 1
    while ($true) {
        if ($SkipOne -and $i -eq 1) {
            $NewName = $RoleName
        }
        else {
            $NewName = $RoleName + ($i)
        }

        if ($NewName -eq $vm.vmName) {
            break
        }
        if ($null -eq $ConfigToCheck) {
            write-log "Config is NULL..  Machine names will not be checked. Please notify someone of this bug." -Failure
            #break
        }
        if (($ConfigToCheck.virtualMachines | Where-Object { ($_.vmName -eq $NewName -or $_.AlwaysOnListenerName -eq $NewName -or $_.ClusterName -eq $NewName) -and $NewName -ne $CurrentName } | Measure-Object).Count -eq 0) {

            $newNameWithPrefix = ($ConfigToCheck.vmOptions.prefix) + $NewName
            if ((Get-List -Type VM | Where-Object { $_.vmName -eq $newNameWithPrefix -or $_.ClusterName -eq $newNameWithPrefix -or $_.AlwaysOnListenerName -eq $newNameWithPrefix } | Measure-Object).Count -eq 0) {
                break
            }
        }
        write-log -verbose "$newName already exists [$CurrentName].. Trying next"
        $i++
    }
    return $NewName.ToUpper()
}

function Get-NewSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the machine CAS/Primary")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    $usedSiteCodes = @()
    $usedSiteCodes += (get-list -type VM -domain $Domain | Where-Object { $_.SiteCode }).SiteCode
    if ($ConfigToCheck.VirtualMachines) {
        $usedSiteCodes += ($ConfigToCheck.VirtualMachines | Where-Object { $_.SiteCode }).Sitecode
    }

    if ($Role -eq "CAS") {
        $siteCodePrefix = "CS"
        $siteCodePrefix2 = "C"
    }
    if ($role -eq "Primary") {
        $siteCodePrefix = "PS"
        $siteCodePrefix2 = "P"
    }

    if ($role -eq "Secondary") {
        $siteCodePrefix = "SS"
        $siteCodePrefix2 = "S"
    }

    for ($i = 1; $i -lt 10; $i++) {
        if ($i -ge 10) {
            $desiredSiteCode = $siteCodePrefix2 + $i
        }
        else {
            $desiredSiteCode = $siteCodePrefix + $i
        }
        if ($desiredSiteCode -in $usedSiteCodes) {
            continue
        }
        return $desiredSiteCode
    }

}


function get-PrefixForDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain
    )

    $existingDomains = get-list -Type UniqueDomain
    if ($existingDomains -contains $Domain) {
        $existingPrefix = (Get-List -type VM -DomainName $domain | Where-Object { $_.Role -eq "DC" }).Prefix

        if (-not [string]::IsNullOrWhiteSpace($existingPrefix)) {
            return $existingPrefix
        }
    }
    $ValidDomainNames = Get-ValidDomainNames
    $prefix = $($ValidDomainNames[$domain])
    if ([String]::IsNullOrWhiteSpace($prefix)) {
        $prefix = ($domain.ToUpper().SubString(0, 3) + "-") -replace "\.", ""
    }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    return $prefix

}


function select-timezone {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    $commonTimeZones = @()
    $commonTimeZones += $((Get-TimeZone).Id)
    $commonTimeZones += "Pacific Standard Time"
    $commonTimeZones += "Central Standard Time"
    $commonTimeZones += "Eastern Standard Time"
    $commonTimeZones += "Mountain Standard Time"
    $commonTimeZones += "UTC"
    $commonTimeZones += "Central Europe Standard Time"
    $commonTimeZones += "China Standard Time"
    $commonTimeZones += "Tokyo Standard Time"
    $commonTimeZones += "India Standard Time"
    $commonTimeZones += "Russian Standard Time"

    $commonTimeZones = $commonTimeZones | Select-Object -Unique
    $timezone = Get-Menu2 -MenuName "Timezone Selection" -Prompt "Select Timezone" -OptionArray $commonTimeZones -CurrentValue $($ConfigToCheck.vmOptions.timezone) -additionalOptions @{"F" = "Display Full List" }
    if ($timezone -eq "F") {
        Write-Log -Activity "Full Timezone Selection" -NoNewLine
        $timezone = Get-Menu -Prompt "Select Timezone" -OptionArray $((Get-TimeZone -ListAvailable).Id) -CurrentValue $($ConfigToCheck.vmOptions.timezone) -test:$false
    }
    return $timezone
}
function Select-Locale {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    # default locale is en-US
    $commonLocales = @()
    $commonLocales += "en-US"

    # add selection if locale configuration file exists
    $localeConfigPath = Join-Path $Common.ConfigPath "_localeConfig.json"
    if (Test-Path $localeConfigPath) {
        try {
            $localeConfig = Get-Content -Path $localeConfigPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $localeConfig.psobject.Properties | ForEach-Object {
                $commonLocales += $_.Name
            }
        }
        catch {
            Write-Log "Something wrong with _localeConfig.json. Only en-US is available." -Warning
        }
    }

    $commonLanguages = $commonLanguages | Select-Object -Unique
    $locale = Get-Menu2 -MenuName "Locale Menu using _localeConfig.json"  -Prompt "Select Locale" -OptionArray $commonLocales -CurrentValue $($ConfigToCheck.vmOptions.locale)
    if ($null -eq $locale -or $locale -eq "ESCAPE") {
        $locale = $($ConfigToCheck.vmOptions.locale)
    }
    return $locale
}
function select-NewDomainName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )

    if (-not $ConfigToCheck -or $ConfigToCheck.virtualMachines.role -contains "DC") {
        while ($true) {
            $ValidDomainNames = Get-ValidDomainNames
            $CurrentValue = (($ValidDomainNames).Keys | sort-object { $_.Length } | Select-Object -first 1) 
            if ($ConfigToCheck.domainDefaults.DomainName) {
                $CurrentValue = $ConfigToCheck.domainDefaults.DomainName
                if (-not ($($ConfigToCheck.domainDefaults.DomainName) -in ($ValidDomainNames.Keys))) {
                    $prefix = get-PrefixForDomain -Domain $ConfigToCheck.domainDefaults.DomainName
                    $ValidDomainNames.Add($ConfigToCheck.domainDefaults.DomainName, $prefix)
                }                        
            }
            if ($ConfigToCheck.vmOptions.DomainName) {
                $CurrentValue = $ConfigToCheck.vmOptions.DomainName
                if (-not ($($ConfigToCheck.vmoptions.DomainName) -in ($ValidDomainNames.Keys))) {
                    $ValidDomainNames.Add($ConfigToCheck.vmOptions.DomainName, $ConfigToCheck.vmOptions.Prefix)
                }                        
            }

                    
            $domain = $null
            $customOptions = @{ "C" = "Custom Domain" }

            while (-not $domain -and $domain -ne "ESCAPE") {
                $domain = Get-Menu2 -MenuName "Select a pre-approved domain name from the list, or use 'C' for a custom name." -Prompt "Select Domain" -OptionArray $($ValidDomainNames.Keys | Sort-Object { $_.length }) -additionalOptions $customOptions -CurrentValue $CurrentValue -Test:$false

                if ($domain -eq "ESCAPE") {
                    return
                }
                if ($domain -and ($domain.ToLowerInvariant() -eq "c")) {
                    write-host
                    write-host
                    $domain = Read-Host2 -Prompt "Enter Custom Domain Name (eg test.com):"
                    if (-not $domain.Contains(".")) {
                        Write-Host
                        Write-RedX -ForegroundColor FireBrick "domainName value [$($domain)] is invalid. You must specify the Full Domain name. For example: contoso.com"
                        $domain = $null
                        continue
                    }

                    # valid domain name
                    $pattern = "^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$"
                    if (-not ($domain -match $pattern)) {
                        Write-Host
                        Write-RedX -ForegroundColor FireBrick "domainName value [$($domain)] contains invalid characters, is too long, or too short. You must specify a valid Domain name. For example: contoso.com."
                        $domain = $null
                        continue
                    }
                }
                if ($domain.Length -lt 3) {
                    $domain = $null
                }
            }
            if ($domain -and $domain -ne "ESCAPE") {
                if ((get-list -Type UniqueDomain) -contains $domain.ToLowerInvariant()) {
                    Write-Host
                    Write-RedX -ForegroundColor FireBrick "Domain is already in use. Please use the Expand option to expand the domain"
                    continue
                }
            }
            if ($domain -eq "ESCAPE") {
                if ($ConfigToCheck.vmOptions.DomainName) {
                    return $ConfigToCheck.vmOptions.DomainName
                }                
            }

            return $domain
        }
    }
    else {
        $existingDomains = @()
        $existingDomains += get-list -Type UniqueDomain
        if ($existingDomains.count -eq 0) {
            Write-Host
            Write-Host "No DC configured, and no existing domains found. Please Ctrl-C to start over and create a new domain"
            return
        }
        $domain = $null
        while (-not $domain -and $domain -ne "ESCAPE") {
            $domain = Get-Menu2 -MenuName "Existing Domains Selection" -Prompt "Select Domain" -OptionArray $existingDomains -CurrentValue $ConfigToCheck.vmoptions.domainName -test:$false
        }
        return $domain
    }
}

function Show-NewDomainTip {
    param(
        [switch] $LineCount
    )
    if ($LineCount) {
        return 2
    }
    Write-Host
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigTip "  Tip: You can enable Configuration Manager High Availability by editing the properties of a CAS or Primary VM, and selecting ""H"""
}
function Select-DeploymentType {
    $response = $null

    $customOptions = [ordered]@{"*F1" = "Show-NewDomainTip" }
    $customOptions += [ordered]@{"*B1" = ""; "*BREAK1" = "DeploymentType%$($Global:Common.Colors.GenConfigHeader)" }
    $customOptions += [ordered]@{ 
        "1"  = "CAS and Primary %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" 
        "H1" = "Initial VM list will contain a CAS and Primary server for Configuration Manager"
    }
    $customOptions += [ordered]@{ 
        "2"  = "Primary Site only %$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)"
        "H2" = "Initial VM list will contain only a Primary server for Configuration Manager"
    }
    #$customOptions += [ordered]@{
    #    "3"  = "Tech Preview (NO CAS)%$($Global:Common.Colors.GenConfigTechPreview)"
    #    "H3" = "Initial VM list will contain only Tech Preview Primary server for Configuration Manager"
    #}
    $customOptions += [ordered]@{ 
        "3"  = "No ConfigMgr%$($Global:Common.Colors.GenConfigNoCM)" 
        "H3" = "Initial VM list will not contain any ConfigMgr components"
    }


    $response = $null
    while (-not $response) {       

        $response = Get-Menu2 -MenuName "New Domain Wizard - Change Deployment type" -Prompt "Select type of deployment" -AdditionalOptions $customOptions -test:$false -return
        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE") {
            return
        }      
        switch ($response.ToLowerInvariant()) {
            "1" {
                return "CAS and Primary"
            }     
            "2" {
                return "Primary Site only"
            }     
            #"3" {
            #    return "Tech Preview (NO CAS)"
            #}     
            "3" {
                return "No ConfigMgr"
            } 
        }    
                
    }
    
}

function Get-NewDomainConfigHelp {
    param(
        $text       
    )

    switch (($text -split "=")[0].Trim()) {
        "DeploymentType" { "Selects the default type of deployment, Primary or Hierarchy" }
        "DomainName" { "Change the FQDN of the domain" }
        "CMVersion" { "Select which version of ConfigMgr to install.  Will not be used if not installing CM" }
        "Network" { "Select the Network VMs will join.  Only /24 ranges are acceptable. " }
        "DefaultServerOS" { "When adding new server VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultClientOS" { "When adding new client VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultSqlVersion" { "When adding new SQL instances, they will default to this version. Can be changed on individual VMs." }
        "UseDynamicMemory" { "Enable Dynamic Memory on each new VM.  Can be turned off in the settings for each VM, using dynamicMinRam" }
        "IncludeClients" { "Disabling this will prevent the 2 automatic client VMs from appearing in a new domain config" }
        "IncludeSSMSOnNONSQL" { "Disabling this will prevent SQL Management Studio from getting installed on NON-SQL servers" }
        "Done with changes" { "All the settings look good.  Move onto next menu" }
        default { "Help Missing for $text" }
    }
    
}

function Select-NewDomainConfig {


    $valid = $false


    $templateDomain = "TEMPLATE2222.com"
    $newconfig = New-UserConfig -Domain $templateDomain -Subnet "10.234.241.0"
    $subnetlist = Get-ValidSubnets

    $Latestversion = Get-CMLatestBaselineVersion
    $domainDefaults = [PSCustomObject]@{
        DeploymentType      = "Primary Site only"
        CMVersion           = $Latestversion
        DomainName          = ((Get-ValidDomainNames).Keys | sort-object { $_.Length } | Select-Object -first 1)
        Network             = ($subnetList | Select-Object -First 1)
        DefaultClientOS     = "Windows 11 Latest"
        DefaultServerOS     = "Server 2022"
        DefaultSqlVersion   = "Sql Server 2022"
        UseDynamicMemory    = $true
        IncludeClients      = $true
        IncludeSSMSOnNONSQL = $true
    }
    $newconfig | Add-Member -MemberType NoteProperty -name "domainDefaults" -Value $domainDefaults -Force


    #Select-Options -Rootproperty $($Global:Config) -PropertyName vmOptions -prompt "Select Global Property to modify" 
    #$additionalOptions = [ordered]@{"*HF" = "Get-NewDomainConfigHelp"}
    $result = Select-Options -MenuName "New Domain Wizard - Default Settings" -Rootproperty $newConfig -PropertyName domainDefaults -prompt "Select Default Property to modify" -ContinueMode:$true -additionalOptions $additionalOptions -HelpFunction "Get-NewDomainConfigHelp"

    if ($result -eq "ESCAPE") {
        return $result
    }
    
 

    $valid = $false
    while ($valid -eq $false) {
        
        $test = $false
        write-log -verbose "Deploying type: $($newconfig.domainDefaults.DeploymentType)"
        switch ($newconfig.domainDefaults.DeploymentType) {
            "CAS and Primary" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "CAS" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "CS1" -Quiet:$true -test:$test
                if ($newconfig.domainDefaults.CMVersion -eq "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = $Latestversion
                }
            }

            "Primary Site only" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "Primary" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "PS1" -Quiet:$true -test:$test
                if ($newconfig.domainDefaults.CMVersion -eq "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = $Latestversion
                }                

            }
            "Tech Preview (NO CAS)" {
                if ($newconfig.domainDefaults.CMVersion -ne "tech-preview") {
                    $newconfig.domainDefaults.CMVersion = $Latestversion
                }

                $usedPrefixes = Get-List -Type UniquePrefix
                if ("CTP-" -notin $usedPrefixes) {
                    $prefix = "CTP-"
                    $newconfig.domainDefaults.DomainName = "techpreview.com"
                }
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
                Add-NewVMForRole -Role "Primary" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -SiteCode "CTP" -Quiet:$true -test:$test
                                              
            }
            "No ConfigMgr" {
                Add-NewVMForRole -Role "DC" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultServerOS -Quiet:$true -test:$test
            }
        }
        $valid = $true
        if ($test) {
            $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
        }

        if ($valid) {
            $valid = $false
            while ($valid -eq $false) {
                if (-not $newconfig.domainDefaults.DomainName) {
                    $result = select-NewDomainName -ConfigToCheck $newConfig
                    if (-not [string]::IsNullOrEmpty($result) -and $result -ne "ESCAPE") {                        
                        $newconfig.domainDefaults.DomainName = $result
                    }
                    else {
                        continue
                    }
                }
                if (-not $prefix) {
                    $prefix = get-PrefixForDomain -Domain $newconfig.domainDefaults.DomainName
                }
                Write-Verbose "Prefix = $prefix"
                $newConfig.vmOptions.domainName = $newconfig.domainDefaults.DomainName
                $newConfig.vmOptions.prefix = $prefix
                $netbiosName = $newconfig.domainDefaults.DomainName.Split(".")[0]
                $newConfig.vmOptions.DomainNetBiosName = $netbiosName
                if ($newconfig.domainDefaults.CMVersion -and $newConfig.cmOptions.version) {
                    $newConfig.cmOptions.version = $newconfig.domainDefaults.CMVersion
                }
                if ($domain -in ((Get-ValidDomainNames).Keys)) {
                    $valid = $true
                }
                else {
                    $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
                }
                if (-not $valid) {
                    $domain = $null
                }
            }
        }

        if ($newconfig.domainDefaults.IncludeClients) {
            Add-NewVMForRole -Role "DomainMember" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultClientOS -Quiet:$true -test:$test
            Add-NewVMForRole -Role "DomainMember" -Domain $newconfig.domainDefaults.DomainName -ConfigToModify $newconfig -OperatingSystem $newconfig.domainDefaults.DefaultClientOS -Quiet:$true -test:$test
        }


        if ($valid) {
           
            $newConfig.vmOptions.network = $newconfig.domainDefaults.network
            $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
        }
        
    }
    return $newConfig
}
