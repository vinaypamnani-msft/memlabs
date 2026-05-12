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
    [int]$MaxConcurrentJobs = 8
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
    # Clear the env vars immediately so they don't leak to child processes
    Remove-Item Env:\_COMPACT_DISKS_WORKER   -ErrorAction SilentlyContinue
    Remove-Item Env:\_COMPACT_DISKS_DATAFILE  -ErrorAction SilentlyContinue

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # Load serialized disk data from the temp file
    $importedData = Import-Clixml -Path $dataFilePath
    Remove-Item -Path $dataFilePath -Force -ErrorAction SilentlyContinue

    $AttachedCount = $importedData.AttachedCount
    $DomainLabel   = $importedData.DomainLabel

    # Rebuild disk objects
    $diskInfoList = [System.Collections.Generic.List[PSCustomObject]]::new()
    $diskQueue    = [System.Collections.Generic.Queue[PSCustomObject]]::new()
    foreach ($d in $importedData.Disks) {
        $obj = [PSCustomObject]@{
            VMName       = $d.VMName
            Path         = $d.Path
            FileName     = $d.FileName
            OriginalSize = [long]$d.OriginalSize
            Job          = $null
            NewSize      = $null
            Status       = 'Pending'
            Error        = $null
        }
        $diskInfoList.Add($obj)
        $diskQueue.Enqueue($obj)
    }

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
        Title          = if ($DomainLabel) { "Hyper-V VHD Optimization - $DomainLabel" } else { 'Hyper-V VHD Optimization' }
    })

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
            <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="LogText" FontSize="12" FontFamily="Consolas"
                           TextWrapping="Wrap" Foreground="#A6ADC8"/>
            </ScrollViewer>
        </Border>
    </Grid>
