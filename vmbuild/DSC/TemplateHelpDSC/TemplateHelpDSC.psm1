enum Ensure {
    Absent
    Present
}

enum StartupType {
    auto
    delayedauto
    demand
}

[DscResource()]
class InstallADK {
    [DscProperty(Key)]
    [string] $ADKPath

    [DscProperty(Mandatory)]
    [string] $ADKWinPEPath

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_adkpath = $this.ADKPath
        if (!(Test-Path $_adkpath)) {
            # $adkurl = "https://go.microsoft.com/fwlink/?linkid=2120254" # ADK 2004 (19041)
            $adkurl = "https://go.microsoft.com/fwlink/?linkid=2165884"   # ADK Win11
            Start-BitsTransfer -Source $adkurl -Destination $_adkpath -Priority Foreground -ErrorAction Stop
        }



        $_adkWinPEpath = $this.ADKWinPEPath
        if (!(Test-Path $_adkWinPEpath)) {
            # $adkurl = "https://go.microsoft.com/fwlink/?linkid=2120253"  # ADK add-on (19041)
            $adkurl = "https://go.microsoft.com/fwlink/?linkid=2166133"  # ADK Win11
            Start-BitsTransfer -Source $adkurl -Destination $_adkWinPEpath -Priority Foreground -ErrorAction Stop
        }

        #Install DeploymentTools
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkpath
            $arg1 = "/Features"
            $arg2 = "OptionId.DeploymentTools"
            $arg3 = "/q"

            try {
                Write-Verbose "Installing ADK DeploymentTools..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Verbose "ADK DeploymentTools Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to install ADK DeploymentTools with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }

        #Install UserStateMigrationTool
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkpath
            $arg1 = "/Features"
            $arg2 = "OptionId.UserStateMigrationTool"
            $arg3 = "/q"

            try {
                Write-Verbose "Installing ADK UserStateMigrationTool..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Verbose "ADK UserStateMigrationTool Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to install ADK UserStateMigrationTool with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }

        #Install WindowsPreinstallationEnvironment
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkWinPEpath
            $arg1 = "/Features"
            $arg2 = "OptionId.WindowsPreinstallationEnvironment"
            $arg3 = "/q"

            try {
                Write-Verbose "Installing WindowsPreinstallationEnvironment for ADK..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Verbose "WindowsPreinstallationEnvironment for ADK Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to install WindowsPreinstallationEnvironment for ADK with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }
    }

    [bool] Test() {
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\Windows Kits\Installed Roots")
        if ($subKey) {
            $tool1 = $tool2 = $tool3 = $false
            if ($null -ne $subKey.GetValue('KitsRoot10')) {
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*Deployment Tools*" }) {
                    $tool1 = $true
                }
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*Windows PE*" }) {
                    $tool2 = $true
                }
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*User State Migration*" }) {
                    $tool3 = $true
                }

                if ($tool1 -and $tool2 -and $tool3) {
                    return $true
                }
            }
        }
        return $false
    }

    [InstallADK] Get() {
        return $this
    }
}

[DscResource()]
class InstallSSMS {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [void] Set() {
        # Download SSMS

        $ssmsSetup = "C:\temp\SSMS-Setup-ENU.exe"
        if (!(Test-Path $ssmsSetup)) {
            Write-Verbose "Downloading SSMS from $($this.DownloadUrl)..."
            Start-BitsTransfer -Source $this.DownloadUrl -Destination $ssmsSetup -Priority Foreground -ErrorAction Stop
        }

        # Install SSMS
        $adkinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $ssmsSetup
            $arg1 = "/install"
            $arg2 = "/quiet"
            $arg3 = "/norestart"

            try {
                Write-Verbose "Installing SSMS..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Verbose "SSMS Installed Successfully!"

                # Reboot
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                throw "Failed to install SSMS with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }

    }

    [bool] Test() {
        $adkinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe"
        if (!(Test-Path $adkinstallpath)) {
            return $false
        }

        If (!(Get-Item $adkinstallpath).length -gt 0kb) {
            return $false
        }

        return $true
    }

    [InstallSSMS] Get() {
        return $this
    }
}

[DscResource()]
class InstallDotNet4 {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [string] $FileName

    [DscProperty(Mandatory)]
    [string] $NetVersion

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [void] Set() {

        # Download
        $setup = "C:\temp\$($this.FileName)"
        if (!(Test-Path $setup)) {
            Write-Verbose "Downloading .NET $($this.FileName) from $($this.DownloadUrl)..."
            Start-BitsTransfer -Source $this.DownloadUrl -Destination $setup -Priority Foreground -ErrorAction Stop
        }

        # Install
        $cmd = $setup
        $arg1 = "/q"
        $arg2 = "/norestart"

        try {
            Write-Verbose "Installing .NET $($this.FileName)..."
            & $cmd $arg1 $arg2 | out-null

            $processName = ($this.FileName -split ".exe")[0]
            while ($true) {
                Start-Sleep -Seconds 15
                $process = Get-Process $processName -ErrorAction SilentlyContinue
                if ($null -eq $process) {
                    break
                }
            }
            Start-Sleep -Seconds 120 ## Buffer Wait
            Write-Verbose ".NET $($this.FileName) Installed Successfully!"

            # Reboot
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            throw "Failed to install .NET with below error: $ErrorMessage"
        }
    }

    [bool] Test() {

        $NETval = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name "Release"

        If ($NETval.Release -ge $this.NetVersion) {
            Write-Host ".NET $($this.FileName) or greater $($NETval.Release) is installed"
            return $true
        }

        return $false
    }

    [InstallDotNet4] Get() {
        return $this
    }
}


[DscResource()]
class InstallAndConfigWSUS {
    [DscProperty(Key)]
    [string] $WSUSPath

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_WSUSPath = $this.WSUSPath
        if (!(Test-Path -Path $_WSUSPath)) {
            New-Item -Path $_WSUSPath -ItemType Directory
        }
        Write-Verbose "Installing WSUS..."
        Install-WindowsFeature -Name UpdateServices, UpdateServices-WidDB -IncludeManagementTools
        Write-Verbose "Finished installing WSUS..."

        Write-Verbose "Starting the postinstall for WSUS..."
        Set-Location "C:\Program Files\Update Services\Tools"
        .\wsusutil.exe postinstall CONTENT_DIR=C:\WSUS
        Write-Verbose "Finished the postinstall for WSUS"
    }

    [bool] Test() {
        if ((Get-WindowsFeature -Name UpdateServices).installed -eq 'True') {
            return $true
        }
        return $false
    }

    [InstallAndConfigWSUS] Get() {
        return $this
    }

}

[DscResource()]
class WriteEvent {

    [DscProperty(Mandatory)]
    [string] $LogPath

    [DscProperty(Mandatory = $false)]
    [string] $FileName

    [DscProperty(Key)]
    [string] $WriteNode

    [DscProperty(Mandatory)]
    [string] $Status

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_Node = $this.WriteNode
        $_Status = $this.Status
        $_LogPath = $this.LogPath
        $ConfigurationFile = Join-Path -Path $_LogPath -ChildPath "$_FileName.json"
        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

        $Configuration.$_Node.Status = $_Status
        $Configuration.$_Node.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"

        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }

    [bool] Test() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_LogPath = $this.LogPath
        $Configuration = ""
        $ConfigurationFile = Join-Path -Path $_LogPath -ChildPath "$_FileName.json"
        if (Test-Path -Path $ConfigurationFile) {
            $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
        }
        else {
            if (-not $this.FileName) {
                # For named-file, caller must ensure file exists with required nodes.
                [hashtable]$Actions = @{
                    MachineJoinDomain       = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    CSJoinDomain            = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    PSJoinDomain            = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    DPMPJoinDomain          = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    DomainMemberJoinDomain  = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    DelegateControl         = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    SCCMinstall             = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    DPMPFinished            = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    DomainMemberFinished    = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    PassiveReady            = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    ReadyForPrimary         = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    WorkgroupMemberFinished = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                    ConfigurationFinished   = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                }
                $Configuration = New-Object -TypeName psobject -Property $Actions
                $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
            }
        }

        return $false
    }

    [WriteEvent] Get() {
        return $this
    }
}

[DscResource()]
class WaitForEvent {

    [DscProperty(Key)]
    [string] $MachineName

    [DscProperty(Mandatory)]
    [string] $LogFolder

    [DscProperty(Mandatory = $false)]
    [string] $FileName

    [DscProperty(Key)]
    [string] $ReadNode

    [DscProperty(Mandatory)]
    [string] $ReadNodeValue

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }

        $_FilePath = "\\$($this.MachineName)\$($this.LogFolder)"
        $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"

        while (!(Test-Path $ConfigurationFile)) {
            Write-Verbose "Wait for configuration file to exist on $($this.MachineName), will try 60 seconds later..."
            Start-Sleep -Seconds 60
            $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"
        }

        $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
        while ($Configuration.$($this.ReadNode).Status -ne $this.ReadNodeValue) {
            Write-Verbose "Wait for step: [$($this.ReadNode)] to finish on $($this.MachineName), will try 60 seconds later..."
            Start-Sleep -Seconds 60
            $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
        }
    }

    [bool] Test() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_FilePath = "\\$($this.MachineName)\$($this.LogFolder)"
        $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"

        if (!(Test-Path $ConfigurationFile)) { return $false }

        $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
        if ($Configuration.$($this.ReadNode).Status -eq $this.ReadNodeValue) {
            return $true
        }

        return $false

    }

    [WaitForEvent] Get() {
        return $this
    }
}

