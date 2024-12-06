# Common.ps1
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

Function Write-ProgressElapsed {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StopWatch,
        [Parameter(Mandatory = $true)]
        [object]$TimeSpan,
        [Parameter(Mandatory = $true)]
        [String]$text,
        [Parameter(Mandatory = $false)]
        [switch]$showTimeout,
        [Parameter(Mandatory = $false)]
        [string]$FailCount,
        [Parameter(Mandatory = $false)]
        [string]$FailCountMax


    )
    try {
        $percent = [Math]::Min(($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100), 100)
        $msg = ""
        if ($showTimeout) {
            $msg = "Waiting $TimeSpan  "
        }
        $msg = $msg + "Elapsed: $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))"
        if ($FailCount) {
            $msg = $msg + " Failed $FailCount / $FailCountMax"
        }
        Write-Progress2 $msg -Status $text -PercentComplete $percent
    }
    catch {
        Write-Exception $_
        Write-Progress2 "Exception" -Status $_
    }
}

#Main wrapper for Write-Progress.  This allows all params, and catches any errors
Function Write-Progress2 {

    try {
        # write-host -NoNewline "$hideCursor"
        Write-Progress2Impl @Args @PSBoundParameters | out-null
    }
    catch {
        Write-Exception -ExceptionInfo $_
        write-Log "Write-Progress $args $_"
    }
}

#Sub Wrapper for Write-Progress.  This allows PercentComplete to be modified, and can log the activity in verbose
#We can also add additional params here if needed. (eg -NoLog)
Function Write-Progress2Impl {
    [CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=2097036', RemotingCapability = 'None')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        ${Activity},

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]
        ${Status},

        [Parameter(Position = 2)]
        [ValidateRange(0, 2147483647)]
        [int]
        ${Id},

        #[ValidateRange(-1, 100)]
        [int]
        ${PercentComplete},

        [int]
        ${SecondsRemaining},

        [string]
        ${CurrentOperation},

        [ValidateRange(-1, 2147483647)]
        [int]
        ${ParentId},

        [switch]
        ${Completed},

        [int]
        ${SourceId},

        [switch]
        ${force},

        [switch]
        ${log}
    )
    dynamicparam {

        try {
            $targetCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Progress', [System.Management.Automation.CommandTypes]::Cmdlet, $PSBoundParameters)
            $dynamicParams = @($targetCmd.Parameters.GetEnumerator() | Microsoft.PowerShell.Core\Where-Object { $_.Value.IsDynamic })
            if ($dynamicParams.Length -gt 0) {
                $paramDictionary = [Management.Automation.RuntimeDefinedParameterDictionary]::new()
                foreach ($param in $dynamicParams) {
                    $param = $param.Value

                    if (-not $MyInvocation.MyCommand.Parameters.ContainsKey($param.Name)) {
                        $dynParam = [Management.Automation.RuntimeDefinedParameter]::new($param.Name, $param.ParameterType, $param.Attributes)
                        $paramDictionary.Add($param.Name, $dynParam)
                    }
                }

                return $paramDictionary
            }
        }
        catch {
            throw
        }

    }
    begin {

        try {
            $Percent = $null
            if ($PSBoundParameters.TryGetValue('PercentComplete', [ref]$Percent)) {
                if ($Percent -le 1) {
                    $Percent = 1
                }
                if ($Percent -ge 100) {
                    $Percent = 99
                }
                $PSBoundParameters['PercentComplete'] = $percent
            }
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }

            $forcevalue = $null
            if ($force -or $PSBoundParameters.TryGetValue('force', [ref]$forcevalue)) {
                $PSBoundParameters.remove("force")
                $force = $true
                $OriginalProgressPreference = $Global:ProgressPreference
                $Global:ProgressPreference = 'Continue'
            }

            $logvalue = $null
            $writeLog = $false
            if ($log -eq $true -or $PSBoundParameters.TryGetValue('log', [ref]$logvalue)) {
                $PSBoundParameters.remove("log")
                $writeLog = $true
            }

            $Activityvalue = $null
            if ($PSBoundParameters.TryGetValue('Activity', [ref]$Activityvalue)) {
                $Activityvalue = $Activity.Trim()
                $Activityvalue = "  " + $Activityvalue
                # if ($Activityvalue.Contains("`n")) {
                #     Write-Log "$Activity contains new-line"
                # }
                $PSBoundParameters['Activity'] = $Activityvalue
            }

            $StatusValue = $null
            if ($PSBoundParameters.TryGetValue('Status', [ref]$StatusValue)) {
                $StatusValue = $StatusValue.TrimEnd()

                #if ($StatusValue.Contains("`n")) {
                #    Write-Log "$StatusValue contains new-line"
                #}
                $PSBoundParameters['Status'] = $StatusValue
            }

            if ($writeLog) {
                Write-Log "Activity: $Activity  Status: $Status" -LogOnly
            }
            else {
                if ($Global:LastStatus -ne $Status + $Percent) {
                    Write-Log "Write-Status: Activity: $Activity  Status: $Status Percent: $Percent" -verbose -LogOnly
                    $Global:LastStatus = $Status + $Percent
                }
                else {
                    #Write-Log "Ignored Write-Status: Activity: $Activity  Status: $Status Percent: $Percent" -verbose -LogOnly
                }
            }

            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Progress', [System.Management.Automation.CommandTypes]::Cmdlet)
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }

            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
        finally {
            if ($force) {
                $Global:ProgressPreference = $OriginalProgressPreference
            }
        }

    }
    process {

        try {
            if ($force) {
                $OriginalProgressPreference = $Global:ProgressPreference
                $Global:ProgressPreference = 'Continue'
            }
            if ($Activity) {
                $Activity = $Activity.TrimEnd()
                if ($Activity.Contains("`n")) {
                    Write-Log "$Activity contains new-line"
                }
            }
            if ($Status) {
                $Status = $Status.TrimEnd()
                if ($Status.Contains("`n")) {
                    Write-Log "$Status contains new-line"
                }
            }

            if ($PercentComplete -le 1) {
                $PercentComplete = 1
            }
            if ($PercentComplete -ge 100) {
                $PercentComplete = 99
            }

            $steppablePipeline.Process($_)
        }
        catch {
            throw
        }
        finally {
            if ($force) {
                $Global:ProgressPreference = $OriginalProgressPreference
            }
        }

    }
    end {

        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }

    }
}
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
        [switch]$NoNewLine,
        [Parameter(Mandatory = $false)]
        [switch]$Highlight,
        [Parameter(Mandatory = $false)]
        [switch]$SubActivity,
        [Parameter(Mandatory = $false)]
        [switch]$LogOnly,
        [Parameter(Mandatory = $false)]
        [switch]$OutputStream,
        [Parameter(Mandatory = $false)]
        [switch]$HostOnly,
        [Parameter(Mandatory = $false)]
        [switch]$NoIndent,
        [Parameter(Mandatory = $false)]
        [switch]$ShowNotification
    )

    $HashArguments = @{}

    $info = $true
    $logLevel = 1    # 0 = Verbose, 1 = Info, 2 = Warning, 3 = Error

    # Get caller function name and add it to Text
    try {
        $caller = (Get-PSCallStack | Select-Object Command, Location, Arguments)[1].Command
        if ($caller -and $caller -like "*.ps1") { $caller = $caller -replace ".ps1", "" }
        if (-not $caller) { $caller = "<Script>" }
    }
    catch {
        $caller = "<Script>"
    }

    if ($caller -eq "<ScriptBlock>") {
        if ($global:ScriptBlockName) {
            $caller = $global:ScriptBlockName
        }
    }

    if ($Text -is [string]) { $Text = $Text.ToString().Trim() }
    # $Text = "[$caller] $Text"

    if ($ShowNotification.IsPresent) {
        Show-Notification -ToastText $Text
    }

    # Is Verbose?
    $IsVerbose = $false
    if ($MyInvocation.BoundParameters["Verbose"].IsPresent) {
        $IsVerbose = $true
    }

    If ($Success.IsPresent) {
        $info = $false
        $TextOutput = "  SUCCESS: $Text"
        # $Text = "SUCCESS: $Text"
        $HashArguments.Add("ForegroundColor", "Chartreuse")
    }

    If ($Activity.IsPresent) {
        $info = $false
        Set-TitleBar $Text
        Write-Host
        if ($NoNewLine.IsPresent) {
            $Text = "=== $Text"
        }
        else {
            $Text = "=== $Text`r`n"
        }

        $HashArguments.Add("ForegroundColor", "DeepSkyBlue")
    }

    If ($SubActivity.IsPresent -and -not $Activity.IsPresent) {
        $info = $false
        $Text = "  === $Text"
        $HashArguments.Add("ForegroundColor", "LightSkyBlue")
    }

    If ($Warning.IsPresent) {
        $info = $false
        $logLevel = 2
        $TextOutput = "  WARNING: $Text"
        # $Text = "WARNING: $Text"
        $HashArguments.Add("ForegroundColor", "Yellow")

    }

    If ($Failure.IsPresent) {
        $info = $false
        $logLevel = 3
        $TextOutput = "  ERROR: $Text"
        # $Text = "ERROR: $Text"
        $HashArguments.Add("ForegroundColor", "Red")

    }

    If ($IsVerbose) {
        $info = $false
        $logLevel = 0
        $TextOutput = "  VERBOSE: $Text"
        # $Text = "VERBOSE: $Text"
    }

    If ($Highlight.IsPresent) {
        $info = $false
        Write-Host
        $Text = "  +++ $Text"
        $HashArguments.Add("ForegroundColor", "DeepSkyBlue")
    }

    if ($info) {
        $HashArguments.Add("ForegroundColor", "White")
        $TextOutput = "  $Text"
        #$Text = "INFO: $Text"
    }

    # Write to output stream
    if ($OutputStream.IsPresent) {
        $Output = [PSCustomObject]@{
            Text     = $text
            Loglevel = $logLevel
        }
        if ($HashArguments) {
            foreach ($arg in $HashArguments.Keys) {
                $Output | Add-Member -MemberType NoteProperty -Name $arg -Value $HashArguments[$arg] -Force
            }
        }

        Write-Output $Output
    }

    # Write progress if output stream and failure present
    if ($OutputStream.IsPresent -and $Failure.IsPresent) {
        Write-Progress -Activity $Text -Status "Failed :-(" -Completed
    }

    # Write to console, if not logOnly and not OutputStream
    $writeHost = $false
    If (-not $LogOnly.IsPresent -and -not $OutputStream.IsPresent -and -not $IsVerbose) {
        $writeHost = $true
    }

    # Always log verbose to host, if VerboseEnabled
    if ($IsVerbose -and $Common.VerboseEnabled) {
        $writeHost = $true
    }

    # Suppress write-host when in-job
    if ($InJob.IsPresent) {
        $writeHost = $false
    }

    if ($writeHost) {
        if ($TextOutput) {
            if ($NoIndent.IsPresent) {
                $TextOutput = $TextOutput.Trim()
            }
            Write-Host2 $TextOutput @HashArguments
        }
        else {
            Write-Host2 $Text @HashArguments
        }
    }

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
        $Text = $Text.ToString().Trim()
        try {
            $CallingFunction = Get-PSCallStack | Select-Object -first 2 | select-object -last 1
            $context = $CallingFunction.Command
            $file = $CallingFunction.Location
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $date = Get-Date -Format 'MM-dd-yyyy'
            $time = Get-Date -Format 'HH:mm:ss.fff'

            $logText = "<![LOG[$Text]LOG]!><time=""$time"" date=""$date"" component=""$caller"" context=""$context"" type=""$logLevel"" thread=""$tid"" file=""$file"">"
            $logText | Out-File $Common.LogPath -Append -Encoding utf8
        }
        catch {
            try {
                # Retry once and ignore if failed
                $logText | Out-File $Common.LogPath -Append -ErrorAction SilentlyContinue -Encoding utf8
            }
            catch {
                # ignore
            }
        }
    }
}

function Show-Notification {
    [cmdletbinding()]
    Param (
        [string]
        $ToastTitle = "MEMLabs VMBuild",
        [string]
        [parameter(ValueFromPipeline)]
        $ToastText,
        [string]
        [parameter(ValueFromPipeline)]
        $ToastTag = "VMBuild"
    )

    if ($Common.PS7) { return } # Not supported on PS7

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $Template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)

    $RawXml = [xml] $Template.GetXml()
    ($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "1" }).AppendChild($RawXml.CreateTextNode($ToastTitle)) > $null
    ($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "2" }).AppendChild($RawXml.CreateTextNode($ToastText)) > $null

    $SerializedXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $SerializedXml.LoadXml($RawXml.OuterXml)

    $Toast = [Windows.UI.Notifications.ToastNotification]::new($SerializedXml)
    $Toast.Tag = $ToastTag
    $Toast.Group = "VMBuild"
    $Toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(1)

    $Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell")
    $Notifier.Show($Toast);
}

