#requires -Version 5.1
<#
.SYNOPSIS
    Runs the shipped scoped OSD planner and its JSON-round-tripped guest handler.
.DESCRIPTION
    Every guest I/O, provider, process and mutation command is mocked. No lab
    operation is performed. Use -GuestOnly for the Windows PowerShell 5.1 leg.
#>
[CmdletBinding()]
param([string]$RootPath, [switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0
function Assert-OsdTest {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-OsdThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-OsdTest ($failure -like $Pattern) "$Message -- actual failure: '$failure'."
}
function Import-OsdTestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse failed: $Path; $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one '$Name' definition." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
foreach ($name in @('Test-MemLabsContextOnlyVM', 'Get-MemLabsRequestedDeploymentVMs', 'Resolve-MemLabsDeploymentPrimary')) {
    . (Import-OsdTestFunction $configPath $name)
}
foreach ($name in @('Get-MemLabsEnabledTaskSequenceApplications', 'Get-MemLabsApplicationContentSnapshot')) {
    . (Import-OsdTestFunction (Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1') $name)
}
. (Join-Path $RootPath 'common\Common.ExistingHierarchy.Osd.ps1')
if (-not ('Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Microsoft.ConfigurationManagement.ApplicationManagement.Serialization {
    public sealed class InstallerDefinition {
        public object[] Contents { get; set; }
        public object InstallContent { get; set; }
        public InstallerDefinition() { Contents = new object[0]; }
    }
    public sealed class DeploymentDefinition {
        public string Id { get; set; }
        public InstallerDefinition Installer { get; set; }
        public DeploymentDefinition() { Id = "dt:1"; Installer = new InstallerDefinition(); }
    }
    public sealed class ApplicationDefinition {
        public DeploymentDefinition[] DeploymentTypes { get; set; }
        public ApplicationDefinition() { DeploymentTypes = new[] { new DeploymentDefinition() }; }
    }
    public static class SccmSerializer {
        public static ApplicationDefinition DeserializeFromString(string xml) {
            var result = new ApplicationDefinition();
            if (xml == "CONTENTLESS-MISMATCH") result.DeploymentTypes[0].Id = "dt:99";
            else if (xml == "CONTENTFUL-FIXTURE") result.DeploymentTypes[0].Installer.Contents = new object[] { new object() };
            else if (xml == "CONTENTLESS-MIXED") {
                var sibling = new DeploymentDefinition { Id = "dt:2" };
                sibling.Installer.Contents = new object[] { new object() };
                sibling.Installer.InstallContent = new object();
                result.DeploymentTypes = new[] { result.DeploymentTypes[0], sibling };
            }
            else if (xml != "CONTENTLESS-FIXTURE") throw new System.InvalidOperationException("Unexpected fixture definition");
            return result;
        }
    }
}
'@
}

function New-OsdTestConfig {
    [pscustomobject]@{
        parameters = [pscustomobject]@{ domainName = 'fixture.test'; IsAzureVM = $true }
        vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; network = '192.168.1.0' }
        virtualMachines = @(
            [pscustomobject]@{ vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; hidden = $true }
            [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'; hidden = $true }
            [pscustomobject]@{ vmName = 'PRI2'; role = 'Primary'; siteCode = 'P02'; parentSiteCode = 'CAS'; hidden = $true }
            [pscustomobject]@{ vmName = 'DPA'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true; hidden = $true; network = '192.168.1.0' }
            [pscustomobject]@{ vmName = 'DPB'; role = 'SiteSystem'; siteCode = 'P02'; installDP = $true; hidden = $true; network = '192.168.2.0' }
            [pscustomobject]@{ vmName = 'SEC1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; hidden = $true; installDP = $true; network = '192.168.3.0' }
            [pscustomobject]@{ vmName = 'OSD1'; role = 'OSDClient'; network = '192.168.1.0'; osdMacAddress = '00:15:5D:00:00:01'; osdTaskSequence = 'MEMLABS-w11-Install OS image'; installOffice = 'Current'; BitLocker = $true; additionalDisks = [pscustomobject][ordered]@{ E = [long](20GB); F = [long](30GB) } }
            [pscustomobject]@{ vmName = 'OSD2'; role = 'OSDClient'; network = '192.168.2.0'; osdMacAddress = '00:15:5D:00:00:02'; osdTaskSequence = 'MEMLABS-w10-Install OS image'; installOffice = 'SemiAnnual' }
            [pscustomobject]@{ vmName = 'OSD3'; role = 'OSDClient'; network = '192.168.3.0'; osdMacAddress = '00:15:5D:00:00:03'; osdTaskSequence = $null; installOffice = $false; BitLocker = $false }
            [pscustomobject]@{ vmName = 'OLDOSD'; role = 'OSDClient'; hidden = $true; network = '192.168.9.0'; osdMacAddress = 'invalid'; osdTaskSequence = 'deliberately broken' }
        )
        osdPxePaths = @(
            [pscustomobject]@{ clientNetwork = '192.168.1.0'; mode = 'Direct'; distributionPointVM = 'DPA'; distributionPointSiteCode = 'PRI' }
            [pscustomobject]@{ clientNetwork = '192.168.2.0'; mode = 'Direct'; distributionPointVM = 'DPB'; distributionPointSiteCode = 'P02' }
            [pscustomobject]@{ clientNetwork = '192.168.3.0'; mode = 'Direct'; distributionPointVM = 'SEC1'; distributionPointSiteCode = 'SEC' }
            [pscustomobject]@{ clientNetwork = '192.168.9.0'; mode = 'Invalid'; reason = 'intentional customer reproduction' }
        )
    }
}
$config = New-OsdTestConfig
$before = $config | ConvertTo-Json -Depth 30 -Compress
$plans = @(Get-MemLabsExistingOsdActions -DeployConfig $config)
$primaryPlan = @($plans | Where-Object SiteCode -eq PRI)[0]
$otherPlan = @($plans | Where-Object SiteCode -eq P02)[0]
$singleConfig = New-OsdTestConfig
$singleConfig.virtualMachines = @($singleConfig.virtualMachines | Where-Object { $_.vmName -notin @('OSD2', 'OSD3') })
$singlePlan = @(Get-MemLabsExistingOsdActions -DeployConfig $singleConfig)[0]
if (-not $GuestOnly) {
    Assert-OsdTest (($config | ConvertTo-Json -Depth 30 -Compress) -eq $before) 'Planning changed the input configuration.'
    Assert-OsdTest ($plans.Count -eq 2 -and $primaryPlan.Kind -eq 'Osd' -and $primaryPlan.OwnerVMName -eq 'PRI1') 'Planning did not isolate the owning existing Primaries.'
    Assert-OsdTest (($primaryPlan.TargetVMNames -join ',') -eq 'OSD1,OSD3' -and ($otherPlan.TargetVMNames -join ',') -eq 'OSD2') 'Secondary ownership or exact requested target filtering is wrong.'
    Assert-OsdTest ($primaryPlan.Payload.Targets[0].Sequences.Count -eq 1 -and $primaryPlan.Payload.Targets[1].Sequences.Count -eq 2) 'Selected and PXE-prompt task-sequence choices were not preserved.'
    Assert-OsdTest ($primaryPlan.Payload.Targets[0].Disks[1].SizeBytes -eq 30GB -and $primaryPlan.Payload.Targets[0].BitLocker) 'Per-target disk/BitLocker payload was lost.'
    Assert-OsdTest ($primaryPlan.TimeoutSeconds -le 7200 -and $primaryPlan.TimeoutSeconds -gt 0) 'The action has no finite parent timeout.'
    $early = New-OsdTestConfig
    foreach ($vm in $early.virtualMachines | Where-Object { $_.role -eq 'OSDClient' -and -not $_.hidden }) { $vm.PSObject.Properties.Remove('osdMacAddress') }
    Assert-OsdTest (@(Get-MemLabsExistingOsdActions -DeployConfig $early).Count -eq 2) 'Early owner/mutex planning requires NICs that Phase 1 has not created.'
    $empty = New-OsdTestConfig
    $empty.virtualMachines = @($empty.virtualMachines | Where-Object { $_.role -ne 'OSDClient' -or $_.hidden })
    Assert-OsdTest (@(Get-MemLabsExistingOsdActions -DeployConfig $empty).Count -eq 0) 'Context-only OSD clients scheduled an action.'
    $bare = [pscustomobject]@{ virtualMachines = @([pscustomobject]@{ vmName = 'BARE1'; role = 'OSDClient' }) }
    Assert-OsdTest (@(Get-MemLabsExistingOsdActions -DeployConfig $bare).Count -eq 0) 'An empty VM without ConfigMgr scheduled provider work.'
    $newOwner = New-OsdTestConfig
    foreach ($vm in $newOwner.virtualMachines | Where-Object role -eq Primary) { $vm.hidden = $false }
    Assert-OsdTest (@(Get-MemLabsExistingOsdActions -DeployConfig $newOwner).Count -eq 0) 'A new Primary was taken away from ordinary Phase 8.'
    $bad = New-OsdTestConfig
    $bad.virtualMachines[6].osdTaskSequence = 'MEMLABS-Custom TS Example'
    Assert-OsdThrows { Get-MemLabsExistingOsdActions -DeployConfig $bad } '*unsupported task sequence*' 'Unsupported explicit selection was silently changed.'
    $bad = New-OsdTestConfig
    $bad.osdPxePaths[0].distributionPointSiteCode = 'XXX'
    Assert-OsdThrows { Get-MemLabsExistingOsdActions -DeployConfig $bad } '*Cannot resolve one Primary owner*' 'An ambiguous/missing owner was guessed.'
    $bad = New-OsdTestConfig
    $bad.virtualMachines[7].osdMacAddress = $bad.virtualMachines[6].osdMacAddress
    Assert-OsdThrows { Get-MemLabsExistingOsdActions -DeployConfig $bad } '*duplicate*' 'Cross-owner duplicate MACs were accepted.'
    $bad = New-OsdTestConfig
    $bad.virtualMachines[6].additionalDisks = [pscustomobject]@{ S = 20GB }
    Assert-OsdThrows { Get-MemLabsExistingOsdActions -DeployConfig $bad } '*invalid additional disk*' 'A reserved data-disk letter was accepted.'
    $longName = New-OsdTestConfig
    $longName.virtualMachines[6].vmName = 'OSDCLIENT-12345'
    $longPlan = @(Get-MemLabsExistingOsdActions -DeployConfig $longName | Where-Object SiteCode -eq PRI)[0]
    Assert-OsdTest (@($longPlan.Payload.Targets.Sequences | Where-Object { $_.NewName.Length -gt 50 }).Count -eq 0) 'A supported 15-character target name creates a task-sequence name beyond the provider limit.'

    $relayConfig = New-OsdTestConfig
    foreach ($row in @(
            @{ Index = 0; TargetIndex = 6; Name = 'RELAY1'; Network = '192.168.10.0'; RelayIP = '192.168.10.4'; DPIP = '192.168.1.25'; Management = '192.168.1.0' }
            @{ Index = 1; TargetIndex = 7; Name = 'RELAY2'; Network = '192.168.20.0'; RelayIP = '192.168.20.4'; DPIP = '192.168.2.25'; Management = '192.168.2.0' }
        )) {
        $relayConfig.virtualMachines[$row.TargetIndex].network = $row.Network
        $path = $relayConfig.osdPxePaths[$row.Index]
        $path.clientNetwork = $row.Network
        $path.mode = 'Relay'
        $path | Add-Member -NotePropertyName relayVM -NotePropertyValue $row.Name
        $path | Add-Member -NotePropertyName relayIPv4 -NotePropertyValue $row.RelayIP
        $path | Add-Member -NotePropertyName distributionPointIPv4 -NotePropertyValue $row.DPIP
        $relayConfig.virtualMachines += [pscustomobject]@{
            vmName = $row.Name; role = 'DHCPRelay'; hidden = $true; osFamily = 'Linux'; network = $row.Management
        }
    }
    $relayConfig.virtualMachines += [pscustomobject]@{ vmName = 'BROKEN-UNRELATED'; role = 'DHCPRelay'; hidden = $true; osFamily = 'Linux'; network = 'invalid' }
    $relayConfig.virtualMachines += [pscustomobject]@{ vmName = 'OSD4'; role = 'OSDClient'; network = '192.168.10.0'; osdMacAddress = '00:15:5D:00:00:04' }
    $relaySnapshot = $relayConfig | ConvertTo-Json -Depth 30 -Compress
    $relayPlans = @(Get-MemLabsExistingOsdActions -DeployConfig $relayConfig)
    $relayPlan = @($relayPlans | Where-Object SiteCode -eq PRI)[0]
    $relayOtherPlan = @($relayPlans | Where-Object SiteCode -eq P02)[0]
    Assert-OsdTest (($relayConfig | ConvertTo-Json -Depth 30 -Compress) -eq $relaySnapshot) 'Relay planning mutated input metadata.'
    Assert-OsdTest (($relayPlan.Payload.Relays.VMName -join ',') -eq 'RELAY1' -and
        ($relayOtherPlan.Payload.Relays.VMName -join ',') -eq 'RELAY2') 'Relay prerequisites include unrelated relays or cross owning Primaries.'
    foreach ($vm in $relayConfig.virtualMachines | Where-Object { $_.role -eq 'OSDClient' -and -not $_.hidden }) { $vm.PSObject.Properties.Remove('osdMacAddress') }
    Assert-OsdTest (@(Get-MemLabsExistingOsdActions -DeployConfig $relayConfig).Count -eq 2) 'Early relay owner planning requires target MACs or live relay NICs.'

    function Invoke-OsdRelayHostTest {
        param([string]$Mode = 'Ready', $Plan = $relayPlan)
        & {
            param($Mode, $Plan)
            $payload = $Plan.Payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            if ($Mode -eq 'NewRelayAlreadySynced') { foreach ($relay in $payload.Relays) { $relay.IsExisting = $false } }
            if ($Mode -eq 'UnresolvedDP') { $payload.Targets[0].Paths[0].DPIPv4 = '' }
            if ($Mode -eq 'MissingSerializedRelay') { $payload.Relays = @() }
            if ($Mode -eq 'UnrequiredSerializedRelay') {
                $payload.Relays += [pscustomobject]@{ VMName = 'BROKEN-UNRELATED'; ManagementIPv4 = '192.168.99.4'; ManagementNetwork = '192.168.99.0' }
            }
            $before = $payload | ConvertTo-Json -Depth 30 -Compress
            $Common = [pscustomobject]@{ CachePath = 'C:\fixture-cache' }
            $script:RelayState = [pscustomobject]@{
                Mode = $Mode; Payload = $payload; VMReads = @(); AuthReads = 0; Started = 0; Disposed = 0
                Writes = 0; GuestCalls = 0; Script = ''; Killed = @()
                Existing = [pscustomobject]@{ Service = 'Keep exactly'; Config = 'Keep unrelated mappings'; Key = 'Keep bytes and ACL'; Adapters = 'Keep all'; VM = 'Keep power state' }
            }
            $existingBefore = $script:RelayState.Existing | ConvertTo-Json -Compress
            function Find-OpenSshTool { param($Name); if ($script:RelayState.Mode -ne 'MissingSsh') { return 'C:\fixture-ssh\ssh.exe' } }
            function Test-Path { [CmdletBinding()]param($LiteralPath, $PathType); return $script:RelayState.Mode -ne 'MissingKey' }
            function Get-VM2 {
                [CmdletBinding()]param($Name)
                $script:RelayState.VMReads += $Name
                if ($Name -notin @($script:RelayState.Payload.Relays.VMName)) { throw "Unrelated VM observation '$Name'." }
                if ($script:RelayState.Mode -eq 'MissingRelay') { return }
                [pscustomobject]@{ Name = $Name; State = $(if ($script:RelayState.Mode -eq 'StoppedRelay') { 'Off' } else { 'Running' }) }
            }
            function Get-VMNetworkAdapter {
                [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$VM)
                process {
                    $relay = @($script:RelayState.Payload.Relays | Where-Object VMName -eq $VM.Name)[0]
                    if ($script:RelayState.Mode -ne 'MissingManagementNIC') {
                        [pscustomobject]@{ SwitchName = $relay.ManagementNetwork; MacAddress = '00155D010001' }
                    }
                    $paths = @($script:RelayState.Payload.Targets.Paths | Where-Object RelayVM -eq $VM.Name | Sort-Object ClientNetwork -Unique)
                    foreach ($path in $paths) {
                        if ($script:RelayState.Mode -eq 'MissingClientNIC') { continue }
                        [pscustomobject]@{ SwitchName = $path.ClientNetwork; MacAddress = $(if ($script:RelayState.Mode -eq 'MissingClientMAC') { '' } else { '00155D100004' }) }
                        if ($script:RelayState.Mode -eq 'DuplicateClientNIC') { [pscustomobject]@{ SwitchName = $path.ClientNetwork; MacAddress = '00155D100005' } }
                    }
                    [pscustomobject]@{ SwitchName = 'UNRELATED-OLD-SWITCH'; MacAddress = '00155D990004' }
                }
            }
            function Invoke-LinuxSshReadyProbe {
                param($SshExe, $PrivateKeyPath, $IPAddress, $TimeoutSeconds)
                if ($SshExe -ne 'C:\fixture-ssh\ssh.exe' -or $PrivateKeyPath -ne 'C:\fixture-cache\ssh\memlabs_ed25519' -or
                    $IPAddress -notin @($script:RelayState.Payload.Relays.ManagementIPv4) -or $TimeoutSeconds -gt 10) { throw 'Unscoped/unbounded existing-key SSH probe.' }
                $script:RelayState.AuthReads++
                if ($script:RelayState.Mode -eq 'MissingAuthExit') { return [pscustomobject]@{ Output = 'not a native receipt' } }
                [pscustomobject]@{
                    ExitCode = $(if ($script:RelayState.Mode -eq 'AuthFailure') { 255 } else { 0 })
                    TimedOut = ($script:RelayState.Mode -eq 'AuthTimeout')
                }
            }
            function New-Object {
                [CmdletBinding()]param($TypeName)
                if ($TypeName -ne 'System.Diagnostics.Process') { throw "Unexpected construction '$TypeName'." }
                $inputStream = [pscustomobject]@{}
                $inputStream | Add-Member -MemberType ScriptMethod -Name WriteAsync -Value {
                    param($Text)
                    $script:RelayState.Script = $Text
                    $task = [pscustomobject]@{}
                    $task | Add-Member -MemberType ScriptMethod -Name Wait -Value {
                        param($Milliseconds)
                        if ($Milliseconds -gt 10000 -or $Milliseconds -le 0) { throw 'Unbounded native input.' }
                        return $script:RelayState.Mode -ne 'NativeInputTimeout'
                    }
                    return $task
                }
                $inputStream | Add-Member -MemberType ScriptMethod -Name Close -Value { }
                $outputStream = [pscustomobject]@{}
                $outputStream | Add-Member -MemberType ScriptMethod -Name ReadToEndAsync -Value {
                    $text = "MEMLABS_OSD_RELAY_READY mappings=1`n"
                    if ($script:RelayState.Mode -eq 'NoReadinessMarker') { $text = 'some unrelated success' }
                    $task = [pscustomobject]@{ Result = $text; IsCompleted = $true }
                    $task | Add-Member -MemberType ScriptMethod -Name Wait -Value { param($Milliseconds); return $script:RelayState.Mode -ne 'NativeOutputTimeout' }
                    return $task
                }
                $errorStream = [pscustomobject]@{}
                $errorStream | Add-Member -MemberType ScriptMethod -Name ReadToEndAsync -Value {
                    $task = [pscustomobject]@{ Result = 'OSD relay blocked: required mapping is absent'; IsCompleted = $true }
                    $task | Add-Member -MemberType ScriptMethod -Name Wait -Value { param($Milliseconds); return $true }
                    return $task
                }
                $process = [pscustomobject]@{
                    StartInfo = $null; Id = 90909; StandardInput = $inputStream; StandardOutput = $outputStream; StandardError = $errorStream
                    ExitCode = $(if ($script:RelayState.Mode -eq 'NativeObservationFailure') { 23 } else { 0 })
                }
                $process | Add-Member -MemberType ScriptMethod -Name Start -Value {
                    if ($this.StartInfo.FileName -ne 'C:\fixture-ssh\ssh.exe' -or
                        'UserKnownHostsFile=NUL' -notin $this.StartInfo.ArgumentList -or '-F' -notin $this.StartInfo.ArgumentList) {
                        throw 'Observation SSH may write known_hosts or load local-command configuration.'
                    }
                    $script:RelayState.Started++
                    return $true
                }
                $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                    param($Milliseconds)
                    if ($Milliseconds -gt 60000 -or $Milliseconds -le 0) { throw 'Unbounded native relay observation.' }
                    return $script:RelayState.Mode -ne 'NativeObservationTimeout'
                }
                $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:RelayState.Disposed++ }
                return $process
            }
            function Stop-Process {
                [CmdletBinding()]param($Id, [switch]$Force)
                if ($Id -ne 90909) { throw 'Stopped an unrelated process.' }
                $script:RelayState.Killed += $Id
            }
            foreach ($forbidden in @(
                    'Get-LinuxAdminSshKeyPair', 'Repair-LinuxAdminSshKeyPair', 'Set-LinuxSshPrivateKeyAcl', 'Get-LinuxSshExePath',
                    'Get-OpenSshToolPath', 'Install-OpenSshClientFeature', 'Sync-LinuxDhcpRelay', 'Invoke-LinuxVmCommand',
                    'Wait-LinuxVmReady', 'Start-VM2', 'Start-VM', 'Restart-VM', 'Stop-VM', 'Set-VM', 'Add-VMNetworkAdapter',
                    'Set-VMNetworkAdapter', 'Connect-VMNetworkAdapter', 'New-Item', 'Set-Content', 'Copy-Item', 'Remove-Item', 'Set-Acl'
                )) {
                Set-Item -Path "Function:\$forbidden" -Value { $script:RelayState.Writes++; throw 'Forbidden relay/host prerequisite repair.' }
            }
            $failure = ''; $receipt = $null
            try {
                $receipt = & ([scriptblock]::Create($Plan.HostPreflight.ToString())) $payload
                $script:RelayState.GuestCalls++ # The runner may now invoke the guest handler.
            }
            catch { $failure = $_.Exception.Message }
            Assert-OsdTest (($payload | ConvertTo-Json -Depth 30 -Compress) -eq $before) "Host preflight changed its serialized inputs in '$Mode'."
            Assert-OsdTest (($script:RelayState.Existing | ConvertTo-Json -Compress) -eq $existingBefore -and $script:RelayState.Writes -eq 0) "Host preflight mutated retained state in '$Mode'."
            if ($Mode -in @('Ready', 'NewRelayAlreadySynced')) {
                Assert-OsdTest (-not $failure -and $script:RelayState.GuestCalls -eq 1) "Read-only relay readiness failed in '$Mode': $failure"
                if ($payload.Relays.Count) {
                    Assert-OsdTest ($receipt.Status -eq 'Verified' -and ($receipt.RelayVMNames -join ',') -eq ($payload.Relays.VMName -join ',')) 'Relay receipt escaped the exact declared prerequisite scope.'
                }
                else { Assert-OsdTest ($script:RelayState.VMReads.Count -eq 0 -and $script:RelayState.Started -eq 0) 'A direct PXE path observed unrelated relays.' }
            }
            else { Assert-OsdTest ($failure -and $script:RelayState.GuestCalls -eq 0) "Broken relay '$Mode' did not stop before guest mutations." }
            [pscustomobject]@{ State = $script:RelayState; Failure = $failure; Receipt = $receipt }
        } $Mode $Plan
    }
    $relayReady = Invoke-OsdRelayHostTest
    Assert-OsdTest (($relayReady.State.VMReads -join ',') -eq 'RELAY1' -and $relayReady.State.AuthReads -eq 1 -and $relayReady.State.Disposed -eq 1) 'Duplicate clients caused repeated relay probes, or native observation was not disposed.'
    $null = Invoke-OsdRelayHostTest -Plan $relayOtherPlan
    $null = Invoke-OsdRelayHostTest -Mode NewRelayAlreadySynced
    $null = Invoke-OsdRelayHostTest -Plan $singlePlan
    foreach ($case in @(
            @{ Mode = 'MissingSsh'; Pattern = '*ssh.exe is unavailable*Nothing was installed*' }
            @{ Mode = 'MissingKey'; Pattern = '*SSH private key is unavailable*no key was generated*' }
            @{ Mode = 'MissingRelay'; Pattern = '*RELAY1*not Running*' }
            @{ Mode = 'StoppedRelay'; Pattern = '*RELAY1*not Running*' }
            @{ Mode = 'MissingManagementNIC'; Pattern = '*RELAY1*management adapter*found 0*' }
            @{ Mode = 'MissingClientNIC'; Pattern = '*RELAY1*required client switch*found 0*' }
            @{ Mode = 'DuplicateClientNIC'; Pattern = '*RELAY1*required client switch*found 2*' }
            @{ Mode = 'MissingClientMAC'; Pattern = '*RELAY1*client adapter MAC is unavailable*' }
            @{ Mode = 'UnresolvedDP'; Pattern = '*RELAY1*no explicit valid relay/DP IPv4*' }
            @{ Mode = 'MissingSerializedRelay'; Pattern = '*Serialized relay prerequisites do not match*' }
            @{ Mode = 'UnrequiredSerializedRelay'; Pattern = '*Serialized relay prerequisites do not match*' }
            @{ Mode = 'AuthFailure'; Pattern = '*RELAY1*SSH authentication failed*not repaired*' }
            @{ Mode = 'AuthTimeout'; Pattern = '*RELAY1*SSH authentication failed or timed out*' }
            @{ Mode = 'MissingAuthExit'; Pattern = '*RELAY1*SSH authentication failed*' }
            @{ Mode = 'NativeObservationFailure'; Pattern = '*RELAY1*exited 23*required mapping is absent*' }
            @{ Mode = 'NativeObservationTimeout'; Pattern = '*RELAY1*bounded timeout*' }
            @{ Mode = 'NativeInputTimeout'; Pattern = '*RELAY1*input exceeded its bounded timeout*' }
            @{ Mode = 'NativeOutputTimeout'; Pattern = '*RELAY1*output exceeded its bounded timeout*' }
            @{ Mode = 'NoReadinessMarker'; Pattern = '*RELAY1*did not confirm every required mapping*' }
        )) {
        $blocked = Invoke-OsdRelayHostTest -Mode $case.Mode
        Assert-OsdTest ($blocked.Failure -like $case.Pattern) "Relay blocker '$($case.Mode)' lost specific evidence: $($blocked.Failure)"
        if ($case.Mode -in @('NativeObservationTimeout', 'NativeInputTimeout')) {
            Assert-OsdTest (($blocked.State.Killed -join ',') -eq '90909' -and $blocked.State.Disposed -eq 1) 'Timed-out observation stopped anything other than its own SSH process or leaked the handle.'
        }
    }

    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw 'Git Bash is required to execute the shipped read-only relay probe against command mocks.' }
    $bashMocks = @'
ip() {
    case "$*" in
        '-o link show') printf '%s\n' '2: eth0: <UP> link/ether 00:15:5d:01:00:01 brd ff:ff:ff:ff:ff:ff' '3: eth1: <UP> link/ether 00:15:5d:10:00:04 brd ff:ff:ff:ff:ff:ff' ;;
        '-4 -o address show dev eth0') printf '%s\n' '2: eth0 inet 192.168.1.4/24 scope global eth0' ;;
        '-4 -o address show dev eth1')
            if [ "$OSD_BASH_MODE" != BadAddress ]; then printf '%s\n' '3: eth1 inet 192.168.10.4/24 scope global eth1'; fi ;;
        '-4 route show default') printf '%s\n' 'default via 192.168.1.200 dev eth0' ;;
        '-4 route get 192.168.1.25')
            if [ "$OSD_BASH_MODE" = BadTargetRoute ]; then printf '%s\n' '192.168.1.25 dev unrelated0'
            else printf '%s\n' '192.168.1.25 dev eth0 src 192.168.1.4'; fi ;;
        *) printf 'FORBIDDEN ip %s\n' "$*" >&2; return 97 ;;
    esac
}
sysctl() { [ "$*" = '-n net.ipv4.ip_forward' ] || return 97; printf '0\n'; }
function /usr/sbin/dnsmasq {
    [ "$*" = '--test --conf-file=/etc/memlabs-dhcp-relay.conf' ] || return 97
    [ "$OSD_BASH_MODE" != InvalidConfig ]
}
systemctl() {
    case "$*" in
        'is-enabled --quiet memlabs-dhcp-relay.service') return 0 ;;
        'is-active --quiet memlabs-dhcp-relay.service') [ "$OSD_BASH_MODE" != StoppedService ] ;;
        'show --property MainPID --value memlabs-dhcp-relay.service') printf '321\n' ;;
        *) printf 'FORBIDDEN systemctl %s\n' "$*" >&2; return 97 ;;
    esac
}
ss() {
    [ "$*" = '-H -lunp' ] || return 97
    if [ "$OSD_BASH_MODE" = WrongListenerOwner ]; then printf '%s\n' 'UNCONN 0 0 0.0.0.0:67 0.0.0.0:* users:(("other",pid=999,fd=6))'
    else printf '%s\n' 'UNCONN 0 0 0.0.0.0:67 0.0.0.0:* users:(("dnsmasq",pid=321,fd=6))'; fi
}
grep() {
    if [ "$1" = -Fxc ] && [ "${3:-}" = /etc/memlabs-dhcp-relay.conf ]; then
        [ "$2" = 'dhcp-relay=192.168.10.4,192.168.1.25' ] || return 97
        case "$OSD_BASH_MODE" in
            MissingMapping) printf '0\n'; return 1 ;;
            DuplicateMapping) printf '2\n'; return 0 ;;
            *) printf '1\n'; return 0 ;;
        esac
    fi
    command grep "$@"
}
for mutator in mktemp rm mv mkdir touch tee cp chmod chown apt-get reboot sudo install netplan; do
    eval "$mutator() { printf 'FORBIDDEN mutation $mutator\n' >&2; return 97; }"