[DscResource()]
class WaitForExtendSchemaFile {
    [DscProperty(Key)]
    [string] $MachineName

    [DscProperty(Mandatory)]
    [string] $ExtFolder

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_FilePath = "\\$($this.MachineName)\$($this.ExtFolder)"
        $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"

        while (!(Test-Path $extadschpath)) {
            Write-Verbose "Wait for extadsch.exe exist on $($this.MachineName), will try 10 seconds later..."
            Start-Sleep -Seconds 10
            $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"
        }

        Write-Verbose "Extended the Active Directory schema..."

        & $extadschpath | out-null

        Write-Verbose "Done."
    }

    [bool] Test() {
        return $false
    }

    [WaitForExtendSchemaFile] Get() {
        return $this
    }
}

[DscResource()]
class DelegateControl {
    [DscProperty(Key)]
    [string] $Machine

    [DscProperty(Mandatory)]
    [string] $DomainFullName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $root = (Get-ADRootDSE).defaultNamingContext
        $ou = $null
        try {
            $ou = Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
        }
        if ($null -eq $ou) {
            $ou = New-ADObject -Type Container -name "System Management" -Path "CN=System,$root" -Passthru
        }
        $DomainName = $this.DomainFullName.split('.')[0]
        #Delegate Control
        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $arg2 = "/G"
        $arg3 = "" + $DomainName + "\" + $this.Machine + "`$:GA;;"
        $arg4 = "/I:T"

        & $cmd $arg1 $arg2 $arg3 $arg4
    }

    [bool] Test() {
        $_machinename = $this.Machine
        $root = (Get-ADRootDSE).defaultNamingContext
        try {
            Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
            return $false
        }

        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $permissioninfo = & $cmd $arg1

        if (($permissioninfo | Where-Object { $_ -like "*$($_machinename)$*" } | Where-Object { $_ -like "*FULL CONTROL*" }).COUNT -gt 0) {
            return $true
        }

        return $false
    }

    [DelegateControl] Get() {
        return $this
    }
}

[DscResource()]
class AddNtfsPermissions {
    [DscProperty(key)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $testPath = "C:\staging\DSC\AddNtfsPermissions.txt"
        & icacls C:\tools /grant "Users:(M,RX)" /t | Out-File $testPath -Force -ErrorAction SilentlyContinue
        & icacls C:\temp /grant "Users:F" /t | Out-File $testPath -Append -Force
        & takeown /F C:\windows\system32\Configuration /A /R | Out-File $testPath -Append -Force
        & icacls C:\windows\system32\Configuration /grant "Administrators:F" /t | Out-File $testPath -Append -Force
    }

    [bool] Test() {
        $testPath = "C:\staging\DSC\AddNtfsPermissions.txt"
        if (Test-Path $testPath) {
            return $true
        }

        return $false
    }

    [AddNtfsPermissions] Get() {
        return $this
    }
}


[DscResource()]
class AddBuiltinPermission {
    [DscProperty(key)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        sqlcmd -Q "if not exists(select * from sys.server_principals where name='BUILTIN\administrators') CREATE LOGIN [BUILTIN\administrators] FROM WINDOWS;EXEC master..sp_addsrvrolemember @loginame = N'BUILTIN\administrators', @rolename = N'sysadmin'"
        $retrycount = 0
        $sqlpermission = sqlcmd -Q "if exists(select * from sys.server_principals where name='BUILTIN\administrators') Print 1"
        while ($null -eq $sqlpermission) {
            if ($retrycount -eq 3) {
                $sqlpermission = 1
            }
            else {
                $retrycount++
                Start-Sleep -Seconds 240
                sqlcmd -Q "if not exists(select * from sys.server_principals where name='BUILTIN\administrators') CREATE LOGIN [BUILTIN\administrators] FROM WINDOWS;EXEC master..sp_addsrvrolemember @loginame = N'BUILTIN\administrators', @rolename = N'sysadmin'"
                $sqlpermission = sqlcmd -Q "if exists(select * from sys.server_principals where name='BUILTIN\administrators') Print 1"
            }
        }
    }

    [bool] Test() {
        Start-Sleep -Seconds 60
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $sqlpermission = sqlcmd -Q "if exists(select * from sys.server_principals where name='BUILTIN\administrators') Print 1"
        if ($null -eq $sqlpermission) {
            Write-Verbose "Need to add the builtin administrators permission."
            return $false
        }
        Write-Verbose "No need to add the builtin administrators permission."
        return $true
    }

    [AddBuiltinPermission] Get() {
        return $this
    }
}

[DscResource()]
class DownloadSCCM {
    [DscProperty(Key)]
    [string] $CM

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_CM = $this.CM
        $cmpath = "c:\temp\$_CM.exe"
        $cmsourcepath = "c:\$_CM"

        Write-Verbose "Downloading $_CM installation source..."
        if ($_CM -eq "CMTP") {
            $cmurl = "https://go.microsoft.com/fwlink/?linkid=2077212&clcid=0x409"
        }
        else {
            $cmurl = "https://go.microsoft.com/fwlink/?linkid=2093192"
        }

        Start-BitsTransfer -Source $cmurl -Destination $cmpath -Priority Foreground -ErrorAction Stop
        if (Test-Path $cmsourcepath) {
            Remove-Item -Path $cmsourcepath -Recurse -Force | Out-Null
        }

        if (!(Test-Path $cmsourcepath)) {
            Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -Wait
        }
    }

    [bool] Test() {
        $_CM = $this.CM
        $cmpath = "c:\temp\$_CM.exe"
        if (!(Test-Path $cmpath)) {
            return $false
        }

        return $true
    }

    [DownloadSCCM] Get() {
        return $this
    }
}

[DscResource()]
class DownloadFile {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $FilePath

    [void] Set() {
        Write-Verbose "Downloading file from $($this.DownloadUrl)..."
        Start-BitsTransfer -Source $this.DownloadUrl -Destination $this.FilePath -Priority Foreground -ErrorAction Stop
    }

    [bool] Test() {
        if (!(Test-Path $this.FilePath)) {
            return $false
        }

        If (!(Get-Item $this.FilePath).length -gt 0kb) {
            return $false
        }

        return $true
    }

    [DownloadFile] Get() {
        return $this
    }
}

[DscResource()]
class InstallDP {
    [DscProperty(key)]
    [string] $SiteCode

    [DscProperty(Mandatory)]
    [string] $DomainFullName

    [DscProperty(Mandatory)]
    [string] $DPMPName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $ProviderMachineName = $env:COMPUTERNAME + "." + $this.DomainFullName # SMS Provider machine name

        # Customizations
        $initParams = @{}
        if ($null -eq $ENV:SMS_ADMIN_UI_PATH) {
            $ENV:SMS_ADMIN_UI_PATH = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386"
        }

        # Import the ConfigurationManager.psd1 module
        if ($null -eq (Get-Module ConfigurationManager)) {
            Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams
        }

        # Connect to the site's drive if it is not already present
        Write-Verbose "Setting PS Drive..."

        New-PSDrive -Name $this.SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
        while ($null -eq (Get-PSDrive -Name $this.SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            Write-Verbose "Failed ,retry in 10s. Please wait."
            Start-Sleep -Seconds 10
            New-PSDrive -Name $this.SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
        }

        # Set the current location to be the site code.
        Set-Location "$($this.SiteCode):\" @initParams

        $DPServerFullName = $this.DPMPName + "." + $this.DomainFullName
        if ($null -eq $(Get-CMSiteSystemServer -SiteSystemServerName $DPServerFullName)) {
            New-CMSiteSystemServer -Servername $DPServerFullName -Sitecode $this.SiteCode
        }

        $Date = [DateTime]::Now.AddYears(10)
        Add-CMDistributionPoint -SiteSystemServerName $DPServerFullName -SiteCode $this.SiteCode -CertificateExpirationTimeUtc $Date
    }

    [bool] Test() {
        return $false
    }

    [InstallDP] Get() {
        return $this
    }
}

[DscResource()]
class InstallMP {
    [DscProperty(key)]
    [string] $SiteCode

    [DscProperty(Mandatory)]
    [string] $DomainFullName

    [DscProperty(Mandatory)]
    [string] $DPMPName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $ProviderMachineName = $env:COMPUTERNAME + "." + $this.DomainFullName # SMS Provider machine name
        # Customizations
        $initParams = @{}
        if ($null -eq $ENV:SMS_ADMIN_UI_PATH) {
            $ENV:SMS_ADMIN_UI_PATH = "C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\i386"
        }

        # Import the ConfigurationManager.psd1 module
        if ($null -eq (Get-Module ConfigurationManager)) {
            Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams
        }

        # Connect to the site's drive if it is not already present
        Write-Verbose "Setting PS Drive..."

        New-PSDrive -Name $this.SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
        while ($null -eq (Get-PSDrive -Name $this.SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            Write-Verbose "Failed ,retry in 10s. Please wait."
            Start-Sleep -Seconds 10
            New-PSDrive -Name $this.SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
        }

        # Set the current location to be the site code.
        Set-Location "$($this.SiteCode):\" @initParams

        $MPServerFullName = $this.DPMPName + "." + $this.DomainFullName
        if (!(Get-CMSiteSystemServer -SiteSystemServerName $MPServerFullName)) {
            Write-Verbose "Creating cm site system server..."
            New-CMSiteSystemServer -SiteSystemServerName $MPServerFullName
            Write-Verbose "Finished creating cm site system server."
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPServerFullName
            Write-Verbose "Adding management point on $MPServerFullName ..."
            Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http
            Write-Verbose "Finished adding management point on $MPServerFullName ..."
        }
        else {
            Write-Verbose "$MPServerFullName is already a Site System Server , skip running this script."
        }
    }

    [bool] Test() {
        return $false
    }

    [InstallMP] Get() {
        return $this
    }
}

[DscResource()]
class WaitForDomainReady {
    [DscProperty(key)]
    [string] $DCName

    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory = $false)]
    [int] $WaitSeconds = 30

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_DCName = $this.DCName
        $_DomainName = $this.DomainName
        $_WaitSeconds = $this.WaitSeconds
        $_DCFullName = "$_DCName.$_DomainName"
        Write-Verbose "Domain computer is: $_DCName"
        $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        while (!$testconnection) {
            Write-Verbose "Waiting for Domain ready , will try again 30 seconds later..."
            ipconfig /renew
            ipconfig /registerdns
            Start-Sleep -Seconds $_WaitSeconds
            $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        }
        Write-Verbose "Domain is ready now."
    }

    [bool] Test() {
        $_DCName = $this.DCName
        $_DomainName = $this.DomainName
        $_DCFullName = "$_DCName.$_DomainName"
        Write-Verbose "Domain computer is: $_DCFullName"
        $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore

        if (!$testconnection) {
            ipconfig /renew
            return $false
        }

        ipconfig /registerdns
        return $true
    }

    [WaitForDomainReady] Get() {
        return $this
    }
}

[DscResource()]
class VerifyComputerJoinDomain {
    [DscProperty(key)]
    [string] $ComputerName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_Computername = $this.ComputerName
        $_ComputernameList = $_Computername.Split(',')
        foreach ($CL in $_ComputernameList) {
            $searcher = [adsisearcher] "(cn=$CL)"
            while ($searcher.FindAll().count -ne 1) {
                Write-Verbose "$CL not join into domain yet , will search again after 1 min"
                Start-Sleep -Seconds 60
                $searcher = [adsisearcher] "(cn=$CL)"
            }
            Write-Verbose "$CL joined into the domain."
        }
    }

    [bool] Test() {
        return $false
    }

    [VerifyComputerJoinDomain] Get() {
        return $this
    }
}

[DscResource()]
class SetDNS {
    [DscProperty(key)]
    [string] $DNSIPAddress

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_DNSIPAddress = $this.DNSIPAddress
        $dnsset = Get-DnsClientServerAddress | ForEach-Object { $_ | Where-Object { $_.InterfaceAlias.StartsWith("Ethernet") -and $_.AddressFamily -eq 2 } }
        Write-Verbose "Set dns: $_DNSIPAddress for $($dnsset.InterfaceAlias)"
        Set-DnsClientServerAddress -InterfaceIndex $dnsset.InterfaceIndex -ServerAddresses $_DNSIPAddress
    }

    [bool] Test() {
        $_DNSIPAddress = $this.DNSIPAddress
        $dnsset = Get-DnsClientServerAddress | ForEach-Object { $_ | Where-Object { $_.InterfaceAlias.StartsWith("Ethernet") -and $_.AddressFamily -eq 2 } }
        if ($dnsset.ServerAddresses -contains $_DNSIPAddress) {
            return $true
        }
        return $false
    }

    [SetDNS] Get() {
        return $this
    }
}

[DscResource()]
class WriteStatus {
    [DscProperty(key)]
    [string] $Status

    [void] Set() {

        $_Status = $this.Status
        $StatusFile = "C:\staging\DSC\DSC_Status.txt"
        $_Status | Out-File -FilePath $StatusFile -Force

        $StatusLog = "C:\staging\DSC\DSC_Log.txt"
        $time = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
        "$time $_Status" | Out-File -FilePath $StatusLog -Append

        Write-Verbose "Writing Status: $_Status"

    }

    [bool] Test() {
        $_Status = $this.Status
        $StatusLog = "C:\staging\DSC\DSC_Log.txt"

        if (Test-Path $StatusLog) {
            Write-Verbose "Testing if $StatusLog contains: $_Status"
            $contains = Get-Content -Path $StatusLog -Force | Select-String -Pattern $_Status -SimpleMatch
            if ($contains) {
                Write-Verbose "StatusLog contains status."
                return $true
            }
        }

        Write-Verbose "StatusLog does NOT contain status."
        return $false
    }

    [WriteStatus] Get() {
        return $this
    }
}

[DscResource()]
class WriteFileOnce {
    [DscProperty(key)]
    [string] $FilePath

    [DscProperty(key)]
    [string] $Content

    [void] Set() {
        $_FilePath = $this.FilePath
        $_Content = $this.Content
        $flag = "$_FilePath.done"

        $_Content | Out-File -FilePath $_FilePath -Force
        "WriteFileOnce" | Out-File -FilePath $flag -Force
        Write-Verbose "Writing specified content to $_FilePath"
    }

    [bool] Test() {
        $_FilePath = $this.FilePath
        $_Content = $this.Content
        $flag = "$_FilePath.done"

        # Wrote once, don't do it again
        if (Test-Path $flag) {
            return $true
        }

        if (Test-Path $_FilePath) {
            Write-Verbose "Testing if $_FilePath contains specified content"
            $contains = (Get-Content -Path $_FilePath -Force) -eq $_Content
            if ($contains) {
                Write-Verbose "FilePath contains content."
                return $true
            }
        }

        Write-Verbose "FilePath does not contain content."
        return $false
    }

    [WriteFileOnce] Get() {
        return $this
    }
}

[DscResource()]
class WaitForFileToExist {
    [DscProperty(key)]
    [string] $FilePath

    [void] Set() {
        $_FilePath = $this.FilePath
        while (!(Test-Path $_FilePath)) {
            Write-Verbose "Wait for $_FilePath to exist, will try 60 seconds later..."
            Start-Sleep -Seconds 60
        }

    }

    [bool] Test() {
        $_FilePath = $this.FilePath

        if (Test-Path $_FilePath) {
            return $true
        }

        return $false
    }

    [WaitForFileToExist] Get() {
        return $this
    }
}

[DscResource()]
class ChangeSQLServicesAccount {
    [DscProperty(key)]
    [string] $SQLInstanceName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_SQLInstanceName = $this.SQLInstanceName
        $serviceName = if ($_SQLInstanceName -eq "MSSQLSERVER") { $_SQLInstanceName } else { "MSSQL`$$_SQLInstanceName" }
        $query = "Name = '$serviceName'"
        $services = Get-WmiObject win32_service -Filter $query