function Write-Exception {
    [CmdletBinding()]
    param (
        [Parameter()]
        $ExceptionInfo,
        [Parameter()]
        $AdditionalInfo
    )

    $guid = (New-Guid).Guid
    $crashFile = Join-Path $Common.CrashLogsPath "$guid.txt"

    $sb = [System.Text.StringBuilder]::new()

    $parentFunctionName = (Get-PSCallStack)[1].FunctionName
    $msg = "`n=== $parentFunctionName`: An error occurred: $ExceptionInfo"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red

    $msg = "`n=== Exception.ScriptStackTrace:`n"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red
    Write-Log -LogOnly $msg -Failure

    $msg = $ExceptionInfo.ScriptStackTrace
    [void]$sb.AppendLine($msg)
    $msg | Out-Host
    Write-Log -LogOnly $msg -Failure

    $msg = "`n=== Get-PSCallStack:`n"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red
    Write-Log -LogOnly $msg -Failure

    $msg = (Get-PSCallStack | Select-Object Command, Location, Arguments | Format-Table | Out-String).Trim()
    [void]$sb.AppendLine($msg)
    $msg | Out-Host
    Write-Log -LogOnly $msg -Failure
    if ($AdditionalInfo) {
        $msg = "`n=== Additional Information:`n"
        [void]$sb.AppendLine($msg)
        Write-Host2 "$msg" -ForegroundColor Red
        Write-Host "Dumped to $crashFile"
        Write-Log -LogOnly $msg -Failure
        Write-Log -LogOnly  "Dumped to $crashFile" -Failure
        $msg = ($AdditionalInfo | Out-String).Trim()
        [void]$sb.AppendLine($msg)
        Write-Log -LogOnly $msg -Failure
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
        [Parameter(Mandatory = $false)]
        [switch]$UseBITS,
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
        Write-Log "WhatIf: $Action $sourceDisplay file to $Destination"
        return $true
    }

    # Not making these mandatory to allow WhatIf to run with null values
    if (-not $Source -and -not $Destination) {
        Write-Log "Source and Destination parameters must be specified." -Failure
        return $false
    }

    # Not making these mandatory to allow WhatIf to run with null values
    if (-not $Action) {
        Write-Log "Action must be specified." -Failure
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
        Write-Log "$Action $sourceDisplay to $Destination... "
        if ($DisplayName) { Write-Log "$DisplayName" -LogOnly }
    }

    if ($RemoveIfPresent.IsPresent -and (Test-Path $Destination)) {
        Remove-Item -Path $Destination -Force -Confirm:$false -WhatIf:$WhatIf
    }

    # Create destination directory if it doesn't exist
    $destinationDirectory = Split-Path $Destination -Parent
    if (-not (Test-Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'Continue'
    try {
        $i = 0
        $timedOut = $false

        # Wait for existing download to finish, dont bother when action is copying
        if ($Action -eq "Downloading") {
            while (Get-Process -Name "curl" -ErrorAction SilentlyContinue) {
                Write-Log "Download for '$sourceDisplay' waiting on an existing download. Checking again in 2 minutes..." -Warning
                Start-Sleep -Seconds 120

                $i++
                if ($i -gt 5) {
                    Write-Log "Timed out while waiting to download '$sourceDisplay'." -Failure
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
            Write-Log "Download skipped. $Destination already exists." -LogOnly
            return $true
        }

        if ($Action -eq "Downloading") {
            if ($UseBITS.IsPresent) {
                try {
                    Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
                }
                catch {
                    Write-log "Start-BitsTransfer $_" -LogOnly
                    if ($_ -Match "the module could not be loaded" ) {
                        Write-Log -Failure "Could not invoke Start-BitsTransfer due to load failure.  Please close all powershell windows and retry."
                    }
                }
            }
            else {
                $worked = Start-CurlTransfer @HashArguments -Silent:$Silent
                if (-not $worked) {
                    Write-Log "Failed to download file using curl"
                    return $false
                }
            }
        }
        else {

            Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
        }

        if (Test-Path $Destination) {
            return $true
        }
        else {
            Write-Log "Destinataion $Destination does not exist" -Failure
        }
        Write-Log "Returning failure from Get-File"
        return $false
    }
    catch {
        Write-Log "$Action $sourceDisplay failed. Error: $($_.ToString().Trim())" -Failure
        Write-Log "$Action $sourceDisplay failed. Error: $($_.ScriptStackTrace)" -LogOnly
        return $false
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}

function Copy-ItemSafe {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Destination,
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [string] $VMDomainName,
        [Parameter(Mandatory = $false)]
        [switch] $Recurse,
        [Parameter(Mandatory = $false)]
        [switch] $Container,
        [Parameter(Mandatory = $false)]
        [switch] $WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        [Parameter(Mandatory = $false, HelpMessage = "When running as a job.. Timeout length")]
        [int]$TimeoutSeconds = 360
    )
    #$PSScriptRoot = $using:PSScriptRoot
    $location = $PSScriptRoot
    $testpath = Join-Path $location "Common.ps1"
    if (-not (Test-Path -PathType Leaf $testpath)) {
        write-host "Could not find $testpath"
        $location = Split-Path $location -Parent
        $testpath = Join-Path $location "Common.ps1"
        if (-not (Test-Path -PathType Leaf $testpath)) {
            write-host "Could not find $testpath"
            return $false
        }
    }
    $enableVerbose = $false
    $CopyItemScript = {
        try {
            #Write-Host "CopyItemScript starting"
            # Dot source common
            $rootPath = $using:location
            #Write-Host "Loading common: . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose"
            . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose

            $ps = Get-VmSession -VmName $using:VMName -VmDomainName $using:VMDomainName

            if ($ps) {
                Write-Log "[Copy-ItemSafe] [$($using:VMName)] Copying $($using:Path) to $($using:Destination) Whatif:$($using:WhatIF)"
                Copy-Item -ToSession $ps -Path $using:Path -Destination $using:Destination -Recurse:$using:Recurse -Container:$using:Container -Force:$using:Force -verbose:$using:enableVerbose -WhatIf:$using:WhatIF
            }
            else {
                Write-Log "[Copy-ItemSafe] Failed to get Powershell Session for $using:VMName"
                return $false
            }
        }
        catch {
            write-log $_
            return $false
        }
        return $true
    }

    write-log "[Copy-Itemsafe] location: $location enableVerbose: $enableVerbose VMName:$VMName Path:$Path Destination:$Destination WhatIF:$WhatIF Recurse:$Recurse Container:$Container  Force:$Force"

    $retries = 3
    while ($retries -gt 0) {
        $job = start-job -ScriptBlock $CopyItemScript
        $wait = Wait-Job -Timeout $TimeoutSeconds -Job $job
        $job
        if ($wait.State -eq "Running") {
            Stop-Job $job
            remove-job -job $job
            $retries--
        }
        else {
            if ($wait.State -eq "Completed") {
                $result = Receive-Job $job
                write-log "[Copy-ItemSafe] returned: $result"
                remove-job $job
                return $true
            }
            else {
                write-log "[Copy-ItemSafe] State = $($wait.State)" -logonly
                Stop-Job $job
                remove-job $job
                $retries--
            }

        }
    }
    return $false

}

function Test-URL {

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
        Write-Log "Curl was not found, and could not be installed." -Failure
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
            Write-Log "Download failed with exit code $LASTEXITCODE. Will retry $(20 - $retryCount) more times."
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


function Add-SwitchAndDhcp {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Name.")]
        [string]$NetworkName,
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name.")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Override DNS.")]
        [string]$DNSServer,
        [Parameter(Mandatory = $false, HelpMessage = "What If?")]
        [switch]$WhatIf
    )


    if ($WhatIf.IsPresent) {
        Write-Log "[What-If] Will create/verify Hyper-V switch and DHCP scopes."
        return $true
    }


    get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' } | start-service
    $service = get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' }
    if ($service) {
        Write-Log "DHCPServer Service could not be started." -Failure
        return $false
    }
    Write-Log "Creating/verifying Hyper-V switch and DHCP Scopes for '$NetworkName' network." -Activity

    $switch = Test-NetworkSwitch -NetworkName $NetworkName -NetworkSubnet $NetworkSubnet -DomainName $DomainName
    if (-not $switch) {
        Write-Log "Failed to verify/create Hyper-V switch for $NetworkName network ($NetworkSubnet). Exiting." -Failure
        return $false
    }

    # Test if DHCP scope exists, if not create it
    $worked = Test-DHCPScope -ScopeID $NetworkSubnet -ScopeName $NetworkName -DomainName $DomainName -DNSServer $DNSServer
    if (-not $worked) {
        Write-Log "Failed to verify/create DHCP Scope for the '$NetworkName' network. ($NetworkSubnet) Exiting." -Failure
        return $false
    }
    return $true
}

function Test-NetworkSwitch {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Name.")]
        [string]$NetworkName,
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name.")]
        [string]$DomainName
    )

    $notes = $DomainName
    if (-not $notes) {
        if ($NetworkName -eq "cluster") {
            $notes = "Cluster network shared by all domains"
        }
        else {
            $notes = $NetworkName
        }
    }
    $exists = Get-VMSwitch2 -NetworkName $NetworkName
    if (-not $exists) {
        Write-Log "HyperV Network switch for '$NetworkName' not found. Creating a new one."
        try {
            New-VMSwitch -Name $NetworkName -SwitchType Internal -Notes $notes -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "Failed to create HyperV Network switch for $NetworkName. Trying again in 30 seconds"
            start-sleep -seconds 30
            New-VMSwitch -Name $NetworkName -SwitchType Internal -Notes $notes -ErrorAction Continue | Out-Null
        }
        Start-Sleep -Seconds 5 # Sleep to make sure network adapter is present
    }

    $exists = Get-VMSwitch2 -NetworkName $NetworkName
    if (-not $exists) {
        Write-Log "HyperV Network switch could not be created."
        return $false
    }

    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$NetworkName*" }
    }
    catch {
        Write-log "Get-NetAdapter $_" -LogOnly
        if ($_ -Match "the module could not be loaded" ) {
            Write-Log -Failure "Could not invoke Get-NetAdapter due to load failure.  Please close all powershell windows and retry."
        }
    }

    if (-not $adapter) {
        Write-Log "Network adapter for '$NetworkName' switch was not found."
        return $false
    }

    $interfaceAlias = $adapter.InterfaceAlias
    $desiredIp = $NetworkSubnet.Substring(0, $NetworkSubnet.LastIndexOf(".")) + ".200"

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "$interfaceAlias IP is '$($currentIp.IPAddress)'. Changing it to $desiredIp."
        New-NetIPAddress -InterfaceAlias $interfaceAlias -IPAddress $desiredIp -PrefixLength 24 | Out-Null
        Start-Sleep -Seconds 5 # Sleep to make sure IP changed
    }

    $currentIp = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue
    if ($currentIp.IPAddress -ne $desiredIp) {
        Write-Log "Unable to set IP for '$interfaceAlias' network adapter to $desiredIp."
        return $false
    }

    $valid = Test-NetworkNat -NetworkSubnet $NetworkSubnet
    return $valid
}

function Test-NoRRAS {

    $router = (get-itemproperty -Path HKLM:\system\CurrentControlSet\services\Tcpip\Parameters).IpEnableRouter
    if ((Get-WindowsFeature Routing).Installed -or $router -eq 0) {
        Set-ItemProperty -Path HKLM:\system\CurrentControlSet\services\Tcpip\Parameters -Name IpEnableRouter -Value 1
        Uninstall-WindowsFeature 'Routing', 'DirectAccess-VPN' -Confirm:$false -IncludeManagementTools
        try {
            Remove-VMSwitch2 -NetworkName "External"
        }
        catch {}
        $response = Read-YesorNoWithTimeout -Prompt "Reboot needed after RRAS removal and IpEnableRouter TCP Value. Reboot now? (Y/n)" -HideHelp -Default "y" -timeout 300
        if ($response -eq "n") {
            Write-log "Please Reboot."
            Exit
        }
        Write-Log "Rebooting computer. Please re-run vmbuild.cmd when it comes up."
        Restart-Computer -Force
        Exit
    }
    else {
        # RRAS not found, test NAT
        $natValid = Test-Networks
        if (-not $natValid) {
            exit
        }
    }
}

function Test-Networks {

    $invalidNetworks = @()
    $networkList = Get-List -Type UniqueNetwork
    foreach ($network in $networkList) {
        $valid = Test-NetworkNat -NetworkSubnet $network
        if (-not $valid) {
            $invalidNetworks += $network
        }
    }

    $internetSubnet = "172.31.250.0"
    $valid = Test-NetworkNat -NetworkSubnet $internetSubnet
    if (-not $valid) {
        $invalidNetworks += $internetSubnet
    }

    $clusterNetwork = "10.250.250.0"
    $valid = Test-NetworkNat -NetworkSubnet $clusterNetwork
    if (-not $valid) {
        $invalidNetworks += $clusterNetwork
    }

    if ($invalidNetworks.Count -gt 0) {
        Write-Log "Failed to verify whether following networks exist in NAT: $($invalidNetworks -join ', ')" -Failure
        return $false
    }

    return $true

}

