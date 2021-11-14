[CmdletBinding()]
param (
    [Parameter()]
    [switch]$InJob,
    [Parameter()]
    [switch]$VerboseEnabled
)

########################
### Common Functions ###
########################

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Text,
        [Parameter(Mandatory = $false)]
        [switch]$Warning,
        [Parameter(Mandatory = $false)]
        [switch]$Failure,
        [Parameter(Mandatory = $false)]
        [switch]$Success,
        [Parameter(Mandatory = $false)]
        [switch]$Activity,
        [Parameter(Mandatory = $false)]
        [switch]$SubActivity,
        [Parameter(Mandatory = $false)]
        [switch]$LogOnly,
        [Parameter(Mandatory = $false)]
        [switch]$OutputStream,
        [Parameter(Mandatory = $false)]
        [switch]$HostOnly
    )

    $HashArguments = @{}
    $info = $true

    # Is Verbose?
    $IsVerbose = $false
    if ($MyInvocation.BoundParameters["Verbose"].IsPresent) {
        $IsVerbose = $true
    }

    If ($Success.IsPresent) {
        $info = $false
        $Text = "SUCCESS: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Green)
    }

    If ($Activity.IsPresent) {
        $info = $false
        Write-Host
        $Text = "=== $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Cyan)
    }

    If ($SubActivity.IsPresent) {
        $info = $false
        Write-Host
        $Text = "====== $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Magenta)
    }

    If ($Warning.IsPresent) {
        $info = $false
        $Text = "WARNING: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Yellow)
    }

    If ($Failure.IsPresent) {
        $info = $false
        $Text = "ERROR: $Text"
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::Red)
    }

    If ($IsVerbose) {
        $info = $false
        $Text = "VERBOSE: $Text"
    }

    if ($info) {
        $HashArguments.Add("ForegroundColor", [System.ConsoleColor]::White)
        $Text = "INFO: $Text"
    }

    # Write to output stream
    if ($OutputStream.IsPresent) {
        Write-Output $Text
    }

    # Write progress if output stream and failure present
    if ($OutputStream.IsPresent -and $Failure.IsPresent) {
        Write-Progress -Activity $Text -Status "Failed :(" -Completed
    }

    # Write to console, if not logOnly and not OutputStream and not verbose
    If (-not $LogOnly.IsPresent -and -not $OutputStream.IsPresent -and -not $IsVerbose) {
        Write-Host $Text @HashArguments
    }

    $time = Get-Date -Format 'MM/dd/yyyy HH:mm:ss:fff'
    $Text = "$time $Text"

    # Write to log, non verbose entries
    $write = $false
    if (-not $HostOnly.IsPresent -and -not $IsVerbose) {
        $write = $true
    }

    # Write verbose entries, if verbose logging enabled
    if ($IsVerbose -and $Common.VerboseEnabled) {
        $write = $true
    }

    if ($write) {
        try {
            $Text | Out-File $Common.LogPath -Append
        }
        catch {
            try {
                # Retry once and ignore if failed
                $Text | Out-File $Common.LogPath -Append -ErrorAction SilentlyContinue
            }
            catch {
                # ignore
            }
        }
    }
}

function Write-Exception {
    [CmdletBinding()]
    param (
        [Parameter()]
        $ExceptionInfo,
        [Parameter()]
        $AdditionalInfo
    )

    $crashLogsFolder = Join-Path $PSScriptRoot "crashlogs"
    if (-not (Test-Path $crashLogsFolder)) { New-Item -Path $crashLogsFolder -ItemType Directory -Force | Out-Null }
    $guid = (New-Guid).Guid
    $crashFile = Join-Path $crashLogsFolder "$guid.txt"

    $sb = [System.Text.StringBuilder]::new()

    $parentFunctionName = (Get-PSCallStack)[1].FunctionName
    $msg = "`n=== $parentFunctionName`: An error occurred: $ExceptionInfo"
    [void]$sb.AppendLine($msg)
    Write-Host $msg -ForegroundColor Red

    $msg = "`n=== Exception.ScriptStackTrace:`n"
    [void]$sb.AppendLine($msg)
    Write-Host $msg -ForegroundColor Red

    $msg = $ExceptionInfo.ScriptStackTrace
    [void]$sb.AppendLine($msg)
    $msg | Out-Host

    $msg = "`n=== Get-PSCallStack:`n"
    [void]$sb.AppendLine($msg)
    Write-Host $msg -ForegroundColor Red

    $msg = (Get-PSCallStack | Select-Object Command, Location, Arguments | Format-Table | Out-String).Trim()
    [void]$sb.AppendLine($msg)
    $msg | Out-Host

    if ($AdditionalInfo) {
        $msg = "`n=== Additional Information:`n"
        [void]$sb.AppendLine($msg)
        Write-Host "$msg" -ForegroundColor Red
        Write-Host "Dumped to $crashFile"

        $msg = ($AdditionalInfo | Out-String).Trim()
        [void]$sb.AppendLine($msg)
    }

    $sb.ToString() | Out-File -FilePath $crashFile -Force
    Write-Host
}