        if ($services.State -eq 'Running') {
            #Check if SQLSERVERAGENT is running
            $sqlserveragentflag = 0
            $sqlAgentService = if ($_SQLInstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$_SQLInstanceName" }
            $sqlserveragentservices = Get-WmiObject win32_service -Filter "Name = '$sqlAgentService'"
            if ($null -ne $sqlserveragentservices) {
                if ($sqlserveragentservices.State -eq 'Running') {
                    Write-Verbose "[$(Get-Date -format HH:mm:ss)] $sqlAgentService need to be stopped first"
                    $Result = $sqlserveragentservices.StopService()
                    Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopping $sqlAgentService.."
                    if ($Result.ReturnValue -eq '0') {
                        $sqlserveragentflag = 1
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
                    }
                }
            }
            $Result = $services.StopService()
            Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopping SQL Server services.."
            if ($Result.ReturnValue -eq '0') {
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
            }

            Write-Verbose "[$(Get-Date -format HH:mm:ss)] Changing the services account..."

            $Result = $services.change($null, $null, $null, $null, $null, $null, "LocalSystem", $null, $null, $null, $null)
            if ($Result.ReturnValue -eq '0') {
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Successfully Change the services account"
                if ($sqlserveragentflag -eq 1) {
                    Write-Verbose "[$(Get-Date -format HH:mm:ss)] Starting $sqlAgentService.."
                    $Result = $sqlserveragentservices.StartService()
                    if ($Result.ReturnValue -eq '0') {
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Started"
                    }
                }
                $Result = $services.StartService()
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Starting SQL Server services.."
                while ($Result.ReturnValue -ne '0') {
                    $returncode = $Result.ReturnValue
                    Write-Verbose "[$(Get-Date -format HH:mm:ss)] Return $returncode , will try again"
                    Start-Sleep -Seconds 10
                    $Result = $services.StartService()
                }
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Started"
            }
        }
    }

