# Common.GenConfig.CmMenus.ps1
# Picker / menu helpers for ConfigMgr role, site code, SQL, OS, WSUS,
# forest trust, and CM version selection used throughout genconfig.ps1.

Function Get-SupportedOperatingSystemsForRole {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $role,
        [Parameter(Mandatory = $false, HelpMessage = "vm")]
        [object] $vm = $null
    )

    $ServerList = $Common.Supported.OperatingSystems | Where-Object { $_ -like 'Server*' }
    $ClientList = $Common.Supported.OperatingSystems | Where-Object { $_ -notlike 'Server*' }
    $AllList = $Common.Supported.OperatingSystems
    switch ($role) {
        "DC" { return $ServerList }
        "BDC" { return $ServerList }
        "CAS" { return $ServerList }
        "CAS and Primary" { return $ServerList }
        "Primary" { return $ServerList }
        "Secondary" { return $ServerList }
        "FileServer" { return $ServerList }
        "Sqlserver" { return $ServerList }
        "SiteSystem" { return $ServerList }
        "WSUS" { return $ServerList }
        "SQLAO" { return $ServerList }
        "PassiveSite" { return $ServerList }
        "DomainMember" {
            if ($vm -and $vm.SqlVersion) {
                return $ServerList
            }
            else {
                return $AllList
            }
        }
        "DomainMember (Server)" { return $ServerList }
        "DomainMember (Client)" { return $ClientList }
        "WorkgroupMember" { return $AllList }
        "InternetClient" { return $ClientList }
        "AADClient" { return $ClientList }
        "OSDClient" { return $null }
        "Linux" { Return (Get-LinuxImages).name }
        default {
            return $AllList
        }
    }
    return $AllList
}


Function Get-OperatingSystemMenuClient {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $OSList = Get-SupportedOperatingSystemsForRole -role "DomainMember (Client)" 
        if ($null -eq $OSList ) {
            return
        }


        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-OperatingSystemMenuServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $OSList = Get-SupportedOperatingSystemsForRole -role "DomainMember (Server)" 
        if ($null -eq $OSList ) {
            return
        }


        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-OperatingSystemMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $OSList = Get-SupportedOperatingSystemsForRole -role $property.Role -vm $CurrentValue
        if ($null -eq $OSList ) {
            return
        }

        Write-Log -Activity -NoNewLine "Operating System Selection"

        $OSName = Get-Menu2 -MenuName "Operating System Selection" -Prompt "Select OS Version" -OptionArray $OSList -CurrentValue $CurrentValue -Test:$false -NoClear
        if ($OSName -eq "ESCAPE") {
            return
        }
        $property."$name" = $OSName
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-ParentSiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [String] $role,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Domain")]
        [string] $Domain
    )

    if ($Role -eq "Primary") {
        $casSiteCodes = Get-ValidCASSiteCodes -config $global:config -domain $Domain

        $additionalOptions = @{ 
            "X"  = "No Parent - Standalone Primary" 
            "HX" = "Configure this VM to be a standalone primary. Not part of a Hierarchy"
        }
        do {
            $result = Get-Menu2 -MenuName "Primary Server Parent Selection" -Prompt "Select CAS sitecode to connect primary to" -OptionArray $casSiteCodes -CurrentValue $CurrentValue -additionalOptions $additionalOptions -Test:$false
        } while (-not $result)
        if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
            return $null
        }
        else {
            return $result
        }
    }
    if ($Role -eq "Secondary") {
        $priSiteCodes = Get-ValidPRISiteCodes -config $global:config -domain $Domain
        if (($priSiteCodes | Measure-Object).Count -eq 0) {
            write-Host "No valid primaries available to connect secondary to."
            return $null
        }
        do {
            Write-Log -Activity -NoNewLine "Secondary Server Parent Selection"
            $result = Get-Menu2 -MenuName "Secondary Server Parent Selection" -Prompt "Select Primary sitecode to connect secondary to" -OptionArray $priSiteCodes -CurrentValue $CurrentValue -Test:$false
        } while (-not $result)
        if ($result -and ($result.ToLowerInvariant() -eq "escape")) {
            return $null
        }
        
        return $result
    }
    return $null
}
Function Set-ParentSiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $valid = $false
    while ($valid -eq $false) {


        $value = Get-ParentSiteCodeMenu -role $property.role -CurrentValue $CurrentValue -domain $global:config.vmOptions.domainName
        if (-not $value) {
            return
        }
        if ($value.Trim()) {
            $property."$name" = $value
        }

        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-ValidSiteCodesForRP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config,
        [Parameter(Mandatory = $false, HelpMessage = "Current VM")]
        [Object] $CurrentVM
    )

    $allSiteCodes = @()

    $list2 = Get-List2 -deployConfig $Config

    $allSiteCodes = ($list2 | where-object { $_.role -in ("CAS", "Primary", "SiteSystem") }).SiteCode

    $currentRPs = ($list2 | Where-Object { $_.installRP -and $_.vmName -ne $CurrentVM.vmName } )

    $invalidSiteCodes = @()
    foreach ($rp in $currentRPs) {
        if ($rp.sitecode) {
            $invalidSiteCodes += $rp.siteCode
        }
        else {
            # No SiteCode prop means this is a remoteSQLVM for an existing or new primary/cas
            $SiteServer = $list2 | Where-Object ($_.RemoteSQLVM -eq $rp.vmName -and $_.Role -in "CAS", "Primary")
            if ($SiteServer) {
                if ($SiteServer.SiteCode) {
                    $invalidSiteCodes += $SiteServer.SiteCode
                }
            }
        }
    }

    foreach ($siteCode in $invalidSiteCodes | where-object { $_ }) {
        #write-host "Removing $sitecode"
        $allSiteCodes = $allSiteCodes | where-object { $_ -ne $siteCode }
    }

    return $allSiteCodes
}