done
'@
    foreach ($mode in @('Ready', 'BadAddress', 'BadTargetRoute', 'InvalidConfig', 'StoppedService', 'WrongListenerOwner', 'MissingMapping', 'DuplicateMapping')) {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $bash
        foreach ($argument in @('--noprofile', '--norc', '-s')) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        try {
            $process.StartInfo = $info
            if (-not $process.Start()) { throw 'Could not start Bash command mocks.' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write(("OSD_BASH_MODE='$mode'`n$bashMocks`n$($relayReady.State.Script)" -replace "`r", ''))
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(15000)) { Stop-Process -Id $process.Id -Force; throw 'Bash command mocks exceeded 15s.' }
            $output = "$($stdout.Result)`n$($stderr.Result)"
            Assert-OsdTest ($output -notlike '*FORBIDDEN*') "Relay observation attempted an unapproved operation in Bash '$mode': $output"
            if ($mode -eq 'Ready') {
                Assert-OsdTest ($process.ExitCode -eq 0 -and $output -like '*MEMLABS_OSD_RELAY_READY mappings=1*') "The exact shipped relay query did not execute successfully under Bash mocks: $output"
            }
            else {
                Assert-OsdTest ($process.ExitCode -ne 0 -and $output -like '*OSD relay blocked:*' -and $output -notlike '*MEMLABS_OSD_RELAY_READY*') "Broken native relay state '$mode' passed the exact shipped Bash query: $output"
            }
        }
        finally { $process.Dispose() }
    }
}