    [bool] Test() {
        $_SQLInstanceName = $this.SQLInstanceName
        $serviceName = if ($_SQLInstanceName -eq "MSSQLSERVER") { $_SQLInstanceName } else { "MSSQL`$$_SQLInstanceName" }
        $query = "Name = '$serviceName'"
        $services = Get-WmiObject win32_service -Filter $query

        if ($null -ne $services) {
            if ($services.StartName -ne "LocalSystem") {
                return $false
            }
            else {
                return $true
            }
        }

        return $true
    }

    [ChangeSQLServicesAccount] Get() {
        return $this
    }
}


[DscResource()]
class ChangeSqlInstancePort {
    [DscProperty(key)]
    [string] $SQLInstanceName

    [DscProperty(Mandatory)]
    [int] $SQLInstancePort

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_SQLInstanceName = $this.SQLInstanceName
        $_SQLInstancePort = $this.SQLInstancePort

        if ($_SQLInstanceName -eq "MSSQLSERVER") {
            return
        }

        Try {
            # Load the assemblies
            Write-Verbose "[ChangeSqlInstancePort]: Setting port for $_SQLInstanceName to $_SQLInstancePort"

            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | Out-Null
            $mc = new-object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $env:COMPUTERNAME
            $i = $mc.ServerInstances[$_SQLInstanceName]
            $p = $i.ServerProtocols['Tcp']
            $ip = $p.IPAddresses['IPAll']
            $ip.IPAddressProperties['TcpDynamicPorts'].Value = ''
            $ipa = $ip.IPAddressProperties['TcpPort']
            $ipa.Value = [string]$_SQLInstancePort
            $p.Alter()

            New-NetFirewallRule -DisplayName 'SQL over TCP Inbound (Named Instance)' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort $_SQLInstancePort -Group "For SQL Server"

        }
        Catch {
            Write-Verbose "ERROR[ChangeSqlInstancePort]: SET Failed: $($_.Exception.Message)"
        }
    }

    [bool] Test() {

        $_SQLInstanceName = $this.SQLInstanceName
        $_SQLInstancePort = $this.SQLInstancePort

        if ($_SQLInstanceName -eq "MSSQLSERVER") {
            return $true
        }

        try {
            # Load the assemblies
            Write-Verbose "[ChangeSqlInstancePort]: Testing port for $_SQLInstanceName"

            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | Out-Null
            $mc = new-object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $env:COMPUTERNAME
            $i = $mc.ServerInstances[$_SQLInstanceName]
            $p = $i.ServerProtocols['Tcp']
            $ip = $p.IPAddresses['IPAll']
            $ipa = $ip.IPAddressProperties['TcpPort']
            if ($ipa.Value -eq $_SQLInstancePort) {
                return $true
            }
            return $false
        }
        catch {
            Write-Verbose "ERROR[ChangeSqlInstancePort]: TEST Failed: $($_.Exception.Message)"
            return $false
        }
    }

    [ChangeSqlInstancePort] Get() {
        return $this
    }
}

[DscResource()]
class RegisterTaskScheduler {
    [DscProperty(key)]
    [string] $TaskName

    [DscProperty(Mandatory)]
    [string] $ScriptName

    [DscProperty(Mandatory)]
    [string] $ScriptPath

    [DscProperty(Mandatory)]
    [string] $ScriptArgument

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $AdminCreds

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_TaskName = $this.TaskName
        $_ScriptName = $this.ScriptName
        $_ScriptPath = $this.ScriptPath
        $_ScriptArgument = $this.ScriptArgument
        $_AdminCreds = $this.AdminCreds

        $ProvisionToolPath = "$env:windir\temp\ProvisionScript"
        if (!(Test-Path $ProvisionToolPath)) {
            New-Item $ProvisionToolPath -ItemType directory | Out-Null
        }

        $exists = Get-ScheduledTask -TaskName $_TaskName -ErrorAction SilentlyContinue
        if ($exists) {
            Unregister-ScheduledTask -TaskName $_TaskName -Confirm:$false
        }

        $sourceDirctory = "$_ScriptPath\*"
        $destDirctory = "$ProvisionToolPath\"

        Copy-item -Force -Recurse $sourceDirctory -Destination $destDirctory

        $TaskDescription = "vmbuild task"
        $TaskCommand = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $TaskScript = "$ProvisionToolPath\$_ScriptName"

        Write-Verbose "Task script full path is : $TaskScript "

        $TaskArg = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $TaskScript $_ScriptArgument"

        Write-Verbose "command is : $TaskArg"

        $Action = New-ScheduledTaskAction -Execute $TaskCommand -Argument $TaskArg

        $TaskStartTime = [datetime]::Now.AddMinutes(2)
        $Trigger = New-ScheduledTaskTrigger -Once -At $TaskStartTime

        $Principal = New-ScheduledTaskPrincipal -UserId $_AdminCreds.UserName -RunLevel Highest
        $Password = $_AdminCreds.GetNetworkCredential().Password

        $Task = New-ScheduledTask -Action $Action -Trigger $Trigger -Description $TaskDescription -Principal $Principal
        $Task | Register-ScheduledTask -TaskName $_TaskName -User $_AdminCreds.UserName -Password $Password -Force

        # $TaskStartTime = [datetime]::Now.AddMinutes(2)
        # $service = new-object -ComObject("Schedule.Service")
        # $service.Connect()
        # $rootFolder = $service.GetFolder("\")
        # $TaskDefinition = $service.NewTask(0)
        # $TaskDefinition.RegistrationInfo.Description = "$TaskDescription"
        # $TaskDefinition.Settings.Enabled = $true
        # $TaskDefinition.Settings.AllowDemandStart = $true
        # $triggers = $TaskDefinition.Triggers
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa383915(v=vs.85).aspx
        # $trigger = $triggers.Create(1)
        # $trigger.StartBoundary = $TaskStartTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
        # $trigger.Enabled = $true
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa381841(v=vs.85).aspx
        # $Action = $TaskDefinition.Actions.Create(0)
        # $action.Path = "$TaskCommand"
        # $action.Arguments = "$TaskArg"
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa381365(v=vs.85).aspx
        # $rootFolder.RegisterTaskDefinition("$_TaskName", $TaskDefinition, 6, "System", $null, 5)
    }

    [bool] Test() {

        $ConfigurationFile = Join-Path -Path "C:\Staging\DSC" -ChildPath "ScriptWorkflow.json"
        if (-not (Test-Path $ConfigurationFile)) {
            return $false
        }

        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
        if ($Configuration.ScriptWorkflow.Status -eq 'NotStart') {
            $Configuration.ScriptWorkflow.Status = 'Scheduled'
            $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
            return $false
        }

        return $true
    }

    [RegisterTaskScheduler] Get() {
        return $this
    }
}

[DscResource()]
class SetAutomaticManagedPageFile {
    [DscProperty(key)]
    [string] $TaskName

    [DscProperty(Mandatory)]
    [bool] $Value

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_Value = $this.Value
        $computersys = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
        Write-Verbose "Set AutomaticManagedPagefile to $_Value..."
        $computersys.AutomaticManagedPagefile = $_Value
        $computersys.Put()
    }

    [bool] Test() {
        $_Value = $this.Value
        $computersys = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges;
        if ($computersys.AutomaticManagedPagefile -ne $_Value) {
            return $false
        }

        return $true
    }

    [SetAutomaticManagedPageFile] Get() {
        return $this
    }
}

[DscResource()]
class InitializeDisks {
    [DscProperty(key)]
    [string] $DummyKey

    [DscProperty(Mandatory)]
    [string] $VM

    [void] Set() {

        Write-Verbose "Initializing disks"

        $_VM = $this.VM | ConvertFrom-Json
        $_Disks = $_VM.additionalDisks

        # For debugging
        Write-Verbose  "VM Additional Disks: $_Disks"
        Get-Disk | Write-Verbose

        if ($null -eq $_Disks) {
            Write-Verbose "No disks to initialize."
            return
        }

        # Loop through disks
        $count = 0
        $label = "DATA"
        foreach ($disk in $_Disks.psobject.properties) {
            Write-Verbose "Assigning $($disk.Name) Drive Letter to disk with size $($disk.Value)"
            $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $disk.Value } | Select-Object -First 1
            $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $disk.Name | Format-Volume -FileSystem NTFS -NewFileSystemLabel "$label`_$count" -Confirm:$false -Force
            $count++
        }