</Window>
'@

        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $window.Title = $UiSync.Title
        $window.Add_Closed({ $UiSync.WindowClosed = $true })

        $TitleText       = $window.FindName('TitleText')
        $StatusText      = $window.FindName('StatusText')
        $OverallProgress = $window.FindName('OverallProgress')
        $OverallPctText  = $window.FindName('OverallPctText')
        $ElapsedText     = $window.FindName('ElapsedText')
        $JobPanel        = $window.FindName('JobPanel')
        $LogText         = $window.FindName('LogText')
        $LogScroll       = $window.FindName('LogScroll')
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
                $LogScroll.ScrollToEnd()
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
    function Get-JobPercent {
        param($Job)
        if ($Job -and $Job.ChildJobs.Count -gt 0) {
            $progressRecords = $Job.ChildJobs[0].Progress
            if ($progressRecords -and $progressRecords.Count -gt 0) {
                $latest = $progressRecords[$progressRecords.Count - 1]
                if ($latest.PercentComplete -ge 0) { return $latest.PercentComplete }
            }
        }
        return 0
    }

    function Update-Progress {
        param($DiskList, $ActiveJobs, $Total, $StartTime)
        $elapsed = (Get-Date) - $StartTime
        $running = @($DiskList | Where-Object { $_.Status -eq 'Running' }).Count
        $pending = @($DiskList | Where-Object { $_.Status -eq 'Pending' }).Count
        $done    = @($DiskList | Where-Object { $_.Status -in 'Completed', 'Failed' }).Count
        $pct = if ($Total -gt 0) { [math]::Round(($done / $Total) * 100) } else { 0 }

        $UiSync.OverallPercent = $pct
        $UiSync.StatusText     = "$done of $Total completed | Running: $running | Pending: $pending"
        $UiSync.ElapsedText    = $elapsed.ToString('hh\:mm\:ss')

        $jobSnapshot = [System.Collections.ArrayList]::new()
        foreach ($disk in $ActiveJobs) {
            $jobPct = Get-JobPercent -Job $disk.Job
            [void]$jobSnapshot.Add(@{
                Name    = "$($disk.VMName) - $($disk.FileName)"
                Percent = $jobPct
            })
        }
        $UiSync.Jobs = $jobSnapshot
    }

    # --- Synchronous processing loop (main thread of the detached process) ---
    $activeJobs     = [System.Collections.Generic.List[PSCustomObject]]::new()
    $completedCount = 0
    $totalCount     = $diskInfoList.Count
    $startTime      = Get-Date

    try {
        while ($diskQueue.Count -gt 0 -or $activeJobs.Count -gt 0) {
            if ($UiSync.WindowClosed) { throw 'WindowClosed' }

            while ($activeJobs.Count -lt $MaxConcurrentJobs -and $diskQueue.Count -gt 0) {
                $disk = $diskQueue.Dequeue()
                [void]$UiSync.Log.Add("[START] $($disk.VMName) - $($disk.FileName)")
                try {
                    $VhdPath = $disk.Path
                    $OptMode = $Mode
                    $job = Start-Job -ScriptBlock {
                        param($p, $m)
                        Optimize-VHD -Path $p -Mode $m
                    } -ArgumentList $VhdPath, $OptMode
                    $disk.Job    = $job
                    $disk.Status = 'Running'
                    [void]$activeJobs.Add($disk)
                }
                catch {
                    $disk.Status = 'Failed'
                    $disk.Error  = $_.Exception.Message
                    [void]$UiSync.Log.Add("[ERROR] $($disk.FileName): $($_.Exception.Message)")
                    $completedCount++
                }
            }

            $stillRunning = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($disk in $activeJobs) {
                if ($disk.Job.State -eq 'Completed') {
                    $disk.Status = 'Completed'
                    $NewFileSize = Get-VhdFileSize -Path $disk.Path
                    $disk.NewSize = if ($NewFileSize) { $NewFileSize } else { $disk.OriginalSize }
                    $saved    = $disk.OriginalSize - $disk.NewSize
                    $savedPct = if ($disk.OriginalSize -gt 0) { [math]::Round(($saved / $disk.OriginalSize) * 100, 1) } else { 0 }
                    [void]$UiSync.Log.Add("[DONE]  $($disk.VMName) - $($disk.FileName): $(Format-Size $disk.OriginalSize) -> $(Format-Size $disk.NewSize) (Saved: $(Format-Size $saved), $savedPct%)")
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                    $completedCount++
                }
                elseif ($disk.Job.State -eq 'Failed') {
                    $disk.Status = 'Failed'
                    $reason = $disk.Job.ChildJobs[0].JobStateInfo.Reason
                    $disk.Error = if ($reason) { $reason.Message } else { ($disk.Job.ChildJobs[0].Error | Out-String).Trim() }
                    if (-not $disk.Error) { $disk.Error = 'Unknown error' }
                    [void]$UiSync.Log.Add("[FAIL]  $($disk.VMName) - $($disk.FileName): $($disk.Error)")
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                    $completedCount++
                }
                else {
                    [void]$stillRunning.Add($disk)
                }
            }
            $activeJobs = $stillRunning

            Update-Progress -DiskList $diskInfoList -ActiveJobs $activeJobs -Total $totalCount -StartTime $startTime

            if ($activeJobs.Count -gt 0 -or $diskQueue.Count -gt 0) {
                Start-Sleep -Milliseconds 300
            }
        }

        Update-Progress -DiskList $diskInfoList -ActiveJobs $activeJobs -Total $totalCount -StartTime $startTime
    }
    catch {
        # interrupted (window closed or error)
    }
    finally {
        if ($activeJobs.Count -gt 0) {
            foreach ($disk in $activeJobs) {
                if ($disk.Job) {
                    Stop-Job  -Job $disk.Job -ErrorAction SilentlyContinue
                    Remove-Job -Job $disk.Job -Force -ErrorAction SilentlyContinue
                    $disk.Status = 'Cancelled'
                }
            }
        }
    }

    # --- Final summary into the UI log ---
    $duration   = (Get-Date) - $startTime
    $successful = @($diskInfoList | Where-Object { $_.Status -eq 'Completed' })
    $failed     = @($diskInfoList | Where-Object { $_.Status -eq 'Failed' })
    $cancelled  = @($diskInfoList | Where-Object { $_.Status -eq 'Cancelled' })

    [void]$UiSync.Log.Add('')
    [void]$UiSync.Log.Add('========================================')
    [void]$UiSync.Log.Add('  Optimization Complete!')
    [void]$UiSync.Log.Add('========================================')

    if ($successful.Count -gt 0) {
        $totalNewSize = ($successful | Measure-Object -Property NewSize -Sum).Sum
        $totalOldSize = ($successful | Measure-Object -Property OriginalSize -Sum).Sum
        $totalSaved   = $totalOldSize - $totalNewSize
        $totalPct     = if ($totalOldSize -gt 0) { [math]::Round(($totalSaved / $totalOldSize) * 100, 1) } else { 0 }

        foreach ($s in $successful) {
            $sv = $s.OriginalSize - $s.NewSize
            $sp = if ($s.OriginalSize -gt 0) { [math]::Round(($sv / $s.OriginalSize) * 100, 1) } else { 0 }
            [void]$UiSync.Log.Add("  $($s.VMName) - $($s.FileName):  $(Format-Size $s.OriginalSize) -> $(Format-Size $s.NewSize)  (Saved $sp%)")
        }
        [void]$UiSync.Log.Add("Total space saved: $(Format-Size $totalSaved) ($totalPct%)")
    }

    if ($failed.Count -gt 0) {
        [void]$UiSync.Log.Add('--- Failed ---')
        foreach ($f in $failed) {
            [void]$UiSync.Log.Add("  $($f.VMName) - $($f.FileName): $($f.Error)")
        }
    }

    if ($cancelled.Count -gt 0) {
        [void]$UiSync.Log.Add('--- Cancelled ---')
        foreach ($c in $cancelled) {
            [void]$UiSync.Log.Add("  $($c.VMName) - $($c.FileName)")
        }
    }

    [void]$UiSync.Log.Add("Duration: $($duration.ToString('hh\:mm\:ss'))  |  Completed: $($successful.Count)  |  Failed: $($failed.Count)  |  Cancelled: $($cancelled.Count)  |  Skipped: $AttachedCount")

    $UiSync.OverallPercent = 100
    $UiSync.StatusText     = "All done - $($successful.Count) completed, $($failed.Count) failed, $($cancelled.Count) cancelled"
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