function Test-NetworkNat {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet

    )

    $exists = Get-NetNat -Name $NetworkSubnet -ErrorAction SilentlyContinue
    if ($exists) {
        Write-Log "'$NetworkSubnet' is already present in NAT." -Verbose
        return $true
    }

    try {
        Write-Log "'$NetworkSubnet' not found in NAT. Adding it."
        New-NetNat -Name $NetworkSubnet -InternalIPInterfaceAddressPrefix "$($NetworkSubnet)/24" -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "New-NetNat -Name $NetworkSubnet -InternalIPInterfaceAddressPrefix `"$($NetworkSubnet)/24`" failed with error: $_" -Failure
        return $false
    }

}


function Start-DHCP {
    # Install DHCP, if not found
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Restart
    )

    $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $dhcp) {
        Write-Log "DHCP is not installed. Installing..."
        $installed = Install-WindowsFeature 'DHCP' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools -ErrorAction SilentlyContinue

        if (-not $installed.Success) {
            Write-Log "DHCP Installation failed $($installed.ExitCode). Install DHCP windows feature manually, and try again." -Failure
            return $false
        }
    }

    if ($dhcp.Status -ne 'Running') {
        start-service "DHCPServer"
        start-sleep -seconds 5
    }
    else {
        if ($Restart) {
            restart-service "DHCPServer"
            start-sleep -seconds 5
        }
    }
    $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($dhcp.Status -ne 'Running') {
        Start-Sleep -Seconds 10
        start-service "DHCPServer"
        start-sleep -seconds 30
        $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if ($dhcp.Status -ne 'Running') {
            return $false
        }
    }
    return $true
}

function Test-DHCPScope {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope ID.")]
        [string]$ScopeID,
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope Name.")]
        [string]$ScopeName,
        [Parameter(Mandatory = $false, HelpMessage = "DHCP Domain Name option.")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Override DNS Server")]
        [string]$DNSServer
    )
    try {

        write-log -logonly "Test-DHCPScope called with ScopeID: $ScopeID ScopeName: $ScopeName DomainName: $DomainName DNSSERVER: $DNSServer"
        # Define Lease Time
        $leaseTimespan = New-TimeSpan -Days 16
        $DomainScope = $true
        if (-not $DomainName) {
            $leaseTimespan = New-TimeSpan -Days 365
            $DomainScope = $false
        }

        # Install DHCP, if not found


        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "DHCP Could not be started" -Failure
            return $false
        }

        # Define scope options
        $DHCPDNSAddress = $null
        $network = $ScopeID.Substring(0, $ScopeID.LastIndexOf("."))
        if ($ScopeName -notin ("cluster", "Internet")) {
            if ($DNSServer) {
                $DHCPDNSAddress = $DNSServer
            }
            else {
                $DC = get-list -type VM -domain $DomainName | Where-Object { $_.Role -eq "DC" }
                if ($DC) {
                    $DHCPDNSAddress = ($DC.Network.Substring(0, $DC.Network.LastIndexOf(".")) + ".1")
                }
                else {
                    $DHCPDNSAddress = $network + ".1"
                }
            }
        }


        # Check if scope exists
        $createScope = $true
        $scope = Get-DhcpServerv4Scope -ScopeId $scopeID -ErrorAction SilentlyContinue
        if ($scope) {
            if ($DHCPDNSAddress) {
                $scopeOptions = get-DhcpServerv4OptionValue -scopeID $scopeID -ErrorAction SilentlyContinue
                $currentDNS = ($scopeOptions | Where-Object OptionID -eq 6).Value
                if ($currentDNS -ne $DHCPDNSAddress) {
                    Write-Log "'$ScopeID ($ScopeName)' scope does not match preferred DNS server"
                    $createScope = $true
                }
                else {
                    Write-Log "'$ScopeID ($ScopeName)' scope is already present in DHCP."
                    $createScope = $false
                }
            }
            else {
                Write-Log "'$ScopeID ($ScopeName)' scope is already present in DHCP."
                $createScope = $false
            }
        }
        else {
            Write-Log "'$ScopeID ($ScopeName)' scope is not present in DHCP. Creating new scope"
            $createScope = $true
        }

        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "DHCP Could not be started" -Failure
            return $false
        }

        if ($scope -and $createScope) {
            Remove-DhcpServerv4Scope -scopeID $scopeID -force
        }

        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "DHCP Could not be started" -Failure
            return $false
        }

        $DHCPDefaultGateway = $network + ".200"
        $DHCPScopeStart = $network + ".20"
        $DHCPScopeEnd = $network + ".199"

        $scope = $null
        # Create scope, if needed
        $maxRetries = 3
        $retry = 0
        if ($createScope) {

            Write-Log "Creating '$ScopeID ($ScopeName)' scope with DHCPDefaultGateway: $DHCPDefaultGateway DHCPScopeStart: $DHCPScopeStart DHCPScopeEnd: $DHCPScopeEnd DNSServer: $DHCPDNSAddress "
            while (-not $scope) {
                try {
                    if ($retry -gt 0) {
                        if ($retry -ge $maxRetries) {
                            Write-Log "Max Retries Exceeded. Failed to add '$ScopeID ($ScopeName)' to DHCP." -Failure
                            return $false
                        }
                        $dhcp = Start-DHCP
                        if (-not $dhcp) {
                            Write-Log "DHCP Could not be started" -Failure
                            return $false
                        }
                    }
                    $retry++
                    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $DHCPScopeStart -EndRange $DHCPScopeEnd -SubnetMask 255.255.255.0 -LeaseDuration $leaseTimespan -ErrorAction Stop
                    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorVariable ScopeErr -ErrorAction Stop
                    if ($scope) {
                        Write-Log "'$ScopeID ($ScopeName)' scope added to DHCP."
                    }
                    else {
                        Write-Log "Failed to add '$ScopeID ($ScopeName)' to DHCP. $ScopeErr" -Failure
                    }
                }
                catch {
                    Write-Log "Failed to add '$ScopeID ($ScopeName)' to DHCP." -Failure
                }
            }


            try {
                if (-not $DomainScope) {
                    if ($ScopeName -eq "cluster") {
                        $HashArguments = @{
                            ScopeId = $ScopeID
                            Router  = $DHCPDefaultGateway
                        }
                    }
                    else {
                        $HashArguments = @{
                            ScopeId   = $ScopeID
                            Router    = $DHCPDefaultGateway
                            DnsServer = @("4.4.4.4", "8.8.8.8")
                        }
                    }
                }
                else {
                    $HashArguments = @{
                        ScopeId    = $ScopeID
                        Router     = $DHCPDefaultGateway
                        DnsDomain  = $DomainName
                        WinsServer = $DHCPDNSAddress
                        DnsServer  = $DHCPDNSAddress
                    }
                }

                Set-DhcpServerv4OptionValue @HashArguments -Force -ErrorAction Stop
                Write-Log "Added/updated scope options for '$ScopeID ($ScopeName)' scope in DHCP." -Success
                return $true
            }
            catch {
                Write-Log "Failed to add/update scope options for '$ScopeID ($ScopeName)' scope in DHCP. $_" -Failure
                Write-Log "$($_.ScriptStackTrace)" -LogOnly
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Log $_
        Write-Exception -ExceptionInfo $_
        return $false
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
        [bool]$InProgress,
        [Parameter(Mandatory = $false)]
        [switch]$UpdateVersion,
        [Parameter(Mandatory = $false)]
        [bool]$Force = $false
    )

    try {
        $ProgressPreference = 'SilentlyContinue'

        $ThisVM = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName }

        $network = $DeployConfig.vmOptions.network
        if ($ThisVm.network) {
            $network = $ThisVm.network
        }

        $vmNote = [PSCustomObject]@{
            inProgress           = $InProgress
            success              = $Successful
            role                 = $ThisVM.role
            deployedOS           = $ThisVM.operatingSystem
            domain               = $DeployConfig.vmOptions.domainName
            adminName            = $DeployConfig.vmOptions.adminName
            network              = $network
            prefix               = $DeployConfig.vmOptions.prefix
            memLabsDeployVersion = $Common.MemLabsVersion
        }

        if ($UpdateVersion.IsPresent) {
            $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $Common.MemLabsVersion -Force
        }

        foreach ($prop in $ThisVM.PSObject.Properties) {
            if ($prop.Name -eq "thisParams" -or $prop.Name -eq "SQLAO") {
                continue
            }
            $vmNote | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
        }

        Set-VMNote -vmName $vmName -vmNote $vmNote -force:$Force

    }
    catch {
        Write-Log "Failed to add a note to the VM '$VmName' in Hyper-V. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
    }
    finally {
        $ProgressPreference = 'Continue'
    }
}

function Get-VMNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    $vm = Get-VM2 -Name $VMName

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_"
        return $null
    }

    $vmNoteObject = $null
    try {
        if ($vm.Notes -like "*lastUpdate*") {
            try {
                $vmNoteObject = $vm.Notes | ConvertFrom-Json
            }
            catch {
                return $null
            }

            if (-not $vmNoteObject.adminName) {
                # we renamed this property, read as "adminName" if it exists
                $vmNoteObject | Add-Member -MemberType NoteProperty -Name "adminName" -Value $vmNoteObject.domainAdmin  -Force
            }

            return $vmNoteObject
        }
        else {
            Write-Log "$VMName`: VM Properties do not contain values. Assume this was not deployed by vmbuild. $_" -Verbose -LogOnly -Warning
            return $null
        }
    }
    catch {
        Write-Log "Failed to get VM Properties for '$($vm.Name)'. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Set-VMNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $true, ParameterSetName = "VMVersion")]
        [string]$vmName,
        [Parameter(Mandatory = $true, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $false, ParameterSetName = "VMVersion")]
        [object]$vmNote,
        [Parameter(Mandatory = $false, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $true, ParameterSetName = "VMVersion")]
        [string]$vmVersion,
        [Parameter(Mandatory = $false)]
        [switch]$forceVersionUpdate,
        [Parameter(Mandatory = $false)]
        [bool]$force
    )

    if (-not $vmNote) {
        $vmNote = Get-VMNote -VMName $vmName
    }
    if ($force -eq $false) {
        #If we are not forcing an overwrite, use the new note to update the contents of the old note.
        #Old Note may have more properties than the new note, and we dont want to lose those.
        $oldvmNote = Get-VMNote -VMName $vmName
        if ($oldvmNote) {
            foreach ($note in $vmNote.PSObject.Properties) {
                $oldvmNote | Add-Member -MemberType NoteProperty -Name $note.Name -Value $note.Value -Force
            }
            $vmNote = $oldvmNote
        }
    }

    $vmVersionUpdated = $false
    if ($vmVersion -and ($vmNote.memLabsVersion -lt $vmVersion -or $forceVersionUpdate.IsPresent)) {
        $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $vmVersion -Force
        $vmVersionUpdated = $true
    }

    $vmNote | Add-Member -MemberType NoteProperty -Name "lastUpdate" -Value (Get-Date -format "MM/dd/yyyy HH:mm") -Force
    $vmNoteJson = ($vmNote | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
    $vm = Get-VM2 $VmName
    if ($vm) {
        if ($vmVersionUpdated) {
            Write-Log "Setting VM Note for $vmName (version $vmVersion)" -Verbose
        }
        else {
            Write-Log "Setting VM Note for $vmName to $vmNoteJson" -Verbose -LogOnly
        }
        $vm | Set-VM -Notes $vmNoteJson -ErrorAction Stop
    }
    else {
        Write-Log "Failed to get VM from Hyper-V. Cannot set VM Note for $vmName" -Verbose
    }
}

function Update-VMNoteVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$vmName,
        [Parameter(Mandatory = $false)]
        [string]$vmVersion
    )

    $vmNote = Get-VMNote -VMName $VmName
    $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $vmVersion -Force
    Set-VMNote -vmName $VmName -vmNote $vmNote
}

