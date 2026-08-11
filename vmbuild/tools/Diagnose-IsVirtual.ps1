<#
.SYNOPSIS
    Explains why the ConfigMgr client reports a machine as Virtual or Physical.

.DESCRIPTION
    Reproduces, step for step, the client-side detection the DDR custom provider performs
    (CDDRInstProv::IsVirtualMachine / GetVirtualMachineHostName / GetVirtualMachineType in
    DdrInstProv.cpp) and the CCMVDI mapping that feeds CCM_DesktopMachine.IsVirtual, so you
    can see exactly where the "correct" signal should have been picked up.

    Source verified against Configmgr-Main (dev):
      /src/client/InventoryAgent/CustomProviders/DdrProv/DdrInstProv.cpp
      /src/common/mof/DDRProv.mof
      /src/common/mof/CCMVDIClient.mof
      /src/common/mof/inventorydefaultpolicy_inst.mof

    Product detection order (all in root\ccm\invagt unless noted):
      0. Kill-switch  HKLM\SOFTWARE\Microsoft\CCM\VirtualMachine : Disable(DWORD)=1 -> PHYSICAL
      1. WMI probes   CCM_VirtualMachineInfoByWMI  InfoType=0 : run each WMINamespace/WMIQuery;
                      ANY instance returned -> IsVirtual = true
                      (OOB: root\cimv2 Win32_ComputerSystem Model="Virtual Machine" OR like "%VMware%")
      2. RegKey probes CCM_VirtualMachineInfoByRegKey InfoType=0 : compare value to RegKeyValue
                      (default MOF ships NONE for InfoType=0)
    IMPORTANT: the RegKey probes do NOT read the raw registry. GetRegistryKeyValueFromWMIObject
    queries  root\ccm\cimodels : CCM_RegistryValue_Setting_String
             where Hive=1 and key='<RegKey>' and ValueName='<name>' and RegistryPathRedirectionMode=1
    and reads the 'Value' field. If that CIM provider is unavailable the probe silently fails.

    VirtualMachineType enum (source): 0 = Physical, 1 = Hyper-V, 2 = Azure IaaS.

    Read-only. Safe on production clients. Run elevated so HKLM and the CCM namespaces are readable.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

function Write-Flag {
    param([string]$Text, [ValidateSet('ok', 'hit', 'warn', 'info')] [string]$State)
    switch ($State) {
        'hit' { Write-Host ('  [MATCH] ' + $Text) -ForegroundColor Yellow }
        'warn' { Write-Host ('  [WARN ] ' + $Text) -ForegroundColor Red }
        'info' { Write-Host ('  [ .. ] ' + $Text) -ForegroundColor Gray }
        default { Write-Host ('  [ ok ] ' + $Text) -ForegroundColor Green }
    }
}

