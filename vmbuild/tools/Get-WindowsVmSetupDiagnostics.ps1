#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Collects offline Windows setup diagnostics from one Hyper-V VM.
.DESCRIPTION
    Gracefully stops the selected VM, mounts only its disks read-only without
    drive letters, and collects setup logs plus allowlisted registry state.
    The VM is left off. No guest rename, rejoin, registry repair, or restart runs.
    Raw registry hives and unattend files are never included in the archive.
    Stop deployment/test retry loops before collection. The collector refuses
    to run while another process holds the MemLabs host mutation lease.
.PARAMETER AllowTurnOff
    Permits a hard power-off if graceful shutdown fails or the VM is saved/paused.
.EXAMPLE
    .\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -AllowTurnOff
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VmName,
    [string]$Destination = (Join-Path $PSScriptRoot '..\logs\setup-diagnostics'),
    [ValidateRange(5, 600)][int]$StopTimeoutSeconds = 90,
    [switch]$AllowTurnOff
)

$ErrorActionPreference = 'Stop'

function New-MemLabsPrivateDiagnosticDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $null = New-Item -Path $Path -ItemType Directory -ErrorAction Stop
    $security = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $security.SetAccessRuleProtection($true, $false)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $callerSid = $identity.User }
    finally { $identity.Dispose() }
    foreach ($sid in @(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
            $callerSid
        )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
}

function Remove-MemLabsSetupDiagnosticJob {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Context
    )

    if ("$($Job.State)" -in @('Running', 'NotStarted')) {
        try { Stop-Job -Job $Job -ErrorAction Stop }
        catch { Write-Warning "${Context}: stopping the owned shutdown job failed: $($_.Exception.Message)" }
    }
    try { Remove-Job -Job $Job -Force -ErrorAction Stop }
    catch { Write-Warning "${Context}: removing the owned shutdown job failed: $($_.Exception.Message)" }
}

function Stop-MemLabsVmForSetupDiagnostics {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [switch]$AllowTurnOff
    )

    if ("$($VM.State)" -eq 'Off') { return 'AlreadyOff' }
    $shutdownError = ''
    if ("$($VM.State)" -eq 'Running') {
        $job = $null
        try {
            Write-Host "$($VM.Name): requesting graceful shutdown (budget ${TimeoutSeconds}s)."
            $job = Stop-VM -VM $VM -AsJob -Confirm:$false -ErrorAction Stop
            $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds -ErrorAction Stop
            if ($completed) { $null = Receive-Job -Job $job -ErrorAction Stop }
            else { $shutdownError = "Graceful shutdown exceeded ${TimeoutSeconds}s." }
        }
        catch { $shutdownError = $_.Exception.Message }
        finally {
            if ($job) { Remove-MemLabsSetupDiagnosticJob -Job $job -Context "$($VM.Name) graceful shutdown" }
        }
    }
    $current = Get-VM -Id $VM.Id -ErrorAction Stop
    if ("$($current.State)" -eq 'Off') {
        if ($shutdownError) { Write-Warning "$($VM.Name): shutdown reported '$shutdownError'; live VM state is now Off." }
        return 'OffAfterGracefulRequest'
    }
    if (-not $AllowTurnOff) {
        throw "$($VM.Name) is still $($current.State). $shutdownError No disk was mounted. Use -AllowTurnOff to explicitly permit hard power-off."
    }
    Write-Warning "$($VM.Name): using explicitly permitted hard power-off. $shutdownError"
    $job = $null
    try {
        $job = Stop-VM -VM $current -TurnOff -AsJob -Confirm:$false -ErrorAction Stop
        $completed = Wait-Job -Job $job -Timeout 30 -ErrorAction Stop
        if (-not $completed) { throw 'Hard power-off did not finish within 30 seconds.' }
        $null = Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        if ($job) { Remove-MemLabsSetupDiagnosticJob -Job $job -Context "$($VM.Name) hard power-off" }
    }
    if ("$((Get-VM -Id $VM.Id -ErrorAction Stop).State)" -ne 'Off') {
        throw "$($VM.Name) did not reach Off. Refusing to mount its disk."
    }
    return 'TurnOff'
}