function Update-VMNoteProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter(Mandatory = $true)]
        [string]$PropertyValue
    )

    $vmNote = Get-VMNote -VMName $VmName
    $vmNote | Add-Member -MemberType NoteProperty -Name $PropertyName -Value $PropertyValue -Force
    Set-VMNote -vmName $VmName -vmNote $vmNote
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
        Write-Log "DNS resource record for $RecordToDelete was not found." -LogOnly
    }
    else {
        $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock2 -SuppressLog
        if ($result.ScriptBlockFailed) {
            Write-OrangePoint "Failed to remove DNS resource record for $RecordToDelete. Please remove the record manually."
        }
        else {
            Write-GreenCheck "Removed DNS resource record for $RecordToDelete"
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
        Write-Log "Failed to get description for '$ScopeId' scope in DHCP. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
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
        [string]$DiskControllerType = "SCSI",
        [Parameter(Mandatory = $false)]
        [string]$SwitchName2,
        [Parameter(Mandatory = $false)]
        [object]$AdditionalDisks,
        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,
        [Parameter(Mandatory = $false)]
        [PsCustomObject] $DeployConfig,
        [Parameter(Mandatory = $false)]
        [switch]$OSDClient,
        [Parameter(Mandatory = $false)]
        [switch]$tpmEnabled,
        [Parameter(Mandatory = $false)]
        [switch]$Migrate,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'
    $Activity = "Creating Virtual Machine"
    try {
        # WhatIf
        if ($WhatIf) {
            Write-Log "WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, AdditionalDisks: $AdditionalDisks, SwitchName: $SwitchName, ForceNew: $ForceNew"
            return $true
        }


        Write-Log "$VmName`: $Activity"
        Write-Progress2 $Activity -Status "Starting" -percentcomplete 0 -force
        # Test if source file exists
        if (-not (Test-Path $SourceDiskPath) -and (-not $OSDClient.IsPresent)) {
            Write-Log "$VmName`: $SourceDiskPath not found. Cannot create new VM." -failure -OutputStream
            return $false
        }

        # VM Exists
        $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($vmTest -and $ForceNew.IsPresent) {
            Write-Log "$VmName`: Virtual machine already exists. ForceNew switch is present."
            if ($vmTest.State -ne "Off") {
                Write-Log "$VmName`: Turning the VM off forcefully..."
                $vmTest | Stop-VM -TurnOff -Force -WarningAction SilentlyContinue
            }
            $vmTest | Remove-VM -Force
            Write-Log "$VmName`: Purging $($vmTest.Path) folder..."
            Remove-Item -Path $($vmTest.Path) -Force -Recurse | out-null
            Write-Log "$VmName`: Purge complete."
            Get-List -FlushCache | Out-Null # flush cache
        }

        if ($vmTest -and -not $ForceNew.IsPresent) {
            Write-Log "$VmName`: Virtual machine already exists. ForceNew switch is NOT present. Exit."
            return $false
        }

        if (-not $Migrate) {
            # Make sure Existing VM Path is gone!
            $VmSubPath = Join-Path $VmPath $VmName
            if (Test-Path -Path $VmSubPath) {
                Write-Log "$VmName`: Found existing directory for $VmName. Purging $VmSubPath folder..."
                Remove-Item -Path $VmSubPath -Force -Recurse | out-null
                Write-Log "$VmName`: Purge complete."
            }

            # Retry if its not gone.
            if (Test-Path -Path $VmSubPath) {
                Start-Sleep -Seconds 30
                Write-Log "$VmName`: (Retry) Found existing directory for $VmName. Purging $VmSubPath folder..."
                Remove-Item -Path $VmSubPath -Force -Recurse | out-null
                Write-Log "$VmName`: Purge complete."
            }

            #Fail if its not gone.
            if (Test-Path -Path $VmSubPath) {
                Write-Log "$VmName`: Could not delete $VmSubPath folder... Exit."
                return $false
            }
        }

       

        Write-Progress2 $Activity -Status "Creating VM in Hyper-V" -percentcomplete 5 -force
        # Create new VM
        try {
            $vm = New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop 
        }
        catch {
            Write-Log "$VmName`: Failed to create new VM. $_ with command 'New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop'"
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
            return $false
        }

        Write-Progress2 $Activity -Status "Hyper-V VM Object created. Waiting for Disk Creation" -percentcomplete 30 -force
        # Add VMNote as soon as VM is created
        if ($DeployConfig) {
            New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
        }

        # Copy sysprepped image to VM location
        $osDiskName = "$($VmName)_OS.vhdx"
        $osDiskPath = Join-Path $vm.Path $osDiskName
         
        if (-not $Migrate) {
            if (-not $OSDClient.IsPresent) {
                $worked = Get-File -Source $SourceDiskPath -Destination $osDiskPath -DisplayName "Making a copy of base image in $osDiskPath" -Action "Copying"
                if (-not $worked) {
                    Write-Log "$VmName`: Failed to copy $SourceDiskPath to $osDiskPath. Exiting."
                    return $false
                }
            }
            else {
                Write-Progress2 $Activity -Status "Creating new 127GB C: Drive" -percentcomplete 32 -force
                $worked = New-VHD -Path $osDiskPath -SizeBytes 127GB
                if (-not $worked) {
                    Write-Log "$VmName`: Failed to create new VMD $osDiskPath for OSDClient. Exiting."
                    return $false
                }
            }
        }
         
        if (-not (Test-Path $osDiskPath)) {
            Write-Log "Could not find file $osDiskPath" -Failure
            return
        }


        Write-Log "$VmName`: Enabling Hyper-V Guest Services"
        Write-Progress2 $Activity -Status "Enabling Hyper-V Guest Services" -percentcomplete 35 -force
        Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue | out-null

        if ($Generation -eq "2" -and $tpmEnabled) {
            $mutexName = "TPM"
            $mtx = New-Object System.Threading.Mutex($false, $mutexName)
            Write-Progress2 $Activity -Status "Waiting to enable TPM" -percentcomplete 40 -force
            write-log "Attempting to acquire '$mutexName' Mutex" -LogOnly
            [void]$mtx.WaitOne()
            write-log "acquired '$mutexName' Mutex" -LogOnly
            try {
                Write-Progress2 $Activity -Status "Enabling TPM" -percentcomplete 50 -force
                if ($null -eq (Get-HgsGuardian -Name MemLabsGuardian -ErrorAction SilentlyContinue)) {
                    New-HgsGuardian -Name "MemLabsGuardian" -GenerateCertificates | out-null
                    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                }

                $localCASupported = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported"
                if ($localCASupported -eq 1) {
                    Write-Log "$VmName`: Enabling TPM"
                    $HGOwner = Get-HgsGuardian MemLabsGuardian
                    $KeyProtector = New-HgsKeyProtector -Owner $HGOwner -AllowUntrustedRoot
                    if (-not $KeyProtector -or -not ($KeyProtector.RawData)) {
                        Write-Log "$VmName`: New-HgsKeyProtector failed"
                        return $false
                    }
                    Set-VMKeyProtector -VMName $VmName -KeyProtector $KeyProtector.RawData | out-null
                    Enable-VMTPM $VmName -ErrorAction Stop | out-null ## Only required for Win11
                }
                else {
                    Write-Log "$VmName`: Skipped enabling TPM since HKLM:\SOFTWARE\Microsoft\HgsClient\LocalCACertSupported is not set."
                }
            }
            catch {
                Write-Log "$VmName`: TPM failed $_"
                return $false
            }
            finally {
                [void]$mtx.ReleaseMutex()
                [void]$mtx.Dispose()
            }
        }

        Write-Progress2 $Activity -Status "Setting VM to shutdown on stop" -percentcomplete 60 -force
        Write-Log "$VmName`: Setting VM to shutdown on stop"
        Set-VM -Name $vmName -AutomaticStopAction ShutDown | out-null

        Write-Progress2 $Activity -Status "Setting Processors" -percentcomplete 62 -force
        Write-Log "$VmName`: Setting Processor count to $Processors"
        Set-VM -Name $vmName -ProcessorCount $Processors | out-null

        Write-Progress2 $Activity -Status "Adding OS Disk to VM" -percentcomplete 65 -force
        Write-Log "$VmName`: Adding virtual disk $osDiskPath"
        Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType $DiskControllerType -ControllerNumber 0 | out-null

        Write-Progress2 $Activity -Status "Adding DVD disk to VM" -percentcomplete 70 -force
        Write-Log "$VmName`: Adding a DVD drive"
        Add-VMDvdDrive -VMName $VmName | out-null

        Write-Progress2 $Activity -Status "Changing Boot Order" -percentcomplete 75 -force
        Write-Log "$VmName`: Changing boot order"
        $f = Get-VM2 -Name $VmName | Get-VMFirmware
        $f_file = $f.BootOrder | Where-Object { $_.BootType -eq "File" }
        $f_net = $f.BootOrder | Where-Object { $_.BootType -eq "Network" }
        $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
        $f_dvd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }

        # Add additional disks
        if ($AdditionalDisks) {
            $count = 0
            $label = "DATA"
            Write-Progress2 $Activity -Status "Adding Additional Disks" -percentcomplete 80 -force
            foreach ($disk in $AdditionalDisks.psobject.properties) {
                $newDiskName = "$VmName`_$label`_$count.vhdx"
                $newDiskPath = Join-Path $vm.Path $newDiskName
                Write-Log "$VmName`: Adding $newDiskPath"
                if (-not $Migrate) {
                    New-VHD -Path $newDiskPath -SizeBytes ($disk.Value / 1) -Dynamic | out-null
                }
                if (-not (Test-Path $newDiskPath)) {
                    Write-Log "Failed to find $newDiskPath" -Failure
                    return
                }
                Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath | out-null
                $count++
            }
        }

        Write-Progress2 $Activity -Status "Setting Firmware" -percentcomplete 85 -force
        # 'File' firmware is not present on new VM, seems like it's created after Windows setup.
        if ($null -ne $f_file) {
            if (-not $OSDClient.IsPresent) {
                Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_hd, $f_net | out-null
            }
            else {
                Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_net, $f_hd | out-null
            }
        }
        else {
            if (-not $OSDClient.IsPresent) {
                Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_hd, $f_net | out-null
            }
            else {
                Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_net, $f_hd | out-null
            }
        }

        Write-Progress2 $Activity -Status "Starting VM" -percentcomplete 86 -force
        Write-Log "$VmName`: Starting virtual machine"
        $started = Start-VM2 -Name $VmName -Passthru
        if (-not $started) {
            Write-Log "$VmName`: VM Not Started."
            return $false
        }

        if ($SwitchName2) {
            Write-Progress2 $Activity -Status "SQLAO: Waiting to add 2nd NIC" -percentcomplete 90 -force
            $mtx = New-Object System.Threading.Mutex($false, "GetIP")
            write-log "Attempting to acquire 'GetIP' Mutex" -LogOnly
            [void]$mtx.WaitOne()
            write-log "acquired 'GetIP' Mutex" -LogOnly
            try {
                Write-Progress2 $Activity -Status "SQLAO: Adding 2nd NIC" -percentcomplete 95 -force
                write-log "$VmName`: Adding 2nd NIC attached to $SwitchName2" -LogOnly
                $Global:ProgressPreference = 'SilentlyContinue'
                $vmnet = Add-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName2 -Passthru
                write-log "$VmName`: NIC added MAC: $($vmnet.MacAddress)" -LogOnly

                if (-not $($vmnet.MacAddress)) {
                    start-sleep -Seconds 60
                    if (-not $($vmnet.MacAddress)) {
                        #Investigate deleting and re-adding
                        write-log "$VmName`: 2nd NIC does not have a MAC address: $($vmnet)" -Failure
                        return $false
                    }
                }

                $dc = Get-List2 -DeployConfig $DeployConfig -SmartUpdate | Where-Object { $_.Role -eq "DC" }
                if (-not ($dc.network)) {
                    $dns = $DeployConfig.vmOptions.network.Substring(0, $DeployConfig.vmOptions.network.LastIndexOf(".")) + ".1"
                }
                else {
                    $dns = $dc.network.Substring(0, $dc.network.LastIndexOf(".")) + ".1"
                }


                if (-not $dns) {
                    write-Log -Failure "$VmName`:Could not determine DNS for cluster network"
                    return $false
                }

                $ip = $null
                $ipa = $null
                try {
                    $ip = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -ErrorAction Stop
                    if (! $ip) {
                        $ip = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -ErrorAction Stop
                    }
                    if (! $ip) {
                        Write-Log "$VmName`: Could not acquire a free cluster DHCP Address"
                        return $false
                    }
                    else {     
                        Write-Log -Verbose  ($VmName+ ' 1Calling $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                        $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue          
                        Write-Log -Verbose  ($VmName+' 1Calling Complete')
                    }

                    Write-Log "$VmName`: Adding a second nic connected to switch $SwitchName2 with ip $ip and DNS $dns Mac:$($vmnet.MacAddress)"
                    Write-Log -Verbose ($VmName+'  2Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                    Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
                    Write-Log -Verbose  ($VmName+'  2Calling Complete')
                    Write-Log -Verbose ($VmName+'  3Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                    Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
                    Write-Log -Verbose  ($VmName+'  3Calling Complete')


                    Add-DhcpServerv4Reservation -ScopeId "10.250.250.0" -IPAddress $ip -ClientId $vmnet.MacAddress -Description "Reservation for $VMName" -ErrorAction Stop | out-null
                    Set-DhcpServerv4OptionValue -optionID 6 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                    Set-DhcpServerv4OptionValue -optionID 44 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                    Set-DhcpServerv4OptionValue -optionID 15 -value $DeployConfig.vmOptions.DomainName -ReservedIP $ip -Force -ErrorAction Stop | out-null
                }
                catch {
                    #retry
                    Start-DHCP -Restart
                    $ip = $null
                    try {
                        $ip = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -ErrorAction Stop
                        if (! $ip) {
                            $ip = Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -ErrorAction Stop
                        }
                        if (! $ip) {
                            Write-Log "$VmName`: Could not acquire a free cluster DHCP Address"
                            return $false
                        }
                        else {
                            Write-Log -Verbose ($VmName+'6Calling $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                            $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $ip } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue   
                            Write-Log -Verbose  ($VmName+'  6Calling Complete')
                        }
                        Write-Log "$VmName`: Adding a second nic connected to switch $SwitchName2 with ip $ip and DNS $dns Mac:$($vmnet.MacAddress)"
                        Write-Log -Verbose ($VmName+'7Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                        Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.ClientId -replace "-", "" -eq $($vmnet.MacAddress) } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
                        Write-Log -Verbose  ($VmName+'  7Calling Complete')
                        Write-Log -Verbose ($VmName+'8Calling Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                        Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.Name -like $($currentItem.vmName) + ".*" } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
                        Write-Log -Verbose  ($VmName+'  8Calling Complete')

                        Add-DhcpServerv4Reservation -ScopeId "10.250.250.0" -IPAddress $ip -ClientId $vmnet.MacAddress -Description "Reservation for $VMName" -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 6 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 44 -value $dns -ReservedIP $ip -Force -ErrorAction Stop | out-null
                        Set-DhcpServerv4OptionValue -optionID 15 -value $DeployConfig.vmOptions.DomainName -ReservedIP $ip -Force -ErrorAction Stop | out-null
                    }
                    catch {
                        write-log -failure "$VmName`:Failed to reserve IP address $ip for DNS: $dns and Mac:$($vmnet.MacAddress)"
                        Write-Log "$_ $($_.ScriptStackTrace)" -LogOnly
                        return $false
                    }
                }

                $currentItem = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName }
                #$currentItem | Add-Member -MemberType NoteProperty -Name "ClusterNetworkIP" -Value $ip -Force
                #$currentItem | Add-Member -MemberType NoteProperty -Name "DNSServer" -Value $dns -Force
                if ($currentItem.OtherNode) {
                    $IPs = (Get-DhcpServerv4FreeIPAddress -ScopeId "10.250.250.0" -NumAddress 75 -WarningAction SilentlyContinue) | Select-Object -Last 2
                    Write-Log "$VmName`: SQLAO: Setting New ClusterIPAddress and AG IPAddress" -LogOnly
                    $clusterIP = $IPs[0]
                    $AGIP = $IPs[1]


                    if ($clusterIP) { 
                        Write-Log -Verbose ($VmName +' 4Calling  $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $clusterIP } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                        $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $clusterIP } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue           
                        Write-Log -Verbose ($VmName +' 4Calling Complete')
                    }
                    if ($AGIP) {
                        Write-Log -Verbose ($VmName+' 5Calling $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $AGIP } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue')
                        $ipa = Get-DhcpServerv4Reservation -ScopeId "10.250.250.0" | Where-Object { $_.IpAddress -eq $AGIP } | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue    
                        Write-Log -Verbose ($VmName +' 5Calling Complete')
                    }
                    write-log "$VmName`: ClusterIP: $clusterIP  AGIP: $AGIP"

                    if (-not $clusterIP -or -not $AGIP) {
                        write-log -failure "$VmName`:Failed to acquire Cluster or AGIP for SQLAO"
                        return $false
                    }

                    $currentItem | Add-Member -MemberType NoteProperty -Name "ClusterIPAddress" -Value $clusterIP -Force
                    $currentItem | Add-Member -MemberType NoteProperty -Name "AGIPAddress" -Value $AGIP -Force

                    Add-DhcpServerv4ExclusionRange -ScopeId "10.250.250.0" -StartRange $clusterIP -EndRange $clusterIP -ErrorAction SilentlyContinue | out-null
                    Add-DhcpServerv4ExclusionRange -ScopeId "10.250.250.0" -StartRange $AGIP -EndRange $AGIP -ErrorAction SilentlyContinue | out-null
                }
            }
            catch {
                Write-Progress2 $Activity -Status "SQLAO: $_" -percentcomplete 99 -force
                Start-Sleep -seconds 5
                Write-Exception $_
                Write-Log "$vmName`: Failed adding 2nd NIC $_"
                return $false
            }
            finally {
                [void]$mtx.ReleaseMutex()
                [void]$mtx.Dispose()
            }

            New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
            Write-Progress2 $Activity -Status "SQLAO: 2nd NIC Added" -percentcomplete 100 -force
        }

        Write-Progress2 $Activity -Status "VM Created in Hyper-V successfully" -percentcomplete 100 -force -Completed
        return $true
    }
    catch {
        Write-Exception $_
        Write-Progress2 $Activity -Status $_ -percentcomplete 100 -force -Completed
        Start-Sleep -Seconds 3
        Write-Log "Create VM failed with $_"
        return $false
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}

function Get-AvailableMemoryGB {
    $availableMemory = Get-CimInstance win32_operatingsystem | Select-Object -Expand FreePhysicalMemory
    $availableMemory = ($availableMemory - ("8GB" / 1kB)) * 1KB / 1GB
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
        [int]$TimeoutMinutes = 30,
        [Parameter(Mandatory = $false)]
        [int]$WaitSeconds = 10,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false)]
        [switch]$Quiet,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "WhatIf: Will wait for $VmName for $TimeoutMinutes minutes to become ready" -Warning
        return $true
    }

    $ready = $false

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeSpan = New-TimeSpan -Minutes $TimeoutMinutes
    $stopWatch.Start()
    $vmTest = Get-VM2 -Name $VmName
    if ($VmState) {
        Write-Log "$VmName`: Waiting for VM to go in $VmState state..."
        do {
            try {
                $vmTest = Get-VM2 -Name $VmName
                if (-not $vmTest) {
                    Write-Progress2 -Activity  "Could not find VM" -Status "Could not find VM" -PercentComplete 100 -Completed
                    Write-Log -Failure "Could not find VM $VMName"
                    return
                }

                try {
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "Waiting for VM to go in '$VmState' state. Current State: $($vmTest.State)"
                }
                catch {

                }
                $ready = $vmTest.State -eq $VmState
                Start-Sleep -Seconds 5
            }
            catch {
                $ready = $false
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
        if (-not $ready -and ($vmState -eq "Off")) {
            stop-vm2 -name $VMName -Force
        }
    }

    if ($OobeComplete.IsPresent) {
        $originalStatus = "Waiting for OOBE to complete for $vmName "
        Write-Log "$VmName`: $originalStatus"
        try {
            Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus
        }
        catch {}
        $readyOobe = $false
        $wwahostrunning = $false
        $readySmb = $false

        [int]$failures = 0
        [int]$maxFailures = ([int]$TimeoutMinutes * 4)
        # SuppressLog for all Invoke-VmCommand calls here since we're in a loop.
        do {
            # Check OOBE complete registry key

            try {
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "Testing HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State\ImageState = IMAGE_STATE_COMPLETE"
            }
            catch {}

            $stopwatch2 = [System.Diagnostics.Stopwatch]::new()
            $stopwatch2.Start()
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState }
            $stopwatch2.Stop()
            Write-Log "$VmName`: $out" -Verbose
            if ($null -eq $out.ScriptBlockOutput -and -not $readyOobe) {
                try {
                    if ($failures -gt ([int]$TimeoutMinutes * 2)) {
                        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus -failcount $failures -failcountMax $maxFailures
                    }
                    else {
                        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus
                    }
                }
                catch {

                }
                Start-Sleep -Seconds 5
                if ($stopwatch2.elapsed.TotalSeconds -gt 15) {
                    [int]$failures = $failures + ([math]::Round($stopwatch2.elapsed.TotalSeconds / 15, 0))
                }
                else {
                    [int]$failures++
                }
                if ($failures -ge $maxFailures) {
                    stop-vm2 -force -name $VmName -TurnOff
                    start-sleep -seconds 8
                    Start-vm2 -name $VmName
                    Start-Sleep -Seconds 8
                    [int]$failures = 0
                }
            }
            else {
                [int]$failures = 0
                $text = $($originalStatus + ": " + $out.ScriptBlockOutput)
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $text
            }

            # Wait until OOBE is ready
            if ($null -ne $out.ScriptBlockOutput -and -not $readyOobe) {
                Write-Log "$VmName`: OOBE State is $($out.ScriptBlockOutput)"
                $status = $originalStatus
                $status += "Current State: $($out.ScriptBlockOutput)"
                $readyOobe = "IMAGE_STATE_COMPLETE" -eq $out.ScriptBlockOutput
                try {
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $status
                }
                catch {

                }
                Start-Sleep -Seconds 5
            }

            # Wait until \\localhost\c$ is accessible
            if (-not $readySmb -and $readyOobe) {

                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "OOBE complete. Checking SMB access"
                Start-Sleep -Seconds 3
                $out = Invoke-VmCommand -VmName $VmName -AsJob -VmDomainName $VmDomainName -SuppressLog -ScriptBlock { Test-Path -Path "\\localhost\c$" -ErrorAction SilentlyContinue }
                if ($null -ne $out.ScriptBlockOutput -and -not $readySmb) { Write-Log "$VmName`: OOBE complete. \\localhost\c$ access result is $($out.ScriptBlockOutput)" }
                $readySmb = $true -eq $out.ScriptBlockOutput
                if ($readySmb) { Start-Sleep -Seconds 10 } # Extra wait to ensure wwahost has had a chance to start
            }

            # Wait until wwahost.exe is not found, or not longer running
            if ($readySmb) {
                $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue }

                if ($wwahost.ScriptBlockOutput) {
                    $wwahostrunning = $true
                    Write-Log "$VmName`: OOBE complete. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running." -Verbose
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text  "OOBE complete, and SMB available. Waiting for WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) to stop before continuing"
                    Start-Sleep -Seconds 15
                }
                else {
                    Write-Log "$VmName`: OOBE complete. WWAHost not running."
                    $wwahostrunning = $false
                }
            }

            # OOBE and SMB ready, buffer wait to ensure we're at login screen. Bad things happen if you reboot the machine before it really finished OOBE.
            if (-not $wwahostrunning -and $readySmb) {
                Write-Log "$VmName`: VM is ready. Waiting $WaitSeconds seconds before continuing."
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is ready. Waiting $WaitSeconds seconds before continuing"
                Start-Sleep -Seconds $WaitSeconds
                $ready = $true
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState } -ShowVMSessionError | Out-Null
        }
    }

    if ($OobeStarted.IsPresent) {
        $status = "Waiting for OOBE to start "
        Write-Log "$VmName`: $status"
        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $status

        do {
            $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue }

            if ($wwahost.ScriptBlockOutput) {
                $ready = $true
                Write-Log "$VmName`: OOBE Started. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running." -Verbose
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "OOBE Started. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running"
            }
            else {
                Write-Log "$VmName`: OOBE hasn't started yet. WWAHost not running."
                $ready = $false
                Start-Sleep -Seconds $WaitSeconds
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue } -ShowVMSessionError | Out-Null
        }
    }

    if ($PathToVerify) {
        if ($PathToVerify -eq "C:\Users") {
            $msg = "Waiting for VM to respond"
        }
        else {
            $msg = "Waiting for $PathToVerify to exist"
        }

        $vmTest = Get-VM2 -Name $VmName
        if ($vmTest.State -ne "Running") {
            start-vm2 -name $vmName
            start-sleep -seconds 30
        }
        if (-not $vmTest) {
            Write-Progress2 -Activity  "Could not find VM" -Status "Could not find VM" -PercentComplete 100 -Completed
            Write-Log -Failure "Could not find VM $VMName"
            return
        }
        if (-not $Quiet.IsPresent) { Write-Log "$VmName`: $msg..." }
        do {
            Start-Sleep -Seconds 5
            try {
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $msg
            }
            catch {}
            $vmTest = Get-VM2 -Name $VmName
            if ($vmTest.State -ne "Running") {
                stop-vm2 -name $vmName
                start-sleep -seconds 30
                start-vm2 -name $vmName
                start-sleep -seconds 30
            }

            # Test if path exists; if present, VM is ready. SuppressLog since we're in a loop.
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -ScriptBlock { Test-Path $using:PathToVerify } -SuppressLog
            $ready = $true -eq $out.ScriptBlockOutput
            if ($ready) {
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is responding"
            }

        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -ScriptBlock { Test-Path $using:PathToVerify } -ShowVMSessionError | Out-Null
        }
    }



    if ($ready) {
        Write-Progress2 -Activity "Waiting for virtual machine" -Status "Wait complete." -Completed
        if (-not $Quiet.IsPresent) { Write-Log "$VmName`: VM is now available." -Success }
    }
    else {
        Write-Progress2 -Activity "Waiting for virtual machine" -Status "Timer expired while waiting for VM" -Completed
        Write-Log "$VmName`: Timer expired while waiting for VM" -Warning
    }

    return $ready
}

function Invoke-VmCommand {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $true, HelpMessage = "Script Block to execute")]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName, # = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "Domain Account to use for creating domain creds")]
        [string]$VmDomainAccount,
        [Parameter(Mandatory = $false, HelpMessage = "Argument List to supply to ScriptBlock")]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $false, HelpMessage = "Display Name of the script for log/console")]
        [string]$DisplayName,
        [Parameter(Mandatory = $false, HelpMessage = "Suppress log entries. Useful when waiting for VM to be ready to run commands.")]
        [switch]$SuppressLog,
        [Parameter(Mandatory = $false, HelpMessage = "Check return value = true to indicate success")]
        [switch]$CommandReturnsBool,
        [Parameter(Mandatory = $false, HelpMessage = "Show VM Session errors, very noisy")]
        [switch]$ShowVMSessionError,
        [Parameter(Mandatory = $false, HelpMessage = "Run command as a job")]
        [switch]$AsJob,
        [Parameter(Mandatory = $false, HelpMessage = "When running as a job.. Timeout length")]
        [int]$TimeoutSeconds = 180,
        [Parameter(Mandatory = $false, HelpMessage = "What If")]
        [switch]$WhatIf
    )
    try {
        # Set display name for logging
        if (-not $DisplayName) {
            $DisplayName = $ScriptBlock
        }

        # WhatIf
        if ($WhatIf.IsPresent) {
            Write-Log "WhatIf: Will run '$DisplayName' inside '$VmName'"
            return $true
        }

        # Fatal failure
        if ($null -eq $Common.LocalAdmin) {
            Write-Log "$VmName`: Skip running '$DisplayName' since Local Admin creds not available" -Failure
            return $false
        }

        # Log entry
        if (-not $SuppressLog) {
            Write-Log "$VmName`: Running '$DisplayName'" -Verbose
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
        $ps = $null
        if ($VmDomainAccount) {
            $ps = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName -VmDomainAccount $VmDomainAccount -ShowVMSessionError:$ShowVMSessionError
        }

        if (-not $ps) {
            $ps = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName -ShowVMSessionError:$ShowVMSessionError
        }

        if (-not $ps -and $VmDomainName -eq "WORKGROUP") {
            $domain2 = (Get-VMNote -VMName $vmName).domain
            $ps = Get-VmSession -VmName $VmName -VmDomainName $domain2 -VmDomainAccount "admin" -ShowVMSessionError:$ShowVMSessionError
        }

        $failed = $null -eq $ps

        # Run script block inside VM
        if (-not $failed) {
            try {
                if ($AsJob) {
                    $job = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue -AsJob
                    $job | Wait-Job -Timeout $TimeoutSeconds
                    if ($job.State -eq "Completed") {
                        $return.ScriptBlockOutput = Receive-Job $job
                        if (-not $SuppressLog) {
                            Write-Log "$VmName`: Job '$DisplayName' Succeeded"
                        }
                        $failed = $false
                    }
                    else {
                        $failed = $true
                        $return.ScriptBlockFailed = $true
                        if ($Err2.Count -ne 0) {
                            $OutErr = "$($Err2[0].ToString().Trim())"
                        }
                        else {
                            $OutErr = "Unknown Error"
                        }
                        if (-not $SuppressLog) {
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Job State: $($job.State) Error: $OutErr." -Failure
                        }
                        if ($job.State -eq "Running") {
                            Write-Log "$VmName`: Job '$DisplayName' timed out. Job State: $($job.State) Error: $OutErr." -Failure
                        }
                        Stop-Job $job | Out-Null
                        Remove-Job $job
                    }
                }
                else {
                    $return.ScriptBlockOutput = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue
                }
            }
            catch {
                $failed = $true
                if (-not $SuppressLog) {
                    Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $_" -Failure
                    Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    Write-Exception -ExceptionInfo $_
                }
            }
            if ($CommandReturnsBool) {
                if ($($return.ScriptBlockOutput) -ne $true) {
                    Write-Log "Output was: $($return.ScriptBlockOutput)" -Warning
                    $failed = $true
                    $return.ScriptBlockFailed = $true
                    if ($Err2.Count -ne 0) {
                        $failed = $true
                        $return.ScriptBlockFailed = $true
                        if (-not $SuppressLog) {
                            if ($Err2.Count -eq 1) {
                                Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $($Err2[0].ToString().Trim())." -Failure
                            }
                            else {
                                $msg = @()
                                foreach ($failMsg in $Err2) { $msg += $failMsg }
                                Write-Log "$VmName`: Failed to run '$DisplayName'. Error: {$($msg -join '; ')}" -Failure
                            }
                        }
                    }
                }
            }
            else {
                if ($Err2.Count -ne 0) {
                    $failed = $true
                    $return.ScriptBlockFailed = $true
                    if (-not $SuppressLog) {
                        if ($Err2.Count -eq 1) {
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $($Err2[0].ToString().Trim())." -Failure
                        }
                        else {
                            $msg = @()
                            foreach ($failMsg in $Err2) { $msg += $failMsg }
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Error: {$($msg -join '; ')}" -Failure
                        }
                    }
                }
            }
        }
        else {
            $return.ScriptBlockFailed = $true
            # Uncomment when debugging, this is called many times while waiting for VM to be ready
            # Write-Log "Invoke-VmCommand: $VmName`: Failed to get VM Session." -Failure -LogOnly
            # return $return
        }

        # Set Command Result state in return object
        if (-not $failed) {
            $return.CommandResult = $true
            if (-not $SuppressLog) {
                Write-Log "$VmName`: Successfully ran '$DisplayName'" -LogOnly -Verbose
            }
        }
    }
    catch {
        Write-Log "$VmName`: Invoke-VMCommand Exception $_"
    }
    return $return

}