function Get-TestId { param([int]$Number); return ('{0}{1:D5}' -f $script:TestSite, $Number) }
function New-TestWmi {
    param([hashtable]$Properties)
    $row = [pscustomobject]$Properties
    $row | Add-Member -MemberType ScriptMethod -Name Get -Value { }
    return $row
}
function Add-TestNativeSequenceMethods {
    param($Sequence)
    $Sequence | Add-Member -MemberType ScriptMethod -Name Get -Value {
        $id = "$($this.PackageID)"
        $script:State.NativeRefreshes[$id] = [int]$script:State.NativeRefreshes[$id] + 1
        if ($id -in @($script:State.NewSequences.PackageID)) {
            if ($script:Mode -eq 'CopyForeignSourceSiteOnRefresh') { $this.SourceSite = 'CAS' }
            if ($script:Mode -eq 'CopySourceSiteAvailableAfterRefresh') { $this.SourceSite = $script:TestSite }
            if ($script:Mode -eq 'CopyForeignSourceSiteAfterRename' -and $script:State.NativeRefreshes[$id] -ge 2) { $this.SourceSite = 'CAS' }
        }
    }
    $Sequence | Add-Member -MemberType ScriptMethod -Name GetArrayItems -Value {
        param($Name)
        $id = "$($this.PackageID)"
        $isCopy = $id -in @($script:State.NewSequences.PackageID)
        if ($Name -ne 'References' -or ($isCopy -and [int]$script:State.NativeRefreshes[$id] -lt 3) -or
            (-not $isCopy -and [int]$script:State.NativeRefreshes[$id] -lt 1)) { throw 'References were not read from the exact refreshed native package.' }
        if ($isCopy) { $script:State.NativeArrayReads += $id }
        $ids = @((Get-TestId 3)) + @($this.Steps | Where-Object Type -eq Apply | ForEach-Object ImagePackageID) + @((Get-TestId 1))
        if ($script:Mode -eq 'BrokenRetainedReference') { $ids += 'BAD00001' }
        $references = @($ids | ForEach-Object {
                @{ Type = [pscustomobject]@{ IntegerValue = 0 }; Package = [pscustomobject]@{ StringValue = "$_" } }
            })
        # Application references are not package IDs and must not be sent to a
        # package-class query. Native references need not retain export order.
        $references += @{ Type = [pscustomobject]@{ IntegerValue = 1 }; Package = [pscustomobject]@{ StringValue = 'ScopeId_native/Application_native' } }
        if ($script:Mode -eq 'PrunedApplicationReference') { $references = @($references | Where-Object { $_['Type'].IntegerValue -ne 1 }) }
        if ($script:Mode -eq 'RegeneratedReferences') {
            $references += $references[0]
            [array]::Reverse($references)
        }
        if ($script:Mode -eq 'NoNativePackageReferences') { return @($references | Where-Object { $_['Type'].IntegerValue -ne 0 }) }
        if ($script:Mode -eq 'UnreadableNativeReferenceType') {
            return @(@{ Type = [pscustomobject]@{ IntegerValue = 'unmeasured' }; Package = [pscustomobject]@{ StringValue = (Get-TestId 1) } })
        }
        return $references
    }
}
function New-TestSequence {
    param([string]$Version, [int]$Number)
    $image = Get-TestId 11
    if ($Version -eq 'w10') { $image = Get-TestId 10 }
    $sequence = [pscustomobject]@{
        Name = "MEMLABS-$Version-Install OS image"; PackageID = (Get-TestId $Number); BootImageID = (Get-TestId 1); SourceSite = $script:TestSite
        Steps = @(
            [pscustomobject]@{ Type = 'Apply'; Name = 'Apply Operating System'; ImagePackageID = $image; Enabled = $true }
            [pscustomobject]@{ Type = 'OfflineBitLocker'; Name = 'Pre-provision BitLocker'; Condition = $null }
            [pscustomobject]@{ Type = 'Setup'; Name = 'Setup Windows and Configuration Manager'; ClientPackageID = (Get-TestId 3); Enabled = $true }
            [pscustomobject]@{ Type = 'BitLocker'; Name = 'Enable BitLocker'; Condition = $null }
            [pscustomobject]@{ Type = 'Variable'; Name = 'MEMLABS set OSDComputerName: OLDOSD'; VariableName = 'OSDComputerName'; VariableValue = 'OLDOSD'; Condition = $null }
            [pscustomobject]@{ Type = 'InstallApplication'; Name = 'MEMLABS install Office: Old'; Application = 'BROKEN-EXISTING-OFFICE'; Condition = $null }
        )
    }
    Add-TestNativeSequenceMethods $sequence
    return $sequence
}
function Assert-NewSequence {
    param($InputObject)
    if ($InputObject.PackageID -notin @($script:State.NewSequences.PackageID)) { throw 'Forbidden mutation of a retained task sequence.' }
}
function Assert-NewPath {
    param([string]$Path)
    if ($Path -notlike "$($script:State.Root)*") { throw "Forbidden write outside the private action root: $Path" }
}
function ConvertTo-OsdTestLocalSourcePath {
    param([string]$Path)
    if ($Path.StartsWith($script:State.SourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $script:State.Root + $Path.Substring($script:State.SourceRoot.Length)
    }
    return $Path
}
function Get-Location {
    [pscustomobject]@{ Provider = [pscustomobject]@{ Name = 'CMSite' }; Drive = [pscustomobject]@{ Name = $(if ($script:Mode -eq 'WrongProvider') { 'BAD' } else { $script:TestSite }) } }
}
function Get-Service { [CmdletBinding()]param($Name); [pscustomobject]@{ Status = $(if ($script:Mode -eq 'StoppedService') { 'Stopped' } else { 'Running' }) } }
function Get-CMDistributionPoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode)
    $script:State.DpReads++
    if ($script:Mode -eq 'MissingDP' -or ($script:Mode -eq 'RequestedDpLag' -and $script:State.DpReads -lt 3)) { return }
    [pscustomobject]@{ NetworkOSPath = "\\$SiteSystemServerName"; SiteCode = $SiteCode }
}
function Get-CMTaskSequence {
    [CmdletBinding()]param($Name, $TaskSequenceId)
    $rows = @($script:State.Retained.Sequences) + @($script:State.NewSequences)
    if ($Name) { return @($rows | Where-Object Name -eq $Name) }
    return @($rows | Where-Object PackageID -eq $TaskSequenceId)
}
function Get-WmiObject {
    [CmdletBinding()]param($Namespace, $Class, $Filter, $Property)
    if ($Namespace -ne "root\SMS\site_$script:TestSite") { throw "Cross-owner query: $Namespace" }
    $script:State.Queries += "$Class/$Filter"
    switch ($Class) {
        SMS_TaskSequencePackage {
            return [pscustomobject]@{ PackageID = ($Filter -split "'")[1] }
        }
        SMS_ApplicationLatest {
            if ($script:Mode -eq 'MissingInheritedApplication') { return }
            $reads = @($script:State.Queries | Where-Object { $_ -like 'SMS_ApplicationLatest/*' }).Count
            $revision = if ($script:Mode -eq 'ApplicationRevisionChanged' -and $reads -gt 1) { 2 } else { 1 }
            $definition = switch ($script:Mode) {
                MixedContentlessApplication { 'CONTENTLESS-MIXED' }
                WrongContentlessIdentity { 'CONTENTLESS-MISMATCH' }
                MissingDeclaredApplicationContent { 'CONTENTFUL-FIXTURE' }
                default { 'CONTENTLESS-FIXTURE' }
            }
            return New-TestWmi @{ CI_ID = 101; CI_UniqueID = "app/$revision"; CIVersion = $revision; ModelName = 'ScopeId_native/Application_native'; PackageID = (Get-TestId 80); IsExpired = $false; SDMPackageXML = $definition }
        }
        SMS_CIRelation {
            if ($Filter -eq 'FromCIID=101 AND RelationType=9') {
                [pscustomobject]@{ ToCIID = 201; IsBroken = $false }
                if ($script:Mode -eq 'MixedContentlessApplication') { [pscustomobject]@{ ToCIID = 202; IsBroken = $false } }
                return
            }
            if ($script:Mode -eq 'BrokenInheritedDependency' -and $Filter -eq 'FromCIID=201 AND RelationType=10') { return [pscustomobject]@{ ToCIID = 202; IsBroken = $true } }
            return
        }
        SMS_DeploymentType {
            $id = [int]($Filter -split '=')[1]
            return New-TestWmi @{ CI_ID = $id; CI_UniqueID = $(if ($id -eq 202) { 'dt/2' } else { 'dt/1' }); CIVersion = 1 }
        }
        SMS_AppDependenceRelation { return }
        SMS_CIToContent {
            if ($script:Mode -in @('ContentlessInheritedApplication', 'WrongContentlessIdentity', 'MissingDeclaredApplicationContent') -or
                ($script:Mode -eq 'MixedContentlessApplication' -and $Filter -eq 'CI_ID=201')) { return }
            return [pscustomobject]@{ ContentID = 901; ContentUniqueID = 'content/1'; ContentVersion = 1 }
        }
        SMS_PackageToContent { return [pscustomobject]@{ PackageID = (Get-TestId 80); ContentID = 901; ContentUniqueID = 'content/1'; ContentVersionInPkg = 1; MinPackageVersion = 3 } }
        SMS_ContentPackage {
            $reads = @($script:State.Queries | Where-Object { $_ -like 'SMS_ApplicationLatest/*' }).Count
            return New-TestWmi @{ PackageID = (Get-TestId 80); SourceVersion = $(if ($script:Mode -eq 'ApplicationContentChanged' -and $reads -gt 1) { 4 } else { 3 }) }
        }
        SMS_DistributionPointInfo {
            $site = ($Filter -split "'")[1]
            foreach ($path in @($script:CasePayload.Targets.Paths | Where-Object DPSiteCode -eq $site | Sort-Object DPFqdn -Unique)) {
                [pscustomobject]@{ SiteCode = $site; NetworkOSPath = "\\$($path.DPFqdn)"; ServerName = $path.DPFqdn; NALPath = "\\$($path.DPFqdn)\SMS_DP$"; ServiceType = 0 }
            }
            return
        }
        SMS_R_System {
            if ($Filter) {
                return @($script:State.Imports | Where-Object { $Filter -eq "Name='$($_.Name)'" })
            }
            $rows = @($script:State.Retained.Resources)
            if ($script:Mode -eq 'NameCollision') { $rows += [pscustomobject]@{ Name = $script:CasePayload.Targets[0].vmName; ResourceID = 60; MACAddresses = @('00:15:5D:99:99:99') } }
            if ($script:Mode -eq 'MacCollision') { $rows += [pscustomobject]@{ Name = 'OTHER'; ResourceID = 61; MACAddresses = @($script:CasePayload.Targets[0].osdMacAddress) } }
            return $rows
        }
        SMS_Boundary {
            if ($script:Mode -eq 'MissingBoundary') { return }
            foreach ($path in $script:CasePayload.Targets.Paths | Sort-Object ClientNetwork -Unique) {
                [pscustomobject]@{ BoundaryID = $path.ClientNetwork; BoundaryType = 3; Value = "$($path.ClientNetwork -replace '\.0$', '.1')-$($path.ClientNetwork -replace '\.0$', '.254')" }
            }
            return
        }
        SMS_BoundaryGroupMembers {
            foreach ($path in $script:CasePayload.Targets.Paths | Sort-Object ClientNetwork -Unique) {
                [pscustomobject]@{ BoundaryID = $path.ClientNetwork; GroupID = 1 }
            }
            return
        }
        SMS_BoundaryGroup { return [pscustomobject]@{ GroupID = 1; DefaultSiteCode = $(if ($script:Mode -eq 'WrongBoundaryOwner') { 'BAD' } else { $script:TestSite }) } }
        SMS_BoundaryGroupSiteSystems {
            if ($script:Mode -eq 'MissingBoundaryDP') { return }
            foreach ($dp in $script:CasePayload.Targets.Paths.DPFqdn | Select-Object -Unique) {
                [pscustomobject]@{ GroupID = 1; ServerNALPath = "\\$dp\SMS_DP$" }
            }
            return
        }
        SMS_CIContentPackage {
            $id = ($Filter -split "'")[1]
            return [pscustomobject]@{ PackageID = $script:State.AppPackages[$id] }
        }
        SMS_PackageStatusDistPointsSummarizer {
            $id = ($Filter -split "'")[1]
            if ($id -eq (Get-TestId 80)) {
                $site = ($Filter -split "'")[3]
                $nal = (($Filter -split "'")[5] -replace '\\\\', '\')
                $reads = @($script:State.Queries | Where-Object { $_ -like 'SMS_ApplicationLatest/*' }).Count
                return [pscustomobject]@{
                    ServerNALPath = $nal; SiteCode = $site; SourceVersion = $(if ($script:Mode -eq 'ApplicationContentChanged' -and $reads -gt 1) { 4 } else { 3 })
                    State = $(if ($script:Mode -eq 'StaleInheritedApplication') { 7 } else { 0 })
                }
            }
            foreach ($dp in $script:CasePayload.Targets.Paths.DPFqdn | Select-Object -Unique) {
                $state = 0; $version = 1
                if ($script:Mode -eq 'StaleExistingContent' -and $id -eq (Get-TestId 11)) { $version = 0 }
                if ($script:Mode -eq 'BrokenExistingContent' -and $id -eq (Get-TestId 11)) { $state = 3 }
                if ($id -in @($script:State.AppPackages.Values)) {
                    if ($script:Mode -eq 'PendingNewContent') { $state = 1 }
                    if ($script:Mode -eq 'BrokenNewContent') { $state = 3 }
                }
                [pscustomobject]@{ ServerNALPath = "\\$dp\SMS_DP$"; State = $state; SourceVersion = $version }
            }
            [pscustomobject]@{ ServerNALPath = '\\UNRELATED.fixture.test\SMS_DP$'; State = 3; SourceVersion = 0 }
            return
        }
        SMS_Advertisement {
            if ($script:Mode -eq 'AdvertisementNoOp') { return }
            return @($script:State.Advertisements | Where-Object {
                    $Filter -eq "PackageID='$($_.PackageID)' AND CollectionID='$($_.CollectionID)'"
                })
        }
        { $_ -in @('SMS_BootImagePackage', 'SMS_ImagePackage', 'SMS_Package', 'SMS_PackageBaseclass') } {
            $id = ($Filter -split "'")[1]
            if ($script:Mode -eq 'MissingImage' -and $id -eq (Get-TestId 11)) { return }
            if ($script:Mode -eq 'MissingClientPackage' -and $id -eq (Get-TestId 3)) { return }
            if ($id -eq 'BAD00001') { return }
            $properties = @{ PackageID = $id; SourceVersion = 1; PkgFlags = 0x400; ImagePath = 'C:\Existing\Boot.wim'; PkgSourcePath = 'C:\Existing\Boot.wim' }
            if ($Class -eq 'SMS_BootImagePackage' -and $script:Mode -eq 'BootNotPxe') { $properties.PkgFlags = 0 }
            return New-TestWmi $properties
        }
        default { throw "Unmocked WMI query '$Class'." }
    }
}
function Invoke-WmiMethod {
    [CmdletBinding()]param($Namespace, $Class, $Name, $ArgumentList)
    Assert-OsdTest ($Namespace -eq "root\SMS\site_$script:TestSite" -and $Class -eq 'SMS_TaskSequencePackage' -and $Name -eq 'GetSequence' -and
        $ArgumentList[0].PackageID) 'Native GetSequence did not bind the selected package through the static contract.'
    $steps = @()
    if ($script:Mode -in @('InheritedApplicationReady', 'ContentlessInheritedApplication', 'MixedContentlessApplication', 'WrongContentlessIdentity', 'MissingDeclaredApplicationContent', 'ApplicationRevisionChanged', 'ApplicationContentChanged', 'MissingInheritedApplication', 'StaleInheritedApplication', 'PrunedApplicationReference', 'BrokenInheritedDependency', 'DisabledInheritedApplication')) {
        $app = [pscustomobject]@{ __CLASS = 'SMS_TaskSequence_InstallApplicationAction'; Enabled = $true; Name = 'Customer repro application'; ApplicationName = 'ScopeId_native/Application_native'; BaseVariableName = '' }
        $steps = @($app)
        if ($script:Mode -eq 'DisabledInheritedApplication') { $steps = @([pscustomobject]@{ __CLASS = 'SMS_TaskSequence_Group'; Enabled = $false; Steps = @($app) }) }
    }
    [pscustomobject]@{ ReturnValue = 0; TaskSequence = [pscustomobject]@{ Steps = $steps } }
}
function Get-ItemProperty {
    [CmdletBinding()]param($LiteralPath, $Name)
    if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\SMS\DP') {
        return [pscustomobject]@{ IsActive = $(if ($script:Mode -eq 'PxeInactive') { 0 } else { 1 }) }
    }
    if ($LiteralPath -like '*WDSTFTP') { return [pscustomobject]@{ RootFolder = 'C:\RemoteInstall' } }
    throw "Unmocked registry query '$LiteralPath'."
}
function Get-CimInstance {
    [CmdletBinding()]param($ClassName, $Filter, $OperationTimeoutSec)
    if ($ClassName -ne 'Win32_Service') { throw "Unmocked CIM class '$ClassName'." }
    $script:State.PxeReads++
    [pscustomobject]@{
        Name = 'SccmPxe'; PathName = '"C:\SMS_DP$\sms\bin\sccmpxe.exe"'
        State = $(if ($script:Mode -eq 'PxeStopped' -or ($script:Mode -eq 'RequestedPxeLag' -and $script:State.PxeReads -lt 3)) { 'Stopped' } else { 'Running' })
    }
}
function New-PSSessionOption { param($OpenTimeout, $OperationTimeout); [pscustomobject]@{ OpenTimeout = $OpenTimeout; OperationTimeout = $OperationTimeout } }
function Invoke-Command {
    [CmdletBinding()]param($ComputerName, $ConfigurationName, $Credential, $SessionOption, $ScriptBlock, $ArgumentList)
    if ($ComputerName -notin @($script:CasePayload.Targets.Paths.DPFqdn) -or $SessionOption.OperationTimeout -gt 60000) { throw 'Unscoped remoting.' }
    $script:State.Remoted += $ComputerName
    & $ScriptBlock @ArgumentList
}
function Test-Path {
    [CmdletBinding()]param($LiteralPath, $PathType)
    if ($script:Mode -eq 'MissingAppSourceShare' -and $LiteralPath -eq $script:State.SourceShare) { return $false }
    if ($LiteralPath -like "*\MemLabs-Expansion-$($script:CasePayload.ActionId)*") {
        if ($script:Mode -eq 'UnreadablePersistentSource' -and $LiteralPath.StartsWith($script:State.SourceRoot)) { return $false }
        $local = ConvertTo-OsdTestLocalSourcePath $LiteralPath
        if (-not $script:State.Files.ContainsKey($local)) { return $false }
        if ($PathType -eq 'Container') { return $script:State.Files[$local] -eq '[directory]' }
        if ($PathType -eq 'Leaf') { return $script:State.Files[$local] -ne '[directory]' }
        return $true
    }
    if ($script:Mode -eq 'MissingBootSource' -and $LiteralPath -like '*\Existing\Boot.wim') { return $false }
    if ($script:Mode -eq 'MissingPxePayload' -and $LiteralPath -like '*\SMSBoot\*') { return $false }
    if ($script:Mode -eq 'MissingBootstrapInput' -and $LiteralPath -like '*\staging\Optimize-Defender.ps1') { return $false }
    if ($LiteralPath -eq 'FileSystem::C:\tools\odt\setup.exe') { return $false }
    return $true
}
function New-Item {
    [CmdletBinding()]param($Path, $ItemType, [switch]$Force)
    Assert-NewPath $Path
    $current = $Path
    while ($current.StartsWith($script:State.Root, [StringComparison]::OrdinalIgnoreCase)) {
        $script:State.Files[$current] = '[directory]'
        $current = $current.Substring(0, $current.LastIndexOf('\'))
    }
}
function Set-Content {
    [CmdletBinding()]param($LiteralPath, $Value, $Encoding)
    Assert-NewPath $LiteralPath
    $script:State.Files[$LiteralPath] = "$Value"
}
function Copy-Item {
    [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Recurse)
    Assert-NewPath $Destination
    $script:State.Files[$Destination] = "copy of $LiteralPath"
    if ($Recurse -and $LiteralPath -eq 'FileSystem::C:\tools\LogMachine') {
        $script:State.Files["$Destination\LogMachine.exe"] = 'mock LogMachine bytes'
    }
}
function Invoke-WebRequest {
    [CmdletBinding()]param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    Assert-NewPath "FileSystem::$OutFile"
    if ($Uri -ne 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -or $TimeoutSec -ne 120) { throw 'Unexpected network download.' }
    $script:State.Files["FileSystem::$OutFile"] = 'mock ODT'
}
function Start-Process {
    [CmdletBinding()]param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$NoNewWindow)
    Assert-NewPath "FileSystem::$FilePath"
    if ($ArgumentList -notlike '/download *') { throw 'Only the private Office source download may execute.' }
    $script:State.ProcessArguments += $ArgumentList
    $p = [pscustomobject]@{ Id = 77777; ExitCode = $(if ($script:Mode -eq 'NativeExitFailure') { 17 } else { 0 }) }
    $p | Add-Member -NotePropertyName SourceDirectory -NotePropertyValue ($FilePath.Substring(0, $FilePath.LastIndexOf('\')))
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param($Milliseconds)
        if ($Milliseconds -gt 5400000 -or $Milliseconds -le 0) { throw 'Unbounded native wait.' }
        if ($this.ExitCode -eq 0 -and $script:Mode -notin @('NativeTimeout', 'EmptyOfficeDownload')) {
            $script:State.Files["FileSystem::$($this.SourceDirectory)\Office\Data\stream.x64.en-us.dat"] = 'mock Office content bytes'
        }
        return $script:Mode -ne 'NativeTimeout'
    }
    $p | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:State.Disposed++ }
    return $p
}
function Stop-Process {
    [CmdletBinding()]param($Id, [switch]$Force)
    if ($Id -ne 77777) { throw 'Attempt to stop an unrelated process.' }
    $script:State.StoppedPids += $Id
}
function Get-ChildItem {
    [CmdletBinding()]param($LiteralPath, [switch]$File, [switch]$Recurse)
    Assert-NewPath $LiteralPath
    if ($script:Mode -ne 'EmptyOfficeDownload') { [pscustomobject]@{ Name = 'stream.x64.en-us.dat' } }
}
function Start-Sleep {
    param($Seconds)
    $script:State.Sleeps++
    if ($Seconds -gt 10 -or $script:State.Sleeps -gt 1000) { throw 'Unbounded poll.' }
}
function Write-DscStatus { param($status, [switch]$Failure, [switch]$Warning); $script:State.Messages += "$status"; if ($Failure) { $global:MemLabsFailureSequence++ } }
function Get-CMApplication {
    [CmdletBinding()]param($Name, $Id)
    if ($Id) {
        if ($script:Mode -eq 'ApplicationReadbackFailure') { return }
        return @($script:State.Apps | Where-Object { "$($_.CI_ID)" -eq "$Id" })
    }
    return @($script:State.Apps | Where-Object LocalizedDisplayName -eq $Name)
}
function New-CMApplication {
    [CmdletBinding()]param($Name, $Publisher, $SoftwareVersion, $Description, $AutoInstall)
    if ($Name -notlike "$($script:CasePayload.NamePrefix)-*") { throw 'Unscoped new application.' }
    $id = 501 + $script:State.Apps.Count
    $app = [pscustomobject]@{ CI_ID = $id; LocalizedDisplayName = $Name; SoftwareVersion = $SoftwareVersion; AutoInstall = $AutoInstall }
    $script:State.Apps += $app
    $script:State.AppPackages["$id"] = Get-TestId (200 + $script:State.Apps.Count)
    return $app
}
function Add-CMScriptDeploymentType {
    [CmdletBinding()]param($Application, $DeploymentTypeName, $ContentLocation, $InstallCommand, $ScriptLanguage, $ScriptText, $InstallationBehaviorType, $LogonRequirementType)
    if ($Application.CI_ID -notin @($script:State.Apps.CI_ID)) { throw 'Retained application deployment type mutation.' }
    if ("FileSystem::$ContentLocation" -notlike "$($script:State.SourceRoot)\*") { throw 'Application content references temporary or non-C:\Apps source storage.' }
    Assert-NewPath (ConvertTo-OsdTestLocalSourcePath "FileSystem::$ContentLocation")
    $script:State.Types["$($Application.CI_ID)"] = [pscustomobject]@{
        LocalizedDisplayName = $DeploymentTypeName; InstallCommand = $InstallCommand; ScriptText = $ScriptText
        ContentLocation = $ContentLocation
    }
}
function Get-CMDeploymentType {
    [CmdletBinding()]param($ApplicationName)
    $app = @($script:State.Apps | Where-Object LocalizedDisplayName -eq $ApplicationName)[0]
    return $script:State.Types["$($app.CI_ID)"]
}
function Start-CMContentDistribution {
    [CmdletBinding()]param($InputObject, $DistributionPointName, [switch]$DisableContentDependencyDetection)
    if ($InputObject.CI_ID -notin @($script:State.Apps.CI_ID) -or -not $DisableContentDependencyDetection) { throw 'Existing content redistribution or dependency expansion is forbidden.' }
    if (@($DistributionPointName | Where-Object { $_ -notin @($script:CasePayload.Targets.Paths.DPFqdn) }).Count) { throw 'Distribution outside requested target DPs.' }
    $script:State.Distributions += [pscustomobject]@{ CI_ID = $InputObject.CI_ID; DPs = @($DistributionPointName) }
}
function Copy-CMTaskSequence {
    [CmdletBinding(SupportsShouldProcess = $true)]param($InputObject)
    if ($script:Mode -eq 'CopyReturnsExisting') { return $InputObject }
    $copy = $InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copy.PackageID = Get-TestId (2000 + $script:State.NewSequences.Count)
    if ($script:Mode -eq 'CopySourceSiteAvailableAfterRefresh') { $copy.SourceSite = 'STALE' }
    Add-TestNativeSequenceMethods $copy
    $script:State.NewSequences += $copy
    return $copy
}
function Set-CMTaskSequence {
    [CmdletBinding()]param($InputObject, $NewName, $Description)
    Assert-NewSequence $InputObject
    if ($InputObject.SourceSite -ne $script:TestSite -or [int]$script:State.NativeRefreshes["$($InputObject.PackageID)"] -lt 1) {
        throw 'A copied sequence was mutated before native refreshed ownership validation.'
    }
    $InputObject.Name = $NewName
}
function Get-CMTSStepApplyOperatingSystem { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject); process { $InputObject.Steps | Where-Object Type -eq Apply } }
function Get-CMTSStepSetupWindowsAndConfigMgr { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject); process { $InputObject.Steps | Where-Object Type -eq Setup } }
function Get-CMTSStepOfflineEnableBitLocker { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName); process { $InputObject.Steps | Where-Object Type -eq OfflineBitLocker } }
function Get-CMTSStepEnableBitLocker { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName); process { $InputObject.Steps | Where-Object Type -eq BitLocker } }
function Get-CMTaskSequenceGroup {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName)
    process { if ($script:Mode -eq 'BadBareMetalShape') { [pscustomobject]@{ Name = $StepName } } }
}
function Get-CMTSStepReboot { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName); process { } }
function Get-CMTSStepSetVariable { [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject); process { $InputObject.Steps | Where-Object Type -eq Variable } }
function Remove-CMTSStepSetVariable {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName, [switch]$Force)
    process { Assert-NewSequence $InputObject; $InputObject.Steps = @($InputObject.Steps | Where-Object Name -ne $StepName) }
}
function New-CMTSStepConditionQueryWmi { [CmdletBinding()]param($Namespace, $Query); [pscustomobject]@{ Operands = @([pscustomobject]@{ Namespace = $Namespace; Query = $Query }) } }
function New-CMTSStepConditionVariable { [CmdletBinding()]param($OperatorType, $ConditionVariableName, $ConditionVariableValue); [pscustomobject]@{ OperatorType = $OperatorType; Variable = $ConditionVariableName; Value = $ConditionVariableValue } }
function New-CMTSStepConditionIfStatement { [CmdletBinding()]param($StatementType, $Condition); [pscustomobject]@{ StatementType = $StatementType; Operands = @($Condition) } }
function New-CMTSStepSetVariable {
    [CmdletBinding()]param($Name, $TaskSequenceVariable, $TaskSequenceVariableValue, $Condition)
    [pscustomobject]@{ Name = $Name; Type = 'Variable'; VariableName = $TaskSequenceVariable; VariableValue = $TaskSequenceVariableValue; Condition = $Condition }
}
function Set-CMTSStepOfflineEnableBitLocker {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName, [switch]$ClearCondition, $AddCondition)
    process {
        Assert-NewSequence $InputObject
        $step = @($InputObject.Steps | Where-Object Name -eq $StepName)[0]
        if ($ClearCondition) { $step.Condition = $null }
        else { $step.Condition = [pscustomobject]@{ Operands = @($AddCondition) } }
    }
}
function Set-CMTSStepEnableBitLocker {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName, [switch]$ClearCondition, $AddCondition)
    process { $InputObject | Set-CMTSStepOfflineEnableBitLocker -StepName $StepName -ClearCondition:$ClearCondition -AddCondition $AddCondition }
}
function Get-CMTSStepInstallApplication {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName)
    process { $InputObject.Steps | Where-Object { $_.Type -eq 'InstallApplication' -and (-not $StepName -or $_.Name -eq $StepName) } }
}
function Remove-CMTSStepInstallApplication {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $StepName, [switch]$Force)
    process { Assert-NewSequence $InputObject; $InputObject.Steps = @($InputObject.Steps | Where-Object Name -ne $StepName) }
}
function New-CMTSStepInstallApplication {
    [CmdletBinding()]param($Name, $Application, $Condition, $RetryCount)
    [pscustomobject]@{ Name = $Name; Type = 'InstallApplication'; Application = "$($Application.CI_ID)"; Condition = $Condition; RetryCount = $RetryCount }
}
function Add-CMTaskSequenceStep {
    [CmdletBinding()]param([Parameter(ValueFromPipeline = $true)]$InputObject, $Step, $InsertStepStartIndex)
    process {
        Assert-NewSequence $InputObject
        if ($InsertStepStartIndex -eq 0) { $InputObject.Steps = @($Step) + @($InputObject.Steps) }
        else { $InputObject.Steps = @($InputObject.Steps) + @($Step) }
    }
}
function Get-CMDeviceCollection { [CmdletBinding()]param($Name); return @($script:State.Collections | Where-Object Name -eq $Name) }
function New-CMDeviceCollection {
    [CmdletBinding()]param($Name, $LimitingCollectionName, $Comment)
    if ($Name -notlike "$($script:CasePayload.NamePrefix)-*" -or $LimitingCollectionName -ne 'All Systems') { throw 'Unscoped collection creation.' }
    $collection = [pscustomobject]@{ Name = $Name; CollectionID = (Get-TestId (3000 + $script:State.Collections.Count)) }
    $script:State.Collections += $collection
    return $collection
}
function Add-CMDeviceCollectionQueryMembershipRule {
    [CmdletBinding()]param($CollectionId, $RuleName, $QueryExpression)
    if ($CollectionId -notin @($script:State.Collections.CollectionID)) { throw 'Unscoped membership mutation.' }
    $script:State.QueryRules[$CollectionId] = @([pscustomobject]@{ RuleName = $RuleName; QueryExpression = $QueryExpression })
}
function Get-CMDeviceCollectionQueryMembershipRule { [CmdletBinding()]param($CollectionId); return @($script:State.QueryRules[$CollectionId]) }
function Get-CMDeviceCollectionDirectMembershipRule { [CmdletBinding()]param($CollectionId); return @($script:State.DirectRules[$CollectionId]) }
function Set-CMCollection { [CmdletBinding()]param($CollectionId, $RefreshType); if ($CollectionId -notin @($script:State.Collections.CollectionID)) { throw 'Retained collection mutation.' } }
function Invoke-CMCollectionUpdate { [CmdletBinding()]param($CollectionId); if ($CollectionId -notin @($script:State.Collections.CollectionID)) { throw 'Retained collection evaluation.' } }
function New-CMApplicationDeployment {
    [CmdletBinding()]param($InputObject, $Collection, $DeployAction, $DeployPurpose, $UserNotification)
    if ($InputObject.CI_ID -notin @($script:State.Apps.CI_ID) -or $Collection.CollectionID -notin @($script:State.Collections.CollectionID)) { throw 'Unscoped existing application deployment.' }
    if ($script:Mode -ne 'ApplicationPolicyNoOp') {
        $script:State.AppDeployments += [pscustomobject]@{ CI_ID = $InputObject.CI_ID; CollectionID = $Collection.CollectionID; Purpose = $DeployPurpose }
    }
}
function Get-CMApplicationDeployment {
    [CmdletBinding()]param($Application, $Collection)
    return @($script:State.AppDeployments | Where-Object { $_.CI_ID -eq $Application.CI_ID -and $_.CollectionID -eq $Collection.CollectionID })
}
function Import-CMComputerInformation {
    [CmdletBinding()]param($ComputerName, $MacAddress, $CollectionId, [switch]$MergeIfExist)
    if ($MergeIfExist -or $ComputerName -notin @($script:CasePayload.Targets.vmName) -or $CollectionId -notin @($script:State.Collections.CollectionID)) { throw 'Existing resource merge or unscoped import.' }
    if ($script:Mode -eq 'ImportError') { Write-Error 'Native import/provider rejected the target.' }
    if ($script:Mode -eq 'ImportNoOp') { return }
    $row = [pscustomobject]@{ Name = $ComputerName; MACAddresses = @($MacAddress); ResourceID = (4000 + $script:State.Imports.Count) }
    $script:State.Imports += $row
    $script:State.DirectRules[$CollectionId] = @([pscustomobject]@{ ResourceID = $row.ResourceID; ResourceName = $ComputerName })
}
function New-CMDeviceVariable {
    [CmdletBinding()]param($DeviceId, $VariableName, $VariableValue, $IsMask)
    if ([int]$DeviceId -notin @($script:State.Imports.ResourceID)) { throw 'Retained device variable mutation.' }
    $script:State.Variables[$DeviceId] = [pscustomobject]@{ Name = $VariableName; Value = $VariableValue; IsMasked = $false }
    return [pscustomobject]@{ __CLASS = 'SMS_MachineSettings'; ResourceID = [int]$DeviceId }
}
function Get-CMDeviceVariable {
    [CmdletBinding()]param($ResourceId, $VariableName)
    if ($script:Mode -eq 'MaskedVariableReadback') {
        $masked = [pscustomobject]@{ Name = $VariableName; IsMasked = $true }
        $masked | Add-Member -MemberType ScriptProperty -Name Value -Value { $script:State.MaskedValueReads++; return $null }
        return $masked
    }
    return $script:State.Variables[$ResourceId]
}
function New-CMTaskSequenceDeployment {
    [CmdletBinding()]param($TaskSequencePackageId, $CollectionId, $DeployPurpose, $MakeAvailableTo, $RerunBehavior, $AvailableDateTime, $ScheduleEvent)
    if ($TaskSequencePackageId -notin @($script:State.NewSequences.PackageID) -or $CollectionId -notin @($script:State.Collections.CollectionID)) { throw 'Existing task-sequence policy mutation.' }
    $script:State.Advertisements += [pscustomobject]@{
        PackageID = $TaskSequencePackageId; CollectionID = $CollectionId; AdvertFlags = 0x40000
        Purpose = $DeployPurpose; MakeAvailableTo = $MakeAvailableTo; Rerun = $RerunBehavior; Schedule = $ScheduleEvent
    }
}
foreach ($forbidden in @(
        'Start-Service', 'Restart-Service', 'Set-CMDistributionPoint', 'Add-CMDistributionPoint',
        'Update-CMDistributionPoint', 'Set-CMBootImage', 'New-CMBootImage', 'Set-CMApplication',
        'Remove-CMDevice', 'Remove-CMTaskSequence', 'New-SmbShare', 'New-CMBoundary', 'Set-CMDeviceVariable', 'Remove-CMDeviceVariable',
        'Export-CMTaskSequence', 'Import-CMTaskSequence',
        'Add-CMBoundaryToGroup', 'Invoke-CMSystemDiscovery', 'ScriptWorkflow', 'perfloading'
    )) {
    Set-Item -Path "Function:\$forbidden" -Value { throw 'Forbidden existing-hierarchy repair or general workflow.' }
}

