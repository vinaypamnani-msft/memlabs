<#
.SYNOPSIS
    Compacts Hyper-V virtual hard disks in parallel with a WPF progress UI.

.DESCRIPTION
    Optimizes (compacts) the VHDs attached to the specified Hyper-V VMs in
    parallel, showing real-time progress, disk sizes before/after, and space
    savings. Jobs are scheduled up to MaxConcurrentJobs concurrent, largest
    disks first.

    Launched from the MemLabs domain "Compact VHDX's in domain" menu. The
    caller stops the selected VMs first; this worker only runs Optimize-VHD.

.PARAMETER VMNames
    The names of the VMs whose VHDs should be compacted. If omitted, every
    VM on the host is considered.

.PARAMETER Mode
    The optimization mode: Quick, Full, Retrim, or Prezeroed. Default is Full.

.PARAMETER MaxConcurrentJobs
    Maximum number of concurrent optimization jobs. Default is 8.
#>

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [string[]]$VMNames,

    [ValidateSet('Quick', 'Full', 'Retrim', 'Prezeroed')]
    [string]$Mode = 'Full',

    [ValidateRange(1, 16)]
    [int]$MaxConcurrentJobs = 8,

    # Skip the in-guest defrag step (mount VHDX, defrag, Optimize-Volume,
    # dismount) before Optimize-VHD. By default we run defrag because it
    # massively improves the space reclaimed by Optimize-VHD - the guest has
    # to release the blocks first.
    [switch]$SkipDefrag,

    # Skip the offline filesystem cleanup pass (delete WSUS cache, temp,
    # dumps, prefetch, recycle bin) + offline DISM /Cleanup-Image while the
    # VHDX is mounted. Default is to run it.
    [switch]$SkipOfflineClean,

    # Skip the zero-fill of free space before Optimize-VHD. Zero-filling
    # massively improves space reclaim because Optimize-VHD only reclaims
    # blocks that contain zeros. Default is to run it.
    [switch]$SkipZeroFill,

    # Skip the in-guest (online) cleanup that runs against still-running VMs
    # via PSDirect BEFORE shutting them down. Default is to run it.
    # Credentials are sourced from $Common.LocalAdmin after we dot-source
    # Common.ps1 in worker mode.
    [switch]$SkipOnlineClean,

    # Friendly label shown in the WPF window title bar and embedded in the
    # per-run log file name. Normally a domain name; falls back to a VM
    # count if not supplied.
    [string]$DomainLabel
)

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    return '{0:N2} KB' -f ($Bytes / 1KB)
}

function Get-VhdFileSize {
    param([string]$Path)
    try {
        ([System.IO.FileInfo]::new($Path)).Length
    }
    catch {
        $null
    }
}

