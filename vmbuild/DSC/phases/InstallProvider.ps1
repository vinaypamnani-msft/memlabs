#InstallProvider.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# Announce the workload up front. Without this the no-op path (no VM flagged
# InstallSMSProv, i.e. every re-run of a config that has no additional provider)
# emitted ZERO lines, so "job ran and did nothing in 0.4s" was indistinguishable
# from "job never started" or "job hung" in ConfigMgrSetup.log.
$installProvStart = Get-Date
$provList = @($deployConfig.virtualMachines | Where-Object { $_.InstallSMSProv -eq $true })
if ($provList.Count -eq 0) {
    Write-DscStatus "[InstallProv] Nothing to do: no VM in this config has InstallSMSProv=true"
    return
}
Write-DscStatus "[InstallProv] Starting: $($provList.Count) VM(s) flagged InstallSMSProv ($(($provList.vmName) -join ', '))"

# Providers we tried and could not prove are installed. A killed/failed setupwpf used to fall
# straight through to "setupWPF has completed" + "Finished", so Phase 8 went green while root\SMS
# never existed on the target and only Phase 11 (hours later) noticed.
$failedProviders = [System.Collections.Generic.List[string]]::new()

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","

# Resolve per-VM cmOptions (multi-hierarchy safe).
$cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
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

$setupWPF = Join-Path $path "bin\X64\setupwpf.exe"

if (-not (Test-Path $setupWPF)) {
    Write-DscStatus "[InstallProv] Could not find $setupWPF" -Failure
    return $false
}