function Get-File {
    param(
        [Parameter(Mandatory = $false)]
        $Source,
        [Parameter(Mandatory = $false)]
        $Destination,
        [Parameter(Mandatory = $false)]
        $DisplayName,
        [Parameter(Mandatory = $false)]
        [ValidateSet("Downloading", "Copying")]
        $Action,
        [Parameter(Mandatory = $false)]
        [switch]$Silent,
        [Parameter(Mandatory = $false)]
        [switch]$RemoveIfPresent,
        [Parameter(Mandatory = $false)]
        [switch]$ForceDownload,
        [Parameter(Mandatory = $false)]
        [switch]$ResumeDownload,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false, ParameterSetName = "WhatIf")]
        [switch]$WhatIf
    )

    # Display name for source
    $sourceDisplay = $Source

    # Add storage token, if source is like Storage URL
    if ($Source -and $Source -like "$($StorageConfig.StorageLocation)*") {
        $Source = "$Source`?$($StorageConfig.StorageToken)"
        $sourceDisplay = Split-Path $sourceDisplay -Leaf

        if ($UseCDN.IsPresent) {
            $Source = $Source.Replace("blob.core.windows.net", "azureedge.net")
        }

        #Write-Log "Download Source: $Source"
    }

    # What If
    if ($WhatIf -and -not $Silent) {
        Write-Log "Get-File - WhatIf: $Action $sourceDisplay file to $Destination"
        return $true
    }

    # Not making these mandatory to allow WhatIf to run with null values
    if (-not $Source -and -not $Destination) {
        Write-Log "Get-File: Source and Destination parameters must be specified." -Failure
        return $false
    }

    # Not making these mandatory to allow WhatIf to run with null values
    if (-not $Action) {
        Write-Log "Get-File: Action must be specified." -Failure
        return $false
    }

    $destinationFile = Split-Path $Destination -Leaf

    $HashArguments = @{
        Source      = $Source
        Destination = $Destination
        Description = "$Action $destinationFile using BITS"
    }

    if ($DisplayName) { $HashArguments.Add("DisplayName", $DisplayName) }

    if (-not $Silent) {
        Write-Log "Get-File: $Action $sourceDisplay to $Destination... "
        if ($DisplayName) { Write-Log "Get-File: $DisplayName" -LogOnly }
    }

    if ($RemoveIfPresent.IsPresent -and (Test-Path $Destination)) {
        Remove-Item -Path $Destination -Force -Confirm:$false -WhatIf:$WhatIf
    }

    # Create destination directory if it doesn't exist
    $destinationDirectory = Split-Path $Destination -Parent
    if (-not (Test-Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    try {
        $i = 0
        $timedOut = $false

        # Wait for existing download to finish, dont bother when action is copying
        if ($Action -eq "Downloading") {
            while (Get-Process -Name "curl" -ErrorAction SilentlyContinue) {
                Write-Log "Get-File: Download for '$sourceDisplay' waiting on an existing download. Checking again in 2 minutes..." -Warning
                Start-Sleep -Seconds 120

                $i++
                if ($i -gt 5) {
                    Write-Log "Get-File: Timed out while waiting to download '$sourceDisplay'." -Failure
                    $timedOut = $true
                    break
                }
            }
        }

        if ($timedOut) {
            return $false
        }

        # Skip re-download if file already exists, dont bother when action is copying
        if ($Action -eq "Downloading" -and (Test-Path $Destination) -and -not $ForceDownload.IsPresent -and -not $ResumeDownload.IsPresent) {
            Write-Log "Get-File: Download skipped. $Destination already exists." -LogOnly
            return $true
        }

        if ($Action -eq "Downloading") {
            $worked = Start-CurlTransfer @HashArguments -Silent:$Silent
            if (-not $worked) {
                Write-Log "Get-File: Failed to download file using curl."
                return $false
            }
        }
        else {
            Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
        }

        if (Test-Path $Destination) {
            return $true
        }

        return $false
    }
    catch {
        Write-Log "Get-File: $Action $sourceDisplay failed. Error: $($_.ToString().Trim())" -Failure
        return $false
    }
}

function Start-CurlTransfer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Source,
        [Parameter(Mandatory = $true)]
        [string] $Destination,
        [Parameter(Mandatory = $false)]
        [string] $Description,
        [Parameter(Mandatory = $false)]
        [string] $DisplayName,
        [Parameter(Mandatory = $false)]
        [switch]$Silent
    )

    $curlPath = "C:\ProgramData\chocolatey\bin\curl.exe"
    if (-not (Test-Path $curlPath)) {
        & choco install curl -y | Out-Null
    }

    if (-not (Test-Path $curlPath)) {
        Write-Log "Start-CurlTransfer: Curl was not found, and could not be installed." -Failure
        return $false
    }

    $retryCount = 0
    $success = $false
    Write-Host
    do {
        $retryCount++
        if ($Silent) {
            & $curlPath -s -L -o $Destination -C - "$Source"
        }
        else {
            & $curlPath -L -o $Destination -C - "$Source"
        }

        if ($LASTEXITCODE -eq 0) {
            $success = $true
            Write-Host
            break
        }
        else {
            Write-Host
            Write-Log "Start-CurlTransfer: Download failed with exit code $LASTEXITCODE. Will retry $(20 - $retryCount) more times."
            Write-Host
            Start-Sleep -Seconds 5
        }

    } while ($retryCount -le 10)

    return $success
}

function New-Directory {
    param(
        $DirectoryPath
    )

    if (-not (Test-Path -Path $DirectoryPath)) {
        New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    }

    return $DirectoryPath
}

# https://stackoverflow.com/questions/61231739/set-the-position-of-powershell-window
Function Set-Window {
    <#
        .SYNOPSIS
            Sets the window size (height,width) and coordinates (x,y) of
            a process window.
        .DESCRIPTION
            Sets the window size (height,width) and coordinates (x,y) of
            a process window.

        .PARAMETER ProcessID
            ID of the process to determine the window characteristics

        .PARAMETER X
            Set the position of the window in pixels from the top.

        .PARAMETER Y
            Set the position of the window in pixels from the left.

        .PARAMETER Width
            Set the width of the window.

        .PARAMETER Height
            Set the height of the window.

        .PARAMETER Passthru
            Display the output object of the window.

        .NOTES
            Name: Set-Window
            Author: Boe Prox
            Version History
                1.0//Boe Prox - 11/24/2015
                    - Initial build

        .OUTPUT
            System.Automation.WindowInfo

        .EXAMPLE
            Get-Process powershell | Set-Window -X 2040 -Y 142 -Passthru

            ProcessName Size     TopLeft  BottomRight
            ----------- ----     -------  -----------
            powershell  1262,642 2040,142 3302,784

            Description
            -----------
            Set the coordinates on the window for the process PowerShell.exe

    #>
    [OutputType('System.Automation.WindowInfo')]
    [cmdletbinding()]
    Param (
        [parameter(ValueFromPipelineByPropertyName = $True)]
        $ProcessID,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [switch]$Passthru
    )
    Begin {
        Try {
            [void][Window]
        }
        Catch {
            Add-Type @"
              using System;
              using System.Runtime.InteropServices;
              public class Window {
                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

                [DllImport("User32.dll")]
                public extern static bool MoveWindow(IntPtr handle, int x, int y, int width, int height, bool redraw);
              }
              public struct RECT
              {
                public int Left;        // x position of upper-left corner
                public int Top;         // y position of upper-left corner
                public int Right;       // x position of lower-right corner
                public int Bottom;      // y position of lower-right corner
              }
"@
        }
    }
    Process {
        $Rectangle = New-Object RECT
        $Handle = (Get-Process -id $ProcessID).MainWindowHandle
        $Return = [Window]::GetWindowRect($Handle, [ref]$Rectangle)
        If (-NOT $PSBoundParameters.ContainsKey('Width')) {
            $Width = $Rectangle.Right - $Rectangle.Left
        }
        If (-NOT $PSBoundParameters.ContainsKey('Height')) {
            $Height = $Rectangle.Bottom - $Rectangle.Top
        }
        If ($Return) {
            $Return = [Window]::MoveWindow($Handle, $x, $y, $Width, $Height, $True)
        }
        If ($PSBoundParameters.ContainsKey('Passthru')) {
            $Rectangle = New-Object RECT
            $Return = [Window]::GetWindowRect($Handle, [ref]$Rectangle)
            If ($Return) {
                $Height = $Rectangle.Bottom - $Rectangle.Top
                $Width = $Rectangle.Right - $Rectangle.Left
                $Size = New-Object System.Management.Automation.Host.Size -ArgumentList $Width, $Height
                $TopLeft = New-Object System.Management.Automation.Host.Coordinates -ArgumentList $Rectangle.Left, $Rectangle.Top
                $BottomRight = New-Object System.Management.Automation.Host.Coordinates -ArgumentList $Rectangle.Right, $Rectangle.Bottom
                If ($Rectangle.Top -lt 0 -AND $Rectangle.LEft -lt 0) {
                    Write-Warning "Window is minimized! Coordinates will not be accurate."
                }
                $Object = [pscustomobject]@{
                    ProcessID   = $ProcessID
                    Size        = $Size
                    TopLeft     = $TopLeft
                    BottomRight = $BottomRight
                }
                $Object.PSTypeNames.insert(0, 'System.Automation.WindowInfo')
                $Object
            }
        }
    }
}

