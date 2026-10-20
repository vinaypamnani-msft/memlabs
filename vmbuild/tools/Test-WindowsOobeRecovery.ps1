#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess
$phaseRoot = Join-Path $PSScriptRoot '..\DSC\phases'
. (Join-Path $phaseRoot 'WindowsOobeRecovery.ps1')
. (Join-Path $PSScriptRoot 'Common.WindowsVmOobeRepair.ps1')
$actualCompletionWait = ${function:Wait-MemLabsOobeRepairCompletion}
$actualExportValidation = ${function:Test-MemLabsOobeRepairExport}
Add-Type -TypeDefinition @'
using System;
namespace MemLabs {
    public sealed class OobeRepairTestClock {
        public static double Now;
        private readonly double start = Now;
        public static OobeRepairTestClock StartNew() { return new OobeRepairTestClock(); }
        public TimeSpan Elapsed { get { return TimeSpan.FromSeconds(Now - start); } }
        public void Stop() { }
    }
}
'@
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Reset-GuestFixture {
    $script:Registry = @{}
    foreach ($target in Get-MemLabsOobeRepairPolicyTargets) {
        $script:Registry["$($target.Path)|$($target.Name)"] = [pscustomobject]@{ Kind = 'DWord'; Value = 1 }
    }
    $script:MachineGuid = '11111111-1111-1111-1111-111111111111'
    $script:ServiceStartup = 3; $script:ServiceStatus = 'Stopped'; $script:Elevated = $true
    $script:Writes = 0; $script:FailRemove = ''; $script:FailStart = $false
    $script:Setup = [pscustomobject]@{
        Version = 1; Required = $true; ProductType = 1; Ready = $false
        ImageState = 'IMAGE_STATE_UNDEPLOYABLE'; SetupType = 2; SystemSetupInProgress = 0
        OOBEInProgress = 1; NativeOobeComplete = $false; ActiveName = 'UNCHANGED'; PendingName = 'UNCHANGED'
        Reason = 'MachineSetupIncomplete'; Detail = 'Synthetic incomplete OOBE'
    }
}
function Test-MemLabsOobeRepairElevation { return $script:Elevated }
function Get-MemLabsWindowsClientSetupState { return $script:Setup }
function Get-CimInstance {
    param($ClassName, $OperationTimeoutSec, $ErrorAction)
    Assert-True ($ClassName -eq 'Win32_ComputerSystem' -and $OperationTimeoutSec -eq 5) 'Unexpected or unbounded guest CIM query.'
    [pscustomobject]@{ Name = 'UNCHANGED'; Domain = 'fixture.invalid'; PartOfDomain = $true }
}
function Test-Path {
    param($LiteralPath, $ErrorAction)
    if ($LiteralPath -like 'HKLM:*') { return $true }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Get-Item {
    param($LiteralPath, [switch]$Force, $ErrorAction)
    if ($LiteralPath -notlike 'HKLM:*') { return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop }
    $key = [pscustomobject]@{ Path = $LiteralPath }
    $key | Add-Member ScriptMethod GetValueNames {
        @($script:Registry.Keys | Where-Object { $_.StartsWith("$($this.Path)|") } |
            ForEach-Object { $_.Substring($this.Path.Length + 1) })
    }
    $key | Add-Member ScriptMethod GetValueKind { param($name); return $script:Registry["$($this.Path)|$name"].Kind }
    $key | Add-Member ScriptMethod GetValue { param($name, $default, $options); return $script:Registry["$($this.Path)|$name"].Value }
    $key | Add-Member ScriptMethod Dispose {}
    return $key
}
function Get-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Cryptography') { return [pscustomobject]@{ MachineGuid = $script:MachineGuid } }
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv') { return [pscustomobject]@{ Start = $script:ServiceStartup } }
    throw "Unexpected guest registry read: $LiteralPath"
}
function Get-Service {
    param($Name, $ErrorAction)
    Assert-True ($Name -eq 'wuauserv') 'Repair touched another service.'
    $service = [pscustomobject]@{ Status = $script:ServiceStatus }
    $service | Add-Member ScriptMethod WaitForStatus {
        param($status, $timeout)
        Assert-True ($timeout.TotalSeconds -eq 10 -and "$status" -eq $script:ServiceStatus) 'Service operation was unbounded or not verified.'
    }
    return $service
}
function Set-Service {
    param($Name, $StartupType, $ErrorAction)
    Assert-True ($Name -eq 'wuauserv' -and $StartupType -in @('Manual', 'Disabled')) 'Unexpected service configuration change.'
    $script:Writes++
    $script:ServiceStartup = if ($StartupType -eq 'Manual') { 3 } else { 4 }
}
function Start-Service {
    param($Name, $ErrorAction)
    Assert-True ($Name -eq 'wuauserv') 'Unexpected service startup.'
    if ($script:FailStart) { $script:ServiceStatus = 'StartPending'; throw 'Synthetic service startup failure' }
    $script:Writes++; $script:ServiceStatus = 'Running'
}
function Stop-Service {
    param($Name, $ErrorAction)
    Assert-True ($Name -eq 'wuauserv') 'Unexpected service stop.'
    $script:Writes++; $script:ServiceStatus = 'Stopped'
}
function Remove-ItemProperty {
    param($LiteralPath, $Name, $ErrorAction)
    Assert-True (@(Get-MemLabsOobeRepairPolicyTargets | Where-Object { $_.Path -eq $LiteralPath -and $_.Name -eq $Name }).Count -eq 1) 'Repair removed an unapproved registry value.'
    if ($Name -eq $script:FailRemove) { throw 'Synthetic policy write failure' }
    $script:Writes++
    $script:Registry.Remove("$LiteralPath|$Name")
}
function New-ItemProperty {
    param($LiteralPath, $Name, $PropertyType, $Value, [switch]$Force, $ErrorAction)
    Assert-True (@(Get-MemLabsOobeRepairPolicyTargets | Where-Object { $_.Path -eq $LiteralPath -and $_.Name -eq $Name }).Count -eq 1 -and
        $PropertyType -eq 'DWord' -and $Value -eq 1) 'Restoration wrote an unapproved registry value.'
    $script:Writes++
    $script:Registry["$LiteralPath|$Name"] = [pscustomobject]@{ Kind = 'DWord'; Value = $Value }
}
function New-Item {
    param($Path, $ItemType, [switch]$Force, $ErrorAction)
    if ($Path -like 'HKLM:*') {
        Assert-True (@(Get-MemLabsOobeRepairPolicyTargets | Where-Object Path -eq $Path).Count -gt 0) 'Restoration created an unapproved registry key.'
        return
    }
    Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force -ErrorAction Stop
}
Reset-GuestFixture
$snapshot = Get-MemLabsOobeRepairGuestState
$receipt = Invoke-MemLabsWindowsOobeRecovery -Action Apply -Snapshot $snapshot -Confirm:$false
Assert-True ($receipt.Status -eq 'Applied' -and $script:Registry.Count -eq 0 -and $script:ServiceStatus -eq 'Running') 'Known update blockers were not removed.'
$receipt = Invoke-MemLabsWindowsOobeRecovery -Action Restore -Snapshot $snapshot -Confirm:$false
Assert-True ($receipt.Status -eq 'Restored' -and $script:Registry.Count -eq 3 -and $script:ServiceStatus -eq 'Stopped') 'Original update policy/service state was not restored.'
Reset-GuestFixture
$script:ServiceStartup = 4
$snapshot = Get-MemLabsOobeRepairGuestState
$null = Invoke-MemLabsWindowsOobeRecovery -Action Apply -Snapshot $snapshot -Confirm:$false
$null = Invoke-MemLabsWindowsOobeRecovery -Action Restore -Snapshot $snapshot -Confirm:$false
Assert-True ($script:ServiceStartup -eq 4 -and $script:ServiceStatus -eq 'Stopped') 'Disabled service configuration was not restored.'
foreach ($scenario in @('Admin', 'Machine', 'Type', 'PolicyRace', 'UnknownPolicy', 'AlreadyComplete', 'Specialize', 'NoCandidate')) {
    Reset-GuestFixture
    $snapshot = Get-MemLabsOobeRepairGuestState
    if ($scenario -eq 'Admin') { $script:Elevated = $false }
    if ($scenario -eq 'Machine') { $script:MachineGuid = '22222222-2222-2222-2222-222222222222' }
    if ($scenario -eq 'Type') { $snapshot.Policies[0].Value = '1' }
    if ($scenario -eq 'PolicyRace') { $script:Registry["$($snapshot.Policies[0].Path)|$($snapshot.Policies[0].Name)"].Value = 0 }
    if ($scenario -eq 'UnknownPolicy') { $snapshot.Policies[0].Path = 'HKLM:\UNAPPROVED' }
    if ($scenario -eq 'AlreadyComplete') { $script:Setup.Ready = $true }
    if ($scenario -eq 'Specialize') { $script:Setup.SystemSetupInProgress = 1 }
    if ($scenario -eq 'NoCandidate') {
        foreach ($value in $script:Registry.Values) { $value.Value = 0 }
        $script:ServiceStatus = 'Running'; $snapshot = Get-MemLabsOobeRepairGuestState
    }
    $failure = $null
    try { $null = Invoke-MemLabsWindowsOobeRecovery -Action Apply -Snapshot $snapshot -Confirm:$false }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure -and $script:Writes -eq 0) "$scenario allowed a speculative/unsafe guest write."
}
foreach ($scenario in @('PartialPolicyWrite', 'ServiceStart')) {
    Reset-GuestFixture
    $snapshot = Get-MemLabsOobeRepairGuestState
    if ($scenario -eq 'PartialPolicyWrite') { $script:FailRemove = 'DoNotConnectToWindowsUpdateInternetLocations' }
    else { $script:FailStart = $true }
    $failure = $null
    try { $null = Invoke-MemLabsWindowsOobeRecovery -Action Apply -Snapshot $snapshot -Confirm:$false }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'original settings were restored' -and $script:Registry.Count -eq 3 -and
        $script:ServiceStatus -eq 'Stopped') "$scenario failed without restoring changed settings."
}
Reset-GuestFixture
$snapshot = Get-MemLabsOobeRepairGuestState
$null = Invoke-MemLabsWindowsOobeRecovery -Action Apply -Snapshot $snapshot -WhatIf
Assert-True ($script:Writes -eq 0) 'Guest WhatIf changed settings.'