$global:ps_cache = @{}
function Get-VmSession {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "Domain Account to use for creating domain creds")]
        [string]$VmDomainAccount,
        [Parameter(Mandatory = $false, HelpMessage = "Show VM Session errors, very noisy")]
        [switch]$ShowVMSessionError
    )


    $VmName = $VmName.Split(".")[0]

    $ps = $null

    # Cache key
    $cacheKey = $VmName + "-" + $VmDomainName

    # Set domain name to VmName when workgroup
    if ($VmDomainName -eq "WORKGROUP") {
        $vmDomainName = $VmName
    }

    # Get PS Session
    if ($VmDomainAccount) {
        $username = "$VmDomainName\$VmDomainAccount"
        $cacheKey = $cacheKey + "-" + $VmDomainAccount
    }
    else {
        $username = "$VmDomainName\$($Common.LocalAdmin.UserName)"
        $cacheKey = $cacheKey + "-" + $Common.LocalAdmin.UserName
    }

    Write-Log "$VmName`: Get-VmSession started with cachekey $cacheKey" -Verbose
    # Retrieve session from cache
    if ($global:ps_cache.ContainsKey($cacheKey)) {
        $ps = $global:ps_cache[$cacheKey]
        if ($ps.Availability -eq "Available") {
            Write-Log "$VmName`: Returning session for $userName from cache using key $cacheKey." -Verbose
            return $ps
        }
        else {
            $global:ps_cache.Remove($cacheKey)
            try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
        }
    }

    $vm = get-vm2 -Name $VmName
    if (-not $vm) {
        Write-Log "$VmName`: Failed to find VM named $VmName" -Failure -OutputStream
        return
    }
    $failCount = 0
    while ($true) {
        $ps = $null
        $failCount++
        if ($failCount -gt 1) {
            start-sleep -seconds 15
        }
        if ($failCount -gt 3) {
            break
        }

        $creds = New-Object System.Management.Automation.PSCredential ($username, $Common.LocalAdmin.Password)
        $ps = New-PSSession -Name $VmName -VMId $vm.vmID -Credential $creds -ErrorVariable Err0 -ErrorAction SilentlyContinue
        if ($Err0.Count -ne 0) {
            try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
            if ($VmDomainName -ne $VmName) {
                Write-Log "$VmName`: Failed to establish a session using $username. Error: $Err0" -Warning -Verbose
                $username2 = "$VmName\$($Common.LocalAdmin.UserName)"
                $creds = New-Object System.Management.Automation.PSCredential ($username2, $Common.LocalAdmin.Password)
                $cacheKey = $VmName + "-WORKGROUP"
                Write-Log "$VmName`: Falling back to local account and attempting to get a session using $username2." -Verbose
                $ps = New-PSSession -Name $VmName -VMId $vm.vmID -Credential $creds -ErrorVariable Err1 -ErrorAction SilentlyContinue
                if ($Err1.Count -ne 0) {
                    try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
                    $VM = Get-List -type VM | Where-Object { $_.VmName -eq $VmName }
                    if ($VM) {

                        $username3 = "$($VM.Domain)\$($Common.LocalAdmin.UserName)"
                        $creds = New-Object System.Management.Automation.PSCredential ($username3, $Common.LocalAdmin.Password)
                        $cacheKey = $VmName + "-$($VM.Domain)"
                        $ps = New-PSSession -Name $VmName -VMId $vm.vmID -Credential $creds -ErrorVariable Err1 -ErrorAction SilentlyContinue
                    }
                    if (-not $ps) {
                        if ($ShowVMSessionError.IsPresent -or ($failCount -eq 3)) {
                            Write-Log "$VmName`: Failed to establish a session using $username and $username2 $username3. Error: $Err1" -Warning
                        }
                        else {
                            Write-Log "$VmName`: Failed to establish a session using $username and $username2 $username3. Error: $Err1" -Warning -Verbose
                        }
                        continue
                    }
                }
            }
            else {
                if ($ShowVMSessionError.IsPresent -or ($failCount -eq 3)) {
                    try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
                    Write-Log "$VmName`: Failed to establish a session using $username. Error: $Err0" -Warning
                }
                else {
                    try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
                    Write-Log "$VmName`: Failed to establish a session using $username. Error: $Err0" -Warning -Verbose
                }
                continue
            }
        }

        if ($ps.Availability -eq "Available") {
            # Cache & return session
            Write-Log "$VmName`: Created session with VM using $username. CacheKey [$cacheKey]" -Success -Verbose
            $global:ps_cache[$cacheKey] = $ps
            return $ps
        }
        try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
        Write-Log "$VmName`: Could not create session with VM using $username. CacheKey [$cacheKey]" -Warning
    }
    try { Remove-PSSession $ps -ErrorAction SilentlyContinue } catch {}
    Write-Log "$VmName`: Could not create session with VM using $username. CacheKey [$cacheKey]" -Failure
}

