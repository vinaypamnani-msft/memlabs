#InstallProvider.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$DomainName = $DomainFullName.Split(".")[0]
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","

$usePKI = $deployConfig.cmOptions.UsePKI
if (-not $usePKI) {
    $usePKI = $false
}
# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# E:\ConfigMgr
$path = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'
if (-not $path) {
    $path = "E:\ConfigMgr"
}

if (-not (Test-Path $setupWPF)) {
    Write-DscStatus "[InstallProv] Could not find $setupWPF" -Failure
    return $false
}

foreach ($prov in $deployConfig.virtualMachines | Where-Object { $_.InstallSMSProv -eq $true } ) {

    $Install = $true
    $thisSiteCode = $thisVM.SiteCode
    if ($prov.SiteCode -ne $thisSiteCode) {
        #If this is the remote SQL Server for this site code, dont continue
        if ($prov.vmName -ne $thisVM.RemoteSQLVM) {
            continue
        }
    }    

    $providers = Get-WmiObject -class "SMS_ProviderLocation" -Namespace "root\SMS"
    foreach ($provider in $providers) {
        $vmName = "$($prov.VmName).".ToLowerInvariant() #Add a dot to match FQDN Machines
        if ($provider.Machine.ToLowerInvariant().StartsWith($vmName)) {
            Write-DscStatus "Found Provider: $($provider.Machine) with Namespace $($provider.NamespacePath). Skipping."
            $Install = $false
            break
        }
    }

    if ($Install) {
        $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        while ($running) {
            Write-DscStatus "[InstallProv] setupWPF is already running.. Waiting for it to stop"
            start-sleep -seconds 60
            $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        }
        $machine = "$($prov.VMname).$DomainFullName"
        & $setupWPF /HIDDEN /SDKINST $machine
        $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        while ($running) {
            Write-DscStatus "[InstallProv] setupWPF is running to install the provider. Please Wait"
            start-sleep -seconds 60
            $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        }
        Write-DscStatus "[InstallProv] setupWPF has completed"
    }

}

