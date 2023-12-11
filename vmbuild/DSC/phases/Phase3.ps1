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

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $NetBiosDomainName = $deployConfig.vmoptions.domainNetBiosName

    $l = $ConfigurationData.LocaleSettings

    Node $AllNodes.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }

        # Install Language Packs
        if ($l -and $l.LanguageTag -and $l.LanguageTag -ne "en-US") {
            LanguagePack InstallLanguagePack {
                LanguagePackName = $l.LanguageTag
                LanguagePackLocation = "C:\LanguagePacks"
            }

            Language ConfigureLanguage {
                IsSingleInstance = "Yes"
                LocationID = $l.LocationID
                MUILanguage = $l.MUILanguage
                MUIFallbackLanguage = $l.MUIFallbackLanguage
                SystemLocale = $l.SystemLocale
                AddInputLanguages = $l.AddInputLanguages
                RemoveInputLanguages = $l.RemoveInputLanguages
                UserLocale = $l.UserLocale
                CopySystem = $true
                CopyNewUser = $true
                Dependson = "[LanguagePack]InstallLanguagePack"
            }

            LocalConfigurationManager {
                RebootNodeIfNeeded = $true
                ActionAfterReboot = "ContinueConfiguration"
                ConfigurationMode = "ApplyAndAutoCorrect"
            }
        }

        # Install feature roles
        $featureRoles = @($ThisVM.role)
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") {
            $featureRoles += "Site Server"
        }

        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") {
           $featureRoles += "WSUS"
        }

        WriteStatus AddLocalAdmin {
            Status = "Adding required accounts [$($ThisVM.thisParams.LocalAdminAccounts -join ',')] to Administrators group"
        }

        $addUserDependancy = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $ThisVM.thisParams.LocalAdminAccounts) {
            $i++
            $DscNodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$DscNodeName" {
                Name              = $user
                NetbiosDomainName = $NetBiosDomainName
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$DscNodeName"
        }

        WriteStatus InstallFeature {
            DependsOn = $addUserDependancy
            Status    = "Installing required windows features for role $featureRoles"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = "DummyName"
            Role      = $featureRoles
            DependsOn = "[WriteStatus]InstallFeature"
        }

        WriteStatus InstallDotNet {
            DependsOn = '[InstallFeatureForSCCM]InstallFeature'
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        $nextDepend = "[InstallDotNet4]DotNet"
        if ($ThisVM.installSSMS -eq $true -or (($null -eq $ThisVM.installSSMS) -and $ThisVM.SQLVersion)) {
            # Check if false, for older configs that didn't have this prop

            $ssmsDownloadUrl = "https://aka.ms/ssmsfullsetup"
            if ($l.LanguageTag -ne "en-US") {
                $ssmsDownloadUrl = $ssmsDownloadUrl + "?clcid=" + $l.LanguageID
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

        if ($ThisVM.role -eq 'CAS' -or $ThisVM.role -eq "Primary" -or $ThisVM.role -eq "PassiveSite") {

            $prevDepend = $nextDepend

            WriteStatus ADKInstall {
                DependsOn = $nextDepend
                Status    = "Downloading and installing ADK"
            }

            InstallADK ADKInstall {
                ADKPath      = "C:\temp\adksetup.exe"
                ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
                Ensure       = "Present"
                DependsOn    = "[WriteStatus]ADKInstall"
            }

            $nextDepend = "[InstallADK]ADKInstall"
            if (-not $ThisVM.thisParams.ParentSiteServer -and $ThisVM.role -ne "PassiveSite" -and -not $ThisVM.hidden) {

                $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }
                $CMDownloadStatus = "Downloading Configuration Manager current branch (required baseline version)"
                if ($CM -eq "CMTP") {
                    $CMDownloadStatus = "Downloading Configuration Manager technical preview"
                }

                WriteStatus DownLoadSCCM {
                    DependsOn = $nextDepend
                    Status    = $CMDownloadStatus
                }

                DownloadSCCM DownLoadSCCM {
                    CM            = $CM
                    CMDownloadUrl = $ThisVM.thisParams.cmDownloadVersion.downloadUrl
                    Ensure        = "Present"
                    DependsOn     = $prevDepend
                }

                FileReadAccessShare CMSourceSMBShare {
                    Name      = $CM
                    Path      = "c:\$CM"
                    DependsOn = "[DownLoadSCCM]DownLoadSCCM"
                }
                $nextDepend = @($nextDepend, "[FileReadAccessShare]CMSourceSMBShare")
                #$nextDepend = "[FileReadAccessShare]CMSourceSMBShare"
            }
        }

        #add depend stuff
     #   if ($ThisVM.role -eq 'CAS' -or $ThisVM.role -eq "Primary" -or $ThisVM.role -eq "Secondary") {
            WriteStatus ODBCDriverInstall {
                DependsOn = $nextDepend
                Status = "Downloading and installing ODBC driver"
            }

            InstallODBCDriver ODBCDriverInstall {
                DependsOn = "[WriteStatus]ODBCDriverInstall"
                ODBCPath = "C:\temp\msodbcsql.msi"
                Ensure   = "Present"
            }

            $nextDepend = "[InstallODBCDriver]ODBCDriverInstall"
      #  }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

    }
}