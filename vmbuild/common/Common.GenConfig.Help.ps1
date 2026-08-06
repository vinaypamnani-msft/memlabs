# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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
        "PushCMClientToClients" { "Default value for the per-VM 'pushClient' flag on newly added client-OS DomainMember VMs (Windows 10/11)." }
        "PushCMClientToServers" { "Default value for the per-VM 'pushClient' flag on newly added server-OS DomainMember VMs (Windows Server)." }
        "PushCMClientToSiteSystems" { "Default value for the per-VM 'pushClient' flag on newly added site system VMs (Primary, CAS, Secondary, SiteSystem, PassiveSite). Off by default since site servers install the client locally during CM setup." }
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
        "WsusImportBaseline" { "When True (default), pre-seed the WSUS category catalog by importing the shipped 'wsusutil export' baseline cab -- much faster than a first Microsoft Update sync. Set to False to skip the cab and perform a natural Microsoft Update sync instead. No effect on OfflineSUP configs or when no baseline cab is shipped." }
        "EnableBLM" { "Enable BitLocker Management. Configures GPO, enables the BLM site feature, and deploys a BitLocker policy to encrypt client OS drives via the MP recovery service." }
        "PrePopulateObjects" { "This setting will pre-populate a number of objects in the CM database, such as packages, scripts, OSD Task Sequences, Baselines, etc." }
        # Not seeded into any default cmOptions block on purpose -- it only appears here if a
        # config already carries it, which keeps it out of every normal lab's menu.
        "ReproPolicyBulkCount" { "REPRO ONLY. Creates this many contentless packages + Available deployments to All Systems during perfloading, purely to pad the machine policy set. Widens the window during which a client's policy is INCOMPLETE after a purge-and-re-request (site upgrade, client reinstall, ResetPolicy) -- which is when the Policy Platform can wrongly treat previously-intended settings as orphaned and revert them, running their remediation scripts. Requires PrePopulateObjects. Leave unset (or 0) for normal labs. See tools\Watch-PolicyChurn.ps1." }

        # VM

        "vmName" { "Change the name of the VM" }
        "Role" { "Change the VM's role. Changing this is not recommended." }
        "Memory" { "Change the starting and Maximum memory for this VM." }
        "DynamicMinRam" { "Enables Dynamic Memory.  Sets the Minimum amount of RAM." }
        "VirtualProcs" { "Change the number of virtual processors assigned to this VM" }
        "OperatingSystem" { "Change the Operating System that will be installed on this VM" }
        "tpmEnabled" { "Enable the virtual TPM on this VM." }
        "enableRDP" { "Install xrdp + a lightweight XFCE desktop on this Linux VM via cloud-init, open TCP/3389 in ufw, and add an RDCMan entry that auto-logs in as vmbuildadmin using the lab's LocalAdmin password. Use this when you need a GUI on the Proxy VM (browser, file manager, etc.)." }
        "joinDomain" { "On first boot, install realmd/SSSD and join this Linux VM to the lab AD domain using vmOptions.adminName + the host's LocalAdmin password. Waits up to 20min for the DC's DNS to come up, then runs 'realm join'. Domain Admins get sudo NOPASSWD. Enabling this also assigns a dedicated AD user (user<N>, created in AD like a Windows client's domainUser) that gets NOPASSWD sudo on the box and becomes the default RDCMan/mRemoteNG SSH/RDP login; disabling removes it. Leave off for a standalone DHCP-only Linux VM." }
        "useProxy" { "Route this VM's outbound HTTP/HTTPS through the domain's Squid Proxy VM. CM site systems also get Set-CMSiteSystemServer -UseProxy. Requires a Proxy VM." }
        "pushClient" { "Site code to push the ConfigMgr client from, or No. Picking a site assigns this VM's subnet to that site's boundary group (a boundary is created for the subnet). All VMs on the same subnet must push from the same site. Defaults are seeded from domainDefaults.PushCMClientToClients (client OS), PushCMClientToServers (server OS DomainMembers), or PushCMClientToSiteSystems (site system roles) and resolved to the matching site (or the first Primary)." }
        "BitLocker" { "Enable BitLocker encryption on this VM. Adds the computer to the ConfigMgr BLM collection so the BitLocker policy targets it. Requires tpmEnabled and cmOptions.EnableBLM." }
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
        "cmOptions" { "ConfigMgr options for this top-level site server (version, license, install, push, PKI, SCP, BLM). Press Enter to edit." }

        default { "Help Missing for $text" }
    }
}
