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

function Get-SiteServiceSummary {
    $parts = @()
    foreach ($n in 'SMS_SITE_COMPONENT_MANAGER', 'SMS_EXECUTIVE') {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        $short = $n -replace '^SMS_', ''
        if ($svc) { $parts += "$short=$($svc.Status)" } else { $parts += "$short=absent" }
    }
    return ($parts -join ' ')
}

function Get-SitecompProgress {
    # sitecomp is what actually performs the shutdown setup is waiting on, so its log -- not
    # ConfigMgrSetup.log -- is the only place that shows which component is holding things up.
    param([string] $InstallDir)

    $log = Join-Path $InstallDir 'Logs\sitecomp.log'
    if (-not (Test-Path $log)) { return 'sitecomp.log not found' }

    $item = Get-Item -LiteralPath $log -ErrorAction SilentlyContinue
    if (-not $item) { return 'sitecomp.log unreadable' }

    $idleMin = [math]::Round(((Get-Date) - $item.LastWriteTime).TotalMinutes, 1)
    $tail = ''
    try {
        $line = @(Get-Content -LiteralPath $log -Tail 1 -ErrorAction Stop)[0]
        if ($line) {
            $m = [regex]::Match($line, '\<!\[LOG\[(?<body>.*?)\]LOG\]')
            if ($m.Success) { $tail = $m.Groups['body'].Value } else { $tail = $line }
            $tail = ($tail -replace '\s+', ' ').Trim()
            if ($tail.Length -gt 140) { $tail = $tail.Substring(0, 140) + '...' }
        }
    }
    catch { $tail = "(tail failed: $($_.Exception.Message))" }

    return "sitecomp idle ${idleMin}m last='$tail'"
}

function Test-ProviderTargetReady {
    # Setup reaches the target with the WMI registry provider (CWmiRegistry::WmiOpen) and SMB.
    # Check the same things up front so a dead target fails here instead of 30 min into a site
    # shutdown. Deliberately NOT RemoteRegistry -- setup does not use it.
    param([string] $Fqdn)

    $problems = [System.Collections.Generic.List[string]]::new()

    try {
        $null = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $Fqdn -OperationTimeoutSec 60 -ErrorAction Stop
    }
    catch {
        $problems.Add("WMI root\cimv2 unreachable: $($_.Exception.Message)")
    }

    try {
        $hklm = [uint32]2147483650
        $r = Invoke-CimMethod -Namespace 'root\default' -ClassName 'StdRegProv' -MethodName 'EnumKey' `
            -Arguments @{ hDefKey = $hklm; sSubKeyName = 'SOFTWARE\Microsoft' } `
            -ComputerName $Fqdn -OperationTimeoutSec 60 -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { $problems.Add("WMI registry provider EnumKey returned $($r.ReturnValue)") }
    }
    catch {
        $problems.Add("WMI registry provider unreachable: $($_.Exception.Message)")
    }

    $adminShare = '\\' + $Fqdn + '\admin$'
    if (-not (Test-Path -LiteralPath $adminShare -ErrorAction SilentlyContinue)) {
        $problems.Add('admin$ share not reachable')
    }

    # InstallSDK verifies Deployment Tools + WinPE on the TARGET and fails with
    # CONFIGMGR_ERROR_PREREQ_ADK if either is missing -- but only after the site is already down.
    $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    foreach ($feature in @('Deployment Tools', 'Windows Preinstallation Environment')) {
        $remote = '\\' + $Fqdn + '\C$\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\' + $feature
        if (-not (Test-Path -LiteralPath $remote -ErrorAction SilentlyContinue)) {
            $problems.Add("ADK '$feature' missing on the target ($adkRoot\$feature)")
        }
    }

    return $problems
}

