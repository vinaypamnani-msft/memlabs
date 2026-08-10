Configuration Phase8
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'TemplateHelpDSC', 'ActiveDirectoryDsc', 'ComputerManagementDsc', 'FailoverClusterDsc', 'AccessControlDsc', 'SqlServerDsc', 'CertificateDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json


    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # $CM (CMTP vs CMCB source folder) is resolved per-Node from the owning
    # VM's cmOptions so multi-hierarchy deploys with mixed CM versions stamp
    # the correct folder on each node. See CAS/Primary and DC Node blocks.

    # Strip domain prefix from credential username if present (the multi-node
    # DSC compilation path pre-prefixes with NetBIOS name, which would create
    # an invalid double-prefix like "FQDN\NetBIOS\user")
    $AdminUserName = $Admincreds.UserName
    if ($AdminUserName -match '\\') { $AdminUserName = ($AdminUserName -split '\\', 2)[1] }

    # Domain Creds
    $DomainName = $deployConfig.parameters.domainName
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)


    Node $AllNodes.Where{ $_.Role -eq 'FileServer' }.NodeName
    {

        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }

        WriteStatus Start {
            DependsOn = $nextDepend
            Status    = "Creating PMPCApps share in E:\PMPCApps"
        }

        File "PMPCApps" {
            DestinationPath = 'E:\PMPCApps'
            Type            = 'Directory'
            Ensure          = "Present"
            DependsOn       = $nextDepend
        }
        $nextDepend = "[File]PMPCApps"

        NTFSAccessEntry PMPCApps {
            Path              = 'E:\PMPCApps'
            AccessControlList = @(
                NTFSAccessControlList {
                    Principal          = "Everyone"
                    ForcePrincipal     = $false
                    AccessControlEntry = @(
                        NTFSAccessControlEntry {
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'FullControl'
                            Inheritance       = 'This folder subfolders and files'
                            Ensure            = 'Present'
                        }
                    )
                }
                            
                NTFSAccessControlList {
                    Principal          = "$netbiosName\$DomainAdminName"
                    ForcePrincipal     = $false
                    AccessControlEntry = @(
                        NTFSAccessControlEntry {
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'FullControl'
                            Inheritance       = 'This folder subfolders and files'
                            Ensure            = 'Present'
                        }
                    )
                }
            )
            DependsOn         = $nextDepend
        }
        $nextDepend = "[NTFSAccessEntry]PMPCApps"

        SmbShare "PMPCShare" {
            Name        = "PMPCApps"
            Path        = 'E:\PMPCApps'
            #Ensure                = "Present"
            Description = "Share for PMPC Apps"
            #FolderEnumerationMode = 'Unrestricted'
            FullAccess  = "Everyone"
            #ReadAccess            = "Everyone"
            DependsOn   = $nextDepend
        }
        $nextDepend = "[SmbShare]PMPCShare"


        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'SiteSystem' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }

        # --- PKI IIS web-server certificate (relocated here from Phase 3) -----
        # The Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab), so requesting these in Phase 3 dead-locked with
        # "No Certificate Authority could be found". By Phase 8 the CA exists, so
        # we request + bind the web cert here, gated BEFORE this node's main work
        # so it lands before the site's HTTPS flip (EnableHTTPS in ScriptWorkflow).
        # Same gate + logic as the old Phase 3 $AddIISCert block.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # $caVMCert only matches a CA VM built in THIS deploy. When adding a site system
        # to an EXISTING PKI domain the Enterprise CA already lives in AD (no InstallCA VM
        # here), so an empty $caVMCert must NOT suppress the web-server cert while UsePKI
        # is set -- otherwise the HTTPS MP MSI fails with error 25055.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $nextDepend = $null
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status = "Requesting IIS Certificate for PKI"
            }

            # Refresh the machine's Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (which grants Enroll on the CM
            # cert templates) WITHOUT a reboot: the DC adds this computer account to
            # that group in Phase 2, and every site server already reboots in Phase
            # 3 (IIS feature + .NET installs) AFTER the group is created, so by Phase
            # 8 the machine token is normally already current. Purging the machine
            # (0x3e7 = SYSTEM LUID) Kerberos ticket cache forces a fresh TGT on the
            # next auth -- the CMC enrollment DCOM call to the CA -- so enrollment is
            # deterministic even on a -StartPhase 8 re-run, with no reboot. Replaces
            # the old dedicated 'IISGroupReboot' RebootNow.
            # Group SIDs reach the PAC from the KDC when the TGT is issued, not from
            # Group Policy, so no gpupdate is involved.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }
            $nextDepend = "[Script]PkiRefreshGroupToken"

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run). Also prunes duplicate DP certs.
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $fn = 'ConfigMgr Client DistributionPoint Certificate'
                    $dupes = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.FriendlyName -eq $fn } | Sort-Object NotBefore -Descending)
                    if ($dupes.Count -gt 1) {
                        foreach ($old in $dupes | Select-Object -Skip 1) {
                            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }
            $nextDepend = "[Script]PkiRefreshTemplateCache"

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = $nextDepend
            }
            $nextDepend = "[CertReq]PkiWebCert"

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = $nextDepend
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $nextDepend = "[AddCertificateToIIS]PkiAddCert"

            if ($ThisVM.role -eq "Primary") {
                CertReq PkiDpCert {
                    Subject             = "Client DistributionPoint Cert"
                    SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                    KeyLength           = '2048'
                    Exportable          = $true
                    ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                    CertificateTemplate = 'ConfigMgrClientDistributionPointCertificate'
                    AutoRenew           = $true
                    FriendlyName        = 'ConfigMgr Client DistributionPoint Certificate'
                    KeyType             = 'RSA'
                    RequestType         = 'CMC'
                    DependsOn           = $nextDepend
                }
                $nextDepend = "[CertReq]PkiDpCert"

                CertificateExport PkiDpCertExport {
                    Type         = 'PFX'
                    FriendlyName = 'ConfigMgr Client DistributionPoint Certificate'
                    Path         = 'c:\temp\ConfigMgrClientDistributionPointCertificate.pfx'
                    Password     = $Admincreds
                    MatchSource  = $true
                    DependsOn    = $nextDepend
                }
                $nextDepend = "[CertificateExport]PkiDpCertExport"
            }
        }

        # WSUS categories baseline cab import for a REMOTE SUP site system.
        # When the SUP/WSUS role lives on a dedicated site system (this box)
        # rather than co-located on the site server, nobody else imports the
        # categories cab onto THIS WSUS host: InstallRoles (Primary/CAS) and
        # the Secondary Phase 8 path both run the import against their OWN
        # localhost WSUS, which a remote SUP is not. Without this block the
        # SUP's taxonomy stays at the ~17-row postinstall default until a slow
        # upstream categories sync lands (observed on a remote SUP: Phase 11
        # "WSUS initial sync (taxonomy) not populated [TaxonomyCats=17]").
        #
        # TIMING: WSUS on a dedicated SUP site system is installed + postinstalled
        # by CM when the owning site server's InstallRoles adds the SUP role.
        # InstallRoles runs EARLY in the site server's ScriptWorkflow -- after CM
        # setup but BEFORE perfloading kicks the first CM update sync. So we must
        # NOT wait for the site server's ScriptWorkflow=Completed (that's AFTER
        # perfloading -- too late to help). Instead, poll locally for WSUS to
        # become postinstalled (SUSDB ready) and run the import the moment it is,
        # in parallel with the site-server CM install, so the taxonomy is loaded
        # before/at perfloading's sync. The cab was already staged to
        # C:\staging\wsus\ in Phase <=7. Idempotent + non-fatal:
        # Start-WsusBaselineImportBackground short-circuits with
        # 'already-imported' / 'no-cab' / 'no-wsusutil' as appropriate.
        #
        # TOP-LEVEL ONLY: `wsusutil import` is valid ONLY for a SUP that syncs
        # from Microsoft Update (the cab is an MU-sourced catalog). A DOWNSTREAM
        # SUP (a child primary's / secondary's SUP that syncs from the CAS/parent
        # upstream WSUS) must NOT import -- it corrupts the local sync anchor and
        # the next upstream sync fails with UssInternalError ("updates pipeline
        # broken"). Downstream SUPs get their categories via replication from the
        # upstream. So gate on the owning site server being top-level (no
        # parentSiteCode). Start-WsusBaselineImportBackground also self-guards on
        # the live WSUS upstream config as a belt-and-suspenders.
        $supSiteServer = $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary") -and $_.Sitecode -eq $ThisVM.Sitecode } | Select-Object -First 1
        if ($ThisVM.installSUP -eq $true -and $supSiteServer -and -not $supSiteServer.parentSiteCode) {
            WriteStatus ImportWsusBaselineStatus {
                Status    = "Importing the WSUS categories baseline once CM postinstalls WSUS on this SUP."
                DependsOn = $nextDepend
            }

            Script ImportWsusBaseline {
                GetScript  = { @{ Result = '' } }
                TestScript = {
                    if (-not (Test-Path 'C:\staging\wsus\WsusCategoriesBaseline.cab')) { return $true }
                    try {
                        [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
                        $srv = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
                        return ($srv.GetUpdateCategories().Count -ge 100)
                    }
                    catch { return $false }
                }
                SetScript  = {
                    try { . C:\staging\DSC\phases\ScriptFunctions.ps1 } catch {}

                    # Poll for local WSUS readiness: WsusUtil.exe present AND the
                    # WSUS API answers (GetUpdateCategories throws until the SUSDB
                    # postinstall CM runs during InstallRoles has completed).
                    # Generous cap (~6h, polling 60s) because CM setup on the site
                    # server can take 1-3h before InstallRoles even adds the SUP
                    # role. Non-fatal on timeout.
                    $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
                    $ready = $false
                    for ($i = 0; $i -lt 360; $i++) {
                        if (Test-Path $wsusUtil) {
                            try {
                                [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
                                $srv = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
                                $null = $srv.GetUpdateCategories()
                                $ready = $true
                                break
                            }
                            catch {}
                        }
                        if (($i % 10) -eq 0) {
                            try { Write-DscStatus "[Phase8-SiteSystem] Waiting for CM to install/postinstall WSUS on this SUP before importing the categories baseline (waited $i min)..." -NoLog } catch {}
                        }
                        Start-Sleep -Seconds 60
                    }

                    if (-not $ready) {
                        try { Write-DscStatus "[Phase8-SiteSystem] WSUS not postinstalled after ~6h; skipping cab import (an upstream categories sync will populate the taxonomy later)." } catch {}
                        return
                    }

                    try {
                        Start-WsusBaselineImportBackground -Tag '[Phase8-SiteSystem]' | Out-Null
                        Wait-WsusBaselineImport -Tag '[Phase8-SiteSystem]'
                    }
                    catch {
                        # Non-fatal: an upstream categories sync will eventually
                        # populate the taxonomy, just slower. Don't break DSC.
                    }
                }
                DependsOn  = "[WriteStatus]ImportWsusBaselineStatus"
            }
            $nextDepend = '[Script]ImportWsusBaseline'
        }

        if ($ThisVM.InstallPatchMyPC) {
            $WaitFor = @()

            $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary") -and $_.Sitecode -eq $ThisVM.Sitecode }
            if ($serverToWait) {
                $WaitFor += $serverToWait.vmName        
            }
       
            $WaitFor = $WaitFor | Where-Object { $_ } | select-object -Unique
            if ($WaitFor) {
                WriteStatus WaitSCCM {
                    DependsOn = $nextDepend
                    Status    = "Waiting on $($WaitFor -join ",") to Complete"
                }

                WaitForAll WaitSCCM {
                    ResourceName     = '[WaitForEvent]WorkflowComplete'
                    NodeName         = $WaitFor
                    RetryIntervalSec = 5
                    RetryCount       = 7200
                    DependsOn        = $nextDepend
                }
                $nextDepend = '[WaitForAll]WaitSCCM'
            }
            InstallConsole InstallConsole {
                SiteServerFQDN = $serverToWait.VmName + "." + $DomainName
                CMInstallDir   = $serverToWait.CMInstallDir
                DependsOn      = $nextDepend                
            }
            $nextDepend = '[InstallConsole]InstallConsole'

            if ($serverToWait.RemoteSQLVM) {
                $SqlServer = $serverToWait.RemoteSQLVM
            }
            else {
                $SqlServer = $serverToWait.VmName
            }
            InstallPMPC InstallPMPC {
                DependsOn  = $nextDepend
                Path       = "C:\temp\pmpc.msi"
                URL        = $deployConfig.URLS.PMPC
                SiteCode   = $ThisVM.Sitecode
                SqlServer  = $SqlServer
                SiteServer = $serverToWait.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
                Ensure     = "Present"
            }
            $nextDepend = '[InstallPMPC]InstallPMPC'


        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'WSUS' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }

        # --- PKI IIS web-server certificate (relocated here from Phase 3) -----
        # The Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab), so requesting these in Phase 3 dead-locked with
        # "No Certificate Authority could be found". By Phase 8 the CA exists, so
        # we request + bind the web cert here, gated BEFORE this node's main work
        # so it lands before the site's HTTPS flip (EnableHTTPS in ScriptWorkflow).
        # Same gate + logic as the old Phase 3 $AddIISCert block.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # $caVMCert only matches a CA VM built in THIS deploy. When adding a site system
        # to an EXISTING PKI domain the Enterprise CA already lives in AD (no InstallCA VM
        # here), so an empty $caVMCert must NOT suppress the web-server cert while UsePKI
        # is set -- otherwise the HTTPS MP MSI fails with error 25055.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $nextDepend = $null
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status = "Requesting IIS Certificate for PKI"
            }

            # Refresh the machine's Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (which grants Enroll on the CM
            # cert templates) WITHOUT a reboot: the DC adds this computer account to
            # that group in Phase 2, and every site server already reboots in Phase
            # 3 (IIS feature + .NET installs) AFTER the group is created, so by Phase
            # 8 the machine token is normally already current. Purging the machine
            # (0x3e7 = SYSTEM LUID) Kerberos ticket cache forces a fresh TGT on the
            # next auth -- the CMC enrollment DCOM call to the CA -- so enrollment is
            # deterministic even on a -StartPhase 8 re-run, with no reboot. Replaces
            # the old dedicated 'IISGroupReboot' RebootNow.
            # Group SIDs reach the PAC from the KDC when the TGT is issued, not from
            # Group Policy, so no gpupdate is involved.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }
            $nextDepend = "[Script]PkiRefreshGroupToken"

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run). Also prunes duplicate DP certs.
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $fn = 'ConfigMgr Client DistributionPoint Certificate'
                    $dupes = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.FriendlyName -eq $fn } | Sort-Object NotBefore -Descending)
                    if ($dupes.Count -gt 1) {
                        foreach ($old in $dupes | Select-Object -Skip 1) {
                            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }
            $nextDepend = "[Script]PkiRefreshTemplateCache"

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = $nextDepend
            }
            $nextDepend = "[CertReq]PkiWebCert"

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = $nextDepend
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $nextDepend = "[AddCertificateToIIS]PkiAddCert"
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'SqlServer' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        $AgentJobSet = "C:\staging\DSC\SQLScripts\Disable-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\AgentJob-Get.sql"


        WriteStatus DisableAgentJob {
            Status = "Disabling Agent Jobs"
        }

        SqlScript 'DisableAgentJob' {
            Id                   = 'DisableAgentJob'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]DisableAgentJob'


        $WaitFor = @()
        $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $node.NodeName -and $_.role -in "CAS", "Primary" }
        if ($serverToWait) {
            $WaitFor += $serverToWait.vmName
        }
        if ($ThisVm.role -eq "SQLAO" -and (-not $ThisVM.OtherNode)) {
            $primaryNode = $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.OtherNode -eq $node.NodeName }
            $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName -and $_.role -in "CAS", "Primary" }
            if ($serverToWait) {
                $WaitFor += $serverToWait.vmName
            }
        }
        $WaitFor = $WaitFor | Where-Object { $_ } | select-object -Unique
        if ($WaitFor) {
            WriteStatus WaitSCCM {
                DependsOn = $nextDepend
                Status    = "Waiting on $($WaitFor -join ",") to Complete"
            }

            WaitForAll WaitSCCM {
                ResourceName     = '[WaitForEvent]WorkflowComplete'
                NodeName         = $WaitFor
                RetryIntervalSec = 5
                RetryCount       = 7200
                DependsOn        = $nextDepend
            }
            $nextDepend = '[WaitForAll]WaitSCCM'
        }

        $AgentJobSet = "C:\staging\DSC\SQLScripts\Enable-AgentJob-Set.sql"

        WriteStatus EnableAgentJob {
            Status = "Enabling Agent Jobs"
        }

        SqlScript 'EnableAgentJob' {
            Id                   = 'EnableAgentJob'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            DependsOn            = $nextDepend
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]EnableAgentJob'

        $CustomJobSet = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Set.sql"
        $CustomJobTest = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Test.sql"
        $CustomJobGet = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Get.sql"

        SqlScript 'MemLabsCustomization' {
            Id                   = 'MemLabsCustomization'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            SetFilePath          = $CustomJobSet
            TestFilePath         = $CustomJobTest
            GetFilePath          = $CustomJobGet
            DisableVariables     = $true
            DependsOn            = $nextDepend
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]MemLabsCustomization'
        
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)
        $PSName = $ThisVM.thisParams.PSName
        $CSName = $ThisVM.thisParams.CSName

        WriteStatus DelegateControl {
            Status = "Assigning permissions to Systems Management container"
        }

        $nextDepend = "[WriteStatus]DelegateControl"
        $waitOnDependency = @($nextDepend)
        foreach ($server in $ThisVM.thisParams.ServersToWaitOn) {

            VerifyComputerJoinDomain "WaitFor$server" {
                ComputerName = $server
                Ensure       = "Present"
                DependsOn    = $nextDepend
            }

            DelegateControl "Add$server" {
                Machine        = $server
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[VerifyComputerJoinDomain]WaitFor$server"
            }

            $waitOnDependency += "[DelegateControl]Add$server"
        }

        $nextDepend = $waitOnDependency

        if ($CSName -or $PSName) {
            # AD schema extensions are cumulative -- a single extension by the
            # highest-version top-level site server in this domain covers every
            # hierarchy. Prefer tech-preview (newer schema) over current-branch.
            # Falls back to legacy $CSName/$PSName if no top-levels are visible
            # in this deployConfig snapshot.
            $dcDomain = if ($ThisVM.Domain) { $ThisVM.Domain } else { $deployConfig.parameters.domainName }
            $domainTops = @($deployConfig.virtualMachines | Where-Object {
                    $_.Role -in 'CAS', 'Primary' -and -not $_.parentSiteCode -and
                    (-not $_.Domain -or $_.Domain -eq $dcDomain)
                })
            $schemaServer = $domainTops | Where-Object {
                $vmCmo = if ($_.cmOptions) { $_.cmOptions } else { $deployConfig.cmOptions }
                $vmCmo.version -eq 'tech-preview'
            } | Select-Object -First 1
            if (-not $schemaServer) { $schemaServer = $domainTops | Select-Object -First 1 }

            if ($schemaServer) {
                $parentName = $schemaServer.vmName
                $parentCmo = if ($schemaServer.cmOptions) { $schemaServer.cmOptions } else { $deployConfig.cmOptions }
            }
            else {
                $parentName = if ($CSName) { $CSName } else { $PSName }
                $parentVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $parentName } | Select-Object -First 1
                $parentCmo = if ($parentVM.cmOptions) { $parentVM.cmOptions } else { $deployConfig.cmOptions }
            }
            $CM = if ($parentCmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

            WriteStatus WaitExtSchema {
                DependsOn = $nextDepend
                Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName          = $parentName
                ExtFolder            = $CM
                Ensure               = "Present"
                DependsOn            = "[WriteStatus]WaitExtSchema"
                PsDscRunAsCredential = $DomainCreds
            }
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }


    Node $AllNodes.Where{ $_.Role -eq "Secondary" }.NodeName
    {

        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)
        $PSName = $ThisVM.thisParams.ParentSiteServer

        #$ParentSiteCode = ($deployConfig.virtualMachines | where-object { $_.vmName -eq ($Node.NodeName) }).ParentSiteCode
        #$PSName = ($deployConfig.virtualMachines | where-object { $_.Role -eq "Primary" -and $_.SiteCode -eq $ParentSiteCode }).vmName

        # --- PKI IIS web-server certificate (relocated here from Phase 3) -----
        # The Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab), so requesting these in Phase 3 dead-locked with
        # "No Certificate Authority could be found". By Phase 8 the CA exists, so
        # we request + bind the web cert here, gated BEFORE this node's main work
        # so it lands before the site's HTTPS flip (EnableHTTPS in ScriptWorkflow).
        # Same gate + logic as the old Phase 3 $AddIISCert block.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # $caVMCert only matches a CA VM built in THIS deploy. When adding a site system
        # to an EXISTING PKI domain the Enterprise CA already lives in AD (no InstallCA VM
        # here), so an empty $caVMCert must NOT suppress the web-server cert while UsePKI
        # is set -- otherwise the HTTPS MP MSI fails with error 25055.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $nextDepend = $null
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status = "Requesting IIS Certificate for PKI"
            }

            # Refresh the machine's Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (which grants Enroll on the CM
            # cert templates) WITHOUT a reboot: the DC adds this computer account to
            # that group in Phase 2, and every site server already reboots in Phase
            # 3 (IIS feature + .NET installs) AFTER the group is created, so by Phase
            # 8 the machine token is normally already current. Purging the machine
            # (0x3e7 = SYSTEM LUID) Kerberos ticket cache forces a fresh TGT on the
            # next auth -- the CMC enrollment DCOM call to the CA -- so enrollment is
            # deterministic even on a -StartPhase 8 re-run, with no reboot. Replaces
            # the old dedicated 'IISGroupReboot' RebootNow.
            # Group SIDs reach the PAC from the KDC when the TGT is issued, not from
            # Group Policy, so no gpupdate is involved.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }
            $nextDepend = "[Script]PkiRefreshGroupToken"

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run). Also prunes duplicate DP certs.
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $fn = 'ConfigMgr Client DistributionPoint Certificate'
                    $dupes = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.FriendlyName -eq $fn } | Sort-Object NotBefore -Descending)
                    if ($dupes.Count -gt 1) {
                        foreach ($old in $dupes | Select-Object -Skip 1) {
                            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }
            $nextDepend = "[Script]PkiRefreshTemplateCache"

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = $nextDepend
            }
            $nextDepend = "[CertReq]PkiWebCert"

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = $nextDepend
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $nextDepend = "[AddCertificateToIIS]PkiAddCert"
        }

        WriteStatus ODBCDriverInstall {            
            Status    = "Downloading and installing ODBC driver version 18"
            DependsOn = $nextDepend
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
            URL       = $deployConfig.URLS.ODBC
            Ensure    = "Present"
            DependsOn = "[WriteStatus]ODBCDriverInstall"
        }
        $nextDepend = "[InstallODBCDriver]ODBCDriverInstall"

        WriteStatus ReportBuilderInstall {            
            Status    = "Downloading and installing ODBC driver version 18"
            DependsOn = $nextDepend
        }

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus WaitPrimary {
            Status    = "Waiting for Site Server $PSName to finish configuration."
            DependsOn = $nextDepend
        }

        WaitForEvent WaitPrimary {
            MachineName   = $PSName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = $nextDepend
        }

        # WSUS categories baseline cab import for this Secondary's SUP.
        #
        # A Secondary's SUP is ALWAYS a DOWNSTREAM/replica that syncs from the
        # parent primary's SUP -- there is NO topology in which a Secondary is a
        # top-level Microsoft Update source. `wsusutil import` of the MU-sourced
        # cab is only valid for a top-level MU SUP; importing it into a downstream
        # WSUS stamps a foreign sync anchor and the next upstream sync fails with
        # UssInternalError (confirmed live on FAB-PS2DPMPSUP1). So this node must
        # NEVER import -- it is an UNCONDITIONAL, topology-based no-op.
        #
        # We do NOT rely on the function's runtime downstream-skip guard here: a
        # freshly-postinstalled WSUS defaults to SyncFromMicrosoftUpdate=True with
        # no upstream set, and CM only flips it to downstream when WCM reconciles
        # the SUP component -- so there is a window after WaitPrimary where the
        # runtime config still looks top-level. Gating on topology (Secondary =
        # always downstream) closes that race entirely. Categories replicate from
        # the upstream SUP instead. (Resource kept only for the DependsOn chain.)
        Script ImportWsusBaseline {
            GetScript  = { @{ Result = '' } }
            TestScript = { return $true }
            SetScript  = {
                try {
                    . C:\staging\DSC\phases\ScriptFunctions.ps1
                    Write-DscStatus '[Phase8-Secondary] Secondary SUP is always downstream - skipping WSUS cab import (categories replicate from the upstream SUP; importing the MU cab would corrupt the sync anchor / UssInternalError).'
                }
                catch { }
            }
            DependsOn  = "[WaitForEvent]WaitPrimary"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[Script]ImportWsusBaseline"
        }

        WriteStatus Complete {
            DependsOn = "[Script]ImportWsusBaseline"
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'CAS' -or $_.Role -eq "Primary" }.NodeName
    {
        $ThisMachineName = $Node.NodeName
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        #[System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        # Resolve per-VM CM version so each hierarchy uses its own source
        # folder when multiple top-level site servers are deployed together.
        $cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $CM = if ($cmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

        # --- PKI IIS web-server certificate (relocated here from Phase 3) -----
        # The Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab), so requesting these in Phase 3 dead-locked with
        # "No Certificate Authority could be found". By Phase 8 the CA exists, so
        # we request + bind the web cert here, gated BEFORE this node's main work
        # so it lands before the site's HTTPS flip (EnableHTTPS in ScriptWorkflow).
        # Same gate + logic as the old Phase 3 $AddIISCert block.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # $caVMCert only matches a CA VM built in THIS deploy. When adding a site system
        # to an EXISTING PKI domain the Enterprise CA already lives in AD (no InstallCA VM
        # here), so an empty $caVMCert must NOT suppress the web-server cert while UsePKI
        # is set -- otherwise the HTTPS MP MSI fails with error 25055.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $nextDepend = $null
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status = "Requesting IIS Certificate for PKI"
            }

            # Refresh the machine's Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (which grants Enroll on the CM
            # cert templates) WITHOUT a reboot: the DC adds this computer account to
            # that group in Phase 2, and every site server already reboots in Phase
            # 3 (IIS feature + .NET installs) AFTER the group is created, so by Phase
            # 8 the machine token is normally already current. Purging the machine
            # (0x3e7 = SYSTEM LUID) Kerberos ticket cache forces a fresh TGT on the
            # next auth -- the CMC enrollment DCOM call to the CA -- so enrollment is
            # deterministic even on a -StartPhase 8 re-run, with no reboot. Replaces
            # the old dedicated 'IISGroupReboot' RebootNow. NOTE: the site server's
            # own ScriptWorkflow (RegisterTaskScheduler, below) is unaffected -- no
            # reboot fires here anymore.
            # Group SIDs reach the PAC from the KDC when the TGT is issued, not from
            # Group Policy, so no gpupdate is involved.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }
            $nextDepend = "[Script]PkiRefreshGroupToken"

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run). Also prunes duplicate DP certs.
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $fn = 'ConfigMgr Client DistributionPoint Certificate'
                    $dupes = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.FriendlyName -eq $fn } | Sort-Object NotBefore -Descending)
                    if ($dupes.Count -gt 1) {
                        foreach ($old in $dupes | Select-Object -Skip 1) {
                            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }
            $nextDepend = "[Script]PkiRefreshTemplateCache"

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = $nextDepend
            }
            $nextDepend = "[CertReq]PkiWebCert"

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = $nextDepend
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $nextDepend = "[AddCertificateToIIS]PkiAddCert"

            if ($ThisVM.role -eq "Primary") {
                CertReq PkiDpCert {
                    Subject             = "Client DistributionPoint Cert"
                    SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                    KeyLength           = '2048'
                    Exportable          = $true
                    ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                    CertificateTemplate = 'ConfigMgrClientDistributionPointCertificate'
                    AutoRenew           = $true
                    FriendlyName        = 'ConfigMgr Client DistributionPoint Certificate'
                    KeyType             = 'RSA'
                    RequestType         = 'CMC'
                    DependsOn           = $nextDepend
                }
                $nextDepend = "[CertReq]PkiDpCert"

                CertificateExport PkiDpCertExport {
                    Type         = 'PFX'
                    FriendlyName = 'ConfigMgr Client DistributionPoint Certificate'
                    Path         = 'c:\temp\ConfigMgrClientDistributionPointCertificate.pfx'
                    Password     = $Admincreds
                    MatchSource  = $true
                    DependsOn    = $nextDepend
                }
                $nextDepend = "[CertificateExport]PkiDpCertExport"
            }
        }

        WriteStatus ADKInstall {
            Status    = "Downloading and installing ADK"
            DependsOn = $nextDepend
        }

        InstallADK ADKInstall {
            ADKPath              = "C:\temp\adksetup.exe"
            ADKWinPEPath         = "c:\temp\adksetupwinpe.exe"
            ADKDownloadPath      = $deployConfig.URLS.ADK
            ADKWinPEDownloadPath = $deployConfig.URLS.ADKPE         
            Ensure               = "Present"
            DependsOn            = "[WriteStatus]ADKInstall"
        }

        $nextDepend = "[InstallADK]ADKInstall"

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus ODBCDriverInstall {
            DependsOn = $nextDepend
            Status    = "Downloading and installing ODBC driver version 18"
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
            URL       = $deployConfig.URLS.ODBC
            Ensure    = "Present"
            DependsOn = "[WriteStatus]ODBCDriverInstall"
        }

        $nextDepend = "[InstallODBCDriver]ODBCDriverInstall"

        if (-not $ThisVM.thisParams.ParentSiteServer -and (-not $($ThisVM.hidden))) {

            $CMDownloadStatus = "Downloading Configuration Manager current branch (required baseline version)"
            if ($CM -eq "CMTP") {
                $CMDownloadStatus = "Downloading Configuration Manager technical preview"
            }

            if ($ThisVM.thisParams.cmDownloadVersion.downloadUrl) {

                WriteStatus DownLoadSCCM {
                    DependsOn = $nextDepend
                    Status    = $CMDownloadStatus
                }
                $nextDepend = "[WriteStatus]DownLoadSCCM"

                DownloadSCCM DownLoadSCCM {
                    CM            = $CM
                    CMDownloadUrl = $ThisVM.thisParams.cmDownloadVersion.downloadUrl
                    Ensure        = "Present"
                    DependsOn     = $nextDepend
                }
                $nextDepend = "[DownLoadSCCM]DownLoadSCCM"

                # URL-download CM: share the extracted C:\CMCB tree. For ISO CM the
                # host has already mounted the CM ISO and created the CMCB share
                # pointing at the DVD (Mount-CmIsoForPhase), so we must NOT re-point
                # it back at C:\CMCB here.
                FileReadAccessShare CMSourceSMBShare {
                    Name      = $CM
                    Path      = "c:\$CM"
                    DependsOn = $nextDepend
                }

                $nextDepend = "[FileReadAccessShare]CMSourceSMBShare"
            }
        }

        WriteStatus RunScriptWorkflow {
            DependsOn = $nextDepend
            Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
        }

        WriteFileOnce CMSvc {
            FilePath  = "$LogPath\cm_svc.txt"
            Content   = $Admincreds.GetNetworkCredential().Password
            DependsOn = "[WriteStatus]RunScriptWorkflow"
        }

        RegisterTaskScheduler RunScriptWorkflow {
            TaskName       = "ScriptWorkflow"
            ScriptName     = "ScriptWorkflow.ps1"
            ScriptPath     = $PSScriptRoot
            ScriptArgument = "$DeployConfigPath $LogPath"
            AdminCreds     = $CMAdmin
            Ensure         = "Present"
            DependsOn      = "[WriteFileOnce]CMSvc"
        }

        WaitForEvent WorkflowComplete {
            MachineName   = $ThisMachineName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = "[RegisterTaskScheduler]RunScriptWorkflow"
        }

        $nextDepend = "[WaitForEvent]WorkflowComplete"

        if ($thisVM.InstallPatchMyPC) {

            if ($ThisVM.RemoteSQLVM) {
                $SqlServer = $ThisVM.RemoteSQLVM
            }
            else {
                $SqlServer = $ThisVM.VmName
            }

            InstallPMPC InstallPMPC {
                DependsOn  = $nextDepend
                Path       = "C:\temp\pmpc.msi"
                URL        = $deployConfig.URLS.PMPC
                Ensure     = "Present"
                SiteCode   = $ThisVM.Sitecode
                SqlServer  = $SqlServer
                SiteServer = $ThisVM.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
            }
            $nextDepend = '[InstallPMPC]InstallPMPC'
            # No RebootNow here: pmpc.msi was installed with /norestart and the
            # forced reboot would kill the in-flight WSUS sync that perfloading
            # kicked off after AddProduct (sync runs async on WsusService.exe
            # and is not waited on by ScriptWorkflow). Any reboot PMPC actually
            # needs is picked up at the next natural restart.
        }

        WriteStatus Complete {
            DependsOn = $nextDepend 
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'PassiveSite' }.NodeName
    {
        $ThisMachineName = $Node.NodeName
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        # --- PKI IIS web-server certificate (relocated here from Phase 3) -----
        # The Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab), so requesting these in Phase 3 dead-locked with
        # "No Certificate Authority could be found". By Phase 8 the CA exists, so
        # we request + bind the web cert here, gated BEFORE this node's main work
        # so it lands before the site's HTTPS flip. Same gate + logic as the old
        # Phase 3 $AddIISCert block.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # $caVMCert only matches a CA VM built in THIS deploy. When adding a site system
        # to an EXISTING PKI domain the Enterprise CA already lives in AD (no InstallCA VM
        # here), so an empty $caVMCert must NOT suppress the web-server cert while UsePKI
        # is set -- otherwise the HTTPS MP MSI fails with error 25055.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $nextDepend = $null
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status = "Requesting IIS Certificate for PKI"
            }

            # Refresh the machine's Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (which grants Enroll on the CM
            # cert templates) WITHOUT a reboot: the DC adds this computer account to
            # that group in Phase 2, and every site server already reboots in Phase
            # 3 (IIS feature + .NET installs) AFTER the group is created, so by Phase
            # 8 the machine token is normally already current. Purging the machine
            # (0x3e7 = SYSTEM LUID) Kerberos ticket cache forces a fresh TGT on the
            # next auth -- the CMC enrollment DCOM call to the CA -- so enrollment is
            # deterministic even on a -StartPhase 8 re-run, with no reboot. Replaces
            # the old dedicated 'IISGroupReboot' RebootNow.
            # Group SIDs reach the PAC from the KDC when the TGT is issued, not from
            # Group Policy, so no gpupdate is involved.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }
            $nextDepend = "[Script]PkiRefreshGroupToken"

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run). Also prunes duplicate DP certs.
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $fn = 'ConfigMgr Client DistributionPoint Certificate'
                    $dupes = @(Get-ChildItem Cert:\LocalMachine\My |
                        Where-Object { $_.FriendlyName -eq $fn } | Sort-Object NotBefore -Descending)
                    if ($dupes.Count -gt 1) {
                        foreach ($old in $dupes | Select-Object -Skip 1) {
                            Remove-Item "Cert:\LocalMachine\My\$($old.Thumbprint)" -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }
            $nextDepend = "[Script]PkiRefreshTemplateCache"

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = $nextDepend
            }
            $nextDepend = "[CertReq]PkiWebCert"

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = $nextDepend
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $nextDepend = "[AddCertificateToIIS]PkiAddCert"
        }

        WriteStatus ADKInstall {
            Status    = "Downloading and installing ADK"
            DependsOn = $nextDepend
        }

        InstallADK ADKInstall {
            ADKPath              = "C:\temp\adksetup.exe"
            ADKWinPEPath         = "c:\temp\adksetupwinpe.exe"
            ADKDownloadPath      = $deployConfig.URLS.ADK
            ADKWinPEDownloadPath = $deployConfig.URLS.ADKPE           
            Ensure               = "Present"
            DependsOn            = "[WriteStatus]ADKInstall"
        }
        $nextDepend = "[InstallADK]ADKInstall"

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus WaitActive {
            Status    = "Waiting for $($ThisVM.thisParams.ActiveNode) to finish adding passive site server role"
            DependsOn = '[InstallADK]ADKInstall'
        }

        WaitForAll ActiveNode {
            ResourceName     = '[WriteStatus]Complete'
            NodeName         = $ThisVM.thisParams.ActiveNode
            RetryIntervalSec = 5
            RetryCount       = 6500
            DependsOn        = '[WriteStatus]WaitActive'
        }

        WriteStatus Complete {
            DependsOn = "[WaitForAll]ActiveNode"
            Status    = "Complete!"
        }

    }
}