foreach ($prov in $provList) {
    $machine = "$($prov.VMname).$DomainFullName"
    Write-DscStatus "[InstallProv] Installing provider on $machine"
    $Install = $true
    $thisSiteCode = $thisVM.SiteCode
    if ($prov.SiteCode -ne $thisSiteCode) {
        #If this is the remote SQL Server for this site code, don't continue
        if ($prov.vmName -ne $thisVM.RemoteSQLVM) {
            continue
        }
    }    

    $providers = Get-CimInstance -class "SMS_ProviderLocation" -Namespace "root\SMS"
    foreach ($provider in $providers) {
         #Add a dot to match FQDN Machines
        if ($provider.Machine.ToLowerInvariant() -eq $machine.ToLowerInvariant() ) {
            Write-DscStatus "Found Provider: $($provider.Machine) with Namespace $($provider.NamespacePath). Skipping."
            $Install = $false
            break
        }
    }

    if ($Install) {
        # Bounded wait for any leftover setupwpf from a prior pass to finish, then kill the stale instance
        # if it's wedged -- the old loop had NO cap and could spin forever on a stuck prior run.
        $preWaited = 0
        $preCap = 600   # 10 min
        $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        while ($running) {
            if ($preWaited -ge $preCap) {
                Write-DscStatus "[InstallProv] setupWPF still running after $preCap s -- killing the stale instance so we can proceed"
                foreach ($p in $running) { try { $p.Kill() } catch { } }
                Start-Sleep -Seconds 5
                break
            }
            Write-DscStatus "[InstallProv] setupWPF is already running.. Waiting for it to stop"
            start-sleep -seconds 60
            $preWaited += 60
            $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        }

        Write-DscStatus "[InstallProv] Running & $setupWPF /HIDDEN /SDKINST $machine"
        # /SDKINST modifies the site, so setup first does a full StopServices() cycle. On a CAS+Primary
        # hierarchy that shutdown took 34 min and wrote NOTHING to ConfigMgrSetup.log while it ran, so
        # the old 30-min cap killed setup ~5 min short and left the site mid-shutdown.
        $installCap = 5400   # 90 min
        $proc = $null
        $installFailed = $false
        try {
            $proc = Start-Process -FilePath $setupWPF -ArgumentList @('/HIDDEN', '/SDKINST', $machine) -PassThru -WindowStyle Hidden -ErrorAction Stop
        }
        catch {
            Write-DscStatus "[InstallProv] Failed to start setupWPF: $($_.Exception.Message)" -Failure
            $installFailed = $true
        }

        if ($proc) {
            # Heartbeat rather than one blind WaitForExit: setup is silent for half an hour inside
            # StopServices(), so the site service state is the only liveness signal available -- and a
            # moving status keeps the host from reading this as a frozen LCM.
            $waited = 0
            $beat = 300
            while ($waited -lt $installCap -and -not $proc.WaitForExit($beat * 1000)) {
                $waited += $beat
                $exeState = (Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue).Status
                Write-DscStatus "[InstallProv] setupWPF running $([int]($waited / 60))m of $([int]($installCap / 60))m on $machine (SMS_EXECUTIVE=$exeState) -- /SDKINST stops and restarts the site, this is expected to be slow"
            }

            if (-not $proc.HasExited) {
                # Killing here leaves the site mid-maintenance; the rest of Phase 8 then runs against it.
                Write-DscStatus "[InstallProv] setupWPF did not finish within $installCap s on $machine -- killing it. The provider is NOT installed and the site may be left mid-maintenance (services stopped); see ConfigMgrSetup.log" -Failure
                try { $proc.Kill() } catch { }
                Get-Process "setupwpf" -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
                $installFailed = $true
            }
        }

        # Belt-and-braces: bounded wait for any lingering setupwpf to clear (was an unbounded loop).
        $postWaited = 0
        $postCap = 300   # 5 min
        $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        while ($running) {
            if ($postWaited -ge $postCap) {
                Write-DscStatus "[InstallProv] setupWPF lingering after $postCap s -- killing it"
                foreach ($p in $running) { try { $p.Kill() } catch { } }
                break
            }
            Write-DscStatus "[InstallProv] setupWPF is running to install the provider on $machine. Please Wait"
            start-sleep -seconds 60
            $postWaited += 60
            $running = Get-Process "setupwpf" -ErrorAction SilentlyContinue
        }

        if ($installFailed) {
            $failedProviders.Add($machine)
            continue
        }

        # setupwpf exiting 0 is not proof the provider registered. Confirm it landed in
        # SMS_ProviderLocation before calling this VM done -- the SMS Provider host is recycling
        # right after /SDKINST, so give the query a few tries.
        $verified = $false
        for ($v = 1; $v -le 10; $v++) {
            try {
                $verified = [bool](Get-CimInstance -Class "SMS_ProviderLocation" -Namespace "root\SMS" -ErrorAction Stop |
                        Where-Object { $_.Machine -and $_.Machine.ToLowerInvariant() -eq $machine.ToLowerInvariant() })
            }
            catch {
                $verified = $false
            }
            if ($verified) { break }
            if ($v -lt 10) { Start-Sleep -Seconds 30 }
        }

        if ($verified) {
            Write-DscStatus "[InstallProv] setupWPF has completed; $machine is registered in SMS_ProviderLocation"
        }
        else {
            Write-DscStatus "[InstallProv] setupWPF exited but $machine never appeared in SMS_ProviderLocation -- provider install did not take"
            $failedProviders.Add($machine)
        }
    }

}

$installProvElapsed = [math]::Round(((Get-Date) - $installProvStart).TotalSeconds, 1)
if ($failedProviders.Count -gt 0) {
    # Throw rather than write another JOBFAILURE status: the host breaks Phase 8 the instant it polls
    # one, so a second status here would make "does Phase 8 fail?" a poll-timing coin flip. The throw
    # reaches ScriptWorkFlow's join, which logs it deterministically.
    $msg = "[InstallProv] FAILED on $($failedProviders.Count) of $($provList.Count) provider VM(s): $($failedProviders -join ', '). root\SMS will not exist there, so Phase 11 SMSProv will fail. Elapsed $($installProvElapsed)s"
    Write-DscStatus $msg
    throw $msg
}

Write-DscStatus "[InstallProv] Finished: $($provList.Count) provider VM(s) in $($installProvElapsed)s"