function Restore-SiteServices {
    # A killed setupwpf leaves the site mid-maintenance. Everything after this in Phase 8
    # (client push, EnableBLM, collection re-eval) needs a running site, and so does a retry.
    param([int] $TimeoutSeconds = 900)

    Write-DscStatus "[InstallProv] Restoring site services after a failed provider install ($(Get-SiteServiceSummary))"
    foreach ($n in 'SMS_SITE_COMPONENT_MANAGER', 'SMS_EXECUTIVE') {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -ne 'Running') {
            try { Start-Service -Name $n -ErrorAction Stop }
            catch { Write-DscStatus "[InstallProv] Could not start ${n}: $($_.Exception.Message)" }
        }
    }

    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        $exe = Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue
        $scm = Get-Service -Name 'SMS_SITE_COMPONENT_MANAGER' -ErrorAction SilentlyContinue
        if ($exe -and $exe.Status -eq 'Running' -and $scm -and $scm.Status -eq 'Running') {
            Write-DscStatus "[InstallProv] Site services healthy again after $($waited)s ($(Get-SiteServiceSummary))"
            return $true
        }
        Start-Sleep -Seconds 30
        $waited += 30
        if ($waited % 300 -eq 0) {
            Write-DscStatus "[InstallProv] Waiting for site services to come back ($($waited)s of $TimeoutSeconds s; $(Get-SiteServiceSummary))"
        }
    }

    Write-DscStatus "[InstallProv] Site services still not Running after $TimeoutSeconds s ($(Get-SiteServiceSummary))"
    return $false
}

