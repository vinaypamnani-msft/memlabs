#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Collects offline Windows setup diagnostics from one Hyper-V VM.
.DESCRIPTION
    By default, gracefully stops the selected VM, mounts only its disks read-only without
    drive letters, and collects setup logs plus allowlisted registry state.
    Captures the selected VM console before shutdown when a framebuffer exists.
    The VM is left off. No guest rename, rejoin, registry repair, or restart runs.
    Raw registry hives and unattend files are never included in the archive.
    Stop deployment/test retry loops before collection. The collector refuses
    to run while another process holds the MemLabs host mutation lease.
    Required host modules and commands are checked before shutdown or mounting.
.PARAMETER IncludeLiveProbe
    Opts into bounded, read-only first-logon/process and registered/provisioned AppX
    inspection before the offline collection. Starts an Off VM, observes for 190s,
    uses saved credentials, and makes no repair changes. Off/Running VMs only.
.PARAMETER IncludeHangDump
    Explicitly captures only the verified FirstLogonAnim process before shutdown.
    Requires an already Running VM, even with IncludeLiveProbe; never boots it.
    Writes a protected guest dump, then verifies/copies it through the offline mount.
    The dump contains process memory and can briefly affect the target process.
.PARAMETER RepairOobe
    Explicitly opts into an OOBE-only Windows Update access trial. Uses the saved
    MemLabs local administrator credential unless GuestCredential is supplied.
    BackupPath optionally requests a verified full VM export before repair.
    No rename, domain repair, setup-completion override, or ACL reset is performed.
.PARAMETER GuestCredential
    Optional override. By default, reuses Common.LocalAdmin or loads cached
    vmbuildadmin credentials through the same helper used by New-Lab.
.PARAMETER BackupPath
    Optional full-export destination. When omitted, repair runs without a VM backup.
.PARAMETER AllowTurnOff
    Permits a hard power-off if graceful shutdown fails or the VM is saved/paused.
.EXAMPLE
    .\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -AllowTurnOff
.EXAMPLE
    .\Get-WindowsVmSetupDiagnostics.ps1 -VmName CST-W11CLIENT1 -RepairOobe
.EXAMPLE
    .\Get-WindowsVmSetupDiagnostics.ps1 -VmName ADA-W11CLIENT1 -IncludeLiveProbe
.EXAMPLE
    .\Get-WindowsVmSetupDiagnostics.ps1 -VmName ADA-W11CLIENT1 -IncludeLiveProbe -IncludeHangDump
