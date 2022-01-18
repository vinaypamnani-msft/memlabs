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