Function Get-ValidSiteCodesForWSUS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $CurrentVM
    )

    $siteCodes = @()

    $list2 = Get-List2 -deployConfig $Config

    $topLevelSiteServers = ($list2 | where-object { $_.role -in ("CAS", "Primary") -and -not $_.ParentSiteCode })


    foreach ($item in $topLevelSiteServers) {

        $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $item.SiteCode -and $_.VmName -ne $CurrentVM.VmName }

        if ($existingSUP) {
            if ($item.role -ne "CAS") {
                # If we have an existingSUP on the top level, add the site code only if its a Primary Top Level Site
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            # We have an existingSUP on the top level.. Add all children of the top level site
            $childSiteServers = ($list2 | where-object { $_.role -in ("CAS", "Primary") -and $_.ParentSiteCode -eq $item.SiteCode })
            foreach ($item2 in $childSiteServers) {
                $sitecodes += "$($item2.SiteCode) ($($item2.vmName), $($item2.Network) Parent: $($item.SiteCode))"
            }
        }
        else {
            # We do not have an existing SUP on the top level.. Only add the TopLevel as options. No Children Allowed.
            $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
        }
    }

    return $sitecodes

}
Function Get-SiteCodeForWSUS {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $true, HelpMessage = "Config")]
        [Object] $Config

    )

    $siteCodes = Get-ValidSiteCodesForWSUS

    $result = $null
    $Options = [ordered]@{ "X" = "StandAlone WSUS" }
    while (-not $result) {
        $result = Get-Menu2 -MenuName "Site Code selection for SUP" -Prompt "Select sitecode to connect SUP to" -OptionArray $siteCodes -CurrentValue $CurrentValue -AdditionalOptions $options -Test:$false -Split
    }
    if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
        return $null
    }
    else {
        return $result
    }

}
#   #Get-PSCallStack | out-host
#   while ($valid -eq $false) {
#       $siteCodes = @()
#       $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Primary" } )
#       if ($tempSiteCodes) {
#           foreach ($tempSiteCode in $tempSiteCodes) {
#               $siteCodes += "$($tempSiteCode.SiteCode) (New Primary Server - $($tempSiteCode.vmName))"
#           }
#       }
#
#       $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "CAS" })
#       if ($tempSiteCodes) {
#           foreach ($tempSiteCode in $tempSiteCodes) {
#               if (-not [String]::IsNullOrWhiteSpace($tempSiteCode)) {
#                   $siteCodes += "$($tempSiteCode.SiteCode) (New CAS Server - $($tempSiteCode.vmName))"
#               }
#           }
#       }
#       if ($Domain) {
#
#           foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object SiteCode, Network, VmName -Unique)) {
#               $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
#           }
#
#           foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object SiteCode, Network, VmName -Unique)) {
#               $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
#           }
#           if ($siteCodes.Length -eq 0) {
#               Write-Host
#               write-host "No valid site codes are eligible to accept this SUP"
#               return $null
#           }
#           else {
#               #write-host $siteCodes
#           }
#           $result = $null
#           $Options = [ordered]@{ "X" = "StandAlone WSUS" }
#           while (-not $result) {
#               $result = Get-Menu -Prompt "Select sitecode to connect SUP to" -OptionArray $siteCodes -CurrentValue $CurrentValue -AdditionalOptions $options -Test:$false -Split
#           }
#           if ($result -and ($result.ToLowerInvariant() -eq "x")) {
#               return $null
#           }
#           else {
#               return $result
#           }
#       }
#   }
#}