#>
[CmdletBinding(DefaultParameterSetName = 'Collect', SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Collect')]
    [Parameter(Mandatory, ParameterSetName = 'Repair')]
    [Parameter(Mandatory, ParameterSetName = 'Live')]
    [Parameter(Mandatory, ParameterSetName = 'Dump')]
    [ValidateNotNullOrEmpty()][string]$VmName,
    [string]$Destination,
    [ValidateRange(5, 600)][int]$StopTimeoutSeconds = 90,
    [switch]$AllowTurnOff,
    [Parameter(Mandatory, ParameterSetName = 'Live')][switch]$IncludeLiveProbe,
    [Parameter(Mandatory, ParameterSetName = 'Dump')]
    [Parameter(ParameterSetName = 'Live')][switch]$IncludeHangDump,
    [Parameter(Mandatory, ParameterSetName = 'Repair')][switch]$RepairOobe,
    [Parameter(ParameterSetName = 'Repair')][ValidateNotNullOrEmpty()][string]$BackupPath,
    [Parameter(ParameterSetName = 'Repair')]
    [Parameter(ParameterSetName = 'Live')]
    [Parameter(ParameterSetName = 'Dump')][ValidateNotNull()][pscredential]$GuestCredential,
    [Parameter(ParameterSetName = 'Repair')][ValidateRange(60, 3600)][int]$RepairTimeoutSeconds = 900,
    [Parameter(ParameterSetName = 'Repair')][ValidateRange(60, 7200)][int]$BackupTimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'

function Initialize-MemLabsSetupDiagnosticModules {
    param([switch]$IncludeLiveProbe)
    $requirements = [ordered]@{
        'Hyper-V' = @('Get-VM', 'Stop-VM', 'Get-VMHardDiskDrive', 'Get-VHD', 'Mount-VHD', 'Dismount-VHD')
        'Storage' = @('Get-Disk', 'Set-Disk', 'Get-Partition', 'Get-Volume')
        'Microsoft.PowerShell.Diagnostics' = @('Get-WinEvent')
        'Microsoft.PowerShell.Archive' = @('Compress-Archive')
        'CimCmdlets' = @('Get-CimInstance', 'Get-CimAssociatedInstance', 'Invoke-CimMethod')
    }
    if ($IncludeLiveProbe) { $requirements['Hyper-V'] += 'Start-VM' }
    foreach ($moduleName in $requirements.Keys) {
        try {
            Import-Module -Name $moduleName -Global -ErrorAction Stop | Out-Null
            foreach ($commandName in $requirements[$moduleName]) {
                Get-Command -Name "$moduleName\$commandName" -ErrorAction Stop | Out-Null
            }
        }
        catch {
            $message = "Diagnostic host dependency '$moduleName' failed before VM shutdown or disk mounting. " +
                "Retry from a fresh elevated Windows PowerShell 5.1 process (powershell.exe -NoProfile), " +
                "especially if the error names a missing remoteIpMoProxy format file. Original error: $($_.Exception.Message)"
            $failure = [InvalidOperationException]::new($message, $_.Exception)
            $failure.Data['DiagnosticModule'] = $moduleName
            $failure.Data['OriginalErrorId'] = $_.FullyQualifiedErrorId
            throw $failure
        }
    }
}

function Resolve-MemLabsSetupDiagnosticPath {
    param([Parameter(Mandatory)][string]$Path)
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Destination must be a filesystem path.' }
    return $resolved
}

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

function Add-MemLabsSetupConsoleScreenshot {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$Stage,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Errors
    )

    $name = "Console-$Stage.png"
    $record = [ordered]@{
        Stage = $Stage; Path = $name; Status = 'Unavailable'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o'); VMId = "$($VM.Id)"
        Width = $null; Height = $null; AllBlack = $null; Error = $null
    }
    try {
        $live = Get-VM -Id $VM.Id -ErrorAction Stop
        if ($live.Name -ne $VM.Name) { throw 'The selected VM identity changed before console capture.' }
        . (Join-Path $PSScriptRoot 'Common.VmConsoleScreenshot.ps1')
        $capture = Save-MemLabsVmConsoleScreenshot -VMId $VM.Id -Path (Join-Path $Bundle $name)
        $record.Status = $capture.Status
        if ($capture.Status -eq 'Captured') {
            if (-not [IO.File]::Exists((Join-Path $Bundle $name))) { throw 'Console capture did not create its PNG.' }
            $record.Width = $capture.Width; $record.Height = $capture.Height; $record.AllBlack = $capture.AllBlack
            $record['UsedFallbackResolution'] = $capture.UsedFallbackResolution
            foreach ($field in @('BufferLayout', 'SourceBytes', 'PrefixBytes')) {
                if ($capture.PSObject.Properties[$field]) { $record[$field] = $capture.$field }
            }
            Write-Host "$($VM.Name): console screenshot captured ($Stage)."
        }
    }
    catch {
        $record.Status = 'Error'; $record.Error = $_.Exception.Message
        if ($_.Exception.Data['ConsoleRawPath']) {
            $record['RawPath'] = [IO.Path]::GetFileName($_.Exception.Data['ConsoleRawPath'])
            $record['RawMetadataPath'] = [IO.Path]::GetFileName($_.Exception.Data['ConsoleRawMetadataPath'])
            $record.Width = $_.Exception.Data['ConsoleWidth']; $record.Height = $_.Exception.Data['ConsoleHeight']
        }
        $Errors.Add("Console capture ($Stage) failed: $($_.Exception.Message)")
        Write-Warning "$($VM.Name): console capture ($Stage) failed: $($_.Exception.Message)"
    }
    $Records.Add([pscustomobject]$record)
    return [pscustomobject]$record
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
    if ('MemLabs.OfflineSetupHiveReader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace MemLabs {
    public static class OfflineSetupHiveReader {
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int OROpenHive(string path, out IntPtr key);
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int OROpenKey(OfflineHandle key, string subKey, out IntPtr result);
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORGetValue(OfflineHandle key, string subKey, string name, out uint type, byte[] data, ref uint size);
        [DllImport("offreg.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORCloseHive(IntPtr key);
        [DllImport("offreg.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORCloseKey(IntPtr key);

        internal sealed class OfflineHandle : SafeHandleZeroOrMinusOneIsInvalid {
            private readonly bool root;
            internal OfflineHandle(IntPtr value, bool isRoot) : base(true) { SetHandle(value); root = isRoot; }
            protected override bool ReleaseHandle() { return (root ? ORCloseHive(handle) : ORCloseKey(handle)) == 0; }
        }
        public sealed class Key : IDisposable {
            private readonly OfflineHandle handle;
            internal Key(OfflineHandle value) { handle = value; }
            public Key OpenSubKey(string subKey, bool writable) {
                if (writable) throw new UnauthorizedAccessException("Offline setup keys are read-only.");
                IntPtr value;
                int error = OROpenKey(handle, subKey, out value);
                if (error == 2) return null;
                if (error != 0) throw new Win32Exception(error, "OROpenKey failed for " + subKey + " (native error " + error + ").");
                return new Key(new OfflineHandle(value, false));
            }
            public object GetValue(string name, object defaultValue, RegistryValueOptions options) {
                uint type;
                uint size = 0;
                int error = ORGetValue(handle, null, name, out type, null, ref size);
                if (error == 2) return defaultValue;
                if (error != 0 && error != 234) throw new Win32Exception(error, "ORGetValue sizing failed for " + name + ".");
                if (size > 1048576) throw new InvalidDataException("Offline setup value exceeds the 1 MiB metadata limit: " + name);
                byte[] data = new byte[size];
                error = ORGetValue(handle, null, name, out type, data, ref size);
                if (error != 0) throw new Win32Exception(error, "ORGetValue failed for " + name + ".");
                if (type == 1 || type == 2) return Encoding.Unicode.GetString(data, 0, (int)size).TrimEnd('\0');
                if (type == 4 && size == 4) return BitConverter.ToInt32(data, 0);
                if (type == 11 && size == 8) return BitConverter.ToInt64(data, 0);
                if (type == 7) {
                    string text = Encoding.Unicode.GetString(data, 0, (int)size).TrimEnd('\0');
                    return text.Length == 0 ? new string[0] : text.Split('\0');
                }
                throw new InvalidDataException("Unsupported offline setup value type/size for " + name + ": " + type + "/" + size);
            }
            public void Dispose() { handle.Dispose(); }
        }
        public static Key OpenReadOnly(string path) {
            IntPtr value;
            int error = OROpenHive(path, out value);
            if (error != 0) throw new Win32Exception(error, "OROpenHive failed (native error " + error + "). The private copy could not be inspected; this does not establish guest registry corruption.");
            return new Key(new OfflineHandle(value, true));
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
    $hive = [MemLabs.OfflineSetupHiveReader]::OpenReadOnly($Path)
    try {
        if ($Kind -eq 'SOFTWARE') {
            return [ordered]@{
                ImageState = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows\CurrentVersion\Setup\State' -Names @('ImageState')
                WindowsVersion = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows NT\CurrentVersion' `
                    -Names @('ProductName', 'DisplayVersion', 'CurrentBuild', 'UBR', 'EditionID', 'InstallationType')
                FirstLogonPolicy = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows\CurrentVersion\Policies\System' -Names @('EnableFirstLogonAnimation')
                WinlogonProgress = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows NT\CurrentVersion\Winlogon' `
                    -Names @('AutoAdminLogon', 'AutoLogonCount', 'DefaultUserName', 'DefaultDomainName')
                UserOobeSettings = Read-MemLabsOfflineSetupRegistryValues -Hive $hive `
                    -SubKey 'Microsoft\Windows\CurrentVersion\OOBE' `
                    -Names @('SkipUserOOBE', 'SkipMachineOOBE', 'LaunchUserOOBE', 'BypassNRO')
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
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowDirectory
    )

    if ([IO.Path]::IsPathRooted($RelativePath) -or
        @($RelativePath.Split('\') | Where-Object { $_ -in @('.', '..') }).Count) {
        throw 'Offline evidence paths must be relative and must not contain traversal segments.'
    }
    $path = $WindowsRoot
    foreach ($part in (@('') + $RelativePath.Split('\'))) {
        if ($part) { $path = Join-Path $path $part }
        # PS5.1 Get-Item can silently return no item for missing volume-GUID paths.
        try { $attributes = [IO.File]::GetAttributes($path) }
        catch [IO.FileNotFoundException] { return }
        catch [IO.DirectoryNotFoundException] { return }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse point '$path'; offline evidence must remain inside the mounted Windows volume."
        }
    }
    $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
    if ($isDirectory -and -not $AllowDirectory) { throw "Expected an evidence file, not a directory: '$path'." }
    if (-not $isDirectory -and $AllowDirectory) { throw "Expected an evidence directory, not a file: '$path'." }
    return $path
}

function Get-MemLabsOfflineAppxInventory {
    param(
        [Parameter(Mandatory)][string]$WindowsRoot,
        [Parameter(Mandatory)][string]$Bundle
    )

    $volumeRoot = [IO.DirectoryInfo]::new($WindowsRoot).Parent.FullName
    $packages = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $failedPackages = [Collections.Generic.List[object]]::new()
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1MB
    $eventPath = Join-Path $Bundle 'AppReadiness-events.json'
    if ([IO.File]::Exists($eventPath)) {
        try {
            $records = Get-Content -LiteralPath $eventPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (@($records).Count -gt 80) { throw 'The AppReadiness summary exceeds its 80-record diagnostic limit.' }
            foreach ($record in $records) {
                if ($record.Id -ne 319) { continue }
                try {
                    $textReader = [IO.StringReader]::new($record.Xml)
                    $reader = $null
                    try {
                        $reader = [Xml.XmlReader]::Create($textReader, $settings)
                        $document = [xml]::new()
                        $document.XmlResolver = $null
                        $document.Load($reader)
                    }
                    finally { if ($reader) { $reader.Dispose() }; $textReader.Dispose() }
                    $packageNode = @($document.GetElementsByTagName('Data') | Where-Object { $_.GetAttribute('Name') -eq 'PackageId' })
                    if ($packageNode.Count -ne 1) { throw 'The failed-preregistration event has no unique PackageId.' }
                    if (-not $packageNode[0].InnerText.StartsWith('Microsoft.WindowsAppRuntime.2_', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($packageNode[0].InnerText -notmatch '^Microsoft\.WindowsAppRuntime\.2_(?:[0-9]+\.){3}[0-9]+_(?:x64|x86|arm64)__8wekyb3d8bbwe$') {
                        throw 'The failed-preregistration event has an invalid Runtime 2 package identity.'
                    }
                    $relative = "Program Files\WindowsApps\$($packageNode[0].InnerText)\AppxManifest.xml"
                    $manifestPath = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $relative
                    $failedPackages.Add([pscustomobject]@{
                        PackageId = $packageNode[0].InnerText; EventTime = $record.TimeCreated
                        ExpectedManifest = $relative; ManifestPresent = [bool]$manifestPath
                    })
                }
                catch { $errors.Add("Inspect AppReadiness event 319 at '$($record.TimeCreated)': $($_.Exception.Message)") }
            }
        }
        catch { $errors.Add("Read AppReadiness package evidence: $($_.Exception.Message)") }
    }
    foreach ($location in @(
            @{ Path = 'Program Files\WindowsApps'; Prefixes = @('Microsoft.WindowsAppRuntime.2_', 'Microsoft.StartExperiencesApp_') },
            @{ Path = 'Windows\SystemApps'; Prefixes = @('MicrosoftWindows.Client.OOBE_', 'Microsoft.Windows.CloudExperienceHost_', 'MicrosoftWindows.Client.CBS_', 'Microsoft.Windows.StartMenuExperienceHost_') }
        )) {
        try {
            $directory = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $location.Path -AllowDirectory
            if (-not $directory) { $missing.Add($location.Path); continue }
            $folders = @(foreach ($prefix in $location.Prefixes) {
                    Get-ChildItem -LiteralPath $directory -Filter "$prefix*" -Directory -Force -ErrorAction Stop |
                        Select-Object -First 65
                })
            if ($folders.Count -gt 64) { throw "Too many matching package folders under $($location.Path)." }
        }
        catch { $errors.Add("Read package inventory under '$($location.Path)': $($_.Exception.Message)"); continue }
        foreach ($folder in $folders | Sort-Object Name) {
            $package = [ordered]@{
                Folder = "$($location.Path)\$($folder.Name)"; ManifestPresent = $null
                Name = $null; Version = $null; Architecture = $null; Dependencies = @(); Error = $null
            }
            try {
                $relative = "$($location.Path)\$($folder.Name)\AppxManifest.xml"
                $manifestPath = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $relative
                $package.ManifestPresent = [bool]$manifestPath
                if ($manifestPath) {
                    $manifestStream = [IO.File]::OpenRead($manifestPath)
                    $reader = $null
                    try {
                        if ($manifestStream.Length -gt 1MB) { throw "Package manifest exceeds the 1 MiB diagnostic limit: $relative" }
                        # A volume-GUID file path must not be interpreted as an XML source URI.
                        $reader = [Xml.XmlReader]::Create($manifestStream, $settings)
                        $document = [xml]::new()
                        $document.XmlResolver = $null
                        $document.Load($reader)
                    }
                    finally { if ($reader) { $reader.Dispose() }; $manifestStream.Dispose() }
                    $identity = @($document.SelectNodes('/*[local-name()="Package"]/*[local-name()="Identity"]'))
                    if ($identity.Count -ne 1) { throw "Package identity is missing/ambiguous: $relative" }
                    if (-not $identity[0].GetAttribute('Name') -or -not $identity[0].GetAttribute('Version')) {
                        throw "Package identity name/version is missing: $relative"
                    }
                    $package['Name'] = $identity[0].GetAttribute('Name')
                    $package['Version'] = $identity[0].GetAttribute('Version')
                    $package['Architecture'] = $identity[0].GetAttribute('ProcessorArchitecture')
                    $dependencies = @($document.SelectNodes('/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="PackageDependency" or local-name()="MainPackageDependency"]'))
                    if ($dependencies.Count -gt 128) { throw "Package dependency count exceeds the diagnostic limit: $relative" }
                    $package['Dependencies'] = @($dependencies | ForEach-Object {
                            [pscustomobject]@{ Type = $_.LocalName; Name = $_.GetAttribute('Name'); MinVersion = $_.GetAttribute('MinVersion'); Publisher = $_.GetAttribute('Publisher') }
                        })
                }
            }
            catch {
                $package.Error = $_.Exception.Message
                $errors.Add("Read package '$($package.Folder)': $($_.Exception.Message)")
            }
            $packages.Add([pscustomobject]$package)
        }
    }
    [pscustomobject]@{
        Version = 1; Purpose = 'Read-only package payload/dependency evidence, not a diagnosis of corruption'
        FailedRuntimePreregistration = $failedPackages.ToArray()
        Packages = $packages.ToArray(); MissingDirectories = $missing.ToArray(); Errors = $errors.ToArray()
    }
}

function Copy-MemLabsBoundedDiagnosticFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][long]$MaxTotalBytes,
        [Parameter(Mandatory)][hashtable]$Budget
    )
    $inputStream = $null; $created = $false
    try {
        $inputStream = [IO.File]::OpenRead($Source)
        $length = $inputStream.Length
        if ($length -gt $MaxBytes) { throw "Evidence file exceeds its $MaxBytes-byte limit ($length bytes): $Source" }
        if ([long]$Budget.Bytes -lt 0 -or [long]$Budget.Bytes -gt $MaxTotalBytes -or
            $length -gt $MaxTotalBytes - [long]$Budget.Bytes) { throw "Evidence file exceeds the $MaxTotalBytes-byte aggregate limit: $Source" }
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        try {
            $inputStream.CopyTo($outputStream)
            if ($outputStream.Length -ne $length) { throw "Evidence length changed while copying: $Source" }
        }
        finally { $outputStream.Dispose() }
        $Budget.Bytes = [long]$Budget.Bytes + $length
        return $length
    }
    catch {
        if ($created) { [IO.File]::Delete($Destination) }
        throw
    }
    finally { if ($inputStream) { $inputStream.Dispose() } }
}

function Copy-MemLabsOfflineOobeWerReports {
    param([string]$WindowsRoot, [string]$Bundle, $Manifest)
    $volumeRoot = [IO.DirectoryInfo]::new($WindowsRoot).Parent.FullName
    $budget = @{ Bytes = 0L }
    foreach ($location in @('ProgramData\Microsoft\Windows\WER\ReportArchive', 'ProgramData\Microsoft\Windows\WER\ReportQueue')) {
        try {
            $directory = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $location -AllowDirectory
            if (-not $directory) { $Manifest.Missing.Add($location); continue }
            $folders = @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop |
                Where-Object Name -match 'FirstLogonAnim|CloudExperienceHost|Client[._]OOBE|msoobe|WWAHost|Winlogon' |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 65)
            if ($folders.Count -gt 64) { $Manifest.Errors.Add("WER evidence exceeds the 64-report limit under $location; only the newest 64 reports are retained.") }
            foreach ($folder in $folders | Select-Object -First 64) {
                try {
                    $relative = "$location\$($folder.Name)\Report.wer"
                    $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $relative
                    if (-not $source) { $Manifest.Missing.Add($relative); continue }
                    $reportName = 'WER-{0:D3}.wer' -f @($Manifest.Files | Where-Object Kind -eq 'OobeWerReport').Count
                    $bytes = Copy-MemLabsBoundedDiagnosticFile -Source $source -Destination (Join-Path $Bundle $reportName) `
                        -MaxBytes 1MB -MaxTotalBytes 64MB -Budget $budget
                    $Manifest.Files.Add([ordered]@{
                        Path = $reportName; Kind = 'OobeWerReport'; Source = $relative
                        SourceBytes = $bytes; Truncated = $false; SourceLastWriteUtc = [IO.File]::GetLastWriteTimeUtc($source).ToString('o')
                    })
                }
                catch { $Manifest.Errors.Add("Read OOBE WER report '$($folder.Name)': $($_.Exception.Message)") }
            }
        }
        catch { $Manifest.Errors.Add("Read OOBE WER reports under '$location': $($_.Exception.Message)") }
    }
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
            'Logs\MoSetup\BlueBox.log', 'Debug\NetSetup.log',
            'Logs\CBS\CBS.log', 'Logs\DISM\dism.log', 'Debug\UserMode\userenv.log'
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

    $traceBudget = @{ Bytes = 0L }
    foreach ($relative in @('Panther\setup.etl', 'Panther\UnattendGC\setup.etl')) {
        try {
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath $relative
            if (-not $source) { $Manifest.Missing.Add($relative); continue }
            $target = Join-Path $Bundle "SetupLogs\$relative"
            $null = New-Item -Path (Split-Path $target -Parent) -ItemType Directory -Force -ErrorAction Stop
            $bytes = Copy-MemLabsBoundedDiagnosticFile -Source $source -Destination $target -MaxBytes 64MB -MaxTotalBytes 128MB -Budget $traceBudget
            $Manifest.Files.Add([ordered]@{ Path = "SetupLogs\$relative"; Kind = 'SetupTrace'; SourceBytes = $bytes; Truncated = $false })
        }
        catch { $Manifest.Errors.Add("Copy full setup trace '$relative': $($_.Exception.Message)") }
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
            # The offline library reads private copies without a host registry mount.
            $registryState[$kind] = Read-MemLabsOfflineWindowsSetupHive -Path $copy -Kind $kind
        }
        catch { $Manifest.Errors.Add("Read offline $kind setup state: $($_.Exception.Message)") }
    }
    if ($registryState.Count -gt 0) {
        $registryState | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $Bundle 'WindowsSetupState.json') -Encoding UTF8 -ErrorAction Stop
        $Manifest.Files.Add([ordered]@{ Path = 'WindowsSetupState.json'; Truncated = $false })
    }
    $eventSources = [Collections.Generic.List[object]]::new()
    foreach ($eventSource in @(
            @{ Name = 'Setup'; File = 'Setup.evtx' },
            @{ Name = 'System'; File = 'System.evtx' },
            @{ Name = 'Application'; File = 'Application.evtx' },
            @{ Name = 'DSC-Operational'; File = 'Microsoft-Windows-DSC%4Operational.evtx' },
            @{ Name = 'UserProfiles'; File = 'Microsoft-Windows-User Profile Service%4Operational.evtx' },
            @{ Name = 'UserProfiles-Legacy'; File = 'Microsoft-Windows-User Profiles Service%4Operational.evtx' },
            @{ Name = 'AppReadiness'; File = 'Microsoft-Windows-AppReadiness%4Admin.evtx' },
            @{ Name = 'Shell-Core'; File = 'Microsoft-Windows-Shell-Core%4Operational.evtx' },
            @{ Name = 'AppModel'; File = 'Microsoft-Windows-AppModel-Runtime%4Admin.evtx' },
            @{ Name = 'Winlogon'; File = 'Microsoft-Windows-Winlogon%4Operational.evtx' },
            @{ Name = 'AppXDeployment'; File = 'Microsoft-Windows-AppXDeploymentServer%4Operational.evtx' },
            @{ Name = 'TaskScheduler'; File = 'Microsoft-Windows-TaskScheduler%4Operational.evtx' },
            @{ Name = 'CloudExperienceHost'; File = 'Microsoft-Windows-CloudExperienceHost%4Operational.evtx' },
            @{ Name = 'UserOobeSignIn'; File = 'Security.evtx';
                XPath = "*[System[(EventID=4624 or EventID=4625)] and EventData[Data[@Name='TargetUserName']='defaultuser0']]" }
        )) {
        if (-not $eventSource.ContainsKey('XPath')) { $eventSource.XPath = $null }
        $eventSources.Add($eventSource)
    }
    try {
        $directory = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath 'System32\winevt\Logs' -AllowDirectory
        if ($directory) {
            $known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($source in $eventSources) { $null = $known.Add($source.File) }
            foreach ($prefix in @('User Profile', 'Winlogon', 'AppReadiness', 'AppXDeployment', 'AppModel', 'Shell-Core',
                    'CloudExperienceHost', 'OOBE', 'Authentication User Interface', 'User Device Registration',
                    'ModernDeployment-Diagnostics-Provider', 'DeviceManagement-Enterprise-Diagnostics-Provider', 'AppLocker', 'CodeIntegrity')) {
                foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter "Microsoft-Windows-$prefix*.evtx" `
                        -File -Force -ErrorAction Stop | Sort-Object Name | Select-Object -First 65)) {
                    if (-not $known.Add($file.Name)) { continue }
                    if ($eventSources.Count -ge 64) { throw 'Discovered event evidence exceeds the 64-channel limit.' }
                    $eventSources.Add(@{ Name = ('Additional-{0:D2}' -f $eventSources.Count); File = $file.Name; XPath = $null })
                }
            }
        }
    }
    catch { $Manifest.Errors.Add("Discover offline logon/OOBE event channels: $($_.Exception.Message)") }
    $rawDirectory = Join-Path $Bundle 'EventLogs'
    $null = New-Item -Path $rawDirectory -ItemType Directory -Force -ErrorAction Stop
    $rawBudget = @{ Bytes = 0L }
    $Manifest['EventLogs'] = [Collections.Generic.List[object]]::new()
    $Manifest['EventEvidenceLimits'] = [ordered]@{
        MaxChannels = 64; MaxRawBytesPerLog = 64MB; MaxRawBytesTotal = 256MB
        MaxSummaryScan = 1000; MaxSummaryRecords = 80; MaxDefaultUserSignInRecords = 1000
        SecurityScope = 'Only defaultuser0 event 4624/4625 records; absence does not prove logon success or that auditing was enabled.'
    }
    foreach ($eventSource in $eventSources) {
        $log = $eventSource.Name
        $eventRecordInfo = [ordered]@{
            Name = $log; Source = $eventSource.File; Status = 'Missing'
            RawStatus = 'NotCollected'; RawPath = $null; SummaryPath = $null; XPath = $eventSource.XPath
        }
        $Manifest.EventLogs.Add($eventRecordInfo)
        try {
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $WindowsRoot -RelativePath "System32\winevt\Logs\$($eventSource.File)"
            if (-not $source) { $Manifest.Missing.Add($eventSource.File); continue }
            $eventRecordInfo.Status = 'Collecting'
            if (-not $eventSource.XPath) {
                try {
                    $relative = "EventLogs\$log.evtx"
                    $bytes = Copy-MemLabsBoundedDiagnosticFile -Source $source -Destination (Join-Path $Bundle $relative) `
                        -MaxBytes 64MB -MaxTotalBytes 256MB -Budget $rawBudget
                    $Manifest.Files.Add([ordered]@{
                        Path = $relative; Kind = 'RawEventLog'; Source = $eventSource.File
                        SourceBytes = $bytes; Truncated = $false
                    })
                    $eventRecordInfo.RawStatus = 'Copied'; $eventRecordInfo.RawPath = $relative
                }
                catch {
                    $eventRecordInfo.RawStatus = 'Error'
                    $Manifest.Errors.Add("Copy full offline $log EVTX: $($_.Exception.Message)")
                }
            }
            else { $eventRecordInfo.RawStatus = 'ScopedSignInSummaryOnly' }
            Write-Host "Summarizing offline $log events."
            $sourceRecordCount = 0
            $eventParameters = @{ Path = [Management.Automation.WildcardPattern]::Escape($source); MaxEvents = 1000; ErrorAction = 'Stop' }
            if ($eventSource.XPath) { $eventParameters.FilterXPath = $eventSource.XPath }
            $summaryLimit = if ($eventSource.XPath) { 1000 } else { 80 }
            $events = @(Get-WinEvent @eventParameters |
                ForEach-Object { $sourceRecordCount++; $_ } |
                Where-Object { $log -notin @('System', 'Application') -or
                    $_.ProviderName -match 'Setup|OOBE|Netlogon|Kernel-Boot|Kernel-Power|User32|Winlogon|User Profiles? Service|Application Error|Windows Error Reporting|AppModel|CloudExperienceHost' -or
                    $_.Id -in @(6005, 6006, 6008) } |
                Select-Object -First $summaryLimit |
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
            if ($sourceRecordCount -eq 0) { throw 'The offline event query returned no records without an empty-log status; evidence could not be verified.' }
            if ($eventSource.XPath -and $sourceRecordCount -ge 1000) {
                $Manifest.Errors.Add('The defaultuser0 sign-in summary reached its 1,000-event limit; sign-in history may be incomplete.')
            }
            ConvertTo-Json -InputObject $events -Depth 5 |
                Set-Content -LiteralPath (Join-Path $Bundle "$log-events.json") -Encoding UTF8 -ErrorAction Stop
            $eventRecordInfo.Status = 'Collected'; $eventRecordInfo.SummaryPath = "$log-events.json"
            $Manifest.Files.Add([ordered]@{ Path = "$log-events.json"; Truncated = -not $eventSource.XPath -or $sourceRecordCount -ge 1000 })
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Set-Content -LiteralPath (Join-Path $Bundle "$log-events.json") -Value '[]' -Encoding UTF8 -ErrorAction Stop
                $Manifest.Files.Add([ordered]@{ Path = "$log-events.json"; Truncated = $false })
                $eventRecordInfo.Status = 'NoMatchingEvents'; $eventRecordInfo.SummaryPath = "$log-events.json"
            }
            else {
                $eventRecordInfo.Status = 'Error'
                $Manifest.Errors.Add("Read offline $log events: $($_.Exception.Message)")
            }
        }
    }
    Copy-MemLabsOfflineOobeWerReports -WindowsRoot $WindowsRoot -Bundle $Bundle -Manifest $Manifest
    $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $WindowsRoot -Bundle $Bundle
    $inventory | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $Bundle 'AppxPrerequisiteInventory.json') -Encoding UTF8 -ErrorAction Stop
    $Manifest.Files.Add([ordered]@{ Path = 'AppxPrerequisiteInventory.json'; Truncated = $false })
    foreach ($errorMessage in $inventory.Errors) { $Manifest.Errors.Add($errorMessage) }
}

function Invoke-MemLabsWindowsSetupDiagnostics {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(5, 600)][int]$StopTimeoutSeconds = 90,
        [switch]$AllowTurnOff,
        [switch]$IncludeLiveProbe,
        [switch]$IncludeHangDump,
        [pscredential]$GuestCredential
    )

    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VmName)) {
        throw 'Specify one exact VM name, not a wildcard.'
    }
    $vms = @(Get-VM -Name $VmName -ErrorAction Stop)
    if ($vms.Count -ne 1 -or $vms[0].Name -ine $VmName) { throw 'Exactly one matching VM is required.' }
    $vm = $vms[0]
    $action = if ($IncludeHangDump) { 'Capture the live FirstLogonAnim hang dump, collect diagnostics without repair, and leave Off; never start the VM' }
    elseif ($IncludeLiveProbe) { 'Start if Off, observe and inspect first logon without repair, then collect offline evidence and leave Off' } else {
        'Stop if necessary, collect read-only Windows setup evidence, and leave the VM off'
    }
    if (-not $PSCmdlet.ShouldProcess($vm.Name, $action)) { return }
    if ($IncludeHangDump -and "$($vm.State)" -ne 'Running') { throw 'Hang-dump collection requires an already Running VM displaying the stall; it will not boot or resume a VM.' }
    if ($IncludeLiveProbe -and "$($vm.State)" -notin @('Off', 'Running')) { throw 'Live inspection requires an Off or Running VM; resume or shut it down normally first.' }
    Initialize-MemLabsSetupDiagnosticModules -IncludeLiveProbe:$IncludeLiveProbe
    if ($IncludeLiveProbe -or $IncludeHangDump) {
        $GuestCredential = Resolve-MemLabsOobeRepairCredential -GuestCredential $GuestCredential
    }
    if ($IncludeLiveProbe) {
        $liveGuestBlock = Get-MemLabsFirstLogonGuestBlock
    }
    if ($IncludeHangDump) { $dumpGuestBlock = Get-MemLabsFirstLogonDumpGuestBlock }
    $destinationPath = Resolve-MemLabsSetupDiagnosticPath -Path $Destination
    $safeName = $vm.Name -replace '[\\/:*?"<>|]', '_'
    $name = "$safeName-SetupFailure-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $collectionRoot = Join-Path $destinationPath $name
    New-MemLabsPrivateDiagnosticDirectory -Path $collectionRoot
    $bundle = Join-Path $collectionRoot 'Bundle'
    $privateRoot = Join-Path $collectionRoot 'PrivateState'
    $null = New-Item -Path $bundle, $privateRoot -ItemType Directory
    $manifest = @{
        SchemaVersion = 1; CollectorVersion = 8; RegistryReader = 'offreg.dll'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Host = $env:COMPUTERNAME; VMName = $vm.Name; VMId = "$($vm.Id)"
        OriginalState = "$($vm.State)"; FinalState = ''; Status = 'Collecting'
        Files = [Collections.Generic.List[object]]::new()
        Missing = [Collections.Generic.List[string]]::new()
        Errors = [Collections.Generic.List[string]]::new()
        Disks = [Collections.Generic.List[object]]::new()
        Screenshots = [Collections.Generic.List[object]]::new()
        LiveProbe = [ordered]@{
            Requested = [bool]$IncludeLiveProbe; Status = 'NotRequested'; ReadOnlyGuestQueries = $true
            StartAttempted = $false; StartedVm = $false; ObservationSeconds = 190
            RepairPerformed = $false; AuthenticationRetried = $false
            Stages = [Collections.Generic.List[object]]::new(); Error = $null
        }
        HangDump = [ordered]@{
            Requested = [bool]$IncludeHangDump; Status = 'NotRequested'
            Token = $(if ($IncludeHangDump) { [guid]::NewGuid().ToString('N') } else { $null })
            Capture = $null; Error = $null
            GuestDumpRetention = 'A captured dump remains in its protected guest directory; the offline mount is never made writable to delete it.'
        }
        Privacy = 'No unattend XML, SAM, SECURITY registry hive, or raw registry hives are archived. Security event summaries are limited to defaultuser0 sign-ins. Opt-in hang dumps contain process memory. Console images and logs may contain visible guest data, device/account identifiers, paths, or other sensitive details; review the protected archive before sharing.'
    }
    $fatal = $null
    $windowsFound = $false
    $mountCleanupFailed = $false
    try {
        if ($IncludeHangDump) {
            $null = Add-MemLabsSetupConsoleScreenshot -VM $vm -Bundle $bundle -Stage BeforeDump `
                -Records $manifest.Screenshots -Errors $manifest.Errors
            try { Invoke-MemLabsFirstLogonHangDump -VM $vm -GuestCredential $GuestCredential -GuestBlock $dumpGuestBlock -Manifest $manifest }
            catch {
                $manifest.Errors.Add("Hang-dump capture outcome could not be verified; preserving the running VM without shutdown or mounting: $($_.Exception.Message)")
                throw
            }
        }
        if ($IncludeLiveProbe) {
            try { Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $GuestCredential -GuestBlock $liveGuestBlock -Bundle $bundle -Manifest $manifest }
            catch {
                $manifest.LiveProbe.Status = 'Failed'; $manifest.LiveProbe.Error = $_.Exception.Message
                $manifest.Errors.Add("Read-only live probe failed; no authentication retry or repair was attempted: $($_.Exception.Message)")
                if ($_.Exception.Data['FirstLogonProbePowerIndeterminate']) {
                    $manifest.LiveProbe.Status = 'Indeterminate'
                    throw 'Live probe startup outcome is unknown. No further power operation or disk mount is safe; inspect the report before retrying.'
                }
                Write-Warning "Live inspection failed: $($_.Exception.Message). Continuing with offline evidence only."
            }
            $vm = Get-VM -Id $vm.Id -ErrorAction Stop
            if ($vm.Name -ne $manifest.VMName) { throw 'The selected VM identity changed during live inspection.' }
        }
        $null = Add-MemLabsSetupConsoleScreenshot -VM $vm -Bundle $bundle -Stage BeforeStop `
            -Records $manifest.Screenshots -Errors $manifest.Errors
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
                        if ($IncludeHangDump) {
                            try { Copy-MemLabsOfflineFirstLogonDump -WindowsRoot $windows -Bundle $bundle -Manifest $manifest }
                            catch {
                                $manifest.HangDump.Status = 'CopyFailed'
                                $manifest.Errors.Add("Copy/verify FirstLogon dump through the read-only mount: $($_.Exception.Message)")
                            }
                        }
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
    foreach ($consoleRecord in $manifest.Screenshots) {
        if ($consoleRecord.Status -eq 'Captured') { $manifest.Files.Add([ordered]@{ Path = $consoleRecord.Path; Truncated = $false; Kind = 'ConsoleScreenshot' }) }
        if ($consoleRecord.PSObject.Properties['RawPath']) {
            $manifest.Files.Add([ordered]@{ Path = $consoleRecord.RawPath; Truncated = $false; Kind = 'RawConsoleFramebuffer' })
            $manifest.Files.Add([ordered]@{ Path = $consoleRecord.RawMetadataPath; Truncated = $false; Kind = 'RawConsoleMetadata' })
        }
    }
    if ($manifest.HangDump.Status -eq 'Captured') {
        $manifest.Errors.Add('A live dump was captured but no offline copy was verified; it remains at the reported guest path.')
        $manifest.HangDump.Status = 'NotCopied'
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

if (-not $PSBoundParameters.ContainsKey('Destination')) {
    $Destination = (Join-Path $PSScriptRoot '..\logs\setup-diagnostics')
}
$collectorParameters = @{} + $PSBoundParameters
$collectorParameters.Destination = $Destination
$collectorParameters.StopTimeoutSeconds = $StopTimeoutSeconds
$operation = 'Invoke-MemLabsWindowsSetupDiagnostics'
if ($RepairOobe) {
    . (Join-Path $PSScriptRoot 'Common.WindowsVmOobeRepair.ps1')
    $null = $collectorParameters.Remove('RepairOobe')
    $collectorParameters.RepairTimeoutSeconds = $RepairTimeoutSeconds
    $collectorParameters.BackupTimeoutSeconds = $BackupTimeoutSeconds
    $operation = 'Invoke-MemLabsWindowsOobeRepair'
}
elseif ($PSCmdlet.ParameterSetName -eq 'Repair') { throw 'Repair parameters require -RepairOobe to be explicitly enabled.' }
elseif ($IncludeLiveProbe -or $IncludeHangDump) {
    . (Join-Path $PSScriptRoot 'Common.WindowsVmOobeRepair.ps1')
    if ($IncludeLiveProbe) { . (Join-Path $PSScriptRoot 'Common.WindowsVmFirstLogonProbe.ps1') }
    if ($IncludeHangDump) { . (Join-Path $PSScriptRoot 'Common.WindowsVmFirstLogonDump.ps1') }
}
elseif ($PSCmdlet.ParameterSetName -eq 'Live') { throw 'Live probe parameters require -IncludeLiveProbe to be explicitly enabled.' }
elseif ($PSCmdlet.ParameterSetName -eq 'Dump') { throw 'Hang-dump parameters require -IncludeHangDump to be explicitly enabled.' }
if ($WhatIfPreference) { & $operation @collectorParameters; return }
$mutationMutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
$leaseHeld = $false
try {
    try { $leaseHeld = $mutationMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] {
        $leaseHeld = $true
        Write-Warning 'The previous host mutation lease owner exited unexpectedly; acquiring the abandoned lease for collection.'
    }
    if (-not $leaseHeld) { throw 'Another MemLabs operation owns the host mutation lease. Stop the active deployment/test retry loop before collecting setup diagnostics.' }
    & $operation @collectorParameters
}
finally {
    try { if ($leaseHeld) { $mutationMutex.ReleaseMutex() } }
    finally { $mutationMutex.Dispose() }
}