function Invoke-OsdGuestTest {
    param([string]$Mode = 'Ready', $Plan = $primaryPlan)
    $script:Mode = $Mode
    $script:CasePayload = $Plan.Payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $script:TestSite = "$($Plan.SiteCode)"
    $SiteCode = $script:TestSite
    $ThisVM = [pscustomobject]@{ vmName = $Plan.OwnerVMName }
    $CMAdmin = [pscredential]::new('FIXTURE\Administrator', (ConvertTo-SecureString 'fixture-only-not-a-credential' -AsPlainText -Force))
    $script:State = [pscustomobject]@{
        Retained = [pscustomobject]@{
            Sequences = @((New-TestSequence w11 1001), (New-TestSequence w10 1002))
            Resources = @([pscustomobject]@{ Name = 'OLDOSD'; ResourceID = 50; MACAddresses = @('00:15:5D:FF:FF:FF'); Client = 0 })
            BrokenUnrelated = [pscustomobject]@{ SQL = 'Stopped'; CMG = 'Broken'; OfficeApplication = 'Missing deployment type'; DP = 'PXE disabled'; UnknownComputerPolicy = 'Deleted'; WorkflowReceipt = 'Failed' }
        }
        Root = "FileSystem::C:\Apps\MemLabs-Expansion-$($script:CasePayload.ActionId)"
        SourceRoot = "FileSystem::\\$($script:CasePayload.OwnerFqdn)\c`$\Apps\MemLabs-Expansion-$($script:CasePayload.ActionId)"
        SourceShare = "FileSystem::\\$($script:CasePayload.OwnerFqdn)\c`$"
        RunnerRoot = "FileSystem::C:\ProgramData\MemLabs\Actions\$($script:CasePayload.ActionId)"
        Files = @{}; Apps = @(); AppPackages = @{}; Types = @{}; Distributions = @(); NewSequences = @()
        Collections = @(); QueryRules = @{}; DirectRules = @{}; AppDeployments = @(); Imports = @()
        Variables = @{}; Advertisements = @(); Queries = @(); Messages = @(); ProcessArguments = @()
        StoppedPids = @(); Disposed = 0; Sleeps = 0; DpReads = 0; PxeReads = 0; Remoted = @()
        NativeRefreshes = @{}; NativeArrayReads = @(); MaskedValueReads = 0
    }
    $script:State.Files["$($script:State.RunnerRoot)\Handler.ps1"] = $Plan.Handler.ToString()
    $script:State.Files["$($script:State.RunnerRoot)\SupportFunctions.ps1"] = 'mock staged function definitions'
    if ($Mode -eq 'MissingSelectedTaskSequence') { $script:State.Retained.Sequences = @($script:State.Retained.Sequences | Where-Object Name -notlike '*w11*') }
    if ($Mode -eq 'UnrelatedSequenceBroken') { $script:State.Retained.Sequences[1].Steps = @() }
    if ($Mode -eq 'ForeignTemplateSourceSite') { $script:State.Retained.Sequences[0].SourceSite = 'CAS' }
    if ($Mode -in @('RequestedDpLag', 'RequestedPxeLag')) {
        foreach ($target in $script:CasePayload.Targets) { foreach ($path in $target.Paths) { $path.DPIsCurrentRequest = $true } }
    }
    if ($Mode -eq 'NoMacAtDispatch') { $script:CasePayload.Targets[0].osdMacAddress = '' }
    if ($Mode -eq 'DuplicateMacAtDispatch') { $script:CasePayload.Targets[1].osdMacAddress = $script:CasePayload.Targets[0].osdMacAddress }
    $snapshot = $script:State.Retained | ConvertTo-Json -Depth 30 -Compress
    $result = $null; $failure = ''
    $global:MemLabsFailureSequence = 0
    # Recompile exactly what the parent serializes; no closure over host state.
    $guest = [scriptblock]::Create($Plan.Handler.ToString())
    try { $result = & $guest $script:CasePayload }
    catch { $failure = $_.Exception.Message }
    Assert-OsdTest (($script:State.Retained | ConvertTo-Json -Depth 30 -Compress) -eq $snapshot) "Retained customer reproduction state changed in '$Mode'."
    if ($Mode -in @('Ready', 'UnrelatedSequenceBroken', 'RequestedDpLag', 'RequestedPxeLag', 'CopySourceSiteAvailableAfterRefresh', 'RegeneratedReferences', 'InheritedApplicationReady', 'ContentlessInheritedApplication', 'MixedContentlessApplication', 'DisabledInheritedApplication')) {
        Assert-OsdTest (-not $failure -and @($result).Count -eq 1 -and $result.Status -eq 'Submitted') "Expected a single successful guest receipt in '$Mode', got '$failure'."
        Assert-OsdTest (($result.TargetVMNames -join ',') -eq ($Plan.TargetVMNames -join ',') -and
            ($script:State.Imports.Name -join ',') -eq ($Plan.TargetVMNames -join ',')) "Receipt/import target scope changed in '$Mode'."
        Assert-OsdTest ($script:State.Variables.Count -eq $Plan.TargetVMNames.Count) "Target-specific OSDComputerName variables were not persisted in '$Mode'."
        Assert-OsdTest ($global:MemLabsFailureSequence -eq 0) "Guest failure counter was ignored in '$Mode'."
    }
    else {
        Assert-OsdTest ($failure -and -not $result) "Failure '$Mode' returned a success receipt."
    }
    return [pscustomobject]@{ Result = $result; Failure = $failure; State = $script:State; Payload = $script:CasePayload }
}