Function Get-SiteCodeForDPMP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [string] $Domain
    )
    $valid = $false
    $ConfigToCheck = $Global:Config
    #Get-PSCallStack | out-host
    while ($valid -eq $false) {
        $siteCodes = @()
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "CAS" } )
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                $siteCodes += "$($tempSiteCode.SiteCode) (New CAS VM - $($tempSiteCode.vmName))"
            }
        }
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Primary" } )
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                $siteCodes += "$($tempSiteCode.SiteCode) (New Primary VM - $($tempSiteCode.vmName))"
            }
        }
        $tempSiteCodes = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Secondary" })
        if ($tempSiteCodes) {
            foreach ($tempSiteCode in $tempSiteCodes) {
                if (-not [String]::IsNullOrWhiteSpace($tempSiteCode)) {
                    $siteCodes += "$($tempSiteCode.SiteCode) (New Secondary VM - $($tempSiteCode.vmName))"
                }
            }
        }
        if ($Domain) {
            #$siteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object -ExpandProperty SiteCode -Unique
            #$siteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Secondary" | Select-Object -ExpandProperty SiteCode -Unique
            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "Secondary" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }

            foreach ($item in (Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object SiteCode, Network, VmName -Unique)) {
                $sitecodes += "$($item.SiteCode) ($($item.vmName), $($item.Network))"
            }
            $siteCodes = $siteCodes | Get-Unique

            if ($siteCodes.Length -eq 0) {
                Write-Host
                write-host "No valid site codes are eligible to accept this Site System"
                return $null
            }
            else {
                #write-host $siteCodes
            }
            $result = $null
            while (-not $result) {
                $result = Get-Menu2 -MenuName "Site System SiteCode Selection" -Prompt "Select sitecode to connect Site System to" -OptionArray $siteCodes -CurrentValue $CurrentValue -Test:$false -Split
            }
            if ($result -and ($result.ToLowerInvariant() -eq "x") -or ($result.ToLowerInvariant() -eq "escape")) {
                return $null
            }
            else {
                return $result
            }
        }
    }
}
Function Get-SiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $ConfigToCheck = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [bool] $test = $true
    )

    if ($property.Role -eq "SiteSystem") {
        #Get-PSCallStack | out-host
        $result = Get-SiteCodeForDPMP -CurrentValue $CurrentValue -Domain $configToCheck.vmoptions.domainName
    }

    if ($property.Role -eq "WSUS") {
        $result = Get-SiteCodeForWSUS -CurrentValue $CurrentValue -Config $configToCheck
    }

    if (-not $result) {
        return
    }
    if ($result.ToLowerInvariant() -eq "x") {
        $property.PsObject.Members.Remove($name)
    }
    else {
        $property | Add-Member -MemberType NoteProperty -Name $name -Value $result -Force
        #$property."$name" = $result
    }
    try {
        if ($test -and (Get-TestResult -config $configToCheck -SuccessOnWarning)) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
    catch {
        return
    }
}


Function Get-SqlVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $SQLVer = Get-Menu2 -MenuName "Sql Server Version Selection for $($property.VmName)" "Select SQL Version" $($Common.Supported.SqlVersions) $CurrentValue -Test:$false
        if ($SQLVer -eq "ESCAPE") {
            return
        }
        $property."$name" = $SQLVer
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}