function Get-StorageConfig {


    $newStorageConfigName = "_storageConfig2024.json"
    $newconfigPath = Join-Path $Common.ConfigPath $newStorageConfigName
    $StorageConfigName = "_storageConfig2024.json"
    $configPath = Join-Path $Common.ConfigPath $newStorageConfigName

    if (-not (Test-Path $newconfigPath)) {
        $GetNewStorageConfig = $true
        $storageConfigName = "_storageConfig2022.json"

        $configPath = Join-Path $Common.ConfigPath $storageConfigName
    
        if (-not (Test-Path $configPath)) {            
            Write-Log "Could not find $newconfigPath. Exiting."    
            $Common.FatalError = "Storage Config path '$newconfigPath' not found. Refer to internal documentation."
            Write-Log "File $newconfigPath does not exist."
            return $false       
        }
    }
    
    if (-not (Test-Path $configPath)) {
        $Common.FatalError = "Storage Config path '$configPath' not found. Refer to internal documentation."
        Write-Log "File $configPath does not exist."
        return $false
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
        if ($Common.DevBranch) {
            $fileListName = "_fileList_develop.json"
        }
        $fileListPath = Join-Path $Common.AzureFilesPath $fileListName
        $storageConfigPath = Join-Path $Common.ConfigPath $storageConfigName
        $fileListLocation = "$($StorageConfig.StorageLocation)/$fileListName"


        $productIDName = "productID.txt"
        $productID = "productID"
        $productIdPath = "E:\$productIDName"
        $procuctIdLocation = "$($StorageConfig.StorageLocation)/$productIDName"



        # See if image list needs to be updated
        if (Test-Path $fileListPath) {
            $Common.AzureFileList = Get-Content -Path $fileListPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $updateList = $Common.AzureFileList.UpdateFromStorage
        }

        # Update StorageConfig

        if (-not $InJob.IsPresent) {

            if ($GetNewStorageConfig) {
                $storageConfigLocation = "$($StorageConfig.StorageLocation)/$newStorageConfigName"
                Write-Log "Updating $($newStorageConfigName) from azure storage" -LogOnly
                $storageConfigURL = $storageConfigLocation + "?$($StorageConfig.StorageToken)"
                try {
                    $response = Invoke-WebRequest -Uri $storageConfigURL -UseBasicParsing -ErrorAction Stop
                }
                catch {
                    start-sleep -second 5
                    $response = Invoke-WebRequest -Uri $storageConfigURL -UseBasicParsing -ErrorAction Stop
                }
                if (-not $response) {
                    Write-Log "Failed to download updated storage config"
                }
                else {
                    $response.Content.Trim() | Out-File -FilePath $newconfigPath -Force -ErrorAction SilentlyContinue
                }

            }

            # Update file list
            if (($updateList) -or -not (Test-Path $fileListPath)) {

                Write-Log "Updating fileList from azure storage" -LogOnly

                # Get file list
                #$worked = Get-File -Source $fileListLocation -Destination $fileListPath -DisplayName "Updating file list" -Action "Downloading" -Silent -ForceDownload
                $fileListUrl = $fileListLocation + "?$($StorageConfig.StorageToken)"
                try {
                    $response = Invoke-WebRequest -Uri $fileListUrl -UseBasicParsing -ErrorAction Stop
                }
                catch {
                    start-sleep -second 5
                    $response = Invoke-WebRequest -Uri $fileListUrl -UseBasicParsing -ErrorAction Stop
                }
                if (-not $response) {
                    $Common.FatalError = "Failed to download file list."
                }
                else {
                    $response.Content.Trim() | Out-File -FilePath $fileListPath -Force -ErrorAction SilentlyContinue
                    $Common.AzureFileList = $response.Content.Trim() | ConvertFrom-Json -ErrorAction Stop
                }

            }

            # Get ProductID

            if (-not (Test-Path $productIdPath)) {

                Write-Log "Updating $($productIDName) from azure storage" -LogOnly
                $productIDURL = $procuctIdLocation + "?$($StorageConfig.StorageToken)"
                try {
                    $response = Invoke-WebRequest -Uri $productIDURL -UseBasicParsing -ErrorAction Stop
                }
                catch {
                    start-sleep -second 5
                    $response = Invoke-WebRequest -Uri $productIDURL -UseBasicParsing -ErrorAction Stop
                }
                if (-not $response) {
                    Write-Log "Failed to download updated Product ID"
                }
                else {
                    $response.Content.Trim() | Out-File -FilePath $productIdPath -Force -ErrorAction SilentlyContinue
                }
            }


        }

        if ($InJob.IsPresent) {
            Write-Log "Skipped updating fileList from azure storage, since we're running inside a job." -Verbose
        }

        # Get local admin password, regardless of whether we should update file list
        $username = "vmbuildadmin"
        $item = $Common.AzureFileList.OS | Where-Object { $_.id -eq $username }
        $fileUrl = "$($StorageConfig.StorageLocation)/$($item.filename)?$($StorageConfig.StorageToken)"
        $filePath = Join-Path $PSScriptRoot "cache\$username.txt"
        if (Test-Path $filePath -PathType leaf) {
            $response = Get-Content $filePath
            $response = $response.Trim()
        }
        else {
            $response = Invoke-WebRequest -Uri $fileUrl -UseBasicParsing -ErrorAction Stop
            if ($response) {
                $response.Content.Trim() | Out-file $filePath -Force
            }
            else {
                start-sleep -seconds 60
                $response = Invoke-WebRequest -Uri $fileUrl -UseBasicParsing -ErrorAction Stop
                if (-not $response) {
                    $Common.FatalError = "Could not download default credentials from azure. Please check your token"
                    return $false
                }
                $response.Content.Trim() | Out-file $filePath -Force
            }
            $response = $response.Content.Trim()
        }

        if ($response) {
            $s = ConvertTo-SecureString $response -AsPlainText -Force
            $Common.LocalAdmin = New-Object System.Management.Automation.PSCredential ($username, $s)
        }
        else {
            $Common.FatalError = "Admin file from azure is empty"
        }

        if ([string]::IsNullOrWhiteSpace($common.FatalError) ) {
        
            return $true
        }
        else {
            return $false 
        }

    }
    catch {
        $Common.FatalError = "Storage Access failed. $_"
        Write-Exception -ExceptionInfo $_
        Write-Host $_.ScriptStackTrace | Out-Host
        return $false
    }
    finally {
        $ProgressPreference = $pp
        $VerbosePreference = $vp
    }
}