Write-Host "Collecting VHD information from $($vms.Count) VM(s)..." -ForegroundColor Yellow

# Get all hard disk drives in a single call (faster than per-VM)
$allHardDrives = @(Get-VMHardDiskDrive -VM $vms -ErrorAction SilentlyContinue)
Write-Host "  Found $($allHardDrives.Count) virtual disk(s), resolving details..." -ForegroundColor DarkGray

# Build unique path list with VM info
$SeenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$vmLookup = @{}
foreach ($v in $vms) { $vmLookup[$v.Name] = $v }

$uniqueDisks = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($hd in $allHardDrives) {
    if ($hd.Path -and $SeenPaths.Add($hd.Path)) {
        $fi = [System.IO.FileInfo]::new($hd.Path)
        if ($fi.Exists) {
            $vm = $vmLookup[$hd.VMName]
            $uniqueDisks.Add([PSCustomObject]@{
                VMName       = $hd.VMName
                VMState      = if ($vm) { $vm.State } else { 'Unknown' }
                Path         = $hd.Path
                FileName     = $fi.Name
                OriginalSize = $fi.Length
                VirtualSize  = $null
                VhdType      = $null
                Attached     = $null
                VolumeRoot   = [System.IO.Path]::GetPathRoot($hd.Path)
                Job          = $null
                NewSize      = $null
                Status       = 'Pending'
                Error        = $null
            })
        }
    }
}

# Resolve VHD metadata (VhdType, VirtualSize) in parallel via runspace pool
if ($uniqueDisks.Count -gt 0) {
    $rsPool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min($uniqueDisks.Count, 16))
    $rsPool.Open()
    $rsJobs = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($disk in $uniqueDisks) {
        $ps = [powershell]::Create().AddScript({
            param($Path)
            $v = Get-VHD -Path $Path -ErrorAction SilentlyContinue
            if ($v) { @{ VhdType = $v.VhdType; VirtualSize = $v.Size; Attached = $v.Attached } }
        }).AddArgument($disk.Path)
        $ps.RunspacePool = $rsPool
        $rsJobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Disk = $disk })
    }

    $rsIndex = 0
    foreach ($rj in $rsJobs) {
        $rsIndex++
        Write-Progress -Activity 'Collecting VHD information' `
            -Status "Resolving VHD $rsIndex of $($rsJobs.Count): $($rj.Disk.FileName)" `
            -PercentComplete ([math]::Round($rsIndex / $rsJobs.Count * 100))
        $result = $rj.PS.EndInvoke($rj.Handle)
        if ($result -and $result.Count -gt 0) {
            $rj.Disk.VhdType     = $result[0].VhdType
            $rj.Disk.VirtualSize = $result[0].VirtualSize
            $rj.Disk.Attached    = $result[0].Attached
        }
        $rj.PS.Dispose()
    }
    $rsPool.Close()
    $rsPool.Dispose()
    Write-Progress -Activity 'Collecting VHD information' -Completed
}