function Initialize-MemLabsOfflineSetupHiveType {
    if ('MemLabs.OfflineSetupHive' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace MemLabs {
    public static class OfflineSetupHive {
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
        private static extern int RegLoadAppKey(string path, out IntPtr key, int access, int options, int reserved);
        public static RegistryKey OpenReadOnly(string path) {
            IntPtr value;
            int error = RegLoadAppKey(path, out value, 0x20019, 1, 0);
            if (error != 0) throw new Win32Exception(error);
            SafeRegistryHandle handle = new SafeRegistryHandle(value, true);
            try { return RegistryKey.FromHandle(handle); }
            catch { handle.Dispose(); throw; }
        }
    }
}
'@
}

function Read-MemLabsOfflineSetupRegistryValues {
    param(
        [Parameter(Mandatory)]$Hive,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string[]]$Names
    )

    $key = $Hive.OpenSubKey($SubKey, $false)
    if (-not $key) { return [pscustomobject]@{ Path = $SubKey; Present = $false; Values = @{} } }
    try {
        $values = [ordered]@{}
        foreach ($name in $Names) {
            $values[$name] = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        return [pscustomobject]@{ Path = $SubKey; Present = $true; Values = $values }
    }
    finally { $key.Dispose() }
}

function Read-MemLabsOfflineWindowsSetupHive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('SYSTEM', 'SOFTWARE')][string]$Kind
    )

    Initialize-MemLabsOfflineSetupHiveType
    $hive = [MemLabs.OfflineSetupHive]::OpenReadOnly($Path)
    try {
        if ($Kind -eq 'SOFTWARE') {
            return [ordered]@{
                ImageState = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows\CurrentVersion\Setup\State' -Names @('ImageState')
                WindowsVersion = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows NT\CurrentVersion' `
                    -Names @('ProductName', 'DisplayVersion', 'CurrentBuild', 'UBR', 'EditionID', 'InstallationType')
            }
        }
        $select = Read-MemLabsOfflineSetupRegistryValues -Hive $hive -SubKey 'Select' -Names @('Current')
        $state = [ordered]@{
            Setup = Read-MemLabsOfflineSetupRegistryValues -Hive $hive -SubKey 'Setup' `
                -Names @('SystemSetupInProgress', 'OOBEInProgress', 'SetupType', 'SetupPhase', 'RestartSetup', 'CmdLine')
            ChildCompletion = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                -SubKey 'Setup\Status\ChildCompletion' -Names @('setup.exe')
            SysprepStatus = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                -SubKey 'Setup\Status\SysprepStatus' -Names @('CleanupState', 'GeneralizationState')
            ControlSet = $select
        }
        if ($select.Present -and $select.Values.Current -ge 1 -and $select.Values.Current -le 999) {
            $controlSet = 'ControlSet{0:D3}' -f [int]$select.Values.Current
            $state.ActiveName = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                -SubKey "$controlSet\Control\ComputerName\ActiveComputerName" -Names @('ComputerName')
            $state.PendingName = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                -SubKey "$controlSet\Control\ComputerName\ComputerName" -Names @('ComputerName')
            $state.Tcpip = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                -SubKey "$controlSet\Services\Tcpip\Parameters" -Names @('Hostname', 'NV Hostname', 'Domain', 'NV Domain')
        }
        else { $state.ControlSetError = 'Current control set is absent or invalid; computer/domain names were not inferred.' }
        return $state
    }
    finally { $hive.Dispose() }
}

function Get-MemLabsOfflineSetupSourcePath {
    param(
        [Parameter(Mandatory)][string]$WindowsRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $path = $WindowsRoot
    foreach ($part in (@('') + $RelativePath.Split('\'))) {
        if ($part) { $path = Join-Path $path $part }
        try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] { return }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse point '$path'; offline evidence must remain inside the mounted Windows directory."
        }
    }
    if ($item.PSIsContainer) { throw "Expected an evidence file, not a directory: '$path'." }
    return $path
}

function Copy-MemLabsWindowsSetupEvidence {
    param(
        [Parameter(Mandatory)][string]$WindowsRoot,
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][string]$PrivateRoot,
        [Parameter(Mandatory)][hashtable]$Manifest
    )

    Write-Host 'Collecting Windows setup and domain-join logs (maximum 20 MB per file).'
    foreach ($relative in @(
            'Panther\setupact.log', 'Panther\setuperr.log',
            'Panther\UnattendGC\setupact.log', 'Panther\UnattendGC\setuperr.log',
            'System32\Sysprep\Panther\setupact.log', 'System32\Sysprep\Panther\setuperr.log',
            'Logs\MoSetup\BlueBox.log', 'Debug\NetSetup.log'
        )) {
        try {
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath $relative
            if (-not $source) { $Manifest.Missing.Add($relative); continue }
            $target = Join-Path $Bundle "SetupLogs\$relative"
            $null = New-Item -Path ([IO.Path]::GetDirectoryName($target)) -ItemType Directory -Force
            $length = ([IO.FileInfo]$source).Length
            $truncated = $length -gt 20MB
            if ($truncated) {
                $inputStream = [IO.File]::OpenRead($source)
                try {
                    $header = [byte[]]::new(4)
                    $headerCount = $inputStream.Read($header, 0, $header.Length)
                    $bomLength = 0
                    $alignment = 1
                    if ($headerCount -ge 4 -and (($header[0] -eq 255 -and $header[1] -eq 254 -and $header[2] -eq 0 -and $header[3] -eq 0) -or
                            ($header[0] -eq 0 -and $header[1] -eq 0 -and $header[2] -eq 254 -and $header[3] -eq 255))) {
                        $bomLength = 4; $alignment = 4
                    }
                    elseif ($headerCount -ge 3 -and $header[0] -eq 239 -and $header[1] -eq 187 -and $header[2] -eq 191) { $bomLength = 3 }
                    elseif ($headerCount -ge 2 -and (($header[0] -eq 255 -and $header[1] -eq 254) -or
                            ($header[0] -eq 254 -and $header[1] -eq 255))) { $bomLength = 2; $alignment = 2 }
                    $start = $inputStream.Length - (20MB - $bomLength)
                    $inputStream.Position = $start + (($alignment - ($start % $alignment)) % $alignment)
                    $outputStream = [IO.File]::Create($target)
                    try {
                        if ($bomLength) { $outputStream.Write($header, 0, $bomLength) }
                        $inputStream.CopyTo($outputStream)
                    }
                    finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
            }
            else { Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop }
            $Manifest.Files.Add([ordered]@{ Path = "SetupLogs\$relative"; SourceBytes = $length; Truncated = $truncated })
        }
        catch { $Manifest.Errors.Add("Read setup log '$relative': $($_.Exception.Message)") }
    }

    $registryState = [ordered]@{}
    foreach ($kind in @('SYSTEM', 'SOFTWARE')) {
        try {
            Write-Host "Reading allowlisted offline $kind setup state."
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath "System32\config\$kind"
            if (-not $source) { $Manifest.Errors.Add("Offline registry hive $kind is missing."); continue }
            $copy = Join-Path $PrivateRoot $kind
            Copy-Item -LiteralPath $source -Destination $copy -ErrorAction Stop
            foreach ($suffix in @('.LOG1', '.LOG2')) {
                $transactionLog = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath "System32\config\$kind$suffix"
                if ($transactionLog) {
                    Copy-Item -LiteralPath $transactionLog -Destination "$copy$suffix" -ErrorAction Stop
                }
            }
            # App-key handles unload automatically; no hive is attached to HKLM/HKU.
            $registryState[$kind] = Read-MemLabsOfflineWindowsSetupHive -Path $copy -Kind $kind
        }
        catch { $Manifest.Errors.Add("Read offline $kind setup state: $($_.Exception.Message)") }
    }
    if ($registryState.Count -gt 0) {
        $registryState | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $Bundle 'WindowsSetupState.json') -Encoding UTF8 -ErrorAction Stop
        $Manifest.Files.Add([ordered]@{ Path = 'WindowsSetupState.json'; Truncated = $false })
    }
    foreach ($eventSource in @(
            @{ Name = 'Setup'; File = 'Setup.evtx' },
            @{ Name = 'System'; File = 'System.evtx' },
            @{ Name = 'Application'; File = 'Application.evtx' },
            @{ Name = 'DSC-Operational'; File = 'Microsoft-Windows-DSC%4Operational.evtx' }
        )) {
        $log = $eventSource.Name
        try {
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath "System32\winevt\Logs\$($eventSource.File)"
            if (-not $source) { $Manifest.Missing.Add($eventSource.File); continue }
            Write-Host "Summarizing offline $log events."
            $events = @(Get-WinEvent -Path $source -MaxEvents 1000 -ErrorAction Stop |
                Where-Object { $log -in @('Setup', 'DSC-Operational') -or
                    $_.ProviderName -match 'Setup|OOBE|Netlogon|Kernel-Boot|Kernel-Power|User32|Application Error|Windows Error Reporting|AppModel|CloudExperienceHost' -or
                    $_.Id -in @(6005, 6006, 6008) } |
                Select-Object -First 80 |
                ForEach-Object {
                    $eventRecord = $_
                    $message = $null
                    try { $message = $eventRecord.FormatDescription() }
                    catch { $Manifest.Errors.Add("Format offline $log event message: $($_.Exception.Message)") }
                    [pscustomobject]@{
                        TimeCreated = $eventRecord.TimeCreated; Id = $eventRecord.Id; ProviderName = $eventRecord.ProviderName
                        Level = $eventRecord.Level; Message = $message; Xml = $eventRecord.ToXml()
                    }
                })
            ConvertTo-Json -InputObject $events -Depth 5 |
                Set-Content -LiteralPath (Join-Path $Bundle "$log-events.json") -Encoding UTF8 -ErrorAction Stop
            $Manifest.Files.Add([ordered]@{ Path = "$log-events.json"; Truncated = $true })
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Set-Content -LiteralPath (Join-Path $Bundle "$log-events.json") -Value '[]' -Encoding UTF8 -ErrorAction Stop
                $Manifest.Files.Add([ordered]@{ Path = "$log-events.json"; Truncated = $false })
            }
            else { $Manifest.Errors.Add("Read offline $log events: $($_.Exception.Message)") }
        }
    }
}

function Invoke-MemLabsWindowsSetupDiagnostics {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(5, 600)][int]$StopTimeoutSeconds = 90,
        [switch]$AllowTurnOff
    )

    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VmName)) {
        throw 'Specify one exact VM name, not a wildcard.'
    }
    $vms = @(Get-VM -Name $VmName -ErrorAction Stop)
    if ($vms.Count -ne 1 -or $vms[0].Name -ine $VmName) { throw 'Exactly one matching VM is required.' }
    $vm = $vms[0]
    if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Stop if necessary, collect read-only Windows setup evidence, and leave the VM off')) { return }
    $destinationProvider = $null
    $destinationDrive = $null
    $destinationPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Destination, [ref]$destinationProvider, [ref]$destinationDrive)
    if ($destinationProvider.Name -ne 'FileSystem') { throw 'Destination must be a filesystem path.' }
    $safeName = $vm.Name -replace '[\\/:*?"<>|]', '_'
    $name = "$safeName-SetupFailure-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $collectionRoot = Join-Path $destinationPath $name
    New-MemLabsPrivateDiagnosticDirectory -Path $collectionRoot
    $bundle = Join-Path $collectionRoot 'Bundle'
    $privateRoot = Join-Path $collectionRoot 'PrivateState'
    $null = New-Item -Path $bundle, $privateRoot -ItemType Directory
    $manifest = @{
        SchemaVersion = 1; CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Host = $env:COMPUTERNAME; VMName = $vm.Name; VMId = "$($vm.Id)"
        OriginalState = "$($vm.State)"; FinalState = ''; Status = 'Collecting'
        Files = [Collections.Generic.List[object]]::new()
        Missing = [Collections.Generic.List[string]]::new()
        Errors = [Collections.Generic.List[string]]::new()
        Disks = [Collections.Generic.List[object]]::new()
        Privacy = 'No unattend XML, SAM, SECURITY, or raw registry hives are archived. Setup logs may contain device/account identifiers, paths, or other sensitive details; review the protected archive before sharing.'
    }
    $fatal = $null
    $windowsFound = $false
    $mountCleanupFailed = $false
    try {
        $manifest.ShutdownMode = Stop-MemLabsVmForSetupDiagnostics -VM $vm -TimeoutSeconds $StopTimeoutSeconds -AllowTurnOff:$AllowTurnOff
        $vm = Get-VM -Id $vm.Id -ErrorAction Stop
        $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Sort-Object ControllerNumber, ControllerLocation)
        if ($drives.Count -eq 0) { throw 'The VM has no virtual hard disks.' }
        foreach ($drive in $drives) {
            if (-not $drive.Path) { $manifest.Errors.Add('A pass-through or pathless disk was not mounted.'); continue }
            $mounted = $null
            try {
                if ("$((Get-VM -Id $vm.Id -ErrorAction Stop).State)" -ne 'Off') { throw 'VM power state changed before disk mounting.' }
                $info = Get-VHD -Path $drive.Path -ErrorAction Stop
                if ($info.Attached) { throw "Disk '$($drive.Path)' is already attached; it will not be borrowed or dismounted." }
                Write-Host "$($vm.Name): mounting '$($drive.Path)' read-only, without drive letters."
                $mounted = Mount-VHD -Path $drive.Path -ReadOnly -NoDriveLetter -Passthru -ErrorAction Stop
                $disk = Get-Disk -Number $mounted.DiskNumber -ErrorAction Stop
                if (-not $disk.IsReadOnly) { throw 'The mounted disk is not read-only.' }
                if ($disk.IsOffline) {
                    $null = Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
                    $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
                    if (-not $disk.IsReadOnly -or $disk.IsOffline) { throw 'The mounted disk did not remain read-only and online.' }
                }
                $manifest.Disks.Add([ordered]@{ Path = $drive.Path; ParentPath = $info.ParentPath; DiskNumber = $disk.Number; ReadOnly = $true })
                foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
                    if ("$($partition.GptType)" -eq '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}') { continue }
                    try { $volumes = @(Get-Volume -Partition $partition -ErrorAction Stop) }
                    catch {
                        $manifest.Errors.Add("Read volume for disk $($disk.Number) partition $($partition.PartitionNumber): $($_.Exception.Message)")
                        continue
                    }
                    foreach ($volume in $volumes) {
                        if (-not $volume.Path) { continue }
                        $windows = Join-Path $volume.Path 'Windows'
                        if (-not [IO.File]::Exists((Join-Path $windows 'System32\config\SYSTEM'))) { continue }
                        $windowsFound = $true
                        $manifest.WindowsVolume = $volume.Path
                        Write-Host "$($vm.Name): found Windows at '$windows'."
                        Copy-MemLabsWindowsSetupEvidence -WindowsRoot $windows -Bundle $bundle -PrivateRoot $privateRoot -Manifest $manifest
                        break
                    }
                    if ($windowsFound) { break }
                }
            }
            finally {
                if ($mounted) {
                    for ($attempt = 1; $attempt -le 2; $attempt++) {
                        try { Dismount-VHD -Path $drive.Path -ErrorAction Stop; break }
                        catch {
                            if ($attempt -eq 2) {
                                $mountCleanupFailed = $true
                                $manifest.Errors.Add("Owned mount '$($drive.Path)' could not be dismounted; detach it manually before restarting the VM: $($_.Exception.Message)")
                            }
                            else {
                                Write-Warning "Dismount of '$($drive.Path)' failed; retrying once: $($_.Exception.Message)"
                                Start-Sleep -Seconds 1
                            }
                        }
                    }
                }
            }
            if ($mountCleanupFailed) { throw 'An owned disk mount could not be cleaned up. See the manifest for its path.' }
            if ($windowsFound) { break }
        }
        if (-not $windowsFound) { throw 'No readable Windows installation was found. A locked BitLocker volume or unreadable disk needs separate handling.' }
        if ($manifest.Files.Count -eq 0) { throw 'No diagnostic files were collected.' }
    }
    catch { $fatal = $_; $manifest.Errors.Add($_.Exception.Message) }
    finally {
        try { Remove-Item -LiteralPath $privateRoot -Recurse -Force -ErrorAction Stop }
        catch { $manifest.Errors.Add("Private hive cleanup failed; files are excluded from the archive: $($_.Exception.Message)") }
        try {
            $manifest.FinalState = "$((Get-VM -Id $vm.Id -ErrorAction Stop).State)"
            if ($manifest.FinalState -ne 'Off') { throw "VM is $($manifest.FinalState), not Off." }
        }
        catch {
            $manifest.Errors.Add("Final VM state could not be verified as Off: $($_.Exception.Message)")
            if (-not $fatal) { $fatal = $_ }
        }
    }
    $manifest.Status = if ($fatal) { 'Failed' } elseif ($manifest.Errors.Count) { 'Partial' } else { 'Complete' }
    $manifest | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $bundle 'Manifest.json') -Encoding UTF8 -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $bundle 'Privacy.txt') -Value $manifest.Privacy -Encoding UTF8 -ErrorAction Stop
    $archive = Join-Path $collectionRoot "$name.zip"
    Write-Host 'Creating the protected diagnostic archive.'
    try { Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -ErrorAction Stop }
    catch { throw "Could not create '$archive': $($_.Exception.Message). Unarchived evidence is preserved in '$bundle'." }
    Write-Host "Setup diagnostics: $archive (status=$($manifest.Status); VM left $($manifest.FinalState))."
    Write-Host $manifest.Privacy
    if ($fatal) { throw "Setup diagnostic collection failed: $($fatal.Exception.Message). Partial evidence: $archive" }
    if ($manifest.Errors.Count) { Write-Warning "Collection is partial; review Manifest.json in $archive." }
    [pscustomobject]@{ VMName = $vm.Name; Status = $manifest.Status; ArchivePath = $archive; FinalState = $manifest.FinalState }
}

$collectorParameters = @{} + $PSBoundParameters
$collectorParameters.Destination = $Destination
$collectorParameters.StopTimeoutSeconds = $StopTimeoutSeconds
if ($WhatIfPreference) { Invoke-MemLabsWindowsSetupDiagnostics @collectorParameters; return }
$mutationMutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
$leaseHeld = $false
try {
    try { $leaseHeld = $mutationMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] {
        $leaseHeld = $true
        Write-Warning 'The previous host mutation lease owner exited unexpectedly; acquiring the abandoned lease for collection.'
    }
    if (-not $leaseHeld) { throw 'Another MemLabs operation owns the host mutation lease. Stop the active deployment/test retry loop before collecting setup diagnostics.' }
    Invoke-MemLabsWindowsSetupDiagnostics @collectorParameters
}
finally {
    try { if ($leaseHeld) { $mutationMutex.ReleaseMutex() } }
    finally { $mutationMutex.Dispose() }
}