function Test-NetworkSwitch {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Name.")]
        [string]$NetworkName,
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name.")]
        [string]$DomainName
    )

    $exists = Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -eq $NetworkName }
    if (-not $exists) {
        Write-Log "Get-NetworkSwitch: HyperV Network switch for $NetworkName not found. Creating a new one."
        New-VMSwitch -Name $NetworkName -SwitchType Internal -Notes $DomainName | Out-Null
        Start-Sleep -Seconds 5 # Sleep to make sure network adapter is present
    }

    $exists = Get-VMSwitch -SwitchType Internal | Where-Object { $_.Name -eq $NetworkName }
    if (-not $exists) {
        Write-Log "Get-NetworkSwitch: HyperV Network switch could not be created."
        return $false
    }

    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$NetworkName*" }

    if (-not $adapter) {
        Write-Log "Get-NetworkSwitch: Network adapter for $NetworkName was not found."
        return $false
    }

    $interfaceAlias = $adapter.InterfaceAlias
    $desiredIp = $NetworkSubnet.Substring(0, $NetworkSubnet.LastIndexOf(".")) + ".200"

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "Get-NetworkSwitch: $interfaceAlias IP is $($currentIp.IPAddress). Changing it to $desiredIp."
        New-NetIPAddress -InterfaceAlias $interfaceAlias -IPAddress $desiredIp -PrefixLength 24 | Out-Null
        Start-Sleep -Seconds 5 # Sleep to make sure IP changed
    }

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "Get-NetworkSwitch: Unable to set IP for '$interfaceAlias' network adapter to $desiredIp."
        return $false
    }

    $text = & netsh routing ip nat show interface
    if ($text -like "*$interfaceAlias*") {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' interface is already present in NAT." -Success
        return $true
    }
    else {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' not found in NAT. Restarting RemoteAccess service before adding it."
        $success = $false
        while (-not $success) {
            try {
                Restart-Service RemoteAccess -ErrorAction Stop
                $success = $true
            }
            catch {
                Write-Log "Get-NetworkSwitch: Retry Restarting RemoteAccess Service"
                Start-Sleep -Seconds 10
            }
        }
        & netsh routing ip nat add interface "$interfaceAlias"
    }

    $text = & netsh routing ip nat show interface
    if ($text -like "*$interfaceAlias*") {
        Write-Log "Get-NetworkSwitch: '$interfaceAlias' interface added to NAT." -Success
        return $true
    }
    else {
        Write-Log "Get-NetworkSwitch: Unable to add '$interfaceAlias' to NAT."
        return $false
    }
}

function Test-DHCPScope {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Parameters object of deploy Configuration.")]
        [object]$ConfigParams
    )

    $scopeID = $ConfigParams.DHCPScopeId
    $scopeName = $ConfigParams.DHCPScopeName
    $createScope = $false

    $leaseTimespan = New-TimeSpan -Days 16
    if ($scopeName -eq "Internet") {
        $leaseTimespan = New-TimeSpan -Days 365
    }

    $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $dhcp) {
        Write-Log "Test-DHCPScope: DHCP is not installed. Installing..."
        $installed = Install-WindowsFeature 'DHCP' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools -ErrorAction SilentlyContinue

        if (-not $installed.Success) {
            Write-Log "Test-DHCPScope: DHCP Installation failed $($installed.ExitCode). Install DHCP windows feature manually, and try again." -Failure
            return $false
        }
    }

    $scope = Get-DhcpServerv4Scope -ScopeId $scopeID -ErrorAction SilentlyContinue
    if ($scope) {
        Write-Log "Test-DHCPScope: '$scopeID' scope is already present in DHCP." -Success
        $createScope = $false
    }
    else {
        $createScope = $true
    }

    if ($createScope) {
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $ConfigParams.DHCPScopeStart -EndRange $ConfigParams.DHCPScopeEnd -SubnetMask 255.255.255.0 -LeaseDuration $leaseTimespan -ErrorAction SilentlyContinue
        $scope = Get-DhcpServerv4Scope -ScopeId $scopeID -ErrorVariable ScopeErr -ErrorAction SilentlyContinue
        if ($scope) {
            Write-Log "Test-DHCPScope: '$scopeID' scope added to DHCP."
        }
        else {
            Write-Log "Test-DHCPScope: Failed to add '$scopeID' to DHCP. $ScopeErr" -Failure
            return $false
        }
    }

    try {
        $HashArguments = @{
            ScopeId = $scopeID
            Router  = $ConfigParams.DHCPDefaultGateway
        }

        if ($ConfigParams.DCName) {
            $dcnet = Get-Vm -Name $ConfigParams.DCName -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
        }

        if ($dcnet) {
            $dcIpv4 = $dcnet.IPAddresses | Where-Object { $_ -notlike "*:*" }
            $HashArguments.Add("DnsServer", $dcIpv4)
            $HashArguments.Add("WinsServer", $dcIpv4)
            $HashArguments.Add("DnsDomain", $ConfigParams.DomainName)
        }
        else {
            $HashArguments.Add("DnsServer", $ConfigParams.DHCPDNSAddress)
        }

        Set-DhcpServerv4OptionValue @HashArguments -Force -ErrorAction Stop
        Write-Log "Test-DHCPScope: Added/updated scope options for '$scopeID' scope in DHCP." -Success
        return $true
    }
    catch {
        Write-Log "Test-DHCPScope: Failed to add/update scope options for '$scopeID' scope in DHCP. $_" -Failure
        return $false
    }

}