Function Get-ForestTrustMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )


    $domains = @(Get-List -Type UniqueDomain)
    $domains += "NONE"
    $valid = $false
    while ($valid -eq $false) {
        $result = Get-Menu2 -MenuName "Forest Trust Menu for domain $($global:Config.vmoptions.DomainName)" "Select Forest to Trust" $($domains) $CurrentValue -Test:$false
        if ($result -eq "ESCAPE") {
            return
        }
        $property."$name" = $result

        if ($result -ne "NONE") {
            $remoteCA = (get-list -type vm -DomainName $result | Where-Object { $_.InstallCA })
            if ($remoteCA) {
                Write-OrangePoint "Domain $result already has a CA. Disabling CA in this domain"
                $property.InstallCA = $false
            }
            Get-TargetSitesForDomain $property $result
        }
        else {
            $property.psobject.properties.remove('externalDomainJoinSiteCode')
            $property.InstallCA = $true
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}

Function Get-TargetSitesForDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Domain To get Target Sites")]
        [string] $Domain
    )

    $targetPrimaries = @((Get-list -type vm -DomainName $Domain | Where-Object { $_.Role -eq "Primary" -or $_.Role -eq "Secondary" } ).SiteCode)

    if ($targetPrimaries) {
        $targetPrimaries += "NONE"
        $valid = $false
        while ($valid -eq $false) {
            #$property.externalDomainJoinSiteCode
            $result = Get-Menu2 -MenuName "Remote domain Management Server for this domains clients" -Prompt "Select Target site code in $Domain to configure to manage clients in this domain" -OptionArray $($targetPrimaries) -CurrentValue "NONE" -Test:$false
            if ($result -eq "ESCAPE") {
                if ($property.externalDomainJoinSiteCode) {
                    $result = $property.externalDomainJoinSiteCode
                }
                else {
                    $result = "NONE"
                }
                $property | Add-Member -MemberType NoteProperty -Name "externalDomainJoinSiteCode" -Value $result -Force
                return
            }   
            $property | Add-Member -MemberType NoteProperty -Name "externalDomainJoinSiteCode" -Value $result -Force

            if (Get-TestResult -SuccessOnWarning) {
                return
            }
        }
    }
}

Function Set-SiteServerLocalSql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine
    )

    $ConfigToModify = $global:config
    if ($null -eq $virtualMachine.sqlVersion) {

        $SqlVersion = "SQL Server 2022"
        if ($ConfigToModify.domainDefaults.DefaultSqlVersion) {
            $SqlVersion = $ConfigToModify.domainDefaults.DefaultSqlVersion
        }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value $SqlVersion -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlPort' -Value "1433" -force
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $true -force
        
    }
    if ($virtualMachine.Role -eq "WSUS" -or $virtualMachine.Role -eq "SiteSystem") {
        $virtualMachine.virtualProcs = 4
        $virtualMachine.memory = "6GB"
    }
    else {
        $virtualMachine.virtualProcs = 8
        $virtualMachine.memory = "10GB"
    }


    if ($null -eq $virtualMachine.additionalDisks) {
        $disk = [PSCustomObject]@{"E" = "600GB"; "F" = "100GB" }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
    }
    else {

        if ($null -eq $virtualMachine.additionalDisks.E) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "E" -Value "600GB" -force
        }
        if ($null -eq $virtualMachine.additionalDisks.F) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "F" -Value "200GB" -force
        }
    }

    if ($null -ne $virtualMachine.remoteSQLVM) {
        $SQLVM = $ConfigToModify.VirtualMachines | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        #$SQLVM = $virtualMachine.remoteSQLVM
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
        if ($SQLVM.OtherNode) {
            Remove-VMFromConfig -vmName $SQLVM.OtherNode -Config $global:config
        }
        Remove-VMFromConfig -vmName $SQLVM.vmName -Config $global:config

    }

}