# setupwpf is interactive BY DESIGN for /SDKINST and there is no switch that changes that.
# CommandLineParser.cpp only honours /NOUSERINPUT with /PREREQ, /TESTDBUPGRADE, /UPGRADE,
# /DEINSTALL, /SCRIPT or a secondary install, and ParseSetupAction has no site-maintenance
# action, so /SCRIPT cannot express "add a provider" either. bNoUserInput is therefore always
# FALSE here, which leaves at least two reachable modal dialogs: the MB_ABORTRETRYIGNORE that
# sutils.cpp raises when Site Component Manager reports a shutdown error twice, and
# ConfirmWhetherToContinue() on a MOF update failure in instsite.cpp. Nothing on a session-0
# desktop will ever click either one.
$promptApiReady = $false
try {
    if (-not ('MemLabs.SetupPrompt' -as [type])) {
        Add-Type -Namespace 'MemLabs' -Name 'SetupPrompt' -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll")]
public static extern IntPtr GetDesktopWindow();

[DllImport("user32.dll")]
public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

[DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int GetDlgItemText(IntPtr hDlg, int nIDDlgItem, System.Text.StringBuilder lpString, int nMaxCount);

[DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
'@
    }
    $promptApiReady = $true
}
catch {
    Write-DscStatus "[InstallProv] Could not load the window API ($($_.Exception.Message)) -- a setup prompt can be reported but not answered, and would hang the install"
}

function Resolve-SetupPrompt {
    # Answers IGNORE, which is exactly what setup's own non-interactive branch picks for a
    # primary site (secondary sites get ABORT). Returns a description of what it dismissed;
    # the dialog body names the component that would not stop, so it is worth logging.
    # Walks the desktop rather than using FindWindowEx: PowerShell marshals a $null class name
    # as an empty string, so FindWindowEx just fails with Win32 123 ERROR_INVALID_NAME.
    param([int] $ProcessId)

    if (-not $promptApiReady) { return $null }

    $answered = New-Object System.Collections.Generic.List[string]
    $cls = New-Object System.Text.StringBuilder 256
    $h = [MemLabs.SetupPrompt]::GetWindow([MemLabs.SetupPrompt]::GetDesktopWindow(), 5)   # GW_CHILD

    while ($h -ne [IntPtr]::Zero) {
        $owner = [uint32]0
        [void][MemLabs.SetupPrompt]::GetWindowThreadProcessId($h, [ref]$owner)

        if ($owner -eq $ProcessId) {
            [void]$cls.Clear()
            [void][MemLabs.SetupPrompt]::GetClassName($h, $cls, $cls.Capacity)
            if ($cls.ToString() -eq '#32770') {
                $cap = New-Object System.Text.StringBuilder 512
                [void][MemLabs.SetupPrompt]::GetWindowText($h, $cap, $cap.Capacity)
                # 0xFFFF is the static control a MessageBox puts its body text in.
                $body = New-Object System.Text.StringBuilder 2048
                [void][MemLabs.SetupPrompt]::GetDlgItemText($h, 0xFFFF, $body, $body.Capacity)

                $text = ($body.ToString() -replace '\s+', ' ').Trim()
                if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }

                [void][MemLabs.SetupPrompt]::PostMessage($h, 0x0111, [IntPtr]5, [IntPtr]::Zero)   # WM_COMMAND, IDIGNORE
                $answered.Add("caption='$($cap.ToString().Trim())' text='$text'")
            }
        }

        $h = [MemLabs.SetupPrompt]::GetWindow($h, 2)   # GW_HWNDNEXT
    }

    if ($answered.Count -eq 0) { return $null }
    return ($answered -join ' | ')
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
        # Setup drives the target over WMI (CWmiRegistry) and SMB, and InstallSDK additionally
        # requires the ADK on the TARGET. Check up front so a bad target fails here instead of
        # after the site has already been shut down.
        $preflight = Test-ProviderTargetReady -Fqdn $machine
        if ($preflight.Count -gt 0) {
            Write-DscStatus "[InstallProv] $machine is not ready for a provider install: $($preflight -join '; '). Not starting setupWPF -- it would stop the site first and only then fail."
            $failedProviders.Add($machine)
            continue
        }
        Write-DscStatus "[InstallProv] Pre-flight OK for $machine (WMI, registry provider, admin share, ADK)"

        $maxAttempts = 2
        $installed = $false

        for ($attempt = 1; $attempt -le $maxAttempts -and -not $installed; $attempt++) {

            # Bounded wait for any leftover setupwpf from a prior pass to finish, then kill the stale
            # instance if it's wedged -- the old loop had NO cap and could spin forever.
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

            Write-DscStatus "[InstallProv] Attempt $attempt of ${maxAttempts}: & $setupWPF /HIDDEN /SDKINST $machine ($(Get-SiteServiceSummary))"
            $installCap = 3600   # 60 min
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
                # Poll fast enough to clear a modal prompt quickly, but only report every 5 min.
                # Setup writes NOTHING to ConfigMgrSetup.log while it waits on the site shutdown, so
                # sitecomp's log and the service states are the only progress signals there are.
                $waited = 0
                $poll = 15
                $beat = 300
                $sinceBeat = 0
                $promptsAnswered = 0

                while ($waited -lt $installCap -and -not $proc.WaitForExit($poll * 1000)) {
                    $waited += $poll
                    $sinceBeat += $poll

                    $prompt = Resolve-SetupPrompt -ProcessId $proc.Id
                    if ($prompt) {
                        $promptsAnswered++
                        Write-DscStatus "[InstallProv] setupWPF raised a modal prompt that nothing could ever click -- answered IGNORE (#$promptsAnswered). $prompt"
                    }

                    if ($sinceBeat -ge $beat) {
                        $sinceBeat = 0
                        Write-DscStatus "[InstallProv] setupWPF $([int]($waited / 60))m of $([int]($installCap / 60))m on $machine; $(Get-SiteServiceSummary); $(Get-SitecompProgress -InstallDir $path); prompts answered=$promptsAnswered"
                    }
                }

                if (-not $proc.HasExited) {
                    Write-DscStatus "[InstallProv] setupWPF did not finish within $installCap s on $machine -- killing it. Provider NOT installed and the site may be left mid-maintenance; $(Get-SitecompProgress -InstallDir $path)" -Failure
                    try { $proc.Kill() } catch { }
                    Get-Process "setupwpf" -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
                    $installFailed = $true
                }
                elseif ($promptsAnswered -gt 0) {
                    Write-DscStatus "[InstallProv] setupWPF exited after $([int]($waited / 60))m with $promptsAnswered prompt(s) answered"
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

            if (-not $installFailed) {
                # setupwpf exiting is not proof the provider registered. The SMS Provider host is
                # recycling right after /SDKINST, so give the query a few tries.
                for ($v = 1; $v -le 10; $v++) {
                    try {
                        $installed = [bool](Get-CimInstance -Class "SMS_ProviderLocation" -Namespace "root\SMS" -ErrorAction Stop |
                                Where-Object { $_.Machine -and $_.Machine.ToLowerInvariant() -eq $machine.ToLowerInvariant() })
                    }
                    catch {
                        $installed = $false
                    }
                    if ($installed) { break }
                    if ($v -lt 10) { Start-Sleep -Seconds 30 }
                }

                if (-not $installed) {
                    Write-DscStatus "[InstallProv] setupWPF exited but $machine never appeared in SMS_ProviderLocation -- provider install did not take"
                }
            }

            if ($installed) {
                Write-DscStatus "[InstallProv] $machine is registered in SMS_ProviderLocation (attempt $attempt)"
            }
            elseif ($attempt -lt $maxAttempts) {
                # A retry against a half-shut-down site just fails again, so restore it first.
                Write-DscStatus "[InstallProv] Provider install did not take on $machine; recovering the site and retrying"
                [void](Restore-SiteServices)
            }
        }

        if (-not $installed) {
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