function New-DhcpScopeDescription {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Parameters object of deploy Configuration.")]
        [object]$ConfigParams
    )

    try {
        $scopeID = $ConfigParams.DHCPScopeId

        $dhcpDesc = [PSCustomObject]@{
            Domain  = $ConfigParams.domainName
            DC      = $ConfigParams.DCName
            Primary = $ConfigParams.PSName
            CAS     = $ConfigParams.CSName
        }

        $dhcpDescJson = ($dhcpDesc | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
        Set-DhcpServerv4Scope -ScopeId $scopeID -Description $dhcpDescJson

    }
    catch {
        Write-Log "New-DhcpScopeDescription: Failed to add/update description for '$scopeID' scope in DHCP. $_" -Failure
    }
}

function New-VmNote {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [object]$DeployConfig,
        [Parameter(Mandatory = $false)]
        [bool]$Successful,
        [Parameter(Mandatory = $false)]
        [bool]$InProgress
    )

    try {
        $ProgressPreference = 'SilentlyContinue'

        $ThisVM = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName }

        $vmNote = [PSCustomObject]@{
            inProgress = $InProgress
            success    = $Successful
            role       = $ThisVM.role
            deployedOS = $ThisVM.operatingSystem
            domain     = $DeployConfig.vmOptions.domainName
            adminName  = $DeployConfig.vmOptions.adminName
            network    = $DeployConfig.vmOptions.network
            prefix     = $DeployConfig.vmOptions.prefix
        }

        foreach ($prop in $ThisVM.PSObject.Properties) {
            $vmNote | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
        }

        Set-VMNote -vmName $vmName -vmNote $vmNote

    }
    catch {
        Write-Log "New-VmNote: Failed to add a note to the VM '$VmName' in Hyper-V. $_" -Failure
    }
    finally {
        $ProgressPreference = 'Continue'
    }
}

function Set-VMNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$vmName,
        [Parameter(Mandatory = $true)]
        [object]$vmNote
    )

    $vmNote | Add-Member -MemberType NoteProperty -Name "lastUpdate" -Value (Get-Date -format "MM/dd/yyyy HH:mm") -Force
    $vmNoteJson = ($vmNote | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
    $vm = Get-Vm $VmName -ErrorAction Stop
    if ($vm) {
        Write-Log "Set-VMNote: Setting VM Note for $vmName" -LogOnly
        $vm | Set-VM -Notes $vmNoteJson -ErrorAction Stop
    }
}
function Remove-DnsRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DCName,
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        [Parameter(Mandatory = $true)]
        [string]$RecordToDelete
    )

    # Write-Host "DCName $DCName, Domain $Domain, RecordToDelete $RecordToDelete"

    $scriptBlock1 = {
        #Get-ADComputer -Identity $using:RecordToDelete -ErrorAction SilentlyContinue | Remove-ADObject -Recursive -ErrorAction SilentlyContinue -Confirm:$False
        Get-DnsServerResourceRecord -ZoneName $using:Domain -Node $using:RecordToDelete -RRType A
    }

    $scriptBlock2 = {
        $NodeDNS = Get-DnsServerResourceRecord -ZoneName $using:Domain -Node $using:RecordToDelete -RRType A -ErrorAction SilentlyContinue
        if ($NodeDNS) {
            Remove-DnsServerResourceRecord -ZoneName $using:Domain -InputObject $NodeDNS -Force -ErrorAction SilentlyContinue
        }
    }

    $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock1 -SuppressLog
    if ($result.ScriptBlockFailed) {
        Write-Log "DNS resource record for $RecordToDelete was not found." -HostOnly
    }
    else {
        $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock2 -SuppressLog
        if ($result.ScriptBlockFailed) {
            Write-Log "Failed to remove DNS resource record for $RecordToDelete. Please remove the record manually." -Warning
        }
        else {
            Write-Log "Removed DNS resource record for $RecordToDelete"
        }
    }
}

function Get-DhcpScopeDescription {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope ID.")]
        [string]$ScopeId
    )

    try {
        $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction Stop
        $scopeDescObject = $scope.Description | ConvertFrom-Json
        return $scopeDescObject

    }
    catch {
        Write-Log "Get-DhcpScopeDescription: Failed to get description for '$ScopeId' scope in DHCP. $_" -Failure
        return $null
    }
}

