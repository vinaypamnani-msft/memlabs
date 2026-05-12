function select-PullDPMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null,
        [Parameter(Mandatory = $true, HelpMessage = "CurrentVM")]
        [object] $CurrentVM
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if ((Get-ListOfPossibleDPMP -Config $ConfigToModify -siteCode $CurrentVM.SiteCode).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions += @{ "N" = "Create a DP VM" }

    while ([string]::IsNullOrWhiteSpace($result) -or $result -eq "ESCAPE") {
        Write-Log -Activity "Pull DP Source DP selection" -NoNewLine
        $result = Get-Menu2 -MenuName "Pull DP Source DP selection" -prompt "Select Source DP VM" -optionArray $(Get-ListOfPossibleDPMP -Config $ConfigToModify -siteCode $CurrentVM.SiteCode) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "SiteSystem" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true -SiteCode $CurrentVM.SiteCode
            if ($result) {
                write-Log "Added new DPMP '$result' for SiteCode $($currentVM.SiteCode)" -Success
            }
            else {
                write-Log "Failed to add new DPMP for SiteCode $($currentVM.SiteCode)" -Failure
            }
        }
    }
    return $result
}
function select-RemoteSQLMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if ((Get-ListOfPossibleSQLServers -Config $ConfigToModify).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions = @{}

    $additionalOptions += @{ 
        "N"  = "Create new SQL Server" 
        "HN" = "Adds a new SQL VM to configuration"
    }

    while ([string]::IsNullOrWhiteSpace($result)) {
        Write-Log -Activity -NoNewLine "Remote SQL Server Selection"
        $result = Get-Menu2 -MenuName "Remote SQL Server Selection" -prompt "Select SQL VM" -optionArray $(Get-ListOfPossibleSQLServers -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    if ($result -eq "ESCAPE") {
        return "ESCAPE"
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "SqlServer" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function select-FileServerMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Display HA message")]
        [bool] $HA = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "CurrentValue")]
        [string] $CurrentValue = $null
    )
    #Get-PSCallStack | Out-Host
    $result = $null
    if (((Get-ListOfPossibleFileServers -Config $ConfigToModify).Count -eq 0) -and [string]::IsNullOrWhiteSpace($CurrentValue)) {
        $result = "n"
    }

    $additionalOptions = @{}
    if ($HA) {
        $additionalOptions += @{ 
            "N"  = "Create new FileServer to host Content Library (Needed for HA)"
            "HN" = "ContentLib must be moved to a remote server to enable High Availability"
        }
    }
    else {
        $additionalOptions += @{
            "N"  = "Create a New FileServer VM"
            "HN" = "SQL Always On needs a quorum share. This will be stored on a FileServer" 
        }
    }
    while ([string]::IsNullOrWhiteSpace($result) ) {
        #Allow ESCAPE to pass thru.. handled by caller
        $result = Get-Menu2 -MenuName "Fileserver selection.  FileServer is needed for Remote ContentLib (HA), and Quorum for SQLAO" -prompt "Select FileServer VM" -optionArray $(Get-ListOfPossibleFileServers -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "FileServer" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function Get-ListOfPossibleSQLServers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config
    )
    $SQLList = @()
    $SQL = $Config.virtualMachines | Where-Object { $_.sqlVersion }
    foreach ($item in $SQL) {
        $existing = @()
        $existing += $Config.virtualMachines | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item.vmName -eq $_.vmName) }
        if (-not $existing) {
            $SQLList += $item.vmName
        }
    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $SQLFromList = get-list -type VM -domain $domain | Where-Object { $_.sqlVersion }
        foreach ($item in $SQLFromList) {
            $existing = @()
            $existing += get-list -type VM -domain $domain | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item.vmName -eq $_.vmName) }
            $existing += $Config.virtualMachines | Where-Object { ($_.Role -eq "WSUS" -and ($_.RemoteSQLVM -eq $item.vmName)) -or ($_.InstallSUP -and $item -eq $_.vmName) }
            if (-not $existing) {
                $SQLList += $item.vmName
            }
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $SQLList
}
function Get-ListOfPossibleFileServers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config
    )
    $FSList = @()
    $FS = $Config.virtualMachines | Where-Object { $_.role -eq "FileServer" }
    foreach ($item in $FS) {
        $FSList += $item.vmName
    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $FSFromList = get-list -type VM -domain $domain | Where-Object { $_.role -eq "FileServer" }
        foreach ($item in $FSFromList) {
            $FSList += $item.vmName
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $FSList
}

function Get-ListOfPossibleDPMP {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [string] $siteCode


    )
    $FSList = @()
    $FS = $Config.virtualMachines | Where-Object { $_.InstallDP -eq $true -and -not $_.enablePullDP -and $_.SiteCode -eq $SiteCode }
    foreach ($item in $FS) {

        $FSList += $item.vmName

    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $FSFromList = get-list -type VM -domain $domain | Where-Object { $_.InstallDP -eq $true -and -not $_.enablePullDP -and $_.SiteCode -eq $SiteCode }
        foreach ($item in $FSFromList) {
            $FSList += $item.vmName
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $FSList
}


function show-NewVMMenu {

    param (
        [string]$role,
        [string]$SiteCode
    )

    write-log -Verbose "show-NewVMMenu called with role='$role' siteCode='$SiteCode'"
    if (-not $role) {
        $role = Select-RolesForExisting -enhance:$true
        if (-not $role) {
            return
        }
        if ($role -eq "H") {
            $role = "PassiveSite"
        }
        if ($role -eq "L") {
            $role = "Linux"
        }
    }

    $parentSiteCode = Get-ParentSiteCodeMenu -role $role -CurrentValue $null -Domain $Global:Config.vmOptions.domainName

    if ($role -eq "Secondary") {
        if (-not $parentSiteCode) {
            return
        }
    }

    if ($role -eq "PassiveSite") {
        $existingPassive = @()
        $existingSS = @()


        $existingPassive += Get-List2 -deployConfig $global:config | Where-Object { $_.Role -eq "PassiveSite" }
        $existingSS += Get-List2 -deployConfig $global:config | Where-Object { $_.Role -eq "CAS" -or $_.Role -eq "Primary" }

        $existingSS = $existingSS | Where-Object { $_ }
        $existingPassive = $existingPassive | Where-Object { $_ }

        $PossibleSS = @()
        foreach ($item in $existingSS) {
            if ($existingPassive.SiteCode -contains $item.Sitecode) {
                continue
            }
            $PossibleSS += $item
        }

        if ($PossibleSS.Count -eq 0) {
            Write-Host
            Write-Host "No siteservers found that are eligible for HA"
            return
        }
        if (-not $SiteCode) {
            $result = Get-Menu2 -MenuName "Enable CM High Availability" -Prompt "Select sitecode to expand to HA" -OptionArray $PossibleSS.Sitecode -Test $false -return
            if ([string]::IsNullOrWhiteSpace($result) -or $result -eq "ESCAPE") {
                return
            }
            $SiteCode = $result
        }
    }
    #$os = Select-OSForNew -Role $role

    $machineName = Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config  -parentSiteCode $parentSiteCode -SiteCode $siteCode -ReturnMachineName $true
    if ($role -eq "DC") {
        while ($true) {
            $domain = select-NewDomainName
            if (-not [string]::IsNullOrEmpty($domain) -and $domain -ne "ESCAPE") {   
                $Global:Config.vmOptions.domainName = $domain
            }
            else {
                continue
            }
            $Global:Config.vmOptions.prefix = get-PrefixForDomain -Domain $($Global:Config.vmOptions.domainName)
            $netbiosName = $Global:Config.vmOptions.domainName.Split(".")[0]
            $Global:Config.vmOptions.DomainNetBiosName = $netbiosName
            break
        }
    }
    Get-TestResult -SuccessOnError | out-null
    if (-not $machineName) {
        return
    }
    write-log -verbose "show-NewVMMenu returned machineName '$machineName' for role '$role'"
    return $machineName
}
