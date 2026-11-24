#requires -Version 5.1
<#
Existing-hierarchy OSD never reconciles the hierarchy. Each action authors private
task-sequence copies, applications, content sources and collections for its new
targets. Existing task sequences, content, roles and deployments are read-only
prerequisites. A failed action can leave its unpublished private objects behind;
it never deletes or "repairs" an existing object to make a retry succeed.
Application sources remain under C:\Apps\MemLabs-Expansion-<action-id> until the
owning CM content is explicitly retired; runner staging cleanup must not remove them.
#>
function Get-MemLabsExistingOsdActions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$DeployConfig)

    $ErrorActionPreference = 'Stop'
    $requested = @(Get-MemLabsRequestedDeploymentVMs -DeployConfig $DeployConfig | Where-Object {
            $_.role -eq 'OSDClient' -and -not (Test-MemLabsContextOnlyVM -VM $_)
        })
    if (-not $requested.Count) { return }
    if (-not @($DeployConfig.virtualMachines | Where-Object { $_.role -in @('CAS', 'Primary', 'Secondary') }).Count) {
        return # An OSDClient without ConfigMgr is just an empty VM.
    }

    $groups = @{}
    $names = @{}
    $macs = @{}
    $defaultDomain = "$($DeployConfig.parameters.domainName)"
    if (-not $defaultDomain) { $defaultDomain = "$($DeployConfig.vmOptions.domainName)" }
    foreach ($vm in $requested) {
        $name = "$($vm.vmName)".Trim()
        $mac = ("$($vm.osdMacAddress)" -replace '[-:]', '').ToUpperInvariant()
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $name -match '^\d+$' -or $name.EndsWith('-')) {
            throw "OSD target '$name' is not a valid Windows computer name."
        }
        # Owner/mutex planning also runs before Phase 1 creates the NIC. Phase 8
        # rebuilds this payload after MAC capture; the guest validates identity.
        if ($names.ContainsKey($name) -or ($mac -and $macs.ContainsKey($mac))) {
            throw "OSD target '$name' has a duplicate requested computer name or MAC '$mac'."
        }
        $names[$name] = $true
        if ($mac) { $macs[$mac] = $true }
        $network = "$($vm.network)"
        if (-not $network -and $vm.thisParams) { $network = "$($vm.thisParams.vmNetwork)" }
        if (-not $network) { $network = "$($DeployConfig.vmOptions.network)" }
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($network, [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.GetAddressBytes()[3] -ne 0) {
            throw "OSD target '$name' needs an explicit supported /24 client network, not '$network'."
        }
        $paths = @($DeployConfig.osdPxePaths | Where-Object { "$($_.clientNetwork)" -eq $network })
        if (-not $paths.Count -and (Get-Command Get-OsdPxePaths -ErrorAction SilentlyContinue)) {
            # An explicitly supplied inventory prevents the topology resolver
            # from inspecting live Hyper-V or DHCP during early planning.
            $paths = @(Get-OsdPxePaths -Config $DeployConfig -Inventory @() | Where-Object { "$($_.clientNetwork)" -eq $network })
        }
        if (-not $paths.Count) { throw "OSD target '$name' has no resolved PXE path for '$network'; existing topology was not reconstructed." }
        $owner = $null
        $targetPaths = @()
        foreach ($path in $paths) {
            if ($path.mode -notin @('Direct', 'Relay')) {
                throw "OSD target '$name' has a $($path.mode) PXE path: $($path.reason). Existing topology must be repaired explicitly."
            }
            $resolved = @(Resolve-MemLabsDeploymentPrimary -DeployConfig $DeployConfig -SiteCode "$($path.distributionPointSiteCode)")
            if ($resolved.Count -ne 1 -or $resolved[0].role -ne 'Primary' -or "$($resolved[0].siteCode)" -notmatch '^[A-Za-z0-9]{3}$') {
                throw "OSD target '$name' does not resolve to exactly one owning Primary."
            }
            if ($owner -and $owner.vmName -ne $resolved[0].vmName) {
                throw "OSD target '$name' has PXE paths belonging to different Primaries."
            }
            $owner = $resolved[0]
            $dp = @($DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $path.distributionPointVM })
            if ($dp.Count -ne 1 -or $dp[0].siteCode -ne $path.distributionPointSiteCode -or
                -not ($dp[0].installDP -eq $true -or $dp[0].enablePullDP -eq $true -or $dp[0].role -eq 'Secondary')) {
                throw "OSD target '$name' has incomplete or conflicting DP ownership metadata for '$($path.distributionPointVM)'."
            }
            $domain = $defaultDomain
            if ($dp[0].domain) { $domain = "$($dp[0].domain)" }
            if (-not $domain) { throw "OSD DP '$($dp[0].vmName)' has no explicit domain metadata." }
            $fqdn = "$($dp[0].vmName)"
            if (-not $fqdn.Contains('.')) { $fqdn = "$fqdn.$domain" }
            if ($path.mode -eq 'Relay' -and (-not $path.relayVM -or -not $path.relayIPv4)) {
                throw "OSD target '$name' has an incomplete relay path; existing relay addressing was not inferred."
            }
            $targetPaths += [pscustomobject]@{
                ClientNetwork = $network
                Mode = "$($path.mode)"
                DPFqdn = $fqdn
                DPSiteCode = "$($path.distributionPointSiteCode)"
                RelayVM = "$($path.relayVM)"
                RelayIPv4 = "$($path.relayIPv4)"
                DPIPv4 = "$($path.distributionPointIPv4)"
                DPIsCurrentRequest = ((-not $dp[0].hidden -and $dp[0].ExistingVM -ne $true) -or $dp[0].cmOptionsChanged -eq $true)
            }
        }
        # A new Primary's ordinary Phase 8 owns its initial OSD setup.
        if (-not (Test-MemLabsContextOnlyVM -VM $owner)) { continue }
        $ownerDomain = $defaultDomain
        if ($owner.domain) { $ownerDomain = "$($owner.domain)" }
        $clientDomain = $defaultDomain
        if ($vm.domain) { $clientDomain = "$($vm.domain)" }
        if (-not $ownerDomain -or $ownerDomain -ne $clientDomain) {
            throw "OSD target '$name' and owning Primary '$($owner.vmName)' need the same explicit domain."
        }
        $selected = "$($vm.osdTaskSequence)".Trim()
        $supported = @('MEMLABS-w11-Install OS image', 'MEMLABS-w10-Install OS image')
        if ($selected -and $selected -notin $supported) { throw "OSD target '$name' selects unsupported task sequence '$selected'." }
        $channel = ''
        if ($vm.installOffice -and $vm.installOffice -ne $false) {
            $channel = "$($vm.installOffice)"
            if ($vm.installOffice -eq $true) { $channel = 'Current' }
            if ($channel -notin @('Current', 'MonthlyEnterprise', 'SemiAnnual')) { throw "OSD target '$name' selects unsupported Office channel '$channel'." }
        }
        $disks = @()
        if ($vm.additionalDisks) {
            foreach ($property in @($vm.additionalDisks.PSObject.Properties)) {
                $letter = "$($property.Name)".Trim().TrimEnd(':').ToUpperInvariant()
                $size = 0L
                if ($letter -notmatch '^[E-Y]$' -or $letter -eq 'S' -or
                    -not [long]::TryParse("$($property.Value)", [ref]$size) -or $size -lt 1GB) {
                    throw "OSD target '$name' has an invalid additional disk '$letter' ('$($property.Value)')."
                }
                $index = $disks.Count
                $disks += [pscustomobject]@{ DiskIndex = $index; Letter = $letter; SizeBytes = $size; Label = "DATA_$index" }
            }
        }
        $key = "$($owner.vmName)".ToUpperInvariant()
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Owner = $owner; Domain = $ownerDomain; Targets = @() }
        }
        $groups[$key].Targets += [pscustomobject]@{
            vmName = $name
            role = 'OSDClient'
            osdMacAddress = ($mac -replace '(..)(?!$)', '$1:')
            BitLocker = ($vm.BitLocker -eq $true)
            OfficeChannel = $channel
            SelectedTaskSequence = $selected
            SourceTaskSequenceNames = @($(if ($selected) { $selected } else { $supported }))
            Paths = @($targetPaths | Sort-Object DPFqdn -Unique)
            Disks = @($disks)
        }
    }
    if (-not $groups.Count) { return }

    # Carry only immutable shipped templates and the two reconcilers that are
    # safe when given freshly-created, action-private task-sequence objects.
    $phaseRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $phaseRoot 'perfloading.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot extract shipped OSD templates: $($errors -join '; ')" }
    $helpers = @()
    foreach ($helperName in @('Sync-MemLabsOsdComputerNameSteps', 'Sync-MemLabsOsdBitLockerSteps', 'Sync-MemLabsOsdBootstrapFramework')) {
        $definitions = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName
                }, $true))
        if ($definitions.Count -ne 1) { throw "Expected one shipped '$helperName' definition." }
        if ($helperName -eq 'Sync-MemLabsOsdBootstrapFramework') {
            $assignment = @($definitions[0].Body.FindAll({
                        param($node)
                        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'installScript'
                    }, $true))
            if ($assignment.Count -ne 1) { throw 'Shipped OSD bootstrap installer was not found uniquely.' }
            $literal = $assignment[0].Right.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
            if (-not $literal -or -not $literal.Value) { throw 'Shipped OSD bootstrap installer is not a literal template.' }
            $bootstrapInstaller = $literal.Value
        }
        else { $helpers += $definitions[0].Extent.Text }
    }
    $diskInitializer = [IO.File]::ReadAllText((Join-Path $phaseRoot 'Initialize-OsdDataDisks.ps1')).TrimStart([char]0xFEFF)
    $activationDefinition = [IO.File]::ReadAllText((Join-Path $phaseRoot 'WindowsActivation.Script.ps1')).TrimStart([char]0xFEFF)

    $hostPreflight = {
        param($Payload)
        $ErrorActionPreference = 'Stop'
        $tag = '[ExistingHierarchy OSD relay]'
        $requiredNames = @($Payload.Targets.Paths | Where-Object Mode -eq Relay | ForEach-Object RelayVM | Sort-Object -Unique)
        $providedNames = @($Payload.Relays | ForEach-Object VMName | Sort-Object -Unique)
        if ($providedNames.Count -ne @($Payload.Relays).Count -or $requiredNames.Count -ne $providedNames.Count -or
            @($requiredNames | Where-Object { -not $_ -or $_ -notin $providedNames }).Count) {
            throw "$tag Serialized relay prerequisites do not match the exact required target paths; no guest OSD mutations were submitted."
        }
        if (-not $requiredNames.Count) { return }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        function Stop-OsdRelayPrerequisite {
            param([string]$Name, [string]$Detail)
            throw "$tag Required relay '$Name': $Detail. No VM, adapter, key, network or service was changed; repair it explicitly."
        }
        function Get-OsdRelayBudget {
            $remaining = 120000 - [long]$timer.ElapsedMilliseconds
            if ($remaining -lt 1000) { throw "$tag Read-only preflight exceeded its 120s budget; no guest OSD mutations were submitted." }
            return [int]$remaining
        }
        function Test-OsdRelayIPv4 {
            param([string]$Value)
            $parsed = $null
            return $Value -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($Value, [ref]$parsed) -and
                $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and "$parsed" -eq $Value
        }
        # Do not call Get-LinuxSshExePath/Get-LinuxAdminSshKeyPair or the
        # general Invoke-LinuxVmCommand: those can install SSH, rotate keys or
        # repair key ACLs even when the requested remote command only observes.
        if (Get-Command Find-OpenSshTool -ErrorAction SilentlyContinue) { $ssh = Find-OpenSshTool -Name 'ssh.exe' }
        else { $ssh = @(Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
        if (-not $ssh) { throw "$tag Existing host ssh.exe is unavailable; install it explicitly. Nothing was installed." }
        if (-not $Common -or -not $Common.CachePath) { throw "$tag Existing host Common.CachePath is unavailable; no SSH key was created." }
        $keyPath = Join-Path "$($Common.CachePath)" 'ssh\memlabs_ed25519'
        if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf -ErrorAction Stop)) {
            throw "$tag Existing host SSH private key is unavailable; no key was generated or repaired."
        }
        $probeBody = @'
set -euo pipefail
fail() { printf 'OSD relay blocked: %s\n' "$*" >&2; exit 3; }
interface_for_mac() {
    ip -o link show | awk -v expected="$1" '{
        for (i=1; i<NF; i++) {
            if ($i == "link/ether") {
                mac=tolower($(i+1)); gsub(/:/, "", mac)
                if (mac == expected) { name=$2; sub(/:$/, "", name); sub(/@.*/, "", name); print name }
            }
        }
    }'
}
management_if=$(interface_for_mac "$MANAGEMENT_MAC")
[ -n "$management_if" ] && [[ "$management_if" != *$'\n'* ]] || fail 'management MAC does not identify exactly one interface'
ip -4 -o address show dev "$management_if" | awk '{print $4}' | grep -Fx "$MANAGEMENT_IP/24" >/dev/null || fail 'management IP/MAC mismatch'
default_routes=$(ip -4 route show default)
[ "$(printf '%s\n' "$default_routes" | wc -l)" -eq 1 ] || fail 'default route count is not one'
printf '%s\n' "$default_routes" | grep -E " dev $management_if( |$)" >/dev/null || fail 'management interface does not own the default route'
[ "$(sysctl -n net.ipv4.ip_forward)" = 0 ] || fail 'IP forwarding is enabled on the dedicated relay'
config=/etc/memlabs-dhcp-relay.conf
unit=memlabs-dhcp-relay.service
/usr/sbin/dnsmasq --test --conf-file="$config" || fail 'existing dnsmasq configuration is invalid'
systemctl is-enabled --quiet "$unit" || fail 'relay service is not enabled'
systemctl is-active --quiet "$unit" || fail 'relay service is not active'
pid=$(systemctl show --property MainPID --value "$unit")
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'relay service has no MainPID'
ss -H -lunp | grep -E '(^|[[:space:]])[^[:space:]]*:67[[:space:]]' | grep -F "pid=$pid," >/dev/null || fail 'the relay service does not own a UDP/67 listener'
count=0
while IFS='|' read -r expected_mac expected_ip expected_target extra; do
    [ -n "$expected_mac" ] && [ -z "$extra" ] || fail 'malformed required mapping'
    iface=$(interface_for_mac "$expected_mac")
    [ -n "$iface" ] && [[ "$iface" != *$'\n'* ]] || fail "required client MAC $expected_mac does not identify exactly one interface"
    ip -4 -o address show dev "$iface" | awk '{print $4}' | grep -Fx "$expected_ip/24" >/dev/null || fail "$iface does not own $expected_ip/24"
    [ "$(grep -Fxc "dhcp-relay=$expected_ip,$expected_target" "$config")" -eq 1 ] || fail "required mapping $expected_ip -> $expected_target is not present exactly once"
    ip -4 route get "$expected_target" | grep -E " dev $management_if( |$)" >/dev/null || fail "required target $expected_target has no management-interface route"
    count=$((count + 1))
