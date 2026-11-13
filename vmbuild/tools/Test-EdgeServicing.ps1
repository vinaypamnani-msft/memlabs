<#
.SYNOPSIS
    Exercises late Edge servicing without installing software or changing services.
#>
[CmdletBinding()]
param([string]$RootPath)
$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
# Windows PowerShell exports Get-FileHash as a function; load it before installing mocks.
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
$fixesToPerform = @()
. (Join-Path $RootPath 'Fixes\Fix-EdgeServicing.ps1')
if ($fixesToPerform.Count -ne 1 -or -not $fixesToPerform[0].NeededOnFreshDeploy -or
    -not $fixesToPerform[0].AppliesToExisting -or -not $fixesToPerform[0].DoNotSeedFromWatermark -or
    'StandaloneRootCA' -notin $fixesToPerform[0].NotAppliesToRoles -or
    $fixesToPerform[0].FixVersion -ne '261103.0' -or
    $fixesToPerform[0].PrepareScriptBlock -isnot [scriptblock]) { throw 'Edge servicing registration lost its version/late/fresh/existing/offline-root/host-staging contract.' }
$body = $fixesToPerform[0].ScriptBlock
$preparation = $fixesToPerform[0].PrepareScriptBlock
$state = [pscustomobject]@{
    Installed='86.0.622.38'; Target='156.0.0.0'; ExitCodes=@(0); UpdateFiles=$true
    HashValid=$true; SignatureValid=$true; MetadataFails=$false; MetadataFault=''; PolicyValues=$null; Timeout=$false
    ServicesPresent=$true; TasksPresent=$true; InstallCalls=0; DownloadCalls=0; Stops=0; ServiceStarts=0
    DownloadBytes=64; Temporary=$null; ServiceFailure=$false; TaskFailure=$false
    MsiRegistered=$false; RepairCalls=0; DelayedVersion=$false; PendingVersionReads=0; UpdateBeforeRepair=$false
    SignerSubject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    Services=@(); Tasks=@(); Logs=[Collections.Generic.List[string]]::new()
    Calls=[Collections.Generic.List[object]]::new(); VerificationSleeps=0
    AllowNetwork=$false; MetadataCalls=0; StagedPresent=$true; DownloadFailure=$false
    ProbeMode=''; ProbeArchitecture=''; ProbeCalls=0; ServiceWrites=0; TaskWrites=0
}
function Write-Log { param($Message,[switch]$Warning,[switch]$LogOnly); $state.Logs.Add("$Message") }
function Write-FixLog {
    param($Message,$Level)
    $state.Logs.Add("$Level $Message")
    if ($state.UpdateBeforeRepair -and $Message -match 'retrying the verified package in repair mode') {
        $state.Installed='157.0.0.0'
    }
}
function Test-Path {
    param($LiteralPath,$PathType)
    if ($LiteralPath -like 'HKLM:*') { return $null -ne $state.PolicyValues }
    if ($LiteralPath -like '*Microsoft\Edge\Application\msedge.exe') { return $null -ne $state.Installed }
    if ($LiteralPath -like 'C:\staging\MemLabs-Edge-*.msi') { return $state.StagedPresent }
    [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
}
function Get-Item {
    param($LiteralPath,$ErrorAction)
    $state.Logs.Add("Get-Item $LiteralPath version=$($state.Installed)")
    if ($LiteralPath -like '*Microsoft\Edge\Application\msedge.exe') {
        if ($state.PendingVersionReads -gt 0) {
            $state.PendingVersionReads--
            if ($state.PendingVersionReads -eq 0) { $state.Installed=$state.Target }
        }
        return [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductVersion=$state.Installed}}
    }
    if ($LiteralPath -like 'C:\staging\MemLabs-Edge-*.msi') { return [pscustomobject]@{Length=$state.DownloadBytes} }
    [IO.FileInfo]::new($LiteralPath)
}
function New-Item {
    param($Path,$ItemType,[switch]$Force,$ErrorAction)
    if ($Path -like 'C:\staging*') { return [pscustomobject]@{FullName=$Path} }
    $null = [IO.Directory]::CreateDirectory($Path)
}
function Get-ItemProperty { param($LiteralPath,$ErrorAction); $state.PolicyValues }
function Get-Service { param($ErrorAction); if ($state.ServicesPresent) { $state.Services } }
function Set-Service {
    param($Name,$StartupType,$ErrorAction)
    $state.ServiceWrites++
    if ($state.ServiceFailure) { throw 'Fixture service change denied' }
    foreach ($service in $state.Services | Where-Object Name -eq $Name) { $service.StartType=$StartupType }
}
function Start-Service {
    param($Name,$ErrorAction)
    $state.ServiceStarts++
    throw 'Fixture: demand-activated Edge updater services must not be forced to start.'
}
function Get-ScheduledTask { param($ErrorAction); if ($state.TasksPresent) { $state.Tasks } }
function Enable-ScheduledTask {
    param($TaskName,$TaskPath,$ErrorAction)
    $state.TaskWrites++
    if ($state.TaskFailure) { throw 'Fixture task change denied' }
    foreach ($task in $state.Tasks | Where-Object TaskName -eq $TaskName) { $task.State='Ready' }
}
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$ErrorAction)
    if (-not $state.AllowNetwork) { throw 'An isolated guest attempted an internet metadata request.' }
    $state.MetadataCalls++
    if ($Uri -ne 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -or $TimeoutSec -ne 30) { throw 'Edge metadata source or timeout changed.' }
    if ($state.MetadataFails) { throw 'Fixture metadata offline' }
    $artifact = [pscustomobject]@{
        ArtifactName='msi'; Location='https://msedge.sf.dl.delivery.mp.microsoft.com/fixture/edge.msi'
        HashAlgorithm='SHA256'; Hash=('A'*64); SizeInBytes=64
    }
    switch ($state.MetadataFault) {
        InsecureOrigin { $artifact.Location='http://msedge.sf.dl.delivery.mp.microsoft.com/fixture/edge.msi' }
        LookalikeOrigin { $artifact.Location='https://dl.delivery.mp.microsoft.com.example.invalid/edge.msi' }
        UserInfoOrigin { $artifact.Location='https://fixture@msedge.sf.dl.delivery.mp.microsoft.com/edge.msi' }
        InvalidHash { $artifact.Hash='invalid' }
        WrongHashAlgorithm { $artifact.HashAlgorithm='SHA1' }
        Oversized { $artifact.SizeInBytes=1GB+1 }
        ZeroSize { $artifact.SizeInBytes=0 }
        InvalidSize { $artifact.SizeInBytes='invalid' }
        WrongArtifact { $artifact.ArtifactName='exe' }
        LowercaseHash { $artifact.Hash='a'*64 }
    }
    $architectures = @('x64','x86','arm64')
    if ($state.MetadataFault -eq 'MissingArchitecture') { $architectures=@('unsupported') }
    $version = $state.Target
    if ($state.MetadataFault -eq 'InvalidVersion') { $version='invalid' }
    $artifacts = @($artifact)
    if ($state.MetadataFault -eq 'DuplicateArtifact') { $artifacts += $artifact }
    $product = [pscustomobject]@{Product='Stable';Releases=@(
        foreach ($architecture in $architectures) {
            [pscustomobject]@{Platform='Windows';Architecture=$architecture;ProductVersion=$version;Artifacts=$artifacts}
            [pscustomobject]@{Platform='Windows';Architecture=$architecture;ProductVersion='100.0.0.0';Artifacts=$artifacts}
        }
        [pscustomobject]@{Platform='Linux';Architecture='x64';ProductVersion='999.0.0.0';Artifacts=$artifacts}
    )}
    if ($state.MetadataFault -eq 'WrongProduct') { $product.Product='Beta' }
    if ($state.MetadataFault -eq 'DuplicateStable') { $product }
    $product
}
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction)
    if (-not $state.AllowNetwork) { throw 'An isolated guest attempted an internet download.' }
    if ($Uri -notlike 'https://msedge.sf.dl.delivery.mp.microsoft.com/*' -or -not $UseBasicParsing -or $TimeoutSec -ne 180) { throw 'Edge download source or bounded streaming changed.' }
    $state.DownloadCalls++
    $state.Temporary = [IO.Path]::GetDirectoryName($OutFile)
    [IO.File]::WriteAllBytes($OutFile,[byte[]]::new($state.DownloadBytes))
    if ($state.DownloadFailure) { throw 'Fixture host download failed after writing partial media' }
}
function Invoke-VmCommand {
    param($VmName,$VmDomainName,$VmDomainAccount,$ScriptBlock,$ArgumentList,$DisplayName,
        [switch]$AsJob,$TimeoutSeconds,$SessionMaxRetries,[switch]$FailOnRemoteError)
    if ($VmName -ne 'LAB-EDGE' -or $VmDomainName -ne 'lab.test' -or $VmDomainAccount -ne 'setupadmin' -or
        $DisplayName -ne 'Inspecting Edge for host staging' -or -not $AsJob -or $TimeoutSeconds -ne 60 -or
        $SessionMaxRetries -ne 1 -or -not $FailOnRemoteError) { throw 'The host Edge probe lost its identity/deadline contract.' }
    $state.ProbeCalls++
    if ($state.ProbeMode -eq 'Failure') {
        return [pscustomobject]@{ScriptBlockFailed=$true;ScriptBlockOutput=$null;ErrorDetails='Fixture guest probe failed'}
    }
    $output = @(& $ScriptBlock @ArgumentList)
    if ($state.ProbeArchitecture) { $output[0].Architecture=$state.ProbeArchitecture }
    if ($state.ProbeMode -eq 'Empty') { $output=@() }
    if ($state.ProbeMode -eq 'Ambiguous') { $output += $output[0] }
    [pscustomobject]@{ScriptBlockFailed=$false;ScriptBlockOutput=$output;ErrorDetails=$null}
}
function Get-FileHash { param($LiteralPath,$Algorithm,$ErrorAction); $state.Logs.Add("Hash valid=$($state.HashValid)"); [pscustomobject]@{Hash=$(if($state.HashValid){'A'*64}else{'B'*64})} }
function Get-AuthenticodeSignature {
    param($LiteralPath,$ErrorAction)
    [pscustomobject]@{Status=$(if($state.SignatureValid){'Valid'}else{'NotTrusted'});SignerCertificate=[pscustomobject]@{Subject=$state.SignerSubject}}
}
function Start-Process {
    param($FilePath,$ArgumentList,[switch]$PassThru,$ErrorAction)
    if ($FilePath -notlike '*\System32\msiexec.exe' -or '/qn' -notin $ArgumentList -or '/norestart' -notin $ArgumentList) { throw 'Edge installation stopped being silent/non-restarting.' }
    $repair = 'REINSTALL=ALL' -in $ArgumentList
    if ($repair -ne ('REINSTALLMODE=vomus' -in $ArgumentList)) { throw 'MSI repair properties must be supplied together.' }
    if ($repair -and $state.InstallCalls -eq 0) { throw 'Repair was incorrectly used for the initial MSI installation.' }
    $expectedLogOption = if ($state.InstallCalls -eq 0) { '/L*v' } else { '/L*v+' }
    if ($expectedLogOption -notin $ArgumentList) { throw 'Later MSI attempts would discard the original no-op log.' }
    $index = [math]::Min($state.InstallCalls,$state.ExitCodes.Count-1)
    $state.InstallCalls++
    if ($repair) { $state.RepairCalls++ }
    $state.Calls.Add([pscustomobject]@{ Repair=$repair; LogOption=$expectedLogOption })
    $state.Logs.Add("Start MSI exit=$($state.ExitCodes[$index])")
    $processFixture = $state
    $process = [pscustomobject]@{Id=987654;Handle=[IntPtr]::Zero;ExitCode=$state.ExitCodes[$index];Repair=$repair}
    $process | Add-Member ScriptMethod WaitForExit ({
        param($Milliseconds)
        $processFixture.Logs.Add("Wait=$Milliseconds exit=$($this.ExitCode) update=$($processFixture.UpdateFiles)")
        if ($null -eq $Milliseconds) { return }
        if ($Milliseconds -le 0 -or $Milliseconds -gt 600000) { throw 'MSI wait exceeded its shared installation deadline.' }
        if ($processFixture.Timeout) { return $false }
        if ($this.ExitCode -in @(0,3010)) {
            if ($processFixture.UpdateFiles -and (-not $processFixture.MsiRegistered -or $this.Repair)) {
                if ($processFixture.DelayedVersion) { $processFixture.PendingVersionReads=4 }
                else { $processFixture.Installed=$processFixture.Target }
            }
            $processFixture.MsiRegistered=$true
        }
        $true
    }.GetNewClosure())
    $process | Add-Member ScriptMethod Refresh { }
    $process | Add-Member ScriptMethod Dispose { }
    $process
}
function Stop-Process { param($Id,[switch]$Force,$ErrorAction); if($Id -ne 987654){throw 'Unexpected process termination.'};$state.Stops++ }
function Start-Sleep {
    param($Seconds,$Milliseconds)
    if ($PSBoundParameters.ContainsKey('Milliseconds')) {
        if ($Milliseconds -le 0 -or $Milliseconds -gt 5000) { throw 'Browser verification exceeded its polling interval.' }
        $state.VerificationSleeps++
    }
    elseif ($Seconds -ne 15) { throw 'Unexpected MSI retry interval.' }
}
$metadataFailures = @('WrongProduct','DuplicateStable','MissingArchitecture','InvalidVersion','WrongArtifact','DuplicateArtifact',
    'InsecureOrigin','LookalikeOrigin','UserInfoOrigin','WrongHashAlgorithm','InvalidHash','Oversized','ZeroSize','InvalidSize')
