#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Collector parse errors: $($errors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module Microsoft.PowerShell.Archive -ErrorAction Stop
Initialize-MemLabsOfflineSetupHiveType
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace MemLabs {
    public static class SetupDiagnosticTestSupport {
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
        private static extern int RegLoadAppKey(string path, out IntPtr key, int access, int options, int reserved);
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int OROpenHive(string path, out IntPtr key);
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int OROpenKey(IntPtr key, string name, out IntPtr result);
        [DllImport("offreg.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORSetKeySecurity(IntPtr key, uint information, byte[] descriptor);
        [DllImport("offreg.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORSaveHive(IntPtr key, string path, uint major, uint minor);
        [DllImport("offreg.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORCloseKey(IntPtr key);
        [DllImport("offreg.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int ORCloseHive(IntPtr key);

        public static void CreateMixedSecurityFixture(string source, string destination, byte[] descriptor) {
            IntPtr root;
            int error = OROpenHive(source, out root);
            if (error != 0) throw new Win32Exception(error);
            try {
                IntPtr key;
                error = OROpenKey(root, "Setup", out key);
                if (error != 0) throw new Win32Exception(error);
                try {
                    error = ORSetKeySecurity(key, 4, descriptor);
                    if (error != 0) throw new Win32Exception(error);
                }
                finally { ORCloseKey(key); }
                error = ORSaveHive(root, destination, 10, 0);
                if (error != 0) throw new Win32Exception(error);
            }
            finally { ORCloseHive(root); }
        }
        public static RegistryKey OpenWritableFixture(string path) {
            IntPtr value;
            int error = RegLoadAppKey(path, out value, 0xF003F, 1, 0);
            if (error != 0) throw new Win32Exception(error);
            SafeRegistryHandle handle = new SafeRegistryHandle(value, true);
            try { return RegistryKey.FromHandle(handle); }
            catch { handle.Dispose(); throw; }
        }
        public sealed class LeaseHolder : IDisposable {
            private readonly ManualResetEvent ready = new ManualResetEvent(false);
            private readonly ManualResetEvent release = new ManualResetEvent(false);
            private readonly Thread thread;
            private Exception error;
            private volatile bool abandon;
            public bool Acquired { get; private set; }
            public LeaseHolder(string name) {
                thread = new Thread(() => {
                    try {
                        using (Mutex mutex = new Mutex(false, name)) {
                            Acquired = mutex.WaitOne(0);
                            ready.Set();
                            if (Acquired) {
                                release.WaitOne(30000);
                                if (!abandon) mutex.ReleaseMutex();
                            }
                        }
                    }
                    catch (Exception failure) { error = failure; ready.Set(); }
                });
                thread.IsBackground = true;
                thread.Start();
                if (!ready.WaitOne(5000)) { Dispose(); throw new TimeoutException("Fixture lease thread did not start."); }
                if (error != null) { Dispose(); throw new InvalidOperationException("Fixture lease failed.", error); }
            }
            public void Abandon() { abandon = true; release.Set(); }
            public void Dispose() {
                release.Set();
                if (!thread.Join(5000)) throw new TimeoutException("Fixture lease thread did not stop.");
                ready.Dispose();
                release.Dispose();
            }
        }
    }
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-offline-setup-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $testRoot -ItemType Directory
try {
    $aclPath = Join-Path $testRoot 'acl'
    New-MemLabsPrivateDiagnosticDirectory -Path $aclPath
    $acl = Get-Acl -LiteralPath $aclPath
    Assert-True $acl.AreAccessRulesProtected 'Diagnostic output inherits potentially public permissions.'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $allowedSids = @('S-1-5-18', 'S-1-5-32-544', $identity.User.Value) }
    finally { $identity.Dispose() }
    $rules = @($acl.Access)
    foreach ($rule in $rules) {
        Assert-True ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $allowedSids -and
            $rule.AccessControlType -eq 'Allow') 'Diagnostic output grants unexpected access.'
    }
    foreach ($sid in $allowedSids) {
        Assert-True (@($rules | Where-Object {
                    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid -and
                    ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
                }).Count -gt 0) 'A required caller/SYSTEM/Administrators permission is missing.'
    }

    $fixtureHivePath = Join-Path $aclPath 'Synthetic.hiv'
    $fixtureHive = [MemLabs.SetupDiagnosticTestSupport]::OpenWritableFixture($fixtureHivePath)
    try {
        foreach ($entry in @(
                @{ Path = 'Select'; Values = @{ Current = 1 } },
                @{ Path = 'Setup'; Values = @{ OOBEInProgress = 1; SystemSetupInProgress = 1; CmdLine = 'windeploy.exe'; IgnoredSecret = 'DO-NOT-EXPORT-THIS-SYNTHETIC-VALUE' } },
                @{ Path = 'Setup\Status\ChildCompletion'; Values = @{ 'setup.exe' = 1 } },
                @{ Path = 'ControlSet001\Control\ComputerName\ActiveComputerName'; Values = @{ ComputerName = 'DESKTOP-FIXTURE' } },
                @{ Path = 'ControlSet001\Control\ComputerName\ComputerName'; Values = @{ ComputerName = 'CST-W11CLIENT1' } },
                @{ Path = 'ControlSet001\Services\Tcpip\Parameters'; Values = @{ Domain = 'cstest8.com'; Hostname = 'DESKTOP-FIXTURE' } },
                @{ Path = 'Microsoft\Windows\CurrentVersion\Setup\State'; Values = @{ ImageState = 'IMAGE_STATE_UNDEPLOYABLE' } },
                @{ Path = 'Microsoft\Windows NT\CurrentVersion'; Values = @{ CurrentBuild = '26300'; UBR = 9457 } }
            )) {
            $key = $fixtureHive.CreateSubKey($entry.Path)
            try {
                foreach ($name in $entry.Values.Keys) { $key.SetValue($name, $entry.Values[$name]) }
            }
            finally { $key.Dispose() }
        }
    }
    finally { $fixtureHive.Dispose() }
    $originalHiveHash = (Get-FileHash -LiteralPath $fixtureHivePath -Algorithm SHA256).Hash
    $systemState = Read-MemLabsOfflineWindowsSetupHive -Path $fixtureHivePath -Kind SYSTEM
    $softwareState = Read-MemLabsOfflineWindowsSetupHive -Path $fixtureHivePath -Kind SOFTWARE
    Assert-True ($systemState.ControlSet.Values.Current -eq 1 -and $systemState.Setup.Values.OOBEInProgress -eq 1 -and
        $systemState.ActiveName.Values.ComputerName -eq 'DESKTOP-FIXTURE' -and
        $systemState.PendingName.Values.ComputerName -eq 'CST-W11CLIENT1' -and
        $systemState.Tcpip.Values.Domain -eq 'cstest8.com') 'Native offline setup/name/domain extraction is incorrect.'
    Assert-True ($softwareState.ImageState.Values.ImageState -eq 'IMAGE_STATE_UNDEPLOYABLE' -and
        $softwareState.WindowsVersion.Values.UBR -eq 9457) 'Native offline image/version extraction is incorrect.'
    Assert-True (-not (($systemState | ConvertTo-Json -Depth 10).Contains('DO-NOT-EXPORT-THIS-SYNTHETIC-VALUE'))) `
        'Offline registry extraction escaped its value allowlist.'
    $readOnlyHive = [MemLabs.OfflineSetupHiveReader]::OpenReadOnly($fixtureHivePath)
    try {
        $writeBlocked = $false
        try { $null = $readOnlyHive.OpenSubKey('Setup', $true) }
        catch { $writeBlocked = $true }
        Assert-True $writeBlocked 'The native offline registry handle permits writes.'
    }
    finally { $readOnlyHive.Dispose() }
    Assert-True ((Get-FileHash -LiteralPath $fixtureHivePath -Algorithm SHA256).Hash -eq $originalHiveHash) `
        'Read-only offline inspection changed its input hive.'
    $mixedHivePath = Join-Path $aclPath 'MixedSecurity.hiv'
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new('D:P(A;;KA;;;SY)(A;;KR;;;WD)')
    $descriptorBytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($descriptorBytes, 0)
    [MemLabs.SetupDiagnosticTestSupport]::CreateMixedSecurityFixture($fixtureHivePath, $mixedHivePath, $descriptorBytes)
    $mixedHash = (Get-FileHash -LiteralPath $mixedHivePath -Algorithm SHA256).Hash
    $mixedState = Read-MemLabsOfflineWindowsSetupHive -Path $mixedHivePath -Kind SYSTEM
    Assert-True ($mixedState.Setup.Values.OOBEInProgress -eq 1 -and
        $mixedState.ActiveName.Values.ComputerName -eq 'DESKTOP-FIXTURE' -and
        (Get-FileHash -LiteralPath $mixedHivePath -Algorithm SHA256).Hash -eq $mixedHash) `
        'OS-style mixed key security descriptors prevent read-only offline extraction.'

    $script:GuestRoot = Join-Path $testRoot 'guest'
    $script:EmptyRoot = Join-Path $testRoot 'empty'
    $windows = Join-Path $script:GuestRoot 'Windows'
    $null = New-Item -Path (Join-Path $windows 'Panther'), (Join-Path $windows 'System32\config'),
        (Join-Path $windows 'System32\winevt\Logs'), (Join-Path $windows 'Debug'), $script:EmptyRoot -ItemType Directory -Force
    [IO.File]::WriteAllText((Join-Path $windows 'Panther\setupact.log'), 'Synthetic setup failure in specialize')
    [IO.File]::WriteAllText((Join-Path $windows 'Panther\setuperr.log'), 'Synthetic setup error')
    [IO.File]::WriteAllText((Join-Path $windows 'Debug\NetSetup.log'), 'Synthetic domain-join error')
    [IO.File]::WriteAllText((Join-Path $windows 'Panther\unattend.xml'), 'RAW-SECRET-MUST-NOT-BE-ARCHIVED')
    foreach ($hive in @('SYSTEM', 'SOFTWARE', 'SAM', 'SECURITY')) {
        [IO.File]::WriteAllText((Join-Path $windows "System32\config\$hive"), 'RAW-SECRET-MUST-NOT-BE-ARCHIVED')
    }
    foreach ($log in @('Setup', 'System', 'Application', 'Microsoft-Windows-DSC%4Operational')) {
        [IO.File]::WriteAllText((Join-Path $windows "System32\winevt\Logs\$log.evtx"), 'event fixture')
    }
    $script:Protected = [Collections.Generic.List[string]]::new()
    function New-MemLabsPrivateDiagnosticDirectory {
        param($Path)
        $script:Protected.Add($Path)
        $null = New-Item -Path $Path -ItemType Directory -Force
    }
    $script:VmId = [guid]::NewGuid()
    function Get-VM {
        param($Name, $Id, $ErrorAction)
        $script:VmReads++
        if ($Name -and $Name -ne 'BROKEN-W11') { throw "Unexpected VM name $Name" }
        if ($Id -and $Id -ne $script:VmId) { throw "Unexpected VM ID $Id" }
        if ($Name) {
            for ($i = 0; $i -lt $script:VmCount; $i++) {
                [pscustomobject]@{ Name = 'BROKEN-W11'; Id = $script:VmId; State = $script:VmState }
            }
        }
        else { [pscustomobject]@{ Name = 'BROKEN-W11'; Id = $script:VmId; State = $script:VmState } }
    }
    function Stop-VM {
        param($VM, [switch]$AsJob, [switch]$TurnOff, $Confirm, $ErrorAction)
        Assert-True ($VM.Id -eq $script:VmId -and $AsJob) 'Shutdown was not scoped to the selected VM or was unbounded.'
        $script:StopCalls++
        if ($TurnOff) {
            $script:ForceCalls++
            if ($script:ForceWorks) { $script:VmState = 'Off' }
        }
        elseif ($script:GracefulWorks) { $script:VmState = 'Off' }
        [pscustomobject]@{ State = $(if ($script:VmState -eq 'Off') { 'Completed' } else { 'Running' }) }
    }
    function Wait-Job {
        param($Job, $Timeout, $ErrorAction)
        $script:WaitBudgets.Add($Timeout)
        Assert-True ($Timeout -in @(5, 30, 90)) 'Shutdown wait has an unexpected budget.'
        if ($Job.State -eq 'Completed') { return $Job }
    }
    function Receive-Job { param($Job, $ErrorAction) }
    function Stop-Job {
        param($Job, $ErrorAction)
        if ($script:StopJobFails) { throw 'Synthetic stop-job cleanup failure' }
        $Job.State = 'Stopped'
    }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction); $script:RemovedJobs++ }
    function Start-VM { throw 'The collector must not restart a VM.' }
    function Restart-VM { throw 'The collector must not reset a VM.' }
    function Get-VMHardDiskDrive {
        param($VM, $ErrorAction)
        Assert-True ($VM.Id -eq $script:VmId) 'Another VM disk inventory was queried.'
        [pscustomobject]@{ Path = 'C:\fixture\active-leaf.avhdx'; ControllerNumber = 0; ControllerLocation = 0 }
    }
    function Get-VHD {
        param($Path, $ErrorAction)
        Assert-True ($Path -eq 'C:\fixture\active-leaf.avhdx') 'A parent/base image was inspected instead of the active disk.'
        [pscustomobject]@{ Attached = $script:AlreadyAttached; ParentPath = 'C:\fixture\parent.vhdx' }
    }
    function Mount-VHD {
        param($Path, [switch]$ReadOnly, [switch]$NoDriveLetter, [switch]$Passthru, $ErrorAction)
        Assert-True ($ReadOnly -and $NoDriveLetter -and $Passthru -and $script:VmState -eq 'Off') `
            'Collector mounted a writable disk, assigned a letter, or mounted a running guest.'
        $script:MountCalls++
        if ($script:MountFails) { throw 'Synthetic mount failure' }
        [pscustomobject]@{ DiskNumber = 42 }
    }
    function Get-Disk {
        param($Number, $ErrorAction)
        Assert-True ($Number -eq 42) 'The collector accessed a host disk other than its own mount.'
        if ($script:DiskReadFails) { throw 'Synthetic mounted disk lookup failure' }
        [pscustomobject]@{ Number = 42; IsReadOnly = $script:ReadOnly; IsOffline = $script:DiskOffline }
    }
    function Set-Disk {
        param($Number, $IsOffline, $ErrorAction)
        Assert-True ($Number -eq 42 -and $IsOffline -eq $false -and $script:ReadOnly) 'A host or writable disk was brought online.'
        $script:SetDiskCalls++
        if (-not $script:IgnoreOnlineWrite) { $script:DiskOffline = $false }
    }
    function Get-Partition {
        param($DiskNumber, $ErrorAction)
        $script:PartitionReads++
        [pscustomobject]@{ PartitionNumber = 1; GptType = 'basic' }
    }
    function Get-Volume {
        param($Partition, $ErrorAction)
        if ($script:VolumeReadFails) { throw 'Synthetic volume lookup failure' }
        [pscustomobject]@{ Path = $(if ($script:NoWindows) { $script:EmptyRoot } else { $script:GuestRoot }) }
    }
    function Dismount-VHD {
        param($Path, $ErrorAction)
        Assert-True ($Path -eq 'C:\fixture\active-leaf.avhdx') 'Collector tried to detach an unowned disk.'
        $script:DismountCalls++
        if ($script:DismountFailures -gt 0) { $script:DismountFailures--; throw 'Synthetic detach failure' }
        if ($script:StartAfterDismount) { $script:VmState = 'Running' }
    }
    function Read-MemLabsOfflineWindowsSetupHive {
        param($Path, $Kind)
        Assert-True ($Path -match '\\PrivateState\\(SYSTEM|SOFTWARE)$') 'Registry hives were loaded directly from the mounted guest.'
        if ($script:HiveFails) { throw 'Synthetic offline hive failure' }
        @{ Kind = $Kind; Setup = @{ OOBEInProgress = 1 }; ActiveName = 'DESKTOP-FIXTURE' }
    }
    function Get-WinEvent {
        param($Path, $MaxEvents, $ErrorAction)
        Assert-True ($MaxEvents -eq 1000) 'Offline event scanning lost its record bound.'
        if ($script:EventMode -eq 'NoMatching') { Write-Error -Message 'No events' -ErrorId NoMatchingEventsFound -ErrorAction Stop }
        if ($script:EventMode -eq 'SilentEmpty') { return }
        if ($script:EventMode -eq 'LiteralVolume') {
            Assert-True ($Path.StartsWith('\\`?\Volume{')) 'The literal volume-GUID question mark reached Get-WinEvent as a wildcard.'
        }
        $eventRecord = [pscustomobject]@{
            TimeCreated = [DateTime]::UtcNow; Id = 41
            ProviderName = 'Microsoft-Windows-Kernel-Power'; Level = 1; Message = 'fixture'
        }
        $eventRecord | Add-Member -MemberType ScriptMethod -Name ToXml -Value { '<Event><EventData>fixture</EventData></Event>' }
        $eventRecord | Add-Member -MemberType ScriptMethod -Name FormatDescription -Value {
            if ($script:EventMode -eq 'MessageFails') { throw 'Synthetic message resource failure' }
            return 'fixture'
        }
        if ($script:EventMode -eq 'FilteredEmpty' -and (Split-Path $Path -Leaf) -eq 'System.evtx') {
            $eventRecord.ProviderName = 'UnrelatedProvider'; $eventRecord.Id = 1234
        }
        $count = if ($script:EventMode -eq 'Many') { 101 } else { 1 }
        for ($i = 0; $i -lt $count; $i++) { $eventRecord }
    }
    function Remove-Item {
        param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
        if ($script:PrivateCleanupFails -and (Split-Path $LiteralPath -Leaf) -eq 'PrivateState') { throw 'Synthetic private cleanup failure' }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force -ErrorAction Stop
    }
    function Compress-Archive {
        param($Path, $DestinationPath, $ErrorAction)
        if ($script:ArchiveFails) { throw 'Synthetic archive failure' }
        Microsoft.PowerShell.Archive\Compress-Archive -Path $Path -DestinationPath $DestinationPath -ErrorAction Stop
    }
    function Reset-Fixture {
        $script:VmState = 'Running'; $script:GracefulWorks = $true; $script:ForceWorks = $true
        $script:AlreadyAttached = $false; $script:ReadOnly = $true; $script:NoWindows = $false; $script:HiveFails = $false
        $script:StopCalls = 0; $script:ForceCalls = 0; $script:MountCalls = 0; $script:DismountCalls = 0; $script:PartitionReads = 0
        $script:VmReads = 0; $script:VmCount = 1; $script:DiskOffline = $false; $script:SetDiskCalls = 0; $script:IgnoreOnlineWrite = $false
        $script:MountFails = $false; $script:DiskReadFails = $false; $script:VolumeReadFails = $false; $script:DismountFailures = 0
        $script:StartAfterDismount = $false; $script:StopJobFails = $false; $script:RemovedJobs = 0
        $script:EventMode = 'Normal'; $script:PrivateCleanupFails = $false; $script:ArchiveFails = $false
        $script:WaitBudgets = [Collections.Generic.List[int]]::new()
    }
    $parameters = @{ VmName = 'BROKEN-W11'; Destination = (Join-Path $testRoot 'output'); StopTimeoutSeconds = 5; Confirm = $false }
    Reset-Fixture
    $report = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($report.Status -eq 'Complete' -and $report.FinalState -eq 'Off' -and
        $script:StopCalls -eq 1 -and $script:ForceCalls -eq 0 -and $script:MountCalls -eq 1 -and
        $script:DismountCalls -eq 1 -and (Test-Path -LiteralPath $report.ArchivePath)) 'The normal offline collection did not finish safely.'
    $container = Split-Path $report.ArchivePath -Parent
    $manifestRecord = Get-Content -LiteralPath (Join-Path $container 'Bundle\Manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifestRecord.CollectorVersion -eq 2 -and $manifestRecord.RegistryReader -eq 'offreg.dll') `
        'The archive does not identify the corrected offline registry reader.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $container 'PrivateState'))) 'Private raw hives were retained after collection.'
    $zip = [IO.Compression.ZipFile]::OpenRead($report.ArchivePath)
    try {
        Assert-True (@($zip.Entries | Where-Object FullName -match 'PrivateState|unattend\.xml|(?:^|[/\\])(SYSTEM|SOFTWARE|SAM|SECURITY)$').Count -eq 0) `
            'The diagnostic archive includes an unattend file or raw registry hive.'
        foreach ($entry in $zip.Entries | Where-Object Length -gt 0) {
            $reader = New-Object IO.StreamReader($entry.Open())
            try { Assert-True (-not $reader.ReadToEnd().Contains('RAW-SECRET-MUST-NOT-BE-ARCHIVED')) 'A private hive/unattend payload leaked into the archive.' }
            finally { $reader.Dispose() }
        }
    }
    finally { $zip.Dispose() }

    Reset-Fixture
    $script:VmState = 'Off'
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($script:StopCalls -eq 0) 'An already-stopped VM received another power operation.'
    Reset-Fixture
    $script:GracefulWorks = $false
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'AllowTurnOff' -and $script:MountCalls -eq 0 -and $script:ForceCalls -eq 0) `
        'Graceful timeout forced power off or mounted an active VM without permission.'
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -AllowTurnOff
    Assert-True ($script:ForceCalls -eq 1 -and $script:VmState -eq 'Off' -and $script:DismountCalls -eq 1) `
        'Explicit force-off permission did not produce a verified offline collection.'
    foreach ($scenario in @('Attached', 'Writable', 'NoWindows')) {
        Reset-Fixture
        $script:VmState = 'Off'
        if ($scenario -eq 'Attached') { $script:AlreadyAttached = $true }
        if ($scenario -eq 'Writable') { $script:ReadOnly = $false }
        if ($scenario -eq 'NoWindows') { $script:NoWindows = $true }
        $failure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) "Unsafe $scenario state was treated as successful collection."
        if ($scenario -eq 'Attached') {
            Assert-True ($script:MountCalls -eq 0 -and $script:DismountCalls -eq 0) 'An existing host mount was borrowed or detached.'
        }
        else { Assert-True ($script:DismountCalls -eq 1) 'An owned failed mount was left attached.' }
        if ($scenario -eq 'Writable') { Assert-True ($script:PartitionReads -eq 0) 'A writable disk was examined before rejection.' }
    }
    Reset-Fixture
    $script:HiveFails = $true
    $partial = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($partial.Status -eq 'Partial' -and $script:DismountCalls -eq 1 -and
        -not (Test-Path -LiteralPath (Join-Path (Split-Path $partial.ArchivePath -Parent) 'PrivateState'))) `
        'Hive read failure hid partial status or leaked private staging state.'
    Reset-Fixture
    $count = $script:Protected.Count
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -WhatIf
    Assert-True ($script:StopCalls -eq 0 -and $script:MountCalls -eq 0 -and $script:Protected.Count -eq $count) `
        'WhatIf changed power, mounted a disk, or created output.'

    foreach ($matchingVmCount in @(0, 2)) {
        Reset-Fixture
        $script:VmCount = $matchingVmCount
        $failure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'Exactly one' -and $script:StopCalls -eq 0 -and $script:MountCalls -eq 0) `
            'Missing or ambiguous VM inventory caused a power/disk operation.'
    }
    Reset-Fixture
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics -VmName '*' -Destination $parameters.Destination }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'wildcard' -and $script:VmReads -eq 0) 'Wildcard targeting reached Hyper-V inventory.'

    foreach ($state in @('Saved', 'Paused')) {
        Reset-Fixture
        $script:VmState = $state
        $failure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'AllowTurnOff' -and $script:StopCalls -eq 0 -and $script:MountCalls -eq 0) `
            "$state state was discarded without permission."
        $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -AllowTurnOff
        Assert-True ($script:ForceCalls -eq 1 -and $script:VmState -eq 'Off') "$state power-off permission was not honored."
    }
    Reset-Fixture
    $script:GracefulWorks = $false; $script:ForceWorks = $false
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -AllowTurnOff }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match '30 seconds' -and $script:MountCalls -eq 0 -and $script:WaitBudgets -contains 30) `
        'Unsuccessful hard power-off was unbounded or allowed disk access.'
    Reset-Fixture
    $script:GracefulWorks = $false; $script:StopJobFails = $true
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -AllowTurnOff
    Assert-True ($script:RemovedJobs -eq 2 -and $script:ForceCalls -eq 1 -and $script:DismountCalls -eq 1) `
        'A graceful job cleanup error hid the permitted force fallback or prevented job removal.'

    foreach ($scenario in @('Mount', 'DiskRead', 'VolumeRead', 'OnlineWrite', 'FinalState')) {
        Reset-Fixture
        $script:VmState = 'Off'
        if ($scenario -eq 'Mount') { $script:MountFails = $true }
        if ($scenario -eq 'DiskRead') { $script:DiskReadFails = $true }
        if ($scenario -eq 'VolumeRead') { $script:VolumeReadFails = $true }
        if ($scenario -eq 'OnlineWrite') { $script:DiskOffline = $true; $script:IgnoreOnlineWrite = $true }
        if ($scenario -eq 'FinalState') { $script:StartAfterDismount = $true }
        $failure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure -and $script:StopCalls -eq 0) "The $scenario failure was hidden or triggered another power operation."
        if ($scenario -eq 'Mount') { Assert-True ($script:DismountCalls -eq 0) 'A failed, unowned mount was detached.' }
        else { Assert-True ($script:DismountCalls -eq 1) "The $scenario failure leaked an owned mount." }
    }
    Reset-Fixture
    $script:DiskOffline = $true
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($script:SetDiskCalls -eq 1 -and $script:DismountCalls -eq 1) 'An offline read-only mount was not safely brought online.'
    Reset-Fixture
    $script:DismountFailures = 1
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($script:DismountCalls -eq 2) 'A transient owned-mount cleanup failure was not retried exactly once.'
    Reset-Fixture
    $script:DismountFailures = 2
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
    catch { $failure = $_.Exception.Message }
    $lastRoot = $script:Protected[$script:Protected.Count - 1]
    $failedManifest = Get-Content -LiteralPath (Join-Path $lastRoot 'Bundle\Manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($failure -match 'mount' -and $script:DismountCalls -eq 2 -and
        $failedManifest.Status -eq 'Failed' -and ($failedManifest.Errors -join ' ') -match 'detach it manually') `
        'Permanent disk cleanup failure was hidden, unbounded, or omitted manual recovery context.'

    foreach ($desiredEventMode in @('NoMatching', 'FilteredEmpty', 'Many', 'MessageFails')) {
        Reset-Fixture
        $script:EventMode = $desiredEventMode
        $eventReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
        $eventBundle = Join-Path (Split-Path $eventReport.ArchivePath -Parent) 'Bundle'
        $json = Get-Content -LiteralPath (Join-Path $eventBundle 'System-events.json') -Raw
        $events = ConvertFrom-Json -InputObject $json
        Assert-True ($json.Trim().StartsWith('[')) 'Event output is not a JSON array.'
        if ($desiredEventMode -in @('NoMatching', 'FilteredEmpty')) {
            Assert-True ($json -match '^\s*\[\s*\]\s*$' -and $eventReport.Status -eq 'Complete') 'Empty events produced invalid JSON or a false failure.'
        }
        elseif ($desiredEventMode -eq 'Many') { Assert-True ($events.Count -eq 80) 'Offline event output exceeded its exact 80-record cap.' }
        else {
            Assert-True ($eventReport.Status -eq 'Partial' -and $events.Count -eq 1 -and $events[0].Xml -match 'EventData') `
                'Unavailable event message resources discarded the raw event evidence or hid the formatting error.'
        }
    }

    $largeLog = Join-Path $windows 'Panther\setupact.log'
    try {
        foreach ($encoding in @([Text.Encoding]::Unicode, [Text.UTF8Encoding]::new($false))) {
            $characterCount = if ($encoding.CodePage -eq 1200) { 10MB + 1 } else { 20MB + 1 }
            [IO.File]::WriteAllText($largeLog, ('A' * $characterCount), $encoding)
            Reset-Fixture
            $largeReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
            $zip = [IO.Compression.ZipFile]::OpenRead($largeReport.ArchivePath)
            try {
                $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'SetupLogs/Panther/setupact.log' })[0]
                Assert-True ($entry.Length -le 20MB -and $entry.Length -gt 0) 'A long single-line log exceeded its exact byte cap.'
                if ($encoding.CodePage -eq 1200) {
                    $stream = $entry.Open()
                    try { Assert-True ($stream.ReadByte() -eq 255 -and $stream.ReadByte() -eq 254) 'Truncated UTF-16 logs lost their encoding marker.' }
                    finally { $stream.Dispose() }
                }
            }
            finally { $zip.Dispose() }
            $largeManifest = Get-Content -LiteralPath (Join-Path (Split-Path $largeReport.ArchivePath -Parent) 'Bundle\Manifest.json') -Raw | ConvertFrom-Json
            $logRecord = @($largeManifest.Files | Where-Object Path -eq 'SetupLogs\Panther\setupact.log')[0]
            Assert-True ($logRecord.Truncated -eq $true -and $logRecord.SourceBytes -gt 20MB) 'Log truncation was not recorded accurately.'
        }
    }
    finally { [IO.File]::WriteAllText($largeLog, 'Synthetic setup failure in specialize') }

    $escapeRoot = Join-Path $testRoot 'outside-windows'
    $null = New-Item -Path $escapeRoot -ItemType Directory
    [IO.File]::WriteAllText((Join-Path $escapeRoot 'setupact.log'), 'REPARSE-TARGET-MUST-NOT-BE-COPIED')
    $junction = Join-Path $windows 'Panther\UnattendGC'
    $null = New-Item -Path $junction -ItemType Junction -Target $escapeRoot
    try {
        Reset-Fixture
        $reparseReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
        $reparseBundle = Join-Path (Split-Path $reparseReport.ArchivePath -Parent) 'Bundle'
        $reparseManifest = Get-Content -LiteralPath (Join-Path $reparseBundle 'Manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($reparseReport.Status -eq 'Partial' -and ($reparseManifest.Errors -join ' ') -match 'reparse point' -and
            -not (Test-Path -LiteralPath (Join-Path $reparseBundle 'SetupLogs\Panther\UnattendGC\setupact.log'))) `
            'Offline collection followed a junction outside its Windows evidence root.'
    }
    finally { [IO.Directory]::Delete($junction) }

    Reset-Fixture
    $script:PrivateCleanupFails = $true
    $privateReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($privateReport.Status -eq 'Partial') 'Private staging cleanup failure was not surfaced.'
    $zip = [IO.Compression.ZipFile]::OpenRead($privateReport.ArchivePath)
    try {
        Assert-True (@($zip.Entries | Where-Object FullName -match 'PrivateState|(?:^|[/\\])(SYSTEM|SOFTWARE|SAM|SECURITY)$').Count -eq 0) `
            'Retained private staging was included in the archive after cleanup failure.'
    }
    finally { $zip.Dispose() }
    Reset-Fixture
    $script:ArchiveFails = $true
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
    catch { $failure = $_.Exception.Message }
    $lastRoot = $script:Protected[$script:Protected.Count - 1]
    Assert-True ($failure -match 'Unarchived evidence is preserved' -and $script:DismountCalls -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $lastRoot 'Bundle\Manifest.json'))) 'Archive failure lost the evidence path or leaked its mount.'

    Reset-Fixture
    Push-Location -LiteralPath $testRoot
    try {
        $relativeReport = Invoke-MemLabsWindowsSetupDiagnostics -VmName BROKEN-W11 -Destination '.\relative-output' -StopTimeoutSeconds 5 -Confirm:$false
        Assert-True ($relativeReport.ArchivePath.StartsWith((Join-Path $testRoot 'relative-output\'))) 'Relative output ignored the PowerShell working directory.'
    }
    finally { Pop-Location }
    Reset-Fixture
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics -VmName BROKEN-W11 -Destination 'HKCU:\Software\MemLabsUnused' -Confirm:$false }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'filesystem' -and $script:StopCalls -eq 0) 'A non-filesystem output path reached VM shutdown.'

    # Execute the real entrypoint with only the default output and lease name isolated.
    $lastDefinition = $definitions | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1
    $entryText = ($ast.EndBlock.Statements |
        Where-Object { $_.Extent.StartOffset -gt $lastDefinition.Extent.EndOffset } |
        ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    $testMutexName = "Local\MemLabsSetupDiagnosticTest-$([guid]::NewGuid().ToString('N'))"
    $entryText = $entryText.Replace('Global\MemLabsTestMutationLock', $testMutexName)
    $defaultOutput = Join-Path $testRoot 'default-output'
    $parameterText = $ast.ParamBlock.Extent.Text.Replace(
        '(Join-Path $PSScriptRoot ''..\logs\setup-diagnostics'')', "'$($defaultOutput.Replace("'", "''"))'")
    if ($parameterText -notmatch 'CmdletBinding') { $parameterText = "[CmdletBinding(SupportsShouldProcess)]`n$parameterText" }
    $entrypoint = [scriptblock]::Create("$parameterText`n$entryText")
    $leaseKeepAlive = [Threading.Mutex]::new($false, $testMutexName)
    try {
        Reset-Fixture
        $defaultReport = & $entrypoint -VmName BROKEN-W11 -Confirm:$false
        Assert-True ($defaultReport.Status -eq 'Complete' -and $defaultReport.ArchivePath.StartsWith("$defaultOutput\") -and
            $script:WaitBudgets -contains 90) 'The real entrypoint did not forward omitted defaults.'
        $holder = [MemLabs.SetupDiagnosticTestSupport+LeaseHolder]::new($testMutexName)
        try {
            Assert-True $holder.Acquired 'The normal entrypoint did not release its mutation lease.'
            Reset-Fixture
            $protectedCount = $script:Protected.Count
            $failure = $null
            try { $null = & $entrypoint -VmName BROKEN-W11 -Confirm:$false }
            catch { $failure = $_.Exception.Message }
            Assert-True ($failure -match 'host mutation lease' -and $script:VmReads -eq 0 -and
                $script:StopCalls -eq 0 -and $script:Protected.Count -eq $protectedCount) 'A contended lease changed inventory, power, or evidence.'
            $null = & $entrypoint -VmName BROKEN-W11 -WhatIf
            Assert-True ($script:StopCalls -eq 0 -and $script:MountCalls -eq 0 -and
                $script:Protected.Count -eq $protectedCount) 'Entrypoint WhatIf mutated state while another owner held the lease.'
        }
        finally { $holder.Dispose() }
        Reset-Fixture
        $script:NoWindows = $true
        $failure = $null
        try { $null = & $entrypoint -VmName BROKEN-W11 -Confirm:$false }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) 'The entrypoint hid a fatal collection error.'
        $holder = [MemLabs.SetupDiagnosticTestSupport+LeaseHolder]::new($testMutexName)
        try {
            Assert-True $holder.Acquired 'The failed entrypoint did not release its mutation lease.'
            $holder.Abandon()
        }
        finally { $holder.Dispose() }
        Reset-Fixture
        $abandonedReport = & $entrypoint -VmName BROKEN-W11 -Confirm:$false
        Assert-True ($abandonedReport.Status -eq 'Complete') 'An abandoned mutation lease prevented safe collection.'
    }
    finally { $leaseKeepAlive.Dispose() }

    Reset-Fixture
    $script:EventMode = 'SilentEmpty'
    $emptyQueryReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    $emptyManifest = Get-Content -LiteralPath (Join-Path (Split-Path $emptyQueryReport.ArchivePath -Parent) 'Bundle\Manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($emptyQueryReport.Status -eq 'Partial' -and
        ($emptyManifest.Errors -join ' ') -match 'without an empty-log status') 'A silent zero-record event query became false clean evidence.'

    $savedSourceResolver = ${function:Get-MemLabsOfflineSetupSourcePath}
    try {
        function Get-MemLabsOfflineSetupSourcePath {
            param($WindowsRoot, $RelativePath)
            if ($RelativePath.EndsWith('.evtx')) { return "$WindowsRoot\$RelativePath" }
        }
        Reset-Fixture
        $script:EventMode = 'LiteralVolume'
        $volumeBundle = Join-Path $testRoot 'volume-events'
        $null = New-Item -Path $volumeBundle -ItemType Directory
        $volumeManifest = @{
            Files = [Collections.Generic.List[object]]::new()
            Missing = [Collections.Generic.List[string]]::new()
            Errors = [Collections.Generic.List[string]]::new()
        }
        Copy-MemLabsWindowsSetupEvidence -WindowsRoot '\\?\Volume{11111111-1111-1111-1111-111111111111}\Windows' `
            -Bundle $volumeBundle -PrivateRoot $aclPath -Manifest $volumeManifest
        Assert-True ($volumeManifest.Files.Count -eq 4 -and $volumeManifest.Errors.Count -eq 2 -and
            ($volumeManifest.Errors -join ' ') -notmatch 'wildcard') 'Literal volume-GUID event paths failed their production evidence pipeline.'
    }
    finally { Set-Item -Path Function:\Get-MemLabsOfflineSetupSourcePath -Value $savedSourceResolver }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- offline setup collection scopes power changes, enforces read-only mounts, cleans owned resources, and excludes raw hives and unattend files.'