done < <(printf '%s' "$EXPECTED_MAPPINGS_B64" | base64 -d)
[ "$count" -gt 0 ] || fail 'no required mappings were measured'
printf 'MEMLABS_OSD_RELAY_READY mappings=%s\n' "$count"
'@
        $observed = @()
        foreach ($relay in $Payload.Relays) {
            $null = Get-OsdRelayBudget
            $name = "$($relay.VMName)"
            $declared = @($Payload.Targets.Paths | Where-Object { $_.Mode -eq 'Relay' -and $_.RelayVM -eq $name } |
                    Sort-Object ClientNetwork, RelayIPv4, DPIPv4 -Unique)
            if (-not $declared.Count -or -not (Test-OsdRelayIPv4 "$($relay.ManagementIPv4)")) {
                Stop-OsdRelayPrerequisite $name 'serialized management address or required target paths are invalid'
            }
            $hostVM = @(Get-VM2 -Name $name -ErrorAction Stop)
            if ($hostVM.Count -ne 1 -or $hostVM[0].Name -ne $name -or $hostVM[0].State -ne 'Running') {
                Stop-OsdRelayPrerequisite $name 'the declared Hyper-V VM is absent, ambiguous or not Running'
            }
            $adapters = @($hostVM[0] | Get-VMNetworkAdapter -ErrorAction Stop)
            $management = @($adapters | Where-Object { $_.SwitchName -eq $relay.ManagementNetwork })
            if ($management.Count -ne 1) { Stop-OsdRelayPrerequisite $name "expected one management adapter on '$($relay.ManagementNetwork)', found $($management.Count)" }
            $managementMac = ("$($management[0].MacAddress)" -replace '[-:]', '').ToLowerInvariant()
            if ($managementMac -notmatch '^[0-9a-f]{12}$' -or $managementMac -eq '000000000000') {
                Stop-OsdRelayPrerequisite $name 'management adapter MAC is unavailable'
            }
            $rows = @()
            foreach ($path in $declared) {
                if (-not (Test-OsdRelayIPv4 "$($path.RelayIPv4)") -or -not (Test-OsdRelayIPv4 "$($path.DPIPv4)")) {
                    Stop-OsdRelayPrerequisite $name "required path '$($path.ClientNetwork)' has no explicit valid relay/DP IPv4"
                }
                $clientAdapters = @($adapters | Where-Object { $_.SwitchName -eq $path.ClientNetwork })
                if ($clientAdapters.Count -ne 1) {
                    Stop-OsdRelayPrerequisite $name "expected one adapter on required client switch '$($path.ClientNetwork)', found $($clientAdapters.Count)"
                }
                $clientMac = ("$($clientAdapters[0].MacAddress)" -replace '[-:]', '').ToLowerInvariant()
                if ($clientMac -notmatch '^[0-9a-f]{12}$' -or $clientMac -eq '000000000000') {
                    Stop-OsdRelayPrerequisite $name "client adapter MAC is unavailable on '$($path.ClientNetwork)'"
                }
                $rows += "$clientMac|$($path.RelayIPv4)|$($path.DPIPv4)"
            }
            $remaining = Get-OsdRelayBudget
            $auth = @(Invoke-LinuxSshReadyProbe -SshExe $ssh -PrivateKeyPath $keyPath -IPAddress $relay.ManagementIPv4 `
                    -TimeoutSeconds ([Math]::Min(10, [int][Math]::Floor($remaining / 1000))))
            if ($auth.Count -ne 1 -or -not $auth[0].PSObject.Properties['ExitCode'] -or
                "$($auth[0].ExitCode)" -ne '0' -or $auth[0].TimedOut -eq $true) {
                $authDetail = 'invalid native receipt'
                if ($auth.Count -eq 1) { $authDetail = "exit=$($auth[0].ExitCode), timedOut=$($auth[0].TimedOut)" }
                Stop-OsdRelayPrerequisite $name "existing-key SSH authentication failed or timed out ($authDetail); keys and ACLs were not repaired"
            }
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($rows -join "`n") + "`n"))
            $script = "MANAGEMENT_MAC='$managementMac'`nMANAGEMENT_IP='$($relay.ManagementIPv4)'`nEXPECTED_MAPPINGS_B64='$encoded'`n$probeBody"
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $ssh
            foreach ($argument in @(
                    '-F', 'NUL', '-T', '-i', $keyPath, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
                    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=1',
                    '-o', 'PermitLocalCommand=no', '-o', 'ClearAllForwardings=yes', '-o', 'ControlPath=none', '-o', 'LogLevel=ERROR',
                    "vmbuildadmin@$($relay.ManagementIPv4)", 'sudo -n bash -s'
                )) { $info.ArgumentList.Add($argument) }
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process = $null
            try {
                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $info
                if (-not $process.Start()) { throw 'SSH observation process did not start' }
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $write = $process.StandardInput.WriteAsync(($script -replace "`r", ''))
                if (-not $write.Wait([Math]::Min(10000, (Get-OsdRelayBudget)))) {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    throw 'read-only SSH relay observation input exceeded its bounded timeout'
                }
                $process.StandardInput.Close()
                if (-not $process.WaitForExit([Math]::Min(60000, (Get-OsdRelayBudget)))) {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    throw 'read-only SSH relay observation exceeded its bounded timeout'
                }
                if (-not $stdout.Wait([Math]::Min(5000, (Get-OsdRelayBudget))) -or
                    -not $stderr.Wait([Math]::Min(5000, (Get-OsdRelayBudget)))) {
                    throw 'read-only SSH relay observation output exceeded its bounded timeout'
                }
                $output = "$($stdout.Result)"
                $detail = "$($stderr.Result)".Trim()
                if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
                if ($process.ExitCode -ne 0) { throw "read-only SSH relay observation exited $($process.ExitCode): $detail" }
                if ($output -notmatch "(?m)^MEMLABS_OSD_RELAY_READY mappings=$($declared.Count)\r?$") {
                    throw 'read-only SSH relay observation did not confirm every required mapping'
                }
                $observed += $name
            }
            catch { Stop-OsdRelayPrerequisite $name $_.Exception.Message }
            finally { if ($process) { $process.Dispose() } }
        }
        [pscustomobject]@{ Status = 'Verified'; RelayVMNames = @($observed) }
    }

    $handler = {
        param($Payload)
        $ErrorActionPreference = 'Stop'
        $tag = '[ExistingHierarchy OSD]'
        $actionTimer = [Diagnostics.Stopwatch]::StartNew()
        function Get-OsdRemainingMilliseconds {
            $remaining = 6900000 - [long]$actionTimer.ElapsedMilliseconds
            if ($remaining -le 0) { throw "$tag Action exceeded its bounded 6900s work budget." }
            return [int]$remaining
        }
        $location = Get-Location
        if ($location.Provider.Name -ne 'CMSite' -or $location.Drive.Name -ne $Payload.SiteCode -or
            "$SiteCode" -ne "$($Payload.SiteCode)" -or "$($ThisVM.vmName)" -ne "$($Payload.OwnerVMName)") {
            throw "$tag Incorrect Primary/provider context; no OSD action was performed."
        }
        $ns = "root\SMS\site_$($Payload.SiteCode)"
        if ("$($Payload.ActionId)" -notmatch '^[0-9a-f]{32}$' -or -not @($Payload.Targets).Count) {
            throw "$tag Invalid or empty serialized action payload."
        }
        $targetNames = @{}
        $targetMacs = @{}
        foreach ($target in $Payload.Targets) {
            $name = "$($target.vmName)"
            $mac = "$($target.osdMacAddress)" -replace ':', ''
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $name -match '^\d+$' -or $name.EndsWith('-') -or
                $mac -notmatch '^[0-9A-F]{12}$' -or $mac -in @('000000000000', 'FFFFFFFFFFFF') -or
                (([Convert]::ToByte($mac.Substring(0, 2), 16) -band 1) -ne 0)) {
                throw "$tag Target '$name' needs a valid computer name and captured unicast osdMacAddress before dispatch."
            }
            if ($targetNames.ContainsKey($name) -or $targetMacs.ContainsKey($mac)) { throw "$tag Duplicate requested target name or MAC." }
            $targetNames[$name] = $true
            $targetMacs[$mac] = $true
            foreach ($path in $target.Paths) {
                if ($path.Mode -eq 'Relay' -and -not $path.DPIPv4) {
                    throw "$tag Target '$name' has no resolved DP IPv4 for its requested relay path."
                }
            }
        }
        function Stop-OsdPrerequisite {
            param([string]$Detail)
            throw "$tag Required existing prerequisite: $Detail. Existing state was left unchanged; repair it explicitly."
        }
        function Get-OsdNalServer {
            param([string]$Value)
            if ($Value -match '\\\\([^\\"]+)\\') { return $Matches[1] }
            return ''
        }
        function Test-OsdServerMatch {
            param([string]$Actual, [string]$Expected)
            return $Actual -ieq $Expected -or ($Actual -ieq ($Expected -split '\.')[0])
        }
        function Get-OsdPackage {
            param([string]$Id, [string]$Class = 'SMS_PackageBaseclass')
            if ($Id -notmatch '^[A-Za-z0-9]{8}$') { Stop-OsdPrerequisite "invalid $Class package ID '$Id'" }
            $rows = @(Get-WmiObject -Namespace $ns -Class $Class -Filter "PackageID='$Id'" -ErrorAction Stop)
            if ($rows.Count -ne 1) { Stop-OsdPrerequisite "$Class '$Id' resolved to $($rows.Count) objects" }
            $null = $rows[0].Get()
            return $rows[0]
        }
        function Get-OsdOwnedTaskSequence {
            param([string]$Id)
            if ($Id -notmatch "^$([regex]::Escape($Payload.SiteCode))[A-Za-z0-9]{5}$") {
                throw "$tag Invalid owning-site task-sequence PackageID '$Id'."
            }
            $rows = @(Get-CMTaskSequence -TaskSequenceId $Id -ErrorAction Stop)
            if ($rows.Count -ne 1) { throw "$tag Task sequence '$Id' resolved to $($rows.Count) native objects." }
            $null = $rows[0].Get()
            if ("$($rows[0].PackageID)" -ne $Id -or "$($rows[0].SourceSite)" -ne "$($Payload.SiteCode)") {
                throw "$tag Refreshed task-sequence ownership mismatch: expected PackageID='$Id', SourceSite='$($Payload.SiteCode)'; got PackageID='$($rows[0].PackageID)', SourceSite='$($rows[0].SourceSite)'. No ownership repair was attempted."
            }
            return $rows[0]
        }
        function Test-OsdPackageInstalled {
            param($Package, [object[]]$Paths, [switch]$NewContent)
            $version = 0
            if (-not [int]::TryParse("$($Package.SourceVersion)", [ref]$version) -or $version -le 0) {
                if ($NewContent) { return $false }
                Stop-OsdPrerequisite "package '$($Package.PackageID)' has no readable SourceVersion"
            }
            $rows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
                    -Filter "PackageID='$($Package.PackageID)'" -ErrorAction Stop)
            foreach ($dpName in @($Paths.DPFqdn | Select-Object -Unique)) {
                $matching = @($rows | Where-Object { Test-OsdServerMatch (Get-OsdNalServer "$($_.ServerNALPath)") $dpName })
                if ($matching.Count -ne 1 -or "$($matching[0].State)" -ne '0' -or
                    -not "$($matching[0].SourceVersion)" -or [int]$matching[0].SourceVersion -lt $version) {
                    $states = @($matching | ForEach-Object { "State=$($_.State),Version=$($_.SourceVersion)" }) -join ';'
                    if (-not $NewContent) { Stop-OsdPrerequisite "package '$($Package.PackageID)' is not Installed/current on '$dpName' ($states)" }
                    if (@($matching | Where-Object { "$($_.State)" -notin @('0', '1', '2', '7') }).Count) {
                        throw "$tag NEW content '$($Package.PackageID)' failed on '$dpName' ($states). No redistribution was attempted."
                    }
                    return $false
                }
            }
            return $true
        }
        function Get-OsdInheritedApplicationSnapshot {
            param($TaskSequence, [object[]]$Paths)
            $native = @(Get-WmiObject -Namespace $ns -Class SMS_TaskSequencePackage -Filter "PackageID='$($TaskSequence.PackageID)'" -ErrorAction Stop)
            if ($native.Count -ne 1) { Stop-OsdPrerequisite 'selected task-sequence package cannot be resolved for native application metadata' }
            $sequence = Invoke-WmiMethod -Namespace $ns -Class SMS_TaskSequencePackage -Name GetSequence -ArgumentList @($native[0]) -ErrorAction Stop
            if ($sequence.ReturnValue -ne 0 -or -not $sequence.TaskSequence) { Stop-OsdPrerequisite 'selected task sequence has no readable native sequence' }
            $models = @(Get-MemLabsEnabledTaskSequenceApplications -Steps $sequence.TaskSequence.Steps | Sort-Object -Unique)
            $null = $TaskSequence.Get()
            $references = @(
                foreach ($reference in @($TaskSequence.GetArrayItems('References'))) {
                    if ($reference['Type'].IntegerValue -eq 1) { "$($reference['Package'].StringValue)" }
                }
            )
            if (@($models | Where-Object { $_ -notin $references }).Count) {
                Stop-OsdPrerequisite 'enabled application steps and persisted Type1 references disagree; pruned references were not treated as no dependencies'
            }
            return Get-MemLabsApplicationContentSnapshot -Models $models -Paths $Paths -Namespace $ns
        }
        function Write-OsdFile {
            param([string]$Path, [string]$Text)
            Set-Content -LiteralPath "FileSystem::$Path" -Value $Text -Encoding UTF8 -ErrorAction Stop
        }
        function New-OsdApplication {
            param([string]$Name, [string]$Source, [string]$Command, [string]$Detection, [object[]]$Paths)
            if ($Source -notlike "$sourceRoot\*" -or
                -not (Test-Path -LiteralPath "FileSystem::$Source" -PathType Container -ErrorAction Stop)) {
                throw "$tag New application '$Name' has no readable persistent C:\Apps source '$Source'."
            }
            $created = @(New-CMApplication -Name $Name -Publisher MemLabs -SoftwareVersion $Payload.ActionId `
                    -Description "Private OSD expansion $($Payload.ActionId); targets: $($Payload.Targets.vmName -join ', ')" `
                    -AutoInstall $true -ErrorAction Stop)
            if ($created.Count -ne 1 -or -not $created[0].CI_ID -or $created[0].LocalizedDisplayName -ne $Name) {
                throw "$tag New application '$Name' did not return one matching NEW application/CI_ID."
            }
            $null = Add-CMScriptDeploymentType -Application $created[0] -DeploymentTypeName "$Name install" `
                -ContentLocation $Source -InstallCommand $Command -ScriptLanguage PowerShell -ScriptText $Detection `
                -InstallationBehaviorType InstallForSystem -LogonRequirementType WhetherOrNotUserLoggedOn -ErrorAction Stop
            $readback = @(Get-CMApplication -Id "$($created[0].CI_ID)" -ErrorAction Stop)
            if ($readback.Count -ne 1 -or $readback[0].LocalizedDisplayName -ne $Name) {
                throw "$tag New application '$Name' could not be read back by its CI_ID."
            }
            $types = @(Get-CMDeploymentType -ApplicationName $Name -ErrorAction Stop)
            if ($types.Count -ne 1 -or $types[0].LocalizedDisplayName -ne "$Name install") {
                throw "$tag New application '$Name' did not persist its one private deployment type."
            }
            $null = Start-CMContentDistribution -InputObject $readback[0] -DistributionPointName @($Paths.DPFqdn | Select-Object -Unique) `
                -DisableContentDependencyDetection -ErrorAction Stop
            # Only NEW content is allowed to converge. Never re-arm or update it.
            for ($attempt = 0; $attempt -lt 90; $attempt++) {
                $null = Get-OsdRemainingMilliseconds
                $ids = @(Get-WmiObject -Namespace $ns -Class SMS_CIContentPackage `
                        -Filter "CI_ID='$($created[0].CI_ID)'" -ErrorAction Stop | ForEach-Object { "$($_.PackageID)" } | Select-Object -Unique)
                $ready = $ids.Count -gt 0
                foreach ($id in $ids) {
                    $package = Get-OsdPackage $id
                    if (-not (Test-OsdPackageInstalled $package $Paths -NewContent)) { $ready = $false }
                }
                if ($ready) { return $readback[0] }
                if ($attempt -lt 89) { Start-Sleep -Seconds 10 }
            }
            throw "$tag New application '$Name' was not Installed/current on its exact target DPs within 900s. No existing content was redistributed."
        }

        foreach ($serviceName in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            if ($service.Status -ne 'Running') { Stop-OsdPrerequisite "service '$serviceName' is $($service.Status) on '$($Payload.OwnerVMName)'" }
        }
        $allPaths = @($Payload.Targets.Paths | Sort-Object DPFqdn, ClientNetwork -Unique)
        $resources = @(Get-WmiObject -Namespace $ns -Class SMS_R_System -Property ResourceID, Name, MACAddresses -ErrorAction Stop)
        foreach ($target in $Payload.Targets) {
            $conflicts = @($resources | Where-Object {
                    $row = $_
                    $row.Name -eq $target.vmName -or @($row.MACAddresses | Where-Object {
                            ("$_" -replace '[-:]', '') -eq ("$($target.osdMacAddress)" -replace ':', '')
                        }).Count -gt 0
                })
            if ($conflicts.Count) { Stop-OsdPrerequisite "target '$($target.vmName)' or MAC '$($target.osdMacAddress)' already belongs to an existing resource; it was not merged, reset or reimaged" }
        }
        $boundaries = @(Get-WmiObject -Namespace $ns -Class SMS_Boundary -ErrorAction Stop)
        $members = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupMembers -ErrorAction Stop)
        $boundaryGroups = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop)
        $links = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -ErrorAction Stop)
        foreach ($path in $allPaths) {
            $range = "$($path.ClientNetwork -replace '\.0$', '.1')-$($path.ClientNetwork -replace '\.0$', '.254')"
            $boundaryIds = @($boundaries | Where-Object {
                    ($_.BoundaryType -eq 0 -and $_.Value -eq $path.ClientNetwork) -or ($_.BoundaryType -eq 3 -and $_.Value -eq $range)
                } | ForEach-Object { $_.BoundaryID })
            $groupIds = @($members | Where-Object { $_.BoundaryID -in $boundaryIds } | ForEach-Object { $_.GroupID })
            $ownedIds = @($boundaryGroups | Where-Object { $_.GroupID -in $groupIds -and $_.DefaultSiteCode -eq $Payload.SiteCode } |
                    ForEach-Object { $_.GroupID })
            $dpLinks = @($links | Where-Object {
                    $_.GroupID -in $ownedIds -and (Test-OsdServerMatch (Get-OsdNalServer "$($_.ServerNALPath)") $path.DPFqdn)
                })
            if (-not $dpLinks.Count) { Stop-OsdPrerequisite "network '$($path.ClientNetwork)' has no existing boundary-group path assigned to '$($Payload.SiteCode)' and DP '$($path.DPFqdn)'" }
            $role = @(Get-CMDistributionPoint -SiteSystemServerName $path.DPFqdn -SiteCode $path.DPSiteCode -ErrorAction Stop)
            if ($path.DPIsCurrentRequest -and $role.Count -eq 0) {
                for ($attempt = 0; $attempt -lt 60 -and $role.Count -eq 0; $attempt++) {
                    $null = Get-OsdRemainingMilliseconds
                    Start-Sleep -Seconds 10
                    $role = @(Get-CMDistributionPoint -SiteSystemServerName $path.DPFqdn -SiteCode $path.DPSiteCode -ErrorAction Stop)
                }
            }
            if ($role.Count -ne 1) { Stop-OsdPrerequisite "DP role '$($path.DPFqdn)' at '$($path.DPSiteCode)' resolved to $($role.Count) objects" }
        }
        $templates = @{}
        foreach ($sourceName in @($Payload.Targets.SourceTaskSequenceNames | Select-Object -Unique)) {
            $rows = @(Get-CMTaskSequence -Name $sourceName -ErrorAction Stop | Where-Object {
                    $_.Name -eq $sourceName -and "$($_.PackageID)" -match "^$([regex]::Escape($Payload.SiteCode))[A-Za-z0-9]{5}$"
                })
            if ($rows.Count -ne 1) { Stop-OsdPrerequisite "site-owned task sequence '$sourceName' resolved to $($rows.Count) objects" }
            $ts = Get-OsdOwnedTaskSequence "$($rows[0].PackageID)"
            $apply = @($ts | Get-CMTSStepApplyOperatingSystem -ErrorAction Stop)
            $setup = @($ts | Get-CMTSStepSetupWindowsAndConfigMgr -ErrorAction Stop)
            if ($apply.Count -ne 1 -or $setup.Count -ne 1 -or $apply[0].Enabled -eq $false -or $setup[0].Enabled -eq $false) {
                Stop-OsdPrerequisite "task sequence '$sourceName' needs one enabled Apply OS and Setup Windows/ConfigMgr step"
            }
            foreach ($spec in @(
                    @{ Get = 'Get-CMTSStepOfflineEnableBitLocker'; Name = 'Pre-provision BitLocker' }
                    @{ Get = 'Get-CMTSStepEnableBitLocker'; Name = 'Enable BitLocker' }
                )) {
                if (@($ts | & $spec.Get -StepName $spec.Name -ErrorAction Stop).Count -ne 1) {
                    Stop-OsdPrerequisite "task sequence '$sourceName' needs exactly one '$($spec.Name)' step"
                }
            }
            foreach ($groupName in @('Capture User Files and Settings', 'Restore User Files and Settings')) {
                if (@($ts | Get-CMTaskSequenceGroup -StepName $groupName -ErrorAction Stop).Count) {
                    Stop-OsdPrerequisite "bare-metal task sequence '$sourceName' still contains '$groupName'"
                }
            }
            if (@($ts | Get-CMTSStepInstallApplication -StepName 'MEMLABS install OSD Bootstrap' -ErrorAction Stop).Count -or
                @($ts | Get-CMTSStepReboot -StepName 'MEMLABS restart into installed OS' -ErrorAction Stop).Count) {
                Stop-OsdPrerequisite "task sequence '$sourceName' contains obsolete in-sequence bootstrap actions"
            }
            $paths = @($Payload.Targets | Where-Object { $sourceName -in $_.SourceTaskSequenceNames } | ForEach-Object { $_.Paths })
            $boot = Get-OsdPackage "$($ts.BootImageID)" SMS_BootImagePackage
            if (([int]$boot.PkgFlags -band 0x400) -ne 0x400) { Stop-OsdPrerequisite "boot image '$($boot.PackageID)' is not PXE-enabled" }
            $sourcePresent = $false
            foreach ($source in @($boot.ImagePath, $boot.PkgSourcePath) | Where-Object { $_ }) {
                if (Test-Path -LiteralPath "FileSystem::$source" -PathType Leaf -ErrorAction Stop) { $sourcePresent = $true }
            }
            if (-not $sourcePresent) { Stop-OsdPrerequisite "boot image '$($boot.PackageID)' has no accessible source WIM" }
            $null = Test-OsdPackageInstalled $boot $paths
            $null = Test-OsdPackageInstalled (Get-OsdPackage "$($apply[0].ImagePackageID)" SMS_ImagePackage) $paths
            $null = Test-OsdPackageInstalled (Get-OsdPackage "$($setup[0].ClientPackageID)" SMS_Package) $paths
            $templates[$sourceName] = $ts
        }
        $probePxe = {
            param([string[]]$BootIds)
            $ErrorActionPreference = 'Stop'
            $settings = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -ErrorAction Stop
            if ($settings.IsActive -ne 1) { throw 'PXE responder IsActive is not 1.' }
            $responders = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='SccmPxe' OR Name='WDSServer'" -OperationTimeoutSec 10 -ErrorAction Stop)
            $running = @($responders | Where-Object { $_.State -eq 'Running' })
            if (-not $running.Count) { throw 'No existing PXE responder service is Running.' }
            $sccm = @($running | Where-Object { $_.Name -eq 'SccmPxe' })
            $root = ''
            if ($sccm.Count -eq 1 -and "$($sccm[0].PathName)" -match '^\s*"?(.+?\.exe)"?(?:\s|$)') {
                $root = Split-Path -Parent ([Environment]::ExpandEnvironmentVariables($Matches[1]))
            }
            else {
                $root = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSTFTP' -Name RootFolder -ErrorAction Stop).RootFolder
            }
            if (-not $root) { throw 'PXE payload root is not readable.' }
            foreach ($id in $BootIds) {
                if (-not (Test-Path -LiteralPath "$root\SMSBoot\$id\x64\wdsmgfw.efi" -PathType Leaf -ErrorAction Stop)) {
                    throw "Required existing PXE payload '$id\x64\wdsmgfw.efi' is missing."
                }
            }
            [pscustomobject]@{ Ready = $true }
        }
        foreach ($dpName in @($allPaths.DPFqdn | Select-Object -Unique)) {
            $bootIds = @($Payload.Targets | Where-Object { $dpName -in $_.Paths.DPFqdn } | ForEach-Object {
                    foreach ($sourceName in $_.SourceTaskSequenceNames) { "$($templates[$sourceName].BootImageID)" }
                } | Select-Object -Unique)
            $attempts = 1
            if (@($allPaths | Where-Object { $_.DPFqdn -eq $dpName -and $_.DPIsCurrentRequest }).Count) { $attempts = 61 }
            for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
                $null = Get-OsdRemainingMilliseconds
                try {
                if ($dpName -ieq $Payload.OwnerFqdn) { $readiness = & $probePxe -BootIds $bootIds }
                else {
                    $options = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 60000
                    $readiness = Invoke-Command -ComputerName $dpName -ConfigurationName Microsoft.PowerShell -Credential $CMAdmin `
                        -SessionOption $options -ScriptBlock $probePxe -ArgumentList (, $bootIds) -ErrorAction Stop
                }
                    if (-not $readiness -or $readiness.Ready -ne $true) { throw 'Read-only PXE probe did not return Ready.' }
                    break
                }
                catch {
                    if ($attempt -ge ($attempts - 1)) { Stop-OsdPrerequisite "PXE on '$dpName': $($_.Exception.Message)" }
                    Start-Sleep -Seconds 10
                }
            }
        }

        $payloadFiles = @(
            'Enable-LogMachine.ps1', 'Invoke-MemLabsCustomization.ps1', 'Optimize-Defender.ps1',
            'Set-MemLabsMachineSettings.ps1', 'Set-MemLabsUserShell.ps1',
            'bginfo\CLIENT.bgi', 'bginfo\bginfo_CLIENT.lnk', 'bginfo\bginfo.exe'
        )
        foreach ($file in $payloadFiles) {
            if (-not (Test-Path -LiteralPath "FileSystem::C:\staging\$file" -PathType Leaf -ErrorAction Stop)) {
                Stop-OsdPrerequisite "read-only bootstrap input 'C:\staging\$file' is missing"
            }
        }
        if (-not (Test-Path -LiteralPath 'FileSystem::C:\tools\LogMachine\LogMachine.exe' -PathType Leaf -ErrorAction Stop)) {
            Stop-OsdPrerequisite "read-only bootstrap input 'C:\tools\LogMachine\LogMachine.exe' is missing"
        }
        $share = "\\$($Payload.OwnerFqdn)\c`$"
        if (-not (Test-Path -LiteralPath "FileSystem::$share" -PathType Container -ErrorAction Stop)) {
            Stop-OsdPrerequisite "persistent application-source administrative share '$share' is unavailable"
        }
        # Match the existing app-source lifecycle. These bytes belong to CM
        # content, not the disposable ProgramData\MemLabs\Actions runner files.
        $root = "C:\Apps\MemLabs-Expansion-$($Payload.ActionId)"
        $sourceRoot = "$share\Apps\MemLabs-Expansion-$($Payload.ActionId)"
        if (Test-Path -LiteralPath "FileSystem::$root" -ErrorAction Stop) { throw "$tag Private action source '$root' already exists; it was not overwritten." }
        foreach ($name in $Payload.ApplicationNames) {
            if (@(Get-CMApplication -Name $name -ErrorAction Stop | Where-Object { $_.LocalizedDisplayName -eq $name }).Count) {
                throw "$tag Private application '$name' already exists; it was not revised."
            }
        }
        foreach ($name in @($Payload.RegisteredCollectionName) + @($Payload.Targets.CollectionName)) {
            if (@(Get-CMDeviceCollection -Name $name -ErrorAction Stop | Where-Object { $_.Name -eq $name }).Count) {
                throw "$tag Private collection '$name' already exists; its policy and membership were not changed."
            }
        }
        foreach ($name in $Payload.Targets.Sequences.NewName) {
            if (@(Get-CMTaskSequence -Name $name -ErrorAction Stop | Where-Object { $_.Name -eq $name }).Count) {
                throw "$tag Private task sequence '$name' already exists; it was not modified."
            }
        }
        $applicationSnapshots = @{}
        foreach ($sourceName in $templates.Keys) {
            $paths = @($Payload.Targets | Where-Object { $_.Sequences.SourceName -contains $sourceName } | ForEach-Object { $_.Paths })
            $applicationSnapshots[$sourceName] = Get-OsdInheritedApplicationSnapshot $templates[$sourceName] $paths
        }
        $null = New-Item -Path "FileSystem::$root" -ItemType Directory -ErrorAction Stop
        $bootstrapRoot = "$root\Bootstrap"
        $null = New-Item -Path "FileSystem::$bootstrapRoot\Payload\bginfo" -ItemType Directory -Force -ErrorAction Stop
        foreach ($file in $payloadFiles) {
            Copy-Item -LiteralPath "FileSystem::C:\staging\$file" -Destination "FileSystem::$bootstrapRoot\Payload\$file" -ErrorAction Stop
        }
        Copy-Item -LiteralPath 'FileSystem::C:\tools\LogMachine' -Destination "FileSystem::$bootstrapRoot\Payload\LogMachine" -Recurse -ErrorAction Stop
        Write-OsdFile "$bootstrapRoot\Install.ps1" $Payload.BootstrapInstaller
        Write-OsdFile "$bootstrapRoot\Payload\Initialize-OsdDataDisks.ps1" $Payload.DiskInitializer
        $diskClients = @($Payload.Targets | ForEach-Object { [ordered]@{ ComputerName = $_.vmName; Disks = @($_.Disks) } })
        Write-OsdFile "$bootstrapRoot\Payload\DiskConfig.json" ([ordered]@{ SchemaVersion = 1; Clients = $diskClients } | ConvertTo-Json -Depth 8)
        $version = "$($Payload.ActionId)"
        $detection = "if (Test-Path -LiteralPath 'C:\ProgramData\MemLabs\OSDBootstrap\Version.txt' -PathType Leaf) { if ((Get-Content -LiteralPath 'C:\ProgramData\MemLabs\OSDBootstrap\Version.txt' -Raw -ErrorAction Stop).Trim() -eq '$version') { 'Installed' } }"
        $bootstrapApp = New-OsdApplication $Payload.BootstrapApplicationName "$sourceRoot\Bootstrap" `
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Version $version" $detection $allPaths
        $officeApps = @{}
        foreach ($channel in @($Payload.Targets.OfficeChannel | Where-Object { $_ } | Select-Object -Unique)) {
            $officeRoot = "$root\Office-$channel"
            $null = New-Item -Path "FileSystem::$officeRoot" -ItemType Directory -ErrorAction Stop
            $setupPath = "$officeRoot\setup.exe"
            if (Test-Path -LiteralPath 'FileSystem::C:\tools\odt\setup.exe' -PathType Leaf -ErrorAction Stop) {
                Copy-Item -LiteralPath 'FileSystem::C:\tools\odt\setup.exe' -Destination "FileSystem::$setupPath" -ErrorAction Stop
            }
            else {
                Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setupPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop | Out-Null
            }
            $odtChannel = $channel
            if ($channel -eq 'SemiAnnual') { $odtChannel = 'SemiAnnualPreview' }
            $product = '<Product ID="O365ProPlusRetail"><Language ID="en-us" /></Product>'
            Write-OsdFile "$officeRoot\download.xml" "<Configuration><Add SourcePath=`"$officeRoot`" OfficeClientEdition=`"64`" Channel=`"$odtChannel`">$product</Add></Configuration>"
            Write-OsdFile "$officeRoot\install.xml" "<Configuration><Add OfficeClientEdition=`"64`" Channel=`"$odtChannel`">$product</Add><Display Level=`"None`" AcceptEULA=`"TRUE`" /><Property Name=`"AUTOACTIVATE`" Value=`"0`" /><Property Name=`"FORCEAPPSHUTDOWN`" Value=`"TRUE`" /><Updates Enabled=`"TRUE`" /><RemoveMSI /></Configuration>"
            $downloadBudget = [Math]::Min(5400000, (Get-OsdRemainingMilliseconds))
            $process = Start-Process -FilePath $setupPath -ArgumentList "/download `"$officeRoot\download.xml`"" -PassThru -NoNewWindow -ErrorAction Stop
            try {
                if (-not $process.WaitForExit($downloadBudget)) {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    throw "$tag New Office '$channel' source download exceeded its $($downloadBudget / 1000)s budget."
                }
                if ($process.ExitCode -ne 0) { throw "$tag New Office '$channel' source download failed with native exit code $($process.ExitCode)." }
            }
            finally { if ($process) { $process.Dispose() } }
            if (-not @(Get-ChildItem -LiteralPath "FileSystem::$officeRoot\Office\Data" -File -Recurse -ErrorAction Stop).Count) {
                throw "$tag New Office '$channel' source download returned no content."
            }
            $officeName = "$($Payload.NamePrefix)-Office-$channel"
            $paths = @($Payload.Targets | Where-Object { $_.OfficeChannel -eq $channel } | ForEach-Object { $_.Paths })
            $officeDetection = '$ctr = Get-ItemProperty -Path ''HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'' -ErrorAction SilentlyContinue; if ($ctr.VersionToReport) { $ctr.VersionToReport }'
            $officeApps[$channel] = New-OsdApplication $officeName "$sourceRoot\Office-$channel" 'setup.exe /configure install.xml' $officeDetection $paths
        }
        $activationApp = $null
        if ($Payload.EnableAzureActivation) {
            $activationRoot = "$root\Activation"
            $null = New-Item -Path "FileSystem::$activationRoot" -ItemType Directory -ErrorAction Stop
            $activationInstaller = @'
$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:ProgramData 'MemLabs\OSDActivation.log'
function Write-FixLog { param([string]$Message); Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8 }
'@ + "`r`n" + $Payload.ActivationDefinition + @'

$savedPreference = $ErrorActionPreference
try { $ErrorActionPreference = 'Continue'; $result = & $MemLabsWindowsActivationScript }
finally { $ErrorActionPreference = $savedPreference }
if (-not $result -or -not $result.Success) { throw "Windows activation failed: $($result.Message)" }
'@
            Write-OsdFile "$activationRoot\Install.ps1" $activationInstaller
            $activationDetection = '$p = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationId=''55c92734-d682-4d71-983e-d6ec3f16059f'' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue; if (@($p | Where-Object LicenseStatus -eq 1).Count) { ''Activated'' }'
            $activationApp = New-OsdApplication $Payload.ActivationApplicationName "$sourceRoot\Activation" 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1' $activationDetection $allPaths
        }
        foreach ($definition in $Payload.Helpers) { . ([scriptblock]::Create("$definition")) }
        $privateSequences = @()
        foreach ($target in $Payload.Targets) {
            foreach ($sequence in $target.Sequences) {
                $currentApplicationSnapshot = Get-OsdInheritedApplicationSnapshot $templates[$sequence.SourceName] @($target.Paths)
                if (($currentApplicationSnapshot | ConvertTo-Json -Depth 8 -Compress) -ne ($applicationSnapshots[$sequence.SourceName] | ConvertTo-Json -Depth 8 -Compress)) {
                    Stop-OsdPrerequisite 'inherited application revision/content changed during private task-sequence preparation'
                }
                $copy = @(Copy-CMTaskSequence -InputObject $templates[$sequence.SourceName] -Confirm:$false -ErrorAction Stop)
                if ($copy.Count -ne 1 -or "$($copy[0].PackageID)" -notmatch "^$([regex]::Escape($Payload.SiteCode))[A-Za-z0-9]{5}$" -or
                    $copy[0].PackageID -in @($templates.Values.PackageID) -or $copy[0].PackageID -in @($privateSequences.PackageID)) {
                    throw "$tag Task-sequence copy did not return a NEW site-owned PackageID; nothing was modified through that result."
                }
                $newPackageId = "$($copy[0].PackageID)"
                $ts = Get-OsdOwnedTaskSequence $newPackageId
                $null = Set-CMTaskSequence -InputObject $ts -NewName $sequence.NewName -Description "Private OSD expansion $($Payload.ActionId) for $($target.vmName)" -ErrorAction Stop
                $ts = Get-OsdOwnedTaskSequence $newPackageId
                if ($ts.Name -ne $sequence.NewName) { throw "$tag New task sequence was not renamed to '$($sequence.NewName)'." }
                if (-not (Sync-MemLabsOsdComputerNameSteps -TaskSequences @($ts) -OsdClients @($target) -StatusTag $tag) -or
                    -not (Sync-MemLabsOsdBitLockerSteps -TaskSequences @($ts) -OsdClients @($target) -StatusTag $tag)) {
                    throw "$tag New task sequence '$($ts.PackageID)' failed target-specific naming/BitLocker read-back."
                }
                foreach ($oldOffice in @($ts | Get-CMTSStepInstallApplication -ErrorAction Stop | Where-Object { $_.Name -like 'MEMLABS install Office: *' })) {
                    $null = $ts | Remove-CMTSStepInstallApplication -StepName $oldOffice.Name -Force -ErrorAction Stop
                }
                if ($target.OfficeChannel) {
                    $condition = New-CMTSStepConditionQueryWmi -Namespace 'root\cimv2' -Query "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE MACAddress='$($target.osdMacAddress)'" -ErrorAction Stop
                    $step = New-CMTSStepInstallApplication -Name "MEMLABS install Office: $($target.OfficeChannel)" `
                        -Application $officeApps[$target.OfficeChannel] -Condition $condition -RetryCount 2 -ErrorAction Stop
                    $null = $ts | Add-CMTaskSequenceStep -Step @($step) -InsertStepStartIndex ([int]::MaxValue) -ErrorAction Stop
                }
                $expectedOfficeCount = 0
                if ($target.OfficeChannel) { $expectedOfficeCount = 1 }
                if (@($ts | Get-CMTSStepInstallApplication -ErrorAction Stop | Where-Object { $_.Name -like 'MEMLABS install Office: *' }).Count -ne $expectedOfficeCount) {
                    throw "$tag New task sequence '$($ts.PackageID)' failed Office read-back."
                }
                # References are regenerated by the native protected serializer.
                # Read the refreshed IResultObject's embedded array, not XML or
                # a projected/lazy References property.
                $referenceOwner = Get-OsdOwnedTaskSequence $newPackageId
                $packageReferences = @(
                    foreach ($reference in @($referenceOwner.GetArrayItems('References'))) {
                        $referenceType = -1
                        $typeProperty = $reference['Type']
                        if (-not $typeProperty -or -not [int]::TryParse("$($typeProperty.IntegerValue)", [ref]$referenceType)) {
                            throw "$tag New task sequence '$newPackageId' returned an unreadable native reference Type."
                        }
                        if ($referenceType -eq 0) { "$($reference['Package'].StringValue)" }
                    }
                ) | Select-Object -Unique
                if (-not @($packageReferences).Count) { throw "$tag New install task sequence '$newPackageId' returned no native type-0 package references." }
                foreach ($id in $packageReferences) {
                    $null = Test-OsdPackageInstalled (Get-OsdPackage $id) @($target.Paths)
                }
                $privateSequences += [pscustomobject]@{
                    PackageID = $newPackageId; SourceName = $sequence.SourceName; Target = "$($target.vmName)"; Required = [bool]$sequence.Required
                }
            }
        }

        # No Client=1 wait: these new machines do not boot until host Phase 8
        # workers finish. Waiting for client registration would deadlock setup.
        $registered = New-CMDeviceCollection -Name $Payload.RegisteredCollectionName -LimitingCollectionName 'All Systems' `
            -Comment "Private registered targets for OSD expansion $($Payload.ActionId)" -ErrorAction Stop
        if (-not $registered.CollectionID -or $registered.Name -ne $Payload.RegisteredCollectionName) {
            throw "$tag Registered-target collection returned no matching CollectionID."
        }
        $quoted = @($Payload.Targets | ForEach-Object { "'$($_.vmName)'" }) -join ','
        $query = "select SMS_R_System.ResourceID from SMS_R_System where SMS_R_System.Client = 1 and SMS_R_System.Name in ($quoted)"
        $null = Add-CMDeviceCollectionQueryMembershipRule -CollectionId $registered.CollectionID -RuleName 'Requested OSD clients after registration' -QueryExpression $query -ErrorAction Stop
        $rules = @(Get-CMDeviceCollectionQueryMembershipRule -CollectionId $registered.CollectionID -ErrorAction Stop)
        if ($rules.Count -ne 1 -or ($rules[0].QueryExpression -split '(?i)\bfrom\b', 2)[1].Trim() -ne ($query -split '(?i)\bfrom\b', 2)[1].Trim()) {
            throw "$tag Registered-target collection did not persist its exact requested-name query."
        }
        $null = Set-CMCollection -CollectionId $registered.CollectionID -RefreshType Both -ErrorAction Stop
        $null = New-CMApplicationDeployment -InputObject $bootstrapApp -Collection $registered -DeployAction Install -DeployPurpose Required -UserNotification HideAll -ErrorAction Stop
        if ($activationApp) {
            $null = New-CMApplicationDeployment -InputObject $activationApp -Collection $registered -DeployAction Install -DeployPurpose Required -UserNotification HideAll -ErrorAction Stop
        }
        foreach ($app in @($bootstrapApp, $activationApp) | Where-Object { $null -ne $_ }) {
            if (@(Get-CMApplicationDeployment -Application $app -Collection $registered -ErrorAction Stop).Count -ne 1) {
                throw "$tag New application policy '$($app.LocalizedDisplayName)' did not persist on the private registered-target collection."
            }
        }
        foreach ($target in $Payload.Targets) {
            foreach ($sourceName in @($privateSequences | Where-Object Target -eq $target.vmName | ForEach-Object { $_.SourceName } | Select-Object -Unique)) {
                $snapshot = Get-OsdInheritedApplicationSnapshot $templates[$sourceName] @($target.Paths)
                if (($snapshot | ConvertTo-Json -Depth 8 -Compress) -ne ($applicationSnapshots[$sourceName] | ConvertTo-Json -Depth 8 -Compress)) {
                    Stop-OsdPrerequisite 'inherited application revision/content changed before target import/deployment'
                }
            }
            $collection = New-CMDeviceCollection -Name $target.CollectionName -LimitingCollectionName 'All Systems' `
                -Comment "Only requested OSD target $($target.vmName); action $($Payload.ActionId)" -ErrorAction Stop
            if (-not $collection.CollectionID -or $collection.Name -ne $target.CollectionName) {
                throw "$tag Target collection returned no matching CollectionID for '$($target.vmName)'."
            }
            $null = Import-CMComputerInformation -ComputerName $target.vmName -MacAddress $target.osdMacAddress `
                -CollectionId $collection.CollectionID -ErrorAction Stop
            $deviceRows = @(Get-WmiObject -Namespace $ns -Class SMS_R_System -Filter "Name='$($target.vmName)'" -ErrorAction Stop)
            if ($deviceRows.Count -ne 1 -or [int]$deviceRows[0].ResourceID -le 0 -or
                $target.osdMacAddress -notin @($deviceRows[0].MACAddresses)) {
                throw "$tag New target '$($target.vmName)' import did not read back one matching resource/MAC."
            }
            $resourceId = "$($deviceRows[0].ResourceID)"
            $direct = @(Get-CMDeviceCollectionDirectMembershipRule -CollectionId $collection.CollectionID -ErrorAction Stop)
            if ($direct.Count -ne 1 -or "$($direct[0].ResourceID)" -ne $resourceId) {
                throw "$tag New target '$($target.vmName)' did not persist its sole targeted collection membership."
            }
            $null = New-CMDeviceVariable -DeviceId $resourceId -VariableName OSDComputerName -VariableValue $target.vmName -IsMask $false -ErrorAction Stop
            $variable = @(Get-CMDeviceVariable -ResourceId $resourceId -VariableName OSDComputerName -ErrorAction Stop)
            if ($variable.Count -ne 1) { throw "$tag OSDComputerName variable did not read back for '$($target.vmName)'." }
            if ($variable[0].IsMasked -eq $true) {
                throw "$tag OSDComputerName variable for '$($target.vmName)' is masked; it was left unchanged, without unmasking or repair."
            }
            if ($variable[0].Value -ne $target.vmName) { throw "$tag OSDComputerName variable did not read back for '$($target.vmName)'." }
            foreach ($sequence in @($privateSequences | Where-Object { $_.Target -eq $target.vmName })) {
                $arguments = @{
                    TaskSequencePackageId = $sequence.PackageID; CollectionId = $collection.CollectionID
                    DeployPurpose = 'Available'; MakeAvailableTo = 'ClientsMediaAndPxe'; ErrorAction = 'Stop'
                }
                if ($sequence.Required) {
                    $arguments.DeployPurpose = 'Required'
                    $arguments.RerunBehavior = 'RerunIfFailedPreviousAttempt'
                    $arguments.AvailableDateTime = (Get-Date).AddMinutes(-5)
                    $arguments.ScheduleEvent = 'AsSoonAsPossible'
                }
                $null = New-CMTaskSequenceDeployment @arguments
                $advertisements = @(Get-WmiObject -Namespace $ns -Class SMS_Advertisement `
                        -Filter "PackageID='$($sequence.PackageID)' AND CollectionID='$($collection.CollectionID)'" -ErrorAction Stop)
                if ($advertisements.Count -ne 1 -or ([int]$advertisements[0].AdvertFlags -band 0x40000) -ne 0x40000) {
                    throw "$tag New task sequence '$($sequence.PackageID)' did not persist one PXE-visible SMS_Advertisement for '$($target.vmName)'."
                }
            }
            $null = Invoke-CMCollectionUpdate -CollectionId $collection.CollectionID -ErrorAction Stop
        }
        $null = Invoke-CMCollectionUpdate -CollectionId $registered.CollectionID -ErrorAction Stop
        [pscustomobject]@{ Status = 'Submitted'; TargetVMNames = @($Payload.Targets.vmName) }
    }

    $actions = @()
    foreach ($group in @($groups.Values | Sort-Object { $_.Owner.vmName })) {
        $actionId = [guid]::NewGuid().ToString('N')
        $prefix = "MEMLABS-Expansion-$actionId"
        $applicationNames = @("$prefix-OSD Bootstrap")
        foreach ($target in $group.Targets) {
            $target | Add-Member -NotePropertyName CollectionName -NotePropertyValue "$prefix-$($target.vmName)"
            $sequences = @()
            foreach ($sourceName in $target.SourceTaskSequenceNames) {
                $version = 'w11'
                if ($sourceName -eq 'MEMLABS-w10-Install OS image') { $version = 'w10' }
                $sequences += [pscustomobject]@{
                    SourceName = $sourceName
                    # The task-sequence package Name is limited to 50 characters.
                    NewName = "MEMLABS-$version-$($target.vmName)-$($actionId.Substring(0, 5))-Install OS image"
                    Required = [bool]$target.SelectedTaskSequence
                }
            }
            $target | Add-Member -NotePropertyName Sequences -NotePropertyValue @($sequences)
            if ($target.OfficeChannel) { $applicationNames += "$prefix-Office-$($target.OfficeChannel)" }
        }
        $enableActivation = $DeployConfig.parameters.IsAzureVM -eq $true
        if ($enableActivation) { $applicationNames += "$prefix-OSD Activation" }
        $ownerFqdn = "$($group.Owner.vmName)"
        if (-not $ownerFqdn.Contains('.')) { $ownerFqdn = "$ownerFqdn.$($group.Domain)" }
        $relays = @()
        foreach ($relayName in @($group.Targets.Paths | Where-Object Mode -eq Relay | ForEach-Object RelayVM | Select-Object -Unique)) {
            $relay = @($DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $relayName })
            if ($relay.Count -ne 1 -or $relay[0].role -ne 'DHCPRelay' -or
                -not ($relay[0].osFamily -eq 'Linux' -or "$($relay[0].operatingSystem)" -like 'Ubuntu*')) {
                throw "Required OSD relay '$relayName' does not have one explicit Linux DHCPRelay VM record."
            }
            $managementNetwork = "$($relay[0].network)"
            if (-not $managementNetwork -and $relay[0].thisParams) { $managementNetwork = "$($relay[0].thisParams.vmNetwork)" }
            if (-not $managementNetwork) { $managementNetwork = "$($DeployConfig.vmOptions.network)" }
            $managementAddress = $null
            if (-not [Net.IPAddress]::TryParse($managementNetwork, [ref]$managementAddress) -or
                $managementAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $managementAddress.GetAddressBytes()[3] -ne 0) {
                throw "Required OSD relay '$relayName' has unsupported management network '$managementNetwork'."
            }
            $relays += [pscustomobject]@{
                VMName = "$relayName"
                ManagementNetwork = $managementNetwork
                # This is the shipped DHCPRelay role's fixed address, not DNS.
                ManagementIPv4 = ($managementNetwork -replace '\.0$', '.4')
                IsExisting = ($relay[0].hidden -eq $true -or $relay[0].ExistingVM -eq $true)
            }
        }
        $payload = [pscustomobject]@{
            ActionId = $actionId
            NamePrefix = $prefix
            SiteCode = "$($group.Owner.siteCode)"
            OwnerVMName = "$($group.Owner.vmName)"
            OwnerFqdn = $ownerFqdn
            Targets = @($group.Targets)
            Relays = @($relays)
            BootstrapApplicationName = "$prefix-OSD Bootstrap"
            ActivationApplicationName = "$prefix-OSD Activation"
            RegisteredCollectionName = "$prefix-Registered OSD"
            ApplicationNames = @($applicationNames | Select-Object -Unique)
            EnableAzureActivation = $enableActivation
            Helpers = @($helpers)
            BootstrapInstaller = $bootstrapInstaller
            DiskInitializer = $diskInitializer
            ActivationDefinition = $activationDefinition
        }
        $actions += [pscustomobject]@{
            Kind = 'Osd'
            OwnerVMName = "$($group.Owner.vmName)"
            SiteCode = "$($group.Owner.siteCode)"
            TargetVMNames = @($group.Targets.vmName)
            Payload = $payload
            Handler = $handler
            HostPreflight = $hostPreflight
            TimeoutSeconds = 7200
        }
    }
    return $actions
}
