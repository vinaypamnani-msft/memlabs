configuration Phase3
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc'
    Import-DscResource -ModuleName 'LanguageDsc'
    Import-DscResource -ModuleName 'CertificateDsc'

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $NetBiosDomainName = $deployConfig.vmoptions.domainNetBiosName

    # Log share + CM admin credential, used by the Phase 3 "ScriptWorkflow
    # Download" pre-warm task (RegisterTaskScheduler). Mirrors Phase8.ps1 so
    # the pre-warm runs ScriptWorkflow.ps1 with the same identity/args the real
    # Phase 8 workflow uses.
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"
    $AdminUserName = $Admincreds.UserName
    if ($AdminUserName -match '\\') { $AdminUserName = ($AdminUserName -split '\\', 2)[1] }
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

    $l = $ConfigurationData.LocaleSettings

    Node $AllNodes.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }

        # Install Language Packs
        if ($l -and $l.LanguageTag -and $l.LanguageTag -ne "en-US") {
            LanguagePack InstallLanguagePack {
                LanguagePackName     = $l.LanguageTag
                LanguagePackLocation = "C:\LanguagePacks"
            }

            Language ConfigureLanguage {
                IsSingleInstance     = "Yes"
                LocationID           = $l.LocationID
                MUILanguage          = $l.MUILanguage
                MUIFallbackLanguage  = $l.MUIFallbackLanguage
                SystemLocale         = $l.SystemLocale
                AddInputLanguages    = $l.AddInputLanguages
                RemoveInputLanguages = $l.RemoveInputLanguages
                UserLocale           = $l.UserLocale
                CopySystem           = $true
                CopyNewUser          = $true
                DependsOn            = "[LanguagePack]InstallLanguagePack"
            }

            LocalConfigurationManager {
                RebootNodeIfNeeded = $true
                ActionAfterReboot  = "ContinueConfiguration"
                ConfigurationMode  = "ApplyAndAutoCorrect"
            }
        }

        # Install feature roles. (The PKI IIS web-server cert request that used
        # to be gated off $AddIISCert here was relocated to Phase 8 -- the
        # Enterprise CA is now published by the post-Phase-3 PKI orchestrator, so
        # requesting it in Phase 3 dead-locked with "No Certificate Authority
        # could be found". See the per-node "PKI IIS web-server certificate"
        # blocks in Phase8.ps1.)
        $featureRoles = @($ThisVM.role)
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") {
            $featureRoles += "Site Server"
        }

        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") {
            $featureRoles += "WSUS"
        }

        # Per-VM cmOptions (multi-hierarchy safe); $cmo is reused below for the
        # CM source-folder ($CM) selection.
        $cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }

        WriteStatus AddLocalAdmin {
            Status = "Adding required accounts [$($ThisVM.thisParams.LocalAdminAccounts -join ',')] to Administrators group"
        }

        $addUserDependency = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $ThisVM.thisParams.LocalAdminAccounts) {
            $i++
            $DscNodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$DscNodeName" {
                Name              = $user
                NetbiosDomainName = $NetBiosDomainName
            }
            $addUserDependency += "[AddUserToLocalAdminGroup]$DscNodeName"
        }

        # Phase 2 DSC (SetWindowsProxy resource) configures WinHTTP, machine.config
        # <defaultProxy>, and registry. However, .NET reads machine.config once per
        # AppDomain — if the Phase 3 WmiPrvSE process reuses a cached AppDomain,
        # DefaultWebProxy may still be empty. Read WinHTTP (guaranteed set by Phase 2)
        # and stamp DefaultWebProxy in this AppDomain so all download resources
        # (InstallVCRedist, InstallOleDb, InstallADK, etc.) inherit the proxy.
        Script EnsureProcessProxy {
            DependsOn  = $addUserDependency
            GetScript  = { @{ Result = "$([System.Net.WebRequest]::DefaultWebProxy)" } }
            TestScript = {
                try {
                    $output = & netsh winhttp show proxy 2>$null
                    if ($output -match 'Proxy Server\(s\)\s*:\s*(\S+)') {
                        $current = [System.Net.WebRequest]::DefaultWebProxy
                        if ($current) {
                            $resolved = $current.GetProxy([System.Uri]"https://aka.ms")
                            if ($resolved -and $resolved.Host -ne 'aka.ms') { return $true }
                        }
                        return $false
                    }
                } catch {}
                return $true   # No WinHTTP proxy configured; not a proxy client
            }
            SetScript  = {
                $output = & netsh winhttp show proxy 2>$null
                if ($output -match 'Proxy Server\(s\)\s*:\s*(\S+)') {
                    $proxyAddr = $Matches[1].Trim()
                    $bypass = ''
                    if ($output -match 'Bypass List\s*:\s*(.+)') { $bypass = $Matches[1].Trim() }
                    $wp = New-Object System.Net.WebProxy("http://$proxyAddr", $true)
                    if ($bypass -and $bypass -ne '(none)') {
                        $wp.BypassList = @($bypass -split ';' | ForEach-Object {
                            $e = $_.Trim()
                            if ($e -and $e -ne '<local>') { '^' + ([Regex]::Escape($e) -replace '\\\*','.*') + '$' }
                        } | Where-Object { $_ })
                        $wp.BypassProxyOnLocal = $true
                    }
                    [System.Net.WebRequest]::DefaultWebProxy = $wp
                    Write-Verbose "EnsureProcessProxy: set DefaultWebProxy to http://$proxyAddr"
                }
            }
        }

        WriteStatus InstallFeature {
            DependsOn = '[Script]EnsureProcessProxy'
            Status    = "Installing required windows features for role $featureRoles"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = "DummyName"
            Role      = $featureRoles
            InstallCA = [bool]$ThisVM.InstallCA
            DependsOn = "[WriteStatus]InstallFeature"
        }

        WriteStatus InstallDotNet {
            DependsOn = '[InstallFeatureForSCCM]InstallFeature'
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = $deployConfig.URLS.DotNet
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        $nextDepend = "[InstallDotNet4]DotNet"
        if ($ThisVM.installSSMS -eq $true -or (($null -eq $ThisVM.installSSMS) -and $ThisVM.SQLVersion)) {
            # Check if false, for older configs that didn't have this prop

            $ssmsDownloadUrl = $deployConfig.URLS.SSMS
            if ($l -and $l.LanguageTag -and $l.LanguageTag -ne "en-US" -and $l.LanguageID) {
                # Use & when the URL already has a query string (e.g. go.microsoft.com/fwlink/?linkid=...),
                # otherwise ? (e.g. a bare aka.ms link). Appending a 2nd ? would corrupt the fwlink.
                $clcidSep = if ($ssmsDownloadUrl -like "*`?*") { "&" } else { "?" }
                $ssmsDownloadUrl = $ssmsDownloadUrl + $clcidSep + "clcid=" + $l.LanguageID
            }

            WriteStatus SSMS {
                DependsOn = $nextDepend
                Status    = "Downloading and installing SQL Management Studio"
            }

            InstallSSMS SSMS {
                DownloadUrl = $ssmsDownloadUrl
                Ensure      = "Present"
                DependsOn   = "[WriteStatus]SSMS"
            }

            $nextDepend = "[InstallSSMS]SSMS"
        }

        GpUpdate GpUpdate {
            Run       = "True"
            DependsOn = $nextDepend
        }
        $nextDepend = "[GpUpdate]GpUpdate"

        if ($ThisVM.role -eq 'CAS' -or $ThisVM.role -eq "Primary" -or $ThisVM.role -eq "PassiveSite" -or $ThisVM.InstallSMSProv) {

            $prevDepend = $nextDepend

            WriteStatus ADKInstall {
                DependsOn = $nextDepend
                Status    = "Downloading and installing ADK"
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
            #Find the toplevel site server that is newly being deployed
            if (-not $ThisVM.thisParams.ParentSiteServer -and -not $ThisVM.hidden -and $ThisVM.Role -in ("CAS", "Primary")) {

                $CM = if ($cmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
                $CMDownloadStatus = "Downloading Configuration Manager current branch (required baseline version)"
                if ($CM -eq "CMTP") {
                    $CMDownloadStatus = "Downloading Configuration Manager technical preview"
                }

               

                # URL-download CM versions extract to C:\CMCB (DownloadSCCM) and
                # share C:\CMCB for schema extension. ISO CM versions are mounted
                # on-demand by the host right before Phase 8 (Mount-CmIsoForPhase
                # in Common.Phases.ps1), which also creates the CMCB share pointing
                # at the DVD and installs directly from it -- so there is nothing to
                # download, pre-warm, or share here for the ISO case.
                if ($ThisVM.thisParams.cmDownloadVersion.downloadUrl) {

                    WriteStatus DownLoadSCCM {
                        DependsOn = $prevDepend
                        Status    = $CMDownloadStatus
                    }

                    DownloadSCCM DownLoadSCCM {
                        CM            = $CM
                        CMDownloadUrl = $ThisVM.thisParams.cmDownloadVersion.downloadUrl
                        Ensure        = "Present"
                        DependsOn     = $prevDepend
                    }
                    $prevDepend = "[DownLoadSCCM]DownLoadSCCM"

                    FileReadAccessShare CMSourceSMBShare {
                        Name      = $CM
                        Path      = "c:\$CM"
                        DependsOn = $prevDepend
                    }
                    $nextDepend = @($nextDepend, "[FileReadAccessShare]CMSourceSMBShare")
                }
            }
        }

        #add depend stuff
        #   if ($ThisVM.role -eq 'CAS' -or $ThisVM.role -eq "Primary" -or $ThisVM.role -eq "Secondary") {
        WriteStatus VCInstall {
            DependsOn = $nextDepend
            Status    = "Downloading and installing VC redist"
        }

        InstallVCRedist VCInstall {
            DependsOn = "[WriteStatus]VCInstall"
            Path      = "C:\temp\vc_redist.x64.exe"
            URL       = $deployConfig.URLS.VCredist
            Ensure    = "Present"
        }

        InstallVCRedist VCInstallx86 {
            DependsOn = "[InstallVCRedist]VCInstall"
            Path      = "C:\temp\vc_redist.x86.exe"
            URL       = $deployConfig.URLS.VCredistx86
            Ensure    = "Present"
        }

        WriteStatus SQLClientInstall {
            DependsOn = "[InstallVCRedist]VCInstallx86"
            Status    = "Downloading and installing SQL Client"
        }

        InstallSQLClient SQLClientInstall {
            DependsOn = "[WriteStatus]SQLClientInstall"
            URL       = $deployConfig.URLS.SQLClient
            Path      = "C:\Windows\Temp\sqlncli.msi"
            Ensure    = "Present"
        }

        WriteStatus ODBCDriverInstall {
            DependsOn = "[InstallSQLClient]SQLClientInstall"
            Status    = "Downloading and installing ODBC driver"
        }

        InstallODBCDriver ODBCDriverInstall {
            DependsOn = "[WriteStatus]ODBCDriverInstall"
            URL       = $deployConfig.URLS.ODBC
            ODBCPath  = "C:\temp\msodbcsql.msi"
            Ensure    = "Present"
        }

        WriteStatus OleDbDriverInstall {
            DependsOn = "[InstallODBCDriver]ODBCDriverInstall"
            Status    = "Downloading and installing OleDB driver"
        }

        InstallOleDbDriver InstallOleDbDriver {
            DependsOn = "[WriteStatus]OleDbDriverInstall"
            URL       = $deployConfig.URLS.OleDB
            Path      = "C:\temp\msoledbsql.msi"
            Ensure    = "Present"
        }


        $nextDepend = "[InstallOleDbDriver]InstallOleDbDriver"


        if ($ThisVM.installDP) {
            Registry RAMDiskTFTPWIndowSize {
                DependsOn = $nextDepend
                Ensure    = "Present"
                Key       = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SMS\DP"
                ValueName = "RamDiskTFTPWindowSize"
                ValueData = "16"
                ValueType = "DWord"
            }

            Registry RAMDiskTFTPBlockSize {
                DependsOn = $nextDepend
                Ensure    = "Present"
                Key       = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\SMS\DP"
                ValueName = "RamDiskTFTPBlockSize"
                ValueData = "4096"
                ValueType = "DWord"
            }

            $nextDepend = "[Registry]RAMDiskTFTPBlockSize"
        }

        # PKI IIS web-server cert request relocated to Phase 8 (per site-server
        # node). It ran here in Phase 3 previously, but the Enterprise CA is now
        # published by the post-Phase-3 PKI orchestrator, so requesting a cert in
        # Phase 3 dead-locked ("No Certificate Authority could be found"). See the
        # "PKI IIS web-server certificate" blocks in Phase8.ps1.

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

    }
}