function New-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmPath,
        [Parameter(Mandatory = $false)]
        [string]$SourceDiskPath,
        [Parameter(Mandatory = $true)]
        [string]$Memory,
        [Parameter(Mandatory = $true)]
        [int]$Processors,
        [Parameter(Mandatory = $true)]
        [int]$Generation,
        [Parameter(Mandatory = $true)]
        [string]$SwitchName,
        [Parameter(Mandatory = $false)]
        [object]$AdditionalDisks,
        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,
        [Parameter()]
        [PsCustomObject] $DeployConfig,
        [Parameter(Mandatory = $false)]
        [switch]$OSDClient,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # WhatIf
    if ($WhatIf) {
        Write-Log "New-VirtualMachine - WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, AdditionalDisks: $AdditionalDisks, SwitchName: $SwitchName, ForceNew: $ForceNew"
        return $true
    }

    Write-Log "New-VirtualMachine: $VmName`: Creating Virtual Machine"

    # Test if source file exists
    if (-not (Test-Path $SourceDiskPath) -and (-not $OSDClient.IsPresent)) {
        Write-Log "New-VirtualMachine: $VmName`: $SourceDiskPath not found. Cannot create new VM."
        return $false
    }

    # VM Exists
    $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest -and $ForceNew.IsPresent) {
        Write-Log "New-VirtualMachine: $VmName`: Virtual machine already exists. ForceNew switch is present."
        if ($vmTest.State -ne "Off") {
            Write-Log "New-VirtualMachine: $VmName`: Turning the VM off forcefully..."
            $vmTest | Stop-VM -TurnOff -Force
        }
        $vmTest | Remove-VM -Force
        Write-Log "New-VirtualMachine: $VmName`: Purging $($vmTest.Path) folder..."
        Remove-Item -Path $($vmTest.Path) -Force -Recurse
        Write-Log "New-VirtualMachine: $VmName`: Purge complete."
    }

    if ($vmTest -and -not $ForceNew.IsPresent) {
        Write-Log "New-VirtualMachine: $VmName`: Virtual machine already exists. ForceNew switch is NOT present. Exit."
        return $false
    }

    # Make sure Existing VM Path is gone!
    $VmSubPath = Join-Path $VmPath $VmName
    if (Test-Path -Path $VmSubPath) {
        Write-Log "New-VirtualMachine: $VmName`: Found existing directory for $vmName. Purging $VmSubPath folder..."
        Remove-Item -Path $VmSubPath -Force -Recurse
        Write-Log "New-VirtualMachine: $VmName`: Purge complete." -Verbose
    }

    # Create new VM
    try {
        $vm = New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop
    }
    catch {
        Write-Log "New-VirtualMachine: $VmName`: Failed to create new VM. $_"
        return $false
    }

    # Add VMNote as soon as VM is created
    if ($DeployConfig) {
        New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
    }

    # Copy sysprepped image to VM location
    $osDiskName = "$($VmName)_OS.vhdx"
    $osDiskPath = Join-Path $vm.Path $osDiskName

    if (-not $OSDClient.IsPresent) {
        $worked = Get-File -Source $SourceDiskPath -Destination $osDiskPath -DisplayName "$VmName`: Making a copy of base image in $osDiskPath" -Action "Copying"
        if (-not $worked) {
            Write-Log "New-VirtualMachine: $VmName`: Failed to copy $SourceDiskPath to $osDiskPath. Exiting."
            return $false
        }
    }
    else {
        $worked = New-VHD -Path $osDiskPath -SizeBytes 127GB
        if (-not $worked) {
            Write-Log "New-VirtualMachine: $VmName`: Failed to create new VMD $osDiskPath for OSDClient. Exiting."
            return $false
        }
    }

    Write-Log "New-VirtualMachine: $VmName`: Enabling Hyper-V Guest Services"
    Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    if ($null -eq (Get-HgsGuardian -Name MemLabsGuardian -ErrorAction SilentlyContinue)) {
        New-HgsGuardian -Name "MemLabsGuardian" -GenerateCertificates
        New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $localCASupported = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported"
    if ($localCASupported -eq 1) {
        Write-Log "New-VirtualMachine: $VmName`: Enabling TPM"
        $HGOwner = Get-HgsGuardian MemLabsGuardian
        $KeyProtector = New-HgsKeyProtector -Owner $HGOwner -AllowUntrustedRoot
        Set-VMKeyProtector -VMName $VmName -KeyProtector $KeyProtector.RawData
        Enable-VMTPM $VmName -ErrorAction SilentlyContinue ## Only required for Win11
    }
    else {
        Write-Log "New-VirtualMachine: $VmName`: Skipped enabling TPM since HKLM:\SOFTWARE\Microsoft\HgsClient\LocalCACertSupported is not set."
    }

    Write-Log "New-VirtualMachine: $VmName`: Setting Processor count to $Processors"
    Set-VM -Name $vmName -ProcessorCount $Processors

    Write-Log "New-VirtualMachine: $VmName`: Adding virtual disk $osDiskPath"
    Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType SCSI -ControllerNumber 0


    Write-Log "New-VirtualMachine: $VmName`: Adding a DVD drive"
    Add-VMDvdDrive -VMName $VmName

    Write-Log "New-VirtualMachine: $VmName`: Changing boot order"
    $f = Get-VM $VmName | Get-VMFirmware
    $f_file = $f.BootOrder | Where-Object { $_.BootType -eq "File" }
    $f_net = $f.BootOrder | Where-Object { $_.BootType -eq "Network" }
    $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
    $f_dvd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }

    # Add additional disks
    if ($AdditionalDisks) {
        $count = 0
        $label = "DATA"
        foreach ($disk in $AdditionalDisks.psobject.properties) {
            $newDiskName = "$VmName`_$label`_$count.vhdx"
            $newDiskPath = Join-Path $vm.Path $newDiskName
            Write-Log "New-VirtualMachine: $VmName`: Adding $newDiskPath"
            New-VHD -Path $newDiskPath -SizeBytes ($disk.Value / 1) -Dynamic
            Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath
            $count++
        }
    }

    # 'File' firmware is not present on new VM, seems like it's created after Windows setup.
    if ($null -ne $f_file) {
        if (-not $OSDClient.IsPresent) {
            Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_hd, $f_net
        }
        else {
            Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_net, $f_hd
        }
    }
    else {
        if (-not $OSDClient.IsPresent) {
            Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_hd, $f_net
        }
        else {
            Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_net, $f_hd
        }
    }

    if (-not $OSDClient.IsPresent) {
        try {
            Write-Log "New-VirtualMachine: $VmName`: Starting virtual machine"
            Start-VM -Name $VmName -ErrorAction Stop
        }
        catch {
            try {
                Write-Log "New-VirtualMachine: $VmName`: Failed to start newly created VM. $($_.Exception.Message). Retrying once..." -Warning
                Start-Sleep -Seconds 60
                Start-VM -Name $VmName -ErrorAction Stop
            }
            catch {
                Write-Log "New-VirtualMachine: $VmName`: Failed to start newly created VM. $($_.Exception.Message)" -Failure
                return $false
            }
        }
    }

    return $true
}

function Get-AvailableMemoryGB {
    $availableMemory = Get-WmiObject win32_operatingsystem | Select-Object -Expand FreePhysicalMemory
    $availableMemory = ($availableMemory - ("4GB" / 1kB)) * 1KB / 1GB
    $availableMemory = [Math]::Round($availableMemory, 2)
    if ($availableMemory -lt 0) {
        $availableMemory = 0
    }
    return $availableMemory
}