# ========================= BACKGROUND WORKER MODE =========================
# When launched via self-invocation with the _COMPACT_DISKS_WORKER env var,
# this block runs the WPF window and processing loop, then exits.
if ($env:_COMPACT_DISKS_WORKER) {
    $dataFilePath = $env:_COMPACT_DISKS_DATAFILE
    $readyFilePath = $env:_COMPACT_DISKS_READYFILE
    # Clear the env vars immediately so they don't leak to child processes
    Remove-Item Env:\_COMPACT_DISKS_WORKER    -ErrorAction SilentlyContinue
    Remove-Item Env:\_COMPACT_DISKS_DATAFILE  -ErrorAction SilentlyContinue
    Remove-Item Env:\_COMPACT_DISKS_READYFILE -ErrorAction SilentlyContinue

    # Dot-source Common.ps1 so we have $Common.LocalAdmin (used by the
    # per-VM prep jobs for PSDirect online cleanup) and helpers like
    # Invoke-VmCommand / Get-VmSession. Use -InJob to suppress the
    # background-image/UI bits we don't want from this detached console.
    try {
        $commonPath = Join-Path $PSScriptRoot 'Common.ps1'
        if (Test-Path $commonPath) {
            if ($Common -and $Common.Initialized) { $Common.Initialized = $false }
            . $commonPath -InJob:$true
        }
    }
    catch {
        Write-Warning "Failed to dot-source Common.ps1 (online cleanup will be skipped): $($_.Exception.Message)"
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # Load serialized disk data from the temp file
    $importedData = Import-Clixml -Path $dataFilePath
    Remove-Item -Path $dataFilePath -Force -ErrorAction SilentlyContinue

    $AttachedCount = $importedData.AttachedCount
    $DomainLabel   = $importedData.DomainLabel
    $ShutdownTimeoutSec = if ($importedData.ShutdownTimeoutSec) { [int]$importedData.ShutdownTimeoutSec } else { 300 }

    # Path to Common.ps1 - each prep job dot-sources it to gain access to
    # Invoke-VmCommand + $Common.LocalAdmin for online cleanup. If Common.ps1
    # didn't load in this worker process, online cleanup is silently skipped.
    $WorkerCommonPath = if ($Common -and $Common.Initialized) { Join-Path $PSScriptRoot 'Common.ps1' } else { $null }

    # Per-VM prep records (stop + checkpoint merge) - one entry per VM.
    # When prep completes its disks are pushed onto $diskQueue.
    $vmInfoList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $prepQueue  = [System.Collections.Generic.Queue[PSCustomObject]]::new()
    foreach ($v in $importedData.VMs) {
        $obj = [PSCustomObject]@{
            VMName     = $v.VMName
            Job        = $null
            Status     = 'Pending'        # Pending / Running / Completed / Failed
            Error      = $null
            Forced     = $false           # true if graceful shutdown timed out and we hard-stopped
            WasRunning = $false           # true if VM was Running when prep started; restart it at the end
        }
        $vmInfoList.Add($obj)
        $prepQueue.Enqueue($obj)
    }

    # Compact queue starts empty; populated as prep jobs finish.
    $diskInfoList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $diskQueue    = [System.Collections.Generic.Queue[PSCustomObject]]::new()

    # Shared state between UI thread and main processing thread
    $UiSync = [hashtable]::Synchronized(@{
        OverallPercent = 0
        StatusText     = 'Starting...'
        ElapsedText    = '00:00:00'
        Jobs           = [System.Collections.ArrayList]::new()
        Log            = [System.Collections.ArrayList]::new()
        Close          = $false
        WindowClosed   = $false
        # User-requested-but-deferred shutdown. When the user clicks X mid-run
        # we set this and refuse to launch new prep / compact work, but we let
        # in-flight jobs (snapshot merges, Optimize-VHD, mount/dismount steps)
        # finish naturally. The window's Closing handler enforces this by
        # cancelling the close until the main loop has drained.
        StopRequested  = $false
        # Last-resort hard stop. Only set when the user explicitly chooses
        # 'force close' in the closing-confirmation prompt. The main loop
        # treats this like the old WindowClosed=true behaviour: throw, kill
        # jobs, dismount, exit. Risks: a snapshot merge mid-flight may leave
        # behind orphaned .avhdx files; the safety-net Dismount-VHD covers
        # mounted disks.
        ForceClose     = $false
        WindowReady    = $false
        ReadyFile      = $readyFilePath
        Title          = if ($DomainLabel) { "Hyper-V VHD Optimization - $DomainLabel" } else { 'Hyper-V VHD Optimization' }
        HeaderText     = if ($DomainLabel) { "Hyper-V VHD Optimization - $DomainLabel" } else { 'Hyper-V VHD Optimization' }
        LogPath        = $null
    })

    # --- Dedicated log file for this Compact-Disks run ---
    # logs\Compact-Disks-<domain>-<yyyyMMdd-HHmmss>.log
    # Captures everything that goes into the UI log box plus details that
    # don't fit there (per-VHD start banner, defrag stdout, etc.)
    $script:CompactLogPath = $null
    try {
        $logsDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path $logsDir)) {
            New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $domTag = if ($DomainLabel) {
            ($DomainLabel -replace '[^A-Za-z0-9._-]', '_')
        } else { 'all' }
        $script:CompactLogPath = Join-Path $logsDir "Compact-Disks-$domTag-$stamp.log"
        $UiSync.LogPath = $script:CompactLogPath
        $banner = @(
            "==========================================================="
            "Compact-Disks run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "  Domain           : $DomainLabel"
            "  Mode             : $Mode"
            "  MaxConcurrentJobs: $MaxConcurrentJobs"
            "  SkipOnlineClean  : $SkipOnlineClean"
            "  SkipOfflineClean : $SkipOfflineClean"
            "  SkipDefrag       : $SkipDefrag"
            "  SkipZeroFill     : $SkipZeroFill"
            "  VMs              : $(($importedData.VMs | ForEach-Object VMName) -join ', ')"
            "==========================================================="
        )
        Set-Content -LiteralPath $script:CompactLogPath -Value $banner -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not initialize Compact-Disks log file: $($_.Exception.Message)"
        $script:CompactLogPath = $null
    }

    function Add-UiLog {
        param([string]$Message)
        [void]$UiSync.Log.Add($Message)
        if ($script:CompactLogPath) {
            try {
                $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
                Add-Content -LiteralPath $script:CompactLogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    # ------------------------------------------------------------------
    # Invoke-CompactCleanup - safety-net cleanup for early exit.
    #
    # If the user closes the WPF window mid-run (or the worker dies for
    # any other reason), the per-VM prep/compact jobs that were Stop-Job'd
    # may have died holding mounted VHDs open. This function is the last
    # line of defense: it stops/removes any leftover jobs we own, then
    # walks $diskInfoList and dismounts any VHDX that's still attached to
    # the host. Safe to call multiple times; runs from both the main-loop
    # finally and a PowerShell.Exiting engine event.
    # ------------------------------------------------------------------
    $script:CleanupDone = $false
    function Invoke-CompactCleanup {
        param([string]$Reason = 'Exit')
        if ($script:CleanupDone) { return }
        $script:CleanupDone = $true

        try { Add-UiLog ("[CLEANUP] Starting safety cleanup (reason: $Reason)") } catch {}

        # 1. Kill any of our jobs that are still running. Match by name
        #    prefix so we don't touch unrelated jobs in this session.
        try {
            $leftoverJobs = @(Get-Job -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like 'Prep_*' -or $_.Name -like 'Compact_*'
            })
            foreach ($j in $leftoverJobs) {
                try { Stop-Job  -Job $j -ErrorAction SilentlyContinue } catch {}
                try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
            }
            if ($leftoverJobs.Count -gt 0) {
                try { Add-UiLog ("[CLEANUP] Stopped/removed $($leftoverJobs.Count) leftover job(s)") } catch {}
            }
        } catch {}

        # 2. Dismount any VHDX from our queue that's still attached.
        #    Get-VHD is authoritative (a job that died mid-mount won't have
        #    cleared its $mounted flag, so we can't rely on local state).
        $dismounted = 0
        try {
            if ($diskInfoList -and $diskInfoList.Count -gt 0) {
                foreach ($d in $diskInfoList) {
                    if (-not $d.Path) { continue }
                    if (-not (Test-Path -LiteralPath $d.Path)) { continue }
                    try {
                        $vhd = Get-VHD -Path $d.Path -ErrorAction SilentlyContinue
                        if ($vhd -and $vhd.Attached) {
                            # Only dismount if the VHD isn't attached to a
                            # running VM (i.e. it was mounted to the host
                            # by our offline-clean step, not by Hyper-V
                            # because the guest is running).
                            $ownedByVm = $false
                            try {
                                $ownedByVm = [bool](Get-VM -ErrorAction SilentlyContinue |
                                    Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Path -ieq $d.Path } |
                                    ForEach-Object { (Get-VM -Id $_.VMId -ErrorAction SilentlyContinue).State -eq 'Running' } |
                                    Where-Object { $_ })
                            } catch {}
                            if (-not $ownedByVm) {
                                try {
                                    Dismount-VHD -Path $d.Path -ErrorAction Stop
                                    $dismounted++
                                    try { Add-UiLog ("[CLEANUP] Dismounted $($d.Path)") } catch {}
                                } catch {
                                    try { Add-UiLog ("[CLEANUP] Dismount failed for $($d.Path): $($_.Exception.Message)") } catch {}
                                }
                            }
                        }
                    } catch {
                        # Get-VHD can throw if the file is gone or locked; ignore.
                    }
                }
            }
        } catch {}
        if ($dismounted -gt 0) {
            try { Add-UiLog ("[CLEANUP] Dismounted $dismounted VHD(s) left attached by interrupted jobs") } catch {}
        }

        # 3. Best-effort: clear any stale zero-fill temp file the
        #    interrupted job might have left inside a mounted volume.
        #    (After dismount the file is gone with the volume, so nothing
        #    to do here - kept as a comment for future maintainers.)

        try { Add-UiLog ("[CLEANUP] Safety cleanup complete") } catch {}
    }

    # Engine-exit safety net: even if the script throws or the user kills
    # the window, this fires on normal PowerShell shutdown so we don't
    # leave mounted VHDs behind. (Won't fire on process-kill, but the
    # in-loop finally + Window-Closed branch cover the common cases.)
    try {
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
            try { Invoke-CompactCleanup -Reason 'PowerShell.Exiting' } catch {}
        } | Out-Null
    } catch {}

    # --- WPF window in a dedicated STA runspace ---
    $uiRunspace = [runspacefactory]::CreateRunspace()
    $uiRunspace.ApartmentState = 'STA'
    $uiRunspace.ThreadOptions  = 'ReuseThread'
    $uiRunspace.Open()
    $uiRunspace.SessionStateProxy.SetVariable('UiSync', $UiSync)

    $uiPipeline = [powershell]::Create().AddScript({
        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hyper-V VHD Optimization" Width="780" Height="600" MinWidth="550" MinHeight="400"
        WindowStartupLocation="CenterScreen" Background="#1E1E2E" Topmost="True">
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#CDD6F4"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="14"/>
        </Style>
        <Style x:Key="FlatProgress" TargetType="ProgressBar">
            <Setter Property="Background" Value="#45475A"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="18"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border Background="{TemplateBinding Background}" CornerRadius="3"
                                x:Name="PART_Track">
                            <Grid>
                                <Rectangle x:Name="PART_Indicator" HorizontalAlignment="Left"
                                           Fill="{TemplateBinding Foreground}"
                                           RadiusX="3" RadiusY="3"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="OverallProgress" TargetType="ProgressBar" BasedOn="{StaticResource FlatProgress}">
            <Setter Property="Height" Value="28"/>
            <Setter Property="Foreground" Value="#A6E3A1"/>
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock x:Name="TitleText" FontSize="20" FontWeight="SemiBold"
                       Text="Hyper-V VHD Optimization" Foreground="#89B4FA"/>
            <TextBlock x:Name="LogPathLine" FontSize="11" Margin="0,2,0,0" Foreground="#7F849C"
                       TextTrimming="CharacterEllipsis">
                <Run Text="Log: "/><Hyperlink x:Name="LogPathLink" Foreground="#89DCEB"
                                               TextDecorations="None"
                                               ToolTip="Click to open in Notepad. Right-click to open containing folder."><Run x:Name="LogPathRun" Text="(initializing)"/></Hyperlink>
            </TextBlock>
        </StackPanel>
        <StackPanel Grid.Row="1" Margin="0,0,0,10">
            <TextBlock x:Name="StatusText" FontSize="15" Margin="0,0,0,6"/>
            <Grid>
                <ProgressBar x:Name="OverallProgress" Minimum="0" Maximum="100"
                             Style="{StaticResource OverallProgress}"/>
                <TextBlock x:Name="OverallPctText" HorizontalAlignment="Center" VerticalAlignment="Center"
                           FontSize="14" FontWeight="Bold" Foreground="White"/>
            </Grid>
            <TextBlock x:Name="ElapsedText" FontSize="13" Margin="0,6,0,0" Foreground="#BAC2DE"/>
        </StackPanel>
        <TextBlock Grid.Row="2" Text="Active Jobs" FontSize="15" FontWeight="SemiBold"
                   Margin="0,6,0,6" Foreground="#F9E2AF"/>
        <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" Margin="0,0,0,10">
            <StackPanel x:Name="JobPanel"/>
        </ScrollViewer>
        <Border Grid.Row="4" Background="#181825" CornerRadius="4" Padding="10" MaxHeight="140">
            <TextBox x:Name="LogText" FontSize="12" FontFamily="Consolas"
                     TextWrapping="Wrap" Foreground="#A6ADC8" Background="Transparent"
                     BorderThickness="0" IsReadOnly="True" IsReadOnlyCaretVisible="False"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                     AcceptsReturn="True"/>
        </Border>
    </Grid>
</Window>
'@

        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Title = $UiSync.Title
        # Intercept close. While work is active we never let the X button kill
        # the process - that would Stop-Job an in-flight snapshot merge or
        # Optimize-VHD and risk corrupting the chain or leaving the VHDX
        # mounted on the host. Instead we show a custom 3-button dialog:
        #   'Safe Stop'  - request a safe stop. We cancel the close, set
        #                  StopRequested, and the main loop drains naturally.
        #   'Keep Going' - cancel the close; work continues.
        #   'Force Kill' - sets ForceClose+WindowClosed; the main loop kills
        #                  jobs and dismounts. Last resort.
        # (System.Windows.MessageBox has fixed Yes/No/Cancel labels - we
        # build a custom dialog so the destructive button reads 'Force Kill'.)
        # Once StopRequested is set (or we're past the work phase), the X
        # button is a normal close.
        $script:ShowCloseDialog = {
            param([string]$Title, [string]$Body, [bool]$IncludeSafeStop)
            $btnXaml = if ($IncludeSafeStop) {
@'
                <Button x:Name="BtnSafeStop"  Content="Safe Stop"  IsDefault="True"  MinWidth="110" Margin="0,0,8,0" Padding="10,4"/>
                <Button x:Name="BtnKeepGoing" Content="Keep Going"                  MinWidth="110" Margin="0,0,8,0" Padding="10,4"/>
                <Button x:Name="BtnForceKill" Content="Force Kill" IsCancel="True"  MinWidth="110"                   Padding="10,4" Background="#F38BA8" Foreground="White"/>
'@
            } else {
@'
                <Button x:Name="BtnKeepGoing" Content="Keep Going" IsDefault="True" MinWidth="110" Margin="0,0,8,0" Padding="10,4"/>
                <Button x:Name="BtnForceKill" Content="Force Kill" IsCancel="True"  MinWidth="110"                   Padding="10,4" Background="#F38BA8" Foreground="White"/>
'@
            }
            $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" SizeToContent="Height" Width="560" MinHeight="200"
        WindowStartupLocation="CenterOwner" Background="#1E1E2E"
        ShowInTaskbar="False" ResizeMode="NoResize" Topmost="True">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Foreground="#CDD6F4" FontSize="13" FontFamily="Segoe UI"
                   TextWrapping="Wrap" Margin="0,0,0,18"
                   Text="$([System.Security.SecurityElement]::Escape($Body))"/>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
$btnXaml
        </StackPanel>
    </Grid>
</Window>
"@
            $rd = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dlgXaml))
            $dlg = [System.Windows.Markup.XamlReader]::Load($rd)
            $dlg.Owner = $window
            $result = 'KeepGoing'
            if ($IncludeSafeStop) {
                $dlg.FindName('BtnSafeStop').Add_Click({ $result = 'SafeStop'; $dlg.DialogResult = $true }.GetNewClosure())
            }
            $dlg.FindName('BtnKeepGoing').Add_Click({ $result = 'KeepGoing'; $dlg.DialogResult = $true }.GetNewClosure())
            $dlg.FindName('BtnForceKill').Add_Click({ $result = 'ForceKill'; $dlg.DialogResult = $true }.GetNewClosure())
            [void]$dlg.ShowDialog()
            return $result
        }

        $window.Add_Closing({
            param($sender, $e)
            # If a stop is already in progress, let the close go through only
            # when the worker has acknowledged it (main loop set WindowClosed
            # or transitioned out of work). Otherwise wait silently.
            $busy = (-not $UiSync.WindowClosed) -and (-not $UiSync.ForceClose) -and `
                    (($UiSync.Jobs -and $UiSync.Jobs.Count -gt 0) -or $UiSync.OverallPercent -lt 100)
            if (-not $busy) { return }

            if ($UiSync.StopRequested) {
                # Already asked once - second click is a Force Kill / Keep
                # Waiting decision.
                $r2 = & $script:ShowCloseDialog `
                    -Title 'Force kill?' `
                    -Body  ("A safe stop is already in progress. Active jobs (snapshot merges, Optimize-VHD, mounted VHDs) are being allowed to finish.`n`nForce Kill NOW anyway? This may leave VHDs mounted on the host or interrupt a snapshot merge in progress (risk of orphaned .avhdx files).") `
                    -IncludeSafeStop $false
                if ($r2 -eq 'ForceKill') {
                    $UiSync.ForceClose   = $true
                    $UiSync.WindowClosed = $true
                    return
                }
                $e.Cancel = $true
                return
            }

            $resp = & $script:ShowCloseDialog `
                -Title 'Stop optimization?' `
                -Body  ("VHD optimization is in progress.`n`nClosing now would Stop-Job snapshot merges and Optimize-VHD calls that are running, which can leave the VHD chain in a half-merged state and/or leave VHDX files mounted on the host.`n`nSafe Stop  - Stop accepting new work and wait for the current jobs to finish safely, then close. (Recommended)`nKeep Going - Continue optimizing.`nForce Kill - End now. Risk of corruption / mounted disks.") `
                -IncludeSafeStop $true

            switch ($resp) {
                'SafeStop' {
                    $UiSync.StopRequested = $true
                    $e.Cancel = $true
                }
                'KeepGoing' {
                    $e.Cancel = $true
                }
                'ForceKill' {
                    $UiSync.ForceClose   = $true
                    $UiSync.WindowClosed = $true
                }
            }
        })
        $window.Add_Closed({ $UiSync.WindowClosed = $true })
        $window.Add_Loaded({
            # Signal the foreground (NORMAL-mode) launcher that the window
            # is up so it can close its console without looking crashed.
            if ($UiSync.ReadyFile) {
                try {
                    New-Item -Path $UiSync.ReadyFile -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            }
        })

        $TitleText       = $window.FindName('TitleText')
        $StatusText      = $window.FindName('StatusText')
        $OverallProgress = $window.FindName('OverallProgress')
        $OverallPctText  = $window.FindName('OverallPctText')
        $ElapsedText     = $window.FindName('ElapsedText')
        $JobPanel        = $window.FindName('JobPanel')
        $LogText         = $window.FindName('LogText')
        $LogPathRun      = $window.FindName('LogPathRun')
        $LogPathLink     = $window.FindName('LogPathLink')
        $TitleText.Text  = $UiSync.HeaderText
        if ($UiSync.LogPath) {
            $LogPathRun.Text = $UiSync.LogPath
            $logPathLocal = $UiSync.LogPath
            $LogPathLink.Add_Click({
                try { Start-Process -FilePath 'notepad.exe' -ArgumentList $logPathLocal } catch {}
            }.GetNewClosure())
            $LogPathLink.Add_MouseRightButtonUp({
                try {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$logPathLocal`""
                } catch {}
            }.GetNewClosure())
        } else {
            $LogPathRun.Text = '(no log file)'
            $LogPathLink.IsEnabled = $false
        }

        $bc       = [System.Windows.Media.BrushConverter]::new()
        $fgBrush  = $bc.ConvertFrom('#CDD6F4')
        $bgBar    = $bc.ConvertFrom('#45475A')
        $fillBar  = $bc.ConvertFrom('#74C7EC')

        $ui = @{
            BarRefs  = @{}
            PctRefs  = @{}
            LogCount = 0
            JobHash  = ''
        }

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $timer.Add_Tick({
            if ($UiSync.Close) {
                $timer.Stop()
                $window.Close()
                return
            }

            $OverallProgress.Value = $UiSync.OverallPercent
            $OverallPctText.Text   = "$($UiSync.OverallPercent)%"
            $StatusText.Text       = $UiSync.StatusText
            $ElapsedText.Text      = "Elapsed: $($UiSync.ElapsedText)"

            $snapshot = @($UiSync.Jobs)
            $currentNames = ($snapshot | ForEach-Object { $_.Name }) -join '|'
            $structureChanged = ($currentNames -ne $ui.JobHash)

            if ($structureChanged) {
                $snapshotNames = @{}
                foreach ($j in $snapshot) { $snapshotNames[$j.Name] = $true }

                $rowsByName = @{}
                $toRemove = [System.Collections.Generic.List[object]]::new()
                foreach ($child in $JobPanel.Children) {
                    $rowName = $null
                    foreach ($pair in $ui.BarRefs.GetEnumerator()) {
                        if ($ui.BarRefs[$pair.Key] -and $ui.BarRefs[$pair.Key].Parent -and
                            $ui.BarRefs[$pair.Key].Parent.Parent -eq $child) {
                            $rowName = $pair.Key
                            break
                        }
                    }
                    if ($rowName -and -not $snapshotNames.ContainsKey($rowName)) {
                        $toRemove.Add($child)
                        $ui.BarRefs.Remove($rowName)
                        $ui.PctRefs.Remove($rowName)
                    } elseif ($rowName) {
                        $rowsByName[$rowName] = $child
                    }
                }
                foreach ($r in $toRemove) { $JobPanel.Children.Remove($r) }

                $insertIdx = 0
                foreach ($j in $snapshot) {
                    if (-not $rowsByName.ContainsKey($j.Name)) {
                        $row = [System.Windows.Controls.Grid]::new()
                        $row.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)

                        $c0 = [System.Windows.Controls.ColumnDefinition]::new()
                        $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                        $c1 = [System.Windows.Controls.ColumnDefinition]::new()
                        $c1.Width = [System.Windows.GridLength]::new(150)
                        $c2 = [System.Windows.Controls.ColumnDefinition]::new()
                        $c2.Width = [System.Windows.GridLength]::new(55)
                        $row.ColumnDefinitions.Add($c0)
                        $row.ColumnDefinitions.Add($c1)
                        $row.ColumnDefinitions.Add($c2)

                        $nameBlock = [System.Windows.Controls.TextBlock]::new()
                        $nameBlock.Text = $j.Name
                        $nameBlock.FontSize = 13
                        $nameBlock.Foreground = $fgBrush
                        $nameBlock.VerticalAlignment = 'Center'
                        $nameBlock.TextTrimming = 'CharacterEllipsis'
                        [System.Windows.Controls.Grid]::SetColumn($nameBlock, 0)
                        $row.Children.Add($nameBlock) | Out-Null

                        $barGrid = [System.Windows.Controls.Grid]::new()
                        $barGrid.Margin = [System.Windows.Thickness]::new(10, 0, 10, 0)
                        [System.Windows.Controls.Grid]::SetColumn($barGrid, 1)

                        $bgBdr = [System.Windows.Controls.Border]::new()
                        $bgBdr.Background  = $bgBar
                        $bgBdr.CornerRadius = [System.Windows.CornerRadius]::new(3)
                        $bgBdr.Height = 18
                        $barGrid.Children.Add($bgBdr) | Out-Null

                        $fillBdr = [System.Windows.Controls.Border]::new()
                        $fillBdr.Background  = $fillBar
                        $fillBdr.CornerRadius = [System.Windows.CornerRadius]::new(3)
                        $fillBdr.Height = 18
                        $fillBdr.HorizontalAlignment = 'Left'
                        $fillBdr.Width = 0
                        $barGrid.Children.Add($fillBdr) | Out-Null

                        $row.Children.Add($barGrid) | Out-Null

                        $pctBlock = [System.Windows.Controls.TextBlock]::new()
                        $pctBlock.Text = "$([int]$j.Percent)%"
                        $pctBlock.FontSize = 13
                        $pctBlock.Foreground = $fgBrush
                        $pctBlock.VerticalAlignment  = 'Center'
                        $pctBlock.HorizontalAlignment = 'Right'
                        $pctBlock.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
                        [System.Windows.Controls.Grid]::SetColumn($pctBlock, 2)
                        $row.Children.Add($pctBlock) | Out-Null

                        if ($insertIdx -lt $JobPanel.Children.Count) {
                            $JobPanel.Children.Insert($insertIdx, $row)
                        } else {
                            $JobPanel.Children.Add($row) | Out-Null
                        }

                        $ui.BarRefs[$j.Name] = $fillBdr
                        $ui.PctRefs[$j.Name] = $pctBlock
                        $rowsByName[$j.Name] = $row
                    }
                    $insertIdx++
                }
                $ui.JobHash = $currentNames
            }

            foreach ($j in $snapshot) {
                $pct = [int]$j.Percent
                $fill = $ui.BarRefs[$j.Name]
                $ptxt = $ui.PctRefs[$j.Name]
                if ($fill) {
                    $containerW = $fill.Parent.ActualWidth
                    if ($containerW -gt 0) {
                        $fill.Width = [math]::Max(0, ($pct / 100.0) * $containerW)
                    }
                }
                if ($ptxt) { $ptxt.Text = "$pct%" }
            }

            $logEntries = @($UiSync.Log)
            if ($logEntries.Count -gt $ui.LogCount) {
                $newLines = $logEntries[$ui.LogCount..($logEntries.Count - 1)]
                $existing = $LogText.Text
                if ($existing) { $existing += "`n" }
                $LogText.Text = $existing + ($newLines -join "`n")
                $ui.LogCount = $logEntries.Count
                $LogText.ScrollToEnd()
            }
        })
        $timer.Start()

        $UiSync.WindowReady = $true
        $window.ShowDialog() | Out-Null
    })
    $uiPipeline.Runspace = $uiRunspace
    $uiHandle = $uiPipeline.BeginInvoke()

    # Wait for the UI thread to be ready
    $uiWait = 0
    while (-not $UiSync.WindowReady -and $uiWait -lt 50) {
        Start-Sleep -Milliseconds 100
        $uiWait++
    }

    # --- Helper functions ---
    function Get-JobProgress {
        param($Job)
        $result = [PSCustomObject]@{ Percent = 0; Status = '' }
        if ($Job -and $Job.ChildJobs.Count -gt 0) {
            $progressRecords = $Job.ChildJobs[0].Progress
            if ($progressRecords -and $progressRecords.Count -gt 0) {
                # Two kinds of records flow in:
                #   (a) our own Write-Progress entries with Activity
                #       "Compact <path>" or "Prep <name>" - linear 0..100
                #       across the whole job.
                #   (b) Optimize-VHD's native progress records emitted by
                #       the cmdlet itself - those go 0..100 for just the
                #       final compact step. We squash them into the
                #       30..95 band so the bar doesn't snap back to 0
                #       when Optimize-VHD starts streaming.
                $latest = $progressRecords[$progressRecords.Count - 1]
                $act = "$($latest.Activity)"
                $isOurs = $act.StartsWith('Compact ', [System.StringComparison]::OrdinalIgnoreCase) -or
                          $act.StartsWith('Prep ',    [System.StringComparison]::OrdinalIgnoreCase)
                if ($isOurs) {
                    if ($latest.PercentComplete -ge 0) { $result.Percent = $latest.PercentComplete }
                    if ($latest.StatusDescription)    { $result.Status  = $latest.StatusDescription }
                } else {
                    # Native cmdlet progress (Optimize-VHD). Scale into 30..95.
                    $raw = if ($latest.PercentComplete -ge 0) { $latest.PercentComplete } else { 0 }
                    $result.Percent = [int](30 + ($raw * 0.65))
                    $result.Status  = if ($latest.StatusDescription) {
                        "Optimize-VHD: $($latest.StatusDescription) ($raw%)"
                    } else {
                        "Optimize-VHD ($raw%)"
                    }
                }
            }
        }
        return $result
    }

    function Update-Progress {
        param($DiskList, $ActiveJobs, $ActivePrepJobs, $StartTime)
        $elapsed = (Get-Date) - $StartTime
        $total   = $DiskList.Count
        $done    = @($DiskList | Where-Object { $_.Status -in 'Completed', 'Failed' }).Count
        $running = $ActiveJobs.Count
        $prep    = $ActivePrepJobs.Count
        $pct = if ($total -gt 0) { [math]::Round(($done / $total) * 100) } else { 0 }

        $UiSync.OverallPercent = $pct
        if ($total -gt 0) {
            $UiSync.StatusText = "$done of $total disks compacted | Compacting: $running | Preparing VMs: $prep"
        } else {
            $UiSync.StatusText = "Preparing $prep VM(s) (stop + checkpoint merge)..."
        }
        $UiSync.ElapsedText = $elapsed.ToString('hh\:mm\:ss')

        $jobSnapshot = [System.Collections.ArrayList]::new()
        # Prep jobs first - they don't have a real % so show status text
        foreach ($vm in $ActivePrepJobs) {
            $jp = Get-JobProgress -Job $vm.Job
            $statusTxt = if ($jp.Status) { $jp.Status } else { 'Preparing...' }
            [void]$jobSnapshot.Add(@{
                Name    = "[PREP] $($vm.VMName) - $statusTxt"
                Percent = $jp.Percent
            })
        }
        foreach ($disk in $ActiveJobs) {
            $jp = Get-JobProgress -Job $disk.Job
            [void]$jobSnapshot.Add(@{
                Name    = "$($disk.VMName) - $($disk.FileName)"
                Percent = $jp.Percent
            })
        }
        $UiSync.Jobs = $jobSnapshot
    }

    # --- Synchronous processing loop (main thread of the detached process) ---
    # Two job pools running concurrently:
    #   - $activePrepJobs: one Start-Job per VM. Each does a graceful Stop-VM
    #     (with hard-stop fallback), merges every checkpoint, then returns
    #     that VM's VHD list. Bounded only by VM count (these are mostly idle
    #     waiting on Hyper-V).
    #   - $activeJobs: Optimize-VHD jobs, up to $MaxConcurrentJobs concurrent.
    # When a prep job finishes, its VHDs are pushed onto $diskQueue, so the
    # slowest-to-stop VM doesn't block compaction of fast ones.
    $activePrepJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $activeJobs     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $startTime      = Get-Date

    if ($script:CompactLogPath) {
        Add-UiLog ("Logging to: $script:CompactLogPath")
    }

    # --- Pre-flight: plan concurrent checkpoint merges across all VMs ---
    # Prep jobs run in parallel, so we have to look at the *aggregate* AVHDX
    # bytes per drive, not just per-VM. For every drive that can't hold all
    # merges at once, we'll serialize merges on that drive via a named
    # cross-process mutex acquired inside each prep job.
    #
    # VMs that don't fit even individually are marked Status='Deferred'
    # (NOT 'Failed') and held back. After the main pass completes (which
    # frees disk space via merges and Optimize-VHD on the VMs that did fit),
    # we re-plan the deferred VMs and run another pass. Up to 2 retry passes
    # before declaring them failed.
    $SerializeDrives = @()
    $maxRetryPasses  = 2
    $pass            = 0

    function Invoke-MergePlan {
        param([string[]]$Names, [int]$PassNumber)
        try {
            if (-not (Get-Command Resolve-VMCheckpointMergePlan -ErrorAction SilentlyContinue)) {
                return @{ SerializeDrives = @(); FailingVMs = @() }
            }
            $mp = Resolve-VMCheckpointMergePlan -VMNames $Names
            $tag = if ($PassNumber -eq 0) { 'MERGE-PLAN' } else { "MERGE-PLAN-RETRY$PassNumber" }
            foreach ($d in $mp.Drives) {
                $msg = '{0}: total={1:N1}GB max={2:N1}GB avail={3:N1}GB -> {4}' -f `
                    $d.Drive, ($d.AvhdxTotal/1GB), ($d.AvhdxMax/1GB), ($d.Available/1GB), $d.Classification
                Add-UiLog ("[$tag] $msg")
            }
            if (-not $mp.Ok) {
                foreach ($d in $mp.Drives | Where-Object Classification -eq 'Fail') {
                    Add-UiLog ("[$tag] Drive $($d.Drive): not enough free space for largest VM. Affected: $($d.FailingVMs -join ', ')")
                }
            }
            if ($mp.SerializeDrives.Count -gt 0) {
                Add-UiLog ("[$tag] Serializing merges on drive(s): $($mp.SerializeDrives -join ', ')")
            }
            return @{ SerializeDrives = @($mp.SerializeDrives); FailingVMs = @($mp.FailingVMs) }
        } catch {
            Add-UiLog ("[MERGE-PLAN-WARN] Planning failed: $($_.Exception.Message)")
            return @{ SerializeDrives = @(); FailingVMs = @() }
        }
    }

    $namesForPlan = @($vmInfoList | ForEach-Object VMName)
    $planResult   = Invoke-MergePlan -Names $namesForPlan -PassNumber 0
    $SerializeDrives = $planResult.SerializeDrives
    foreach ($vm in $vmInfoList) {
        if ($planResult.FailingVMs -contains $vm.VMName) {
            $vm.PreFlightFail = $true
        }
    }

    do {
        $shouldRetry = $false
    try {
        $stopAnnounced = $false
        while ($prepQueue.Count -gt 0 -or $activePrepJobs.Count -gt 0 -or
               $diskQueue.Count -gt 0 -or $activeJobs.Count -gt 0) {
            # Hard stop (user picked 'force close' in the closing prompt, or
            # WindowClosed was set by some other path). Throw so the finally
            # below Stop-Job's everything and Invoke-CompactCleanup runs.
            if ($UiSync.ForceClose -or ($UiSync.WindowClosed -and -not $UiSync.StopRequested)) {
                throw 'WindowClosed'
            }

            # Soft stop: user asked to close but we promised to let in-flight
            # work finish. Refuse to launch any new prep/compact jobs; just
            # spin until the active lists drain naturally.
            if ($UiSync.StopRequested) {
                if (-not $stopAnnounced) {
                    Add-UiLog ('[STOP-REQUESTED] User requested close; waiting for active jobs to finish safely before closing...')
                    $stopAnnounced = $true
                }
                $UiSync.StatusText = ('Stop requested - waiting for {0} active job(s) to finish safely...' -f ($activePrepJobs.Count + $activeJobs.Count))
                # Drain queues so nothing new gets started.
                while ($prepQueue.Count -gt 0) { [void]$prepQueue.Dequeue() }
                while ($diskQueue.Count -gt 0) { [void]$diskQueue.Dequeue() }
                if ($activePrepJobs.Count -eq 0 -and $activeJobs.Count -eq 0) {
                    break
                }
                # Fall through to the bottom of the loop to wait/refresh.
            }

            # ----- Launch prep jobs (one per VM, all in parallel) -----
            while ($prepQueue.Count -gt 0) {
                $vm = $prepQueue.Dequeue()
                if ($vm.PSObject.Properties['PreFlightFail'] -and $vm.PreFlightFail) {
                    # Deferred (NOT failed): wait until others compact and
                    # free up enough room. Final retry pass below converts
                    # to 'Failed' if it still can't fit.
                    $vm.Status = 'Deferred'
                    $vm.Error  = 'Pre-flight: not enough free disk space to merge checkpoints'
                    Add-UiLog ("[PREP-DEFER] $($vm.VMName): $($vm.Error)")
                    continue
                }
                Add-UiLog ("[PREP-START] $($vm.VMName)")
                try {
                    $job = Start-Job -Name "Prep_$($vm.VMName)" -ScriptBlock {
                        param($n, $timeoutSec, $commonPath, $doOnlineClean, $serializeDrives)
                        $startedAt = Get-Date
                        $forced = $false
                        $onlineCleanRan = $false
                        function Write-PrepLog($msg) { Write-Output "::LOG::$msg" }

                        Write-PrepLog "--- Prep started for $n ---"

                        # Capture initial state so we can auto-restart at the
                        # end if the VM was running when this script began.
                        $initial = Get-VM -Name $n -ErrorAction SilentlyContinue
                        $wasRunning = ($initial -and $initial.State -eq 'Running')
                        Write-PrepLog ("Initial state: {0}" -f ($initial.State))

                        # Dot-source Common.ps1 so we have Invoke-VmCommand /
                        # Get-VmSession / $Common.LocalAdmin, plus the
                        # Test-VMCheckpointMergeFreeSpace pre-merge check.
                        # -InJob suppresses the UI/background-image init bits.
                        $commonLoaded = $false
                        if ($commonPath -and (Test-Path $commonPath)) {
                            try {
                                if ($Common -and $Common.Initialized) { $Common.Initialized = $false }
                                Write-PrepLog "Dot-sourcing Common.ps1 (worker mode)"
                                . $commonPath -InJob:$true
                                $commonLoaded = $true
                                Write-PrepLog "Common.ps1 loaded"
                            }
                            catch {
                                Write-PrepLog "Common.ps1 load FAILED: $($_.Exception.Message)"
                            }
                        } else {
                            Write-PrepLog "Common.ps1 not found at: $commonPath (online cleanup will be skipped)"
                        }

                        # --- 0) Online cleanup (only if VM is currently Running) ---
                        # Uses Invoke-VmCommand which handles credential lookup
                        # (domain account first, then local fallback via VM
                        # note) and PSSession caching for us.
                        $cur = Get-VM -Name $n -ErrorAction SilentlyContinue
                        if (-not $doOnlineClean) {
                            Write-PrepLog "Online cleanup: SKIPPED (-SkipOnlineClean)"
                        }
                        elseif (-not $commonLoaded) {
                            Write-PrepLog "Online cleanup: SKIPPED (Common.ps1 not loaded)"
                        }
                        elseif (-not $cur -or $cur.State -ne 'Running') {
                            Write-PrepLog ("Online cleanup: SKIPPED (VM state is {0}, must be Running)" -f ($cur.State))
                        }
                        elseif (-not $Common.LocalAdmin) {
                            Write-PrepLog "Online cleanup: SKIPPED (no LocalAdmin credentials available)"
                        }
                        else {
                            Write-Progress -Activity "Prep $n" -Status 'Online cleanup (in-guest)' -PercentComplete 2
                            Write-PrepLog "[ONLINE-CLEAN] Starting in-guest cleanup via PSDirect..."

                            # Discover the VM's domain via the VM note so
                            # Invoke-VmCommand picks the right credentials.
                            $note = Get-VMNote -VMName $n -ErrorAction SilentlyContinue
                            $vmDomain = if ($note -and $note.domain) { $note.domain } else { 'WORKGROUP' }
                            Write-PrepLog "[ONLINE-CLEAN] VM domain (from note): $vmDomain"

                            $cleanupScript = {
                                $ProgressPreference = 'SilentlyContinue'
                                $ErrorActionPreference = 'SilentlyContinue'
                                $report = [System.Collections.Generic.List[string]]::new()
                                function _Add($m) { $report.Add(('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m)) }
                                function _GetFree { try { (Get-PSDrive -Name C).Free } catch { 0 } }
                                $freeStart = _GetFree
                                _Add ("START in-guest cleanup on $env:COMPUTERNAME ; C: free = {0:N1} GB" -f ($freeStart/1GB))

                                # Stop services that lock the caches we want to nuke
                                $svcs = @('wuauserv','bits','cryptsvc','WSUSService','UsoSvc','TrustedInstaller')
                                foreach ($s in $svcs) {
                                    try {
                                        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
                                        if ($svc) {
                                            Stop-Service -Name $s -Force -ErrorAction Stop
                                            _Add "  Stop-Service $s : ok"
                                        }
                                    } catch { _Add "  Stop-Service $s : FAILED $($_.Exception.Message)" }
                                }

                                $purge = @(
                                    'C:\Windows\SoftwareDistribution\Download\*',
                                    'C:\Windows\Temp\*',
                                    'C:\Windows\Logs\CBS\*',
                                    'C:\Windows\Logs\DISM\*',
                                    'C:\Windows\Prefetch\*',
                                    'C:\Windows\Minidump\*',
                                    'C:\Windows\Memory.dmp',
                                    'C:\inetpub\logs\LogFiles\*',
                                    'C:\ProgramData\Microsoft\Windows\WER\*',
                                    'C:\ProgramData\Microsoft\Windows\WindowsUpdate\Log\*',
                                    'C:\ProgramData\USOShared\Logs\*',
                                    'C:\Users\*\AppData\Local\Temp\*',
                                    'C:\Users\*\AppData\Local\Microsoft\Windows\WER\*',
                                    'C:\Users\*\AppData\Local\Microsoft\Windows\INetCache\*',
                                    'C:\Users\*\AppData\Local\Microsoft\Windows\WebCache\*',
                                    # Additional Windows caches and logs
                                    'C:\Windows\Installer\$PatchCache$\*',
                                    'C:\Windows\ccmcache\*',
                                    'C:\Windows\ccmsetup\Logs\*',
                                    'C:\Windows\System32\LogFiles\*',
                                    'C:\Windows\Panther\*',
                                    'C:\PerfLogs\*',
                                    'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache\*',
                                    'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*',
                                    # Per-user crash dumps location
                                    'C:\Users\*\AppData\Local\CrashDumps\*',
                                    # MemLabs install leftovers
                                    'C:\CMCB',
                                    'C:\CMTP',
                                    'C:\temp\Upgrade2025',
                                    'C:\temp\*.msi',
                                    'C:\temp\*.exe',
                                    'C:\temp\*.cab',
                                    'C:\temp\*.zip',
                                    'C:\temp\*.iso',
                                    'C:\temp\adksetup*',
                                    'C:\temp\WinPE*',
                                    'C:\temp\sql',
                                    'C:\temp\sql_CU',
                                    'C:\temp\SQLServer*',
                                    'C:\temp\DSC',
                                    'C:\temp\staging'
                                )
                                foreach ($pat in $purge) {
                                    try {
                                        if (Test-Path -LiteralPath $pat -ErrorAction SilentlyContinue) {
                                            $before = (Get-ChildItem -Path $pat -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Sum -Property Length).Sum
                                            Remove-Item -Path $pat -Recurse -Force -ErrorAction Stop
                                            if ($before -gt 0) { _Add ("  Purged {0} ({1:N1} MB)" -f $pat, ($before/1MB)) }
                                        }
                                    } catch { _Add "  Purge FAILED $pat : $($_.Exception.Message)" }
                                }

                                # --- Age-based pruning ---
                                # Some log dirs we want to TRIM (keep recent
                                # activity) rather than wipe wholesale. Walk
                                # these and delete only files older than
                                # $logAgeDays. Each entry is a directory root
                                # + optional include pattern.
                                $logAgeDays = 10
                                $cutoff = (Get-Date).AddDays(-$logAgeDays)
                                $ageRoots = @(
                                    # IIS access logs (W3SVC*, SMTPSVC*, etc.)
                                    @{ Path = 'C:\inetpub\logs\LogFiles';            Filter = '*' }
                                    @{ Path = 'C:\inetpub\logs\FailedReqLogFiles';   Filter = '*' }
                                    @{ Path = 'C:\inetpub\temp\IIS Temporary Compressed Files'; Filter = '*' }
                                    # Windows / WaaS / Update logs (.etl, .log)
                                    @{ Path = 'C:\Windows\Logs';                     Filter = '*.log' }
                                    @{ Path = 'C:\Windows\Logs';                     Filter = '*.etl' }
                                    @{ Path = 'C:\Windows\Logs\WindowsUpdate';      Filter = '*' }
                                    @{ Path = 'C:\Windows\Logs\waasmedic';          Filter = '*' }
                                    @{ Path = 'C:\Windows\Logs\NetSetup';           Filter = '*' }
                                    @{ Path = 'C:\Windows\Logs\MoSetup';            Filter = '*' }
                                    @{ Path = 'C:\Windows\System32\LogFiles\HTTPERR'; Filter = '*' }
                                    @{ Path = 'C:\Windows\System32\LogFiles\W3SVC';   Filter = '*' }
                                    @{ Path = 'C:\Windows\System32\Winevt\Logs';    Filter = '*Archive*' }
                                    # Configuration Manager (client + site server)
                                    @{ Path = 'C:\Windows\CCM\Logs';                 Filter = '*.lo_' }
                                    @{ Path = 'C:\Windows\CCM\Logs';                 Filter = '*.log' }
                                    @{ Path = 'C:\Windows\ccmsetup\Logs';           Filter = '*' }
                                    @{ Path = 'C:\Program Files\Microsoft Configuration Manager\Logs'; Filter = '*.lo_' }
                                    @{ Path = 'C:\Program Files\Microsoft Configuration Manager\Logs'; Filter = '*.log' }
                                    @{ Path = 'C:\Program Files\SMS_CCM\Logs';      Filter = '*' }
                                    @{ Path = 'C:\SMS_CCM\ServiceData';              Filter = '*' }
                                    # WSUS / SUP
                                    @{ Path = 'C:\Program Files\Update Services\LogFiles'; Filter = '*.log' }
                                    # SQL Server error log rollovers (ERRORLOG.1..ERRORLOG.99)
                                    @{ Path = 'C:\Program Files\Microsoft SQL Server'; Filter = 'ERRORLOG.*'; Recurse = $true }
                                    @{ Path = 'C:\Program Files\Microsoft SQL Server'; Filter = 'SQLAGENT.*'; Recurse = $true }
                                    # NOTE: deliberately NOT pruning C:\Users\**\*.dmp here.
                                    # WER-collected dumps already get nuked above (per-user
                                    # AppData\Local\Microsoft\Windows\WER\* and
                                    # AppData\Local\CrashDumps\* are in the wholesale-purge
                                    # list). Any other .dmp under C:\Users is likely a
                                    # user-collected debug capture (procdump, WinDbg, etc.)
                                    # that we shouldn't touch.
                                )
                                foreach ($r in $ageRoots) {
                                    try {
                                        if (-not (Test-Path -LiteralPath $r.Path -ErrorAction SilentlyContinue)) { continue }
                                        $gciArgs = @{
                                            Path        = $r.Path
                                            Filter      = $r.Filter
                                            Recurse     = $true
                                            File        = $true
                                            Force       = $true
                                            ErrorAction = 'SilentlyContinue'
                                        }
                                        $stale = Get-ChildItem @gciArgs | Where-Object { $_.LastWriteTime -lt $cutoff }
                                        if (-not $stale) { continue }
                                        $bytes = ($stale | Measure-Object -Sum -Property Length).Sum
                                        $count = ($stale | Measure-Object).Count
                                        $stale | Remove-Item -Force -ErrorAction SilentlyContinue
                                        if ($bytes -gt 0) {
                                            _Add ("  Pruned >{0}d {1}\{2} : {3} file(s) {4:N1} MB" -f $logAgeDays, $r.Path, $r.Filter, $count, ($bytes/1MB))
                                        }
                                    } catch { _Add "  Prune FAILED $($r.Path)\$($r.Filter) : $($_.Exception.Message)" }
                                }

                                try { Clear-RecycleBin -Force -ErrorAction Stop; _Add "  Clear-RecycleBin: ok" } catch { _Add "  Clear-RecycleBin: $($_.Exception.Message)" }

                                # Disable hibernation -> removes C:\hiberfil.sys
                                # (typically ~RAM size, often multi-GB).
                                try { & powercfg.exe /h off 2>$null | Out-Null; _Add "  powercfg /h off: ok" } catch { _Add "  powercfg /h off: FAILED" }

                                # Delete all VSS shadow copies / system
                                # restore points. They can hold many GB.
                                try {
                                    $vssOut = & vssadmin.exe delete shadows /all /quiet 2>&1
                                    _Add ("  vssadmin delete shadows /all: {0}" -f (($vssOut | Out-String).Trim() -replace "`r?`n",' | '))
                                } catch { _Add "  vssadmin: FAILED $($_.Exception.Message)" }

                                # Component-store cleanup. /ResetBase makes
                                # installed updates permanent (can't uninstall)
                                # and lets DISM purge superseded payloads.
                                try { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet | Out-Null; _Add "  DISM StartComponentCleanup /ResetBase: ok" } catch { _Add "  DISM StartComponentCleanup: FAILED" }
                                try { & dism.exe /Online /Cleanup-Image /SPSuperseded /Quiet | Out-Null; _Add "  DISM SPSuperseded: ok" } catch { _Add "  DISM SPSuperseded: FAILED" }

                                # Silent disk cleanup (cleanmgr /sagerun) -
                                # pre-set StateFlags so every category is
                                # enabled, then trigger. Best-effort and may
                                # not complete in a PSDirect session, but
                                # what does run is pure gravy.
                                try {
                                    $vcRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
                                    if (Test-Path $vcRoot) {
                                        Get-ChildItem $vcRoot -ErrorAction SilentlyContinue | ForEach-Object {
                                            try {
                                                New-ItemProperty -Path $_.PSPath -Name 'StateFlags9999' `
                                                    -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null
                                            } catch {}
                                        }
                                        Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:9999','/d C:' `
                                            -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                                        _Add "  cleanmgr /sagerun:9999 launched"
                                    }
                                } catch { _Add "  cleanmgr: FAILED $($_.Exception.Message)" }

                                # WSUS server content cleanup (if WSUS role present)
                                try {
                                    if (Get-Module -ListAvailable -Name UpdateServices) {
                                        Import-Module UpdateServices -ErrorAction SilentlyContinue
                                        $wsus = Get-WsusServer -ErrorAction SilentlyContinue
                                        if ($wsus) {
                                            Invoke-WsusServerCleanup -CleanupObsoleteComputers `
                                                -CleanupObsoleteUpdates -CleanupUnneededContentFiles `
                                                -CompressUpdates -DeclineSupersededUpdates `
                                                -DeclineExpiredUpdates -ErrorAction SilentlyContinue | Out-Null
                                            _Add "  WSUS server cleanup: ran"
                                        }
                                    }
                                } catch { _Add "  WSUS cleanup: FAILED $($_.Exception.Message)" }

                                # Restart the services we stopped (best-effort)
                                foreach ($s in @('wuauserv','bits','cryptsvc')) {
                                    try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch {}
                                }

                                $freeEnd = _GetFree
                                _Add ("END in-guest cleanup ; C: free = {0:N1} GB (reclaimed {1:N1} GB)" -f ($freeEnd/1GB), (($freeEnd-$freeStart)/1GB))
                                return ,$report
                            }

                            try {
                                $result = Invoke-VmCommand -VmName $n -VmDomainName $vmDomain `
                                    -ScriptBlock $cleanupScript -DisplayName 'Compact-Disks online cleanup' `
                                    -SuppressLog
                                if ($result -and -not $result.ScriptBlockFailed) {
                                    $onlineCleanRan = $true
                                    Write-PrepLog "[ONLINE-CLEAN] Completed successfully"
                                    if ($result.ScriptBlockOutput) {
                                        foreach ($line in @($result.ScriptBlockOutput)) {
                                            if ($line) { Write-PrepLog "[ONLINE-CLEAN] $line" }
                                        }
                                    }
                                } else {
                                    $errMsg = if ($result) { $result.ScriptBlockFailed } else { 'no result' }
                                    Write-PrepLog "[ONLINE-CLEAN] FAILED: $errMsg"
                                }
                            }
                            catch {
                                Write-PrepLog "[ONLINE-CLEAN] FAILED with exception: $($_.Exception.Message)"
                            }
                        }

                        # --- 1) Graceful shutdown (if running) ---
                        $cur = Get-VM -Name $n -ErrorAction SilentlyContinue
                        if ($cur -and $cur.State -ne 'Off') {
                            Write-PrepLog "[STOP] Requesting graceful shutdown (current state: $($cur.State); timeout: ${timeoutSec}s)"
                            Write-Progress -Activity "Prep $n" -Status 'Stopping (graceful)' -PercentComplete 5
                            try {
                                Stop-VM -Name $n -Force -WarningAction SilentlyContinue -ErrorAction Stop
                            }
                            catch {
                                Write-PrepLog "[STOP] Stop-VM request failed: $($_.Exception.Message) - waiting for guest anyway"
                            }
                            while ((Get-VM -Name $n -ErrorAction SilentlyContinue).State -ne 'Off') {
                                if (((Get-Date) - $startedAt).TotalSeconds -gt $timeoutSec) {
                                    Write-PrepLog "[STOP] Graceful shutdown timeout exceeded; forcing TurnOff"
                                    Write-Progress -Activity "Prep $n" -Status 'Force turn-off (timeout)' -PercentComplete 30
                                    Stop-VM -Name $n -TurnOff -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                                    $forced = $true
                                    Start-Sleep -Seconds 3
                                    break
                                }
                                Write-Progress -Activity "Prep $n" -Status 'Stopping (graceful)' -PercentComplete 20
                                Start-Sleep -Seconds 2
                            }
                            Write-PrepLog ("[STOP] VM stopped (forced={0}, elapsed={1:N0}s)" -f $forced, ((Get-Date)-$startedAt).TotalSeconds)
                        } else {
                            Write-PrepLog "[STOP] VM already Off; no shutdown needed"
                        }

                        # --- 2) Merge every checkpoint ---
                        $mergeSkipped = $false
                        $snapshots = @(Get-VMCheckpoint -VMName $n -ErrorAction SilentlyContinue)
                        if ($snapshots.Count -gt 0) {
                            # Pre-flight: confirm we have enough free disk on
                            # the parent VHDX's drive(s) to absorb the AVHDX
                            # chain. Running out mid-merge hangs the merge and
                            # can leave the VHDX chain unbootable.
                            $freeOk = $true
                            if ($commonLoaded -and (Get-Command Test-VMCheckpointMergeFreeSpace -ErrorAction SilentlyContinue)) {
                                try {
                                    $chk = Test-VMCheckpointMergeFreeSpace -VMName $n
                                    if (-not $chk.Ok) {
                                        $freeOk = $false
                                        Write-Output "::LOG::[MERGE-SKIP] Insufficient free disk space: $($chk.Reason)"
                                        Write-Output "::LOG::[MERGE-SKIP] Continuing with compact-only cleanup (no merge); AVHDX leaf will be optimized in place."
                                    }
                                    else {
                                        foreach ($d in $chk.Details) {
                                            Write-Output ("::LOG::[MERGE-CHECK] {0} need={1:N1}GB avail={2:N1}GB" -f $d.Drive, ($d.Required/1GB), ($d.Available/1GB))
                                        }
                                    }
                                } catch {
                                    Write-Output "::LOG::[MERGE-WARN] Free-space check failed: $($_.Exception.Message)"
                                }
                            }
                            if (-not $freeOk) {
                                # Don't bail - we can still run the rest of the
                                # cleanup (delete files, defrag, zero-fill,
                                # Optimize-VHD) against the AVHDX leaf. That
                                # reclaims space inside the differencing disk
                                # even though the merge can't run, and shrinks
                                # the AVHDX so a future run may be able to
                                # merge. Just skip the merge block.
                                $mergeSkipped = $true
                            }

                            # Acquire a cross-process named mutex per drive that
                            # the merge plan flagged for serialization. This
                            # blocks other prep jobs from merging on the same
                            # drive at the same time, preventing the cumulative
                            # AVHDX size from exceeding free disk space.
                            $heldMutexes = @()
                            $vmMergeDrives = @()
                            if (-not $mergeSkipped -and $serializeDrives -and $serializeDrives.Count -gt 0 -and `
                                $chk -and $chk.Details) {
                                foreach ($det in $chk.Details) {
                                    if ($serializeDrives -contains $det.Drive) {
                                        $vmMergeDrives += $det.Drive
                                    }
                                }
                            }
                            foreach ($drv in $vmMergeDrives) {
                                # Drive letter -> mutex name. Local-only naming
                                # is fine since all prep jobs run on this host.
                                $mxName = "MemLabsMerge_$($drv.TrimEnd(':'))"
                                try {
                                    $mx = [System.Threading.Mutex]::new($false, $mxName)
                                    Write-Output "::LOG::[MERGE-WAIT] waiting for drive $drv mutex"
                                    [void]$mx.WaitOne()
                                    Write-Output "::LOG::[MERGE-LOCK] acquired drive $drv mutex"
                                    $heldMutexes += $mx
                                } catch {
                                    Write-Output "::LOG::[MERGE-WARN] failed to acquire $drv mutex: $($_.Exception.Message)"
                                }
                            }

                            try {

                            if (-not $mergeSkipped) {
                            Write-PrepLog "[MERGE] Merging $($snapshots.Count) checkpoint(s)..."
                            $mergeStart = Get-Date
                            $i = 0
                            $vmPath = (Get-VM -Name $n -ErrorAction SilentlyContinue).Path
                            foreach ($snap in $snapshots) {
                                $i++
                                Write-Progress -Activity "Prep $n" -Status "Merging $i/$($snapshots.Count): $($snap.Name)" -PercentComplete (40 + (50 * $i / $snapshots.Count))
                                Write-PrepLog "[MERGE] $i/$($snapshots.Count): Remove-VMCheckpoint '$($snap.Name)'"
                                try {
                                    Remove-VMCheckpoint -VM $snap.VM -Name $snap.Name -ErrorAction Stop
                                    Write-PrepLog "[MERGE]   ok"
                                }
                                catch {
                                    Write-PrepLog "[MERGE]   Remove-VMCheckpoint failed ($($_.Exception.Message)); trying Remove-VMSnapshot"
                                    try {
                                        Remove-VMSnapshot -VMSnapshot $snap -ErrorAction Stop
                                        Write-PrepLog "[MERGE]   Remove-VMSnapshot ok"
                                    } catch {
                                        Write-PrepLog "[MERGE]   Remove-VMSnapshot also failed: $($_.Exception.Message)"
                                    }
                                }
                                # Sidecar notes file maintained by select-DeleteSnapshotDomain
                                if ($vmPath) {
                                    $notesFile = if ($snap.Name -eq 'MemLabs Snapshot') {
                                        Join-Path $vmPath 'MemLabs.Notes.json'
                                    } else {
                                        Join-Path $vmPath ($snap.Name + '.json')
                                    }
                                    if (Test-Path $notesFile) {
                                        Remove-Item $notesFile -Force -ErrorAction SilentlyContinue
                                    }
                                }
                            }

                            # Wait for AVHDX merges to settle: no VHD path should still
                            # reference .avhdx and no checkpoints should remain.
                            Write-PrepLog "[MERGE] Waiting for AVHDX merges to settle (max 15 min)..."
                            $mergeDeadline = (Get-Date).AddMinutes(15)
                            $lastSettleLog = Get-Date
                            while ((Get-Date) -lt $mergeDeadline) {
                                $hds = @(Get-VMHardDiskDrive -VMName $n -ErrorAction SilentlyContinue)
                                $pendingAvhdx = @($hds | Where-Object { $_.Path -and $_.Path -match '\.avhdx?$' })
                                $pendingChk   = @(Get-VMCheckpoint -VMName $n -ErrorAction SilentlyContinue).Count
                                if ($pendingAvhdx.Count -eq 0 -and $pendingChk -eq 0) { break }
                                if (((Get-Date) - $lastSettleLog).TotalSeconds -ge 30) {
                                    Write-PrepLog ("[MERGE]   still settling: {0} pending AVHDX, {1} pending checkpoint(s)" -f $pendingAvhdx.Count, $pendingChk)
                                    $lastSettleLog = Get-Date
                                }
                                Write-Progress -Activity "Prep $n" -Status 'Waiting for merge to finish' -PercentComplete 92
                                Start-Sleep -Seconds 3
                            }
                            Write-PrepLog ("[MERGE] Settled in {0:N0}s" -f ((Get-Date)-$mergeStart).TotalSeconds)
                            } # if (-not $mergeSkipped)

                            }
                            finally {
                                foreach ($mx in $heldMutexes) {
                                    try { $mx.ReleaseMutex() } catch {}
                                    try { $mx.Dispose() } catch {}
                                }
                                foreach ($drv in $vmMergeDrives) {
                                    Write-Output "::LOG::[MERGE-UNLOCK] released drive $drv mutex"
                                }
                            }
                        }

                        # --- 3) Enumerate VHDs to compact ---
                        Write-Progress -Activity "Prep $n" -Status 'Enumerating VHDs' -PercentComplete 97
                        Write-PrepLog "[ENUMERATE] Listing VHDs attached to VM"
                        $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $disks = [System.Collections.Generic.List[hashtable]]::new()
                        foreach ($hd in (Get-VMHardDiskDrive -VMName $n -ErrorAction SilentlyContinue)) {
                            if ($hd.Path -and $seen.Add($hd.Path) -and (Test-Path $hd.Path)) {
                                $fi = [System.IO.FileInfo]::new($hd.Path)
                                Write-PrepLog ("[ENUMERATE]   {0}  ({1:N1} GB)" -f $hd.Path, ($fi.Length/1GB))
                                $disks.Add(@{
                                    VMName       = $n
                                    Path         = $hd.Path
                                    FileName     = $fi.Name
                                    OriginalSize = [long]$fi.Length
                                })
                            }
                        }
                        Write-PrepLog ("--- Prep done for $n ({0} disk(s), {1:N0}s elapsed) ---" -f $disks.Count, ((Get-Date)-$startedAt).TotalSeconds)
                        Write-Progress -Activity "Prep $n" -Status 'Done' -PercentComplete 100
                        return @{ Ok = $true; Forced = $forced; OnlineCleaned = $onlineCleanRan; WasRunning = $wasRunning; MergeSkipped = $mergeSkipped; Disks = $disks.ToArray() }
                    } -ArgumentList $vm.VMName, $ShutdownTimeoutSec, $WorkerCommonPath, (-not $SkipOnlineClean), $SerializeDrives
                    $vm.Job    = $job
                    $vm.Status = 'Running'
                    [void]$activePrepJobs.Add($vm)
                }
                catch {
                    $vm.Status = 'Failed'
                    $vm.Error  = $_.Exception.Message
                    Add-UiLog ("[PREP-ERR] $($vm.VMName): $($_.Exception.Message)")
                }
            }

            # ----- Reap completed prep jobs -----
            $stillPrep = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($vm in $activePrepJobs) {
                # Drain any phase log lines emitted via Write-Output "::LOG::..."
                # while the job is still running so the UI/log file see them
                # in real time instead of only when the job completes.
                try {
                    $partial = Receive-Job -Job $vm.Job -Keep:$false -ErrorAction SilentlyContinue
                    foreach ($item in @($partial)) {
                        if ($item -is [string] -and $item.StartsWith('::LOG::')) {
                            Add-UiLog ("[PREP] $($vm.VMName) - $($item.Substring(7))")
                        }
                        elseif ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
                            # The job's final result hashtable - stash for the completion branch below.
                            $vm | Add-Member -NotePropertyName _pendingResult -NotePropertyValue $item -Force
                        }
                    }
                } catch {}

                if ($vm.Job.State -eq 'Completed') {
                    # Whatever's still buffered after the Completed transition.
                    try { $rawOut = Receive-Job -Job $vm.Job -ErrorAction Stop } catch { $rawOut = $null }
                    Remove-Job -Job $vm.Job -Force -ErrorAction SilentlyContinue
                    # The prep job may emit "::LOG::..." strings via Write-Output
                    # alongside the final hashtable. Separate them.
                    $result = $null
                    if ($vm.PSObject.Properties['_pendingResult']) {
                        $result = $vm._pendingResult
                        $vm.PSObject.Properties.Remove('_pendingResult')
                    }
                    foreach ($item in @($rawOut)) {
                        if ($item -is [string] -and $item.StartsWith('::LOG::')) {
                            Add-UiLog ("[PREP] $($vm.VMName) - $($item.Substring(7))")
                        }
                        elseif ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
                            $result = $item
                        }
                    }
                    if ($result -and $result.Ok) {
                        $vm.Status = 'Completed'
                        $vm.Forced = [bool]$result.Forced
                        $vm.WasRunning = [bool]$result.WasRunning
                        if ($result.MergeSkipped) {
                            $vm.MergeSkipped = $true
                            Add-UiLog ("[PREP-WARN] $($vm.VMName): merge skipped (insufficient free space) - compacting AVHDX leaf only")
                        }
                        if ($result.OnlineCleaned) {
                            Add-UiLog ("[PREP-INFO] $($vm.VMName): online cleanup ran")
                        }
                        if ($vm.Forced) {
                            Add-UiLog ("[PREP-WARN] $($vm.VMName): force turned-off (graceful timeout)")
                        }
                        $diskCount = if ($result.Disks) { $result.Disks.Count } else { 0 }
                        Add-UiLog ("[PREP-DONE] $($vm.VMName) - $diskCount VHD(s) found")
                        # Sort this VM's disks largest first locally; the queue is FIFO
                        # but interleaving by VM means largest-first per-VM is fine.
                        $sorted = @($result.Disks | Sort-Object { [long]$_.OriginalSize } -Descending)
                        foreach ($d in $sorted) {
                            $diskObj = [PSCustomObject]@{
                                VMName       = $d.VMName
                                Path         = $d.Path
                                FileName     = $d.FileName
                                OriginalSize = [long]$d.OriginalSize
                                Job          = $null
                                NewSize      = $null
                                Status       = 'Pending'
                                Error        = $null
                                StartTime    = $null
                                EndTime      = $null
                            }
                            $diskInfoList.Add($diskObj)
                            $diskQueue.Enqueue($diskObj)
                        }
                    }
                    else {
                        $vm.Status = 'Failed'
                        $vm.Error  = if ($result -and $result.Error) { $result.Error } else { 'Prep job returned no result' }
                        Add-UiLog ("[PREP-FAIL] $($vm.VMName): $($vm.Error)")
                    }
                }
                elseif ($vm.Job.State -eq 'Failed') {
                    $vm.Status = 'Failed'
                    $reason = $vm.Job.ChildJobs[0].JobStateInfo.Reason
                    $vm.Error = if ($reason) { $reason.Message } else { 'Unknown prep error' }
                    Add-UiLog ("[PREP-FAIL] $($vm.VMName): $($vm.Error)")
                    Remove-Job -Job $vm.Job -Force -ErrorAction SilentlyContinue
                }
                else {
                    [void]$stillPrep.Add($vm)
                }
            }
            $activePrepJobs = $stillPrep

            # ----- Launch compact jobs -----
            while ($activeJobs.Count -lt $MaxConcurrentJobs -and $diskQueue.Count -gt 0) {
                $disk = $diskQueue.Dequeue()
                Add-UiLog ("[START] $($disk.VMName) - $($disk.FileName)")
                try {
                    $VhdPath      = $disk.Path
                    $OptMode      = $Mode
                    $DoDefrag     = -not $SkipDefrag
                    $DoOfflineClean = -not $SkipOfflineClean
                    $DoZeroFill   = -not $SkipZeroFill
                    $job = Start-Job -ScriptBlock {
                        param($p, $m, $defrag, $offlineClean, $zeroFill)
                        # Do NOT set $ProgressPreference = 'SilentlyContinue'
                        # here - it suppresses Write-Progress records (both
                        # ours and Optimize-VHD's native progress) so the
                        # parent UI's Get-JobProgress always reads 0%. We
                        # want those records to flow into
                        # $Job.ChildJobs[0].Progress so the UI bar moves.
                        $vhdName = [System.IO.Path]::GetFileName($p)
                        function Write-PhaseLog($msg) { Write-Output "::LOG::$vhdName : $msg" }

                        # --- Mount-once for offline-clean + defrag + zero-fill ---
                        # Optimize-VHD only reclaims blocks that contain zeros.
                        # So while the VHDX is mounted we:
                        #   a) delete known junk dirs (offline)
                        #   b) run DISM /Image:<letter>:\ /Cleanup-Image
                        #   c) defrag + Optimize-Volume (Defrag/SlabConsolidate/ReTrim)
                        #   d) zero-fill remaining free space
                        # then dismount and Optimize-VHD against the parent.
                        $needMount = $offlineClean -or $defrag -or $zeroFill
                        $mounted = $false
                        if ($needMount) {
                            try {
                                Write-PhaseLog 'Mounting VHDX'
                                Write-Progress -Activity "Compact $p" -Status 'Mounting' -PercentComplete 2
                                $mountResult = Mount-VHD -Path $p -PassThru -ErrorAction Stop
                                $mounted = $true
                                Start-Sleep -Seconds 2

                                # Inside a Start-Job the volume manager often
                                # does NOT auto-assign drive letters to a
                                # freshly mounted VHDX, so the defrag /
                                # cleanup / zero-fill loops would silently
                                # iterate zero volumes. Force a drive letter
                                # on each data partition that doesn't have one.
                                $disk = $mountResult | Get-Disk
                                foreach ($part in ($disk | Get-Partition)) {
                                    if ($part.Type -in @('Reserved','Recovery','System')) { continue }
                                    if ([string]::IsNullOrEmpty($part.DriveLetter)) {
                                        try {
                                            Add-PartitionAccessPath -DiskNumber $part.DiskNumber `
                                                -PartitionNumber $part.PartitionNumber `
                                                -AssignDriveLetter -ErrorAction Stop
                                        } catch {
                                            # best-effort; some partitions just won't take a letter
                                        }
                                    }
                                }
                                # Re-read partitions/volumes after the
                                # access-path assignment above.
                                Start-Sleep -Seconds 1
                                $volumes = @($disk | Get-Partition | Get-Volume |
                                    Where-Object { $_.DriveLetter })

                                Write-Progress -Activity "Compact $p" -Status "Mounted - $($volumes.Count) volume(s): $((($volumes | ForEach-Object { $_.DriveLetter + ':' }) -join ' '))" -PercentComplete 3
                                Write-PhaseLog ("Mounted - {0} volume(s): {1}" -f $volumes.Count, ((($volumes | ForEach-Object { $_.DriveLetter + ':' }) -join ' ')))
                                if ($volumes.Count -eq 0) {
                                    Write-Warning "No volumes with drive letters found on $p; skipping offline clean / defrag / zero-fill."
                                }

                                # --- (a) + (b) Offline cleanup pass ---
                                if ($offlineClean) {
                                    $vi = 0
                                    foreach ($vol in $volumes) {
                                        $vi++
                                        $letter = $vol.DriveLetter
                                        $root   = "${letter}:"
                                        Write-PhaseLog "Offline clean ${letter}:"
                                        Write-Progress -Activity "Compact $p" -Status "Offline clean ${letter}:" -PercentComplete (3 + (4 * $vi / [Math]::Max($volumes.Count, 1)))

                                        $purge = @(
                                            "$root\Windows\SoftwareDistribution\Download\*",
                                            "$root\Windows\Temp\*",
                                            "$root\Windows\Logs\CBS\*",
                                            "$root\Windows\Logs\DISM\*",
                                            "$root\Windows\Prefetch\*",
                                            "$root\Windows\Minidump\*",
                                            "$root\Windows\Memory.dmp",
                                            "$root\inetpub\logs\LogFiles\*",
                                            "$root\ProgramData\Microsoft\Windows\WER\*",
                                            "$root\ProgramData\Microsoft\Windows\WindowsUpdate\Log\*",
                                            "$root\ProgramData\USOShared\Logs\*",
                                            "$root\Users\*\AppData\Local\Temp\*",
                                            "$root\Users\*\AppData\Local\Microsoft\Windows\WER\*",
                                            "$root\Users\*\AppData\Local\Microsoft\Windows\INetCache\*",
                                            "$root\Users\*\AppData\Local\Microsoft\Windows\WebCache\*",
                                            "$root\`$Recycle.Bin\*",
                                            # Additional Windows caches and logs
                                            "$root\Windows\Installer\`$PatchCache`$\*",
                                            "$root\Windows\ccmcache\*",
                                            "$root\Windows\ccmsetup\Logs\*",
                                            "$root\Windows\System32\LogFiles\*",
                                            "$root\Windows\Panther\*",
                                            "$root\PerfLogs\*",
                                            "$root\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache\*",
                                            "$root\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*",
                                            # hiberfil.sys (often multi-GB)
                                            "$root\hiberfil.sys",
                                            # pagefile.sys can also be large; OS recreates on boot
                                            "$root\pagefile.sys",
                                            "$root\swapfile.sys",
                                            # MemLabs install leftovers
                                            "$root\CMCB",
                                            "$root\CMTP",
                                            "$root\temp\Upgrade2025",
                                            "$root\temp\*.msi",
                                            "$root\temp\*.exe",
                                            "$root\temp\*.cab",
                                            "$root\temp\*.zip",
                                            "$root\temp\*.iso",
                                            "$root\temp\adksetup*",
                                            "$root\temp\WinPE*",
                                            "$root\temp\sql",
                                            "$root\temp\sql_CU",
                                            "$root\temp\SQLServer*",
                                            "$root\temp\DSC",
                                            "$root\temp\staging"
                                        )
                                        foreach ($pat in $purge) {
                                            try { Remove-Item -Path $pat -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                                        }

                                        # Age-based pruning - trim log dirs
                                        # rather than wiping wholesale so any
                                        # recent activity survives. Mirrors
                                        # the online cleanup list above.
                                        $offlineLogAgeDays = 10
                                        $offlineCutoff = (Get-Date).AddDays(-$offlineLogAgeDays)
                                        $offlineAgeRoots = @(
                                            @{ Path = "$root\inetpub\logs\LogFiles";          Filter = '*' }
                                            @{ Path = "$root\inetpub\logs\FailedReqLogFiles"; Filter = '*' }
                                            @{ Path = "$root\inetpub\temp\IIS Temporary Compressed Files"; Filter = '*' }
                                            @{ Path = "$root\Windows\Logs";                   Filter = '*.log' }
                                            @{ Path = "$root\Windows\Logs";                   Filter = '*.etl' }
                                            @{ Path = "$root\Windows\Logs\WindowsUpdate";     Filter = '*' }
                                            @{ Path = "$root\Windows\Logs\waasmedic";         Filter = '*' }
                                            @{ Path = "$root\Windows\Logs\NetSetup";          Filter = '*' }
                                            @{ Path = "$root\Windows\Logs\MoSetup";           Filter = '*' }
                                            @{ Path = "$root\Windows\System32\LogFiles\HTTPERR"; Filter = '*' }
                                            @{ Path = "$root\Windows\System32\LogFiles\W3SVC";   Filter = '*' }
                                            @{ Path = "$root\Windows\System32\Winevt\Logs";   Filter = '*Archive*' }
                                            @{ Path = "$root\Windows\CCM\Logs";               Filter = '*.lo_' }
                                            @{ Path = "$root\Windows\CCM\Logs";               Filter = '*.log' }
                                            @{ Path = "$root\Windows\ccmsetup\Logs";          Filter = '*' }
                                            @{ Path = "$root\Program Files\Microsoft Configuration Manager\Logs"; Filter = '*.lo_' }
                                            @{ Path = "$root\Program Files\Microsoft Configuration Manager\Logs"; Filter = '*.log' }
                                            @{ Path = "$root\Program Files\SMS_CCM\Logs";     Filter = '*' }
                                            @{ Path = "$root\Program Files\Update Services\LogFiles"; Filter = '*.log' }
                                            @{ Path = "$root\Program Files\Microsoft SQL Server"; Filter = 'ERRORLOG.*' }
                                            @{ Path = "$root\Program Files\Microsoft SQL Server"; Filter = 'SQLAGENT.*' }
                                            # NOTE: deliberately NOT pruning $root\Users\**\*.dmp
                                            # here - WER dumps already get wiped wholesale above;
                                            # everything else is presumed to be a user-collected
                                            # debug capture worth keeping.
                                        )
                                        foreach ($r in $offlineAgeRoots) {
                                            try {
                                                if (-not (Test-Path -LiteralPath $r.Path -ErrorAction SilentlyContinue)) { continue }
                                                $stale = Get-ChildItem -Path $r.Path -Filter $r.Filter -Recurse -File -Force -ErrorAction SilentlyContinue |
                                                         Where-Object { $_.LastWriteTime -lt $offlineCutoff }
                                                if (-not $stale) { continue }
                                                $bytes = ($stale | Measure-Object -Sum -Property Length).Sum
                                                $count = ($stale | Measure-Object).Count
                                                $stale | Remove-Item -Force -ErrorAction SilentlyContinue
                                                if ($bytes -gt 0) {
                                                    Write-PhaseLog ("Pruned >{0}d {1}\{2} : {3} file(s) {4:N1} MB" -f $offlineLogAgeDays, $r.Path, $r.Filter, $count, ($bytes/1MB))
                                                }
                                            } catch {}
                                        }

                                        # Offline DISM only makes sense on the system volume
                                        if (Test-Path "$root\Windows\System32") {
                                            Write-PhaseLog "DISM /Cleanup-Image ${letter}:"
                                            try {
                                                & dism.exe /Image:"$root\" /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet | Out-Null
                                            } catch {}
                                            try {
                                                & dism.exe /Image:"$root\" /Cleanup-Image /SPSuperseded /Quiet | Out-Null
                                            } catch {}
                                        }
                                    }
                                }

                                # --- (c) Defrag pass ---
                                if ($defrag) {
                                    $vi = 0
                                    foreach ($vol in $volumes) {
                                        $vi++
                                        $letter = $vol.DriveLetter
                                        Write-PhaseLog "Defrag ${letter}: starting"
                                        Write-Progress -Activity "Compact $p" -Status "Defrag ${letter}: ($vi/$($volumes.Count))" -PercentComplete (8 + (10 * $vi / [Math]::Max($volumes.Count, 1)))
                                        foreach ($defragArgs in @('/h /x', '/h /k /l', '/h /x', '/h /k')) {
                                            Write-PhaseLog "defrag ${letter}: $defragArgs"
                                            $argList = $defragArgs -split '\s+'
                                            try {
                                                $out = & defrag.exe "${letter}:" @argList 2>&1
                                                foreach ($ln in @($out)) {
                                                    $t = ($ln | Out-String).Trim()
                                                    if ($t) {
                                                        foreach ($sub in ($t -split "`r?`n")) {
                                                            $sub = $sub.Trim()
                                                            if ($sub) { Write-PhaseLog "  defrag> $sub" }
                                                        }
                                                    }
                                                }
                                            } catch {
                                                Write-PhaseLog "  defrag ERROR: $($_.Exception.Message)"
                                            }
                                        }
                                        try { Optimize-Volume -DriveLetter $letter -Defrag         -ErrorAction Stop | Out-Null; Write-PhaseLog "  Optimize-Volume ${letter}: Defrag ok" } catch { Write-PhaseLog "  Optimize-Volume ${letter}: Defrag failed: $($_.Exception.Message)" }
                                        try { Optimize-Volume -DriveLetter $letter -SlabConsolidate -ErrorAction Stop | Out-Null; Write-PhaseLog "  Optimize-Volume ${letter}: SlabConsolidate ok" } catch { Write-PhaseLog "  Optimize-Volume ${letter}: SlabConsolidate failed: $($_.Exception.Message)" }
                                        try { Optimize-Volume -DriveLetter $letter -ReTrim         -ErrorAction Stop | Out-Null; Write-PhaseLog "  Optimize-Volume ${letter}: ReTrim ok" } catch { Write-PhaseLog "  Optimize-Volume ${letter}: ReTrim failed: $($_.Exception.Message)" }
                                        Write-PhaseLog "Defrag ${letter}: complete"
                                    }
                                }

                                # --- (d) Zero-fill free space ---
                                # Optimize-VHD only reclaims zeroed blocks. Without
                                # this, deletes above won't actually shrink the VHDX.
                                # Native fallback: write a temp file of zeros until
                                # the disk fills, then delete it.
                                if ($zeroFill) {
                                    $vi = 0
                                    foreach ($vol in $volumes) {
                                        $vi++
                                        $letter = $vol.DriveLetter
                                        $zfPath = "${letter}:\zero.tmp"
                                        Write-PhaseLog "Zero-fill ${letter}:"
                                        Write-Progress -Activity "Compact $p" -Status "Zero-fill ${letter}:" -PercentComplete (20 + (5 * $vi / [Math]::Max($volumes.Count, 1)))
                                        try {
                                            $stream = [System.IO.File]::Create($zfPath)
                                            try {
                                                $buf = New-Object byte[] (8MB)
                                                while ($true) {
                                                    try {
                                                        $stream.Write($buf, 0, $buf.Length)
                                                    }
                                                    catch [System.IO.IOException] {
                                                        # disk full - expected
                                                        break
                                                    }
                                                }
                                            }
                                            finally {
                                                $stream.Dispose()
                                            }
                                        }
                                        catch {
                                            # best-effort; ignore
                                        }
                                        finally {
                                            if (Test-Path $zfPath) {
                                                Remove-Item -Path $zfPath -Force -ErrorAction SilentlyContinue
                                            }
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Warning "Mount/clean step failed for ${p}: $($_.Exception.Message)"
                            }
                            finally {
                                if ($mounted) {
                                    Write-PhaseLog 'Dismounting'
                                    Write-Progress -Activity "Compact $p" -Status 'Dismounting' -PercentComplete 27
                                    Dismount-VHD -Path $p -ErrorAction SilentlyContinue
                                    Start-Sleep -Seconds 3
                                }
                            }
                        }

                        # --- Final Optimize-VHD on the parent (no longer mounted) ---
                        $preOptSize = try { (Get-Item -LiteralPath $p -ErrorAction Stop).Length } catch { 0 }
                        Write-PhaseLog ("Optimize-VHD ($m) starting (current size: {0:N1} GB)" -f ($preOptSize/1GB))
                        Write-Progress -Activity "Compact $p" -Status "Optimize-VHD ($m)" -PercentComplete 30
                        $optStart = Get-Date
                        try {
                            Optimize-VHD -Path $p -Mode $m -ErrorAction Stop
                            $postOptSize = try { (Get-Item -LiteralPath $p -ErrorAction Stop).Length } catch { 0 }
                            $reclaimed = $preOptSize - $postOptSize
                            Write-PhaseLog ("Optimize-VHD complete in {0:N0}s; size {1:N1} GB -> {2:N1} GB (reclaimed {3:N1} GB)" -f ((Get-Date)-$optStart).TotalSeconds, ($preOptSize/1GB), ($postOptSize/1GB), ($reclaimed/1GB))
                        } catch {
                            Write-PhaseLog "Optimize-VHD FAILED: $($_.Exception.Message)"
                            throw
                        }
                        Write-Progress -Activity "Compact $p" -Status 'Done' -PercentComplete 100
                    } -ArgumentList $VhdPath, $OptMode, $DoDefrag, $DoOfflineClean, $DoZeroFill
                    $disk.Job       = $job
                    $disk.Status    = 'Running'
                    $disk.StartTime = Get-Date
                    [void]$activeJobs.Add($disk)
                }
                catch {
                    $disk.Status = 'Failed'
                    $disk.Error  = $_.Exception.Message
                    Add-UiLog ("[ERROR] $($disk.FileName): $($_.Exception.Message)")
                }
            }

            # ----- Reap completed compact jobs -----
            $stillRunning = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($disk in $activeJobs) {
                # Drain any phase log lines emitted via Write-Output "::LOG::..."
                try {
                    $out = Receive-Job -Job $disk.Job -Keep:$false -ErrorAction SilentlyContinue
                    foreach ($line in @($out)) {
                        if ($line -is [string] -and $line.StartsWith('::LOG::')) {
                            Add-UiLog ("[PHASE] $($disk.VMName) - $($line.Substring(7))")
                        }
                    }
                } catch {}

                if ($disk.Job.State -eq 'Completed') {
                    $disk.Status  = 'Completed'
                    $disk.EndTime = Get-Date
                    $NewFileSize = Get-VhdFileSize -Path $disk.Path
                    $disk.NewSize = if ($NewFileSize) { $NewFileSize } else { $disk.OriginalSize }
                    $saved    = $disk.OriginalSize - $disk.NewSize
                    $savedPct = if ($disk.OriginalSize -gt 0) { [math]::Round(($saved / $disk.OriginalSize) * 100, 1) } else { 0 }
                    Add-UiLog ("[DONE]  $($disk.VMName) - $($disk.FileName): $(Format-Size $disk.OriginalSize) -> $(Format-Size $disk.NewSize) (Saved: $(Format-Size $saved), $savedPct%)")
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                }
                elseif ($disk.Job.State -eq 'Failed') {
                    $disk.Status  = 'Failed'
                    $disk.EndTime = Get-Date
                    $reason = $disk.Job.ChildJobs[0].JobStateInfo.Reason
                    $disk.Error = if ($reason) { $reason.Message } else { ($disk.Job.ChildJobs[0].Error | Out-String).Trim() }
                    if (-not $disk.Error) { $disk.Error = 'Unknown error' }
                    Add-UiLog ("[FAIL]  $($disk.VMName) - $($disk.FileName): $($disk.Error)")
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                }
                else {
                    [void]$stillRunning.Add($disk)
                }
            }
            $activeJobs = $stillRunning

            Update-Progress -DiskList $diskInfoList -ActiveJobs $activeJobs -ActivePrepJobs $activePrepJobs -StartTime $startTime

            if ($activePrepJobs.Count -gt 0 -or $activeJobs.Count -gt 0 -or
                $prepQueue.Count -gt 0 -or $diskQueue.Count -gt 0) {
                Start-Sleep -Milliseconds 400
            }
        }

        Update-Progress -DiskList $diskInfoList -ActiveJobs $activeJobs -ActivePrepJobs $activePrepJobs -StartTime $startTime
    }
    catch {
        # interrupted (window closed or error)
    }
    finally {
        # Only kill running jobs on a true force-close. On a graceful
        # StopRequested drain, both lists are already empty - the main loop
        # waits for activePrepJobs+activeJobs to reach zero before breaking.
        # Killing snapshot-merge or Optimize-VHD jobs while they're still
        # running is what we're trying to avoid in the first place.
        $forceKill = $UiSync.ForceClose -or ($UiSync.WindowClosed -and -not $UiSync.StopRequested)
        if ($forceKill) {
            foreach ($vm in $activePrepJobs) {
                if ($vm.Job) {
                    Stop-Job  -Job $vm.Job -ErrorAction SilentlyContinue
                    Remove-Job -Job $vm.Job -Force -ErrorAction SilentlyContinue
                    $vm.Status = 'Cancelled'
                }
            }
            foreach ($disk in $activeJobs) {
                if ($disk.Job) {
                    Stop-Job  -Job $disk.Job -ErrorAction SilentlyContinue
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                    $disk.Status = 'Cancelled'
                }
            }
            # We just killed jobs that may have been holding VHDs mounted
            # or in the middle of a snapshot merge. Dismount any leftover
            # mounted VHDs immediately so the host doesn't keep them open.
            try { Invoke-CompactCleanup -Reason 'ForceClose' } catch {}
        }
    }

        # --- Retry pass: deferred VMs may now fit thanks to space freed by Optimize-VHD ---
        $pass++
        $deferred = @($vmInfoList | Where-Object { $_.Status -eq 'Deferred' })
        if ($deferred.Count -gt 0 -and $pass -le $maxRetryPasses -and -not $UiSync.WindowClosed -and -not $UiSync.StopRequested) {
            $defNames = @($deferred | ForEach-Object VMName)
            Add-UiLog ('')
            Add-UiLog ("--- Retry pass $pass for $($deferred.Count) deferred VM(s): $($defNames -join ', ') ---")
            $planResult = Invoke-MergePlan -Names $defNames -PassNumber $pass
            $SerializeDrives = $planResult.SerializeDrives
            foreach ($vm in $deferred) {
                if ($planResult.FailingVMs -contains $vm.VMName) {
                    # Still doesn't fit even after others finished compacting.
                    $vm.PreFlightFail = $true
                    $vm.Status = 'Failed'
                    Add-UiLog ("[PREP-FAIL] $($vm.VMName): still insufficient free space after retry pass $pass")
                } else {
                    # Now fits - reset and requeue.
                    $vm.PreFlightFail = $false
                    $vm.Status = 'Pending'
                    $vm.Error  = $null
                    $vm.Job    = $null
                    $prepQueue.Enqueue($vm)
                    $shouldRetry = $true
                    Add-UiLog ("[PREP-RETRY] $($vm.VMName) requeued (pass $pass)")
                }
            }
        }
        elseif ($deferred.Count -gt 0 -and -not $UiSync.WindowClosed -and -not $UiSync.StopRequested) {
            # Out of retry budget - requeue the remaining deferred VMs WITHOUT
            # a pre-flight fail. The prep job's per-VM free-space check will
            # still fail, but the job is tolerant of that: it skips the merge
            # block and falls through to enumerate the AVHDX leaves so the
            # compact phase can still run defrag/zero-fill/Optimize-VHD against
            # them. That reclaims slack space inside the AVHDX even though
            # the merge can't happen, and shrinks the leaf so a future
            # invocation has a better chance of merging.
            foreach ($vm in $deferred) {
                $vm.PreFlightFail = $false
                $vm.Status = 'Pending'
                $vm.Error  = $null
                $vm.Job    = $null
                $prepQueue.Enqueue($vm)
                $shouldRetry = $true
                Add-UiLog ("[PREP-RETRY-NOMERGE] $($vm.VMName) requeued without merge (retry budget exhausted; compact-only pass)")
            }
        }
        elseif ($deferred.Count -gt 0) {
            # Window closed mid-retry - mark deferred VMs failed.
            foreach ($vm in $deferred) {
                $vm.Status = 'Failed'
                Add-UiLog ("[PREP-FAIL] $($vm.VMName): $($vm.Error) (cancelled)")
            }
        }
    } while ($shouldRetry)

    # --- Auto-restart VMs that were Running at the start ---
    # Order matters: DCs first (other VMs need AD), then file servers (some
    # SQL/CM roles depend on remote storage), then SQL, then CAS, then PRI,
    # then everything else. We reuse Get-CriticalVMs + Invoke-SmartStartVMs
    # from Common.GenConfig.ps1 (dot-sourced by Common.ps1 in this worker)
    # which is the same machinery used elsewhere for clean starts.
    $toRestart = @($vmInfoList | Where-Object { $_.WasRunning -and $_.Status -eq 'Completed' })
    if ($toRestart.Count -gt 0) {
        $UiSync.StatusText = "Restarting $($toRestart.Count) VM(s) in critical-order..."
        Add-UiLog ('')
        Add-UiLog ("--- Restarting $($toRestart.Count) VM(s) (DC -> FS -> SQL -> CAS -> PRI -> others) ---")

        # Group VMs by domain so a multi-domain compaction still gets
        # domain-aware ordering. In the common (single-domain) case this
        # loops exactly once.
        $byDomain = @{}
        foreach ($r in $toRestart) {
            $note = $null
            try { $note = Get-VMNote -VMName $r.VMName -ErrorAction SilentlyContinue } catch {}
            $dom = if ($note -and $note.domain) { $note.domain } else { '<unknown>' }
            if (-not $byDomain.ContainsKey($dom)) { $byDomain[$dom] = @() }
            $byDomain[$dom] += $r.VMName
        }

        $smartStartOk = $false
        if (Get-Command Get-CriticalVMs -ErrorAction SilentlyContinue) {
            foreach ($dom in $byDomain.Keys) {
                $names = $byDomain[$dom]
                if ($dom -eq '<unknown>') {
                    Add-UiLog ("[RESTART-WARN] No domain info for: $($names -join ', '); falling back to Start-VM")
                    continue
                }
                try {
                    Add-UiLog ("[RESTART] Domain '$dom' - sequencing $($names.Count) VM(s)")
                    $critList = Get-CriticalVMs -domain $dom -vmNames $names
                    Invoke-SmartStartVMs -CritList $critList -quiet $true
                    $smartStartOk = $true
                    foreach ($n in $names) {
                        Add-UiLog ("[RESTART] $n - start sequenced")
                    }
                }
                catch {
                    Add-UiLog ("[RESTART-ERR] Domain '$dom' smart-start failed: $($_.Exception.Message)")
                }
            }
        }

        # Fallback: any VMs we couldn't sequence (no domain info, or
        # Get-CriticalVMs not available) get a plain Start-VM.
        $unhandled = $toRestart | Where-Object {
            $note = $null
            try { $note = Get-VMNote -VMName $_.VMName -ErrorAction SilentlyContinue } catch {}
            -not ($note -and $note.domain) -or -not $smartStartOk
        }
        if (-not $smartStartOk) {
            foreach ($r in $toRestart) {
                try {
                    Start-VM -Name $r.VMName -ErrorAction Stop
                    Add-UiLog ("[RESTART] $($r.VMName) - start command issued (fallback)")
                }
                catch {
                    Add-UiLog ("[RESTART-FAIL] $($r.VMName): $($_.Exception.Message)")
                }
            }
        }
        elseif ($unhandled) {
            foreach ($r in $unhandled) {
                try {
                    Start-VM -Name $r.VMName -ErrorAction Stop
                    Add-UiLog ("[RESTART] $($r.VMName) - start command issued (no domain)")
                }
                catch {
                    Add-UiLog ("[RESTART-FAIL] $($r.VMName): $($_.Exception.Message)")
                }
            }
        }
    }

    # --- Final summary into the UI log ---
    $duration    = (Get-Date) - $startTime
    $successful  = @($diskInfoList | Where-Object { $_.Status -eq 'Completed' })
    $failed      = @($diskInfoList | Where-Object { $_.Status -eq 'Failed' })
    $cancelled   = @($diskInfoList | Where-Object { $_.Status -eq 'Cancelled' })
    $prepFailed  = @($vmInfoList   | Where-Object { $_.Status -eq 'Failed' })
    $forcedStops = @($vmInfoList   | Where-Object { $_.Forced })

    # Helpers for the summary table
    function _FmtDuration([TimeSpan]$ts) {
        if ($null -eq $ts -or $ts.TotalSeconds -lt 0) { return '       -' }
        if ($ts.TotalHours -ge 1) { return ('{0:0}h{1:00}m{2:00}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
        if ($ts.TotalMinutes -ge 1) { return ('   {0:00}m{1:00}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
        return ('      {0:00}s' -f [int]$ts.TotalSeconds)
    }

    Add-UiLog ('')
    Add-UiLog ('=====================================================================================================')
    Add-UiLog ('  Optimization Complete')
    Add-UiLog ('=====================================================================================================')
    Add-UiLog ("  Domain   : $DomainLabel")
    Add-UiLog ("  Mode     : $Mode    MaxConcurrent: $MaxConcurrentJobs")
    Add-UiLog ("  Duration : $($duration.ToString('hh\:mm\:ss'))")
    Add-UiLog ("  Disks    : $($successful.Count) completed, $($failed.Count) failed, $($cancelled.Count) cancelled")
    Add-UiLog ("  VMs      : $($vmInfoList.Count) total, $($prepFailed.Count) prep-failed, $($forcedStops.Count) force-stopped")
    Add-UiLog ('')

    # -------- Per-disk table --------
    # Column widths chosen so a typical lab fits in the 100-char UI log box.
    $hdrFmt = '  {0,-18} {1,-32} {2,12} {3,12} {4,12} {5,7} {6,9}  {7}'
    $rowFmt = $hdrFmt
    Add-UiLog ('--- Per-disk results -----------------------------------------------------------------------------')
    Add-UiLog ($hdrFmt -f 'VM', 'Disk', 'Before', 'After', 'Saved', 'Saved%', 'Duration', 'Status')
    Add-UiLog ($hdrFmt -f ('-'*18), ('-'*32), ('-'*12), ('-'*12), ('-'*12), ('-'*7), ('-'*9), ('-'*8))

    # Sort: completed (largest savings first), then failed, then cancelled.
    $rankOrder = @{ 'Completed' = 0; 'Failed' = 1; 'Cancelled' = 2 }
    $rows = $diskInfoList | Sort-Object @{Expression = { $rankOrder[$_.Status] }; Ascending = $true }, `
                                        @{Expression = { if ($_.Status -eq 'Completed' -and $_.OriginalSize -gt 0) { -($_.OriginalSize - [long]$_.NewSize) } else { 0 } }; Ascending = $true }, `
                                        VMName, FileName

    foreach ($d in $rows) {
        $vmName   = if ($d.VMName)   { $d.VMName }   else { '' }
        $fileName = if ($d.FileName) { $d.FileName } else { '' }
        if ($vmName.Length   -gt 18) { $vmName   = $vmName.Substring(0,17) + '…' }
        if ($fileName.Length -gt 32) { $fileName = $fileName.Substring(0,31) + '…' }

        if ($d.Status -eq 'Completed' -and $d.NewSize -ne $null) {
            $before = Format-Size $d.OriginalSize
            $after  = Format-Size ([long]$d.NewSize)
            $saved  = $d.OriginalSize - [long]$d.NewSize
            $savedStr = Format-Size $saved
            $pct    = if ($d.OriginalSize -gt 0) { ('{0,5:N1}%' -f (($saved / $d.OriginalSize) * 100)) } else { '    -' }
        } else {
            $before = Format-Size $d.OriginalSize
            $after  = '       -'
            $savedStr = '       -'
            $pct    = '     -'
        }

        $dur = if ($d.StartTime -and $d.EndTime) { _FmtDuration ($d.EndTime - $d.StartTime) } else { '       -' }

        $status = $d.Status
        if ($d.Status -eq 'Failed' -and $d.Error) {
            $errShort = ($d.Error -replace "`r?`n", ' ').Trim()
            if ($errShort.Length -gt 40) { $errShort = $errShort.Substring(0,39) + '…' }
            $status = "Failed: $errShort"
        }
        Add-UiLog ($rowFmt -f $vmName, $fileName, $before, $after, $savedStr, $pct, $dur, $status)
    }

    # -------- Totals --------
    if ($successful.Count -gt 0 -or $failed.Count -gt 0) {
        Add-UiLog ($hdrFmt -f ('-'*18), ('-'*32), ('-'*12), ('-'*12), ('-'*12), ('-'*7), ('-'*9), ('-'*8))
        $totalOld   = ($diskInfoList | Measure-Object -Property OriginalSize -Sum).Sum
        $sucOld     = ($successful   | Measure-Object -Property OriginalSize -Sum).Sum
        $sucNew     = ($successful   | Measure-Object -Property NewSize      -Sum).Sum
        $totalSaved = $sucOld - $sucNew
        # Post-compact total = (sum of all original sizes) - savings on the successful ones.
        $totalAfter = $totalOld - $totalSaved
        $totalPct   = if ($sucOld -gt 0) { ('{0,5:N1}%' -f (($totalSaved / $sucOld) * 100)) } else { '     -' }
        Add-UiLog ($rowFmt -f 'TOTAL', "($($diskInfoList.Count) disk(s))",
            (Format-Size $totalOld), (Format-Size $totalAfter), (Format-Size $totalSaved),
            $totalPct, (_FmtDuration $duration), '')
    }

    # -------- VM-level issues --------
    if ($forcedStops.Count -gt 0) {
        Add-UiLog ('')
        Add-UiLog ('--- Force turned-off (graceful shutdown timed out) ---')
        foreach ($f in $forcedStops) { Add-UiLog ("  $($f.VMName)") }
    }
    if ($prepFailed.Count -gt 0) {
        Add-UiLog ('')
        Add-UiLog ('--- Prep failed (VM was not compacted) ---')
        foreach ($f in $prepFailed) { Add-UiLog ("  $($f.VMName): $($f.Error)") }
    }
    if ($cancelled.Count -gt 0) {
        Add-UiLog ('')
        Add-UiLog ('--- Cancelled ---')
        foreach ($c in $cancelled) { Add-UiLog ("  $($c.VMName) - $($c.FileName)") }
    }

    Add-UiLog ('=====================================================================================================')

    if ($script:CompactLogPath) {
        Add-UiLog ("Log file: $script:CompactLogPath")
    }

    $UiSync.OverallPercent = 100
    $UiSync.StatusText     = "All done - $($successful.Count) completed, $($failed.Count) failed, $($cancelled.Count) cancelled, $($forcedStops.Count) forced"
    $UiSync.Jobs           = [System.Collections.ArrayList]::new()

    # Window stays open for log review - wait until the user closes it, then clean up
    while (-not $UiSync.WindowClosed) { Start-Sleep -Milliseconds 500 }

    # Final safety net: by this point everything *should* be dismounted
    # (either the jobs finished cleanly and ran their own dismount, or
    # the main-loop finally ran Invoke-CompactCleanup). Re-run it anyway -
    # it's idempotent and cheap, and it guarantees no VHDX is left
    # attached to the host once this script exits.
    try { Invoke-CompactCleanup -Reason 'WorkerExit' } catch {}

    try { $uiPipeline.EndInvoke($uiHandle) } catch {}
    $uiPipeline.Dispose()
    $uiRunspace.Close()
    $uiRunspace.Dispose()
    return
}

# ========================= NORMAL (INTERACTIVE) MODE =========================
# The worker (background mode above) does everything: stop, merge checkpoints,
# enumerate VHDs, and compact - all per-VM in parallel. This entry point just
# validates the VM list and hands off.
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Hyper-V VHD Optimization" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($VMNames -and $VMNames.Count -gt 0) {
    $vms = @(Get-VM -Name $VMNames -ErrorAction SilentlyContinue)
    $missing = @($VMNames | Where-Object { $_ -notin ($vms | ForEach-Object Name) })
    foreach ($m in $missing) { Write-Warning "VM '$m' not found - skipping." }
}
else {
    $vms = @(Get-VM -ErrorAction Stop)
}

if (-not $vms -or $vms.Count -eq 0) {
    Write-Warning "No virtual machines found."
    return
}

Write-Host "Selected $($vms.Count) VM(s):" -ForegroundColor Yellow
foreach ($v in $vms) {
    Write-Host ("  - {0,-25} State: {1}" -f $v.Name, $v.State) -ForegroundColor DarkGray
}
Write-Host "Optimization mode: $Mode | Max concurrent compact jobs: $MaxConcurrentJobs`n" -ForegroundColor Yellow
Write-Host "Each VM will be gracefully stopped, have its checkpoints merged, and then compacted - all in parallel.`n" -ForegroundColor DarkGray

# --- Serialize VM list and launch a detached background process ---
$dataFile = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    "CompactDisks_$([guid]::NewGuid().ToString('N')).xml"
)

$domainLabel = ''
if ($DomainLabel) {
    $domainLabel = $DomainLabel
}
elseif ($env:_COMPACT_DISKS_DOMAINLABEL) {
    # Start-CompactDisksUI passes the domain label via env var because
    # powershell.exe -Command quoting around an embedded -DomainLabel '...'
    # argument was unreliable. See note in Start-CompactDisksUI.
    $domainLabel = $env:_COMPACT_DISKS_DOMAINLABEL
}
elseif ($VMNames -and $VMNames.Count -gt 0) {
    $domainLabel = "$($VMNames.Count) VM(s)"
}
# Clear so it doesn't leak to grandchild processes (the worker re-launch
# below inherits env vars, but DomainLabel is plumbed through the clixml
# file from this point on).
Remove-Item Env:\_COMPACT_DISKS_DOMAINLABEL -ErrorAction SilentlyContinue

@{
    VMs                 = @($vms | ForEach-Object { @{ VMName = $_.Name } })
    AttachedCount       = 0   # legacy field, kept for backward compat in the worker
    DomainLabel         = $domainLabel
    ShutdownTimeoutSec  = 300
} | Export-Clixml -Path $dataFile

$psExe      = (Get-Process -Id $PID).Path
$scriptPath = $MyInvocation.MyCommand.Path
$argString  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1} -MaxConcurrentJobs {2}' -f $scriptPath, $Mode, $MaxConcurrentJobs
if ($SkipDefrag)       { $argString += ' -SkipDefrag' }
if ($SkipOfflineClean) { $argString += ' -SkipOfflineClean' }
if ($SkipZeroFill)     { $argString += ' -SkipZeroFill' }
if ($SkipOnlineClean)  { $argString += ' -SkipOnlineClean' }

# Ready-file: the worker touches this once the WPF window has loaded so
# this foreground process can stay visible (with status messages) until the
# UI actually appears. Otherwise the user clicks the menu item and the
# console window vanishes for ~5-10s while WPF spins up, which looks like
# a crash.
$readyFile = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    "CompactDisksReady_$([guid]::NewGuid().ToString('N')).flag"
)

# Signal background mode via environment variables (invisible to the user)
$env:_COMPACT_DISKS_WORKER    = '1'
$env:_COMPACT_DISKS_DATAFILE  = $dataFile
$env:_COMPACT_DISKS_READYFILE = $readyFile
Start-Process -FilePath $psExe -ArgumentList $argString -WindowStyle Hidden -UseNewEnvironment:$false
Remove-Item Env:\_COMPACT_DISKS_WORKER    -ErrorAction SilentlyContinue
Remove-Item Env:\_COMPACT_DISKS_DATAFILE  -ErrorAction SilentlyContinue
Remove-Item Env:\_COMPACT_DISKS_READYFILE -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Starting Compact-Disks worker. Waiting for the WPF progress window to appear...' -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path $readyFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    Write-Host '.' -NoNewline -ForegroundColor DarkGray
}
Write-Host ''
if (Test-Path $readyFile) {
    Remove-Item -Path $readyFile -Force -ErrorAction SilentlyContinue
    Write-Host 'WPF window is open. This console will close in 2 seconds.' -ForegroundColor Green
    Start-Sleep -Seconds 2
}
else {
    Write-Host 'Timed out waiting for the WPF window. The worker may still be starting; check Task Manager.' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}
