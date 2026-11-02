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
    $fixesToPerform[0].FixVersion -ne '261102.0') { throw 'Edge servicing registration lost its version/late/fresh/existing/offline-root contract.' }
$body = $fixesToPerform[0].ScriptBlock
$state = [pscustomobject]@{
    Installed='86.0.622.38'; Target='156.0.0.0'; ExitCodes=@(0); UpdateFiles=$true
    HashValid=$true; SignatureValid=$true; MetadataFails=$false; MetadataFault=''; PolicyValues=$null; Timeout=$false
    ServicesPresent=$true; TasksPresent=$true; InstallCalls=0; DownloadCalls=0; Stops=0; ServiceStarts=0
    DownloadBytes=64; Temporary=$null; ServiceFailure=$false; TaskFailure=$false
    MsiRegistered=$false; RepairCalls=0; DelayedVersion=$false; PendingVersionReads=0; UpdateBeforeRepair=$false
    SignerSubject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    Services=@(); Tasks=@(); Logs=[Collections.Generic.List[string]]::new()
    Calls=[Collections.Generic.List[object]]::new(); VerificationSleeps=0
}
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
    if ($state.TaskFailure) { throw 'Fixture task change denied' }
    foreach ($task in $state.Tasks | Where-Object TaskName -eq $TaskName) { $task.State='Ready' }
}
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$ErrorAction)
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
    if ($Uri -notlike 'https://msedge.sf.dl.delivery.mp.microsoft.com/*' -or -not $UseBasicParsing -or $TimeoutSec -ne 180) { throw 'Edge download source or bounded streaming changed.' }
    $state.DownloadCalls++
    $state.Temporary = [IO.Path]::GetDirectoryName($OutFile)
    [IO.File]::WriteAllBytes($OutFile,[byte[]]::new($state.DownloadBytes))
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
    'MetadataOffline','PolicyBlocked','ManualOnlyPolicy',
    'ApplicationPolicyOverride','ManagedTarget','StableChannelPolicy','LowercaseHash','MissingUpdater','MissingTasks','ServiceFailure','TaskFailure') + $metadataFailures
foreach ($case in $cases) {
    $state.Installed='86.0.622.38'; $state.ExitCodes=@(0); $state.UpdateFiles=$true; $state.HashValid=$true
    $state.SignatureValid=$true; $state.MetadataFails=$false; $state.PolicyValues=$null; $state.Timeout=$false
    $state.ServicesPresent=$true; $state.TasksPresent=$true; $state.InstallCalls=0; $state.DownloadCalls=0; $state.Stops=0; $state.ServiceStarts=0; $state.Logs.Clear()
    $state.Target='156.0.0.0'
    $state.MsiRegistered=$false; $state.RepairCalls=0; $state.DelayedVersion=$false
    $state.PendingVersionReads=0; $state.UpdateBeforeRepair=$false; $state.VerificationSleeps=0; $state.Calls.Clear()
    $state.MetadataFault=''; $state.DownloadBytes=64; $state.Temporary=$null; $state.ServiceFailure=$false; $state.TaskFailure=$false
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
        MetadataOffline {$state.MetadataFails=$true}
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
    if ($case -in $metadataFailures) { $state.MetadataFault=$case }
    $savedProtocol=[Net.ServicePointManager]::SecurityProtocol
    $output=@(& $body)
    $success=$case -in @('Old','Uninstalled','Current','CurrentUpdaterRunning','Newer','MsiBusy','RebootRequired',
        'MsiNoOpThenRepair','MsiNoOpBusyRepair','DelayedVersion','ConcurrentUpdate',
        'ApplicationPolicyOverride','StableChannelPolicy','LowercaseHash')
    if ($output.Count -ne 1 -or $output[0].Success -isnot [bool] -or $output[0].Success -ne $success) {
        throw "Edge scenario '$case' returned an incorrect maintenance result: $($output | ConvertTo-Json -Compress); fixture=$($state.Logs -join '; ')"
    }
    if ([Net.ServicePointManager]::SecurityProtocol -ne $savedProtocol) { throw "$case leaked TLS changes." }
    if (-not $success -and (-not $output[0].Message -or @($output[0].Errors).Count -eq 0)) { throw "$case omitted its explicit failure reason." }
    if ($state.Temporary -and [IO.Directory]::Exists($state.Temporary)) { throw "$case leaked its temporary MSI directory." }
    if ($case -in (@('HashFailure','SizeMismatch','SignatureFailure','WrongSigner','PolicyBlocked','ManualOnlyPolicy','ManagedTarget','MetadataOffline') + $metadataFailures) -and $state.InstallCalls) { throw "$case executed an unverified MSI." }
    if ($case -in $metadataFailures -and $state.DownloadCalls) { throw "$case downloaded an unapproved artifact." }
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
    if ($case -eq 'MetadataOffline' -and ($state.Services[0].StartType -eq 'Disabled' -or $state.Tasks[0].State -eq 'Disabled')) { throw 'An unavailable download left updates permanently disabled.' }
}
Write-Host 'PASS -- Edge Stable integrity, idle updaters, delayed convergence, bounded MSI no-op repair, no downgrade and explicit failure semantics.'