function Wait-ForVm {

    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true, ParameterSetName = "VmState")]
        [string]$VmState,
        [Parameter(Mandatory = $false, ParameterSetName = "OobeComplete")]
        [switch]$OobeComplete,
        [Parameter(Mandatory = $false, ParameterSetName = "OobeStarted")]
        [switch]$OobeStarted,
        [Parameter(Mandatory = $false, ParameterSetName = "VmTestPath")]
        [string]$PathToVerify,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 10,
        [Parameter(Mandatory = $false)]
        [int]$WaitSeconds = 15,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "Wait-ForVm: WhatIf: Will wait for $VmName for $TimeoutMinutes minutes to become ready" -Warning
        return $true
    }

    $ready = $false

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeSpan = New-TimeSpan -Minutes $TimeoutMinutes
    $stopWatch.Start()

    if ($VmState) {
        Write-Log "Wait-ForVm: $VmName`: Waiting for VM to go in $VmState state..."
        do {
            try {
                $vmTest = Get-VM -Name $VmName
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "Waiting for VM to go in '$VmState' state. Current State: $($vmTest.State)" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                $ready = $vmTest.State -eq $VmState
                Start-Sleep -Seconds 5
            }
            catch {
                $ready = $false
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($OobeComplete.IsPresent) {
        $originalStatus = "Waiting for OOBE to complete. "
        Write-Log "Wait-ForVm: $VmName`: $originalStatus"
        Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $originalStatus -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
        $readyOobe = $false
        $wwahostrunning = $false
        $readySmb = $false

        # SuppressLog for all Invoke-VmCommand calls here since we're in a loop.
        do {
            # Check OOBE complete registry key
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState }

            # Wait until OOBE is ready

            if ($null -ne $out.ScriptBlockOutput -and -not $readyOobe) {
                Write-Log "Wait-ForVm: $VmName`: OOBE State is $($out.ScriptBlockOutput)"
                $status = $originalStatus
                $status += "Current State: $($out.ScriptBlockOutput)"
                $readyOobe = "IMAGE_STATE_COMPLETE" -eq $out.ScriptBlockOutput
            }

            if (-not $readyOobe) {
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $status -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 5
            }

            # Wait until \\localhost\c$ is accessible
            if (-not $readySmb -and $readyOobe) {
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "OOBE complete. Waiting 15 seconds, before checking SMB access" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds 15
                $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -ScriptBlock { Test-Path -Path "\\localhost\c$" -ErrorAction SilentlyContinue }
                if ($null -ne $out.ScriptBlockOutput -and -not $readySmb) { Write-Log "Wait-ForVm: $VmName`: OOBE complete. \\localhost\c$ access result is $($out.ScriptBlockOutput)" }
                $readySmb = $true -eq $out.ScriptBlockOutput
                if ($readySmb) { Start-Sleep -Seconds 15 } # Extra 15 second wait to ensure wwahost has had a chance to start
            }

            # Wait until wwahost.exe is not found, or not longer running
            if ($readySmb) {
                $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue }

                if ($wwahost.ScriptBlockOutput) {
                    $wwahostrunning = $true
                    Write-Log "Wait-ForVm: $VmName`: OOBE complete. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running." -Verbose
                    Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "OOBE complete, and SMB available. Waiting for WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) to stop before continuing" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                    Start-Sleep -Seconds 15
                }
                else {
                    Write-Log "Wait-ForVm: $VmName`: OOBE complete. WWAHost not running."
                    $wwahostrunning = $false
                }
            }

            # OOBE and SMB ready, buffer wait to ensure we're at login screen. Bad things happen if you reboot the machine before it really finished OOBE.
            if (-not $wwahostrunning -and $readySmb) {
                Write-Log "Wait-ForVm: $VmName`: VM is ready. Waiting $WaitSeconds seconds before continuing."
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "VM is ready. Waiting $WaitSeconds seconds before continuing" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
                Start-Sleep -Seconds $WaitSeconds
                $ready = $true
            }

        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($OobeStarted.IsPresent) {
        $status = "Waiting for OOBE to start "
        Write-Log "Wait-ForVm: $VmName`: $status"
        Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed)" -Status $status -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)

        do {
            $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue }

            if ($wwahost.ScriptBlockOutput) {
                $ready = $true
                Write-Log "Wait-ForVm: $VmName`: OOBE Started. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running." -Verbose
                Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status "OOBE Started. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running" -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            }
            else {
                Write-Log "Wait-ForVm: $VmName`: OOBE hasn't started yet. WWAHost not running."
                $ready = $false
                Start-Sleep -Seconds $WaitSeconds
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    if ($PathToVerify) {
        if ($PathToVerify -eq "C:\Users") {
            $msg = "Waiting for VM to respond"
        }
        else {
            $msg = "Waiting for $PathToVerify to exist"
        }

        Write-Log "Wait-ForVm: $VmName`: $msg..."
        do {
            Write-Progress -Activity  "$VmName`: Waiting $TimeoutMinutes minutes. Elapsed time: $($stopWatch.Elapsed.ToString("hh\:mm\:ss\:ff"))" -Status $msg -PercentComplete ($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100)
            Start-Sleep -Seconds 5

            # Test if path exists; if present, VM is ready. SuppressLog since we're in a loop.
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -ScriptBlock { Test-Path $using:PathToVerify } -SuppressLog
            $ready = $true -eq $out.ScriptBlockOutput

        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
    }

    Write-Progress -Activity "$VmName`: Waiting for virtual machine" -Status "Wait complete." -Completed

    if ($ready) {
        Write-Log "Wait-ForVm: $VmName`: VM is now available." -Success
    }

    if (-not $ready) {
        Write-Log "Wait-ForVm: $VmName`: Timer expired while waiting for VM" -Warning
    }

    return $ready
}

function Invoke-VmCommand {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $true, HelpMessage = "Script Block to execute")]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "Argument List to supply to ScriptBlock")]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $false, HelpMessage = "Display Name of the script for log/console")]
        [string]$DisplayName,
        [Parameter(Mandatory = $false, HelpMessage = "Suppress log entries. Useful when waiting for VM to be ready to run commands.")]
        [switch]$SuppressLog,
        [Parameter(Mandatory = $false, HelpMessage = "What If")]
        [switch]$WhatIf
    )

    # Set display name for logging
    if (-not $DisplayName) {
        $DisplayName = $ScriptBlock
    }

    # WhatIf
    if ($WhatIf.IsPresent) {
        Write-Log "Invoke-VmCommand: WhatIf: Will run '$DisplayName' inside '$VmName'"
        return $true
    }

    # Fatal failure
    if ($null -eq $Common.LocalAdmin) {
        Write-Log "Invoke-VmCommand: $VmName`: Skip running '$DisplayName' since Local Admin creds not available" -Failure
        return $false
    }

    # Log entry
    if (-not $SuppressLog) {
        Write-Log "Invoke-VmCommand: $VmName`: Running '$DisplayName'" -Verbose
    }

    # Create return object
    $return = [PSCustomObject]@{
        CommandResult     = $false
        ScriptBlockFailed = $false
        ScriptBlockOutput	= $null
    }

    # Prepare args
    $HashArguments = @{
        ScriptBlock = $ScriptBlock
    }

    if ($ArgumentList) {
        $HashArguments.Add("ArgumentList", $ArgumentList)
    }

    # Get VM Session
    $ps = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName
    $failed = $null -eq $ps

    # Run script block inside VM
    if (-not $failed) {
        $return.ScriptBlockOutput = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue
        if ($Err2.Count -ne 0) {
            $failed = $true
            $return.ScriptBlockFailed = $true
            if (-not $SuppressLog) {
                Write-Log "Invoke-VmCommand: $VmName`: Failed to run '$DisplayName'. Error: $Err2" -Failure
            }
        }
    }
    else {
        # Uncomment when debugging, this is called many times while waiting for VM to be ready
        # Write-Log "Invoke-VmCommand: $VmName`: Failed to get VM Session." -Failure -LogOnly
        # return $return
    }

    # Set Command Result state in return object
    if (-not $failed) {
        $return.CommandResult = $true
        if (-not $SuppressLog) {
            Write-Log "Invoke-VmCommand: $VmName`: Successfully ran '$DisplayName'" -LogOnly -Verbose
        }
    }

    return $return

}

