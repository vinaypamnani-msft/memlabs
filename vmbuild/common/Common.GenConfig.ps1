Function Get-SupportedOperatingSystemsForRole {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $role
    )

    $ServerList = $Common.Supported.OperatingSystems | Where-Object { $_ -like 'Server*' }
    $ClientList = $Common.Supported.OperatingSystems | Where-Object { $_ -notlike 'Server*' }
    $AllList = $Common.Supported.OperatingSystems
    switch ($role) {
        "DC" { return $ServerList }
        "CAS" { return $ServerList }
        "CAS and Primary" { return $ServerList }
        "Primary" { return $ServerList }
        "Secondary" { return $ServerList }
        "FileServer" { return $ServerList }
        "SQLAO" { return $ServerList }
        "DPMP" { return $ServerList }
        "DomainMember" { return $AllList }
        "DomainMember (Server)" { return $ServerList }
        "DomainMember (Client)" { return $ClientList }
        "WorkgroupMember" { return $AllList }
        "InternetClient" { return $ClientList }
        "AADClient" { return $ClientList }
        "OSDClient" { return $null }
        default {
            return $AllList
        }
    }
    return $AllList
}

Function Read-SingleKeyWithTimeout {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 10,
        [Parameter(Mandatory = $false, HelpMessage = "Valid Keys")]
        [string[]] $ValidKeys,
        [Parameter(Mandatory = $false, HelpMessage = "Prompt")]
        [string] $Prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Returns the string BACKSPACE on backspace")]
        [switch] $backspace
    )


    Function Write-Prompt {
        param (
            [Parameter(Mandatory = $true, HelpMessage = "color")]
            [string] $color

        )
        [int]$charsToDelete = $Prompt.Length + $charsToDeleteNextTime

        #Write-Host -NoNewline ("`b" * $charsToDelete)
        $deleteChars = ("`b" * $charsToDelete)
        if ($timeout -ne 0) {
            if ($timeoutLeft -le 3) {
                Write-Host ($deleteChars + "[") -NoNewline
                write-Host -Foregroundcolor Red $timeoutLeft -NoNewline
                Write-Host "]" -NoNewline
            }
            else {
                write-Host ($deleteChars + "[" + $timeoutLeft + "]") -NoNewline
            }
            $deleteChars = ""
            $charsToDeleteNextTime = "[$timeoutLeft]".Length
        }
        Write-Host -NoNewline -ForegroundColor $color ($deleteChars + $Prompt)
        return $charsToDeleteNextTime
    }

    $key = $null
    $secs = 0
    $charsToDeleteNextTime = 0
    if ($Prompt) {
        if ($timeout) {
            Write-Host "[$timeout]" -NoNewline
            $charsToDeleteNextTime = "[$timeout]".Length
        }
        Write-Host $Prompt -NoNewline
    }
    $i = 0
    start-sleep -Milliseconds 200
    $host.ui.RawUI.FlushInputBuffer()
    While ($secs -le ($timeout * 40)) {
        $timeoutLeft = [Math]::Round(($timeout) - $secs / 40, 0)
        if ([Console]::KeyAvailable) {
            $key = $host.UI.RawUI.ReadKey()
            $host.ui.RawUI.FlushInputBuffer()
            if ($key.VirtualKeyCode -eq 13) {
                return $null
            }
            if ($key.VirtualKeyCode -eq 8) {
                if ($backspace) {
                    Write-Host -NoNewline (" `b `b")
                    return "BACKSPACE"
                }
                else { continue }
            }

            if ($key.Character) {
                if ($ValidKeys) {
                    if ($key.Character.ToString() -in $ValidKeys) {
                        return $key.Character.ToString()
                    }
                    else {
                        Write-Host -NoNewline ("`b `b")
                    }
                }
                else {
                    #$key | out-host
                    return $key.Character.ToString()
                }
            }
            else {
                $key = $null
            }
        }
        if ($Prompt) {
            switch (($i++ % 64) / 16) {
                0 { $charsToDeleteNextTime = Write-Prompt -Color Green }
                1 { $charsToDeleteNextTime = Write-Prompt -Color Red }
                2 { $charsToDeleteNextTime = Write-Prompt -Color Yellow }
                3 { $charsToDeleteNextTime = Write-Prompt -Color Blue }
            }
        }
        #Write-Host -NoNewline ("`b `b{0}" -f '/?\|'[($i++ % 4)])
        start-sleep -Milliseconds 25
        if ($timeout -ne 0) {
            #infinite wait
            $secs++
        }
    }

    if (-not $key) {
        return $null
    }

}