Function Set-SiteServerRemoteSQL {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine,
        [Parameter(Mandatory = $true, HelpMessage = "VmName")]
        [string] $vmName
    )

    if ($null -ne $virtualMachine.sqlVersion) {
        $virtualMachine.PsObject.Members.Remove('sqlVersion')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceName')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceDir')
        $virtualMachine.PsObject.Members.Remove('sqlPort')
        if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
        }
    }
    $virtualMachine.memory = "4GB"
    $virtualMachine.dynamicMinRam = "4GB"
    if ($global:Config.domainDefaults.UseDynamicMemory) {
        $virtualMachine.dynamicMinRam = "1GB"
    }

    $virtualMachine.virtualProcs = 4
    if ($null -ne $virtualMachine.additionalDisks.F) {
        $virtualMachine.additionalDisks.PsObject.Members.Remove('F')
    }
    if ($null -ne $virtualMachine.remoteSQLVM) {
        $oldSQLVM = $global:Config.VirtualMachines | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        {
            if ($oldSQLVM) {
                $oldSQLVM.PsObject.Members.Remove('installRP')
            }
        }
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
    }
   
    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'remoteSQLVM' -Value $vmName -force
    $newSQLVM = $global:Config.VirtualMachines | Where-Object { $_.vmName -eq $vmName }
    if ($newSQLVM) {
        if (-not $newSQLVM.InstallRP) {
            if ($newSQLVM.role -ne "SQLAO") {
                $newSQLVM | Add-Member -MemberType NoteProperty -Name 'installRP' -Value $false -force
                $newSQLVM | Add-Member -MemberType NoteProperty -Name 'InstallSMSProv' -Value $false -force
            }
        }
        $oldSQLVMName = $virtualMachine.VmName
        if ($oldSQLVM) {
            $oldSQLVMName = $oldSQLVM.VmName
        }
        if ($virtualMachine.wsusDataBaseServer) {
            if ($oldSQLVMName -eq $virtualMachine.wsusDataBaseServer) {
                if ($newSQLVM.role -ne "SQLAO") {
                    $virtualMachine.wsusDataBaseServer = $newSQLVM.vmName
                }
                else {
                    $virtualMachine.wsusDataBaseServer = "WID"
                }
            }
        }
    }
}
Function Get-WsusDBName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = [ordered]@{ 
            "L"  = "Local SQL (Installed on this Server)" 
            "HL" = "Add a SQL instance to this VM that WSUS will use"
        }
        $additionalOptions += [ordered] @{ 
            "N"  = "Remote SQL (Create a new SQL VM)" 
            "HN" = "Add a new VM with SQL installed that WSUS will use"
        }
        $additionalOptions += [ordered] @{ 
            "W"  = "Use Local WID for SQL"
            "HW" = "WSUS will use WID (Windows Internal Database) for its database"
        }



        $validVMs = @($Global:Config.virtualMachines | Where-Object { ($_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion) } | Select-Object -ExpandProperty vmName)

        $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $Global:Config -SiteCode $property.siteCode -type VM

        $sql = Get-SqlServerForSiteCode -siteCode $property.SiteCode -deployConfig $Global:Config -type VM
        if (-not $ActiveVM.InstallSUP) {
            if (-not $sql.InstallSUP) {
                $validVMs += $($sql.vmName)
            }
        }
        $validVMs = $validVMs | Get-Unique

        $result = Get-Menu2 -MenuName "Select WSUS SQL" -Prompt "Select SQL Options" -OptionArray $($validVMs) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return "REFRESH"
        }
        switch ($result.ToLowerInvariant()) {
            "l" {
                Set-SiteServerLocalSql $property
                $property."$name" = $property.VmName
                $valid = $true
            }
            "n" {
                $VMname = $($property.SiteCode) + "WSUSSQL"
                Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $VMname -network:$property.network
                $property."$name" = $VMname
                $valid = $true
                #Set-SiteServerRemoteSQL $property $name
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
            }
            "w" {
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
                $property."$name" = "WID"
                $valid = $true
            }
            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    continue
                }
                $property."$name" = $result
                $valid = $true
                $property.psobject.properties.remove('sqlversion')
                $property.psobject.properties.remove('sqlInstanceDir')
                $property.psobject.properties.remove('sqlInstanceName')
                $property.psobject.properties.remove('sqlPort')
                $property.psobject.properties.remove('SqlServiceAccount')
                $property.psobject.properties.remove('SqlAgentAccount')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $property | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }
            }
        }

    }
}
Function Get-remoteSQLVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = [ordered]@{ 
            "L"  = "Local SQL (Installed on this Server)"
            "HL" = "Add a SQL instance to this VM"
        }

        $validVMs = $Global:Config.virtualMachines | Where-Object { ($_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion) -or ($_.Role -eq "SQLAO" -and $_.OtherNode ) } | Select-Object -ExpandProperty vmName

        $CASVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "CAS" }
        $PRIVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }

        if ($Property.Role -eq "CAS") {
            if ($null -ne $PRIVM.remoteSQLVM) {
                #Write-Verbose "Checking "
                $validVMs = $validVMs | Where-Object { $_ -ne $PRIVM.remoteSQLVM }
            }
        }
        if ($Property.Role -eq "Primary") {
            if ($null -ne $CASVM.remoteSQLVM) {
                $validVMs = $validVMs | Where-Object { $_ -ne $CASVM.remoteSQLVM }
            }
        }

        #if (($validVMs | Measure-Object).Count -eq 0) {

        if ($property.Role -eq "WSUS") {
            $additionalOptions += [ordered] @{ 
                "R"  = "Remote SQL"
                "HR" = "Opens a menu to select a Remote SQL VM to use"
            }
            $additionalOptions += [ordered] @{ 
                "W"  = "Use Local WID for SQL"
                "HW" = "WSUS will use WID (Windows Internal Database) as its database"
            }
            Write-Log -Activity -NoNewLine "WSUS SQL Server Options"
        }
        else {
            $additionalOptions += [ordered] @{ 
                "N"  = "Remote SQL (Create a new SQL VM)"
                "HN" = "A new VM with SQL installed will be added to the configuration"
            }
            $additionalOptions += [ordered] @{ 
                "A"  = "Remote SQL Always On Cluster (Create a new SQL Cluster)" 
                "HA" = "A pair of SQLAO VMs will be added to the configuration"
            }
            Write-Log -Activity -NoNewLine "CM SQL Server Options"
        }
        #}
       
        $result = Get-Menu2 -MenuName "Select SQL" -Prompt "Select SQL Options" -OptionArray $($validVMs) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return
        }
        switch ($result.ToLowerInvariant()) {
            "l" {
                Set-SiteServerLocalSql $property
            }
            "n" {
                $name = $($property.SiteCode) + "SQL"
                Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name -network:$property.network
                Set-SiteServerRemoteSQL $property $name
            }
            "r" {
                $sqlVMName = select-RemoteSQLMenu -ConfigToModify $global:config -currentValue $property.remoteSQLVM
                if ($sqlVMName -eq "ESCAPE") {
                    return
                }
                #$name = $($property.SiteCode) + "SQL"
                #Add-NewVMForRole -Role "SqlServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name -network:$property.network
                Set-SiteServerRemoteSQL $property $sqlVMName
            }
            "a" {
                $name1 = $($property.SiteCode) + "SQLAO1"
                $name2 = $($property.SiteCode) + "SQLAO2"
                Add-NewVMForRole -Role "SQLAO" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name1 -Name2 $Name2 -network:$property.network -SiteCode $($property.SiteCode)
                Set-SiteServerRemoteSQL $property $name1
            }
            "w" {
                $virtualMachine.PsObject.Members.Remove('sqlVersion')
                $virtualMachine.PsObject.Members.Remove('sqlInstanceName')
                $virtualMachine.PsObject.Members.Remove('sqlPort')
                $virtualMachine.PsObject.Members.Remove('sqlInstanceDir')
                $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
                if ($global:Config.domainDefaults.IncludeSSMSOnNONSQL -eq $false) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'installSSMS' -Value $false -force
                }

            }
            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    continue
                }
                Set-SiteServerRemoteSQL $property $result
            }
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($null -ne $name) {
                if ($property."$name" -eq $CurrentValue) {
                    return
                }
            }
        }
    }
}