# Mirrors CDDRInstProv::ExecuteWMIQuery: open namespace, run query, take first instance.
function Invoke-Probe {
    param([string]$Namespace, [string]$Query)
    $result = [pscustomobject]@{ Ran = $false; Count = 0; Error = $null; First = $null }
    $nsClean = $Namespace -replace '^\\\\\.\\', ''
    try {
        $inst = @(Get-CimInstance -Namespace $nsClean -Query $Query -ErrorAction Stop)
        $result.Ran = $true
        $result.Count = $inst.Count
        if ($inst.Count -gt 0) { $result.First = $inst[0] }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

# Mirrors CDDRInstProv::GetRegistryKeyValueFromWMIObject EXACTLY: read the value via the CCM
# cimodels registry model, NOT the raw registry. Returns the 'Value' field or $null.
function Get-CcmRegistryValue {
    param([string]$RegKey, [string]$ValueName)
    $out = [pscustomobject]@{ ProviderOk = $false; Value = $null; Error = $null; Query = $null }
    $q = "select * from CCM_RegistryValue_Setting_String where Hive=1 and key='" +
    $RegKey + "' and ValueName = '" + $ValueName + "' and RegistryPathRedirectionMode=1"
    $out.Query = $q
    try {
        $inst = @(Get-CimInstance -Namespace 'root\ccm\cimodels' -Query $q -ErrorAction Stop)
        $out.ProviderOk = $true
        if ($inst.Count -gt 0) { $out.Value = [string]$inst[0].Value }
    }
    catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

$causeVirtual = New-Object System.Collections.Generic.List[string]  # why it IS virtual
$whyNotVirtual = New-Object System.Collections.Generic.List[string] # why a VM would look physical
$blockers = New-Object System.Collections.Generic.List[string]      # provider/plumbing failures

# ---------------------------------------------------------------------------
Write-Section '0. Kill-switch  (HKLM\SOFTWARE\Microsoft\CCM\VirtualMachine : Disable)'
# Source: IsVirtualMachine reads HKLM software\microsoft\ccm\VirtualMachine, DWORD "Disable".
$killDisabled = $false
$kill = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\VirtualMachine' -Name 'Disable' -ErrorAction SilentlyContinue
if ($kill -and $kill.Disable -eq 1) {
    $killDisabled = $true
    Write-Flag 'Disable = 1 -> detection FORCED OFF; client always reports PHYSICAL.' 'hit'
    $whyNotVirtual.Add('Kill-switch Disable=1 forces PHYSICAL regardless of hardware.')
}
elseif ($kill) { Write-Flag ('Disable = {0} (not 1) -> override inactive.' -f $kill.Disable) 'ok' }
else { Write-Flag 'Not set -> override inactive; probes run.' 'ok' }

# ---------------------------------------------------------------------------
Write-Section '1. Raw hardware identity  (what any probe has to work with)'
# Not all of these are read by the product, but they are the signals you would use to author a
# probe for a hypervisor that the OOB Model check misses. Win32_ComputerSystem.Model IS the OOB signal.
$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
$prod = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
if ($cs) {
    Write-Host ('  Win32_ComputerSystem.Manufacturer : {0}' -f $cs.Manufacturer)
    Write-Host ('  Win32_ComputerSystem.Model        : {0}   <-- OOB probe keys on THIS' -f $cs.Model)
}
if ($bios) {
    Write-Host ('  Win32_BIOS.Manufacturer           : {0}' -f $bios.Manufacturer)
    Write-Host ('  Win32_BIOS.SMBIOSBIOSVersion      : {0}' -f $bios.SMBIOSBIOSVersion)
    Write-Host ('  Win32_BIOS.SerialNumber           : {0}' -f $bios.SerialNumber)
}
if ($board) {
    Write-Host ('  Win32_BaseBoard.Manufacturer      : {0}' -f $board.Manufacturer)
    Write-Host ('  Win32_BaseBoard.Product           : {0}' -f $board.Product)
}
if ($prod) {
    Write-Host ('  Win32_ComputerSystemProduct.Vendor: {0}' -f $prod.Vendor)
    Write-Host ('  Win32_ComputerSystemProduct.Name  : {0}' -f $prod.Name)
    Write-Host ('  Win32_ComputerSystemProduct.UUID  : {0}' -f $prod.UUID)
}
# Best-effort hypervisor guess purely to steer the operator (NOT part of product logic).
$hint = 'unknown'
$blob = (($cs.Manufacturer, $cs.Model, $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $board.Manufacturer, $board.Product, $prod.Vendor, $prod.Name) -join '|')
switch -Regex ($blob) {
    'VMware' { $hint = 'VMware' ; break }
    'Virtual Machine|Hyper-V|Microsoft Corporation' { $hint = 'Hyper-V / Azure' ; break }
    'VirtualBox|innotek' { $hint = 'VirtualBox (NOT covered by OOB probe)' ; break }
    'QEMU|KVM|Red Hat' { $hint = 'KVM/QEMU (NOT covered by OOB probe)' ; break }
    'Xen' { $hint = 'Xen (NOT covered by OOB probe)' ; break }
    'Nutanix|AHV' { $hint = 'Nutanix AHV (NOT covered by OOB probe)' ; break }
    'Google' { $hint = 'Google Compute Engine (NOT covered by OOB probe)' ; break }
    'Parallels' { $hint = 'Parallels (NOT covered by OOB probe)' ; break }
    default { $hint = 'no known hypervisor marker in SMBIOS strings' }
}
Write-Flag ('Hypervisor hint from SMBIOS strings: {0}' -f $hint) 'info'

# ---------------------------------------------------------------------------
Write-Section '2. WMI probes  (CCM_VirtualMachineInfoByWMI, InfoType=0) -- the IsVirtual signal'
$wmiProbes = @(Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'CCM_VirtualMachineInfoByWMI' -ErrorAction SilentlyContinue |
        Where-Object { $_.InfoType -eq 0 })
if ($wmiProbes.Count -eq 0) {
    Write-Flag 'No InfoType=0 WMI probes registered (client not installed, or MOF not compiled?).' 'warn'
    $blockers.Add('CCM_VirtualMachineInfoByWMI (InfoType=0) returned no probe rows.')
}
foreach ($probe in $wmiProbes) {
    Write-Host ''
    Write-Host ('  Namespace : {0}' -f $probe.WMINamespace)
    Write-Host ('  Query     : {0}' -f $probe.WMIQuery)
    $r = Invoke-Probe -Namespace $probe.WMINamespace -Query $probe.WMIQuery
    if (-not $r.Ran) {
        Write-Flag ('Probe query FAILED to run: {0}' -f $r.Error) 'warn'
        $blockers.Add(('WMI probe could not run [{0}] {1}: {2}' -f $probe.WMINamespace, $probe.WMIQuery, $r.Error))
        continue
    }
    Write-Host ('  Returned {0} instance(s).' -f $r.Count)
    if ($r.Count -gt 0) {
        Write-Flag 'Instance returned -> IsVirtual = TRUE from this probe.' 'hit'
        $causeVirtual.Add(('WMI probe matched: [{0}] {1}' -f $probe.WMINamespace, $probe.WMIQuery))
    }
    else {
        Write-Flag 'No instance -> this probe does NOT flag the machine as virtual.' 'ok'
        $whyNotVirtual.Add(('WMI probe returned 0 rows: [{0}] {1}' -f $probe.WMINamespace, $probe.WMIQuery))
    }
}

# ---------------------------------------------------------------------------
Write-Section '3. RegKey probes  (CCM_VirtualMachineInfoByRegKey, InfoType=0) -- via CCM cimodels'
$regProbes = @(Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'CCM_VirtualMachineInfoByRegKey' -ErrorAction SilentlyContinue |
        Where-Object { $_.InfoType -eq 0 })
if ($regProbes.Count -eq 0) {
    Write-Flag 'No InfoType=0 RegKey probes (default MOF ships none) -- expected.' 'ok'
}
foreach ($probe in $regProbes) {
    $expected = [string]$probe.RegKeyValue
    Write-Host ''
    Write-Host ('  RegKey          : {0}' -f $probe.RegKey)
    Write-Host ('  RegKeyValueName : {0}   (expected = "{1}")' -f $probe.RegKeyValueName, $expected)
    $ccm = Get-CcmRegistryValue -RegKey $probe.RegKey -ValueName $probe.RegKeyValueName
    Write-Host ('  CCM cimodels query: {0}' -f $ccm.Query)
    if (-not $ccm.ProviderOk) {
        Write-Flag ('root\ccm\cimodels provider FAILED: {0}' -f $ccm.Error) 'warn'
        $blockers.Add('CCM_RegistryValue_Setting_String (root\ccm\cimodels) unavailable -> regkey probes silently fail.')
        continue
    }
    Write-Host ('  CCM-read Value  : {0}' -f $ccm.Value)
    $match = ($null -ne $ccm.Value -and $ccm.Value.Trim().ToLower() -eq $expected.Trim().ToLower())
    if ($match) {
        Write-Flag 'Value matches -> IsVirtual = TRUE from this probe.' 'hit'
        $causeVirtual.Add(('RegKey probe matched: {0}\{1} = "{2}"' -f $probe.RegKey, $probe.RegKeyValueName, $ccm.Value))
    }
    else {
        Write-Flag 'Value does not match -> this probe does not flag virtual.' 'ok'
    }
}

# ---------------------------------------------------------------------------
Write-Section '4. HostName / VMType inputs  (InfoType 1/2/3) -- classification, not IsVirtual'
# InfoType=1 hostname (WMI then RegKey), InfoType=3 HostingSystemEditionId, InfoType=2 Azure VMType.
foreach ($it in 1, 2, 3) {
    $rows = @(Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'CCM_VirtualMachineInfoByRegKey' -ErrorAction SilentlyContinue |
            Where-Object { $_.InfoType -eq $it })
    foreach ($probe in $rows) {
        $ccm = Get-CcmRegistryValue -RegKey $probe.RegKey -ValueName $probe.RegKeyValueName
        $val = if ($ccm.ProviderOk) { $ccm.Value } else { '<provider error: ' + $ccm.Error + '>' }
        Write-Host ('  InfoType={0}  {1}\{2} = "{3}"' -f $it, $probe.RegKey, $probe.RegKeyValueName, $val)
        if (-not $ccm.ProviderOk) {
            $blockers.Add('CCM_RegistryValue_Setting_String (root\ccm\cimodels) unavailable.')
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section '5. Client-computed result  (CCM_VirtualMachineInfo) + raw registry cross-check'
$vmInfo = Get-CimInstance -Namespace 'root\ccm\invagt' -ClassName 'CCM_VirtualMachineInfo' -ErrorAction SilentlyContinue
$vmTypeMap = @{ 0 = 'Physical'; 1 = 'Hyper-V'; 2 = 'Azure IaaS' }
if ($vmInfo) {
    $t = [int]$vmInfo.VirtualMachineType
    $tName = if ($vmTypeMap.ContainsKey($t)) { $vmTypeMap[$t] } else { "unknown($t)" }
    Write-Host ('  CCM_VirtualMachineInfo.IsVirtualMachine      = {0}' -f $vmInfo.IsVirtualMachine)
    Write-Host ('  CCM_VirtualMachineInfo.VirtualMachineHostName = {0}' -f $vmInfo.VirtualMachineHostName)
    Write-Host ('  CCM_VirtualMachineInfo.VirtualMachineType    = {0}  ({1})' -f $t, $tName)
}
else {
    Write-Flag 'CCM_VirtualMachineInfo not available -- client not installed or inventory not run.' 'warn'
    $blockers.Add('CCM_VirtualMachineInfo (root\ccm\invagt) not readable.')
}
# Raw-registry cross-check of the fingerprints the CCM cimodels path SHOULD surface. A mismatch
# between "present in raw registry" and "returned by CCM cimodels" pinpoints a broken read path.
Write-Host ''
Write-Host '  Raw-registry cross-check (bypasses CCM cimodels):'
$raw = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'; Name = 'PhysicalHostName' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'; Name = 'HostingSystemEditionId' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows Azure'; Name = 'VMType' }
)
foreach ($r in $raw) {
    $item = Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
    if ($item) { Write-Host ('    PRESENT: {0}\{1} = "{2}"' -f $r.Path, $r.Name, $item.($r.Name)) -ForegroundColor Yellow }
    else { Write-Host ('    absent : {0}\{1}' -f $r.Path, $r.Name) }
}

# ---------------------------------------------------------------------------
Write-Section '6. VDI mapping + final projected value  (CCM_DesktopMachine, root\ccmvdi)'
$desktop = Get-CimInstance -Namespace 'root\ccmvdi' -ClassName 'CCM_DesktopMachine' -ErrorAction SilentlyContinue
if ($desktop) {
    Write-Host ('  CCM_DesktopMachine.IsVirtual      = {0}' -f $desktop.IsVirtual)
    Write-Host ('  CCM_DesktopMachine.Partner        = {0}' -f $desktop.Partner)
    Write-Host ('  CCM_DesktopMachine.HostIdentifier = {0}' -f $desktop.HostIdentifier)
    if ($vmInfo -and $vmInfo.IsVirtualMachine -and -not $desktop.IsVirtual) {
        Write-Flag 'Local says VIRTUAL but CCM_DesktopMachine says physical -> a partner mapping overrode it.' 'warn'
        $whyNotVirtual.Add('VDI partner mapping projected IsVirtual=false over a local IsVirtualMachine=true.')
    }
    if ($vmInfo -and -not $vmInfo.IsVirtualMachine -and $desktop.IsVirtual -and $desktop.Partner -ne 'SCCM') {
        $causeVirtual.Add(('VDI partner "{0}" is forcing IsVirtual=true.' -f $desktop.Partner))
    }
}
else {
    Write-Flag 'CCM_DesktopMachine (root\ccmvdi) not available.' 'warn'
}
Write-Host ''
Write-Host '  IsVirtual partner mappings (root\ccmvdi : CCM_Partner_Attributes), priority order:'
$maps = @(Get-CimInstance -Namespace 'root\ccmvdi' -ClassName 'CCM_Partner_Attributes' -ErrorAction SilentlyContinue |
        Where-Object { $_.CCMPropertyName -eq 'IsVirtual' })
if ($maps.Count -gt 0) {
    $maps | Sort-Object ReservedUint1 |
        Select-Object @{n = 'Priority'; e = { switch ($_.ReservedUint1) { 0 { '0-External' } 1 { '1-Internal/RDV' } 2 { '2-SCCM' } default { $_.ReservedUint1 } } } },
    Partner, PartnerNamespace, PartnerQuery |
        Format-Table -AutoSize | Out-String | Write-Host
}
else { Write-Host '  (none found)' }

# ---------------------------------------------------------------------------
Write-Section '7. Inventory freshness  (server value only updates on next hardware inventory)'
$invLog = Join-Path $env:SystemRoot 'CCM\Logs\InventoryAgent.log'
if (Test-Path $invLog) {
    Write-Host ('  {0}  (last write {1})' -f $invLog, (Get-Item $invLog).LastWriteTime)
    Select-String -Path $invLog -Pattern 'Virtual Machine' -SimpleMatch -ErrorAction SilentlyContinue |
        Select-Object -Last 3 | ForEach-Object { Write-Host ('    > ' + $_.Line.Trim()) -ForegroundColor DarkGray }
}
else { Write-Flag 'InventoryAgent.log not found (client not installed here?).' 'warn' }
Write-Host ''
Write-Host '  Force a Hardware Inventory Cycle after any fix:' -ForegroundColor DarkGray
Write-Host "    Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000001}' }" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Section 'SUMMARY'
$isVirtualNow = $null
if ($vmInfo) { $isVirtualNow = [bool]$vmInfo.IsVirtualMachine }
if ($null -ne $isVirtualNow) {
    Write-Host ('  Current client verdict: IsVirtualMachine = {0}' -f $isVirtualNow) -ForegroundColor Cyan
}

if ($blockers.Count -gt 0) {
    Write-Host ''
    Write-Host '  PLUMBING PROBLEMS (detection could not read a signal it relies on):' -ForegroundColor Red
    $blockers | Select-Object -Unique | ForEach-Object { Write-Host ('   - ' + $_) -ForegroundColor Red }
}

if ($killDisabled) {
    Write-Host ''
    Write-Host '  Detection is force-disabled (Disable=1) -> reports PHYSICAL by design.' -ForegroundColor Yellow
    Write-Host '  If the server shows virtual, the value is stale -> force hardware inventory.' -ForegroundColor Yellow
}
elseif ($causeVirtual.Count -gt 0) {
    Write-Host ''
    Write-Host '  WHY IT IS VIRTUAL:' -ForegroundColor Yellow
    $i = 1; foreach ($c in ($causeVirtual | Select-Object -Unique)) { Write-Host ('   {0}. {1}' -f $i, $c) -ForegroundColor Yellow; $i++ }
    Write-Host ''
    Write-Host '  If this machine is really PHYSICAL, remediate the matched signal:' -ForegroundColor Cyan
    Write-Host '   - Model-based hit  : correct SMBIOS Product Name (BIOS/firmware/OEM tool).'
    Write-Host '   - Custom probe hit : remove the extra CCM_VirtualMachineInfoBy* instance / leftover guest tools.'
    Write-Host '   - Cannot fix HW    : set HKLM\SOFTWARE\Microsoft\CCM\VirtualMachine\Disable = 1.'
}
else {
    Write-Host ''
    Write-Host '  No signal flagged this machine as virtual.' -ForegroundColor Green
    if ($hint -like '*NOT covered*') {
        Write-Host ('  Hardware looks like {0}.' -f $hint) -ForegroundColor Yellow
        Write-Host '  The OOB probe only matches Hyper-V ("Virtual Machine") and VMware ("%VMware%").' -ForegroundColor Yellow
        Write-Host '  To detect this hypervisor, ADD a probe instance in root\ccm\invagt, e.g.:' -ForegroundColor Cyan
        Write-Host '     CCM_VirtualMachineInfoByWMI { InfoType=0; WMINamespace="\\.\root\cimv2";' -ForegroundColor Gray
        Write-Host '       WMIQuery="select * from Win32_ComputerSystem where Manufacturer like ''%QEMU%''"; WMIPropertyName="" }' -ForegroundColor Gray
        Write-Host '  Pick a WMIQuery keyed on a string shown in section 1 that uniquely identifies the VM.' -ForegroundColor Cyan
    }
    else {
        Write-Host '  If this machine is really VIRTUAL, the OOB Model probe did not match it. Check:' -ForegroundColor Cyan
        Write-Host '   - section 1: does Win32_ComputerSystem.Model actually say "Virtual Machine"/contain "VMware"?'
        Write-Host '   - section 0: is the kill-switch set?'
        Write-Host '   - PLUMBING PROBLEMS above: could a probe query or the CCM cimodels read path not run?'
        Write-Host '   - section 7: is the reported value simply stale (force hardware inventory)?'
    }
}
Write-Host ''