Function Show-StatusEraseLine {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "role")]
        [string] $data,
        [Parameter(Mandatory = $false, HelpMessage = "role")]
        [switch] $indent
    )
    if ($indent) {
        Write-Host "  " -NoNewline
    }
    Write-Host $data -NoNewline
    start-Sleep -seconds 2 | out-null
    Write-Host "`r" -NoNewline
    #Write-GreenCheck "Check Point Complete for ADA-DC1" -ForeGroundColor Green
}

function ConvertTo-DeployConfigEx {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config to Convert")]
        [object] $deployConfig
    )


    $deployConfigEx = $deployConfig | ConvertTo-Json -depth 5 | ConvertFrom-Json
    foreach ($thisVM in $deployConfigEx.virtualMachines) {

        $cm_svc = "cm_svc"
        $accountLists = [pscustomobject]@{
            SQLSysAdminAccounts = @()
            LocalAdminAccounts  = @($cm_svc)
            WaitOnDomainJoin    = @()
            DomainAccounts      = @($deployConfig.vmOptions.adminName, "cm_svc", "vmbuildadmin", "administrator")
            DomainAdmins        = @($deployConfig.vmOptions.adminName)
            SchemaAdmins        = @($deployConfig.vmOptions.adminName)
        }
        $thisParams = [pscustomobject]@{}
        if ($thisVM.domainUser) {
            $accountLists.LocalAdminAccounts += $thisVM.domainUser
        }

        #Get the current network from get-list or config
        $thisVMObject = Get-VMFromList2 -deployConfig $deployConfig -vmName $thisVM.vmName
        if ($thisVMObject.network) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "vmNetwork" -Value $thisVMObject.network -Force
        }
        else {
            $thisParams | Add-Member -MemberType NoteProperty -Name "vmNetwork" -Value $deployConfig.vmOptions.network -Force
        }

        $SQLAO = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" }

        switch ($thisVM.role) {
            "FileServer" {
                if ($SQLAO) {
                    foreach ($sql in $SQLAO) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $sql -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                    }
                }
            }

            "DC" {
                if ($SQLAO) {
                    $DomainAccountsUPN = @()
                    $DomainComputers = @()
                    foreach ($sql in $SQLAO) {
                        if ($sql.OtherNode) {

                            $ClusterName = $sql.ClusterName

                            $DomainAccountsUPN += @($sql.SqlServiceAccount, $sql.SqlAgentAccount)

                            $DomainComputers += @($ClusterName)
                        }
                    }

                    $DomainAccountsUPN = $DomainAccountsUPN | Select-Object -Unique
                    $DomainComputers = $DomainComputers | Select-Object -Unique
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAccountsUPN" -Value $DomainAccountsUPN -Force
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DomainComputers" -Value  $DomainComputers -Force
                }
                $accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.domainUser } | Select-Object -ExpandProperty domainUser -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SQLAgentAccount } | Select-Object -ExpandProperty SQLAgentAccount -Unique
                #$accountLists.DomainAccounts += get-list2 -DeployConfig $deployConfig | Where-Object { $_.SqlServiceAccount } | Select-Object -ExpandProperty SqlServiceAccount -Unique
                $accountLists.DomainAccounts = $accountLists.DomainAccounts | Select-Object -Unique

                $ServersToWaitOn = @()
                $thisPSName = $null
                $thisCSName = $null
                foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in "Primary", "Secondary", "CAS", "PassiveSite", "SQLAO" -and -not $_.hidden }) {
                    $ServersToWaitOn += $vm.vmName
                    if ($vm.Role -eq "Primary") {
                        $thisPSName = $vm.vmName
                        if ($vm.ParentSiteCode) {
                            $thisCSName = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $vm.ParentSiteCode
                        }
                    }
                    if ($vm.Role -eq "CAS") {
                        $thisCSName = $vm.vmName
                    }
                }

                $thisParams | Add-Member -MemberType NoteProperty -Name "ServersToWaitOn" -Value $ServersToWaitOn -Force
                if ($thisPSName) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "PSName" -Value $thisPSName -Force
                }
                if ($thisCSName) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "CSName" -Value $thisCSName -Force
                }
                if ($thisVM.hidden) {
                    $DC = get-list -type VM -DomainName $deployConfig.vmOptions.DomainName | Where-Object { $_.Role -eq "DC" }
                    $addr = $dc.Network.Substring(0, $dc.Network.LastIndexOf(".")) + ".1"
                    $gateway = $dc.Network.Substring(0, $dc.Network.LastIndexOf(".")) + ".200"
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCIPAddress" -Value $addr  -Force
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCDefaultGateway" -Value $gateway  -Force
                }
                else {
                    #This is Okay.. since the vmOptions.network for the DC is correct
                    $addr = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf(".")) + ".1"
                    $gateway = $deployConfig.vmOptions.network.Substring(0, $deployConfig.vmOptions.network.LastIndexOf(".")) + ".200"
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCIPAddress" -Value $addr  -Force
                    $thisParams | Add-Member -MemberType NoteProperty -Name "DCDefaultGateway" -Value $gateway  -Force
                }

            }
            "SQLAO" {
                $AlwaysOn = Get-SQLAOConfig -deployConfig $deployConfig -vmName $thisVM.vmName
                if ($AlwaysOn) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "SQLAO" -Value $AlwaysOn -Force
                }


            }
            "PassiveSite" {
                $ActiveVM = Get-ActiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
                if ($ActiveVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "ActiveNode" -Value $ActiveVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $ActiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    if ($ActiveVM.Role -eq "CAS") {
                        $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $ActiveVM.siteCode }
                        if ($primaryVM) {
                            Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                            $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                            if ($PassiveVM) {
                                Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                            }
                        }
                    }
                }
            }
            "CAS" {
                $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $thisVM.siteCode }
                if ($primaryVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin
                    }
                }
            }
            "Primary" {
                $reportingSecondaries = @()
                $reportingSecondaries += ($deployConfig.virtualMachines | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }).siteCode
                $reportingSecondaries += (get-list -type vm -domain $deployConfig.vmOptions.domainName | Where-Object { $_.Role -eq "Secondary" -and $_.parentSiteCode -eq $thisVM.siteCode }).siteCode
                $reportingSecondaries = $reportingSecondaries | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
                $thisParams | Add-Member -MemberType NoteProperty -Name "ReportingSecondaries" -Value $reportingSecondaries -Force




                $AllSiteCodes = $reportingSecondaries
                $AllSiteCodes += $thisVM.siteCode


                foreach ($dpmp in $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -in $AllSiteCodes -and -not $_.hidden }) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $dpmp  -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                }

                $SecondaryVM = $deployConfig.virtualMachines | Where-Object { $_.parentSiteCode -eq $ThisVM.siteCode -and $_.role -eq "Secondary" -and -not $_.hidden }

                if ($SecondaryVM) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $SecondaryVM  -accountLists $accountLists -deployConfig $deployconfig -WaitOnDomainJoin
                }
                # If we are deploying a new CAS at the same time, record it for the DSC
                $CASVM = $deployConfig.virtualMachines | Where-Object { $_.role -in "CAS" -and $thisVM.ParentSiteCode -eq $_.SiteCode }
                if ($CASVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "CSName" -Value $CASVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $CASVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin

                    $CASPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $CASVM.siteCode -type VM
                    if ($CASPassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $CASPassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }
                }

            }
            "Secondary" {
                $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $thisVM.parentSiteCode }
                if ($primaryVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    $PassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                    if ($PassiveVM) {
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }
                }
            }
        }

        #add the SiteCodes and Subnets so DC can add ad sites, and primary can setup BG's
        if ($thisVM.Role -eq "DC" -or $thisVM.Role -eq "Primary") {
            $sitesAndNetworks = @()
            $siteCodes = @()
            # foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in "Primary", "Secondary" -and -not $_.hidden }) {
            #     $sitesAndNetworks += [PSCustomObject]@{
            #         SiteCode = $vm.siteCode
            #         Subnet   = $deployConfig.vmOptions.network
            #     }
            #     if ($vm.siteCode -in $siteCodes) {
            #         Write-Log "Error: $($vm.vmName) has a sitecode already in use in config by another Primary or Secondary"
            #     }
            #     $siteCodes += $vm.siteCode
            # }
            foreach ($vm in get-list2 -DeployConfig $deployConfig | Where-Object { $_.role -in "Primary", "Secondary" }) {
                $sitesAndNetworks += [PSCustomObject]@{
                    SiteCode = $vm.siteCode
                    Subnet   = $vm.network
                }
                if ($vm.siteCode -in $siteCodes) {
                    Write-Log "Error: $($vm.vmName) has a sitecode already in use in hyper-v by another Primary or Secondary"
                }
                $siteCodes += $vm.siteCode
            }
            $thisParams | Add-Member -MemberType NoteProperty -Name "sitesAndNetworks" -Value $sitesAndNetworks -Force
        }


        #Get the CU URL, and SQL permissions
        if ($thisVM.sqlVersion) {
            $sqlFile = $Common.AzureFileList.ISO | Where-Object { $_.id -eq $thisVM.sqlVersion }
            $sqlCUUrl = $sqlFile.cuURL
            $thisParams | Add-Member -MemberType NoteProperty -Name "sqlCUURL" -Value $sqlCUUrl -Force
            $backupSolutionURL = "https://ola.hallengren.com/scripts/MaintenanceSolution.sql"
            $thisParams | Add-Member -MemberType NoteProperty -Name "backupSolutionURL" -Value $backupSolutionURL -Force

            $DomainAdminName = $deployConfig.vmOptions.adminName
            $DomainName = $deployConfig.parameters.domainName
            $DName = $DomainName.Split(".")[0]
            $cm_admin = "$DNAME\$DomainAdminName"
            $vm_admin = "$DNAME\vmbuildadmin"
            $accountLists.SQLSysAdminAccounts = @('NT AUTHORITY\SYSTEM', $cm_admin, $vm_admin, 'BUILTIN\Administrators')
            $SiteServerVM = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $thisVM.vmName }

            if (-not $SiteServerVM) {
                $OtherNode = $deployConfig.virtualMachines | Where-Object { $_.OtherNode -eq $thisVM.vmName }

                if ($OtherNode) {
                    $SiteServerVM = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $OtherNode.vmName }
                }
            }

            if (-not $SiteServerVM) {
                $SiteServerVM = Get-List -Type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.RemoteSQLVM -eq $thisVM.vmName }
            }
            if (-not $SiteServerVM -and $thisVM.Role -eq "Secondary") {
                $SiteServerVM = Get-PrimarySiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            }
            if (-not $SiteServerVM -and $thisVM.Role -in "Primary", "CAS") {
                $SiteServerVM = $thisVM
            }
            if ($SiteServerVM) {
                Add-VMToAccountLists -thisVM $thisVM -VM $SiteServerVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                $passiveNodeVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteServerVM.siteCode -type VM
                if ($passiveNodeVM) {
                    Add-VMToAccountLists -thisVM $thisVM -VM $passiveNodeVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                }

                if ($SiteServerVM.Role -eq "Primary") {
                    $CASVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "CAS" -and $_.SiteCode -eq $SiteServerVM.ParentSiteCode }
                    if ($CASVM) {
                        $thisParams | Add-Member -MemberType NoteProperty -Name "CAS" -Value $CASVM.vmName -Force
                        Add-VMToAccountLists -thisVM $thisVM -VM $CASVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                        $CASPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $CASVM.siteCode -type VM
                        if ($CASPassiveVM) {
                            Add-VMToAccountLists -thisVM $thisVM -VM $CASPassiveVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts  -LocalAdminAccounts   -WaitOnDomainJoin
                        }
                    }
                }

                if ($SiteServerVM.Role -eq "CAS") {
                    $primaryVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.parentSiteCode -eq $SiteServerVM.siteCode }
                    if ($primaryVM) {
                        $thisParams | Add-Member -MemberType NoteProperty -Name "Primary" -Value $primaryVM.vmName -Force
                        Add-VMToAccountLists -thisVM $thisVM -VM $primaryVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts -LocalAdminAccounts -WaitOnDomainJoin
                        $primaryPassiveVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $primaryVM.siteCode -type VM
                        if ($primaryPassiveVM) {
                            Add-VMToAccountLists -thisVM $thisVM -VM $primaryPassiveVM -accountLists $accountLists -deployConfig $deployconfig -SQLSysAdminAccounts  -LocalAdminAccounts   -WaitOnDomainJoin
                        }
                    }
                }
            }


        }

        #Get the SiteServer this VM's SiteCode reports to.  If it has a passive node, get that as -P
        if ($thisVM.siteCode) {
            $SiteServerVM = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
            $thisParams | Add-Member -MemberType NoteProperty -Name "SiteServer" -Value $SiteServerVM.vmName -Force
            Add-VMToAccountLists -thisVM $thisVM -VM $SiteServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            $passiveSiteServerVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.siteCode -type VM
            if ($passiveSiteServerVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "SiteServerPassive" -Value $passiveSiteServerVM.vmName -Force
                Add-VMToAccountLists -thisVM $thisVM -VM $passiveSiteServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            }
            #If we report to a Secondary, get the Primary as well, and passive as -P
            if ((get-RoleForSitecode -ConfigTocheck $deployConfig -siteCode $thisVM.siteCode) -eq "Secondary") {
                $PrimaryServerVM = Get-PrimarySiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.SiteCode -type VM
                if ($PrimaryServerVM) {
                    $thisParams | Add-Member -MemberType NoteProperty -Name "PrimarySiteServer" -Value $PrimaryServerVM.vmName -Force
                    Add-VMToAccountLists -thisVM $thisVM -VM $PrimaryServerVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts -WaitOnDomainJoin
                    $PassivePrimaryVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -siteCode $PrimaryServerVM.SiteCode -type VM
                    if ($PassivePrimaryVM) {
                        $thisParams | Add-Member -MemberType NoteProperty -Name "PrimarySiteServerPassive" -Value $PassivePrimaryVM.vmName -Force
                        Add-VMToAccountLists -thisVM $thisVM -VM $PassivePrimaryVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
                    }

                }
            }
        }
        #Get the VM Name of the Parent Site Code Site Server
        if ($thisVM.parentSiteCode) {
            $parentSiteServerVM = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServer" -Value $parentSiteServerVM.vmName -Force
            $passiveSiteServerVM = Get-PassiveSiteServerForSiteCode -deployConfig $deployConfig -SiteCode $thisVM.parentSiteCode -type VM
            if ($passiveSiteServerVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "ParentSiteServerPassive" -Value $passiveSiteServerVM.vmName -Force
            }
        }

        #If we have a passive server for a site server, record it here, only check config, as it couldnt already exist
        if ($thisVM.role -in "CAS", "Primary") {
            $passiveVM = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" -and $_.SiteCode -eq $thisVM.siteCode }
            if ($passiveVM) {
                $thisParams | Add-Member -MemberType NoteProperty -Name "PassiveNode" -Value $passiveVM.vmName -Force
                Add-VMToAccountLists -thisVM $thisVM -VM $PassiveVM -accountLists $accountLists -deployConfig $deployconfig -LocalAdminAccounts  -WaitOnDomainJoin
            }
        }


        $SQLSysAdminAccounts = $accountLists.SQLSysAdminAccounts | Sort-Object | Get-Unique
        if ($SQLSysAdminAccounts.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "SQLSysAdminAccounts" -Value $SQLSysAdminAccounts -Force
        }

        $WaitOnDomainJoin = $accountLists.WaitOnDomainJoin | Sort-Object | Get-Unique
        if ($WaitOnDomainJoin.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "WaitOnDomainJoin" -Value $WaitOnDomainJoin -Force
        }

        $LocalAdminAccounts = @()
        $LocalAdminAccounts += $accountLists.LocalAdminAccounts | Sort-Object | Get-Unique
        if ($LocalAdminAccounts.Count -gt 0) {
            $thisParams | Add-Member -MemberType NoteProperty -Name "LocalAdminAccounts" -Value $LocalAdminAccounts -Force
        }
        if ($thisVM.role -in "DC") {
            $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAccounts" -Value $accountLists.DomainAccounts -Force
            $thisParams | Add-Member -MemberType NoteProperty -Name "DomainAdmins" -Value $accountLists.DomainAdmins -Force
            $thisParams | Add-Member -MemberType NoteProperty -Name "SchemaAdmins" -Value $accountLists.SchemaAdmins -Force
        }

        #    $thisParams | ConvertTo-Json -Depth 5 | out-Host

        $thisVM | Add-Member -MemberType NoteProperty -Name "thisParams" -Value $thisParams -Force
    }
    return $deployConfigEx
}
