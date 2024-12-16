enum Ensure {
    Absent
    Present
}

function Invoke-DownloadFile {
    param(
        [string] $url,
        [string] $dest
    )

    if ((Test-Path $dest)) {
        If (-not (Get-Item $dest).length -gt 0kb) {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }

    if (!(Test-Path $dest)) {
        Write-Status "Downloading $url to $dest"
        $dirname = Split-Path $dest -Parent
        New-Item -ItemType Directory -Force -Path $dirname
        try {
            Start-BitsTransfer -Source $url -Destination $dest -Priority Foreground -ErrorAction Stop
        }
        catch {
            Write-Status "Failed Downloading $url to $dest. Retrying"
            ipconfig /flushdns
            start-sleep -seconds 60
            try {
                Start-BitsTransfer -Source $url -Destination $dest -Priority Foreground -ErrorAction Stop
            }
            catch {
                try {
                    Write-Status "Failed Downloading $url to $dest. Retrying with Invoke-WebRequest"
                    Invoke-WebRequest -Uri $url -OutFile $dest -ErrorAction Stop
                    #Start-BitsTransfer -Source $odbcurl -Destination $_odbcpath -Priority Foreground -ErrorAction Stop
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    # Force reboot
                    #[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                    #$global:DSCMachineStatus = 1
                    write-status "Failed to Download $url with error: $ErrorMessage"
                    throw "Failed to Download $url with error: $ErrorMessage"
                    return
                }
            }
        }        
    }

}

[DscResource()]
class InstallADK {
    [DscProperty(Key)]
    [string] $ADKPath

    [DscProperty(Mandatory)]
    [string] $ADKWinPEPath

    [DscProperty(Mandatory)]
    [string] $ADKDownloadPath #  "https://go.microsoft.com/fwlink/?linkid=2196127"

    [DscProperty(Mandatory)]
    [string] $ADKWinPEDownloadPath #  "https://go.microsoft.com/fwlink/?linkid=2243391"

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_adkpath = $this.ADKPath
        $_adkWinPEpath = $this.ADKWinPEPath

        $_ADKDownloadPath = $this.ADKDownloadPath
        $_ADKWinPEDownloadPath = $this.ADKWinPEDownloadPath


        # Use this block to download the FULL ADK, Filename: adksetup.exe
        Invoke-DownloadFile $_ADKDownloadPath $_adkpath
        
        # Use this block to download the WinPE ADK, Filename: adkwinpesetup.exe
        Invoke-DownloadFile $_ADKWinPEDownloadPath $_adkWinPEpath        

        #Install DeploymentTools
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
        Write-Status "Installing ADK DeploymentTools to $adkinstallpath"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkpath
            $arg1 = "/Features"
            $arg2 = "OptionId.DeploymentTools"
            $arg3 = "/q"

            try {
                Write-Status "Installing ADK DeploymentTools..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Status "ADK DeploymentTools Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Status "Failed to install ADK DeploymentTools with below error: $ErrorMessage"
                throw "Failed to install ADK DeploymentTools with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }

        #Install UserStateMigrationTool
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        Write-Status "Installing ADK UserStateMigrationTool to $adkinstallpath"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkpath
            $arg1 = "/Features"
            $arg2 = "OptionId.UserStateMigrationTool"
            $arg3 = "/q"

            try {
                Write-Status "Installing ADK UserStateMigrationTool..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Status "ADK UserStateMigrationTool Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Status "Failed to install ADK UserStateMigrationTool with below error: $ErrorMessage"
                throw "Failed to install ADK UserStateMigrationTool with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }

        #Install WindowsPreinstallationEnvironment
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment"
        Write-Status "Installing ADK WindowsPreinstallationEnvironment to $adkinstallpath"
        while (!(Test-Path $adkinstallpath)) {
            $cmd = $_adkWinPEpath
            $arg1 = "/Features"
            $arg2 = "OptionId.WindowsPreinstallationEnvironment"
            $arg3 = "/q"

            try {
                Write-Status "Installing WindowsPreinstallationEnvironment for ADK..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Status "WindowsPreinstallationEnvironment for ADK Installed Successfully!"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Status "Failed to install WindowsPreinstallationEnvironment for ADK with below error: $ErrorMessage"
                throw "Failed to install WindowsPreinstallationEnvironment for ADK with below error: $ErrorMessage"
            }

            Start-Sleep -Seconds 10
        }
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
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

        Invoke-DownloadFile $this.DownloadUrl $ssmsSetup
                
        # Install SSMS
        $smssinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE"
        $smssinstallpath2 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE"
        $smssinstallpath3 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE"

        if ((Test-Path $smssinstallpath) -or (Test-Path $smssinstallpath2) -or (Test-Path $smssinstallpath3)) {
            Write-Status "SSMS Installed Successfully! (Tested Out)"
            return
        }
        else {

            $cmd = $ssmsSetup
            $arg1 = "/install"
            $arg2 = "/quiet"
            $arg3 = "/norestart"

            try {
                Write-Status "Installing SSMS..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Status "SSMS Installed Successfully!"

                start-sleep -Seconds 60
                # Reboot
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Status "Failed to install SSMS with below error: $ErrorMessage"
                throw "Failed to install SSMS with below error: $ErrorMessage"
            }
            Start-Sleep -Seconds 10
        }
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
        $smssinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe"
        $smssinstallpath2 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe"
        $smssinstallpath3 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe"

        if (Test-Path $smssinstallpath) {
            If ((Get-Item $smssinstallpath).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath exists"
                return $true
            }
        }

        if (Test-Path $smssinstallpath2) {
            If ((Get-Item $smssinstallpath2).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath2 exists"
                return $true
            }
        }
        if (Test-Path $smssinstallpath3) {
            If ((Get-Item $smssinstallpath3).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath3 exists"
                return $true
            }
        }

        Write-Verbose "Test - Installing SSMS... $smssinstallpath3 does not exist"
        return $false
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
        
        Invoke-DownloadFile $this.DownloadUrl $setup
        
        # Install
        $cmd = $setup
        $arg1 = "/q"
        $arg2 = "/norestart"

        try {
            Write-Status "Installing .NET $($this.FileName)..."
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
            Write-Status ".NET $($this.FileName) Installed Successfully!"

            # Reboot
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install .NET with below error: $ErrorMessage"
            throw "Failed to install .NET with below error: $ErrorMessage"
        }
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
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
class InstallODBCDriver {
    [DscProperty(Key)]
    [string] $ODBCPath

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_odbcpath = $this.ODBCPath
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_odbcpath
       
        # Install ODBC Driver
        $cmd = "msiexec"
        $arg1 = "/i"
        $arg2 = $_odbcpath
        $arg3 = "IACCEPTMSODBCSQLLICENSETERMS=YES"
        $arg4 = "/qn"
        #$arg5 = "/lv c:\temp\odbcinstallation.log"

        try {
            Write-Status "Installing Microsoft ODBC Driver 18 for SQL Server..."
            Write-Verbose ("Commandline: $cmd $arg1 $arg2 $arg3 $arg4")
            & $cmd $arg1 $arg2 $arg3 $arg4 #$arg5
            Write-Status "Microsoft ODBC Driver 18 for SQL Server was Installed Successfully!"
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install Microsoft ODBC Driver 18 for SQL Server with error: $ErrorMessage"
            throw "Failed to install Microsoft ODBC Driver 18 for SQL Server with error: $ErrorMessage"
        }
        Start-Sleep -Seconds 10
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
        try {
            $ODBCRegistryPath = "HKLM:\Software\Microsoft\MSODBCSQL18"

            if (Test-Path -Path $ODBCRegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $ODBCVersion = Get-ItemProperty -Path $ODBCRegistryPath -Name "InstalledVersion" -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "Microsoft ODBC Driver 18 for SQL Server Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ($ODBCVersion.InstalledVersion -ge "18.1.2.1") {
                Write-Host "Microsoft ODBC Driver for SQL Server 18.1.2.1 or greater $($ODBCVersion.InstalledVersion) is installed"
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    [InstallODBCDriver] Get() {
        return $this
    }
}

[DscResource()]
class InstallSqlClient {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_path = $this.Path
        $_URL = $this.URL
        Invoke-DownloadFile $_URL $_path

        # Install
        #VC_redist.x64.exe /install /passive /quiet
        $cmd = "msiexec"
        $arg1 = "/i"
        $arg2 = $_path
        $arg3 = "IACCEPTSQLNCLILICENSETERMS=YES"
        $arg4 = "/qn"
        #$arg5 = "/lv c:\temp\odbcinstallation.log"

        try {
            Write-Status "Installing Sql Client..."
            Write-Verbose ("Commandline: $cmd $arg1 $arg2 $arg3 $arg4")
            & $cmd $arg1 $arg2 $arg3 #$arg5
            Write-Status "SQL Client was Installed Successfully!"
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install Sql Client with error: $ErrorMessage"
            throw "Failed to install Sql Client with error: $ErrorMessage"
        }
        Start-Sleep -Seconds 20
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
        try {
            #HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64\Major >= 14
            $RegistryPath = "HKLM:\SOFTWARE\Microsoft\SQLNCLI11"

            if (Test-Path -Path $RegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $Version = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "Sql Client Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ([System.Version]$($Version.InstalledVersion) -ge [System.Version]"11.4.7001.0") {
                Write-Host "Sql Client 11.4.7001.0 or greater $($Version.InstalledVersion) is installed"
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    [InstallSqlClient] Get() {
        return $this
    }
}

[DscResource()]
class InstallVCRedist {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_path = $this.Path
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_path
       
        # Install
        #VC_redist.x64.exe /install /passive /quiet
        $cmd = $_path
        $arg1 = "/install"
        $arg2 = "/passive"
        $arg3 = "/quiet"
        #$arg4 = "/qn"
        #$arg5 = "/lv c:\temp\odbcinstallation.log"

        try {
            Write-Status "Installing VC Redist..."
            Write-Verbose ("Commandline: $cmd $arg1 $arg2 $arg3")
            & $cmd $arg1 $arg2 $arg3 #$arg5
            Write-Status "VC Redist was Installed Successfully!"
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install VC Redist with error: $ErrorMessage"
            throw "Failed to install VC Redist with error: $ErrorMessage"
        }
        Start-Sleep -Seconds 20
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
        try {
            #HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64\Major >= 14
            $RegistryPath = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"

            if (Test-Path -Path $RegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $Version = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "VC Redist Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ($Version.Major -ge "14") {
                Write-Host "VC Redist 14 or greater $($Version.InstalledVersion) is installed"
                return $true
            }
            return $false
        }
        catch {
            return $false
        }
    }

    [InstallVCRedist] Get() {
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
        Write-Status "Installing WSUS..."
        Install-WindowsFeature -Name UpdateServices, UpdateServices-WidDB -IncludeManagementTools
        Write-Status "Finished installing WSUS..."

        Write-Status "Starting the postinstall for WSUS..."
        Set-Location "C:\Program Files\Update Services\Tools"
        .\wsusutil.exe postinstall CONTENT_DIR=C:\WSUS
        Write-Status "Finished the postinstall for WSUS"
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
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
        Write-Status "Setting event $_Node to $_Status in $_LogPath"
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
                    ConfigurationFinished = @{
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

        $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
        Write-Verbose "Attempting to acquire '$_FileName' Mutex"
        [void]$mtx.WaitOne()
        Write-Verbose "Acquired '$_FileName' Mutex"
        $Configuration = $null
        try {
            $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
        }
        finally {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }
        while ($Configuration.$($this.ReadNode).Status -ne $this.ReadNodeValue) {
            Write-Verbose "Wait for step: [$($this.ReadNode)] to finish on $($this.MachineName), will try 60 seconds later..."
            Start-Sleep -Seconds 60
            $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
            Write-Verbose "Attempting to acquire '$_FileName' Mutex"
            [void]$mtx.WaitOne()
            Write-Verbose "Acquired '$_FileName' Mutex"
            try {
                $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
            }
            finally {
                [void]$mtx.ReleaseMutex()
                [void]$mtx.Dispose()
            }
        }
        Write-Status "Step: [$($this.ReadNode)] Finished on $($this.MachineName)"
    }

    [bool] Test() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_FilePath = "\\$($this.MachineName)\$($this.LogFolder)"
        $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"

        if (!(Test-Path $ConfigurationFile)) { return $false }
        $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
        Write-Verbose "Attempting to acquire '$_FileName' Mutex"
        [void]$mtx.WaitOne()
        Write-Verbose "acquired '$_FileName' Mutex"
        try {
            $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
            if ($Configuration.$($this.ReadNode).Status -eq $this.ReadNodeValue) {
                return $true
            }
            return $false
        }
        catch {
            return $false
        }
        finally {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
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

    [DscProperty()]
    [System.Management.Automation.PSCredential] $AdminCreds

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {

        Write-Status "Extend Schema. Testing network connection"
        $success = $false
        while ($success -eq $false) {
            if ($this.AdminCreds) {
                $user = $this.AdminCreds.UserName
                $pass = $this.AdminCreds.GetNetworkCredential().Password
                $machine = "\\$($this.MachineName)"
                Write-Verbose "Running New-SmbMapping -RemotePath \\$machine -UserName $user -Password $pass"
                Write-Status "Testing connection to \\$machine for user $user"
                $smb = New-SmbMapping -RemotePath $machine -UserName $user -Password $pass
                if ($smb) {
                    Write-Verbose "Mapping success: $smb"
                    $success = $true
                }
                else {
                    Write-Status "Could not get a connection to \\$machine for user $user. Retrying."
                    Write-Verbose "Mapping Failure.."
                    start-sleep -Seconds 30
                }
            }
            else {
                Write-Verbose "No AdminCreds passed.. Moving on"
                $success = $true
            }
        }

        $_FilePath = "\\$($this.MachineName)\$($this.ExtFolder)"
        $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath2 = Join-Path -Path $_FilePath -ChildPath "cd.retail\SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath3 = Join-Path -Path $_FilePath -ChildPath "cd.retail.LN\SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath4 = Join-Path -Path $_FilePath -ChildPath "cd.preview\SMSSETUP\BIN\X64\extadsch.exe"
        while (!(Test-Path $extadschpath) -and !(Test-Path $extadschpath2) -and !(Test-Path $extadschpath3) -and !(Test-Path $extadschpath4)) {
            Write-Verbose "Testing $extadschpath and $extadschpath2 and $extadschpath3"
            Write-Status "Wait for extadsch.exe exist on $($this.MachineName), will try 10 seconds later..."
            Start-Sleep -Seconds 10
            $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath2 = Join-Path -Path $_FilePath -ChildPath "cd.retail\SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath3 = Join-Path -Path $_FilePath -ChildPath "cd.retail.LN\SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath4 = Join-Path -Path $_FilePath -ChildPath "cd.preview\SMSSETUP\BIN\X64\extadsch.exe"
        }

        Write-Status "Extending the Active Directory schema..."

        # Force AD Replication
        $domainControllers = Get-ADDomainController -Filter *
        if ($domainControllers.Count -gt 1) {
            Write-Status "Forcing AD Replication on $($domainControllers.Name -join ',')"
            $domainControllers.Name | Foreach-Object { repadmin /syncall $_ (Get-ADDomain).DistinguishedName /AdeP }
            Start-Sleep -Seconds 3
        }

        if (Test-Path $extadschpath) {
            Write-Status "Running $extadschpath"
            & $extadschpath | out-null
        }
        if (Test-Path $extadschpath2) {
            Write-Status "Running $extadschpath2"
            & $extadschpath2 | out-null
        }

        if (Test-Path $extadschpath3) {
            Write-Status "Running $extadschpath3"
            & $extadschpath3 | out-null
        }

        if (Test-Path $extadschpath4) {
            Write-Status "Running $extadschpath4"
            & $extadschpath4 | out-null
        }
        Write-Status "Done Extending Schema"
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

    [DscProperty()]
    [bool] $IsGroup

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_machinename = $this.Machine
        $root = (Get-ADRootDSE).defaultNamingContext
        $ou = $null

        
        try {
            Write-Status "Getting AD Object: CN=System Management,CN=System,$root"
            $ou = Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
        }
        if ($null -eq $ou) {
            Write-Status "Creating new AD Object: CN=System Management,CN=System,$root"
            $ou = New-ADObject -Type Container -name "System Management" -Path "CN=System,$root" -Passthru
        }
        $DomainName = $this.DomainFullName.split('.')[0]
        #Delegate Control
        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $arg2 = "/G"
        if ($this.IsGroup) {
            $arg3 = "" + $this.DomainFullName + "\" + $this.Machine + "`:GA;;"
        }
        else {
            $arg3 = "" + $DomainName + "\" + $this.Machine + "`$:GA;;"

        }
        $arg4 = "/I:T"


        $retries = 0
        $maxretries = 15
        while ($retries -le $maxretries) {

            ipconfig /flushdns

            if ($retries -eq 5) {
                $_FileName = "C:\temp\SysMgmt.txt"

                if (-not (Test-Path $_FileName)) {
                    Write-Status "dsacls.exe failed to add permissions 5 time.. Attempting reboot."
                    Write-Verbose "Rebooting"
                    New-Item $_FileName
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                    $global:DSCMachineStatus = 1
                    return
                }
            }

            $retries++
            Write-Status "Running dsacls.exe to add FULL Control to CN=System Management. Try $retries/$maxretries"
            Write-Verbose "Running $cmd $arg1 $arg2 $arg3 $arg4"
            $result = & $cmd $arg1 $arg2 $arg3 $arg4 *>&1

            Write-Verbose "Result $result"

            $tcmd = "dsacls.exe"
            $targ1 = "CN=System Management,CN=System,$root"
            $permissioninfo = & $tcmd $targ1

            if ($this.IsGroup) {
                Write-Verbose "Testing for *$($DomainName)\$($_machinename)* IsGroup: $($this.IsGroup)"
                if (($permissioninfo | Where-Object { $_ -like "*$($DomainName)\$($_machinename)*" } | Where-Object { $_ -like "*FULL CONTROL*" }).COUNT -gt 0) {
                    break
                }
            }
            else {
                Write-Verbose "Testing for *$($_machinename)$* IsGroup: $($this.IsGroup)"
                if (($permissioninfo | Where-Object { $_ -like "*$($_machinename)$*" } | Where-Object { $_ -like "*FULL CONTROL*" }).COUNT -gt 0) {
                    break
                }
            }

            Write-Verbose "$tcmd $targ1 did not contain the new permissions. Sleeping 60 seconds and trying again"
            Write-Verbose "$permissioninfo"
            Start-Sleep -Seconds 60

        }


    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
        $_machinename = $this.Machine
        $DomainName = $this.DomainFullName.split('.')[0]
        $root = (Get-ADRootDSE).defaultNamingContext
        try {
            Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
            return $false
        }

        Write-Verbose "Testing for *$($DomainName)\$($_machinename)* IsGroup: $($this.IsGroup)"
        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $permissioninfo = & $cmd $arg1

        if ($this.IsGroup) {
            if (($permissioninfo | Where-Object { $_ -like "*$($DomainName)\$($_machinename)*" } | Where-Object { $_ -like "*FULL CONTROL*" }).COUNT -gt 0) {
                return $true
            }
        }
        else {
            if (($permissioninfo | Where-Object { $_ -like "*$($_machinename)$*" } | Where-Object { $_ -like "*FULL CONTROL*" }).COUNT -gt 0) {
                return $true
            }
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
        Write-Status "Adding NTFS permissions to C:\tools"
        $testPath = "C:\staging\DSC\AddNtfsPermissions.txt"
        & icacls C:\tools /grant "Users:(M,RX)" /t | Out-File $testPath -Force -ErrorAction SilentlyContinue
        & icacls C:\temp /grant "Users:F" /t | Out-File $testPath -Append -Force
        & takeown /F C:\windows\system32\Configuration /A /R | Out-File $testPath -Append -Force
        & icacls C:\windows\system32\Configuration /grant "Administrators:F" /t | Out-File $testPath -Append -Force
    }

    [bool] Test() {
        Write-Status "DSC Test- Checking deployment status"
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
class DownloadSCCM {
    [DscProperty(Key)]
    [string] $CM

    [DscProperty(Key)]
    [string] $CMDownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_CM = $this.CM
        $_CMURL = $this.CMDownloadUrl
        $cmpath = "c:\temp\$_CM.exe"
        $cmsourcepath = "c:\$_CM"
        Write-Status "Downloading [$_CMURL] $_CM installation source... to $cmpath"

        Invoke-DownloadFile $_CMURL $cmpath
        
        if (Test-Path $cmsourcepath) {
            Remove-Item -Path $cmsourcepath -Recurse -Force | Out-Null
        }

        if (!(Test-Path $cmsourcepath)) {

            Write-Status "Extracting $cmpath to $cmsourcepath"
            if (($_CMURL -like "*MCM_*") -or ($_CMURL -like "*go.microsoft.com*")) {
                $size = (Get-Item $cmpath).length / 1GB
                if ($size -gt 1) {
                    Start-Process -Filepath ($cmpath) -ArgumentList ('-d' + $cmsourcepath + ' -s2') -Wait
                }
                else {
                    Start-Process -Filepath ($cmpath) -ArgumentList ('/extract:"' + $cmsourcepath + '" /quiet') -Wait
                }
            }
            else {
                Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -Wait
            }
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
        Write-Verbose "Downloading file from $($this.DownloadUrl) to $($this.FilePath)..."
        Invoke-DownloadFile $this.DownloadUrl $this.FilePath
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
        Write-Verbose "Domain Controller is: $_DCName"
        $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        while (!$testconnection) {
            Write-Status "Waiting for Domain ready. Trying to ping $_DCName, will try again 30 seconds later..."
            ipconfig /flushdns
            ipconfig /renew
            ipconfig /registerdns
            Start-Sleep -Seconds $_WaitSeconds
            $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        }
        Write-Status "Domain is ready now."
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
                Write-Status "[adsisearcher] Waiting for $CL to join domain. Retrying in 30 Seconds."
                Start-Sleep -Seconds 30
                $searcher = [adsisearcher] "(cn=$CL)"
            }
            Write-Status "$CL has joined the domain."
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
        Write-Status "Set dns: $_DNSIPAddress for $($dnsset.InterfaceAlias)"
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

function Write-Status {
    param(
        [String] $Status
    )
    $_Status = $Status

    $StatusFile = "C:\staging\DSC\DSC_Status.txt"
    $StatusLog = "C:\staging\DSC\DSC_Log.log"
    try {
        Write-Verbose "Writing Status: $_Status"    

        try {
            try {
                [void](Get-Variable this -ErrorAction Stop)
                $Static = $false
            }
            catch {
                $Static = $true
            }
            if ($Static) {
                $prefix = (Get-PSCallStack)[1].FunctionName
            }
            else {
                $prefix = $this.gettype().Name
            }      
            if ($prefix -ne "WriteStatus") {
                $_Status = "$($prefix)`: $($_Status)"      
            }
        }
        catch {}
        $AlreadyComplete = $false
        if (Test-Path $StatusFile) {
            try {
                $AlreadyComplete = (Get-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue) -eq "Complete!"
            }
            catch {}
        }

        if (-not $AlreadyComplete) {
            "$_Status" | Out-File -FilePath $StatusFile -Force
        }
    

        try {
            try {
                $caller = (Get-PSCallStack | Select-Object Command, Location, Arguments)[1].Command
                if (-not $caller) {
                    $caller = $this.gettype().Name
                }
            }
            catch {}
            $Text = $_Status.ToString().Trim()
            $CallingFunction = Get-PSCallStack | Select-Object -first 2 | select-object -last 1
            $context = $CallingFunction.Command
            if (-not $context) {
                $context = $CallingFunction.FunctionName
            }
            $file = $CallingFunction.Location
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $date = Get-Date -Format 'MM-dd-yyyy'
            $time = Get-Date -Format 'HH:mm:ss.fff'

            $logText = "<![LOG[$Text]LOG]!><time=""$time"" date=""$date"" component=""$caller"" context=""$context"" type=""Status"" thread=""$tid"" file=""$file"">"
            $logText | Out-File $StatusLog -Append -Encoding utf8
            Write-Progress -Activity $caller -Status $Text -PercentComplete 50
        }
        catch {
            try {
                # Retry once and ignore if failed
                $logText | Out-File $StatusLog -Append -ErrorAction SilentlyContinue -Encoding utf8
            }
            catch {
                $_Status | Out-File $StatusLog -Append -ErrorAction SilentlyContinue -Encoding utf8
            }
        }
    }
    catch {
        Write-Verbose $_
    }

}

[DscResource()]
class WriteStatus {
    [DscProperty(key)]
    [string] $Status

    [void] Set() {

        $_Status = $this.Status
        Write-Status $_Status 
    }

    [bool] Test() {
        $_Status = $this.Status
        $StatusLog = "C:\staging\DSC\DSC_Log.log"

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

        Write-Status "Writing specified content to $_FilePath"

        $_Content | Out-File -FilePath $_FilePath -Force
        "WriteFileOnce" | Out-File -FilePath $flag -Force

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
                    Write-Status "$sqlAgentService need to be stopped first"
                    $Result = $sqlserveragentservices.StopService()
                    Write-Status "Stopping $sqlAgentService.."
                    if ($Result.ReturnValue -eq '0') {
                        $sqlserveragentflag = 1
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
                    }
                }
            }
            $Result = $services.StopService()
            Write-Status "Stopping SQL Server services.."
            if ($Result.ReturnValue -eq '0') {
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
            }

            Write-Status "Changing the services account to LocalSystem..."

            $Result = $services.change($null, $null, $null, $null, $null, $null, "LocalSystem", $null, $null, $null, $null)
            if ($Result.ReturnValue -eq '0') {
                Write-Status "Successfully Changed the service account"
                if ($sqlserveragentflag -eq 1) {
                    Write-Status "Starting $sqlAgentService.."
                    $Result = $sqlserveragentservices.StartService()
                    if ($Result.ReturnValue -eq '0') {
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Started"
                    }
                }
                $Result = $services.StartService()
                Write-Status "Starting SQL Server services.."
                while ($Result.ReturnValue -ne '0') {
                    $returncode = $Result.ReturnValue
                    Write-Status "Start Service Returned $returncode, Retry in 10 seconds"
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

        #if ($_SQLInstanceName -eq "MSSQLSERVER") {
        #    return
        #}

        Try {
            # Load the assemblies
            Write-Status "[ChangeSqlInstancePort]: Setting port for $_SQLInstanceName to $_SQLInstancePort"

            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | Out-Null
            $mc = new-object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $env:COMPUTERNAME
            $i = $mc.ServerInstances[$_SQLInstanceName]
            $p = $i.ServerProtocols['Tcp']
            foreach ($ip in $p.IPAddresses) {
                #$ip = $p.IPAddresses['IPAll']
                $ip.IPAddressProperties['TcpDynamicPorts'].Value = ''
                $ipa = $ip.IPAddressProperties['TcpPort']
                $ipa.Value = [string]$_SQLInstancePort
            }
            $p.Alter()


            New-NetFirewallRule -DisplayName 'SQL over TCP Inbound (Named Instance)' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort $_SQLInstancePort -Group "For SQL Server"

        }
        Catch {
            Write-Status "ERROR[ChangeSqlInstancePort]: SET Failed: $($_.Exception.Message)"
        }
    }

    [bool] Test() {

        $_SQLInstanceName = $this.SQLInstanceName
        $_SQLInstancePort = $this.SQLInstancePort

        #if ($_SQLInstanceName -eq "MSSQLSERVER") {
        #    return $true
        #}

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



        $RegisterTime = [datetime]::Now
        $waitTime = 30

        $success = $this.RegisterTask()
        $lastRunTime = $this.GetLastRunTime()
        $failCount = 0
        Write-Status "Starting task $_Taskname from $_ScriptPath $_ScriptName $_ScriptArgument"
        Write-Verbose "lastRunTime: $lastRunTime   RegisterTime: $RegisterTime"
        while ($lastRunTime -lt $RegisterTime) {
            Write-Verbose "Checking to see if task has started Attempt $failCount"
            Write-Verbose "lastRunTime: $lastRunTime   RegisterTime: $RegisterTime"

            if ($failCount -gt 2) {
                Write-Verbose "Manually starting the task"
                Start-ScheduledTask -TaskName $_TaskName
                start-sleep $waitTime
                $lastRunTime = $this.GetLastRunTime()
            }

            if ($failCount -eq 5) {
                Write-Status "$_TaskName has not ran yet after 5 Cycles. Re-Registering Task"
                #Unregister existing task
                $success = $this.RegisterTask()

            }

            if ($failCount -eq 8) {
                Write-Status "$_TaskName failed to run after 8 retries, and reregistration. Exiting. Please check Task Scheduler for Task: $_TaskName"
                throw "Task failed to run after 8 retries, and reregistration. Exiting. Please check Task Scheduler for Task: $_TaskName"
            }

            if ($lastRunTime -gt $RegisterTime) {
                Write-Status "$_Taskname was successfully started at $lastRunTime"
                break
            }
            else {
                Write-Status "$_Taskname has not started. Last run time was: $lastRunTime"
                $failCount++
            }
            start-sleep -Seconds $waitTime
            $lastRunTime = $this.GetLastRunTime()
        }
        Write-Status "$_TaskName was successfully started at $lastRunTime"



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

        $exists = Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
        if ($exists) {
            if ($exists.state -eq "Running") {
                Stop-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue                                
            }
            Unregister-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
            return $false
        }
        return $false
    }

    [RegisterTaskScheduler] Get() {
        return $this
    }


    [bool] RegisterTask() {
        $ProvisionToolPath = "$env:windir\temp\ProvisionScript"
        if (!(Test-Path $ProvisionToolPath)) {
            New-Item $ProvisionToolPath -ItemType directory | Out-Null
        }
        Write-Status "Checking for existing task: $($this.TaskName)"
        $exists = Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Status "Task $($this.TaskName) already exists. Removing"
            if ($exists.state -eq "Running") {
                stop-Process -Name setup -Force -ErrorAction SilentlyContinue
                stop-Process -Name setupwpf -Force -ErrorAction SilentlyContinue
                $exists | Stop-ScheduledTask -ErrorAction SilentlyContinue
            }
            Unregister-ScheduledTask -TaskName $($this.TaskName) -Confirm:$false
            Write-Status "Task $($this.TaskName) Removed"
            Start-Sleep -Seconds 10
        }

        $sourceDirctory = "$($this.ScriptPath)\*"
        $destDirctory = "$ProvisionToolPath\"

        Write-Status "Copying $sourceDirctory to $destDirctory"
        Copy-item -Force -Recurse $sourceDirctory -Destination $destDirctory

        $TaskDescription = "vmbuild task"
        $TaskCommand = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $TaskScript = "$ProvisionToolPath\$($this.ScriptName)"

        Write-Status "Task script full path is : $TaskScript "

        $TaskArg = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $TaskScript $($this.ScriptArgument)"

        $Action = New-ScheduledTaskAction -Execute $TaskCommand -Argument $TaskArg
        Write-Verbose "New-ScheduledTaskAction : $TaskCommand $TaskArg"

        # Seconds to wait to start task
        $waitTime = 15
        $TaskStartTime = [datetime]::Now.AddSeconds($waitTime)
        $RegisterTime = [datetime]::Now
        #$Trigger = New-ScheduledTaskTrigger -Once -At $TaskStartTime
        #Write-Verbose "Time is now: $RegisterTime Task Scheduled to run at $TaskStartTime"

        $Principal = New-ScheduledTaskPrincipal -UserId $($this.AdminCreds.UserName) -RunLevel Highest
        $Password = $($this.AdminCreds).GetNetworkCredential().Password
        $certauthFile = $destDirctory + "\" + "certauth.txt"
        $Password | Out-file -FilePath $certauthFile -Force

        $Task = New-ScheduledTask -Action $Action -Description $TaskDescription -Principal $Principal

        $Task | Register-ScheduledTask -TaskName $($this.TaskName) -User $($this.AdminCreds.UserName) -Password $Password -Force | out-Null

        start-sleep -Seconds $waitTime

        Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) is starting"
        Start-ScheduledTask -TaskName $($this.TaskName)
        Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) has Started."

        return $true

    }

    [datetime] GetLastRunTime() {

        $filterXML = @'
        <QueryList>
         <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
          <Select Path="Microsoft-Windows-TaskScheduler/Operational">
           *[EventData/Data[@Name='TaskName']='\TEMPLATE']
          </Select>
         </Query>
        </QueryList>
'@

        $filterXML = $filterXML -replace ("TEMPLATE", $this.TaskName)
        $Lastevent = (Get-WinEvent  -FilterXml $filterXML -ErrorAction Stop) | Where-Object { $_.ID -eq 100 } | Select-Object -First 1

        if ($Lastevent) {
            Write-Verbose "Last Run Time is $($Lastevent.TimeCreated)"
            return $Lastevent.TimeCreated
        }
        Write-Verbose "No Last Run Time found returning $([datetime]::MinValue)"
        return [datetime]::MinValue

    }
}

[DscResource()]
class InitializeDisks {
    [DscProperty(key)]
    [string] $DummyKey

    [DscProperty(Mandatory)]
    [string] $VM

    [void] Set() {

        Write-Status "Initializing disks"

        $_VM = $this.VM | ConvertFrom-Json
        $_Disks = $_VM.additionalDisks

        # For debugging
        Write-Status  "VM Additional Disks: $_Disks"
        Get-Disk | Write-Verbose

        if ($null -eq $_Disks) {
            Write-Verbose "No disks to initialize."
            return
        }

        # Loop through disks
        $count = 0
        $label = "DATA"
        foreach ($disk in $_Disks.psobject.properties) {
            Write-Status "Assigning $($disk.Name) Drive Letter to disk with size $($disk.Value)"
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
            Write-Status "Moving CD-ROM drive to Z:.."
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
class AddUserToLocalAdminGroup {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Key)]
    [string] $NetbiosDomainName

    [void] Set() {
        $_DomainName = $($this.NetbiosDomainName)
        $_Name = $this.Name
        $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
        $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
        Write-Status "Adding $_DomainName\$_Name to administrators group"
        if (-not $GroupObj.IsMember("WinNT://$_DomainName/$_Name")) {
            $GroupObj.Add("WinNT://$_DomainName/$_Name")
        }

    }

    [bool] Test() {
        $_DomainName = $($this.NetbiosDomainName)
        $_Name = $this.Name
        $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
        $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Testing $_DomainName\$_Name is in administrators group"
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
            Write-Status "Joining computer to Domain $_DomainName"
            Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Stop
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
            $count = 0
            Write-Status "Failed to join into the domain $_DomainName, retry $count/$_retryCount"
            $flag = $false
            while ($CurrentDomain -ne $_DomainName) {
                if ($count -lt $_retryCount) {
                    $count++
                    Write-Status "Current Domain of $CurrentDomain does not match $_DomainName. Retry count: $count/$_retryCount"
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
                Write-Status "Failed too many times.  Rejoining domain, and rebooting."
                Add-Computer -DomainName $_DomainName -Credential $_credential
            }
            else {
                Write-Status "Domain Join Successful. Rebooting."
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

        Write-Status "Opening firewall ports for Role:$_Role"

        New-NetFirewallRule -DisplayName "Cluster Network Outbound" -Profile Any -Direction Outbound -Action Allow -RemoteAddress "10.250.250.0/24"
        New-NetFirewallRule -DisplayName "Cluster Network Inbound" -Profile Any -Direction Inbound -Action Allow -RemoteAddress "10.250.250.0/24"

        New-NetFirewallRule -DisplayName 'WinRM Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(5985, 5986) -Group "For WinRM"
        New-NetFirewallRule -DisplayName 'WinRM Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(5985, 5986) -Group "For WinRM"
        New-NetFirewallRule -DisplayName 'RDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -Group "For RdcMan"

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
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-28502"
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

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM"

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
        if ($_Role -contains "State Migration Point") {
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
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM PXE SP"

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
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM RSP"
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
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM MP"
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
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Domain -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SLP"
            #Dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM RSP"
        }
        if ($_Role -contains "SQL Server") {
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Domain -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SQL Server"
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
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-28502"
            Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)" -Direction Inbound
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Client"
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Client"


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

    [DscProperty(NotConfigurable)]
    [string] $Version = "4"

    [void] Set() {
        $_Role = $this.Role

        Write-Status "Installing Windows Features for Role $_Role"

        # Install on all devices
        try {
            Write-Status "Installing Windows Feature TelnetClient"
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

            #
            #
            #
            #   If you add roles here, please update the Version number so existing Machines will get the new roles
            #
            #
            #

            # Always install BITS
            Write-Status "Installing Windows Features: BITS, BITS-IIS-Ext"
            Install-WindowsFeature BITS, BITS-IIS-Ext

            # Always install IIS
            Write-Status "Installing Windows Features: Web-Windows-Auth, web-ISAPI-Ext"
            Install-WindowsFeature Web-Windows-Auth, web-ISAPI-Ext

            Write-Status "Installing Windows Features: Web-WMI, Web-Metabase"
            Install-WindowsFeature Web-WMI, Web-Metabase

            Write-Status "Installing Windows Features: RSAT-AD-PowerShell"
            Install-WindowsFeature RSAT-AD-PowerShell

            Write-Status "Installing Windows Features: AD-Domain-Services"
            $result = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
            if ($result.RestartNeeded -eq "Yes") {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }

            if ($_Role -notcontains "DomainMember") {
                Write-Status "Installing Windows Features: Rdc"
                Install-WindowsFeature -Name "Rdc"
            }

            if ($_Role -contains "DC") {
                #Moved to All Servers
                #Install-WindowsFeature RSAT-AD-PowerShell
            }
            if ($_Role -contains "SQLAO") {
                Write-Status "Installing Windows Features: Failover-clustering, RSAT-Clustering-PowerShell, RSAT-Clustering-CmdInterface, RSAT-Clustering-Mgmt, RSAT-AD-PowerShell"
                Install-WindowsFeature Failover-clustering, RSAT-Clustering-PowerShell, RSAT-Clustering-CmdInterface, RSAT-Clustering-Mgmt, RSAT-AD-PowerShell
            }
            if ($_Role -contains "Site Server") {
                Write-Status "Installing Windows Features: Net-Framework-Core"
                Install-WindowsFeature Net-Framework-Core

                Write-Status "Installing Windows Features: NET-Framework-45-Core"
                Install-WindowsFeature "NET-Framework-45-Core"

                Write-Status "Installing Windows Features: Web-Basic-Auth, Web-IP-Security, Web-Url-Auth, Web-Windows-Auth, Web-ASP, Web-Asp-Net, web-ISAPI-Ext"
                Install-WindowsFeature Web-Basic-Auth, Web-IP-Security, Web-Url-Auth, Web-Windows-Auth, Web-ASP, Web-Asp-Net, web-ISAPI-Ext

                Write-Status "Installing Windows Features: Web-Mgmt-Console, Web-Lgcy-Mgmt-Console, Web-Lgcy-Scripting, Web-WMI, Web-Metabase, Web-Mgmt-Service, Web-Mgmt-Tools, Web-Scripting-Tools"
                Install-WindowsFeature Web-Mgmt-Console, Web-Lgcy-Mgmt-Console, Web-Lgcy-Scripting, Web-WMI, Web-Metabase, Web-Mgmt-Service, Web-Mgmt-Tools, Web-Scripting-Tools
                #Install-WindowsFeature BITS, BITS-IIS-Ext

                Write-Status "Installing Windows Features: Rdc"
                Install-WindowsFeature -Name "Rdc"

                Write-Status "Installing Windows Features: UpdateServices-UI"
                Install-WindowsFeature -Name UpdateServices-UI
                #Install-WindowsFeature -Name WDS
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
            if ($_Role -contains "WSUS") {
                Write-Status "Installing Windows Features: WSUS Stuff.. This shouldnt be used anymore."
                Install-WindowsFeature "UpdateServices-Services", "UpdateServices-RSAT", "UpdateServices-API", "UpdateServices-UI"
            }
            if ($_Role -contains "State migration point") {
                #iis
                Install-WindowsFeature Web-Default-Doc, Web-Asp-Net, Web-Asp-Net45, Web-Net-Ext, Web-Net-Ext45, Web-Metabase
            }
        }

        $StatusPath = "$env:windir\temp\InstallFeatureStatus$($this.Role)$($this.Version).txt"
        "Finished" >> $StatusPath
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\InstallFeatureStatus$($this.Role)$($this.Version).txt"
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
        Write-Status "Creating Page file on $_Drive"
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
        Write-Status "Page file configured. Rebooting"
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
class FileReadAccessShare {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string] $Path

    [void] Set() {
        $_Name = $this.Name
        $_Path = $this.Path

        Write-Status  "Creating SMB Share $_Name -> $_Path"
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

    [DscProperty()]
    [string] $RootCA

    [void] Set() {
        try {
            $_HashAlgorithm = $this.HashAlgorithm
            #Install CA
            Import-Module ServerManager
            Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools

            if ($this.RootCA) {
                Write-Status "Installing Root CA with Hash Algorithm $_HashAlgorithm"
                Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa  -ParentCA $($this.RootCA) -force
            }
            else {
                Write-Status "Installing Non-Root CA with Hash Algorithm $_HashAlgorithm"
                Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -KeyLength 2048 -HashAlgorithmName $_HashAlgorithm -force
            }

            $StatusPath = "$env:windir\temp\InstallCAStatus.txt"
            "Finished" >> $StatusPath

            Write-Status "Finished installing CA."
        }
        catch {
            Write-Status "Failed to install CA."
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
class UpdateCAPrefs {
    [DscProperty(Key)]
    [string] $RootCA

    [void] Set() {
        try {
            certutil -setreg Policy\EditFlags +EDITF_ENABLELDAPREFERRALS
            Restart-Service -Name certsvc
            $StatusPath = "$env:windir\temp\UpdateCAStatus.txt"
            "Finished" >> $StatusPath

            Write-Status "Finished installing CA."
        }
        catch {
            Write-Status "Failed to install CA. $_"
        }
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\UpdateCAStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [UpdateCAPrefs] Get() {
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
        $_ClusterName = $this.ClusterName
        $_Nodes = $this.Nodes
        try {
            foreach ($c in Get-ClusterResource -Cluster $_ClusterName) {
                $NeedsFixing = $c | Get-ClusterOwnerNode | Where-Object { $_.OwnerNodes.Count -ne 2 }
                if ($NeedsFixing) {
                    Write-Status "Cluster $_ClusterName`: Setting Cluster Node owners $($_Nodes -Join ',') on $($c.Name)"
                    $c | Set-ClusterOwnerNode -owners $_Nodes
                }
            }
        }
        catch {
            Write-Status "$_ClusterName Failed to Set Owner Nodes"
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
            Write-Status "Failed to Find Cluster Resources."
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
            $valid = $false
            [int]$failCount = 0
            Write-Status "Getting Cluster $_ClusterName"
            $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
            if ($Cluster) {
                $valid = $true
            }
            while (-not $valid -and $failCount -lt 15) {
                Write-Status "Failed to get Cluster $_ClusterName. Retrying $failCount/15"
                try {
                    $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
                    if ($Cluster) {
                        $valid = $true
                    }
                    else {
                        $failCount++
                        start-sleep 60
                    }
                }
                catch {
                    Write-Verbose "$_ Failed Get-ClusterResource for $_ClusterName"
                    $failCount++
                    start-sleep 60
                }
            }
            $ResourcesToRemove = ($Cluster | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject
            if ($ResourcesToRemove) {
                foreach ($Resource in $ResourcesToRemove) {
                    Write-Status "Cluster Removing $($resource.Name)"
                    Remove-ClusterResource -Name $resource.Name -Force
                }
            }
            Write-Status "Cluster Registering new DNS records"
            Get-ClusterResource -Name "Cluster Name" | Update-ClusterNetworkNameResource
            Write-Status "Finished Removing Unwanted Cluster IPs"
        }
        catch {
            Write-Status "Failed to Remove Cluster IPs."
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $_ClusterName = $this.ClusterName
            $valid = $false
            [int]$failCount = 0
            $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
            if ($Cluster) {
                $valid = $true
            }
            while (-not $valid -and $failCount -lt 15) {
                try {
                    $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
                    if ($Cluster) {
                        $valid = $true
                    }
                    else {
                        Write-Verbose "$_ Get-ClusterResource for $_ClusterName did not return an entry"
                        $failCount++
                        start-sleep 60
                    }
                }
                catch {
                    Write-Verbose "$_ Failed Get-ClusterResource for $_ClusterName"
                    $failCount++
                    start-sleep 60
                }
            }
            $ResourcesToRemove = ($Cluster | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject

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

        write-Status "Installing powershell module $_moduleName for scope $_userScope"
        $Nuget = $null
        try {
            $NuGet = Get-PackageProvider -Name Nuget -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -ListAvailable
        }
        catch { }
        
        IF ($null -eq $NuGet) {
            #Install-PackageProvider Nuget -force -Confirm:$false
            Find-PackageProvider -Name NuGet -Force | Install-PackageProvider -Force -Scope AllUsers -Confirm:$false
            Register-PackageSource -Name nuget.org -Location https://www.nuget.org/api/v2 -ProviderName NuGet -Force -Trusted
        }

        $module = Get-InstalledModule -Name PowerShellGet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 

        IF ($null -eq $module) {
            try { 
                Install-Module -Name PowerShellGet -Force -Confirm:$false -Scope $_userScope -ErrorAction Stop
            }
            catch {
                write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope"
                Start-Sleep -Seconds 120
                Install-Module -Name PowerShellGet -Force -Confirm:$false -Scope $_userScope -SkipPublisherCheck -Force -AcceptLicense -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
        }

        $module = Get-InstalledModule -Name $_moduleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        IF ($null -eq $module) {
            IF ($this.Clobber -eq 'Yes') {
                try {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -ErrorAction Stop
                }
                catch {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope.."
                    Start-Sleep -Seconds 120
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -SkipPublisherCheck -Force -AcceptLicense -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
            ELSE {
                try {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope..."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -ErrorAction Stop
                }
                catch {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope...."
                    Start-Sleep -Seconds 120
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -SkipPublisherCheck -Force -AcceptLicense -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
        }
    }

    [bool] Test() {

        $_ModuleName = $this.CheckModuleName
        write-verbose ('Searching for module:' + $_ModuleName)
        $GetModuleStatus = Get-InstalledModule -Name $_ModuleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        if ($GetModuleStatus) {
            write-verbose ('Found module:' + $_ModuleName + 'ModuleStatus:' + $GetModuleStatus.Version)
            return $true
        }

        return $false

    }

    [ModuleAdd] Get() {
        return $this
    }

}


[DscResource()]
class ConfigureWSUS {
    [DscProperty(Key)]
    [string] $ContentPath

    [DscProperty()]
    [string]$SqlServer

    [DscProperty()]
    [string]$HTTPSUrl
    # Should usually be 'ConfigMgr WebServer Certificate'
    [DscProperty()]
    [string]$TemplateName

    [void] Set() {

        $_HTTPSurl = $this.HTTPSUrl
        $_FriendlyName = $this.TemplateName
        $postinstallOutput = ""
        try {
            #write-Status ("Configuring WSUS for $($this.SqlServer) in $($this.ContentPath)")
            try {
                New-Item -Path $this.ContentPath -ItemType Directory -Force
            }
            catch {
                write-verbose ("$_")
            }

            if ($this.SqlServer) {
                write-Status ("Configuring WSUS for $($this.SqlServer) in $($this.ContentPath)")
                write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath)")
                $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath) 2>&1
            }
            else {
                write-Status ("Configuring WSUS for WID in $($this.ContentPath)")
                write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath)")
                $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath) 2>&1
            }
        }
        catch {
            Write-Status "Failed to Configure WSUS"
            Write-Verbose "$_ $postinstallOutput"
        }
        try {
            $wsus = get-WsusServer
        }
        catch {
            Write-Status "Failed to Configure WSUS"
            Write-Verbose "$_"
            throw
        }

        if ($this.HTTPSUrl) {
            Write-Status "Configuring HTTPS for WSUS"
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            if (-not $cert) {
                Write-Status "Could not find cert with friendly Name $_FriendlyName"
                throw "Could not find cert with friendly Name $_FriendlyName"
            }

            Write-Status "Removing web binding for port 8531"
            (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https") | Remove-WebBinding

            $webBinding = (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https")
            if (-not $webBinding) {
                #New-WebBinding -Name "WSUS Administration" -Protocol https -Port 8531 -IPAddress *
                Write-Status "Creating new web binding for port 8531"
                $webBinding = New-WebBinding -Name "WSUS Administration" -IPAddress "*" -Port 8531  -Protocol "https"

            }
            $webBinding = (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https")
            if (-not $webBinding) {
                Write-Status "Could not create webbinding for 8531"
                throw "Could not create webbinding for 8531"
            }

            Write-Status "Adding SSL cert $($cert.Thumbprint) to MY store"
            $webBinding.AddSslCertificate($($cert.Thumbprint), "my")

            #$cert | New-Item -Path IIS:\SslBindings\0.0.0.0!8531

            $wsussslparams = @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')
            foreach ($item in $wsussslparams) {
                Write-Status "Configuring IIS for WSUS SSL"
                $cfgSection = Get-IISConfigSection -Location "WSUS Administration/$item" -SectionPath "system.webServer/security/access";
                Set-IISConfigAttributeValue -ConfigElement $cfgSection -AttributeName "sslFlags" -AttributeValue "Ssl";
            }
            Write-Status "Running WsusUtil.exe ConfigureSSL $_HTTPSurl"
            write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' configuressl $_HTTPSurl")
            & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' configuressl $_HTTPSurl

        }
    }

    [bool] Test() {

        try {
            $wsus = get-WsusServer
            if ($wsus) {
                return $true
            }

            return $false
        }
        catch {
            Write-Verbose "Failed to Find WSUS Server"
            Write-Verbose "$_"
            return $false
        }
    }

    [ConfigureWSUS] Get() {
        return $this
    }

}

[DscResource()]
class WSUSSync {
    [DscProperty(Key)]
    [string] $ServerName

    [void] Set() {
       
        Write-Status "Starting initial WSUSSync for $($this.ServerName) using Product: SQL Server 2005 Category: Tools"
        try {
            $WSUS = Get-WsusServer -Name $this.ServerName -PortNumber 8530 #-UseSsl
 
            Get-WsusProduct | Set-WsusProduct -disable
            Get-WsusProduct | Where-Object { $_.Product.Title -eq "SQL Server 2005" } | Set-WsusProduct
         
            Get-WsusClassification | Set-WsusClassification -disable
            Get-WsusClassification | Where-Object { $_.Classification.Title -eq "Tools" } | Set-WsusClassification
         
            $sub = $WSUS.GetSubscription()
            $sub.StartSynchronization()
        }
        catch {
            Write-Status "Initial WSUSSync failed.  Skipping."
        }
       
    }

    [bool] Test() {

        try {
            $wsus = get-WsusServer
            $sub = $WSUS.GetSubscription()
            if ($wsus) {
                if (($sub.GetUpdateCategories() | where-object { $_.Title -eq "SQL Server 2005" }).Count -ge 1) {
                    return $true
                }
            }

            return $false
        }
        catch {
            Write-Status "Failed to Find WSUS Server"
            Write-Verbose "$_"
            return $false
        }
    }

    [WSUSSync] Get() {
        return $this
    }

}


#InstallPBIRS
[DscResource()]
class InstallPBIRS {
    [DscProperty(Key)]
    [string] $InstallPath

    [DscProperty()]
    [string]$SqlServer

    [DscProperty()]
    [string]$DownloadUrl

    [DscProperty()]
    #Must be PBIRS
    [string]$RSInstance

    [DscProperty()]
    [PSCredential]$DBcredentials

    [DscProperty()]
    [bool]$IsRemoteDatabaseServer

    [DscProperty()]
    [string]$TemplateName

    [DscProperty()]
    [string]$DNSName

    [void] Set() {
        try {
            $_Creds = $this.DBcredentials
            write-Status ("Configuring PBIRS for $($this.SqlServer) in $($this.InstallPath)")


            $pbirsSetup = "C:\temp\PowerBIReportServer.exe"
            Invoke-DownloadFile $this.DownloadUrl $pbirsSetup
            
            try {
                New-Item -Path $this.InstallPath -ItemType Directory -Force
            }
            catch {
                write-verbose ("InstallPBIRS $_")
            }


            write-Status ("Starting $pbirsSetup")
            $PBIRSargs = "/quiet /InstallFolder=$($this.InstallPath) /IAcceptLicenseTerms /Edition=Dev /Log C:\staging\PBI.log"
            Start-Process $pbirsSetup $PBIRSargs -Wait

            try {
                write-Status ("Installing Module ReportingServicesTools")
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Install-Module -Name ReportingServicesTools -Force -AllowClobber -Confirm:$false
            }
            catch {
                Write-Verbose ("InstallPBIRS $_")
            }


            try {
                Write-Status "Calling Set-RsDatabase"
                if ($this.IsRemoteDatabaseServer) {
                    try {
                        Write-Status ("Calling Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                    catch {
                        Write-Status ("Calling2 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                }
                else {
                    try {
                        Write-Status ("Calling Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                    catch {
                        Write-Status ("Calling2 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                }
            }
            catch {
                Write-Verbose ("InstallPBIRS $_")
                if ($this.IsRemoteDatabaseServer) {
                    Write-Status ("Calling3 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -IsExistingDatabase -TrustServerCertificate")
                    Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -IsExistingDatabase -TrustServerCertificate
                }
                else {
                    Write-Status ("Calling3 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -IsExistingDatabase -TrustServerCertificate")
                    Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -IsExistingDatabase -TrustServerCertificate
                }
            }


            Write-Status ("Calling Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext")
            Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext


            if ($this.TemplateName) {
                Write-Status ("Enabling HTTPS")
                start-sleep -seconds 20
                $_FriendlyName = $this.TemplateName
                $_dnsName = $this.DNSName

                $httpsPort = 443
                $ipAddress = "0.0.0.0"
                $lcid = (Get-Culture).Lcid

                $wmiName = (Get-WmiObject -namespace root\Microsoft\SqlServer\ReportServer  -class __Namespace -ComputerName $env:COMPUTERNAME).Name
                $version = (Get-WmiObject -namespace root\Microsoft\SqlServer\ReportServer\$wmiName -class __Namespace).Name
                $rsConfig = Get-WmiObject -namespace "root\Microsoft\SqlServer\ReportServer\$wmiName\$version\Admin" -class MSReportServer_ConfigurationSetting

                Write-Status ("Removing ReportServerWebApp ReportServerWebService URLS")
                $rsConfig.RemoveURL("ReportServerWebApp", "https://+:$httpsPort", $lcid)
                $rsConfig.RemoveURL("ReportServerWebApp", "https://$($_dnsName):$httpsPort", $lcid)
                $rsConfig.ReserveURL("ReportServerWebApp", "https://$($_dnsName):$httpsPort", $lcid)

                $rsConfig.RemoveURL("ReportServerWebService", "https://+:$httpsPort", $lcid)
                $rsConfig.RemoveURL("ReportServerWebService", "https://$($_dnsName):$httpsPort", $lcid)
                $rsConfig.ReserveURL("ReportServerWebService", "https://$($_dnsName):$httpsPort", $lcid)
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
                if (-not $cert) {
                    throw "Could not find cert with friendly Name $_FriendlyName"
                }

                Write-Status ("Adding ReportServerWebApp ReportServerWebService URLS")
                $thumbprint = $cert.ThumbPrint.ToLower()
                $rsConfig.CreateSSLCertificateBinding('ReportServerWebApp', $Thumbprint, $ipAddress, $httpsport, $lcid)
                $rsConfig.CreateSSLCertificateBinding('ReportServerWebService', $Thumbprint, $ipAddress, $httpsport, $lcid)
                $rsConfig.SetSecureConnectionLevel("1")
                $rsConfig.DeleteEncryptedInformation()
                $rsConfig.ReencryptSecureInformation()
                $rsconfig.SetServiceState($false, $false, $false)
                $rsconfig.SetServiceState($true, $true, $true)
            }
            Write-Status ("Restart PowerBIReportServer Service")
            Start-Sleep -seconds 10
            Restart-Service -Name "PowerBIReportServer" -Force
            Start-Sleep -Seconds 10
            Write-Status ("Calling Initialize-Rs -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext")
            try { Initialize-Rs -ReportServerInstance $($this.RSInstance) -ReportServerVersion SQLServervNext } catch {}
            Write-Status ("Restart PowerBIReportServer Service")
            Restart-Service -Name "PowerBIReportServer" -Force
            try {
                Get-Service | Where-Object { $_.Name -eq "SQLSERVERAGENT" -or $_.Name -like "SqlAgent*" } | Start-Service
            }
            catch {}
        }
        catch {
            Write-Status "Failed to Configure PBIRS"
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $service = $null
            if ($($this.RSInstance) -eq "PBIRS") {
                try {
                    $service = Get-Service PowerBIReportServer -ErrorAction SilentlyContinue
                }
                catch {}
            }

            if ($service) {
                if ($service.status -eq "Running") {
                    return $true
                }
            }

            return $false
        }
        catch {
            Write-Verbose "Failed to Find PBIRS Server"
            Write-Verbose "$_"
            return $false
        }
    }

    [InstallPBIRS] Get() {
        return $this
    }

}

[DscResource()]
class ImportCertifcateTemplate {
    [DscProperty(Key)]
    [string]$TemplateName

    [DscProperty(Mandatory)]
    [string]$DNPath

    [void] Set() {

        $_TemplateName = $this.TemplateName
        $_DNPath = $this.DNPath


        Write-Status "Adding Certificate Template $_TemplateName"

        $StatusLog = "C:\staging\DSC\DSC_Log.log"

        $_Path = "C:\staging\DSC\CertificateTemplates\$_TemplateName.ldf"
        if (!(Test-Path -Path $_Path -PathType Leaf)) {
            throw "Could not find $_Path"
        }
        $TargetFile = "c:\temp\$_TemplateName.ldf"
        Write-Status "TargetFile $TargetFile source: $_Path"
        (Get-Content $_Path).Replace('DC=TEMPLATE,DC=com', $_DNPath) | Set-Content $TargetFile -Force
        Write-Status "Running ldifde -i -k -f $TargetFile"
        ldifde -i -k -f $TargetFile | Out-File -FilePath $StatusLog -Append
    }

    [bool] Test() {

        $_TemplateName = $this.TemplateName
        try {
            $ConfigContext = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $ConfigContext = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigContext"
            $filter = "(cn=$_TemplateName)"
            $ds = New-object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ConfigContext", $filter)
            $found = $ds.Findone()
            if ($found) {
                return $true
            }
            return $false
        }
        catch {
            Write-Verbose "$_"
            Write-Verbose " -- Restart-Service -Name CertSvc"
            $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name CertSvc
            start-sleep -seconds 60
            Write-Verbose " -- ADCSAdministration\get-Catemplate"
            $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
        }
        if ($count -gt 0) {
            return $true
        }

        return $false
    }

    [ImportCertifcateTemplate] Get() {
        return $this
    }

}

[DscResource()]
class RebootNow {
    [DscProperty(Key)]
    [string]$FileName

    [void] Set() {

        $_FileName = $this.FileName

        if (-not (Test-Path $_FileName)) {
            Write-Status "Rebooting machine."
            Start-sleep -seconds 5
            New-Item $_FileName
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
            return
        }

        Write-Verbose "Not Rebooting"
    }

    [bool] Test() {

        $_FileName = $this.FileName
        if (-not (Test-Path $_FileName)) {
            return $false
        }

        return $true
    }

    [RebootNow] Get() {
        return $this
    }

}

[DscResource()]
class InstallRootCertificate {
    [DscProperty(Key)]
    [string]$CAName


    [void] Set() {

        $_FileName = "C:\Temp\rootCA.cer"


        if (-not (Test-Path $_FileName)) {
            Write-Status "Install Root Cert"

            $cmd = "certutil.exe"
            $arg1 = "-config"
            $arg2 = $this.CAName
            $arg3 = "-ca.cert"
            $arg4 = $_FileName
            & $cmd $arg1 $arg2 $arg3 $arg4

            Write-Status "Running certutil.exe -dspublish -f $_FileName RootCA"
            certutil.exe -dspublish -f $_FileName RootCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName NtauthCA"
            certutil.exe -dspublish -f $_FileName NtauthCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName SubCA"
            certutil.exe -dspublish -f $_FileName SubCA

        }


    }

    [bool] Test() {

        $_FileName = "C:\Temp\rootCA.cer"
        if (-not (Test-Path $_FileName)) {
            return $false
        }

        return $true
    }

    [InstallRootCertificate] Get() {
        return $this
    }

}



[DscResource()]
class AddCertificateTemplate {
    [DscProperty(Key)]
    [string]$TemplateName

    [DscProperty()]
    [string]$GroupName

    [DscProperty()]
    [string]$Permissions

    [DscProperty()]
    [bool]$PermissionsOnly

    [void] Set() {

        $_TemplateName = $this.TemplateName
        $_Group = $this.GroupName
        $_Permissions = $this.Permissions

        Write-Status "Adding Certificate Template $_TemplateName"           

        if (-not $this.PermissionsOnly) {
            $_Path = "C:\staging\DSC\CertificateTemplates\$_TemplateName.ldf"
            if (!(Test-Path -Path $_Path -PathType Leaf)) {
                Write-Status "Could not find $_Path"
                throw "Could not find $_Path"
            }
        }

        $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
        Write-Status "Removing $registryKey TimeStamp"  
        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
        Write-Status "Restarting CertSvc"
        restart-Service -Name CertSvc -ErrorAction SilentlyContinue
        Write-Status "Adding Certificate Template $_TemplateName ."   
        if ($_Group) {

            $module = Get-InstalledModule -Name PSPKI -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

            IF ($null -eq $module) {
                Write-Status "Installing PSPKI Module"  
                Write-Verbose "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force"
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Write-Verbose "Install-Module -Name PSPKI -Force:$true -Confirm:$false -MaximumVersion 4.2.0"
                Install-Module -Name PSPKI -Force:$true -Confirm:$false -MaximumVersion 4.2.0
            }
            Write-Status "Adding Certificate Template $_TemplateName .." 
            start-sleep -seconds 10
            Write-Verbose "Get-Command -Module PSPKI"
            Get-Command -Module PSPKI  | Out-null
            Write-Verbose "PSPKI\Get-CertificateTemplate -Name $_TemplateName ..."
            $retries = 0
            $success = $false
            while ($retries -lt 10 -and $success -eq $false) {
                Write-Status "Adding Certificate Template $_TemplateName ..." 
                $retries++
                try {
                    Write-Status "PSPKI\Get-CertificateTemplate -Name $_TemplateName -ErrorAction stop"
                    $template = PSPKI\Get-CertificateTemplate -Name $_TemplateName -ErrorAction stop

                    Write-Status "PSPKI\Get-CertificateTemplateAcl -ErrorAction stop"
                    $templateacl = $template | PSPKI\Get-CertificateTemplateAcl -ErrorAction stop

                    Write-Status "PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions -ErrorAction stop"
                    $templateacl2 = $templateacl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions -ErrorAction stop

                    Write-Status "PSPKI\Set-CertificateTemplateAcl -ErrorAction stop"
                    $templateacl2 | PSPKI\Set-CertificateTemplateAcl -ErrorAction stop
                    $success = $true
                }
                catch {
                    try {
                        $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
                        Write-Status "Restarting CertSvc"
                        restart-Service -Name CertSvc -ErrorAction SilentlyContinue
                        start-sleep -Seconds 60
                    }
                    catch {
                        Write-Verbose "Starting CertSvc: $_"
                    }

                    try {
                        Write-Status "PSPKI\Get-CertificateTemplate -Name $_TemplateName |  PSPKI\Get-CertificateTemplateAcl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions |  PSPKI\Set-CertificateTemplateAcl"
                        PSPKI\Get-CertificateTemplate -Name $_TemplateName |  PSPKI\Get-CertificateTemplateAcl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions |  PSPKI\Set-CertificateTemplateAcl
                        $success = $true
                    }
                    catch {
                        Write-Verbose "$_"
                        if (-not (Test-Path "C:\temp\certreboot2.txt")) {
                            Write-Status "Rebooting $_"
                            New-Item "C:\temp\certreboot2.txt"
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                            $global:DSCMachineStatus = 1
                            return
                        }
                    }
                }
            }
        }

        try {
            Write-Status "Adding Certificate Template $_TemplateName ...." 
            $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name CertSvc -ErrorAction SilentlyContinue
            start-sleep -seconds 60
        }
        catch {}
        if (-not $this.PermissionsOnly) {
            $count = (ADCSAdministration\get-CaTemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
            while ($count -eq 0) {
                try {
                    Write-Status "ADCSAdministration\Add-CATemplate $_TemplateName -Force -ErrorAction Stop"
                    ADCSAdministration\Add-CATemplate $_TemplateName -Force -ErrorAction Stop
                }
                catch {
                    try {
                        Write-Status "Adding Certificate Template $_TemplateName ....." 
                        Start-Service -Name CertSvc
                        Start-Sleep -Seconds 10
                        Write-Verbose "$_"
                        Write-Status "PSPKI\Get-CertificationAuthority | PSPKI\Add-CATemplate -Name $_TemplateName"
                        PSPKI\Get-CertificationAuthority | PSPKI\Add-CATemplate -Name $_TemplateName
                    }
                    catch {
                        # Reboot
                        Write-Verbose "$_"
                        if (-not (Test-Path "C:\temp\certreboot.txt")) {
                            Write-Status "Rebooting $_"
                            New-Item "C:\temp\certreboot.txt"
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                            $global:DSCMachineStatus = 1
                            return
                        }
                        throw
                    }
                }
                $count = (ADCSAdministration\get-CaTemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
            }
        }
    }

    [bool] Test() {


        if ($this.PermissionsOnly) {
            return $false
        }
        $_TemplateName = $this.TemplateName
        try {
            Write-Verbose " -- ADCSAdministration\get-Catemplate"
            $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
        }
        catch {
            Write-Verbose "$_"
            Write-Verbose " -- Restart-Service -Name CertSvc"
            $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name CertSvc
            start-sleep -seconds 60
            Write-Verbose " -- ADCSAdministration\get-Catemplate"
            $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
        }
        if ($count -gt 0) {
            return $true
        }

        return $false
    }

    [AddCertificateTemplate] Get() {
        return $this
    }

}

[DscResource()]
class AddCertificateToIIS {
    [DscProperty(Key)]
    [string]$FriendlyName

    [void] Set() {

        $_FriendlyName = $this.FriendlyName

        Write-Status "Installing cert $_FriendlyName to IIS"
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
        if (-not $cert) {
            Write-Status "Could not find cert with friendly Name $_FriendlyName"
            throw "Could not find cert with friendly Name $_FriendlyName"
        }
        try {
            netsh http delete sslcert ipport=0.0.0.0:443
        }
        catch {}


        #netsh http add sslcert ipport=0.0.0.0:443 certhash=$($cert.Thumbprint) appid='{4dc3e181-e14b-4a21-b022-59fc669b0914}' certstorename=My verifyclientcertrevocation=enable
        #New-WebBinding -Name "Default Web Site" -Protocol https -Port 443 -IPAddress *


        $webBinding = (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol "https")
        if (-not $webBinding) {
            New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port 443  -Protocol "https"
        }
        $webBinding = (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol "https")
        if (-not $webBinding) {
            throw "Could not create webbinding for 443"
        }
        $webBinding.AddSslCertificate($($cert.Thumbprint), "my")

    }

    [bool] Test() {

        try {
            $_FriendlyName = $this.FriendlyName
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            $certdata = netsh http show sslcert ipport=0.0.0.0:443
            $thumprint = $($cert.Thumbprint).ToLower()
            if ($certdata.ToLower() -match $thumprint ) {
                return $true
            }
        }
        catch {
            Write-Verbose "$_"
            return $false
        }

        return $false
    }

    [AddCertificateToIIS] Get() {
        return $this
    }

}

[DscResource()]
class AddToAdminGroup {
    [DscProperty(Key)]
    [string]$DomainName

    [DscProperty()]
    [System.Management.Automation.PSCredential] $RemoteCreds

    [DscProperty(Mandatory)]
    [string[]] $AccountNames

    [DscProperty(Key)]
    [string] $TargetGroup
    [void] Set() {


        Write-Status "Adding accounts to $($this.TargetGroup)"
        $retries = 30
        $tryno = 0
        while ($tryno -le $retries) {
            $tryno++
            try {
                if ($this.DomainName -ne "NONE") {
                    foreach ($AccountName in $this.AccountNames) {

                        if ($AccountName.EndsWith("$")) {
                            Write-Status "Adding Computer $($this.DomainName)\$AccountName"
                            $user1 = Get-ADComputer -Identity $AccountName -server $this.DomainName -AuthType Negotiate -Credential $this.RemoteCreds
                        }
                        else {
                            Write-Status "Adding User  $($this.DomainName)\$AccountName"
                            $user1 = Get-ADuser -Identity $AccountName -server $this.DomainName -AuthType Negotiate -Credential $this.RemoteCreds
                        }
                        Add-ADGroupMember -Identity $this.TargetGroup -Members $user1
                    }
                }
                else {
                    foreach ($AccountName in $this.AccountNames) {

                        if ($AccountName.EndsWith("$")) {
                            Write-Status "Adding Computer $AccountName"
                            $user2 = Get-ADComputer -Identity $AccountName
                        }
                        else {
                            Write-Status "Adding User $AccountName"
                            $user2 = Get-ADuser -Identity $AccountName
                        }
                        Add-ADGroupMember -Identity $this.TargetGroup -Members $user2
                    }
                }
            }
            catch {
                Write-Verbose $_
                start-sleep -seconds 60
                continue
            }
            Write-Status "Done."
            return
        }

    }

    [bool] Test() {

        return $false
    }

    [AddToAdminGroup] Get() {
        return $this
    }

}

[DscResource()]
class RunPkiSync {
    [DscProperty(Key)]
    [string]$SourceForest

    [DscProperty(Key)]
    [string]$TargetForest
    [void] Set() {


        write-Status "Running PKISync from $($this.SourceForest) to $($this.TargetForest)"
        $MaxRetries = 20
        $retry  = 0
        while ($true) {

            if ($retry -ge $MaxRetries) {
                Write-Verbose "Failed to connect to target forests after $MaxRetries attempts"
                return
            }
            $retry++

            
            try {
                Write-Status "Attempting to connect to $($this.TargetForest)"
                $TargetForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext Forest, $this.TargetForest
                $TargetForObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($TargetForestContext)
                if (-not $TargetForObj) {
                    throw "Could not connect to $($this.TargetForest)"
                }

            }
            catch {
                ipconfig /flushdns
                gpupdate.exe /force
                Write-Verbose $_
                Start-Sleep -Seconds 30
                continue
            }
            try {
                Write-Status "Attempting to connect to $($this.SourceForest)"
                $SourceForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext Forest, $this.SourceForest
                $SourceForObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($SourceForestContext)
                if (-not $SourceForObj) {
                    throw "Could not connect to $($this.SourceForest)"
                }
            }
            catch {
                ipconfig /flushdns
                gpupdate.exe /force
                Write-Verbose $_
                Start-Sleep -Seconds 30
                continue
            }

            break
        }

        Write-Status "Running C:\staging\DSC\phases\PKISync.Ps1"
        C:\staging\DSC\phases\PKISync.Ps1 -sourceforest $this.SourceForest -targetforest $this.TargetForest -f
    }

    [bool] Test() {

        return $false
    }

    [RunPkiSync] Get() {
        return $this
    }

}

[DscResource()]
class GpUpdate {
    [DscProperty(Key)]
    [string]$Run

    [void] Set() {
        Write-Status "Forcing a gpupdate"
        gpupdate.exe /force
    }

    [bool] Test() {

        return $false
    }

    [GpUpdate] Get() {
        return $this
    }

}