$ready = Invoke-OsdGuestTest
foreach ($mode in @('InheritedApplicationReady', 'DisabledInheritedApplication')) {
    $null = Invoke-OsdGuestTest -Mode $mode
}
$null = Invoke-OsdGuestTest -Mode ContentlessInheritedApplication -Plan $singlePlan
$null = Invoke-OsdGuestTest -Mode MixedContentlessApplication -Plan $singlePlan
foreach ($mode in @('WrongContentlessIdentity', 'MissingDeclaredApplicationContent')) {
    $blocked = Invoke-OsdGuestTest -Mode $mode -Plan $singlePlan
    Assert-OsdTest ($blocked.Failure -like '*exact-revision contentless*' -and $blocked.State.Imports.Count -eq 0) `
        "Contentless identity/content mismatch '$mode' was accepted as a missing-content fallback."
}
foreach ($mode in @('ApplicationRevisionChanged', 'ApplicationContentChanged')) {
    $blocked = Invoke-OsdGuestTest -Mode $mode -Plan $singlePlan
    Assert-OsdTest ($blocked.Failure -like '*changed*' -and $blocked.State.Imports.Count -eq 0 -and $blocked.State.Advertisements.Count -eq 0) `
        "Inherited application snapshot drift '$mode' reached import/deployment."
}
foreach ($mode in @('MissingInheritedApplication', 'StaleInheritedApplication', 'PrunedApplicationReference', 'BrokenInheritedDependency')) {
    $blocked = Invoke-OsdGuestTest -Mode $mode
    Assert-OsdTest ($blocked.Failure -and $blocked.State.Imports.Count -eq 0 -and $blocked.State.Advertisements.Count -eq 0) `
        "Broken inherited application '$mode' reached target import/PXE advertisement."
}
Assert-OsdTest ($ready.State.NewSequences.Count -eq 3 -and $ready.State.Advertisements.Count -eq 3) 'Selected/prompt targets did not receive exactly their private task-sequence choices.'
Assert-OsdTest (@($ready.State.Advertisements | Where-Object Purpose -eq Required).Count -eq 1 -and
    @($ready.State.Advertisements | Where-Object Purpose -eq Available).Count -eq 2) 'Prompt mode became required, or the selected sequence stopped being required.'
Assert-OsdTest (@($ready.State.Advertisements | Where-Object {
            $_.Purpose -eq 'Required' -and ($_.Rerun -ne 'RerunIfFailedPreviousAttempt' -or $_.Schedule -ne 'AsSoonAsPossible')
        }).Count -eq 0) 'Required OSD could reimage a successfully completed target.'
Assert-OsdTest ($ready.State.Apps.Count -eq 3 -and $ready.State.AppDeployments.Count -eq 2) 'Bootstrap/Office/Azure activation were not private current-operation outputs.'
Assert-OsdTest ($ready.State.NativeArrayReads.Count -eq 3 -and
    @($ready.State.NewSequences | Where-Object { $ready.State.NativeRefreshes["$($_.PackageID)"] -lt 3 }).Count -eq 0) 'Private sequence ownership and lazy reference arrays were not natively refreshed at each boundary.'
$retainedSources = @{}
foreach ($key in @($ready.State.Files.Keys | Where-Object { $_.StartsWith($ready.State.Root) })) { $retainedSources[$key] = $ready.State.Files[$key] }
foreach ($key in @($ready.State.Files.Keys | Where-Object { $_.StartsWith($ready.State.RunnerRoot) })) { $ready.State.Files.Remove($key) }
Assert-OsdTest ($retainedSources.Count -gt 0 -and @($ready.State.Files.Keys | Where-Object { $_.StartsWith($ready.State.RunnerRoot) }).Count -eq 0) 'The success-cleanup fixture did not delete staged handler/support files.'
Assert-OsdTest (@($retainedSources.Keys | Where-Object {
            -not $ready.State.Files.ContainsKey($_) -or $ready.State.Files[$_] -ne $retainedSources[$_]
        }).Count -eq 0) 'Successful runner cleanup removed or changed persistent application source bytes.'
foreach ($type in $ready.State.Types.Values) {
    $source = ConvertTo-OsdTestLocalSourcePath "FileSystem::$($type.ContentLocation)"
    Assert-OsdTest ($source.StartsWith($ready.State.Root + '\') -and $ready.State.Files.ContainsKey($source)) 'A created deployment type lost its persistent C:\Apps source after runner cleanup.'
    $entryPoint = "$source\Install.ps1"
    if ($type.InstallCommand -eq 'setup.exe /configure install.xml') {
        $entryPoint = "$source\setup.exe"
        Assert-OsdTest ($ready.State.Files.ContainsKey("$source\install.xml") -and
            $ready.State.Files.ContainsKey("$source\Office\Data\stream.x64.en-us.dat")) 'Office source XML or downloaded content was not retained with its application.'
    }
    Assert-OsdTest ($ready.State.Files.ContainsKey($entryPoint) -and $type.ContentLocation -notlike '*\ProgramData\MemLabs\Actions\*' -and
        $type.ContentLocation -notlike '*\tools\*') 'An application source depends on deleted runner files or tools storage.'
}
Assert-OsdTest ($ready.State.Files["$($ready.State.Root)\Bootstrap\Install.ps1"] -eq $ready.Payload.BootstrapInstaller -and
    $ready.State.Files["$($ready.State.Root)\Bootstrap\Payload\Initialize-OsdDataDisks.ps1"] -eq $ready.Payload.DiskInitializer -and
    $ready.State.Files.ContainsKey("$($ready.State.Root)\Bootstrap\Payload\LogMachine\LogMachine.exe")) 'Bootstrap/initializer/tool payload bytes were not copied into persistent app-owned content.'
Assert-OsdTest ($ready.State.Files["$($ready.State.Root)\Activation\Install.ps1"].Contains($ready.Payload.ActivationDefinition)) 'The persistent activation installer references transient definition files instead of retaining the shipped implementation.'
$bootstrapType = @($ready.State.Types.Values | Where-Object LocalizedDisplayName -like '*OSD Bootstrap install')[0]
& {
    param($Detection)
    function Test-Path { param($LiteralPath, $PathType); return $false }
    function Get-Content { throw 'A missing marker must not be read.' }
    Assert-OsdTest (@(& ([scriptblock]::Create($Detection))).Count -eq 0) 'Bootstrap detection errors instead of reporting NotInstalled on a new client.'
} $bootstrapType.ScriptText
& {
    param($Detection, $Version)
    function Test-Path { param($LiteralPath, $PathType); return $true }
    function Get-Content { [CmdletBinding()]param($LiteralPath, [switch]$Raw); return $Version }
    Assert-OsdTest ((& ([scriptblock]::Create($Detection))) -eq 'Installed') 'Bootstrap detection does not recognize its successfully installed action version.'
} $bootstrapType.ScriptText $ready.Payload.ActionId
$diskJson = @($ready.State.Files.GetEnumerator() | Where-Object Key -like '*\DiskConfig.json')[0].Value | ConvertFrom-Json
Assert-OsdTest (($diskJson.Clients.ComputerName -join ',') -eq 'OSD1,OSD3' -and $diskJson.Clients[0].Disks[1].SizeBytes -eq 30GB) 'Bootstrap disk configuration includes old clients or loses requested disks.'
$registeredRule = @($ready.State.QueryRules.Values)[0][0].QueryExpression
Assert-OsdTest ($registeredRule -like '*Client = 1*' -and $registeredRule -like "*'OSD1','OSD3'*" -and $registeredRule -notlike '*OLDOSD*') 'Post-PXE enrollment query targets unrelated existing clients.'
foreach ($ts in $ready.State.NewSequences) {
    $targetName = 'OSD3'
    if ($ts.Name -like '*-OSD1-*') { $targetName = 'OSD1' }
    $naming = @($ts.Steps | Where-Object { $_.Type -eq 'Variable' -and $_.VariableName -eq 'OSDComputerName' })
    Assert-OsdTest ($naming.Count -eq 1 -and $naming[0].VariableValue -eq $targetName -and $ts.Steps[0].Name -eq $naming[0].Name) 'MAC-matched naming was not placed before native OS steps on a private copy.'
    $office = @($ts.Steps | Where-Object Type -eq InstallApplication)
    if ($targetName -eq 'OSD1') {
        Assert-OsdTest ($office.Count -eq 1 -and $office[0].Name -eq 'MEMLABS install Office: Current' -and $office[0].RetryCount -eq 2 -and $ts.Steps[-1].Type -eq 'InstallApplication') 'New target Office selection was not appended after Setup Windows.'
    }
    else { Assert-OsdTest ($office.Count -eq 0) 'A no-Office target inherited old Office policy.' }
    $bitlocker = @($ts.Steps | Where-Object Type -eq OfflineBitLocker)[0].Condition | ConvertTo-Json -Depth 15 -Compress
    if ($targetName -eq 'OSD1') { Assert-OsdTest ($bitlocker -like '*00:15:5D:00:00:01*') 'Enabled BitLocker did not receive the new target MAC.' }
    else { Assert-OsdTest ($bitlocker -like '*MEMLABS-BITLOCKER-DISABLED*') 'Disabled BitLocker inherited retained-client enablement.' }
}
Assert-OsdTest ($ready.State.Sleeps -eq 0) 'Happy-path enrollment waited for Client=1 or for existing workflow receipts.'
$other = Invoke-OsdGuestTest -Plan $otherPlan
Assert-OsdTest (($other.State.Imports.Name -join ',') -eq 'OSD2' -and
    @($other.State.NewSequences | Where-Object { $_.PackageID -notlike 'P02*' }).Count -eq 0) 'The second Primary action crossed site ownership.'
$semiAnnualXml = @($other.State.Files.GetEnumerator() | Where-Object Key -like '*Office-SemiAnnual\install.xml')[0].Value
Assert-OsdTest ($semiAnnualXml -like '*Channel="SemiAnnualPreview"*') 'The shipped SemiAnnual Office-to-ODT channel mapping was lost.'
$noAzurePlan = [pscustomobject]@{ SiteCode = $singlePlan.SiteCode; OwnerVMName = $singlePlan.OwnerVMName; TargetVMNames = $singlePlan.TargetVMNames; Handler = $singlePlan.Handler; Payload = ($singlePlan.Payload | ConvertTo-Json -Depth 30 | ConvertFrom-Json) }
$noAzurePlan.Payload.EnableAzureActivation = $false
$noAzure = Invoke-OsdGuestTest -Plan $noAzurePlan
Assert-OsdTest ($noAzure.State.AppDeployments.Count -eq 1 -and @($noAzure.State.Apps | Where-Object LocalizedDisplayName -like '*Activation').Count -eq 0) 'Non-Azure expansion authored activation policy.'
$unrelated = Invoke-OsdGuestTest -Mode UnrelatedSequenceBroken -Plan $singlePlan
Assert-OsdTest ($unrelated.State.NewSequences.Count -eq 1) 'A broken unselected task sequence blocked the current selected operation.'
foreach ($mode in @('CopySourceSiteAvailableAfterRefresh', 'RegeneratedReferences')) {
    $native = Invoke-OsdGuestTest -Mode $mode -Plan $singlePlan
    Assert-OsdTest ($native.State.NativeArrayReads.Count -eq 1 -and $native.State.Advertisements.Count -eq 1) "Native copy/refreshed reference contract '$mode' was not preserved."
}
foreach ($mode in @('RequestedDpLag', 'RequestedPxeLag')) {
    $lag = Invoke-OsdGuestTest -Mode $mode -Plan $singlePlan
    Assert-OsdTest ($lag.State.Sleeps -ge 2 -and $lag.State.Sleeps -lt 61) "Current requested DP prerequisite '$mode' did not converge with a bounded read-only wait."
}
foreach ($mode in @(
        'WrongProvider', 'StoppedService', 'NameCollision', 'MacCollision', 'MissingBoundary', 'WrongBoundaryOwner',
        'MissingBoundaryDP', 'MissingDP', 'MissingSelectedTaskSequence', 'ForeignTemplateSourceSite', 'BadBareMetalShape', 'BootNotPxe',
        'MissingBootSource', 'MissingImage', 'MissingClientPackage', 'StaleExistingContent', 'BrokenExistingContent',
        'PxeInactive', 'PxeStopped', 'MissingPxePayload', 'MissingBootstrapInput', 'MissingAppSourceShare', 'NoMacAtDispatch', 'DuplicateMacAtDispatch'
    )) {
    $blocked = Invoke-OsdGuestTest -Mode $mode
    Assert-OsdTest (@($blocked.State.Files.Keys | Where-Object { $_.StartsWith($blocked.State.Root) }).Count -eq 0 -and $blocked.State.Apps.Count -eq 0 -and
        $blocked.State.NewSequences.Count -eq 0 -and $blocked.State.Imports.Count -eq 0) "Broken required existing state '$mode' allowed mutation before stopping."
    Assert-OsdTest ($blocked.State.Sleeps -eq 0) "Retained prerequisite '$mode' was retried instead of stopped/reported."
}
foreach ($case in @(
        @{ Mode = 'NativeExitFailure'; Pattern = '*native exit code 17*' }
        @{ Mode = 'NativeTimeout'; Pattern = '*source download exceeded*' }
        @{ Mode = 'EmptyOfficeDownload'; Pattern = '*returned no content*' }
        @{ Mode = 'BrokenNewContent'; Pattern = '*NEW content*failed*No redistribution*' }
        @{ Mode = 'PendingNewContent'; Pattern = '*within 900s*' }
        @{ Mode = 'ApplicationReadbackFailure'; Pattern = '*could not be read back*' }
        @{ Mode = 'UnreadablePersistentSource'; Pattern = '*no readable persistent C:\Apps source*' }
        @{ Mode = 'CopyReturnsExisting'; Pattern = '*NEW site-owned PackageID*' }
        @{ Mode = 'CopyForeignSourceSiteOnRefresh'; Pattern = '*Refreshed task-sequence ownership mismatch*SourceSite=''CAS''*' }
        @{ Mode = 'CopyForeignSourceSiteAfterRename'; Pattern = '*Refreshed task-sequence ownership mismatch*SourceSite=''CAS''*' }
        @{ Mode = 'BrokenRetainedReference'; Pattern = '*BAD00001*resolved to 0*' }
        @{ Mode = 'NoNativePackageReferences'; Pattern = '*no native type-0 package references*' }
        @{ Mode = 'UnreadableNativeReferenceType'; Pattern = '*unreadable native reference Type*' }
        @{ Mode = 'ApplicationPolicyNoOp'; Pattern = '*application policy*did not persist*' }
        @{ Mode = 'ImportError'; Pattern = '*Native import/provider rejected*' }
        @{ Mode = 'ImportNoOp'; Pattern = '*import did not read back*' }
        @{ Mode = 'AdvertisementNoOp'; Pattern = '*PXE-visible SMS_Advertisement*' }
        @{ Mode = 'MaskedVariableReadback'; Pattern = '*is masked*left unchanged*without unmasking or repair*' }
    )) {
    $failed = Invoke-OsdGuestTest -Mode $case.Mode -Plan $singlePlan
    Assert-OsdTest ($failed.Failure -like $case.Pattern) "Native/provider failure '$($case.Mode)' lost actionable evidence: $($failed.Failure)"
    if ($case.Mode -eq 'CopyForeignSourceSiteOnRefresh') {
        Assert-OsdTest ($failed.State.NewSequences[0].Name -eq 'MEMLABS-w11-Install OS image' -and $failed.State.Imports.Count -eq 0) 'A borrowed PackageID prefix allowed mutation before refreshed SourceSite ownership was checked.'
    }
    if ($case.Mode -eq 'MaskedVariableReadback') {
        Assert-OsdTest ($failed.State.MaskedValueReads -eq 0 -and $failed.State.Advertisements.Count -eq 0) 'Masked Value was read, unmasked/repaired, or allowed OSD policy submission.'
    }
    if ($case.Mode -eq 'NativeTimeout') {
        Assert-OsdTest (($failed.State.StoppedPids -join ',') -eq '77777' -and $failed.State.Disposed -eq 1) 'Native timeout did not stop/dispose only its own process.'
    }
    if ($case.Mode -eq 'PendingNewContent') { Assert-OsdTest ($failed.State.Sleeps -eq 89) 'New-content convergence was not bounded to 90 observations.' }
}
Write-Host "PASS -- $script:Assertions scoped OSD assertions; PowerShell $($PSVersionTable.PSVersion); GuestOnly=$GuestOnly."