$diskInfoList = @($uniqueDisks)

if ($diskInfoList.Count -eq 0) {
    Write-Warning "No VHD files found to optimize."
    return
}

# Display initial state
Write-Host "`n--- Current VHD Status ---" -ForegroundColor Cyan
$diskInfoList | Format-Table -AutoSize @(
    @{Label = 'VM'; Expression = { $_.VMName }; Width = 20 }
    @{Label = 'State'; Expression = { $_.VMState } }
    @{Label = 'VHD File'; Expression = { $_.FileName }; Width = 30 }
    @{Label = 'Type'; Expression = { $_.VhdType } }
    @{Label = 'Current Size'; Expression = { Format-Size $_.OriginalSize } }
    @{Label = 'Max Size'; Expression = { Format-Size $_.VirtualSize } }
)

$totalOriginalSize = ($diskInfoList | Measure-Object -Property OriginalSize -Sum).Sum
Write-Host "Total current disk usage: $(Format-Size $totalOriginalSize)" -ForegroundColor Yellow
Write-Host "Optimization mode: $Mode | Max concurrent jobs: $MaxConcurrentJobs`n" -ForegroundColor Yellow

# Check for running VMs with attached disks - skip them
$attachedDisks = @($diskInfoList | Where-Object { $_.VMState -eq 'Running' })
if ($attachedDisks) {
    Write-Warning "The following VMs are running - their disks cannot be optimized:"
    $attachedDisks | ForEach-Object { Write-Warning "  - $($_.VMName): $($_.FileName)" }
    $diskInfoList = @($diskInfoList | Where-Object { $_.VMState -ne 'Running' })

    if ($diskInfoList.Count -eq 0) {
        Write-Warning "No eligible VHDs to optimize. Please shut down VMs first."
        return
    }
    Write-Host ""
}

# Sort largest first (the worker will queue in this order)
$diskInfoList = @($diskInfoList | Sort-Object OriginalSize -Descending)

Write-Host "Starting optimization of $($diskInfoList.Count) VHD(s) (largest first, up to $MaxConcurrentJobs concurrent)...`n" -ForegroundColor Green

# --- Serialize disk data and launch a detached background process ---
$dataFile = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    "CompactDisks_$([guid]::NewGuid().ToString('N')).xml"
)

$domainLabel = ''
if ($VMNames -and $VMNames.Count -gt 0) {
    $domainLabel = "$($VMNames.Count) VM(s)"
}

@{
    Disks = @($diskInfoList | ForEach-Object {
        @{ VMName = $_.VMName; Path = $_.Path; FileName = $_.FileName; OriginalSize = $_.OriginalSize }
    })
    AttachedCount = $attachedDisks.Count
    DomainLabel   = $domainLabel
} | Export-Clixml -Path $dataFile

$psExe      = (Get-Process -Id $PID).Path
$scriptPath = $MyInvocation.MyCommand.Path
$argString  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1} -MaxConcurrentJobs {2}' -f $scriptPath, $Mode, $MaxConcurrentJobs

# Signal background mode via environment variables (invisible to the user)
$env:_COMPACT_DISKS_WORKER   = '1'
$env:_COMPACT_DISKS_DATAFILE = $dataFile
Start-Process -FilePath $psExe -ArgumentList $argString -WindowStyle Hidden -UseNewEnvironment:$false
Remove-Item Env:\_COMPACT_DISKS_WORKER   -ErrorAction SilentlyContinue
Remove-Item Env:\_COMPACT_DISKS_DATAFILE  -ErrorAction SilentlyContinue

Write-Host "Optimization is running in the background - progress is shown in the WPF window." -ForegroundColor Green