Function Get-domainUser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $prefix = $Global:Config.VmOptions.Prefix
    $users = get-list2 -DeployConfig $Global:Config | 
    Where-Object { $_.domainUser } | 
    Select-Object -ExpandProperty domainUser -Unique |
    ForEach-Object {
        if ($prefix -and $_.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $_.Substring($prefix.Length)
        }
        else {
            $_
        }
    } |
    Sort-Object -Unique

    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = @{ "N" = "New User" }


        $result = Get-Menu2 -MenuName "Domain User Selection" -Prompt "Select User" -OptionArray $($users) -CurrentValue $CurrentValue -Test:$false -additionalOptions $additionalOptions -return

        if (-not $result -or $result -eq "ESCAPE") {
            return
        }
        switch ($result.ToLowerInvariant()) {
            "n" {
                $result = Read-Host2 -Prompt "Enter desired Username"
            }

            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    if (-not $CurrentValue) {
                        $property.psobject.properties.remove($name)
                    }
                    else {
                        $property | Add-Member -MemberType NoteProperty -Name $name -Value $CurrentValue -force
                    }
                    return
                }
            }
        }
        if ($null -ne $name) {
            $property | Add-Member -MemberType NoteProperty -Name $name -Value $result -force
        }
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($null -ne $name) {
                if ($property."$name" -eq $CurrentValue) {
                    return
                }
            }
        }
    }
}