$cases = @('Current','CurrentUpdaterRunning','Old','Uninstalled','Newer','HashFailure','SizeMismatch','SignatureFailure','WrongSigner','MsiFailure','MsiBusy',
    'MsiBusyExhausted','RebootRequired','PendingRebootOldVersion','MsiMissingCode','Timeout','VersionUnchanged',
    'MsiNoOpThenRepair','MsiNoOpBusyRepair','MsiNoOpBudget','DelayedVersion','ConcurrentUpdate',
    'MissingPayload','WrongArchitecture','InvalidPayloadVersion','InvalidPayloadHash','InvalidPayloadBytes','MissingInstaller',
    'PolicyBlocked','ManualOnlyPolicy',
    'ApplicationPolicyOverride','ManagedTarget','StableChannelPolicy','LowercaseHash','MissingUpdater','MissingTasks','ServiceFailure','TaskFailure')
$architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' }
elseif ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
foreach ($case in $cases) {
    $state.Installed='86.0.622.38'; $state.ExitCodes=@(0); $state.UpdateFiles=$true; $state.HashValid=$true
    $state.SignatureValid=$true; $state.MetadataFails=$false; $state.PolicyValues=$null; $state.Timeout=$false
    $state.ServicesPresent=$true; $state.TasksPresent=$true; $state.InstallCalls=0; $state.DownloadCalls=0; $state.Stops=0; $state.ServiceStarts=0; $state.Logs.Clear()
    $state.Target='156.0.0.0'
    $state.MsiRegistered=$false; $state.RepairCalls=0; $state.DelayedVersion=$false
    $state.PendingVersionReads=0; $state.UpdateBeforeRepair=$false; $state.VerificationSleeps=0; $state.Calls.Clear()
    $state.MetadataFault=''; $state.DownloadBytes=64; $state.Temporary=$null; $state.ServiceFailure=$false; $state.TaskFailure=$false
    $state.AllowNetwork=$false; $state.MetadataCalls=0; $state.StagedPresent=$true
    $state.ServiceWrites=0; $state.TaskWrites=0
    $state.SignerSubject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    $state.Services=@([pscustomobject]@{Name='edgeupdate';StartType='Disabled';Status='Stopped'},[pscustomobject]@{Name='edgeupdatem';StartType='Disabled';Status='Stopped'})
    $state.Tasks=@([pscustomobject]@{TaskName='MicrosoftEdgeUpdateTaskMachineUA';TaskPath='\';State='Disabled'})
    switch ($case) {
        Current {$state.Target='156.0.4314.56'; $state.Installed=$state.Target}
        CurrentUpdaterRunning {$state.Installed=$state.Target; $state.Services[0].Status='Running'}
        Uninstalled {$state.Installed=$null}
        Newer {$state.Installed='157.0.0.0'}
        HashFailure {$state.HashValid=$false}
        SizeMismatch {$state.DownloadBytes=65}
        SignatureFailure {$state.SignatureValid=$false}
        WrongSigner {$state.SignerSubject='CN=Fixture, O=Fixture, C=US'}
        MsiFailure {$state.ExitCodes=@(1603)}
        MsiBusy {$state.ExitCodes=@(1618,0)}
        MsiBusyExhausted {$state.ExitCodes=@(1618,1618,1618)}
        RebootRequired {$state.ExitCodes=@(3010)}
        PendingRebootOldVersion {$state.ExitCodes=@(3010); $state.UpdateFiles=$false}
        MsiMissingCode {$state.ExitCodes=@($null)}
        Timeout {$state.Timeout=$true}
        VersionUnchanged {$state.UpdateFiles=$false}
        MsiNoOpThenRepair {
            $state.Target='156.0.4314.58'; $state.Installed='156.0.4314.56'; $state.MsiRegistered=$true
        }
        MsiNoOpBusyRepair {
            $state.Target='156.0.4314.58'; $state.Installed='156.0.4314.56'; $state.MsiRegistered=$true
            $state.ExitCodes=@(0,1618,0)
        }
        MsiNoOpBudget {$state.MsiRegistered=$true; $state.ExitCodes=@(1618,1618,0)}
        DelayedVersion {$state.DelayedVersion=$true}
        ConcurrentUpdate {$state.MsiRegistered=$true; $state.UpdateBeforeRepair=$true}
        MissingInstaller {$state.StagedPresent=$false}
        PolicyBlocked {$state.PolicyValues=[pscustomobject]@{UpdateDefault=0}}
        ManualOnlyPolicy {$state.PolicyValues=[pscustomobject]@{UpdateDefault=2}}
        ApplicationPolicyOverride {$state.PolicyValues=[pscustomobject]@{UpdateDefault=0;'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'=1}}
        ManagedTarget {$state.PolicyValues=[pscustomobject]@{'TargetVersionPrefix{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'='100.'}}
        StableChannelPolicy {$state.PolicyValues=[pscustomobject]@{'TargetChannel{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'='stable'}}
        LowercaseHash {$state.MetadataFault='LowercaseHash'}
        MissingUpdater {$state.ServicesPresent=$false}
        MissingTasks {$state.TasksPresent=$false}
        ServiceFailure {$state.ServiceFailure=$true}
        TaskFailure {$state.TaskFailure=$true}
    }
    $payload = [pscustomobject]@{Version=$state.Target;Architecture=$architecture;Hash=('A'*64);Bytes=64}
    switch ($case) {
        WrongArchitecture {$payload.Architecture='unsupported'}
        InvalidPayloadVersion {$payload.Version='invalid'}
        InvalidPayloadHash {$payload.Hash='invalid'}
        InvalidPayloadBytes {$payload.Bytes=0}
        LowercaseHash {$payload.Hash='a'*64}
    }
    $payloadJson = $payload | ConvertTo-Json -Compress
    if ($case -eq 'MissingPayload') { $payloadJson='' }
    $savedProtocol=[Net.ServicePointManager]::SecurityProtocol
    $output=@(& $body -PayloadJson $payloadJson)
    $success=$case -in @('Old','Uninstalled','Current','CurrentUpdaterRunning','Newer','MsiBusy','RebootRequired',
        'MsiNoOpThenRepair','MsiNoOpBusyRepair','DelayedVersion','ConcurrentUpdate',
        'ApplicationPolicyOverride','StableChannelPolicy','LowercaseHash')
    if ($output.Count -ne 1 -or $output[0].Success -isnot [bool] -or $output[0].Success -ne $success) {
        throw "Edge scenario '$case' returned an incorrect maintenance result: $($output | ConvertTo-Json -Compress); fixture=$($state.Logs -join '; ')"
    }
    if ([Net.ServicePointManager]::SecurityProtocol -ne $savedProtocol) { throw "$case leaked TLS changes." }
    if (-not $success -and (-not $output[0].Message -or @($output[0].Errors).Count -eq 0)) { throw "$case omitted its explicit failure reason." }
    if ($state.Temporary -and [IO.Directory]::Exists($state.Temporary)) { throw "$case leaked its temporary MSI directory." }
    if ($case -in @('HashFailure','SizeMismatch','SignatureFailure','WrongSigner','PolicyBlocked','ManualOnlyPolicy','ManagedTarget',
        'MissingPayload','WrongArchitecture','InvalidPayloadVersion','InvalidPayloadHash','InvalidPayloadBytes','MissingInstaller') -and $state.InstallCalls) { throw "$case executed an unverified MSI." }
    if ($state.DownloadCalls -or $state.MetadataCalls) { throw "$case required guest internet access." }
    if ($case -in @('Current','CurrentUpdaterRunning','Newer') -and ($state.DownloadCalls -or $state.InstallCalls)) { throw "$case needlessly installed or downgraded Edge." }
    if ($success -and $case -notin @('Current','CurrentUpdaterRunning','Newer') -and $state.InstallCalls -lt 1) { throw "$case never installed the selected Stable release." }
    if ($case -eq 'MsiBusy' -and $state.InstallCalls -ne 2) { throw 'MSI busy retry was not bounded/correct.' }
    if ($case -eq 'MsiBusyExhausted' -and $state.InstallCalls -ne 3) { throw 'MSI busy retries did not stop after three attempts.' }
    if ($state.InstallCalls -gt 3) { throw "$case exceeded the shared three-attempt MSI limit." }
    if ($case -eq 'MsiNoOpThenRepair' -and ($state.InstallCalls -ne 2 -or $state.RepairCalls -ne 1 -or
        $state.Installed -ne $state.Target)) { throw 'The registered-MSI no-op was not repaired and independently verified.' }
    if ($case -eq 'MsiNoOpBusyRepair' -and ($state.InstallCalls -ne 3 -or $state.RepairCalls -ne 2)) {
        throw 'A busy repair did not retain repair mode within the shared attempt cap.'
    }
    if ($case -eq 'MsiNoOpBudget' -and ($state.InstallCalls -ne 3 -or $state.RepairCalls -ne 0)) {
        throw 'A late no-op escaped the shared MSI attempt cap.'
    }
    if ($case -eq 'VersionUnchanged' -and ($state.InstallCalls -ne 2 -or $state.RepairCalls -ne 1)) {
        throw 'A non-converging browser was retried indefinitely instead of failing after repair.'
    }
    if ($case -eq 'PendingRebootOldVersion' -and ($state.InstallCalls -ne 1 -or $state.RepairCalls -ne 0 -or
        $output[0].Message -notmatch '3010')) { throw 'An explicit pending-reboot result was repaired or falsely accepted.' }
    if ($case -eq 'DelayedVersion' -and ($state.InstallCalls -ne 1 -or $state.RepairCalls -ne 0 -or
        $state.VerificationSleeps -eq 0)) { throw 'Delayed browser convergence caused unnecessary MSI repair.' }
    if ($case -eq 'ConcurrentUpdate' -and ($state.InstallCalls -ne 1 -or $state.RepairCalls -ne 0 -or
        $state.Installed -ne '157.0.0.0')) { throw 'A concurrent newer browser update was needlessly repaired or downgraded.' }
    if ($case -eq 'Timeout' -and $state.Stops -ne 1) { throw 'Timed-out MSI launcher was not stopped by its owned process ID.' }
    if ($success -and (@($state.Services | Where-Object StartType -eq 'Disabled').Count -or $state.Tasks[0].State -eq 'Disabled')) { throw "$case left Edge Update disabled." }
    if ($success -and ($state.Services[0].StartType -ne 'Automatic' -or $state.Services[1].StartType -ne 'Manual')) { throw "$case did not restore normal updater service startup." }
    if ($state.ServiceStarts -ne 0) { throw "$case forced an on-demand updater service to start." }
    if ($success) {
        $expectedStatus = if ($case -eq 'CurrentUpdaterRunning') { 'Running' } else { 'Stopped' }
        if ($state.Services[0].Status -ne $expectedStatus) { throw "$case changed the updater's running state." }
    }
    if ($case -eq 'MissingInstaller' -and ($state.Services[0].StartType -eq 'Disabled' -or $state.Tasks[0].State -eq 'Disabled')) { throw 'Missing staged media left updates permanently disabled.' }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-edge-staging-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($testRoot)
$savedCommon = $global:Common
try {
    $hostCases = @('Old','Current','Newer','Uninstalled','CacheReuse','CacheCorrupt','CachedSignatureFailure',
        'X86','Arm64','LowercaseHash','MetadataOffline','HashFailure','SizeMismatch','SignatureFailure','WrongSigner',
        'DownloadFailure','ProbeFailure','ProbeEmpty','ProbeAmbiguous','ProbeArchitecture','ProbeVersion') + $metadataFailures
    foreach ($case in $hostCases) {
        $state.Installed='86.0.622.38'; $state.Target='156.0.0.0'; $state.AllowNetwork=$true
        $state.MetadataFails=$false; $state.MetadataFault=''; $state.MetadataCalls=0; $state.DownloadCalls=0
        $state.HashValid=$true; $state.SignatureValid=$true; $state.DownloadBytes=64; $state.DownloadFailure=$false
        $state.SignerSubject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
        $state.ProbeMode=''; $state.ProbeArchitecture=''; $state.ProbeCalls=0; $state.PendingVersionReads=0
        $state.ServiceWrites=0; $state.TaskWrites=0; $state.InstallCalls=0; $state.Logs.Clear()
        $directory = Join-Path $testRoot $case
        $global:Common = [pscustomobject]@{StagingInjectPath=$directory}
        $definition = [pscustomobject]@{ScriptBlock=$body;RunAsAccount='setupadmin';InjectFiles=@();ArgumentList=@()}
        switch ($case) {
            Current {$state.Installed=$state.Target}
            Newer {$state.Installed='157.0.0.0'}
            Uninstalled {$state.Installed=$null}
            X86 {$state.ProbeArchitecture='x86'}
            Arm64 {$state.ProbeArchitecture='arm64'}
            LowercaseHash {$state.MetadataFault='LowercaseHash'}
            MetadataOffline {$state.MetadataFails=$true}
            HashFailure {$state.HashValid=$false}
            SizeMismatch {$state.DownloadBytes=65}
            SignatureFailure {$state.SignatureValid=$false}
            CachedSignatureFailure {$state.SignatureValid=$false}
            WrongSigner {$state.SignerSubject='CN=Fixture, O=Fixture, C=US'}
            DownloadFailure {$state.DownloadFailure=$true}
            ProbeFailure {$state.ProbeMode='Failure'}
            ProbeEmpty {$state.ProbeMode='Empty'}
            ProbeAmbiguous {$state.ProbeMode='Ambiguous'}
            ProbeArchitecture {$state.ProbeArchitecture='unsupported'}
            ProbeVersion {$state.Installed='invalid'}
        }
        if ($case -in $metadataFailures) { $state.MetadataFault=$case }
        if ($case -in @('CacheCorrupt','CachedSignatureFailure')) {
            $cacheDirectory = Join-Path $directory 'staging'
            $null = [IO.Directory]::CreateDirectory($cacheDirectory)
            $length = if ($case -eq 'CacheCorrupt') { 65 } else { 64 }
            [IO.File]::WriteAllBytes((Join-Path $cacheDirectory "MemLabs-Edge-$($state.Target)-$architecture.msi"), [byte[]]::new($length))
        }
        $failure = $null
        $output = @()
        try {
            $output = @(& $preparation -VMName 'LAB-EDGE' -VMDomain 'lab.test' -VMFix $definition)
            if ($case -eq 'CacheReuse') {
                $output += @(& $preparation -VMName 'LAB-EDGE' -VMDomain 'lab.test' -VMFix $definition)
            }
        }
        catch { $failure=$_.Exception.Message }
        $success = $case -in @('Old','Current','Newer','Uninstalled','CacheReuse','CacheCorrupt','X86','Arm64','LowercaseHash')
        if ($success -ne (-not $failure) -or $output.Count) { throw "Host Edge scenario '$case' returned an incorrect preparation result: $failure" }
        if ($state.InstallCalls -or $state.ServiceWrites -or $state.TaskWrites) { throw "$case modified guest software/updaters during host preparation." }
        if (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.download.msi' -Recurse -File).Count) { throw "$case leaked a partial host download." }
        if (-not $success -and ($definition.InjectFiles.Count -or $definition.ArgumentList.Count)) { throw "$case exposed unverified Edge media or arguments." }
        if (($case -in $metadataFailures -or $case -like 'Probe*' -or $case -eq 'MetadataOffline') -and $state.DownloadCalls) { throw "$case downloaded unapproved Edge media." }
        if ($case -like 'Probe*' -and $state.MetadataCalls) { throw "$case queried Microsoft before validating the guest probe." }
        if (-not $success) { continue }
        if ($definition.ArgumentList.Count -ne 1) { throw "$case omitted the serialized guest metadata." }
        $selected = $definition.ArgumentList[0] | ConvertFrom-Json
        $expectedArchitecture = if ($state.ProbeArchitecture) { $state.ProbeArchitecture } else { $architecture }
        if ($selected.Version -ne $state.Target -or $selected.Architecture -ne $expectedArchitecture) { throw "$case selected the wrong Stable version/architecture." }
        if ($case -in @('Current','Newer')) {
            if ($state.DownloadCalls -or $definition.InjectFiles.Count) { throw "$case downloaded/transferred an unnecessary MSI." }
        }
        else {
            if ($state.DownloadCalls -ne 1 -or $definition.InjectFiles.Count -ne 1 -or
                -not [IO.File]::Exists((Join-Path $directory "staging\$($definition.InjectFiles[0])"))) { throw "$case did not stage exactly one reusable MSI." }
        }
        if ($case -eq 'CacheReuse' -and $state.ProbeCalls -ne 2) { throw 'Cache reuse skipped guest-state validation.' }
        if ($case -eq 'CacheCorrupt' -and ($state.Logs -join "`n") -notmatch 'Cached Edge MSI failed') { throw 'Corrupt host media was refreshed without an explicit diagnostic.' }
    }

    $parallelDirectory = Join-Path $testRoot 'parallel'
    $null = [IO.Directory]::CreateDirectory($parallelDirectory)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $parallelHash = [BitConverter]::ToString($hasher.ComputeHash([byte[]]::new(64))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $worker = {
        param($RootPath, $Directory, $Hash, $Architecture, $Name)
        $ErrorActionPreference = 'Stop'
        $fixesToPerform = @()
        . (Join-Path $RootPath 'Fixes\Fix-EdgeServicing.ps1')
        $global:Common = [pscustomobject]@{StagingInjectPath=$Directory}
        $fixture = @{Directory=$Directory;Hash=$Hash;Architecture=$Architecture;Name=$Name}
        function Write-Log { param($Message,[switch]$Warning,[switch]$LogOnly) }
        function Invoke-VmCommand {
            param($VmName,$VmDomainName,$ScriptBlock,$ArgumentList,$DisplayName,
                [switch]$AsJob,$TimeoutSeconds,$SessionMaxRetries,[switch]$FailOnRemoteError)
            [IO.File]::WriteAllText((Join-Path $fixture.Directory "$($fixture.Name).ready"), 'ready')
            [pscustomobject]@{
                ScriptBlockFailed=$false; ErrorDetails=$null
                ScriptBlockOutput=[pscustomobject]@{Architecture=$fixture.Architecture;Version='86.0.622.38'}
            }
        }
        function Invoke-RestMethod {
            param($Uri,$TimeoutSec,$ErrorAction)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not ([IO.File]::Exists((Join-Path $fixture.Directory 'first.ready')) -and
                    [IO.File]::Exists((Join-Path $fixture.Directory 'second.ready')))) {
                if ($clock.Elapsed.TotalSeconds -gt 15) { throw 'Concurrent cache workers did not meet at the staging barrier.' }
                Start-Sleep -Milliseconds 50
            }
            [pscustomobject]@{Product='Stable';Releases=@(
                [pscustomobject]@{Platform='Windows';Architecture=$fixture.Architecture;ProductVersion='156.0.0.0';Artifacts=@(
                    [pscustomobject]@{
                        ArtifactName='msi';Location='https://msedge.sf.dl.delivery.mp.microsoft.com/fixture/edge.msi'
                        HashAlgorithm='SHA256';Hash=$fixture.Hash;SizeInBytes=64
                    }
                )}
            )}
        }
        function Invoke-WebRequest {
            param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction)
            [IO.File]::AppendAllText((Join-Path $fixture.Directory 'downloads.txt'), "download`r`n")
            Start-Sleep -Milliseconds 500
            [IO.File]::WriteAllBytes($OutFile,[byte[]]::new(64))
        }
        function Get-AuthenticodeSignature {
            param($LiteralPath,$ErrorAction)
            if ([IO.Path]::GetExtension($LiteralPath) -ne '.msi') { throw 'Staged media lost its MSI extension before signature verification.' }
            [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}}
        }
        $definition = $fixesToPerform[0]
        & $definition.PrepareScriptBlock -VMName $Name -VMDomain 'lab.test' -VMFix $definition
        [pscustomobject]@{Name=$Name;Files=@($definition.InjectFiles);Arguments=@($definition.ArgumentList)}
    }
    $jobs = @()
    try {
        foreach ($name in @('first','second')) {
            $jobs += Start-Job -ScriptBlock $worker -ArgumentList $RootPath,$parallelDirectory,$parallelHash,$architecture,$name
        }
        $null = Wait-Job -Job $jobs -Timeout 45
        if (@($jobs | Where-Object State -ne 'Completed').Count) { throw 'Concurrent host Edge staging failed or exceeded its test deadline.' }
        $results = @($jobs | Receive-Job -ErrorAction Stop)
        if ($results.Count -ne 2 -or @($results | Where-Object { $_.Files.Count -ne 1 -or $_.Arguments.Count -ne 1 }).Count -or
            [IO.File]::ReadAllLines((Join-Path $parallelDirectory 'downloads.txt')).Count -ne 1) {
            throw 'Concurrent maintenance workers did not share exactly one verified Edge download.'
        }
    }
    finally {
        foreach ($job in $jobs) {
            if ($job.State -in @('Running','NotStarted','Blocked')) { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
    }
}
finally {
    $global:Common = $savedCommon
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS -- Host-cached Edge staging, zero guest internet requests, integrity, idle updaters, bounded MSI repair, no downgrade and explicit failures.'