function Get-Tools {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Skip Hash Testing of downloaded files.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Tool Name.")]
        [string]$ToolName,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$IncludeOptional,
        [Parameter(Mandatory = $false, HelpMessage = "Inject tools inside all Virtual Machines.")]
        [switch]$Inject,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $allSuccess = $true

    if ($ToolName -and $Common.AzureFileList.Tools.Name -notcontains $ToolName) {
        Write-Log "Invalid Tool Name ($ToolName) specified." -Warning
        return $false
    }

    if ($VmName) {
        $Inject = $true
    }

    Write-Log "Downloading/Verifying Tools that need to be injected in Virtual Machines..." -Activity
    foreach ($tool in $Common.AzureFileList.Tools) {

        if ($ToolName -and $tool.Name -ne $ToolName) { continue }

        if (-not $ToolName -and $tool.Optional -and -not $IncludeOptional.IsPresent) { continue }

        $name = $tool.Name
        $url = $tool.URL
        $fileTargetRelative = $tool.Target
        $fileName = Split-Path $url -Leaf
        if ($fileName.Contains("?")) {
            $fileName = $fileName.Split("?")[0]
        }
        $fileNameForDownload = Join-Path "tools" $fileName
        $downloadPath = Join-Path $Common.AzureToolsPath $fileName

        if (-not $tool.IsPublic) {
            $url = "$($StorageConfig.StorageLocation)/$url"
        }

        if (-not $tool.md5) {
            Write-Log "Downloading/Verifying '$name' without hash" -SubActivity
            $worked = Get-File -Source $url -Destination $downloadPath -DisplayName "Downloading '$filename' to $downloadPath..." -Action "Downloading" -UseBITS -UseCDN:$UseCDN -WhatIf:$WhatIf
        }
        else {
            Write-Log "Downloading/Verifying '$name' with hash" -SubActivity
            $tempworked = Get-FileWithHash -FileName $fileNameForDownload -FileDisplayName $name -FileUrl $url -ExpectedHash $tool.md5 -UseBITS -ForceDownload:$ForceDownloadFiles -IgnoreHashFailure:$IgnoreHashFailure -hashAlg "MD5" -UseCDN:$UseCDN -WhatIf:$WhatIf
            $worked = $tempworked.success
        }

        if (-not $worked) {
            Write-Log "Failed to Download or Verify '$name'"
            $allSuccess = $false
        }

        # Move to staging dir
        if ($worked) {

            # Create final destination directory, if not present
            $fileDestination = Join-Path $Common.StagingInjectPath $fileTargetRelative
            if (-not (Test-Path $fileDestination)) {
                $folderToCreate = $fileDestination
                if ($fileDestination.Contains(".")) {
                    $folderToCreate = Split-Path $fileDestination -Parent
                }
                New-Item -Path $folderToCreate -ItemType Directory -Force | Out-Null
            }

            # File downloaded
            $extractIfZip = $tool.ExtractFolderIfZip
            if (Test-Path $downloadPath) {
                if ($downloadPath.ToLowerInvariant().EndsWith(".zip") -and $extractIfZip -eq $true) {
                    Write-Log "Extracting $fileName to $fileDestination."
                    Expand-Archive -Path $downloadPath -DestinationPath $fileDestination -Force
                }
                else {
                    Write-Log "Copying $fileName to $fileDestination."
                    try {
                        Copy-Item -Path $downloadPath -Destination $fileDestination -Force -Confirm:$false
                    }
                    catch {}
                }
            }
        }
    }


    $injected = $allSuccess
    if ($Inject.IsPresent -and $allSuccess) {
        Write-Log "Injecting $ToolName to $VmName..." -Activity
        $HashArguments = @{
            WhatIf          = $WhatIf
            IncludeOptional = $IncludeOptional
        }

        if ($VmName) { $HashArguments.Add("VmName", $VmName) }
        if ($ToolName) { $HashArguments.Add("ToolName", $ToolName) }
        $HashArguments.Add("ShowProgress", $true)
        $injected = Install-Tools @HashArguments

    }

    if (-not $Inject.IsPresent) {
        Write-Host2
    }

    return $injected
}

function Install-Tools {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Optional ToolName Name.")]
        [string]$ToolName,
        [Parameter(Mandatory = $false)]
        [switch]$IncludeOptional,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    Write-Log "Install-Tools called. ${$VmName}"
    if ($VmName) {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName }
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }

    $success = $true
    foreach ($vm in $allVMs) {

        if ($vm.role -eq "OSDClient") { continue } # no injecting inside OSD client
        if ($vm.vmbuild -eq $false) { continue } # don't touch VM's we didn't create

        $vmName = $vm.vmName
        Write-Log "$vmName`: Injecting Tools to C:\tools directory inside the VM" -Activity

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            continue
        }

        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            continue
        }
        $out = Invoke-VmCommand -VmName $vm.vmName -AsJob -VmDomainName $vm.domain -SuppressLog -ScriptBlock { Test-Path -Path "C:\Tools\Fix-PostInstall.ps1" -ErrorAction SilentlyContinue }
        if ($out.ScriptBlockOutput -ne $true) {
            foreach ($tool in $Common.AzureFileList.Tools) {

                if ($tool.NoUpdate) { continue }

                if ($ToolName -and $tool.Name -ne $ToolName) { continue }

                if (-not $ToolName -and ($tool.Optional -and -not $IncludeOptional.IsPresent)) { continue }

                if ($ShowProgress) {
                    Write-Progress2 "Injecting tools" -Status "Injecting $($tool.Name) to $VmName"
                }

                $worked = Copy-ToolToVM -Tool $tool -VMName $vm.vmName -WhatIf:$WhatIf
                if (-not $worked) {
                    $success = $false
                }
            }
        }
    }

    Write-Host2

    if ($ShowProgress) {
        Write-Progress2 "Injecting tools" -Status "Done" -Completed
    }
    return $success
}

function Copy-ToolToVM {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Tool PS Object.")]
        [object]$Tool,
        [Parameter(Mandatory = $true, HelpMessage = "VM Name to inject tool in.")]
        [string]$VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $vm = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VMName }
    if ($vm.State -ne "Running") {
        Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
        continue
    }

    $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
    if (-not $ps) {
        Write-Log "$vmName`: Failed to get a session with the VM." -Failure
        return $false
    }

    if ($tool.NoUpdate -eq $true) {
        Write-Log "$vmName`: Skipped injecting '$($tool.Name) since it's marked NoUpdate." -Verbose
        return $true
    }

    $toolFileName = Split-Path $tool.url -Leaf
    $fileTargetRelative = Join-Path $tool.Target $toolFileName

    Write-Log "$vmName`: toolFileName = $toolFileName fileTargetRelative = $fileTargetRelative" -LogOnly

    if ($toolFileName.ToLowerInvariant().EndsWith(".zip") -and $tool.ExtractFolderIfZip) {
        Write-Log "$vmName`: File is marked to extract '$($tool.Name) since ExtractFolderIfZip is true" -Verbose
        $fileTargetRelative = $tool.Target
    }

    $toolPathHost = Join-Path $Common.StagingInjectPath $fileTargetRelative
    $fileTargetPathInVM = Join-Path "C:\" $fileTargetRelative

    $isContainer = $false
    if ((Get-Item $toolPathHost) -is [System.IO.DirectoryInfo]) {
        $isContainer = $true
        $fileTargetPathInVM = "C:\tools"
    }

    if ($tool.Name -eq "WMI Explorer") {
        $toolPathHost = Join-Path $toolPathHost "WmiExplorer.exe" # special case, since we extract the file directly in tools folder
        $fileTargetPathInVM = Join-Path "C:\$fileTargetRelative" "WmiExplorer.exe"
    }

    Write-Log "$vmName`: Injecting '$($tool.Name)' from HOST ($fileTargetRelative) to VM ($fileTargetPathInVM)."

    try {
        $progressPref = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        if ($isContainer) {
            #Copy-ItemSafe -VMName $vm.vmName -VmDomainName $vm.domain -Path $toolPathHost -Destination $fileTargetPathInVM -Recurse -Container -Force -WhatIf:$WhatIf -ErrorAction Stop
            Copy-Item -ToSession $ps -Path $toolPathHost -Destination $fileTargetPathInVM -Recurse -Container -Force -WhatIf:$WhatIf -ErrorAction Stop
        }
        else {
            #Copy-ItemSafe -VMName $vm.vmName -VMDomainName $vm.domain -Path $toolPathHost -Destination $fileTargetPathInVM -Force -WhatIf:$WhatIf -ErrorAction Stop
            Copy-Item -ToSession $ps -Path $toolPathHost -Destination $fileTargetPathInVM -Recurse -Container -Force -WhatIf:$WhatIf -ErrorAction Stop
        }
    }
    catch {
        Write-Log "$vmName`: Failed to inject '$($tool.Name)'. $_" -Failure
        return $false
    }
    finally {
        $ProgressPreference = $progressPref
    }

    return $true
}

function Copy-LanguagePacksToVM {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $destDir = "C:\LanguagePacks"

    if ($VmName) {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName }
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }

    foreach ($vm in $allVMs) {
        $vmName = $vm.vmName
        Write-Log "$vmName`: Trying to copy Language Packs to $destDir inside the VM" -Activity

        $sourceDir = Join-Path $Common.ConfigPath "locales" $vm.operatingSystem
        if (-not (Test-Path -Path "${sourceDir}\*" -Include *.cab)) {
            Write-Log "$vmName`: Cannot find language pack(s) in $sourceDir. Skipping copy." -Warning
            continue
        }

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            continue
        }

        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            continue
        }

        if ($ShowProgress) {
            Write-Progress2 "Copying language packs" -Status "Copying language packs to $VmName"
        }

        Write-Log "$vmName`: Copying '${sourceDir}\*' from HOST to VM (${destDir}\)."

        try {
            $progressPref = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"


            Copy-Item -ToSession $ps -Filter "*.cab" -Path "${sourceDir}" -Destination "${destDir}" -Recurse -WhatIf:$WhatIf -ErrorAction Stop
        }
        catch {
            Write-Log "$vmName`: Failed to copy language packs. $_" -Failure
            return $false
        }
        finally {
            $ProgressPreference = $progressPref
        }
    }

    Write-Host2

    if ($ShowProgress) {
        Write-Progress2 "Copying language packs" -Status "Done" -Completed
    }

    return $true
}

function Copy-LocaleConfigToVM {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $sourceDir = $Common.ConfigPath
    $destDir = "C:\staging\locale"
    $localeConfigFile = "_localeConfig.json"

    if ($VmName) {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName }
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }

    foreach ($vm in $allVMs) {
        $vmName = $vm.vmName
        Write-Log "$vmName`: Trying to copy $localeConfigFile to $destDir inside the VM" -Activity

        if (-not (Test-Path -Path "${sourceDir}\*" -Include "$localeConfigFile")) {
            Write-Log "$vmName`: Cannot find $localeConfigFile in $sourceDir. Skipping copy." -Warning
            continue
        }

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            continue
        }

        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            continue
        }

        if ($ShowProgress) {
            Write-Progress2 "Copying $localeConfigFile" -Status "Copying $localeConfigFile to $VmName"
        }

        Write-Log "$vmName`: Copying '${sourceDir}\${localeConfigFile}' from HOST to VM (${destDir}\)."

        try {
            $progressPref = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"

            # Fix me. this includes other empty folders
            Copy-Item -ToSession $ps -Filter "$localeConfigFile" -Path "${sourceDir}" -Destination "${destDir}" -Recurse -WhatIf:$WhatIf -ErrorAction Stop
        }
        catch {
            Write-Log "$vmName`: Failed to copy ${localeConfigFile}. $_" -Failure
            return $false
        }
        finally {
            $ProgressPreference = $progressPref
        }
    }

    Write-Host2

    if ($ShowProgress) {
        Write-Progress2 "Copying $localeConfigFile" -Status "Done" -Completed
    }

    return $true
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

        $fileUrl = "$($StorageConfig.StorageLocation)/$($filename)"
        $worked = Get-FileWithHash -FileName $fileName -FileDisplayName $imageName -FileUrl $fileUrl -ExpectedHash $fileHash -ForceDownload:$ForceDownloadFiles -IgnoreHashFailure:$IgnoreHashFailure -HashAlg $hashAlg -UseCDN:$UseCDN -WhatIf:$WhatIf
        $success = $($worked.success)
    }

    Write-Log -Verbose "Returning $success"
    return $success
}

