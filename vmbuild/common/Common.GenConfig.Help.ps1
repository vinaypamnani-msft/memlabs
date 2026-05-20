# Common.GenConfig.Help.ps1
#
# Get-GenericHelp - resolves a property/label string (as displayed in the
# generic property editor menu) to a one-line help string shown in the
# help pane beside the menu.
#
# Input is usually "PropertyName = currentValue"; we split on '=' and trim,
# so callers can pass either the raw label or the full menu text.
#
# Lives here (was inline in genconfig.ps1) so genconfig.ps1 stays focused on
# menu flow instead of help-text tables.

function Get-GenericHelp {
    param(
        $text
    )

    switch (($text -split "=")[0].Trim()) {
        "DeploymentType" { "Selects the default type of deployment, Primary or Hierarchy" }
        "DomainName" { "Change the FQDN of the domain" }
        "CMVersion" { "Select which version of ConfigMgr to install. Ignored if ConfigMgr is not being installed" }
        "Network" { "Select the Network VMs will join.  Only /24 ranges are acceptable. " }
        "DefaultServerOS" { "When adding new server VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultClientOS" { "When adding new client VMs, they will default to this OS. Can be changed on individual VMs." }
        "DefaultSqlVersion" { "When adding new SQL instances, they will default to this version. Can be changed on individual VMs." }
        "UseDynamicMemory" { "Enable Dynamic Memory on each new VM. Can be overridden per VM via the dynamicMinRam setting" }
        "IncludeClients" { "Disabling this will prevent the 2 automatic client VMs from appearing in a new domain config" }
        "IncludeSSMSOnNONSQL" { "Disabling this will prevent SQL Management Studio from getting installed on NON-SQL servers" }
        "Done with changes" { "All the settings look good.  Move onto next menu" }

        # Global VM

        "Prefix" { "Change the prefix of all machines in the domain.  This is used to ensure unique machine names across all domains." }
        "AdminName" { "Change the default administrator name for all machines and domains. Not recommended to change." }
        "BasePath" { "Change the location to save hyper-v VHDX and other files. Not recommended to change." }
        "domainNetBiosName" { "Change the NetBIOS name of the domain. This will result in a disjoint namespace if it does not match the FQDN" }
        "locale" { "If you have configured _localeConfig.json, you can change the default language of your VMs via language packs" }
        "timeZone" { "Change the timezone of all new VMs deployed in this session." }

        # Global CM

        "Version" { "Change the version of CM to install. By default, we select the newest baseline version." }
        "Install" { "Disable this setting to prevent CM from installing.  This is useful to pre-stage your VMs, but perform a custom installation by hand" }
        "EVALVersion" { "Install the EVAL license for ConfigMgr.  This will expire in 6 months." }
        "UsePKI" { "Automatically set up a complete PKI infrastructure, and use HTTPS for all CM roles, including DP/MP/SUP/RP. Also configurable via PKI Settings menu." }
        "UseOfflineRoot" { "Deploy a two-tier PKI: a Standalone Offline Root CA (workgroup, powered off after setup) issues a certificate for an Enterprise Subordinate CA. Configured via PKI Settings menu." }
        "OfflineSCP" { "Install the SCP role in Offline mode.  This will prevent CM from updating. Useful for offline repros" }
        "OfflineSUP" { "Install the SUP role in Offline mode.  This will prevent WSUS from talking to Microsoft Update to get patch information" }
        "PushClientToDomainMembers" { "Disable this setting to prevent client push from CM.  Clients will not be installed automatically" }
        "EnableBLM" { "Enable BitLocker Management. Configures GPO, enables the BLM site feature, and deploys a BitLocker policy to encrypt client OS drives via the MP recovery service." }
        "PrePopulateObjects" { "This setting will pre-populate a number of objects in the CM database, such as packages, scripts, OSD Task Sequences, Baselines, etc." }

        # VM

        "vmName" { "Change the name of the VM" }
        "Role" { "Change the VM's role. Changing this is not recommended." }
        "Memory" { "Change the starting and Maximum memory for this VM." }
        "DynamicMinRam" { "Enables Dynamic Memory.  Sets the Minimum amount of RAM." }
        "VirtualProcs" { "Change the number of virtual processors assigned to this VM" }
        "OperatingSystem" { "Change the Operating System that will be installed on this VM" }
        "tpmEnabled" { "Enable the virtual TPM on this VM." }
        "BitLocker" { "Enable BitLocker encryption on this VM. Moves the computer to the BLM OU so BitLocker GPO applies. Requires tpmEnabled and cmOptions.EnableBLM." }
        "InstallCA" { "Installs and configures a Certificate Authority on this VM" }
        "ForestTrust" { "This option allows you to create a Forest Trust between this domain, and another already deployed domain." }
        "Add Additional Disk" { "Adds another VHDX to this VM" }
        "Remove Last Additional Disk" { "Removes the last VHDX added to this machine" }
        "Remove this VM from config" { "'Deletes' the VM. Since it's not actually deployed yet, just prevents it from being deployed." }
        "SiteCode" { "Changes the sitecode for this site" }
        "InstallSSMS" { "SQL Server Management Studio will be installed on this VM" }
        "InstallDP" { "Install the Distribution Point role on this VM" }
        "InstallMP" { "Install the Management Point role on this VM" }
        "InstallRP" { "Install SSRS and the Reporting point role on this VM" }
        "InstallSUP" { "Install WSUS and the Software Update Point role on this VM" }
        "InstallSMSProv" { "Install an additional SMS Provider on this machine (Along with the ADK)" }
        "wsusContentDir" { "Change the location where WSUS will store its content" }
        "wsusDataBaseServer" { "Change the database WSUS will use.  Can be WID, or a local or remote SQL Server" }
        "Add SQL" { "Adds a SQL Instance to this VM" }
        "Remove SQL" { "Removes SQL from this VM" }
        "sqlVersion" { "Change the version of SQL installed on this VM" }
        "sqlInstanceName" { "Change the instance name that SQL will use when installing" }
        "sqlInstanceDir" { "Change the location where this instance of SQL will be installed" }
        "sqlPort" { "Change the port number this instance of SQL will use" }
        "SqlAgentAccount" { "Change the account sql will use for the SQL Agent service. Account will be created in the domain." }
        "SqlServiceAccount" { "Change the account sql will use for the SQL Server service. Account and SPNs will be created in the domain." }
        "useFakeWSUSServer" { "Adds a fake WSUS server to the registry, which will prevent the machine from automatically updating from windows update" }
        "Add domain user as admin on this machine" { "Creates an Active Directory user, and assigns it as the primary admin of this machine" }
        "Remove domainUser from this machine" { "Removes the Active Directory user assigned as admin to this machine" }
        "DomainUser" { "Change the name of the domain user assigned as admin on this machine" }
        "RemoteContentLibVM" { "This is the FileServer VM that will be used for the remote ContentLib" }
        "cmInstallDir" { "This is the location in the VM where CM will be installed" }
        "AdditionalDisks" { "This is the list of additional disks created during deployment. You can configure their sizes here." }
        "SiteName" { "This is the display name of the site in configuration manager" }
        "RemoteSQLVM" { "This is the name of the SQL VM that will host databases used by roles on this VM" }
        "AlwaysOnGroupName" { "Display name for the SQL AO Availability Group" }
        "AlwaysOnListenerName" { "DNS Name of the listener used by SQL AO. This would be the name you use to connect to SQL" }
        "ClusterName" { "Internal name used by Clustering to setup the SQL AO cluster. Must be unique" }
        "fileServerVM" { "FileServer VM used by SQL AO for its quorum data" }
        "OtherNode" { "This is a link to the other node of the SQL AO cluster. Not recommended to change" }
        "vmGeneration" { "Sets the Hyper-V VM generation. Only available on OSD clients, all other VMs are gen 2" }
        "ParentSiteCode" { "Sets the parent site code for siteservers or sitesystems" }
        "pullDPSourceDP" { "Sets the source Distribution point for this PullDP" }
        "InstallPatchMyPC" { "Installs the PatchMyPC service on this VM. Must be installed on the Top-Level SUP" }
        "PatchMyPCFileServer" { "Sets the FileServer that PatchMyPC will use to store its updates" }

        default { "Help Missing for $text" }
    }
}
