# Windows Feature to install for role
$featureRole = @("Distribution Point", "Management Point")

# SQL AO
if ($ThisVM.role -eq "SQLAO") {
    $featureRole += "SQLAO"
}

################

if ($IsServerOS) {

    WriteStatus InstallFeature {
        DependsOn = "[SetCustomPagingFile]PagingSettings"
        Status    = "Installing required windows features"
    }

    InstallFeatureForSCCM InstallFeature {
        Name      = "DummyName"
        Role      = $featureRole
        DependsOn = "[SetCustomPagingFile]PagingSettings"
    }

    WriteStatus WaitDomain {
        DependsOn = "[InstallFeatureForSCCM]InstallFeature"
        Status    = "Waiting for domain to be ready"
    }
}
else {
    WriteStatus WaitDomain {
        DependsOn = "[SetCustomPagingFile]PagingSettings"
        Status    = "Waiting for domain to be ready"
    }
}

WriteStatus OpenPorts {
    DependsOn = "[JoinDomain]JoinDomain"
    Status    = "Open required firewall ports"
}

OpenFirewallPortForSCCM OpenFirewall {
    DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
    Name      = "DomainMember"
    Role      = "DomainMember"
}

WriteStatus InstallDotNet {
    DependsOn = '[OpenFirewallPortForSCCM]OpenFirewall'
    Status    = "Installing .NET 4.8"
}

InstallDotNet4 DotNet {
    DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
    FileName    = "ndp48-x86-x64-allos-enu.exe"
    NetVersion  = "528040"
    Ensure      = "Present"
    DependsOn   = "[WriteStatus]InstallDotNet"
}

$addUserDependancy = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $deployConfig.thisParams.LocalAdminAccounts) {
            $i++
            $NodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$NodeName" {
                Name       = $user
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$NodeName"
        }