function Get-FileWithHash {

    param(
        [Parameter(Mandatory = $true, HelpMessage = "File Name. Relative Path inside azureFiles directory.")]
        [string]$FileName,
        [Parameter(Mandatory = $false, HelpMessage = "File Display Name.")]
        [string]$FileDisplayName,
        [Parameter(Mandatory = $true, HelpMessage = "File URL.")]
        [string]$FileUrl,
        [Parameter(Mandatory = $true, HelpMessage = "Expected File Hash.")]
        [string]$ExpectedHash,
        [Parameter(Mandatory = $true, HelpMessage = "Hash Algorithm.")]
        [string]$hashAlg,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownload,
        [Parameter(Mandatory = $false, HelpMessage = "Ignore Hash Failures on file downloads.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$UseBITS,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $fileNameLeaf = Split-Path $FileName -Leaf
    $localImagePath = Join-Path $Common.AzureFilesPath $FileName
    $localImageHashPath = "$localImagePath.$hashAlg"

    $return = [PSCustomObject]@{
        success  = $true
        download = $false
    }

    Write-Log "Downloading/Verifying '$FileDisplayName'" -SubActivity

    if (Test-Path $localImagePath) {

        if (Test-Path $localImageHashPath) {
            # Read hash from local hash file
            $localFileHash = Get-Content $localImageHashPath
        }
        else {
            # Download if file present, but hashFile isn't there.
            #Get-File -Source $FileUrl -Destination $localImagePath -DisplayName "Hash Missing. Downloading '$FileName' to $localImagePath..." -Action "Downloading" -ResumeDownload -UseCDN:$UseCDN -UseBITS:$UseBITS -WhatIf:$WhatIf

            # Calculate file hash, save to local hash file
            #Write-Log "Calculating $hashAlg hash for $FileName in $($Common.AzureFilesPath)..."
            #$hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
            #$localFileHash = $hashFileResult.Hash
            #$localFileHash | Out-File -FilePath $localImageHashPath -Force
            $return.download = $true
        }
        # For dynamically updated packages, its impossible to know the hash ahead of time, so we just re-download these every run
        if ($ExpectedHash -ne "NONE") {
            if ($localFileHash -eq $ExpectedHash) {
                Write-Log "Found $FileName in $($Common.AzureFilesPath) with expected hash $ExpectedHash."
                if ($ForceDownload.IsPresent) {
                    Write-Log "ForceDownload switch present. Removing pre-existing $fileNameLeaf file..." -Warning
                    Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
                    $return.download = $true
                }
                else {
                    # Write-Log "ForceDownload switch not present. Skip downloading '$fileNameLeaf'." -LogOnly
                    $return.download = $false
                    $return.success = $true
                }
            }
            else {
                Write-Log "Found $FileName in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $ExpectedHash. Redownloading..."
                Remove-Item -Path $localImagePath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf | Out-Null
                Remove-Item -Path $localImageHashPath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf | Out-Null
                $return.download = $true
            }
        }
    }
    else {
        $return.download = $true
    }

    if ($return.download) {
        $worked = Get-File -Source $FileUrl -Destination $localImagePath -DisplayName "Downloading '$FileName' to $localImagePath..." -Action "Downloading" -UseCDN:$UseCDN -UseBITS:$UseBITS -WhatIf:$WhatIf -ForceDownload
        if (-not $worked) {
            $return.success = $false
        }
        else {
            if ($ExpectedHash -ne "NONE") {
                # Calculate file hash, save to local hash file
                Write-Log "Calculating $hashAlg hash for downloaded $FileName in $($Common.AzureFilesPath)..."
                $hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
                $localFileHash = $hashFileResult.Hash
                if ($localFileHash -eq $ExpectedHash) {
                    $localFileHash | Out-File -FilePath $localImageHashPath -Force
                    Write-Log "Downloaded $FileName in $($Common.AzureFilesPath) has expected hash $ExpectedHash."
                    $return.success = $true
                }
                else {
                    if ($IgnoreHashFailure) {
                        $return.success = $true
                    }
                    else {
                        Write-Log "Downloaded $filename in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $ExpectedHash." -Failure
                        $return.success = $false
                    }
                }
            }
            else {
                $return.success = $true
            }
        }
    }

    return $return
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
        "BDC",
        "CAS",
        "Primary",
        "Secondary",
        "SiteSystem",
        "PassiveSite",
        "FileServer",
        "SQLAO",
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient",
        "WSUS"

    )

    $rolesForExisting = @(
        "CAS",
        "BDC",
        "Primary",
        "Secondary",
        "SiteSystem",
        "PassiveSite",
        "FileServer",
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient",
        "SQLAO",
        "WSUS"
    )


    $updatablePropList = @("InstallCA", "InstallRP", "InstallMP", "InstallDP", "InstallSUP", "InstallSMSS")
    $propsToUpdate = $updatablePropList
    $propsToUpdate += "wsusContentDir"

    $cmVersions += Get-CMVersions

    $operatingSystems = $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" } | Sort-Object

    $sqlVersions = $Common.AzureFileList.ISO.id | Select-Object -Unique | Sort-Object

    $supported = [PSCustomObject]@{
        Roles              = $roles
        RolesForExisting   = $rolesForExisting
        AllRoles           = ($roles + $rolesForExisting | Select-Object -Unique)
        OperatingSystems   = $operatingSystems
        SqlVersions        = $sqlVersions
        CMVersions         = $cmVersions
        UpdateablePropList = $updatablePropList
        PropsToUpdate      = $propsToUpdate
    }

    $Common.Supported = $supported

}

function Get-CMVersions {
    $cmVersions = @()
    foreach ($version in $Common.AzureFileList.CMVersions) {
        $cmversions += $version.versions
    }
    $cmVersions = $cmVersions | Sort-Object -Descending
    return $cmVersions
}

function Get-CMBaselineVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return ($Common.AzureFileList.CMVersions | Where-Object { $_.versions -contains $CMVersion })

}

function Get-CMLatestBaselineVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return ($Common.AzureFileList.CMVersions.baselineVersion | Where-Object { $_ -notin "tech-preview", "current-branch" } | Sort-Object -Descending | Select-Object -First 1)

}

function Get-CMLatestVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return (Get-CMVersions | Where-Object { $_ -notin "tech-preview", "current-branch" } | Select-Object -First 1)

}

function Get-BranchName {
    try {
        $branch = git rev-parse --abbrev-ref HEAD

        if ($branch -eq "HEAD") {
            # we're probably in detached HEAD state, so print the SHA
            $branch = git rev-parse --short HEAD
        }

        return $branch

    }
    catch {
        return $null
    }
}

Function Set-PS7ProgressWidth {
    if ($PSVersionTable.PSVersion.Major -eq 7) {
        $maxWidth = 500
        try {
            $currentWidth = [Console]::WindowWidth
            if ($currentWidth -gt 0) {
                $maxWidth = [Math]::Round(($currentWidth * 0.95), 0)
            }
        }
        catch {}
        $PSStyle.Progress.MaxWidth = $maxWidth
    }
}

Function Set-TitleBar {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Text
    )

    $VersionString = "MemLabs version $($global:Common.MemLabsVersion)"
    if ($devBranch) {
        $VersionString = $VersionString + " (DevBranch)"
    }

    if ($Global:ConfigFile) {
        $config = [System.Io.Path]::GetFileNameWithoutExtension(($Global:configfile))
        $VersionString = $config + " - " + $VersionString
    }
    # Set Title bar
    $host.ui.RawUI.WindowTitle = $VersionString + " - " + $Text
}

####################
### DOT SOURCING ###
####################
. $PSScriptRoot\common\Common.Colors.ps1
. $PSScriptRoot\common\Common.BaseImage.ps1
. $PSScriptRoot\common\Common.Config.ps1
. $PSScriptRoot\common\Common.Phases.ps1
. $PSScriptRoot\common\Common.Validation.ps1
. $PSScriptRoot\common\Common.RdcMan.ps1
. $PSScriptRoot\common\Common.Remove.ps1
. $PSScriptRoot\common\Common.Maintenance.ps1
. $PSScriptRoot\common\Common.ScriptBlocks.ps1
. $PSScriptRoot\common\Common.GenConfig.ps1
. $PSScriptRoot\common\Common.HyperV.ps1

############################
### Common Object        ###
############################

if (-not $Common.Initialized) {

    # Write progress
    Write-Progress2 "Loading required modules." -Status "Please wait..." -PercentComplete 1

    $global:vm_remove_list = @()

    ###################
    ### GIT BRANCH  ###
    ###################
    Write-Progress2 "Loading required modules." -Status "Checking Git Status" -PercentComplete 2
    write-log "$($env:ComputerName) is running git branch from $($pwd.Path)" -LogOnly
    $devBranch = $false
    try {
        if ($pwd.Path -like '*memlabs*') {
            $currentBranch = Get-BranchName
        }
    }
    catch {}
    if ($currentBranch -and $currentBranch -notmatch "main") {
        $devBranch = $true
    }

    # PS Version
    $PS7 = $false
    Write-Progress2 "Loading required modules." -Status "Checking PS Version" -PercentComplete 3
    if ($PSVersionTable.PSVersion.Major -eq 7) {
        $PS7 = $true
        $PSStyle.Progress.Style = "`e[38;5;123m"
        $psstyle.Formatting.TableHeader = "`e[3;38;5;195m"
        $psstyle.Formatting.Warning = "`e[33m"

    }

    # Set-StrictMode -Off
    # if ($devBranch) {
    #     Set-StrictMode -Version 1.0
    # }
    Write-Progress2 "Loading required modules." -Status "Checking Directories" -PercentComplete 5
    # Paths
    $staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "baseimagestaging")           # Path where staged files for base image creation go
    $storagePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "azureFiles")             # Path for downloaded files
    $logsPath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "logs")                      # Path for log files
    $desktopPath = [Environment]::GetFolderPath("Desktop")

    # Get latest hotfix version


    Write-Progress2 "Loading required modules." -Status "Loading Global Configuration" -PercentComplete 7
    # Common global props

    $colors = Get-Colors

    $global:Common = [PSCustomObject]@{
        MemLabsVersion        = "240920"
        LatestHotfixVersion   = "240710"
        PS7                   = $PS7
        Initialized           = $true
        TempPath              = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "temp")             # Path for temporary files
        ConfigPath            = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files
        # ConfigSamplesPath     = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config\reserved")   # Path for Config files
        CachePath             = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "cache")            # Path for Get-List cache files
        SizeCache             = $null                                                                     # Cache for Memory Assigned, and Disk Usage
        NetCache              = $null                                                                     # Cache for Get-NetworkAdapter
        AzureFilesPath        = $storagePath                                                              # Path for downloaded files
        AzureImagePath        = New-Directory -DirectoryPath (Join-Path $storagePath "os")                # Path to store sysprepped gold image after customization
        AzureIsoPath          = New-Directory -DirectoryPath (Join-Path $storagePath "iso")               # Path for ISO's (typically for SQL)
        AzureToolsPath        = New-Directory -DirectoryPath (Join-Path $storagePath "tools")             # Path for downloading tools to inject in the VM
        StagingAnswerFilePath = New-Directory -DirectoryPath (Join-Path $staging "unattend")              # Path for Answer files
        StagingInjectPath     = New-Directory -DirectoryPath (Join-Path $staging "filesToInject")         # Path to files to inject in VHDX
        StagingWimPath        = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
        StagingImagePath      = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
        StagingVMPath         = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
        LogPath               = Join-Path $logsPath "VMBuild.log"                                         # Log File
        CrashLogsPath         = New-Directory -DirectoryPath (Join-Path $logsPath "crashlogs")            # Path for crash logs
        RdcManFilePath        = Join-Path $DesktopPath "memlabs.rdg"                                      # RDCMan File
        VerboseEnabled        = $VerboseEnabled.IsPresent                                                 # Verbose Logging
        DevBranch             = $devBranch                                                                # Git dev branch
        Supported             = $null                                                                     # Supported Configs
        AzureFileList         = $null
        LocalAdmin            = $null
        FatalError            = $null
        Colors                = $colors
    }

    # Storage config
    $global:StorageConfig = [PSCustomObject]@{
        StorageLocation = $null
        StorageToken    = $null
    }
    Write-Log "Memlabs $($global:Common.MemLabsVersion) Initializing" -LogOnly

    Set-TitleBar "Init Phase"
    Write-Log "Loading required modules." -Verbose

    ### Test Storage config and access
    Write-Progress2 "Loading required modules." -Status "Checking Storage Config" -PercentComplete 9
    $getresults = Get-StorageConfig 
    if ($getresults -eq $false) {
        Write-Log "failed to get the storage JSON file" -Failure
        return 
    }



    Write-Progress2 "Loading required modules." -Status "Gathering VM Maintenance Tasks" -PercentComplete 11
    $global:Common.latestHotfixVersion = Get-VMFixes -ReturnDummyList | Sort-Object FixVersion -Descending | Select-Object -First 1 -ExpandProperty FixVersion

    ### Set supported options
    Write-Progress2 "Loading required modules." -Status "Gathering Supported Options" -PercentComplete 13
    Set-SupportedOptions

    # Generate cache
    $i = 14
    if (-not $InJob.IsPresent) {

        #disable Sticky Keys
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Type String -Value "506"
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Type String -Value "58"
        Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Type String -Value "122"

        try {
            if ($global:common.CachePath) {
                $threshold = 2
                Get-ChildItem -Path $global:common.CachePath -File -Filter "*.json" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$threshold) } | Remove-Item -Force | out-null
            }
        }
        catch {}

        try {
            Get-ChildItem -Force 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -Recurse | ForEach-Object { $_.PSChildName } | ForEach-Object { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\$($_)" -Name "Category" -Value 1 }
        }
        catch {}

        # Retrieve VM List, and cache results
        Write-Progress2 "Loading required modules." -Status "Reset Cache" -PercentComplete $i
        $list = Get-List -Type VM -ResetCache
        foreach ($vm in $list) {
            $i++
            if ($i -ge 98) {
                $i = 98
            }
            Write-Progress2 "Loading required modules." -Status "Updating VM Cache" -PercentComplete $i
            $vm2 = Get-VM -id $vm.vmId
            Update-VMInformation -vm $vm2
        }


        $i++
        Write-Progress2 "Loading required modules." -Status "Moving Logs" -PercentComplete $i

        # Starting 2/1/2022, all logs should be in logs directory. Move logs to the logs folder, if any at root.
        Get-ChildItem -Path $PSScriptRoot -Filter *.log | Move-Item -Destination $logsPath -Force -ErrorAction SilentlyContinue
        $oldCrashPath = Join-Path $PSScriptRoot "crashlogs"
        if (Test-Path $oldCrashPath) {
            Get-ChildItem -Path $oldCrashPath -Filter *.txt | Move-Item -Destination $Common.CrashLogsPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $oldCrashPath -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
        }

        # Starting 3/11/2022, we changed the log format, remove older format logs
        $logPath = Join-Path $PSScriptRoot "logs"
        foreach ($log in (Get-ChildItem $logPath -Filter *.log )) {
            $logLine = Get-Content $log.FullName -TotalCount 1
            if ($logLine -and -not $logLine.StartsWith("<![LOG[")) {
                Remove-Item -Path $log.FullName -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

        $i++
        Write-Progress2 "Loading required modules." -Status "Finalizing" -PercentComplete $i

        # Add HGS Registry key to allow local CA Cert
        New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
    }
    # Write progress
    Write-Progress2 "Loading required modules." -Completed

}