        # Create NO_SMS_ON_DRIVE.SMS
        New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue
    }

    [bool] Test() {

        # TODO: Refine the Test logic, it works now, but it isn't in-line with what we do in Set()

        # Move CD-ROM drive to Z:
        if (-not (Get-Volume -DriveLetter "Z" -ErrorAction SilentlyContinue)) {
            Write-Verbose "Moving CD-ROM drive to Z:.."
            Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter = 'Z:' }
        }

        # Check if there are any RAW disks
        Write-Verbose "Testing if any Raw disks are left"
        $Validate = Get-Disk | Where-Object partitionstyle -eq 'RAW'

        If (!($null -eq $Validate)) {
            Write-Verbose "Disks are not initialized"
            return $false
        }
        Else {
            Write-Verbose "Disks are initialized"
            return $true
        }
    }

    [InitializeDisks] Get() {
        return $this
    }
}

[DscResource()]
class ChangeServices {
    [DscProperty(key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [StartupType] $StartupType

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_Name = $this.Name
        $_StartupType = $this.StartupType
        sc.exe config $_Name start=$_StartupType | Out-Null
    }

    [bool] Test() {
        $_Name = $this.Name
        $_StartupType = $this.StartupType
        $currentstatus = sc.exe qc $_Name

        switch ($_StartupType) {
            "auto" {
                if ($currentstatus[4].contains("DELAYED")) {
                    return $false
                }
                break
            }
            "delayedauto" {
                if (!($currentstatus[4].contains("DELAYED"))) {
                    return $false
                }
                break
            }
            "demand" {
                if (!($currentstatus[4].contains("DEMAND_START"))) {
                    return $false
                }
                break
            }
        }

        return $true
    }

    [ChangeServices] Get() {
        return $this
    }
}

[DscResource()]
class AddUserToLocalAdminGroup {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Key)]
    [string] $DomainName

    [void] Set() {
        $_DomainName = $($this.DomainName).Split(".")[0]
        $_Name = $this.Name
        $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
        $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
        Write-Verbose "[$(Get-Date -format HH:mm:ss)] add $_Name to administrators group"
        $GroupObj.Add("WinNT://$_DomainName/$_Name")

    }

    [bool] Test() {
        $_DomainName = $($this.DomainName).Split(".")[0]
        $_Name = $this.Name
        $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
        $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
        if ($GroupObj.IsMember("WinNT://$_DomainName/$_Name") -eq $true) {
            return $true
        }
        return $false
    }

    [AddUserToLocalAdminGroup] Get() {
        return $this
    }

}

[DscResource()]
class JoinDomain {
    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $Credential

    [void] Set() {
        $_credential = $this.Credential
        $_DomainName = $this.DomainName
        $_retryCount = 100
        try {
            Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Stop
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            Write-Verbose "Failed to join into the domain , retry..."
            $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
            $count = 0
            $flag = $false
            while ($CurrentDomain -ne $_DomainName) {
                if ($count -lt $_retryCount) {
                    $count++
                    Write-Verbose "retry count: $count"
                    Start-Sleep -Seconds 30
                    Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Ignore

                    $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
                }
                else {
                    $flag = $true
                    break
                }
            }
            if ($flag) {
                Add-Computer -DomainName $_DomainName -Credential $_credential
            }
            $global:DSCMachineStatus = 1
        }
    }

    [bool] Test() {
        $_DomainName = $this.DomainName
        $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain

        if ($CurrentDomain -eq $_DomainName) {
            return $true
        }

        return $false
    }

    [JoinDomain] Get() {
        return $this
    }

}

[DscResource()]
class OpenFirewallPortForSCCM {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Role

    [void] Set() {
        $_Role = $this.Role

        Write-Verbose "Current Role is : $_Role"

        if ($_Role -contains "DC") {
            #HTTP(S) Requests
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For DC"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For DC"

            #PS-->DC(in)
            New-NetFirewallRule -DisplayName 'LDAP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Kerberos Password Change TCP' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 464 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Kerberos Password Change UDP' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 464 -Group "For DC"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For DC"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP SSL Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For DC"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For DC"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For DC"
            #Dynamic Port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For DC"

            #THAgent
            Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)" -Direction Inbound
            Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
        }

        if ($_Role -contains "Site Server") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM"

            #site server<->site server
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'PPTP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1723 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'PPTP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1723 -Group "For SCCM"

            #priary site server(out) ->DC
            New-NetFirewallRule -DisplayName 'LDAP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP SSL Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For SCCM"


            #Dynamic Port?
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Wake on LAN Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 9 -Group "For SCCM"
        }

        if ($_Role -contains "Software Update Point") {
            New-NetFirewallRule -DisplayName 'SMB SUPInbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'SMB SUP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) SUP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) SUP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM SUP"
            #SUP->Internet
            New-NetFirewallRule -DisplayName 'HTTP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM SUP"

            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
        }
        if ($_Role -ccontains "State Migration Point") {
            #SMB,RPC Endpoint Mapper
            New-NetFirewallRule -DisplayName 'SMB SMP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'SMB SMP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
        }
        if ($_Role -contains "PXE Service Point") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM PXE SP"
            #Dynamic Port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'DHCP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(67.68) -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'TFTP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 69  -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'BINL Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 4011 -Group "For SCCM PXE SP"
        }
        if ($_Role -contains "System Health Validator") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM System Health Validator"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM System Health Validator"
        }
        if ($_Role -contains "Fallback Status Point") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM FSP "
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM FSP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM FSP"

            New-NetFirewallRule -DisplayName 'HTTP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM FSP"
        }
        if ($_Role -contains "Reporting Services Point") {
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM RSP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM RSP"
        }
        if ($_Role -contains "Distribution Point") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM DP"
            New-NetFirewallRule -DisplayName 'SMB DP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM DP"
            New-NetFirewallRule -DisplayName 'Multicast Protocol Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 63000-64000 -Group "For SCCM DP"
        }
        if ($_Role -contains "Management Point") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'Global Catelog LDAP SSL Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For SCCM MP"

            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM MP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM MP"
        }
        if ($_Role -contains "Branch Distribution Point") {
            New-NetFirewallRule -DisplayName 'SMB BDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM BDP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM BDP"
        }
        if ($_Role -contains "Server Locator Point") {
            New-NetFirewallRule -DisplayName 'HTTP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SLP"
            #Dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM RSP"
        }
        if ($_Role -contains "SQL Server") {
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'WMI' -Program "%systemroot%\system32\svchost.exe" -Service "winmgmt" -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort Domain -Group "For SQL Server WMI"
            New-NetFirewallRule -DisplayName 'DCOM' -Program "%systemroot%\system32\svchost.exe" -Service "rpcss" -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SQL Server DCOM"
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SQL Server"
        }
        if ($_Role -contains "Provider") {
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Provider"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Provider"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM Provider"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
        }
        if ($_Role -contains "Asset Intelligence Synchronization Point") {
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM AISP"
            #rpc dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'HTTPS Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 443 -Group "For SCCM AISP"
        }
        if ($_Role -contains "CM Console") {
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Console"
            #cm console->client
            New-NetFirewallRule -DisplayName 'Remote Control(control) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(control) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 2701 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(data) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2702 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(data) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol UDP -LocalPort 2702 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(RPC Endpoint Mapper) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Assistance(RDP AND RTC) Outbound' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3389 -Group "For SCCM Console"
        }
        if ($_Role -contains "DomainMember" -or $_Role -contains "WorkgroupMember") {
            #Client Push Installation
            Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
            Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)" -Direction Inbound

            #Remote Assistance and Remote Desktop
            New-NetFirewallRule -Program "C:\Windows\PCHealth\HelpCtr\Binaries\helpsvc.exe" -DisplayName "Remote Assistance - Helpsvc.exe" -Enabled True -Direction Outbound -Group "For SCCM Client"
            New-NetFirewallRule -Program "C:\Windows\PCHealth\HelpCtr\Binaries\helpsvc.exe" -DisplayName "Remote Assistance - Helpsvc.exe" -Enabled True -Direction Inbound -Group "For SCCM Client"
            New-NetFirewallRule -DisplayName 'CM Remote Assistance' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Client"

            #Client Requests
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM Client"

            #Client Notification
            New-NetFirewallRule -DisplayName 'CM Client Notification' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 10123 -Group "For SCCM Client"

            #Remote Control
            New-NetFirewallRule -DisplayName 'CM Remote Control' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Client"

            #Wake-Up Proxy
            New-NetFirewallRule -DisplayName 'Wake-Up Proxy' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort @(25536, 9) -Group "For SCCM Client"

            #SUP
            New-NetFirewallRule -DisplayName 'CM Connect SUP' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM Client"

            #enable firewall public profile
            if ($_Role -notcontains "WorkgroupMember") {
                Set-NetFirewallProfile -Profile Public -Enabled True
            }

            if ($_Role -contains "WorkgroupMember") {
                New-NetFirewallRule -DisplayName 'RDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -Group "For WorkgroupMember"
                New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For WorkgroupMember"
                New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For WorkgroupMember"

                # Force reboot, RDP doesn't seem to work until reboot
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
        }
        $StatusPath = "$env:windir\temp\OpenFirewallStatus.txt"
        "Finished" >> $StatusPath
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\OpenFirewallStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [OpenFirewallPortForSCCM] Get() {
        return $this
    }

}