$global:ps_cache = @{}
function Get-VmSession {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP"
    )

    $ps = $null

    # Cache key
    $cacheKey = $VmName + "-" + $VmDomainName

    # Set domain name to VmName when workgroup
    if ($VmDomainName -eq "WORKGROUP") {
        $vmDomainName = $VmName
    }

    # Get PS Session
    $username = "$VmDomainName\$($Common.LocalAdmin.UserName)"

    # Retrieve session from cache
    if ($global:ps_cache.ContainsKey($cacheKey)) {
        $ps = $global:ps_cache[$cacheKey]
        if ($ps.Availability -eq "Available") {
            # Write-Log "Get-VmSession: $VmName`: Returning session for $userName from cache using key $cacheKey." -Verbose
            return $ps
        }
    }

    $creds = New-Object System.Management.Automation.PSCredential ($username, $Common.LocalAdmin.Password)

    $ps = New-PSSession -Name $VmName -VMName $VmName -Credential $creds -ErrorVariable Err0 -ErrorAction SilentlyContinue
    if ($Err0.Count -ne 0) {
        Write-Log "Get-VmSession: $VmName`: Failed to establish a session using $username. Error: $Err0" -Warning -Verbose
        if ($VmDomainName -ne $VmName) {
            $username = "$VmName\$($Common.LocalAdmin.UserName)"
            $creds = New-Object System.Management.Automation.PSCredential ($username, $Common.LocalAdmin.Password)
            $cacheKey = $VmName + "-WORKGROUP"
            Write-Log "Get-VmSession: $VmName`: Attempting to get a session using $username." -Verbose
            $ps = New-PSSession -Name $VmName -VMName $VmName -Credential $creds -ErrorVariable Err1 -ErrorAction SilentlyContinue
            if ($Err1.Count -ne 0) {
                Write-Log "Get-VmSession: $VmName`: Failed to establish a session using $username. Error: $Err1" -Failure -Verbose
                return $null
            }
        }
        else {
            return $null
        }
    }

    # Cache & return session
    Write-Log "Get-VmSession: $VmName`: Created session with VM using $username. CacheKey [$cacheKey]" -Success -Verbose
    $global:ps_cache[$cacheKey] = $ps
    return $ps
}

function Get-StorageConfig {

    $configPath = Join-Path $Common.ConfigPath "_storageConfig.json"

    if (-not (Test-Path $configPath)) {
        $Common.FatalError = "Get-StorageConfig: Storage Config not found. Refer internal documentation."
    }

    try {

        # Disable Progress and Verbose
        $pp = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $vp = $VerbosePreference
        $VerbosePreference = 'SilentlyContinue'

        # Get storage config
        $config = Get-Content -Path $configPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $StorageConfig.StorageLocation = $config.storageLocation
        $StorageConfig.StorageToken = $config.storageToken

        # Get image list from storage location
        $updateList = $true

        # Set file name based on git branch
        $fileListName = "_fileList.json"
        $currentBranch = (& git branch) -match '\*'
        if ($currentBranch -and $currentBranch -notmatch "main") {
            $fileListName = "_fileList_develop.json"
        }
        $fileListPath = Join-Path $Common.AzureFilesPath $fileListName
        $fileListLocation = "$($StorageConfig.StorageLocation)/$fileListName"

        # See if image list needs to be updated
        if (Test-Path $fileListPath) {
            $Common.AzureFileList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $updateList = $Common.AzureFileList.UpdateFromStorage
        }

        # Update file list
        if (($updateList -and -not $InJob.IsPresent) -or -not (Test-Path $fileListPath)) {

            Write-Log "Updating fileList from azure storage" -LogOnly

            # Get file list
            #$worked = Get-File -Source $fileListLocation -Destination $fileListPath -DisplayName "Updating file list" -Action "Downloading" -Silent -ForceDownload
            $fileListUrl = $fileListLocation + "?$($StorageConfig.StorageToken)"
            $response = Invoke-WebRequest -Uri $fileListUrl -UseBasicParsing -ErrorAction Stop
            if (-not $response) {
                $Common.FatalError = "Get-StorageConfig: Failed to download file list."
            }
            else {
                $response.Content.Trim() | Out-File -FilePath $fileListPath -Force -ErrorAction SilentlyContinue
                $Common.AzureFileList = $response.Content.Trim() | ConvertFrom-Json -ErrorAction Stop
            }

        }

        if ($InJob.IsPresent) {
            Write-Log "Skipped updating fileList from azure storage, since we're running inside a job." -Verbose
        }

        # Get local admin password, regardless of whether we should update file list
        $username = "vmbuildadmin"
        $item = $Common.AzureFileList.OS | Where-Object { $_.id -eq $username }
        $fileUrl = "$($StorageConfig.StorageLocation)/$($item.filename)?$($StorageConfig.StorageToken)"
        $response = Invoke-WebRequest -Uri $fileUrl -UseBasicParsing -ErrorAction Stop
        $s = ConvertTo-SecureString $response.Content.Trim() -AsPlainText -Force
        $Common.LocalAdmin = New-Object System.Management.Automation.PSCredential ($username, $s)

    }
    catch {
        $Common.FatalError = "Get-StorageConfig: Storage Config found, but storage access failed. $_"
        Write-Host $_.ScriptStackTrace | Out-Host
    }
    finally {
        $ProgressPreference = $pp
        $VerbosePreference = $vp
    }
}

function Get-FileFromStorage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Storage File to download.")]
        [object]$File,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Ignore Hash Failures on file downloads.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $imageName = $File.id
    Write-Log "Get-FileFromStorage: Downloading/Verifying '$imageName'" -SubActivity

    # What if returns success
    if ($WhatIf) {
        return $true
    }

    $success = $true
    $hashAlg = "MD5"
    $i = 0
    foreach ($fileItem in $File.filename) {

        $isArray = $File.filename -is [array]

        if ($isArray) {
            $fileName = $File.filename[$i]
            $fileHash = $File.($hashAlg)[$i]
            $i++
        }
        else {
            $fileName = $fileItem
            $fileHash = $File.($hashAlg)
        }

        $imageUrl = "$($StorageConfig.StorageLocation)/$($filename)"
        $imageFileName = Split-Path $filename -Leaf
        $localImagePath = Join-Path $Common.AzureFilesPath $filename
        $localImageHashPath = "$localImagePath.$hashAlg"

        $download = $true
        if (Test-Path $localImagePath) {

            if (Test-Path $localImageHashPath) {
                # Read hash from local hash file
                $localFileHash = Get-Content $localImageHashPath
            }
            else {
                # Download if file present, but hashFile isn't there.
                Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading" -ResumeDownload -UseCDN:$UseCDN -WhatIf:$WhatIf

                # Calculate file hash, save to local hash file
                Write-Log "Get-FileFromStorage: Calculating $hashAlg hash for $filename in $($Common.AzureFilesPath)..."
                $hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
                $localFileHash = $hashFileResult.Hash
                $localFileHash | Out-File -FilePath $localImageHashPath -Force
            }

            if ($localFileHash -eq $fileHash) {
                Write-Log "Get-FileFromStorage: Found $filename in $($Common.AzureFilesPath) with expected hash $fileHash."
                if ($ForceDownloadFiles.IsPresent) {
                    Write-Log "Get-FileFromStorage: ForceDownloadFiles switch present. Removing pre-existing $imageFileName file..." -Warning
                    Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
                }
                else {
                    Write-Log "Get-FileFromStorage: ForceDownloadFiles switch not present. Skip downloading '$imageFileName'." -LogOnly
                    $download = $false
                    continue
                }
            }
            else {
                Write-Log "Get-FileFromStorage: Found $filename in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $fileHash. Redownloading..."
                Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
                Remove-Item -Path $localImageHashPath -Force -WhatIf:$WhatIf | Out-Null
                $download = $true
            }
        }

        if ($download) {
            $worked = Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading" -UseCDN:$UseCDN -WhatIf:$WhatIf
            if (-not $worked) {
                $success = $false
            }
            else {
                # Calculate file hash, save to local hash file
                Write-Log "Get-FileFromStorage: Calculating $hashAlg hash for $filename in $($Common.AzureFilesPath)..."
                $hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
                $localFileHash = $hashFileResult.Hash
                if ($localFileHash -eq $fileHash) {
                    $localFileHash | Out-File -FilePath $localImageHashPath -Force
                }
                else {
                    if ($IgnoreHashFailure) {
                        $success = $true
                    }
                    else {
                        Write-Log "Get-FileFromStorage: Downloaded $filename in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $fileHash." -Failure
                        $success = $false
                    }
                }
            }
        }
    }

    return $success
}

