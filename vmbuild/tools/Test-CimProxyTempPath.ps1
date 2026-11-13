#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path $PSScriptRoot -Parent) 'Common.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Repair-CimProxyTempPath'
    }, $true)
if (-not $definition) { throw 'Repair-CimProxyTempPath was not found.' }
. ([scriptblock]::Create($definition.Extent.Text))
$cleanupAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Clear-CimProxyTempFolders.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
foreach ($definition in $cleanupAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-Path {
    param($LiteralPath, $PathType)
    if ($script:CleanupMode) { return $true }
    if ($script:Scenario -eq 'ProbeFailure') { throw 'Synthetic temp-path access failure' }
    return $script:Scenario -ne 'MissingPaths'
}
function New-Item {
    param($ItemType, $Path, [switch]$Force, $ErrorAction)
    Assert-True ($ItemType -eq 'Directory' -and $Force -and $ErrorAction -eq 'Stop') 'Temp recreation lost its explicit directory/error contract.'
    $script:Created.Add($Path)
    [pscustomobject]@{ FullName = $Path }
}
function Get-ChildItem {
    param($LiteralPath, [switch]$Directory, $Filter, [switch]$Force, $ErrorAction)
    $script:Enumerations++
    if ($script:CleanupMode -and $script:Directories.ContainsKey($LiteralPath)) {
        $unsafe = $LiteralPath.EndsWith('_1')
        [pscustomobject]@{
            PSIsContainer = $unsafe -and $script:CleanupScenario -eq 'NestedDirectory'
            Attributes = $(if ($unsafe -and $script:CleanupScenario -eq 'NestedReparse') { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Normal })
        }
        return
    }
    $root = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    if ($script:CleanupMode -and $root -ine $script:CleanupRoot) { return }
    $count = if ($script:CleanupScenario -eq 'BelowThreshold') { 200 } else { 201 }
    foreach ($index in 1..$count) {
        $name = "remoteIpMoProxy_DhcpServer_fixture_$index"
        $proxy = [pscustomobject]@{
            Name = $name; FullName = "$root\$name"; Parent = [pscustomobject]@{ FullName = $root }
            CreationTime = $script:Now.AddHours(-2); LastWriteTime = $script:Now.AddHours(-2)
            Attributes = [IO.FileAttributes]::Directory; PSIsContainer = $true
        }
        if ($index -eq 1 -and $script:CleanupScenario -eq 'RecentCreation') { $proxy.CreationTime = $script:Now.AddHours(-1) }
        if ($index -eq 1 -and $script:CleanupScenario -eq 'RecentWrite') { $proxy.LastWriteTime = $script:Now.AddHours(-1) }
        if ($index -eq 1 -and $script:CleanupScenario -eq 'Reparse') { $proxy.Attributes = [IO.FileAttributes]::ReparsePoint }
        $script:Directories[$proxy.FullName] = $proxy
        $proxy
    }
}
function Get-Item {
    param($LiteralPath, [switch]$Force, $ErrorAction)
    Assert-True ($Force -and $ErrorAction -eq 'Stop' -and $script:Directories.ContainsKey($LiteralPath)) 'Cleanup queried an unverified directory.'
    $directory = $script:Directories[$LiteralPath]
    if ($script:CleanupScenario -eq 'ChangedDirectory' -and $directory.Name.EndsWith('_1')) { $directory.PSIsContainer = $false }
    return $directory
}
function Remove-Item {
    param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction)
    if ($script:CleanupMode) {
        Assert-True ($Recurse -and $Force -and $ErrorAction -eq 'Stop' -and $script:Directories.ContainsKey($LiteralPath)) `
            'Cleanup did not target one exact validated proxy directory.'
        if ($script:CleanupScenario -eq 'DeleteFailure' -and $LiteralPath.EndsWith('_1')) { throw 'Synthetic proxy deletion failure' }
    }
    $script:Deleted.Add($LiteralPath)
}
function Get-Date { return $script:Now }
function Get-Process {
    param($ErrorAction)
    $script:ProcessChecks++
    [pscustomobject]@{ Id = $PID; ProcessName = 'powershell' }
    if ($script:CleanupScenario -in @('ActiveProcess', 'WhatIf') -or
        ($script:CleanupScenario -eq 'NewProcess' -and $script:ProcessChecks -ge 2)) {
        [pscustomobject]@{ Id = ($PID + 1); ProcessName = 'pwsh' }
    }
}
function Get-Module {
    param([switch]$All)
    if ($script:CleanupScenario -eq 'LoadedProxy') {
        [pscustomobject]@{ Name = 'remoteIpMoProxy_fixture'; Path = 'C:\fixture\remoteIpMoProxy_fixture\proxy.psm1' }
    }
    if ($script:CleanupScenario -eq 'LoadedCimModule') {
        [pscustomobject]@{ Name = 'DhcpServer'; Path = 'C:\fixture\DhcpServer\DhcpServer.psd1' }
    }
}
function Get-PSSession {
    param($ErrorAction)
    if ($script:CleanupScenario -eq 'RemotingSession') { [pscustomobject]@{ State = 'Opened' } }
}
function Write-Log {
    param($Message, [switch]$Warning, [switch]$LogOnly)
    $script:Messages.Add($Message)
}

$script:CleanupMode = $false
$script:CleanupScenario = ''
$script:Now = [datetime]'2026-10-20T06:00:00'
foreach ($scenario in @('HealthyPaths', 'MissingPaths', 'ProbeFailure')) {
    $script:Scenario = $scenario
    $script:Created = [Collections.Generic.List[string]]::new()
    $script:Deleted = [Collections.Generic.List[string]]::new()
    $script:Messages = [Collections.Generic.List[string]]::new()
    $script:Directories = @{}
    $script:Enumerations = 0
    $result = @(Repair-CimProxyTempPath)
    Assert-True ($result.Count -eq 1 -and $result[0] -is [bool] -and
        $result[0] -eq ($scenario -eq 'MissingPaths')) "$scenario changed the temp repair result contract."
    Assert-True ($script:Deleted.Count -eq 0) "$scenario automatically deleted shared proxy directories."
    if ($scenario -eq 'HealthyPaths') {
        Assert-True ($script:Enumerations -gt 0 -and ($script:Messages -join ' ') -match 'Clear-CimProxyTempFolders.ps1') `
            'The existing cleanup threshold stopped reporting the explicit maintenance requirement.'
    }
    if ($scenario -eq 'MissingPaths') {
        Assert-True ($script:Created.Count -gt 0 -and ($script:Messages -join ' ') -match 'Recreated missing temp') `
            'Missing temp paths were not recreated or reported.'
    }
    else { Assert-True ($script:Created.Count -eq 0) "$scenario recreated an existing or unverified temp path." }
    if ($scenario -eq 'ProbeFailure') {
        Assert-True (($script:Messages -join ' ') -match 'Synthetic temp-path access failure') 'Temp-path access failures were hidden.'
    }
}
$script:CleanupMode = $true
$script:CleanupRoot = [IO.Path]::GetTempPath().TrimEnd('\')
foreach ($scenario in @('Maintenance', 'BelowThreshold', 'RecentCreation', 'RecentWrite', 'Reparse',
        'ActiveProcess', 'LoadedProxy', 'LoadedCimModule', 'RemotingSession', 'NewProcess', 'ChangedDirectory',
        'NestedDirectory', 'NestedReparse', 'DeleteFailure', 'WhatIf')) {
    $script:CleanupScenario = $scenario
    $script:Directories = @{}
    $script:Deleted = [Collections.Generic.List[string]]::new()
    $script:ProcessChecks = 0
    $failure = $null
    $reports = @()
    try {
        $reports = @(Clear-MemLabsCimProxyTempFolders -Confirm:$false -WhatIf:($scenario -eq 'WhatIf'))
    }
    catch { $failure = $_.Exception.Message }
    if ($scenario -in @('ActiveProcess', 'LoadedProxy', 'LoadedCimModule', 'RemotingSession', 'NewProcess')) {
        Assert-True ($failure -match 'quiet host|Loaded CIM proxy|remoting sessions' -and $script:Deleted.Count -eq 0) `
            "$scenario did not block cleanup before deletion."
    }
    elseif ($scenario -in @('ChangedDirectory', 'NestedDirectory', 'NestedReparse', 'DeleteFailure')) {
        Assert-True ($failure -match '1 folder\(s\) could not be removed' -and $script:Deleted.Count -eq 200) `
            "$scenario hid a failed deletion or deleted an unsafe directory."
    }
    else {
        $expected = if ($scenario -in @('BelowThreshold', 'WhatIf')) { 0 } elseif ($scenario -eq 'Maintenance') { 201 } else { 200 }
        Assert-True (-not $failure -and $reports.Count -eq 1 -and $reports[0].Removed -eq $expected -and
            $script:Deleted.Count -eq $expected) "$scenario changed the guarded cleanup result: $failure"
        if ($scenario -eq 'WhatIf') {
            Assert-True ($reports[0].Status -eq 'Planned' -and $reports[0].Eligible -eq 201 -and $script:ProcessChecks -eq 0) `
                'WhatIf could not preview the maintenance plan without mutating an active host.'
        }
    }
}
& {
    foreach ($name in @('Start-DHCP', 'Test-CimProxyStale', 'Reset-CimProxyModuleState')) {
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        if (-not $definition) { throw "$name was not found." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $proxyDirectory = 'C:\fixture\remoteIpMoProxy_DhcpServer_fixture'
    $proxyModule = [pscustomobject]@{ Name = 'remoteIpMoProxy_DhcpServer_fixture'; Path = "$proxyDirectory\proxy.psm1" }
    $dhcpModule = [pscustomobject]@{ Name = 'DhcpServer'; Path = 'C:\fixture\DhcpServer\DhcpServer.psd1' }
    function Get-Command {
        param($Name, $ErrorAction)
        Assert-True ($Name -eq 'Get-Service') 'DHCP unexpectedly attempted feature installation.'
        [pscustomobject]@{ Name = $Name }
    }
    function Get-Service {
        param($Name, $ErrorAction)
        Assert-True ($Name -eq 'DHCPServer') 'DHCP inspected an unrelated service.'
        [pscustomobject]@{ Status = 'Running' }
    }
    function Start-Service { throw 'DHCP unexpectedly changed service state.' }
    function Restart-Service { throw 'DHCP unexpectedly restarted WMI or DHCP.' }
    function Install-WindowsFeature { throw 'DHCP unexpectedly installed host features.' }
    function Initialize-MemLabsDhcpServer { $script:PostInstallCalls++ }
    function Get-Module {
        param($Name, [switch]$ListAvailable, $ErrorAction)
        if ($ListAvailable) { return $dhcpModule }
        if ($Name) {
            if ($Name -eq 'DhcpServer' -and $script:DhcpLoaded) { return $dhcpModule }
            return
        }
        if ($script:ProxyLoaded) { $proxyModule }
        if ($script:DhcpLoaded) { $dhcpModule }
    }
    function Test-Path {
        param($LiteralPath)
        if ($LiteralPath -eq $proxyDirectory) { return -not $script:ProxyMissing }
        return $script:DhcpScenario -ne 'MissingTemp' -or $script:Created.Contains($LiteralPath)
    }
    function Remove-Module {
        param($ModuleInfo, $Name, [switch]$Force, $ErrorAction)
        Assert-True ($Force -and $ErrorAction -eq 'Stop') 'Stale-module recovery lost its explicit unload contract.'
        if ($ModuleInfo) {
            Assert-True ($ModuleInfo.Name -eq $proxyModule.Name) 'An unrelated proxy module was unloaded.'
            $script:ProxyLoaded = $false
            $script:ModuleRemovals.Add($ModuleInfo.Name)
        }
        else {
            Assert-True ($Name -eq 'DhcpServer') 'An unrelated native module was unloaded.'
            $script:DhcpLoaded = $false
            $script:ModuleRemovals.Add($Name)
        }
    }
    function Get-PSSession {
        param($ErrorAction)
        $script:CompatReads++
        if ($script:CompatAlive) { [pscustomobject]@{ Name = 'WinPSCompatSession_fixture' } }
    }
    function Remove-PSSession {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)]$Session)
        process {
            Assert-True ($Session.Name -eq 'WinPSCompatSession_fixture') 'An unrelated remoting session was reset.'
            $script:CompatAlive = $false
            $script:CompatRemovals++
        }
    }
    function Import-Module {
        param($Name, [switch]$Force, [switch]$SkipEditionCheck, $ErrorAction)
        $expectedSkip = $PSVersionTable.PSEdition -eq 'Core'
        Assert-True ($Name -eq 'DhcpServer' -and $Force -and $ErrorAction -eq 'Stop' -and
            $PSBoundParameters.ContainsKey('SkipEditionCheck') -eq $expectedSkip -and $SkipEditionCheck.IsPresent -eq $expectedSkip) `
            'DHCP lost its runtime-compatible native force-import recovery path.'
        $script:NativeImports++
        if ($script:DhcpScenario -eq 'ImportRetry' -and $script:NativeImports -eq 1) {
            $script:ProxyLoaded = $true; $script:ProxyMissing = $true
            $script:DhcpLoaded = $true; $script:CompatAlive = $true
            throw 'Could not find a part of the path remoteIpMoProxy_DhcpServer_fixture.format.ps1xml'
        }
        Assert-True (-not $script:ProxyLoaded -and -not $script:CompatAlive) 'DHCP retried import without clearing its stale cached proxy/session.'
        $script:DhcpLoaded = $true
    }
    function Write-GreenCheck {
        param($Message)
        $script:Messages.Add($Message)
    }
    foreach ($scenario in @('Healthy', 'MissingTemp', 'StaleProxy', 'ImportRetry')) {
        $script:CleanupMode = $false; $script:CleanupScenario = ''
        $script:DhcpScenario = $scenario
        $script:Created = [Collections.Generic.List[string]]::new()
        $script:Deleted = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Directories = @{}
        $script:NativeImports = 0; $script:CompatReads = 0; $script:CompatRemovals = 0
        $script:PostInstallCalls = 0
        $script:ProxyLoaded = $scenario -eq 'StaleProxy'; $script:ProxyMissing = $script:ProxyLoaded
        $script:DhcpLoaded = $script:ProxyLoaded; $script:CompatAlive = $script:ProxyLoaded
        $script:ModuleRemovals = [Collections.Generic.List[string]]::new()
        $result = @(Start-DHCP)
        $expectedImports = if ($scenario -eq 'ImportRetry') { 2 } else { 1 }
        $expectedResets = if ($scenario -eq 'Healthy') { 0 } else { 1 }
        Assert-True ($result.Count -eq 1 -and $result[0] -is [bool] -and $result[0] -and
            $script:NativeImports -eq $expectedImports -and $script:CompatReads -eq $expectedResets -and
            $script:Deleted.Count -eq 0 -and $script:PostInstallCalls -eq 1) "$scenario broke DHCP startup/recovery or deleted shared proxies."
        if ($scenario -eq 'MissingTemp') { Assert-True ($script:Created.Count -gt 0) 'DHCP did not repair missing temp paths before import.' }
        if ($scenario -in @('StaleProxy', 'ImportRetry')) {
            Assert-True ($script:ModuleRemovals -contains 'DhcpServer' -and
                $script:ModuleRemovals -contains $proxyModule.Name -and $script:CompatRemovals -eq 1) `
                "$scenario did not unload the stale DHCP/proxy modules and compatibility session."
        }
    }
}
if (-not ('MemLabs.CimProxyCleanupTestLease' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace MemLabs {
    public sealed class CimProxyCleanupTestLease : IDisposable {
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private readonly ManualResetEvent release = new ManualResetEvent(false);
        private readonly Thread thread;
        private Exception failure;
        public bool Acquired { get; private set; }
        public CimProxyCleanupTestLease(string name) {
            thread = new Thread(() => {
                try {
                    using (Mutex mutex = new Mutex(false, name)) {
                        Acquired = mutex.WaitOne(0);
                        ready.Set();
                        if (Acquired) {
                            try {
                                if (!release.WaitOne(10000)) throw new TimeoutException("Lease fixture was not released.");
                            }
                            finally { mutex.ReleaseMutex(); }
                        }
                    }
                }
                catch (Exception error) { failure = error; ready.Set(); }
            });
            thread.IsBackground = true;
            thread.Start();
            if (!ready.WaitOne(10000)) { release.Set(); throw new TimeoutException("Lease fixture did not start."); }
            if (failure != null) throw new InvalidOperationException("Lease fixture failed.", failure);
        }
        public void Dispose() {
            release.Set();
            if (!thread.Join(10000)) throw new TimeoutException("Lease fixture did not stop.");
            ready.Dispose();
            release.Dispose();
            if (failure != null) throw new InvalidOperationException("Lease fixture failed.", failure);
        }
    }
}
'@ -ErrorAction Stop
}
$lastDefinition = $cleanupAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1
$entryText = ($cleanupAst.EndBlock.Statements |
    Where-Object { $_.Extent.StartOffset -gt $lastDefinition.Extent.EndOffset } |
    ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
$mutexName = "Local\MemLabsCimProxyCleanupTest-$([guid]::NewGuid().ToString('N'))"
$entryText = $entryText.Replace('Global\MemLabsTestMutationLock', $mutexName)
$entrypoint = [scriptblock]::Create("[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]`nparam()`n$entryText")
$keepAlive = [Threading.Mutex]::new($false, $mutexName)
try {
    $script:CleanupMode = $true; $script:CleanupScenario = 'Maintenance'
    $script:Directories = @{}; $script:Deleted = [Collections.Generic.List[string]]::new()
    $script:ProcessChecks = 0; $script:Enumerations = 0
    $holder = [MemLabs.CimProxyCleanupTestLease]::new($mutexName)
    try {
        Assert-True $holder.Acquired 'The cleanup lease fixture did not acquire its isolated mutex.'
        $failure = $null
        try { $null = & $entrypoint -Confirm:$false } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'host mutation lease' -and $script:Deleted.Count -eq 0 -and
            $script:Enumerations -eq 0) 'A contended cleanup lease allowed enumeration or deletion.'
        $preview = & $entrypoint -WhatIf
        Assert-True ($preview.Status -eq 'Planned' -and $script:Deleted.Count -eq 0) 'A lease-free WhatIf preview mutated shared proxy folders.'
    }
    finally { $holder.Dispose() }
    $report = & $entrypoint -Confirm:$false
    Assert-True ($report.Removed -eq 201 -and $script:Deleted.Count -eq 201) 'The real maintenance entrypoint lost its guarded cleanup path.'
    $holder = [MemLabs.CimProxyCleanupTestLease]::new($mutexName)
    try { Assert-True $holder.Acquired 'Successful cleanup leaked the host mutation lease.' }
    finally { $holder.Dispose() }
    $script:CleanupScenario = 'ActiveProcess'
    $script:Deleted = [Collections.Generic.List[string]]::new()
    $failure = $null
    try { $null = & $entrypoint -Confirm:$false } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'quiet host' -and $script:Deleted.Count -eq 0) 'The real entrypoint ignored another active PowerShell host.'
    $holder = [MemLabs.CimProxyCleanupTestLease]::new($mutexName)
    try { Assert-True $holder.Acquired 'Failed cleanup leaked the host mutation lease.' }
    finally { $holder.Dispose() }
}
finally { $keepAlive.Dispose() }
Write-Host 'PASS -- DHCP native import/temp/stale-proxy recovery is preserved; explicit cleanup enforces threshold/age boundaries, activity guards, directory rechecks, and WhatIf.'