[DscResource()]
class InstallFeatureForSCCM {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Role

    [void] Set() {
        $_Role = $this.Role

        Write-Verbose "Current Role is : $_Role"

        # Install on all devices
        try {
            dism /online /Enable-Feature /FeatureName:TelnetClient
        }
        catch {}
        #Install-WindowsFeature -Name Telnet-Client -ErrorAction SilentlyContinue

        # Server OS?
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $IsServerOS = $true
            if ($os.ProductType -eq 1) {
                $IsServerOS = $false
            }
        }
        else {
            $IsServerOS = $false
        }

        if ($IsServerOS) {

            # Always install BITS
            Install-WindowsFeature BITS, BITS-IIS-Ext
            # Always install IIS
            Install-WindowsFeature Web-Windows-Auth, web-ISAPI-Ext
            Install-WindowsFeature Web-WMI, Web-Metabase

            if ($_Role -notcontains "DomainMember") {
                Install-WindowsFeature -Name "Rdc"
            }

            if ($_Role -contains "DC") {
                Install-WindowsFeature RSAT-AD-PowerShell
            }
            if ($_Role -contains "SQLAO") {
                Install-WindowsFeature Failover-clustering, RSAT-Clustering-PowerShell, RSAT-Clustering-CmdInterface, RSAT-Clustering-Mgmt, RSAT-AD-PowerShell
            }
            if ($_Role -contains "Site Server") {
                Install-WindowsFeature Net-Framework-Core
                Install-WindowsFeature NET-Framework-45-Core
                Install-WindowsFeature Web-Basic-Auth, Web-IP-Security, Web-Url-Auth, Web-Windows-Auth, Web-ASP, Web-Asp-Net, web-ISAPI-Ext
                Install-WindowsFeature Web-Mgmt-Console, Web-Lgcy-Mgmt-Console, Web-Lgcy-Scripting, Web-WMI, Web-Metabase, Web-Mgmt-Service, Web-Mgmt-Tools, Web-Scripting-Tools
                Install-WindowsFeature BITS, BITS-IIS-Ext
            }
            if ($_Role -contains "Application Catalog website point") {
                #IIS
                Install-WindowsFeature Web-Default-Doc, Web-Static-Content, Web-Windows-Auth, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
            if ($_Role -contains "Application Catalog web service point") {
                #IIS
                Install-WindowsFeature Web-Default-Doc, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
            if ($_Role -contains "Asset Intelligence synchronization point") {
                #installed .net 4.5 or later
            }
            if ($_Role -contains "Certificate registration point") {
                #IIS
                Install-WindowsFeature Web-Asp-Net, Web-Asp-Net45, Web-Metabase, Web-WMI
            }
            if ($_Role -contains "Distribution point") {
                #IIS
                Install-WindowsFeature Web-Windows-Auth, web-ISAPI-Ext
                Install-WindowsFeature Web-WMI, Web-Metabase
            }

            if ($_Role -contains "Endpoint Protection point") {
                #.NET 3.5 SP1 is intalled
            }

            if ($_Role -contains "Enrollment point") {
                #iis
                Install-WindowsFeature Web-Default-Doc, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
            if ($_Role -contains "Enrollment proxy point") {
                #iis
                Install-WindowsFeature Web-Default-Doc, Web-Static-Content, Web-Windows-Auth, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
            if ($_Role -contains "Fallback status point") {
                Install-WindowsFeature Web-Metabase
            }
            if ($_Role -contains "Management point") {
                #BITS
                Install-WindowsFeature BITS, BITS-IIS-Ext
                #IIS
                Install-WindowsFeature Web-Windows-Auth, web-ISAPI-Ext
                Install-WindowsFeature Web-WMI, Web-Metabase
            }
            if ($_Role -contains "Reporting services point") {
                #installed .net 4.5 or later
            }
            if ($_Role -contains "Service connection point") {
                #installed .net 4.5 or later
            }
            if ($_Role -contains "Software update point") {
                #default iis configuration
                Install-WindowsFeature web-server
            }
            if ($_Role -contains "State migration point") {
                #iis
                Install-WindowsFeature Web-Default-Doc, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
        }

        $StatusPath = "$env:windir\temp\InstallFeatureStatus.txt"
        "Finished" >> $StatusPath
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\InstallFeatureStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [InstallFeatureForSCCM] Get() {
        return $this
    }
}

[DscResource()]
class SetCustomPagingFile {
    [DscProperty(Key)]
    [string] $Drive

    [DscProperty(Mandatory)]
    [string] $InitialSize

    [DscProperty(Mandatory)]
    [string] $MaximumSize

    [void] Set() {
        $_Drive = $this.Drive
        $_InitialSize = $this.InitialSize
        $_MaximumSize = $this.MaximumSize

        $currentstatus = Get-CimInstance -ClassName 'Win32_ComputerSystem'
        if ($currentstatus.AutomaticManagedPagefile) {
            set-ciminstance $currentstatus -Property @{AutomaticManagedPagefile = $false }
        }

        $currentpagingfile = Get-CimInstance -ClassName 'Win32_PageFileSetting' -Filter "SettingID='pagefile.sys @ $_Drive'"

        if (!($currentpagingfile)) {
            Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{name = "$_Drive\pagefile.sys"; InitialSize = $_InitialSize; MaximumSize = $_MaximumSize }
        }
        else {
            Set-CimInstance $currentpagingfile -Property @{InitialSize = $_InitialSize ; MaximumSize = $_MaximumSize }
        }

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [bool] Test() {
        $_Drive = $this.Drive
        $_InitialSize = $this.InitialSize
        $_MaximumSize = $this.MaximumSize

        $isSystemManaged = (Get-CimInstance -ClassName 'Win32_ComputerSystem').AutomaticManagedPagefile
        if ($isSystemManaged) {
            return $false
        }

        $_Drive = $this.Drive
        $currentpagingfile = Get-CimInstance -ClassName 'Win32_PageFileSetting' -Filter "SettingID='pagefile.sys @ $_Drive'"
        if (!($currentpagingfile) -or !($currentpagingfile.InitialSize -eq $_InitialSize -and $currentpagingfile.MaximumSize -eq $_MaximumSize)) {
            return $false
        }

        return $true
    }

    [SetCustomPagingFile] Get() {
        return $this
    }

}

[DscResource()]
class SetupDomain {
    [DscProperty(Key)]
    [string] $DomainFullName

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $SafemodeAdministratorPassword

    [void] Set() {
        $_DomainFullName = $this.DomainFullName
        $_SafemodeAdministratorPassword = $this.SafemodeAdministratorPassword

        $ADInstallState = Get-WindowsFeature AD-Domain-Services
        if (!$ADInstallState.Installed) {
            Install-WindowsFeature -Name AD-Domain-Services -IncludeAllSubFeature -IncludeManagementTools
        }

        $NetBIOSName = $_DomainFullName.split('.')[0]
        Import-Module ADDSDeployment
        Install-ADDSForest -SafeModeAdministratorPassword $_SafemodeAdministratorPassword.Password `
            -CreateDnsDelegation:$false `
            -DatabasePath "C:\Windows\NTDS" `
            -DomainName $_DomainFullName `
            -DomainNetbiosName $NetBIOSName `
            -LogPath "C:\Windows\NTDS" `
            -InstallDNS:$true `
            -NoRebootOnCompletion:$false `
            -SysvolPath "C:\Windows\SYSVOL" `
            -Force:$true

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [bool] Test() {
        $_DomainFullName = $this.DomainFullName
        $_SafemodeAdministratorPassword = $this.SafemodeAdministratorPassword
        $ADInstallState = Get-WindowsFeature AD-Domain-Services
        if (!($ADInstallState.Installed)) {
            return $false
        }
        else {
            while ($true) {
                try {
                    $domain = Get-ADDomain -Identity $_DomainFullName -ErrorAction Stop
                    Get-ADForest -Identity $domain.Forest -Credential $_SafemodeAdministratorPassword -ErrorAction Stop

                    return $true
                }
                catch {
                    Write-Verbose "Waiting for Domain ready..."
                    Start-Sleep -Seconds 30
                }
            }

        }

        return $true
    }

    [SetupDomain] Get() {
        return $this
    }

}

[DscResource()]
class FileReadAccessShare {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string] $Path

    [void] Set() {
        $_Name = $this.Name
        $_Path = $this.Path

        New-SMBShare -Name $_Name -Path $_Path
    }

    [bool] Test() {
        $_Name = $this.Name

        $testfileshare = Get-SMBShare | Where-Object { $_.name -eq $_Name }
        if (!($testfileshare)) {
            return $false
        }

        return $true
    }

    [FileReadAccessShare] Get() {
        return $this
    }

}

[DscResource()]
class InstallCA {
    [DscProperty(Key)]
    [string] $HashAlgorithm

    [void] Set() {
        try {
            $_HashAlgorithm = $this.HashAlgorithm
            Write-Verbose "Installing CA..."
            #Install CA
            Import-Module ServerManager
            Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools
            Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -KeyLength 2048 -HashAlgorithmName $_HashAlgorithm -force

            $StatusPath = "$env:windir\temp\InstallCAStatus.txt"
            "Finished" >> $StatusPath

            Write-Verbose "Finished installing CA."
        }
        catch {
            Write-Verbose "Failed to install CA."
        }
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\InstallCAStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [InstallCA] Get() {
        return $this
    }

}


[DscResource()]
class ClusterSetOwnerNodes {
    [DscProperty(Key)]
    [string] $ClusterName

    [DscProperty()]
    [string[]]$Nodes

    [void] Set() {
        try {
            $_ClusterName = $this.ClusterName
            $_Nodes = $this.Nodes
            foreach ($c in Get-ClusterResource -Cluster $_ClusterName) {
                $NeedsFixing = $c | Get-ClusterOwnerNode | Where-Object { $_.OwnerNodes.Count -ne 2 }
                if ($NeedsFixing) {
                    Write-Verbose "Setting owners $($_Nodes -Join ',') on $($c.Name)"
                    $c | Set-ClusterOwnerNode -owners $_Nodes
                }
            }
        }
        catch {
            Write-Verbose "Failed to Set Owner Nodes"
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $_ClusterName = $this.ClusterName
            $badNodes = foreach ($c in Get-ClusterResource -Cluster $_ClusterName) {
                $c | Get-ClusterOwnerNode | Where-Object { $_.OwnerNodes.Count -ne 2 }
            }

            if ($badNodes.Count -gt 0) {
                return $false
            }

            return $true
        }
        catch {
            Write-Verbose "Failed to Find Cluster Resources."
            Write-Verbose "$_"
            return $true
        }
    }

    [ClusterSetOwnerNodes] Get() {
        return $this
    }

}

[DscResource()]
class ClusterRemoveUnwantedIPs {
    [DscProperty(Key)]
    [string] $ClusterName

    [void] Set() {
        try {
            $_ClusterName = $this.ClusterName
            $ResourcesToRemove = (Get-ClusterResource -Cluster $_ClusterName | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject
            if ($ResourcesToRemove) {
                foreach ($Resource in $ResourcesToRemove) {
                    Write-Verbose "Cluster Removing $($resource.Name)"
                    Remove-ClusterResource -Name $resource.Name -Force
                }
            }
            Write-Verbose "Cluster Registering new DNS records"
            Get-ClusterResource -Name $_ClusterName | Update-ClusterNetworkNameResource
            Write-Verbose "Finished Removing Unwanted Cluster IPs"
        }
        catch {
            Write-Verbose "Failed to Remove Cluster IPs."
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $_ClusterName = $this.ClusterName
            $ResourcesToRemove = (Get-ClusterResource -Cluster $_ClusterName | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject

            if ($ResourcesToRemove) {
                return $false
            }

            return $true
        }
        catch {
            Write-Verbose "Failed to Find Cluster IPs."
            Write-Verbose "$_"
            return $true
        }
    }

    [ClusterRemoveUnwantedIPs] Get() {
        return $this
    }

}


[DscResource()]
class FileACLPermission {
    [DscProperty(Key)]
    [string]$Path

    [DscProperty(Mandatory)]
    [string[]]$accounts

    [DscProperty()]
    [string]$access = "Allow"

    [DscProperty()]
    [string]$rights = "FullControl"

    [DscProperty()]
    [string]$inherit = "ContainerInherit,ObjectInherit"

    [DscProperty()]
    [string]$propagate = "None"


    [void] Set() {
        foreach ($account in $this.accounts) {
            $_account = $account
            $_path = $this.Path

            write-verbose -message ('Set Entered:  Path Set to:' + $_path + 'Account Operating on:' + $_account)

            $_access = $this.access
            $_rights = $this.rights
            $_inherit = $this.inherit
            $_propagate = $this.propagate

            write-verbose -Message ('Variables Set to:' + $_account + ' ' + $_rights + ' ' + $_inherit + ' ' + $_propagate + ' ' + $_access)

            # Configure the access object values - READ-ONLY
            $_access = [System.Security.AccessControl.AccessControlType]::$_access
            $_rights = [System.Security.AccessControl.FileSystemRights]$_rights
            $_inherit = [System.Security.AccessControl.InheritanceFlags]$_inherit
            $_propagate = [System.Security.AccessControl.PropagationFlags]::$_propagate

            $ace = New-Object System.Security.AccessControl.FileSystemAccessRule($_account, $_rights, $_inherit, $_propagate, $_access)

            #Retrieve the directory ACL and add a new ACL rule
            $acl = Get-Acl $_path
            $acl.AddAccessRule($ace)
            $acl.SetAccessRuleProtection($false, $false)

            #Set-Acl  $directory $acl
            set-acl -aclobject $acl $_path
        }
    }

    [bool] Test() {
        $PermissionTest = $false


        $_access = $this.access
        $_rights = $this.rights
        $_inherit = $this.inherit
        $_propagate = $this.propagate
        $AccountTrack = @{ }

        $GetACL = Get-Acl $this.Path

        foreach ($account in $this.accounts) {

            $_account = $account

            Foreach ($AccessRight in $GetACL.access) {
                IF ($AccessRight.IdentityReference -eq "$_account") {
                    write-verbose -Message ("Account Discovered:" + $_account)
                    IF ($AccessRight.InheritanceFlags -eq $_inherit) {
                        write-verbose -Message ("InheritanceFlags Passed")
                        IF ($AccessRight.AccessControlType -eq $_access) {
                            write-verbose -Message ("Access Passed")
                            IF ($AccessRight.FileSystemRights -eq $_rights) {
                                write-verbose -Message ("Rights Passed")
                                IF ($AccessRight.PropagationFlags -eq $_propagate) {
                                    write-verbose -Message ("Propagate Passed")
                                    $PermissionTest = $true
                                    $AccountTrack.Add($_account, $PermissionTest)
                                }
                            }
                        }
                    }
                }
            }
            $PermissionTest = $false
        }

        IF (($AccountTrack.Count -eq 0) -or $AccountTrack.Count -ne $this.accounts.count) {
            $PermissionTest = $false
            Return $PermissionTest
        }

        $PermissionTest = $true


        foreach ($object in $AccountTrack.Values) {

            IF ($object -eq "$false") {
                write-verbose -Message ("Permission check failed set to false")
                $PermissionTest = $false
            }
        }


        Return $PermissionTest
    }

    [FileACLPermission] Get() {
        return $this
    }
}

[DscResource()]
class ModuleAdd {
    [DscProperty(Key)]
    [string]$key = 'Always'

    [DscProperty(Mandatory)]
    [string]$CheckModuleName

    [DscProperty()]
    [string]$Clobber = 'Yes'

    [DscProperty()]
    [string]$UserScope = 'AllUsers'

    [void] Set() {

        $_moduleName = $this.CheckModuleName
        $_userScope = $this.UserScope

        $NuGet = Get-PackageProvider -Name Nuget -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -ListAvailable

        IF ($null -eq $NuGet) {
            #Install-PackageProvider Nuget -force -Confirm:$false
            Find-PackageProvider -Name NuGet -Force | Install-PackageProvider -Force -Scope AllUsers -Confirm:$false
            Register-PackageSource -Name nuget.org -Location https://www.nuget.org/api/v2 -ProviderName NuGet -Force -Trusted
        }

        $module = Get-InstalledModule -Name PowerShellGet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        IF ($null -eq $module) {
            Install-Module -Name PowerShellGet -Force -Scope $_userScope
        }

        $module = Get-InstalledModule -Name $_moduleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        IF ($null -eq $module) {
            IF ($this.Clobber -eq 'Yes') {
                Install-Module -Name $_moduleName -Force -Scope $_userScope -AllowClobber
            }
            ELSE {
                Install-Module -Name $_moduleName -Force -Scope $_userScope
            }

        }
    }

    [bool] Test() {

        $_ModuleName = $this.CheckModuleName
        $GetModuleStatus = Get-InstalledModule -Name $_ModuleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        write-verbose ('Searching for module:' + $_ModuleName + 'ModuleStatus:' + $GetModuleStatus)


        IF ($null -eq $GetModuleStatus) {
            Return $false
        }
        ELSE {
            Return $true
        }
    }

    [ModuleAdd] Get() {
        return $this
    }

}

[DscResource()]
class ActiveDirectorySPN {
    [DscProperty(Key)]
    [string]$key = 'Always'

    [DscProperty()]
    [string[]]$UserName

    [DscProperty()]
    [string]$UserNameCluster

    [DscProperty()]
    [string[]]$ClusterDevice

    [DscProperty(Mandatory)]
    [string]$FQDNDomainName

    [DscProperty(Mandatory)]
    [string]$OULocationUser

    [DscProperty(Mandatory)]
    [string]$OULocationDevice

    [void] Set() {

        Import-Module ActiveDirectory
        New-PSDrive -PSProvider ActiveDirectory -Name AD -Root "" -Server localhost -ErrorAction SilentlyContinue
        Set-Location AD:

        #Set SPN permissions to object to allow it to update SPN registrations.
        $_OULocationUser = $this.OULocationUser
        $_OULocationDevice = $this.OULocationDevice
        $_FQDNDomainName = $this.FQDNDomainName
        $_UserNameCluster = $this.UserNameCluster

        Foreach ($user in $this.UserName) {
            $_UserName = $user

            write-verbose ('Adding Write Validated SPN permission to User ' + $user + ' on ' + $user + ' account')
            write-verbose ('Setting Permissions for User:' + $_UserName + ' OULocation:' + $_OULocationUser + ' On Domain:' + $_FQDNDomainName)
            #Set SPN permissions to object to allow it to update SPN registrations.

            $oldSddl = "(OA;;RPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;S-1-5-21-1914882237-739871479-3784143264-1199)"
            $UserObject = "CN=$_UserName,$_OULocationUser"

            write-verbose ('ObjectPath set to  AD:' + $UserObject)

            $UserSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADUser -Server "$_FQDNDomainName" $UserObject).SID
            $UserSID = $UserSID.Value

            write-verbose ('User:' + $_UserName + ' SIDValue is:' + $UserSID + ' On Domain:' + $_FQDNDomainName)

            $oldSddl -match "S\-1\-5\-21\-[0-9]*\-[0-9]*\-[0-9]*\-[0-9]*" | Out-Null
            $SIDMatch = $Matches[0]

            $oldSddl = $oldSddl -replace ($SIDMatch, $UserSID)

            #$ACLObject = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
            #$ACLObject.SetSecurityDescriptorSddlForm($oldSddl)

            $ACL = Get-Acl -Path "AD:$UserObject"
            $currentSSDL = $ACL.Sddl

            $newSSDL = $currentSSDL + $oldSddl
            $ACL.SetSecurityDescriptorSddlForm($newSSDL)

            Set-Acl -AclObject $acl -Path "AD:$UserObject"
            write-verbose (' Permissions for User:' + $_UserName + ' OULocation:' + $_OULocationUser + ' On Domain:' + $_FQDNDomainName + ' have been set')
        }

        Foreach ($device in $this.ClusterDevice) {
            $_DeviceName = $device
            write-verbose ('Adding Write Validated SPN permission to User ' + $_DeviceName + ' on ' + $_DeviceName + ' account')
            write-verbose ('Setting Permissions for Device:' + $_DeviceName + ' OULocation:' + $_OULocationDevice + ' On Domain:' + $_FQDNDomainName)

            $oldSddl = "(OA;;SWRPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;S-1-5-21-1914882237-739871479-3784143264-1145)"
            $DeviceObject = "CN=$_DeviceName,$_OULocationDevice"
            $UserObject = "CN=$_UserNameCluster,$_OULocationUser"

            write-verbose ('ObjectPath set to  AD:' + $DeviceObject)

            $ComputerSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADComputer -Server "$_FQDNDomainName" $DeviceObject).SID
            $ComputerSID = $ComputerSID.Value

            $UserSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADUser -Server "$_FQDNDomainName" $UserObject).SID
            $UserSID = $UserSID.Value

            write-verbose ('Device:' + $_DeviceName + ' SIDValue is:' + $ComputerSID + ' On Domain:' + $_FQDNDomainName)

            $oldSddl -match "S\-1\-5\-21\-[0-9]*\-[0-9]*\-[0-9]*\-[0-9]*" | Out-Null
            $SIDMatch = $Matches[0]

            $oldSddl = $oldSddl -replace ($SIDMatch, $UserSID)

            #$ACLObject = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
            #$ACLObject.SetSecurityDescriptorSddlForm($oldSddl)

            write-verbose ('Device:' + $_DeviceName + ' UserSet is:' + $_UserNameCluster + ' On Domain:' + $_FQDNDomainName)

            $ACL = Get-Acl -Path "AD:$DeviceObject"
            $currentSSDL = $ACL.Sddl


            $newSSDL = $currentSSDL + $oldSddl
            $ACL.SetSecurityDescriptorSddlForm($newSSDL)

            Set-Acl -AclObject $acl -Path "AD:$DeviceObject"
            write-verbose (' Permissions for Device:' + $_DeviceName + ' OULocation:' + $_OULocationDevice + ' On Domain:' + $_FQDNDomainName + ' have been set')
        }
    }

    [bool] Test() {

        Import-Module ActiveDirectory
        New-PSDrive -PSProvider ActiveDirectory -Name AD -Root "" -Server localhost -ErrorAction SilentlyContinue
        Set-Location AD:

        #Set SPN permissions to object to allow it to update SPN registrations.
        $_OULocationUser = $this.OULocationUser
        $_OULocationDevice = $this.OULocationDevice
        $_FQDNDomainName = $this.FQDNDomainName
        $_UserNameCluster = $this.UserNameCluster
        $PermissionTest = $false
        $AccountTrack = @{ }

        Foreach ($user in $this.UserName) {
            $_UserName = $user

            write-verbose ('Checking Permissions for User:' + $_UserName + ' OULocation:' + $_OULocationUser + ' On Domain:' + $_FQDNDomainName)

            $oldSddl = "(OA;;RPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;S-1-5-21-1914882237-739871479-3784143264-1199)"
            $UserObject = "CN=$_UserName,$_OULocationUser"

            write-verbose ('ObjectPath set to  AD:' + $UserObject)

            $UserSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADUser -Server "$_FQDNDomainName" $UserObject).SID
            $UserSID = $UserSID.Value

            write-verbose ('User:' + $_UserName + ' SIDValue is:' + $UserSID + ' On Domain:' + $_FQDNDomainName)

            $oldSddl -match "S\-1\-5\-21\-[0-9]*\-[0-9]*\-[0-9]*\-[0-9]*" | Out-Null
            $SIDMatch = $Matches[0]

            $oldSddl = $oldSddl -replace ($SIDMatch, $UserSID)

            #$ACLObject = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
            #$ACLObject.SetSecurityDescriptorSddlForm($oldSddl)

            $ACL = Get-Acl -Path "AD:$UserObject"
            $currentSSDL = $ACL.Sddl

            IF ($currentSSDL -match ("\(OA;;RPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;$UserSID\)")) {
                write-verbose ('Permissions for SPN are already set')
                $AccountTrack.Add($_UserName, $true)
            }
            ELSE {
                write-verbose ('Permissions for SPN are not currently set')
                $AccountTrack.Add($_UserName, $false)
            }
        }

        Foreach ($device in $this.ClusterDevice) {
            $_DeviceName = $device

            write-verbose ('Checking Permissions for Device:' + $_DeviceName + ' OULocation:' + $_OULocationDevice + ' On Domain:' + $_FQDNDomainName)

            $oldSddl = "(OA;;SWRPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;S-1-5-21-1914882237-739871479-3784143264-1145)"
            $DeviceObject = "CN=$_DeviceName,$_OULocationDevice"
            $UserObject = "CN=$_UserNameCluster,$_OULocationUser"

            write-verbose ('ObjectPath set to  AD:' + $DeviceObject)

            $ComputerSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADComputer -Server "$_FQDNDomainName" $DeviceObject).SID
            $ComputerSID = $ComputerSID.Value

            $UserSID = New-Object System.Security.Principal.SecurityIdentifier (Get-ADUser -Server "$_FQDNDomainName" $UserObject).SID
            $UserSID = $UserSID.Value

            write-verbose ('Device:' + $_DeviceName + ' SIDValue is:' + $ComputerSID + ' On Domain:' + $_FQDNDomainName)

            $oldSddl -match "S\-1\-5\-21\-[0-9]*\-[0-9]*\-[0-9]*\-[0-9]*" | Out-Null
            $SIDMatch = $Matches[0]

            $oldSddl = $oldSddl -replace ($SIDMatch, $ComputerSID)

            #$ACLObject = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
            #$ACLObject.SetSecurityDescriptorSddlForm($oldSddl)

            write-verbose ('Device:' + $_DeviceName + ' UserSet is:' + $_UserNameCluster + ' On Domain:' + $_FQDNDomainName)

            $ACL = Get-Acl -Path "AD:$DeviceObject"
            $currentSSDL = $ACL.Sddl

            IF ($currentSSDL -match ("\(OA;;SWRPWP;f3a64788-5306-11d1-a9c5-0000f80367c1;;$UserSID\)")) {
                write-verbose ('Permissions for SPN are already set')
                $AccountTrack.Add($_DeviceName, $true)
            }
            ELSE {
                write-verbose ('Permissions for SPN are not currently set')
                $AccountTrack.Add($_DeviceName, $false)
            }
        }

        $PermissionTest = $true
        foreach ($object in $AccountTrack.Values) {
            #write-verbose ('Permissions for Object:' + $object)
            IF ($object -eq $false) {
                $PermissionTest = $false
            }
        }

        Return $PermissionTest
    }

    [ActiveDirectorySPN] Get() {
        return $this
    }

}