Function Get-CMVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    $noteColor = $Global:Common.Colors.GenConfigTip

    if ($Global:Config.cmOptions.OfflineSCP) {   
        write-host2 -ForegroundColor $noteColor "Note: "-NoNewLine
        write-host2 "SCP is in OFFLINE mode. Only baseline versions will be shown"
    }


    $cmVersions = @()
    foreach ($cmVersion in $($Common.Supported.CmVersions)) {

        switch ($cmVersion) {
            "current-branch" {
                $latest = Get-CMLatestBaselineVersion
                $cmVersions += "$cmVersion (Installs $latest [Latest Baseline])"
            }

            "Tech-preview" {
                #$cmVersions += "$cmVersion (Installs the latest tech preview version of CM)"
            }

            default {
                $baselineVersion = (Get-CMBaselineVersion -CMVersion $cmVersion).baselineVersion
                if ($Global:Config.cmOptions.OfflineSCP) {                    
                    if ($baselineVersion -eq $cmVersion) {
                        $cmVersions += "$cmVersion (baseline)"
                    }
                }
                else {
                    if ($baselineVersion -eq $cmVersion) {
                        $cmVersions += "$cmVersion (baseline)"
                    }
                    else {
                        $cmVersions += "$cmVersion (Upgrade from $baselineVersion)"
                    }
                }
            }
        }

    }

    while ($valid -eq $false) {
        $CMVer = Get-Menu2 -MenuName "CM Version" -Prompt "Select ConfigMgr Version" -optionArray $($cmVersions) -CurrentValue $CurrentValue -Test:$false -split
        if ($CMVer -eq "ESCAPE") {
            return
        }
        $property."$name" = $CMVer
        if (Get-TestResult -SuccessOnWarning) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}
Function Get-RoleMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $DC = Get-List -type VM -domain $global:config.vmOptions.domainName | Where-Object { $_.Role -eq "DC" }
        if ($DC) {
            $role = Get-Menu2 -MenuName "VM role Selection menu for $($property.VmName)" -prompt "Select Role" -optionArray $(Select-RolesForExistingList) -currentValue $CurrentValue -Test:$false
            if ($role -eq "ESCAPE") {
                return
            }
            $property."$name" = $role
        }
        else {
            Write-Log -Activity -NoNewLine "Role Selection menu for $($property.VmName)"
            $role = Get-Menu2 -MenuName "Role Selection menu for $($property.VmName)" -prompt "Select Role" -optionArray $(Select-RolesForNewList) -currentValue $CurrentValue -Test:$false
            if ($role -eq "ESCAPE") {
                return
            }
            $property."$name" = $role
        }

        # If the value is the same.. Do not delete and re-create the VM
        if ($property."$name" -eq $value) {
            # return false if the VM object is still viable.
            return $false
        }

        # In order to make sure the default params like SQLVersion, CMVersion are correctly applied.  Delete the VM and re-create with the same name.
        Remove-VMFromConfig -vmName $property.vmName -ConfigToModify $global:config
        Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config -Name $property.vmName -Quiet:$true

        # We cant do anything with the test result, as our underlying object is no longer in config.
        Get-TestResult -config $global:config -SuccessOnWarning | out-null

        # return true if the VM is deleted.
        return $true
    }
}