$QuickEditCodeSnippet = @"
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;


public static class DisableConsoleQuickEdit
{
    const uint ENABLE_QUICK_EDIT = 0x0040;

    // STD_INPUT_HANDLE (DWORD): -10 is the standard input device.
    const int STD_INPUT_HANDLE = -10;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll")]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll")]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    public static bool SetQuickEdit(bool SetEnabled)
    {

        IntPtr consoleHandle = GetStdHandle(STD_INPUT_HANDLE);

        // get current console mode
        uint consoleMode;
        if (!GetConsoleMode(consoleHandle, out consoleMode))
        {
            // ERROR: Unable to get console mode.
            return false;
        }

        // Clear the quick edit bit in the mode flags
        if (SetEnabled)
        {
            consoleMode &= ~ENABLE_QUICK_EDIT;
        }
        else
        {
            consoleMode |= ENABLE_QUICK_EDIT;
        }

        if (!SetConsoleMode(consoleHandle, consoleMode))
        {
            return false;
        }

        return true;
    }
}
"@

if ($null -eq $QuickEditMode) {
    try {
        $QuickEditMode = add-type -TypeDefinition $QuickEditCodeSnippet -Language CSharp -ErrorAction SilentlyContinue
    }
    catch {}
}

function Set-QuickEdit() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, HelpMessage = "This switch will disable Console QuickEdit option")]
        [switch]$DisableQuickEdit = $false
    )

    if ([DisableConsoleQuickEdit]::SetQuickEdit($DisableQuickEdit)) {
        Write-Verbose "QuickEdit settings has been updated."
    }
    else {
        Write-Verbose "Something went wrong changing QuickEdit settings."
    }
}

function Set-SupportedOptions {

    $roles = @(
        "DC",
        "Primary",
        "CAS",
        "PassiveSite",
        "FileServer",
        "DPMP",
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient"
    )

    $rolesForExisting = @(
        "CAS",
        "Primary",
        "PassiveSite",
        "FileServer",
        "DPMP",
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient"
    )

    $cmVersions = @(
        "current-branch",
        "tech-preview"
    )

    $operatingSystems = $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" } | Sort-Object

    $sqlVersions = $Common.AzureFileList.ISO.id | Select-Object -Unique | Sort-Object

    $supported = [PSCustomObject]@{
        Roles            = $roles
        RolesForExisting = $rolesForExisting
        OperatingSystems = $operatingSystems
        SqlVersions      = $sqlVersions
        CMVersions       = $cmVersions
    }

    $Common.Supported = $supported

}

####################
### DOT SOURCING ###
####################
. $PSScriptRoot\common\Common.BaseImage.ps1
. $PSScriptRoot\common\Common.Config.ps1
. $PSScriptRoot\common\Common.RdcMan.ps1
. $PSScriptRoot\common\Common.Remove.ps1

############################
### Common Object        ###
############################

if (-not $Common.Initialized) {

    # Write progress
    Write-Progress "Loading required modules." -Status "Please wait..." -PercentComplete -1

    # Paths
    $staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "baseimagestaging")           # Path where staged files for base image creation go
    $storagePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "azureFiles")             # Path for downloaded files
    $desktopPath = [Environment]::GetFolderPath("Desktop")

    # Common global props
    $global:Common = [PSCustomObject]@{
        Initialized           = $true
        TempPath              = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "temp")             # Path for temporary files
        ConfigPath            = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files
        ConfigSamplesPath     = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config\samples")   # Path for Config files
        AzureFilesPath        = $storagePath                                                              # Path for downloaded files
        AzureImagePath        = New-Directory -DirectoryPath (Join-Path $storagePath "os")                # Path to store sysprepped gold image after customization
        AzureIsoPath          = New-Directory -DirectoryPath (Join-Path $storagePath "iso")               # Path for ISO's (typically for SQL)
        AzureToolsPath        = New-Directory -DirectoryPath (Join-Path $storagePath "tools")             # Path for downloading tools to inject in the VM
        StagingAnswerFilePath = New-Directory -DirectoryPath (Join-Path $staging "unattend")              # Path for Answer files
        StagingInjectPath     = New-Directory -DirectoryPath (Join-Path $staging "filesToInject")         # Path to files to inject in VHDX
        StagingWimPath        = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
        StagingImagePath      = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
        StagingVMPath         = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
        LogPath               = Join-Path $PSScriptRoot "VMBuild.log"                                     # Log File
        RdcManFilePath        = Join-Path $DesktopPath "memlabs.rdg"                                      # RDCMan File
        VerboseEnabled        = $VerboseEnabled.IsPresent                                                 # Verbose Logging
        Supported             = $null                                                                     # Supported Configs
        AzureFileList         = $null
        LocalAdmin            = $null
        FatalError            = $null
    }

    # Storage config
    $global:StorageConfig = [PSCustomObject]@{
        StorageLocation = $null
        StorageToken    = $null
    }

    Write-Log "Loading required modules." -Verbose

    ### Test Storage config and access
    Get-StorageConfig

    ### Set supported options
    Set-SupportedOptions

    if (-not $InJob.IsPresent) {
        # Retrieve VM List, and cache results
        Get-List -Type VM -ResetCache | Out-Null
    }

    # Add HGS Registry key to allow local CA Cert
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null

    # Write progress
    Write-Progress "Loading required modules." -Completed

}