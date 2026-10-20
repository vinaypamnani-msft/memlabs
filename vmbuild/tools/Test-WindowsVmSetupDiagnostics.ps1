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
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace MemLabs {
    public static class SetupDiagnosticTestSupport {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetVolumeNameForVolumeMountPoint(string mountPoint, StringBuilder name, uint capacity);
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

        public static string GetVolumeGuidPath(string path) {
            string fullPath = Path.GetFullPath(path);
            string root = Path.GetPathRoot(fullPath);
            StringBuilder name = new StringBuilder(1024);
            if (!GetVolumeNameForVolumeMountPoint(root, name, (uint)name.Capacity)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return name.ToString() + fullPath.Substring(root.Length);
        }
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
                @{ Path = 'Microsoft\Windows NT\CurrentVersion'; Values = @{ CurrentBuild = '26300'; UBR = 9457 } },
                @{ Path = 'Microsoft\Windows\CurrentVersion\Policies\System'; Values = @{ EnableFirstLogonAnimation = 0 } },
                @{ Path = 'Microsoft\Windows NT\CurrentVersion\Winlogon'; Values = @{ AutoAdminLogon = '1'; DefaultUserName = 'fixtureadmin'; DefaultPassword = 'DO-NOT-EXPORT-THIS-SYNTHETIC-VALUE' } }
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
        $softwareState.WindowsVersion.Values.UBR -eq 9457 -and
        $softwareState.FirstLogonPolicy.Values.EnableFirstLogonAnimation -eq 0 -and
        $softwareState.WinlogonProgress.Values.AutoAdminLogon -eq '1') 'Native offline image/version/first-logon extraction is incorrect.'
    Assert-True (-not (($systemState | ConvertTo-Json -Depth 10).Contains('DO-NOT-EXPORT-THIS-SYNTHETIC-VALUE'))) `
        'Offline registry extraction escaped its value allowlist.'
    Assert-True (-not (($softwareState | ConvertTo-Json -Depth 10).Contains('DO-NOT-EXPORT-THIS-SYNTHETIC-VALUE'))) `
        'First-logon metadata exported the Winlogon password.'
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
    $runtimeId = 'Microsoft.WindowsAppRuntime.2_2.5.1.0_x64__8wekyb3d8bbwe'
    $oldRuntimeId = 'Microsoft.WindowsAppRuntime.2_2.2.0.0_x64__8wekyb3d8bbwe'
    $runtimeFolder = Join-Path $script:GuestRoot "Program Files\WindowsApps\$runtimeId"
    $oobeFolder = Join-Path $windows 'SystemApps\MicrosoftWindows.Client.OOBE_cw5n1h2txyewy'
    $privateAppFolder = Join-Path $script:GuestRoot 'Program Files\WindowsApps\Private.CompanyApp_1.0.0.0_x64__private'
    $appxBundle = Join-Path $testRoot 'appx-evidence'
    $null = New-Item -Path $runtimeFolder, $oobeFolder, $privateAppFolder, $appxBundle -ItemType Directory -Force
    $runtimeManifest = Join-Path $runtimeFolder 'AppxManifest.xml'
    $runtimeXml = '<Package xmlns="urn:test:appx"><Identity Name="Microsoft.WindowsAppRuntime.2" Version="2.5.1.0" ProcessorArchitecture="x64"/><Properties><Description>RAW-SECRET-MUST-NOT-BE-ARCHIVED</Description></Properties></Package>'
    [IO.File]::WriteAllText($runtimeManifest, $runtimeXml)
    [IO.File]::WriteAllText((Join-Path $privateAppFolder 'AppxManifest.xml'), 'RAW-SECRET-MUST-NOT-BE-ARCHIVED')
    $oobeManifest = Join-Path $oobeFolder 'AppxManifest.xml'
    $oobeXml = '<Package xmlns="urn:test:appx" xmlns:p="urn:test:dependencies"><Identity Name="MicrosoftWindows.Client.OOBE" Version="1.0.0.0" ProcessorArchitecture="x64"/><Dependencies><p:PackageDependency Name="Microsoft.WindowsAppRuntime.2" MinVersion="2.2.0.0" Publisher="CN=Microsoft"/><p:MainPackageDependency Name="Microsoft.Other" MinVersion="1.0.0.0"/></Dependencies></Package>'
    [IO.File]::WriteAllText($oobeManifest, $oobeXml)
    $eventXml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><EventData><Data Name='PackageId'>$oldRuntimeId</Data><Data Name='Result'>-2147024894</Data></EventData></Event>"
    $eventJson = ConvertTo-Json -InputObject @(
        [pscustomobject]@{ Id = 319; TimeCreated = '2026-10-20T16:53:16Z'; Xml = $eventXml },
        [pscustomobject]@{ Id = 319; TimeCreated = '2026-10-05T16:53:16Z'; Xml = $eventXml }
    )
    $appxEvents = Join-Path $appxBundle 'AppReadiness-events.json'
    [IO.File]::WriteAllText($appxEvents, $eventJson)
    $runtimeHash = (Get-FileHash -LiteralPath $runtimeManifest -Algorithm SHA256).Hash
    $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
    $runtimePackage = @($inventory.Packages | Where-Object Name -eq 'Microsoft.WindowsAppRuntime.2')[0]
    $oobePackage = @($inventory.Packages | Where-Object Name -eq 'MicrosoftWindows.Client.OOBE')[0]
    Assert-True ($inventory.Errors.Count -eq 0 -and $inventory.Packages.Count -eq 2 -and
        $runtimePackage.Version -eq '2.5.1.0' -and $runtimePackage.Architecture -eq 'x64' -and
        $runtimePackage.ManifestPresent -and $oobePackage.Dependencies.Count -eq 2 -and
        $oobePackage.Dependencies[0].Name -eq 'Microsoft.WindowsAppRuntime.2' -and
        $oobePackage.Dependencies[0].MinVersion -eq '2.2.0.0' -and
        $oobePackage.Dependencies[1].Type -eq 'MainPackageDependency' -and
        $inventory.FailedRuntimePreregistration.Count -eq 2 -and
        @($inventory.FailedRuntimePreregistration | Where-Object ManifestPresent).Count -eq 0 -and
        ([DateTimeOffset]$inventory.FailedRuntimePreregistration[0].EventTime).UtcDateTime -eq ([DateTimeOffset]'2026-10-20T16:53:16Z').UtcDateTime -and
        ([DateTimeOffset]$inventory.FailedRuntimePreregistration[1].EventTime).UtcDateTime -eq ([DateTimeOffset]'2026-10-05T16:53:16Z').UtcDateTime -and
        ($inventory | ConvertTo-Json -Depth 8) -notmatch 'RAW-SECRET|Private.CompanyApp' -and
        (Get-FileHash -LiteralPath $runtimeManifest -Algorithm SHA256).Hash -eq $runtimeHash) `
        'Read-only AppX evidence lost exact missing paths, manifest identities/dependencies, event dates, or privacy.'
    $guidWindows = [MemLabs.SetupDiagnosticTestSupport]::GetVolumeGuidPath($windows)
    Assert-True ($guidWindows.StartsWith('\\?\Volume{')) 'The native manifest fixture did not use a real volume-GUID path.'
    $guidInventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $guidWindows -Bundle $appxBundle
    Assert-True ($guidInventory.Errors.Count -eq 0 -and
        ($guidInventory | ConvertTo-Json -Depth 8 -Compress) -eq ($inventory | ConvertTo-Json -Depth 8 -Compress) -and
        (Get-FileHash -LiteralPath $runtimeManifest -Algorithm SHA256).Hash -eq $runtimeHash) `
        'Native volume-GUID manifest reads failed or differed from ordinary read-only file paths.'
    $oldRuntimeFolder = Join-Path $script:GuestRoot "Program Files\WindowsApps\$oldRuntimeId"
    $null = New-Item -Path $oldRuntimeFolder -ItemType Directory
    $oldRuntimeManifest = Join-Path $oldRuntimeFolder 'AppxManifest.xml'
    [IO.File]::WriteAllText($oldRuntimeManifest, $runtimeXml.Replace('2.5.1.0', '2.2.0.0'))
    $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
    Assert-True ($inventory.Errors.Count -eq 0 -and
        @($inventory.FailedRuntimePreregistration | Where-Object ManifestPresent).Count -eq 2) `
        'An existing exact preregistration manifest was incorrectly reported missing.'
    [IO.File]::Delete($oldRuntimeManifest)
    foreach ($invalidXml in @('<Package>', '<Package><Identity Name="NoVersion"/></Package>',
            '<!DOCTYPE Package [<!ENTITY hidden "RAW-SECRET-MUST-NOT-BE-ARCHIVED">]><Package>&hidden;</Package>',
            (' ' * (1MB + 1)),
            ('<Package><Identity Name="ManyDependencies" Version="1.0.0.0"/><Dependencies>' +
                ('<PackageDependency Name="Framework" MinVersion="1.0.0.0"/>' * 129) + '</Dependencies></Package>'))) {
        try {
            [IO.File]::WriteAllText($oobeManifest, $invalidXml)
            $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
            Assert-True ($inventory.Errors.Count -eq 1 -and
                @($inventory.Packages | Where-Object { $_.Name -eq 'Microsoft.WindowsAppRuntime.2' -and $_.Version -eq '2.5.1.0' }).Count -eq 1 -and
                @($inventory.Packages | Where-Object Error).Count -eq 1) `
                'An invalid, oversized, or DTD-bearing manifest hid its error or discarded another package.'
        }
        finally { [IO.File]::WriteAllText($oobeManifest, $oobeXml) }
    }
    foreach ($boundaryXml in @(
            ($oobeXml + (' ' * (1MB - [Text.Encoding]::UTF8.GetByteCount($oobeXml)))),
            ('<Package><Identity Name="DependencyBoundary" Version="1.0.0.0"/><Dependencies>' +
                ('<PackageDependency Name="Framework" MinVersion="1.0.0.0"/>' * 128) + '</Dependencies></Package>'))) {
        try {
            [IO.File]::WriteAllText($oobeManifest, $boundaryXml)
            $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
            Assert-True ($inventory.Errors.Count -eq 0 -and $inventory.Packages.Count -eq 3) `
                'A manifest exactly at its byte or dependency limit was incorrectly rejected.'
        }
        finally { [IO.File]::WriteAllText($oobeManifest, $oobeXml) }
    }
    foreach ($badEvents in @('{broken', '[{"Id":319,"Xml":"<Event>"}]',
            '[{"Id":319,"Xml":"<!DOCTYPE Event><Event/>"}]',
            ('[{"Id":319,"Xml":"<Event><Data Name=\"PackageId\">Microsoft.WindowsAppRuntime.2_..\\escape</Data></Event>"}]'))) {
        try {
            [IO.File]::WriteAllText($appxEvents, $badEvents)
            $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
            Assert-True ($inventory.Errors.Count -eq 1 -and $inventory.Packages.Count -eq 3) `
                'Malformed package-event data became clean evidence or prevented independent folder checks.'
        }
        finally { [IO.File]::WriteAllText($appxEvents, $eventJson) }
    }
    foreach ($eventCount in @(80, 81)) {
        try {
            $eventRecords = @(foreach ($number in 1..$eventCount) {
                    [pscustomobject]@{ Id = 319; TimeCreated = '2026-10-20T16:53:16Z'; Xml = $eventXml }
                })
            [IO.File]::WriteAllText($appxEvents, (ConvertTo-Json -InputObject $eventRecords))
            $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
            if ($eventCount -eq 80) {
                Assert-True ($inventory.Errors.Count -eq 0 -and $inventory.FailedRuntimePreregistration.Count -eq 80) `
                    'An 80-record package summary was rejected or treated as a nested array.'
            }
            else {
                Assert-True ($inventory.Errors.Count -eq 1 -and ($inventory.Errors -join ' ') -match '80-record' -and
                    $inventory.FailedRuntimePreregistration.Count -eq 0) 'The package-event summary exceeded its exact record bound.'
            }
        }
        finally { [IO.File]::WriteAllText($appxEvents, $eventJson) }
    }
    foreach ($badRelativePath in @('..\outside', '.\Windows', 'C:\Windows')) {
        $failure = $null
        try { $null = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $windows -RelativePath $badRelativePath }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'relative.*traversal') 'Offline package metadata can escape its mounted-volume root.'
    }
    $packageJunction = Join-Path $script:GuestRoot 'Program Files\WindowsApps\Microsoft.WindowsAppRuntime.2_9.0.0.0_x64__8wekyb3d8bbwe'
    $null = New-Item -Path $packageJunction -ItemType Junction -Target $privateAppFolder
    try {
        $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $windows -Bundle $appxBundle
        Assert-True ($inventory.Errors.Count -eq 1 -and ($inventory.Errors -join ' ') -match 'reparse' -and
            ($inventory | ConvertTo-Json -Depth 8) -notmatch 'RAW-SECRET') 'Package inventory followed a reparse point.'
    }
    finally { [IO.Directory]::Delete($packageJunction) }
    $limitRoot = Join-Path $testRoot 'package-limit'
    $limitWindows = Join-Path $limitRoot 'Windows'
    $null = New-Item -Path $limitWindows -ItemType Directory
    foreach ($number in 1..64) {
        $null = New-Item -Path (Join-Path $limitRoot "Program Files\WindowsApps\Microsoft.WindowsAppRuntime.2_2.5.1.$number`_x64__8wekyb3d8bbwe") -ItemType Directory -Force
    }
    $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $limitWindows -Bundle $appxBundle
    Assert-True ($inventory.Errors.Count -eq 0 -and $inventory.Packages.Count -eq 64) `
        'The exact 64-folder inventory limit was incorrectly rejected.'
    $null = New-Item -Path (Join-Path $limitRoot 'Program Files\WindowsApps\Microsoft.WindowsAppRuntime.2_2.5.1.65_x64__8wekyb3d8bbwe') -ItemType Directory
    $inventory = Get-MemLabsOfflineAppxInventory -WindowsRoot $limitWindows -Bundle $appxBundle
    Assert-True ($inventory.Errors.Count -eq 1 -and ($inventory.Errors -join ' ') -match 'Too many matching' -and
        $inventory.Packages.Count -eq 0) 'Offline package enumeration exceeded its fixed folder bound.'
    $script:Protected = [Collections.Generic.List[string]]::new()
    function New-MemLabsPrivateDiagnosticDirectory {
        param($Path)
        $script:Protected.Add($Path)
        $null = New-Item -Path $Path -ItemType Directory -Force
    }
    function Import-Module {
        param($Name, [switch]$Global, $ErrorAction)
        Assert-True ($Global -and $ErrorAction -eq 'Stop') 'Dependency imports were not explicit or visible to the collector.'
        $script:ModuleImports.Add($Name)
        if ($Name -eq $script:FailedModule) {
            throw 'Synthetic module load failure: remoteIpMoProxy_DhcpServer_stale.format.ps1xml could not be found.'
        }
        [pscustomobject]@{ ImportedModule = $Name }
    }
    function Get-Command {
        param($Name, $ErrorAction)
        Assert-True ($Name -match '^(Hyper-V|Storage|CimCmdlets|Microsoft\.PowerShell\.(Diagnostics|Archive))\\' -and
            $ErrorAction -eq 'Stop') 'Dependency command lookup was not module-qualified or fail-closed.'
        $script:CommandChecks.Add($Name)
        if ($Name -eq $script:MissingCommand) { throw "Synthetic missing dependency command: $Name" }
        if ($Name -eq 'CimCmdlets\Invoke-CimMethod') {
            $script:DependenciesReady = ($script:ModuleImports.Count - $script:ModuleCycleStart) -eq 5 -and
                ($script:CommandChecks.Count - $script:CommandCycleStart) -eq (15 + [int]$script:LiveRequested)
        }
        [pscustomobject]@{ Name = $Name }
    }
    $script:VmId = [guid]::NewGuid()
    function Get-VM {
        param($Name, $Id, $ErrorAction)
        $script:VmReads++
        if ($Name -and $Name -ne 'BROKEN-W11') { throw "Unexpected VM name $Name" }
        if ($Id -and $Id -ne $script:VmId) { throw "Unexpected VM ID $Id" }
        if ($Name) {
            $script:CapturedForCurrentOperation = $false
            $script:DependenciesReady = $false
            $script:ModuleCycleStart = $script:ModuleImports.Count
            $script:CommandCycleStart = $script:CommandChecks.Count
            for ($i = 0; $i -lt $script:VmCount; $i++) {
                [pscustomobject]@{ Name = 'BROKEN-W11'; Id = $script:VmId; State = $script:VmState }
            }
        }
        else { [pscustomobject]@{ Name = 'BROKEN-W11'; Id = $script:VmId; State = $script:VmState } }
    }
    function Stop-VM {
        param($VM, [switch]$AsJob, [switch]$TurnOff, $Confirm, $ErrorAction)
        Assert-True ($VM.Id -eq $script:VmId -and $AsJob) 'Shutdown was not scoped to the selected VM or was unbounded.'
        Assert-True $script:CapturedForCurrentOperation 'Shutdown ran before console evidence capture.'
        Assert-True $script:DependenciesReady `
            'Shutdown ran before all required modules and commands were checked.'
        $script:StopCalls++
        if ($TurnOff) {
            $script:ForceCalls++
            if ($script:ForceWorks) { $script:VmState = 'Off' }
        }
        elseif ($script:GracefulWorks) { $script:VmState = 'Off' }
        [pscustomobject]@{ State = $(if ($script:VmState -eq 'Off') { 'Completed' } else { 'Running' }) }
    }
    function Add-MemLabsSetupConsoleScreenshot {
        param($VM, $Bundle, $Stage, $Records, $Errors)
        $script:CapturedForCurrentOperation = $true
        $script:ConsoleStates.Add($script:VmState)
        $record = [pscustomobject]@{ Status = 'UnavailableNotRunning'; Path = "Console-$Stage.png" }
        if ($script:VmState -eq 'Running') {
            if ($script:ConsoleBadFrame) {
                $record.Status = 'Error'
                $record | Add-Member -NotePropertyName RawPath -NotePropertyValue "Console-$Stage.rgb565.bin"
                $record | Add-Member -NotePropertyName RawMetadataPath -NotePropertyValue "Console-$Stage.rgb565.json"
                [IO.File]::WriteAllBytes((Join-Path $Bundle $record.RawPath), [byte[]]@(1, 2, 3))
                [IO.File]::WriteAllText((Join-Path $Bundle $record.RawMetadataPath), '{"BytesDiscarded":0}')
                $Errors.Add('Synthetic malformed console frame; raw bytes preserved.')
            }
            else {
                $record.Status = 'Captured'
                [IO.File]::WriteAllBytes((Join-Path $Bundle $record.Path), [byte[]]@(137, 80, 78, 71))
            }
        }
        $Records.Add($record)
        return $record
    }
    $probePassword = [Security.SecureString]::new()
    foreach ($character in 'SYNTHETIC-PROBE-SECRET'.ToCharArray()) { $probePassword.AppendChar($character) }
    $script:ProbeCredential = [pscredential]::new('fixture-admin', $probePassword)
    function Resolve-MemLabsOobeRepairCredential {
        param([pscredential]$GuestCredential)
        $script:CredentialResolves++
        if ($script:CredentialFails) { throw 'Synthetic saved credential is unavailable.' }
        if ($GuestCredential) { return $GuestCredential }
        return $script:ProbeCredential
    }
    function Get-MemLabsFirstLogonGuestBlock {
        $script:GuestBlockBuilds++
        return { param($Action) }
    }
    function Invoke-MemLabsWindowsFirstLogonProbe {
        param($VM, [pscredential]$GuestCredential, $GuestBlock, $Bundle, $Manifest)
        Assert-True ($VM.Id -eq $script:VmId -and
            [object]::ReferenceEquals($GuestCredential, $script:ProbeCredential) -and $script:DependenciesReady) `
            'Live inspection lost the exact VM, saved credential, or dependency preflight.'
        $script:LiveProbeCalls++
        if ($script:VmState -eq 'Off') {
            $Manifest.LiveProbe.StartAttempted = $true
            $Manifest.LiveProbe.StartedVm = $true
            $script:ProbeStarts++; $script:VmState = 'Running'
        }
        if ($script:LiveFailure -eq 'PowerUnknown') {
            $failure = [TimeoutException]::new('Synthetic startup outcome is unknown.')
            $failure.Data['FirstLogonProbePowerIndeterminate'] = $true
            throw $failure
        }
        if ($script:LiveFailure -eq 'Auth') { throw [UnauthorizedAccessException]::new('Synthetic PowerShell Direct authentication failure.') }
        foreach ($stage in @('StateBefore', 'Appx', 'StateAfter')) {
            $relative = "Live-$stage.json"
            [IO.File]::WriteAllText((Join-Path $Bundle $relative), '{"ReadOnly":true,"RepairPerformed":false}')
            $Manifest.Files.Add([ordered]@{ Path = $relative; Kind = 'LiveFirstLogonProbe'; Truncated = $false })
            $Manifest.LiveProbe.Stages.Add([pscustomobject]@{ Name = $stage; Status = 'Complete'; Path = $relative })
        }
        $Manifest.LiveProbe.Status = 'Complete'
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
        $path = if ($script:NoWindows) { $script:EmptyRoot } else { $script:GuestRoot }
        if ($script:NativeVolumePaths) { $path = [MemLabs.SetupDiagnosticTestSupport]::GetVolumeGuidPath($path) }
        [pscustomobject]@{ Path = $path }
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
        $script:ModuleImports = [Collections.Generic.List[string]]::new()
        $script:CommandChecks = [Collections.Generic.List[string]]::new()
        $script:FailedModule = ''; $script:MissingCommand = ''
        $script:DependenciesReady = $false; $script:ModuleCycleStart = 0; $script:CommandCycleStart = 0
        $script:ConsoleStates = [Collections.Generic.List[string]]::new()
        $script:ConsoleBadFrame = $false
        $script:NativeVolumePaths = $false
        $script:LiveRequested = $false; $script:CredentialResolves = 0; $script:CredentialFails = $false
        $script:GuestBlockBuilds = 0; $script:LiveProbeCalls = 0; $script:ProbeStarts = 0; $script:LiveFailure = ''
    }
    $parameters = @{ VmName = 'BROKEN-W11'; Destination = (Join-Path $testRoot 'output'); StopTimeoutSeconds = 5; Confirm = $false }
    Reset-Fixture
    $report = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    Assert-True ($report -is [pscustomobject] -and $report.Status -eq 'Complete' -and $report.FinalState -eq 'Off' -and
        $script:StopCalls -eq 1 -and $script:ForceCalls -eq 0 -and $script:MountCalls -eq 1 -and
        $script:DismountCalls -eq 1 -and (Test-Path -LiteralPath $report.ArchivePath) -and
        ($script:ModuleImports -join ',') -eq 'Hyper-V,Storage,Microsoft.PowerShell.Diagnostics,Microsoft.PowerShell.Archive,CimCmdlets' -and
        $script:ConsoleStates[0] -eq 'Running') `
        'The normal offline collection did not preflight dependencies, return one report, or finish safely.'
    $container = Split-Path $report.ArchivePath -Parent
    $manifestRecord = Get-Content -LiteralPath (Join-Path $container 'Bundle\Manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifestRecord.CollectorVersion -eq 7 -and $manifestRecord.RegistryReader -eq 'offreg.dll' -and
        @($manifestRecord.Files | Where-Object Path -eq 'AppxPrerequisiteInventory.json').Count -eq 1) `
        'The archive does not identify the corrected registry reader and package-inventory collector.'
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

    Assert-True ($script:CredentialResolves -eq 0 -and $script:GuestBlockBuilds -eq 0 -and
        -not $manifestRecord.LiveProbe.Requested) 'Offline collection unexpectedly read credentials or prepared a live probe.'
    foreach ($initialState in @('Off', 'Running')) {
        Reset-Fixture
        $script:VmState = $initialState; $script:LiveRequested = $true
        $liveReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe
        $liveBundle = Join-Path (Split-Path $liveReport.ArchivePath -Parent) 'Bundle'
        $liveManifest = Get-Content -LiteralPath (Join-Path $liveBundle 'Manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($liveReport.Status -eq 'Complete' -and $liveReport.FinalState -eq 'Off' -and
            $liveManifest.OriginalState -eq $initialState -and $liveManifest.LiveProbe.Requested -and
            $liveManifest.LiveProbe.Status -eq 'Complete' -and -not $liveManifest.LiveProbe.RepairPerformed -and
            $script:CredentialResolves -eq 1 -and $script:LiveProbeCalls -eq 1 -and
            $script:ProbeStarts -eq [int]($initialState -eq 'Off') -and $script:StopCalls -eq 1 -and $script:MountCalls -eq 1 -and
            @($liveManifest.Files | Where-Object Kind -eq 'LiveFirstLogonProbe').Count -eq 3 -and
            (Test-Path -LiteralPath (Join-Path $liveBundle 'Live-Appx.json'))) `
            "$initialState live inspection lost protected artifacts, saved-credential preflight, or stop-before-mount behavior."
        Assert-True ((Get-Content -LiteralPath (Join-Path $liveBundle 'Manifest.json') -Raw) -notmatch 'SYNTHETIC-PROBE-SECRET') `
            'Live credentials leaked into the collection report.'
    }
    Reset-Fixture
    $script:VmState = 'Off'; $script:LiveRequested = $true; $script:LiveFailure = 'Auth'
    $authReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe
    $authBundle = Join-Path (Split-Path $authReport.ArchivePath -Parent) 'Bundle'
    $authManifest = Get-Content -LiteralPath (Join-Path $authBundle 'Manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($authReport.Status -eq 'Partial' -and $authReport.FinalState -eq 'Off' -and
        $authManifest.LiveProbe.Status -eq 'Failed' -and $script:LiveProbeCalls -eq 1 -and
        -not $authManifest.LiveProbe.AuthenticationRetried -and $script:StopCalls -eq 1 -and
        (Test-Path -LiteralPath (Join-Path $authBundle 'WindowsSetupState.json'))) `
        'Authentication failure retried, became clean live evidence, or prevented safe offline evidence.'
    Reset-Fixture
    $script:VmState = 'Off'; $script:LiveRequested = $true; $script:CredentialFails = $true
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'credential' -and $script:VmState -eq 'Off' -and
        $script:LiveProbeCalls -eq 0 -and $script:StopCalls -eq 0 -and $script:MountCalls -eq 0) `
        'Credential preflight failure reached VM power operations.'
    Reset-Fixture
    $script:VmState = 'Off'; $script:LiveRequested = $true
    $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe -WhatIf
    Assert-True ($script:CredentialResolves -eq 0 -and $script:GuestBlockBuilds -eq 0 -and
        $script:LiveProbeCalls -eq 0 -and $script:VmState -eq 'Off') 'Live WhatIf read credentials or changed power.'
    foreach ($unsupported in @('Saved', 'Paused')) {
        Reset-Fixture
        $script:VmState = $unsupported; $script:LiveRequested = $true
        $failure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe -AllowTurnOff }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'Off or Running' -and $script:CredentialResolves -eq 0 -and
            $script:StopCalls -eq 0 -and $script:LiveProbeCalls -eq 0) 'Live inspection discarded saved/paused state.'
    }
    Reset-Fixture
    $script:VmState = 'Off'; $script:LiveRequested = $true; $script:LiveFailure = 'PowerUnknown'
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters -IncludeLiveProbe -AllowTurnOff }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'startup outcome is unknown' -and $script:LiveProbeCalls -eq 1 -and
        $script:StopCalls -eq 0 -and $script:MountCalls -eq 0) 'Unknown live startup triggered another power operation or disk mount.'

    Reset-Fixture
    $script:NativeVolumePaths = $true
    $guidReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    $guidBundle = Join-Path (Split-Path $guidReport.ArchivePath -Parent) 'Bundle'
    $guidManifest = Get-Content -LiteralPath (Join-Path $guidBundle 'Manifest.json') -Raw | ConvertFrom-Json
    $guidInventory = Get-Content -LiteralPath (Join-Path $guidBundle 'AppxPrerequisiteInventory.json') -Raw | ConvertFrom-Json
    Assert-True ($guidReport.Status -eq 'Complete' -and $guidManifest.Errors.Count -eq 0 -and
        $guidInventory.Errors.Count -eq 0 -and
        @($guidInventory.Packages | Where-Object { $_.Name -eq 'Microsoft.WindowsAppRuntime.2' -and $_.Version -eq '2.5.1.0' }).Count -eq 1 -and
        @($guidInventory.Packages | Where-Object { $_.Name -eq 'MicrosoftWindows.Client.OOBE' -and $_.Dependencies.Count -eq 2 }).Count -eq 1 -and
        $script:DismountCalls -eq 1) 'The production collector lost native volume-GUID manifest evidence or mount cleanup.'

    Reset-Fixture
    $script:ConsoleBadFrame = $true
    $rawReport = Invoke-MemLabsWindowsSetupDiagnostics @parameters
    $rawBundle = Join-Path (Split-Path $rawReport.ArchivePath -Parent) 'Bundle'
    $rawManifest = Get-Content -LiteralPath (Join-Path $rawBundle 'Manifest.json') -Raw | ConvertFrom-Json
    $rawZip = [IO.Compression.ZipFile]::OpenRead($rawReport.ArchivePath)
    try {
        Assert-True ($rawReport.Status -eq 'Partial' -and
            @($rawManifest.Files | Where-Object Kind -eq 'RawConsoleFramebuffer').Count -eq 1 -and
            @($rawManifest.Files | Where-Object Kind -eq 'RawConsoleMetadata').Count -eq 1 -and
            @($rawZip.Entries | Where-Object FullName -eq 'Console-BeforeStop.rgb565.bin').Count -eq 1 -and
            @($rawZip.Entries | Where-Object FullName -eq 'Console-BeforeStop.rgb565.json').Count -eq 1 -and
            -not (Test-Path -LiteralPath (Join-Path $rawBundle 'Console-BeforeStop.png')) -and
            (Test-Path -LiteralPath (Join-Path $rawBundle 'WindowsSetupState.json'))) `
            'A malformed console frame lost raw archive evidence, claimed a PNG, or prevented offline setup collection.'
    }
    finally { $rawZip.Dispose() }

    foreach ($moduleName in @('Hyper-V', 'Storage', 'Microsoft.PowerShell.Diagnostics', 'Microsoft.PowerShell.Archive', 'CimCmdlets')) {
        Reset-Fixture
        $script:FailedModule = $moduleName
        $protectedCount = $script:Protected.Count
        $failure = $null
        $preflightFailure = $null
        try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
        catch { $failure = $_.Exception.Message; $preflightFailure = $_.Exception }
        Assert-True ($failure -like "*'$moduleName'*" -and $failure -match 'before VM shutdown' -and
            $failure -match 'fresh elevated Windows PowerShell 5.1' -and $failure -match 'remoteIpMoProxy_DhcpServer_stale' -and
            $preflightFailure.Data['DiagnosticModule'] -eq $moduleName -and
            -not [string]::IsNullOrWhiteSpace($preflightFailure.Data['OriginalErrorId']) -and
            $preflightFailure.InnerException.Message -match 'Synthetic module load failure' -and
            $script:VmState -eq 'Running' -and $script:StopCalls -eq 0 -and $script:MountCalls -eq 0 -and
            $script:SetDiskCalls -eq 0 -and $script:Protected.Count -eq $protectedCount) `
            "$moduleName dependency failure changed VM/disk/output state or lost the original error and retry guidance."
    }
    Reset-Fixture
    $script:MissingCommand = 'Storage\Get-Disk'
    $protectedCount = $script:Protected.Count
    $failure = $null
    try { $null = Invoke-MemLabsWindowsSetupDiagnostics @parameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'Synthetic missing dependency command: Storage\\Get-Disk' -and
        $script:StopCalls -eq 0 -and $script:MountCalls -eq 0 -and $script:Protected.Count -eq $protectedCount) `
        'A missing Storage command was deferred until after VM or output changes.'

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
    Assert-True ($script:StopCalls -eq 0 -and $script:MountCalls -eq 0 -and $script:Protected.Count -eq $count -and
        $script:ModuleImports.Count -eq 0 -and $script:CommandChecks.Count -eq 0) `
        'WhatIf initialized modules, changed power, mounted a disk, or created output.'

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
    $entryText = $entryText.Replace(
        '(Join-Path $PSScriptRoot ''..\logs\setup-diagnostics'')', "'$($defaultOutput.Replace("'", "''"))'")
    $parameterText = $ast.ParamBlock.Extent.Text
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
            param($WindowsRoot, $RelativePath, [switch]$AllowDirectory)
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
        Assert-True ($volumeManifest.Files.Count -eq 9 -and $volumeManifest.Errors.Count -eq 2 -and
            ($volumeManifest.Errors -join ' ') -notmatch 'wildcard') 'Literal volume-GUID event paths failed their production evidence pipeline.'
    }
    finally { Set-Item -Path Function:\Get-MemLabsOfflineSetupSourcePath -Value $savedSourceResolver }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- offline setup collection preflights dependencies, scopes power changes/read-only mounts, preserves malformed frames, inventories bounded package evidence through native volume-GUID paths, cleans owned resources, and excludes raw hives/unattend/manifests.'
