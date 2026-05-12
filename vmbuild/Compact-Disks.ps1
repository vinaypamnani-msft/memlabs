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
    [switch]$SkipOnlineClean
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
        WindowReady    = $false
        ReadyFile      = $readyFilePath
        Title          = if ($DomainLabel) { "Hyper-V VHD Optimization - $DomainLabel" } else { 'Hyper-V VHD Optimization' }
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
        Add-UiLog ($Message)
        if ($script:CompactLogPath) {
            try {
                $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
                Add-Content -LiteralPath $script:CompactLogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
            } catch {}
        }
    }

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
        <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,10"
                   Text="Hyper-V VHD Optimization" Foreground="#89B4FA"/>
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
        $TitleText.Text  = $UiSync.Title

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
        while ($prepQueue.Count -gt 0 -or $activePrepJobs.Count -gt 0 -or
               $diskQueue.Count -gt 0 -or $activeJobs.Count -gt 0) {
            if ($UiSync.WindowClosed) { throw 'WindowClosed' }

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

                        # Capture initial state so we can auto-restart at the
                        # end if the VM was running when this script began.
                        $initial = Get-VM -Name $n -ErrorAction SilentlyContinue
                        $wasRunning = ($initial -and $initial.State -eq 'Running')

                        # Dot-source Common.ps1 so we have Invoke-VmCommand /
                        # Get-VmSession / $Common.LocalAdmin, plus the
                        # Test-VMCheckpointMergeFreeSpace pre-merge check.
                        # -InJob suppresses the UI/background-image init bits.
                        $commonLoaded = $false
                        if ($commonPath -and (Test-Path $commonPath)) {
                            try {
                                if ($Common -and $Common.Initialized) { $Common.Initialized = $false }
                                . $commonPath -InJob:$true
                                $commonLoaded = $true
                            }
                            catch {
                                # Online cleanup is best-effort; never block compaction
                            }
                        }

                        # --- 0) Online cleanup (only if VM is currently Running) ---
                        # Uses Invoke-VmCommand which handles credential lookup
                        # (domain account first, then local fallback via VM
                        # note) and PSSession caching for us.
                        $cur = Get-VM -Name $n -ErrorAction SilentlyContinue
                        if ($commonLoaded -and $cur -and $cur.State -eq 'Running' -and $Common.LocalAdmin) {
                            Write-Progress -Activity "Prep $n" -Status 'Online cleanup (in-guest)' -PercentComplete 2

                            # Discover the VM's domain via the VM note so
                            # Invoke-VmCommand picks the right credentials.
                            $note = Get-VMNote -VMName $n -ErrorAction SilentlyContinue
                            $vmDomain = if ($note -and $note.domain) { $note.domain } else { 'WORKGROUP' }

                            $cleanupScript = {
                                $ProgressPreference = 'SilentlyContinue'
                                $ErrorActionPreference = 'SilentlyContinue'

                                # Stop services that lock the caches we want to nuke
                                $svcs = @('wuauserv','bits','cryptsvc','WSUSService','UsoSvc','TrustedInstaller')
                                foreach ($s in $svcs) {
                                    try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch {}
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
                                    try { Remove-Item -Path $pat -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                                }

                                try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}

                                # Disable hibernation -> removes C:\hiberfil.sys
                                # (typically ~RAM size, often multi-GB).
                                try { & powercfg.exe /h off 2>$null | Out-Null } catch {}

                                # Delete all VSS shadow copies / system
                                # restore points. They can hold many GB.
                                try { & vssadmin.exe delete shadows /all /quiet 2>$null | Out-Null } catch {}

                                # Component-store cleanup. /ResetBase makes
                                # installed updates permanent (can't uninstall)
                                # and lets DISM purge superseded payloads.
                                try { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet | Out-Null } catch {}
                                try { & dism.exe /Online /Cleanup-Image /SPSuperseded /Quiet | Out-Null } catch {}

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
                                    }
                                } catch {}

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
                                        }
                                    }
                                } catch {}

                                # Restart the services we stopped (best-effort)
                                foreach ($s in @('wuauserv','bits','cryptsvc')) {
                                    try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch {}
                                }
                            }

                            try {
                                $result = Invoke-VmCommand -VmName $n -VmDomainName $vmDomain `
                                    -ScriptBlock $cleanupScript -DisplayName 'Compact-Disks online cleanup' `
                                    -SuppressLog
                                if ($result -and -not $result.ScriptBlockFailed) {
                                    $onlineCleanRan = $true
                                }
                            }
                            catch {
                                # best-effort; never block compaction
                            }
                        }

                        # --- 1) Graceful shutdown (if running) ---
                        $cur = Get-VM -Name $n -ErrorAction SilentlyContinue
                        if ($cur -and $cur.State -ne 'Off') {
                            Write-Progress -Activity "Prep $n" -Status 'Stopping (graceful)' -PercentComplete 5
                            try {
                                Stop-VM -Name $n -Force -WarningAction SilentlyContinue -ErrorAction Stop
                            }
                            catch {
                                # Guest didn't accept the request; we'll fall through to the timeout/turn-off below
                            }
                            while ((Get-VM -Name $n -ErrorAction SilentlyContinue).State -ne 'Off') {
                                if (((Get-Date) - $startedAt).TotalSeconds -gt $timeoutSec) {
                                    Write-Progress -Activity "Prep $n" -Status 'Force turn-off (timeout)' -PercentComplete 30
                                    Stop-VM -Name $n -TurnOff -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                                    $forced = $true
                                    Start-Sleep -Seconds 3
                                    break
                                }
                                Write-Progress -Activity "Prep $n" -Status 'Stopping (graceful)' -PercentComplete 20
                                Start-Sleep -Seconds 2
                            }
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
                            $i = 0
                            $vmPath = (Get-VM -Name $n -ErrorAction SilentlyContinue).Path
                            foreach ($snap in $snapshots) {
                                $i++
                                Write-Progress -Activity "Prep $n" -Status "Merging $i/$($snapshots.Count): $($snap.Name)" -PercentComplete (40 + (50 * $i / $snapshots.Count))
                                try {
                                    Remove-VMCheckpoint -VM $snap.VM -Name $snap.Name -ErrorAction Stop
                                }
                                catch {
                                    # Try via VMSnapshot object directly
                                    Remove-VMSnapshot -VMSnapshot $snap -ErrorAction SilentlyContinue
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
                            $mergeDeadline = (Get-Date).AddMinutes(15)
                            while ((Get-Date) -lt $mergeDeadline) {
                                $hds = @(Get-VMHardDiskDrive -VMName $n -ErrorAction SilentlyContinue)
                                $pendingAvhdx = $hds | Where-Object { $_.Path -and $_.Path -match '\.avhdx?$' }
                                $pendingChk   = @(Get-VMCheckpoint -VMName $n -ErrorAction SilentlyContinue).Count
                                if (-not $pendingAvhdx -and $pendingChk -eq 0) { break }
                                Write-Progress -Activity "Prep $n" -Status 'Waiting for merge to finish' -PercentComplete 92
                                Start-Sleep -Seconds 3
                            }
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
                        $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $disks = [System.Collections.Generic.List[hashtable]]::new()
                        foreach ($hd in (Get-VMHardDiskDrive -VMName $n -ErrorAction SilentlyContinue)) {
                            if ($hd.Path -and $seen.Add($hd.Path) -and (Test-Path $hd.Path)) {
                                $fi = [System.IO.FileInfo]::new($hd.Path)
                                $disks.Add(@{
                                    VMName       = $n
                                    Path         = $hd.Path
                                    FileName     = $fi.Name
                                    OriginalSize = [long]$fi.Length
                                })
                            }
                        }
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
                if ($vm.Job.State -eq 'Completed') {
                    try { $rawOut = Receive-Job -Job $vm.Job -ErrorAction Stop } catch { $rawOut = $null }
                    Remove-Job -Job $vm.Job -Force -ErrorAction SilentlyContinue
                    # The prep job may emit "::LOG::..." strings via Write-Output
                    # alongside the final hashtable. Separate them.
                    $result = $null
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
                        Write-PhaseLog "Optimize-VHD ($m) starting"
                        Write-Progress -Activity "Compact $p" -Status "Optimize-VHD ($m)" -PercentComplete 30
                        Optimize-VHD -Path $p -Mode $m
                        Write-PhaseLog "Optimize-VHD complete"
                        Write-Progress -Activity "Compact $p" -Status 'Done' -PercentComplete 100
                    } -ArgumentList $VhdPath, $OptMode, $DoDefrag, $DoOfflineClean, $DoZeroFill
                    $disk.Job    = $job
                    $disk.Status = 'Running'
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
                    $disk.Status = 'Completed'
                    $NewFileSize = Get-VhdFileSize -Path $disk.Path
                    $disk.NewSize = if ($NewFileSize) { $NewFileSize } else { $disk.OriginalSize }
                    $saved    = $disk.OriginalSize - $disk.NewSize
                    $savedPct = if ($disk.OriginalSize -gt 0) { [math]::Round(($saved / $disk.OriginalSize) * 100, 1) } else { 0 }
                    Add-UiLog ("[DONE]  $($disk.VMName) - $($disk.FileName): $(Format-Size $disk.OriginalSize) -> $(Format-Size $disk.NewSize) (Saved: $(Format-Size $saved), $savedPct%)")
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                }
                elseif ($disk.Job.State -eq 'Failed') {
                    $disk.Status = 'Failed'
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
    }

        # --- Retry pass: deferred VMs may now fit thanks to space freed by Optimize-VHD ---
        $pass++
        $deferred = @($vmInfoList | Where-Object { $_.Status -eq 'Deferred' })
        if ($deferred.Count -gt 0 -and $pass -le $maxRetryPasses -and -not $UiSync.WindowClosed) {
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
        elseif ($deferred.Count -gt 0 -and -not $UiSync.WindowClosed) {
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
    $prepFailed  = @($vmInfoList | Where-Object { $_.Status -eq 'Failed' })
    $forcedStops = @($vmInfoList | Where-Object { $_.Forced })

    Add-UiLog ('')
    Add-UiLog ('========================================')
    Add-UiLog ('  Optimization Complete!')
    Add-UiLog ('========================================')

    if ($forcedStops.Count -gt 0) {
        Add-UiLog ('--- Force turned-off (graceful shutdown timed out) ---')
        foreach ($f in $forcedStops) {
            Add-UiLog ("  $($f.VMName)")
        }
    }

    if ($prepFailed.Count -gt 0) {
        Add-UiLog ('--- Prep failed (VM was not compacted) ---')
        foreach ($f in $prepFailed) {
            Add-UiLog ("  $($f.VMName): $($f.Error)")
        }
    }

    if ($successful.Count -gt 0) {
        $totalNewSize = ($successful | Measure-Object -Property NewSize -Sum).Sum
        $totalOldSize = ($successful | Measure-Object -Property OriginalSize -Sum).Sum
        $totalSaved   = $totalOldSize - $totalNewSize
        $totalPct     = if ($totalOldSize -gt 0) { [math]::Round(($totalSaved / $totalOldSize) * 100, 1) } else { 0 }

        foreach ($s in $successful) {
            $sv = $s.OriginalSize - $s.NewSize
            $sp = if ($s.OriginalSize -gt 0) { [math]::Round(($sv / $s.OriginalSize) * 100, 1) } else { 0 }
            Add-UiLog ("  $($s.VMName) - $($s.FileName):  $(Format-Size $s.OriginalSize) -> $(Format-Size $s.NewSize)  (Saved $sp%)")
        }
        Add-UiLog ("Total space saved: $(Format-Size $totalSaved) ($totalPct%)")
    }

    if ($failed.Count -gt 0) {
        Add-UiLog ('--- Failed ---')
        foreach ($f in $failed) {
            Add-UiLog ("  $($f.VMName) - $($f.FileName): $($f.Error)")
        }
    }

    if ($cancelled.Count -gt 0) {
        Add-UiLog ('--- Cancelled ---')
        foreach ($c in $cancelled) {
            Add-UiLog ("  $($c.VMName) - $($c.FileName)")
        }
    }

    Add-UiLog ("Duration: $($duration.ToString('hh\:mm\:ss'))  |  Completed: $($successful.Count)  |  Failed: $($failed.Count)  |  Cancelled: $($cancelled.Count)  |  Forced: $($forcedStops.Count)  |  Prep-failed VMs: $($prepFailed.Count)")

    if ($script:CompactLogPath) {
        Add-UiLog ("Log file: $script:CompactLogPath")
    }

    $UiSync.OverallPercent = 100
    $UiSync.StatusText     = "All done - $($successful.Count) completed, $($failed.Count) failed, $($cancelled.Count) cancelled, $($forcedStops.Count) forced"
    $UiSync.Jobs           = [System.Collections.ArrayList]::new()

    # Window stays open for log review - wait until the user closes it, then clean up
    while (-not $UiSync.WindowClosed) { Start-Sleep -Milliseconds 500 }

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
if ($VMNames -and $VMNames.Count -gt 0) {
    $domainLabel = "$($VMNames.Count) VM(s)"
}

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