$collectorPath = Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'
$tokens = $null; $errors = $null
$collectorAst = [Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$errors)
foreach ($name in @('Resolve-MemLabsSetupDiagnosticPath', 'New-MemLabsPrivateDiagnosticDirectory')) {
    $definition = $collectorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-oobe-repair-$([guid]::NewGuid().ToString('N'))"
$null = Microsoft.PowerShell.Management\New-Item -Path $testRoot -ItemType Directory
$script:VMId = [guid]::NewGuid()
$script:VM = [pscustomobject]@{ Name = 'TEST-CLIENT'; Id = $script:VMId; Path = 'C:\fixture\vm'; State = 'Off'; Heartbeat = 'OkApplicationsUnknown' }
$script:JobSequence = 0
function New-FixtureJob {
    param($Output)
    $script:JobSequence++
    $job = [pscustomobject]@{ Id = $script:JobSequence; State = 'Completed'; Output = $Output }
    $job | Add-Member ScriptMethod StopJobAsync { $script:AsyncStops++; if (-not $script:KeepStopping) { $this.State = 'Stopped' } }
    return $job
}
function Get-VM {
    param($Name, $Id, $ErrorAction)
    $script:VMReads++
    if ($Name -and $Name -ne $script:VM.Name) { throw 'Wrong VM name' }
    if ($Id -and $Id -ne $script:VMId) { throw 'Wrong VM ID' }
    return $script:VM
}
function Initialize-MemLabsSetupDiagnosticModules {
    $script:HostModuleChecks++
    if ($script:HostModuleFails) { throw 'Synthetic diagnostic host dependency failure' }
}
function Get-VMHardDiskDrive {
    param($VM, $ErrorAction)
    Assert-True ($VM.Id -eq $script:VMId) 'Disk inventory targeted another VM.'
    [pscustomobject]@{ Path = 'C:\fixture\vm\os.avhdx'; SupportPersistentReservations = $false }
}
function Wait-Job {
    param($Job, $Timeout, $ErrorAction)
    $script:JobBudgets.Add($Timeout)
    if ($script:JobTimesOut) { return }
    return $Job
}
function Receive-Job { param($Job, $ErrorAction); return $Job.Output }
function Remove-Job { param($Job, [switch]$Force, $ErrorAction); $script:RemovedJobs++ }
function Export-VM {
    param($VM, $Path, [switch]$AsJob, $Confirm, $ErrorAction)
    Assert-True ($VM.Id -eq $script:VMId -and $VM.State -eq 'Off' -and $AsJob) 'Backup did not target the selected stopped VM.'
    $script:Exports++
    return New-FixtureJob
}
function Test-MemLabsOobeRepairExport {
    param($Path, $VMId, $DiskCount)
    if ($script:BadExport) { throw 'Synthetic incomplete backup' }
    [pscustomobject]@{ Version = 1; VMId = "$VMId"; DiskCount = $DiskCount; Verified = $true }
}
function Start-MemLabsOobeRepairVm {
    param($VM)
    $script:Starts++
    $script:VM.State = 'Running'
}
function Stop-MemLabsVmForSetupDiagnostics {
    param($VM, $TimeoutSeconds, [switch]$AllowTurnOff)
    Assert-True ($VM.Id -eq $script:VMId -and -not $AllowTurnOff) 'Verification used another VM or forced power-off.'
    $script:Stops++
    $script:VM.State = 'Off'
}
function Invoke-MemLabsWindowsSetupDiagnostics {
    param($VmName, $Destination, $StopTimeoutSeconds, [switch]$AllowTurnOff, $Confirm)
    $script:Diagnostics++
    $script:VM.State = 'Off'
    $container = Join-Path $testRoot "diagnostic-$([guid]::NewGuid().ToString('N'))"
    $bundle = Join-Path $container 'Bundle'
    $null = Microsoft.PowerShell.Management\New-Item -Path $bundle -ItemType Directory -Force
    $incomplete = $script:Diagnostics -eq 1 -or $script:BadPersistence
    $state = @{
        SOFTWARE = @{ WindowsVersion = @{ Values = @{ InstallationType = 'Client' } }; ImageState = @{ Values = @{ ImageState = $(if ($incomplete) { 'IMAGE_STATE_UNDEPLOYABLE' } else { 'IMAGE_STATE_COMPLETE' }) } } }
        SYSTEM = @{ Setup = @{ Values = @{ OOBEInProgress = $(if ($incomplete) { 1 } else { 0 }); SetupType = $(if ($incomplete) { 2 } else { 0 }); SystemSetupInProgress = 0 } }; ChildCompletion = @{ Values = @{ 'setup.exe' = 3 } } }
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'WindowsSetupState.json') -Encoding UTF8
    $archive = Join-Path $container 'diagnostic.zip'
    [IO.File]::WriteAllText($archive, 'synthetic diagnostic archive')
    [pscustomobject]@{ ArchivePath = $archive; Status = 'Complete'; FinalState = 'Off' }
}
function Invoke-MemLabsOobeRepairGuestCommand {
    param($VM, [pscredential]$GuestCredential, $GuestBlock, $Action, $Snapshot, $TimeoutSeconds)
    $script:Actions.Add($Action)
    if ($Action -eq 'Inspect') {
        if ($script:AuthFails) { throw 'Synthetic PowerShell Direct authentication failure' }
        return $script:Snapshot
    }
    if ($Action -eq 'Apply') {
        if ($script:ApplyUnknown) {
            $exception = [TimeoutException]::new('Synthetic unknown mutation outcome')
            $exception.Data['OobeRepairIndeterminate'] = $true
            throw $exception
        }
        return [pscustomobject]@{ Version = 1; Scope = 'OobeOnly'; Status = 'Applied'; MachineGuid = $script:Snapshot.MachineGuid; IdentityRepairPerformed = $false }
    }
    if ($Action -eq 'Restore') {
        if ($script:RestoreFails) { throw 'Synthetic restoration failure' }
        return [pscustomobject]@{ Version = 1; Scope = 'OobeOnly'; Status = 'Restored'; MachineGuid = $script:Snapshot.MachineGuid; IdentityRepairPerformed = $false }
    }
    if ($Action -eq 'Probe') {
        [MemLabs.OobeRepairTestClock]::Now += $script:ProbeDelay
        if ($script:ProbeReplies.Count) { $script:LastProbe = $script:ProbeReplies.Dequeue() }
        return $script:LastProbe
    }
    throw "Unexpected guest action: $Action"
}
function Wait-MemLabsOobeRepairCompletion {
    param($VM, [pscredential]$GuestCredential, $GuestBlock, $MachineGuid, $TimeoutSeconds, $StableSeconds = 0, $ExpectedName)
    $script:StabilityChecks.Add($StableSeconds)
    if ($script:OobeFails -or ($script:VerificationFails -and $StableSeconds -gt 0)) { throw 'Synthetic OOBE completion/stability failure' }
    if ($StableSeconds -gt 0) { Assert-True ($StableSeconds -eq 190 -and $ExpectedName -eq 'UNCHANGED') 'Reboot verification missed the watchdog/name-stability requirement.' }
    $result = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($script:Snapshot, 10))
    $result.Setup.Ready = $true; $result.Setup.NativeOobeComplete = $true
    $result.Setup.Reason = 'Complete'; $result.Setup.Detail = 'Synthetic complete OOBE'
    $result.Setup.OOBEInProgress = 0; $result.Setup.SetupType = 0; $result.Setup.ImageState = 'IMAGE_STATE_COMPLETE'
    return $result
}
function Reset-HostFixture {
    Reset-GuestFixture
    $script:Snapshot = Get-MemLabsOobeRepairGuestState
    $script:VM.State = 'Off'
    $script:Exports = 0; $script:Starts = 0; $script:Stops = 0; $script:Diagnostics = 0
    $script:VMReads = 0
    $script:HostModuleChecks = 0; $script:HostModuleFails = $false
    $script:BadExport = $false; $script:AuthFails = $false; $script:ApplyUnknown = $false
    $script:RestoreFails = $false; $script:OobeFails = $false; $script:VerificationFails = $false; $script:BadPersistence = $false
    $script:Actions = [Collections.Generic.List[string]]::new()
    $script:StabilityChecks = [Collections.Generic.List[int]]::new()
    $script:JobBudgets = [Collections.Generic.List[int]]::new()
    $script:JobTimesOut = $false; $script:RemovedJobs = 0; $script:AsyncStops = 0; $script:KeepStopping = $false
    $script:ProbeReplies = [Collections.Generic.Queue[object]]::new()
    $script:ProbeDelay = 0
    $script:LastProbe = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($script:Snapshot, 10))
    $script:LastProbe.Setup.Ready = $true; $script:LastProbe.Setup.NativeOobeComplete = $true
    $script:LastProbe.Setup.Reason = 'Complete'; $script:LastProbe.Setup.Detail = 'Synthetic complete OOBE'
    $script:LastProbe.Setup.ImageState = 'IMAGE_STATE_COMPLETE'; $script:LastProbe.Setup.SetupType = 0; $script:LastProbe.Setup.OOBEInProgress = 0
}
function Start-Sleep {
    param($Seconds)
    [MemLabs.OobeRepairTestClock]::Now += $Seconds
}
function Start-Job {
    param($ArgumentList, $ScriptBlock)
    $output = & $ScriptBlock @ArgumentList
    New-FixtureJob -Output $output
}
function Test-VHD {
    param($Path, $ErrorAction)
    return $script:ExportDiskValid
}
function Get-VHD {
    param($Path, $ErrorAction)
    [pscustomobject]@{ ParentPath = $script:ExportParent }
}
$secret = [Security.SecureString]::new()
foreach ($character in 'NOT-A-REAL-PASSWORD-DO-NOT-ARCHIVE'.ToCharArray()) { $secret.AppendChar($character) }
$secret.MakeReadOnly()
$credential = [pscredential]::new('fixtureadmin', $secret)
$parameters = @{ VmName = 'TEST-CLIENT'; Destination = (Join-Path $testRoot 'results'); BackupPath = (Join-Path $testRoot 'backups'); GuestCredential = $credential; Confirm = $false }
$previousCommonVariable = Get-Variable -Name Common -Scope Global -ErrorAction SilentlyContinue
$hadCommon = $null -ne $previousCommonVariable
$previousCommonValue = if ($hadCommon) { $previousCommonVariable.Value } else { $null }
try {
    $credentialCache = Join-Path $testRoot 'credential-cache'
    $null = Microsoft.PowerShell.Management\New-Item -Path $credentialCache -ItemType Directory
    $cachedCredentialFile = Join-Path $credentialCache 'vmbuildadmin.txt'
    $global:Common = [pscustomobject]@{ LocalAdmin = $credential; CachePath = $credentialCache; OfflineMode = $false }
    $resolved = Resolve-MemLabsOobeRepairCredential
    Assert-True ([object]::ReferenceEquals($resolved, $credential)) 'The already-loaded main-script credential was not reused.'
    $override = [pscredential]::new('explicitoverride', $secret)
    $resolved = Resolve-MemLabsOobeRepairCredential -GuestCredential $override
    Assert-True ([object]::ReferenceEquals($resolved, $override)) 'The explicit credential did not override automatic credentials.'
    $global:Common.LocalAdmin = $null
    [IO.File]::WriteAllText($cachedCredentialFile, 'NOT-A-REAL-PASSWORD-DO-NOT-ARCHIVE')
    $resolved = Resolve-MemLabsOobeRepairCredential
    Assert-True ($resolved -is [pscredential] -and $resolved.UserName -eq 'vmbuildadmin' -and
        $resolved.Password.Length -eq $secret.Length -and $null -eq $global:Common.LocalAdmin -and
        $global:Common.OfflineMode -eq $false) 'The main cache loader failed or changed the caller main-script context.'
    foreach ($cacheCase in @('Missing', 'Empty')) {
        if ($cacheCase -eq 'Missing') { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $cachedCredentialFile -Force }
        else { [IO.File]::WriteAllText($cachedCredentialFile, '   ') }
        $failure = $null
        try { $null = Resolve-MemLabsOobeRepairCredential }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'saved|credential' -and -not $failure.Contains('NOT-A-REAL-PASSWORD-DO-NOT-ARCHIVE')) `
            "$cacheCase cached credential was silently accepted or exposed."
    }
    $global:Common.LocalAdmin = $credential

    Reset-HostFixture
    $script:VM.State = 'Running'
    $script:HostModuleFails = $true
    $failure = $null
    $directoryCount = @(Get-ChildItem -LiteralPath $testRoot -Directory).Count
    try { $null = Invoke-MemLabsWindowsOobeRepair @parameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'Synthetic diagnostic host dependency failure' -and $script:HostModuleChecks -eq 1 -and
        $script:VM.State -eq 'Running' -and $script:Exports -eq 0 -and $script:Starts -eq 0 -and
        $script:Stops -eq 0 -and $script:Diagnostics -eq 0 -and $script:Actions.Count -eq 0 -and
        @(Get-ChildItem -LiteralPath $testRoot -Directory).Count -eq $directoryCount) `
        'A repair dependency failure reached power, backup, guest, or output changes.'
    Reset-HostFixture
    $result = Invoke-MemLabsWindowsOobeRepair @parameters
    Assert-True ($result.Status -eq 'OobeRecoveredIdentityUnchanged' -and $result.FinalState -eq 'Off' -and
        $script:Exports -eq 1 -and $script:Starts -eq 3 -and $script:Stops -eq 3 -and $script:Diagnostics -eq 2 -and
        $script:StabilityChecks.Count -eq 3 -and $script:Actions -contains 'Restore') 'Successful OOBE-only orchestration did not back up, restore, verify two reboots, and finish Off.'
    $zip = [IO.Compression.ZipFile]::OpenRead($result.ArchivePath)
    try {
        Assert-True (@($zip.Entries | Where-Object FullName -match '\.(vhdx?|avhdx?|vmcx)$').Count -eq 0) 'Repair evidence includes the full VM backup.'
        foreach ($entry in $zip.Entries | Where-Object Length -gt 0) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { Assert-True (-not $reader.ReadToEnd().Contains('NOT-A-REAL-PASSWORD-DO-NOT-ARCHIVE')) 'A credential leaked into the report.' }
            finally { $reader.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    Reset-HostFixture
    $automaticParameters = @{} + $parameters
    $automaticParameters.Remove('BackupPath')
    $automaticParameters.Remove('GuestCredential')
    $result = Invoke-MemLabsWindowsOobeRepair @automaticParameters
    $noBackupReport = Get-Content -LiteralPath (Join-Path (Split-Path $result.ArchivePath -Parent) 'Bundle\RepairResult.json') -Raw | ConvertFrom-Json
    Assert-True ($script:Exports -eq 0 -and $script:Starts -eq 3 -and
        $noBackupReport.BackupRequested -eq $false -and $noBackupReport.BackupVerified -eq $false -and
        $null -eq $noBackupReport.BackupPath -and $result.Status -eq 'OobeRecoveredIdentityUnchanged') `
        'Automatic-credential/no-backup mode exported a VM or misreported its backup/recovery state.'
    Reset-HostFixture
    $global:Common.LocalAdmin = $null
    [IO.File]::WriteAllText($cachedCredentialFile, ' ')
    $failure = $null
    try { $null = Invoke-MemLabsWindowsOobeRepair @automaticParameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure -and $script:Starts -eq 0 -and $script:Exports -eq 0 -and $script:Diagnostics -eq 0) `
        'Unavailable automatic credentials permitted a guest/VM operation.'
    $global:Common.LocalAdmin = $credential
    foreach ($scenario in @('Backup', 'Authentication', 'Oobe', 'Verification', 'Persistence', 'Restore', 'Indeterminate')) {
        Reset-HostFixture
        if ($scenario -eq 'Backup') { $script:BadExport = $true }
        if ($scenario -eq 'Authentication') { $script:AuthFails = $true }
        if ($scenario -in @('Oobe', 'Restore')) { $script:OobeFails = $true }
        if ($scenario -eq 'Verification') { $script:VerificationFails = $true }
        if ($scenario -eq 'Persistence') { $script:BadPersistence = $true }
        if ($scenario -eq 'Restore') { $script:RestoreFails = $true }
        if ($scenario -eq 'Indeterminate') { $script:ApplyUnknown = $true }
        $failure = $null
        try { $null = Invoke-MemLabsWindowsOobeRepair @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) "$scenario was reported as recovery success."
        if ($scenario -eq 'Backup') { Assert-True ($script:Starts -eq 0 -and $script:Actions.Count -eq 0) 'An unverified backup permitted VM startup/repair.' }
        if ($scenario -eq 'Authentication') { Assert-True ($script:Actions.Count -eq 1 -and $script:Actions[0] -eq 'Inspect') 'Authentication failure did not stop before guest changes.' }
        if ($scenario -eq 'Oobe') { Assert-True ($script:Actions -contains 'Restore' -and $script:VM.State -eq 'Off') 'Failed OOBE completion did not restore settings and stop gracefully.' }
        if ($scenario -eq 'Indeterminate') { Assert-True (-not ($script:Actions -contains 'Restore') -and $script:Stops -eq 0 -and $script:VM.State -eq 'Running') 'Unknown mutation outcome triggered unsafe follow-up changes.' }
    }
    Reset-HostFixture
    $null = Invoke-MemLabsWindowsOobeRepair @parameters -WhatIf
    Assert-True ($script:Exports -eq 0 -and $script:Starts -eq 0 -and $script:Diagnostics -eq 0 -and
        $script:HostModuleChecks -eq 0) 'Repair WhatIf initialized modules or changed state/evidence.'
    Reset-HostFixture
    $failure = $null
    $wildcardParameters = @{} + $parameters
    $wildcardParameters.VmName = '*'
    try { $null = Invoke-MemLabsWindowsOobeRepair @wildcardParameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure -and $script:VMReads -eq 0 -and $script:Exports -eq 0) 'Wildcard repair reached backup or VM operations.'
    Reset-HostFixture
    $insideParameters = @{} + $parameters
    $insideParameters.BackupPath = 'C:\fixture\vm\backups'
    $failure = $null
    try { $null = Invoke-MemLabsWindowsOobeRepair @insideParameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'outside' -and $script:Exports -eq 0 -and $script:Starts -eq 0) 'A recursive/in-place backup was accepted.'
    Reset-HostFixture
    $job = New-FixtureJob
    $job.State = 'Running'; $script:JobTimesOut = $true; $script:KeepStopping = $true
    $failure = $null
    try { $null = Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds 1 -Operation 'fixture mutation' }
    catch { $failure = $_ }
    Assert-True ($failure.Exception.Data['OobeRepairIndeterminate'] -eq $true -and $script:AsyncStops -gt 0 -and
        $script:RemovedJobs -eq 0) 'An owned timed-out job was treated as known/stopped or disposed while running.'

    $waitBody = $actualCompletionWait.ToString().Replace('[Diagnostics.Stopwatch]::StartNew()', '[MemLabs.OobeRepairTestClock]::StartNew()')
    $clockedWait = [scriptblock]::Create($waitBody)
    Reset-HostFixture
    [MemLabs.OobeRepairTestClock]::Now = 0
    $waitParameters = @{
        VM = $script:VM; GuestCredential = $credential; GuestBlock = {}
        MachineGuid = $script:Snapshot.MachineGuid; TimeoutSeconds = 200
        StableSeconds = 190; ExpectedName = 'UNCHANGED'
    }
    $null = & $clockedWait @waitParameters
    Assert-True ([MemLabs.OobeRepairTestClock]::Now -ge 190 -and [MemLabs.OobeRepairTestClock]::Now -lt 195) `
        'Post-reboot verification did not enforce the exact 190-second stability threshold.'
    Reset-HostFixture
    [MemLabs.OobeRepairTestClock]::Now = 0
    $script:ProbeReplies.Enqueue($script:LastProbe)
    $script:ProbeReplies.Enqueue($script:Snapshot)
    $failure = $null
    try { $null = & $clockedWait @waitParameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 're-entered incomplete OOBE') 'A setup rollback during the stability window was accepted.'
    Reset-HostFixture
    [MemLabs.OobeRepairTestClock]::Now = 0
    $script:ProbeDelay = 201
    $failure = $null
    try { $null = & $clockedWait @waitParameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'not verified within') 'A late ready reply passed after the repair verification deadline.'

    $exportFixture = Join-Path $testRoot 'export-fixture'
    $null = Microsoft.PowerShell.Management\New-Item -Path $exportFixture -ItemType Directory
    [IO.File]::WriteAllText((Join-Path $exportFixture "$($script:VMId).vmcx"), 'synthetic config')
    [IO.File]::WriteAllText((Join-Path $exportFixture 'os.vhdx'), 'synthetic disk')
    Reset-HostFixture
    $script:ExportDiskValid = $true; $script:ExportParent = ''
    $validated = & $actualExportValidation -Path $exportFixture -VMId $script:VMId -DiskCount 1
    Assert-True $validated.Verified 'A self-contained valid export was rejected.'
    foreach ($scenario in @('BadDisk', 'ExternalParent', 'MissingDisk')) {
        Reset-HostFixture
        $script:ExportDiskValid = $scenario -ne 'BadDisk'
        $script:ExportParent = if ($scenario -eq 'ExternalParent') { 'C:\outside-backup\parent.vhdx' } else { '' }
        $minimum = if ($scenario -eq 'MissingDisk') { 2 } else { 1 }
        $failure = $null
        try { $null = & $actualExportValidation -Path $exportFixture -VMId $script:VMId -DiskCount $minimum }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) "$scenario passed full VM backup validation."
    }

    $tokens = $null; $errors = $null
    $guestAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $phaseRoot 'WindowsOobeRecovery.ps1'), [ref]$tokens, [ref]$errors)
    $commands = @($guestAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Assert-True (@($commands | Where-Object { $_ -match 'Rename-Computer|Add-Computer|Remove-Computer|Reset-ComputerMachinePassword|Test-ComputerSecureChannel|Add-AppxPackage|icacls|takeown|reg\.exe' }).Count -eq 0) `
        'OOBE-only recovery includes identity/ACL/app-registration or setup-bypass commands.'

    $lastDefinition = $collectorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1
    $footer = ($collectorAst.EndBlock.Statements |
        Where-Object { $_.Extent.StartOffset -gt $lastDefinition.Extent.EndOffset } |
        ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    $footer = $footer.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
    $parameterText = $collectorAst.ParamBlock.Extent.Text
    if ($parameterText -notmatch 'CmdletBinding') {
        $parameterText = "[CmdletBinding(DefaultParameterSetName='Collect', SupportsShouldProcess)]`n$parameterText"
    }
    $entrypoint = [scriptblock]::Create("$parameterText`n$footer")
    Reset-HostFixture
    $null = & $entrypoint -VmName TEST-CLIENT -Destination (Join-Path $testRoot 'entry-output') `
        -RepairOobe -BackupPath (Join-Path $testRoot 'entry-backup') -GuestCredential $credential -WhatIf
    Assert-True ($script:Exports -eq 0 -and $script:Starts -eq 0 -and $script:Diagnostics -eq 0) `
        'The actual repair entrypoint mutated state under WhatIf.'
    $null = & $entrypoint -VmName TEST-CLIENT -Destination (Join-Path $testRoot 'entry-output') -RepairOobe -WhatIf
    Assert-True ($script:Exports -eq 0 -and $script:Starts -eq 0 -and $script:Diagnostics -eq 0) `
        'The automatic/no-backup repair entrypoint required an export or manual credential.'
    $failure = $null
    try {
        $null = & $entrypoint -VmName TEST-CLIENT -Destination (Join-Path $testRoot 'entry-output') -RepairOobe:$false `
            -BackupPath (Join-Path $testRoot 'entry-backup') -GuestCredential $credential -WhatIf
    }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'explicitly enabled') 'Repair-specific parameters silently enabled mutation without the repair switch.'
}
finally {
    if ($hadCommon) { $global:Common = $previousCommonValue }
    else { Remove-Variable -Name Common -Scope Global -ErrorAction SilentlyContinue }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS -- scoped guest trial/rollback, backup-before-start, authentication stop, two-reboot verification, privacy, and indeterminate outcomes.'
