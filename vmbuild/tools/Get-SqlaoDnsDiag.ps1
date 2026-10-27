<#
.SYNOPSIS
    Collects SQLAO cluster/AG-listener DNS-registration diagnostics into vmbuild\logs.

.DESCRIPTION
    One-shot collector for the Phase 11 SQLAO failure:

      FAIL: Expected cluster IP '<ip>.201' not in DNS (found: )
      WARN: Cluster DNS has unexpected IP '' (expected '<ip>.201')
      WARN: Expected AG IP '<ip>.202' not in resolved addresses

    i.e. the cluster-name (CNO) and AG-listener A-records are missing / blank on
    the DC even though the AG is healthy and the listener accepts SQL connects.

    Runs from the Hyper-V host and uses PowerShell Direct to reach:

      - Each SQLAO node (default PT3-PS1SQLAO1 / PT3-PS1SQLAO2): dumps the full
        cluster picture (Get-Cluster / nodes / networks+roles / every resource +
        its private properties), with special focus on the Network Name (CNO +
        listener) and IP Address resources -- RegisterAllProvidersIP,
        HostRecordTTL, PublishPTRRecords, DnsName, online state, and the OWNER of
        each resource. Pulls the FailoverClustering System-event log entries that
        report DNS registration health (1196 / 1257 / 1228 / 1207 / 1579 / 1592 +
        recent context), a 30-min slice of the cluster.log grepped for the
        Netname/DNS registration path, the node's own NIC/SkipAsSource state, and
        what the node's resolver returns for the cluster + listener names.
        Also auto-DISCOVERS the cluster name, listener name(s), cluster IP and AG
        IP so the DC half needs no hand-entered names.

      - The DC / DNS server (default PT3-DC1): for the discovered names (cluster,
        listener, both nodes) dumps the RAW A-records (so a blank/empty RecordData
        is visible), each record's Timestamp (0 = static, non-zero = dynamic) and
        TTL, the zone's DynamicUpdate mode, and the zone + server aging/scavenging
        settings (a scavenge can delete a dynamically-registered CNO/listener
        record). Also dumps EVERY A-record in the zone matching the cluster
        prefix to surface duplicates / orphaned blanks.

    All output is written to a single timestamped file in vmbuild\logs so it can
    be parsed without further round-trips.

.NOTES
    PS5.1-safe inside the in-guest scriptblocks (no ternary / null-conditional).
    The lab admin password is entered interactively via Get-Credential -- never
    passed on the command line and never seen by the model.
#>
[CmdletBinding()]
param(
    [string[]]$NodeVm = @('PT3-PS1SQLAO1', 'PT3-PS1SQLAO2'),
    [string]$DcVm = 'PT3-DC1',
    [string]$Domain = 'pstest3.com',
    [string]$DomainNetbios = 'pstest3',
    [string]$AdminName = 'admin',
    # Optional manual override if cluster auto-discovery on the nodes fails.
    [string[]]$ExtraNames = @()
)

$ErrorActionPreference = 'Continue'
# Script lives in vmbuild\tools; write diagnostics to vmbuild\logs (one level up).
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $logDir "sqlao-dns-diag-$stamp.txt"

function Add-Section {
    param([string]$Title, [object]$Body)
    $sep = ('=' * 78)
    Add-Content -Path $outFile -Value "`r`n$sep`r`n=== $Title`r`n$sep"
    if ($null -ne $Body) {
        Add-Content -Path $outFile -Value ($Body | Out-String)
    }
}

Add-Content -Path $outFile -Value "SQLAO cluster/listener DNS diagnostic  ($stamp)"
Add-Content -Path $outFile -Value "Nodes=$($NodeVm -join ', ')   DC=$DcVm   Domain=$Domain"

# One password for the lab. Entered locally; never via the model.
$pw = (Get-Credential -UserName "$DomainNetbios\$AdminName" -Message "Enter the lab admin password for $DomainNetbios").Password
$cred = New-Object System.Management.Automation.PSCredential ("$DomainNetbios\$AdminName", $pw)

# ---------------------------------------------------------------------------
#  Node collection (runs in-guest on each SQLAO node -- PS5.1)
#  Returns an object: .Text (the human report) + discovered names so the DC
#  half can query the exact records without hand-entered values.
# ---------------------------------------------------------------------------
$nodeScript = {
    $out = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }

    $discClusterName = ''
    $discListeners = New-Object System.Collections.Generic.List[string]
    $discClusterIPs = New-Object System.Collections.Generic.List[string]
    $discAgIPs = New-Object System.Collections.Generic.List[string]
    $discNodes = New-Object System.Collections.Generic.List[string]

    Import-Module FailoverClusters -ErrorAction SilentlyContinue

    W "### Get-Cluster ###"
    try {
        $cl = Get-Cluster -ErrorAction Stop
        $discClusterName = [string]$cl.Name
        W ($cl | Format-List Name, Domain, * | Out-String)
    }
    catch { W "ERR Get-Cluster: $($_.Exception.Message)" }

    W "### Get-ClusterNode ###"
    try {
        $nodes = Get-ClusterNode -ErrorAction Stop
        foreach ($n in $nodes) { $discNodes.Add([string]$n.Name) }
        W ($nodes | Format-Table Name, State, DynamicWeight, NodeWeight -AutoSize | Out-String)
    }
    catch { W "ERR Get-ClusterNode: $($_.Exception.Message)" }

    W "### Get-ClusterNetwork (+ role: 1=Cluster-only, 3=Cluster+Client) ###"
    try {
        W (Get-ClusterNetwork -ErrorAction Stop | Format-Table Name, State, Role, Address, AddressMask -AutoSize | Out-String)
    }
    catch { W "ERR Get-ClusterNetwork: $($_.Exception.Message)" }

    W "### All cluster resources (State / Type / OwnerGroup) ###"
    $allRes = @()
    try {
        $allRes = @(Get-ClusterResource -ErrorAction Stop)
        W ($allRes | Format-Table Name, State, ResourceType, OwnerGroup, OwnerNode -AutoSize | Out-String)
    }
    catch { W "ERR Get-ClusterResource: $($_.Exception.Message)" }

    W "### Network Name resources -- FULL private properties (CNO + AG listeners) ###"
    W "    (key fields: Name, DnsName, RegisterAllProvidersIP, HostRecordTTL, PublishPTRRecords, StatusDNS)"
    try {
        $nnRes = @($allRes | Where-Object { $_.ResourceType -eq 'Network Name' })
        foreach ($r in $nnRes) {
            W "----- Network Name resource: '$($r.Name)'  State=$($r.State)  Owner=$($r.OwnerNode)  Group=$($r.OwnerGroup) -----"
            try {
                $params = $r | Get-ClusterParameter -ErrorAction Stop
                foreach ($p in $params) { W ("    {0,-28} = {1}" -f $p.Name, $p.Value) }
                # Record the DNS name this resource is supposed to publish.
                $dnsP = $params | Where-Object { $_.Name -eq 'DnsName' } | Select-Object -First 1
                $nameP = $params | Where-Object { $_.Name -eq 'Name' } | Select-Object -First 1
                $published = ''
                if ($dnsP -and $dnsP.Value) { $published = [string]$dnsP.Value }
                elseif ($nameP -and $nameP.Value) { $published = [string]$nameP.Value }
                if ($published) {
                    # core cluster name resource is usually named 'Cluster Name'
                    if ($r.Name -eq 'Cluster Name' -or ($script:discClusterName -and $published -ieq $script:discClusterName)) {
                        if (-not $script:discClusterName) { $script:discClusterName = $published }
                    }
                    else {
                        $script:discListeners.Add($published)
                    }
                }
            }
            catch { W "    ERR Get-ClusterParameter: $($_.Exception.Message)" }
        }
        if (-not $nnRes) { W "(no Network Name resources found)" }
    }
    catch { W "ERR Network Name enumeration: $($_.Exception.Message)" }

    W "### IP Address resources -- FULL private properties (cluster IP + AG VIP) ###"
    try {
        $ipRes = @($allRes | Where-Object { $_.ResourceType -eq 'IP Address' })
        foreach ($r in $ipRes) {
            W "----- IP Address resource: '$($r.Name)'  State=$($r.State)  Group=$($r.OwnerGroup) -----"
            try {
                $params = $r | Get-ClusterParameter -ErrorAction Stop
                foreach ($p in $params) { W ("    {0,-28} = {1}" -f $p.Name, $p.Value) }
                $addrP = $params | Where-Object { $_.Name -eq 'Address' } | Select-Object -First 1
                if ($addrP -and $addrP.Value) {
                    # AG listener IP resource name usually contains the AG/listener name; core cluster IP is 'Cluster IP Address'
                    if ($r.Name -like 'Cluster IP Address*') { $script:discClusterIPs.Add([string]$addrP.Value) }
                    else { $script:discAgIPs.Add([string]$addrP.Value) }
                }
            }
            catch { W "    ERR Get-ClusterParameter: $($_.Exception.Message)" }
        }
        if (-not $ipRes) { W "(no IP Address resources found)" }
    }
    catch { W "ERR IP Address enumeration: $($_.Exception.Message)" }

    W "### FailoverClustering DNS-registration events (System log) ###"
    W "    1196 = Netname failed DNS registration | 1257 = couldn't register, check perms | 1228/1207/1579/1592 = related"
    try {
        $evAll = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering' } -MaxEvents 200 -ErrorAction SilentlyContinue)
        $dnsIds = 1196, 1257, 1228, 1207, 1579, 1592, 1205, 1069
        $dnsEv = @($evAll | Where-Object { $dnsIds -contains $_.Id })
        if ($dnsEv) {
            W "--- DNS/registration-specific events (most recent 30) ---"
            foreach ($e in ($dnsEv | Select-Object -First 30)) {
                W ("[{0}] Id={1} {2}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName)
                W (("    " + (($e.Message -split "`r?`n") -join ' / ')).Substring(0, [Math]::Min(360, ("    " + (($e.Message -split "`r?`n") -join ' / ')).Length)))
            }
        }
        else { W "(no 1196/1257/1228/1207/1579/1592 DNS-registration events found)" }
        W "--- most recent 25 FailoverClustering events (context) ---"
        foreach ($e in ($evAll | Select-Object -First 25)) {
            W ("[{0}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName, (($e.Message -split "`r?`n")[0]))
        }
    }
    catch { W "ERR cluster events: $($_.Exception.Message)" }

    W "### cluster.log (last 30 min) grepped for Netname / DNS / registration ###"
    try {
        $rep = Get-ClusterLog -TimeSpan 30 -Destination $env:TEMP -ErrorAction Stop
        $logFile = $null
        if ($rep) {
            $cand = @(Get-ChildItem -Path $env:TEMP -Filter "$env:COMPUTERNAME*_cluster.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($cand) { $logFile = $cand[0].FullName }
        }
        if ($logFile -and (Test-Path $logFile)) {
            $hits = Select-String -Path $logFile -Pattern 'Netname|DnsName|register|DNS|RegisterAllProviders|PublishPTR' -ErrorAction SilentlyContinue
            foreach ($h in ($hits | Select-Object -Last 80)) { W $h.Line }
            Remove-Item $logFile -Force -ErrorAction SilentlyContinue
        }
        else { W "(cluster.log not produced)" }
    }
    catch { W "ERR Get-ClusterLog: $($_.Exception.Message)" }

    W "### Node NICs / DNS-client registration / SkipAsSource ###"
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' }
        W ($ips | Format-Table IPAddress, PrefixLength, InterfaceAlias, SkipAsSource, PrefixOrigin -AutoSize | Out-String)
        W "--- Get-DnsClient RegisterThisConnectionsAddress ---"
        W (Get-DnsClient -ErrorAction SilentlyContinue | Format-Table InterfaceAlias, RegisterThisConnectionsAddress, ConnectionSpecificSuffix -AutoSize | Out-String)
    }
    catch { W "ERR NIC state: $($_.Exception.Message)" }

    W "### Node resolver view of cluster + listener names ###"
    try {
        $names = New-Object System.Collections.Generic.List[string]
        if ($discClusterName) { $names.Add($discClusterName) }
        foreach ($l in $discListeners) { if ($l) { $names.Add($l) } }
        foreach ($nm in ($names | Select-Object -Unique)) {
            W "--- Resolve-DnsName $nm (node's configured DNS) ---"
            try { W (Resolve-DnsName -Name $nm -Type A -ErrorAction Stop | Format-Table Name, Type, IPAddress, TTL -AutoSize | Out-String) }
            catch { W "    Resolve-DnsName $nm FAILED: $($_.Exception.Message)" }
        }
    }
    catch { W "ERR resolver view: $($_.Exception.Message)" }

    W "### nltest /dsgetdc (which DC is this node bound to) ###"
    try { W ((& nltest "/dsgetdc:$env:USERDNSDOMAIN" 2>&1 | Out-String)) } catch { W "ERR nltest: $($_.Exception.Message)" }

    W "### Computer object for the cluster (CNO) in AD -- enabled? ###"
    try {
        if ($discClusterName) {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.Filter = "(&(objectClass=computer)(cn=$discClusterName))"
            $r = $searcher.FindOne()
            if ($r) {
                $uac = [int]$r.Properties['useraccountcontrol'][0]
                $disabled = (($uac -band 0x2) -ne 0)
                W "CNO '$discClusterName' found in AD. userAccountControl=$uac Disabled=$disabled whenCreated=$($r.Properties['whencreated'][0])"
            }
            else { W "CNO '$discClusterName' NOT found in AD via cn search." }
        }
    }
    catch { W "ERR CNO AD lookup: $($_.Exception.Message)" }

    return [pscustomobject]@{
        Text        = ($out -join "`r`n")
        ClusterName = $discClusterName
        Listeners   = @($discListeners | Select-Object -Unique)
        ClusterIPs  = @($discClusterIPs | Select-Object -Unique)
        AgIPs       = @($discAgIPs | Select-Object -Unique)
        Nodes       = @($discNodes | Select-Object -Unique)
    }
}

# ---------------------------------------------------------------------------
#  DC / DNS collection (runs in-guest on the DC -- PS5.1)
# ---------------------------------------------------------------------------
$dcScript = {
    param($Domain, $Names)
    $out = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }

    Import-Module DnsServer -ErrorAction SilentlyContinue

    W "### DC time / uptime ###"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        W ("Now={0}  LastBoot={1}" -f (Get-Date), $os.LastBootUpTime)
    }
    catch { W "ERR time: $($_.Exception.Message)" }

    W "### Zone '$Domain' settings (DynamicUpdate mode) ###"
    try { W (Get-DnsServerZone -Name $Domain -ErrorAction Stop | Format-List ZoneName, ZoneType, DynamicUpdate, IsDsIntegrated, IsAutoCreated | Out-String) }
    catch { W "ERR Get-DnsServerZone: $($_.Exception.Message)" }

    W "### Zone aging + server scavenging (a scavenge deletes dynamic CNO/listener records) ###"
    try { W (Get-DnsServerZoneAging -Name $Domain -ErrorAction SilentlyContinue | Format-List * | Out-String) }
    catch { W "ERR Get-DnsServerZoneAging: $($_.Exception.Message)" }
    try { W (Get-DnsServerScavenging -ErrorAction SilentlyContinue | Format-List * | Out-String) }
    catch { W "ERR Get-DnsServerScavenging: $($_.Exception.Message)" }

    W "### Per-name A-records (RAW -- shows blank/empty RecordData; Timestamp 0=static, else dynamic) ###"
    foreach ($nm in ($Names | Where-Object { $_ } | Select-Object -Unique)) {
        $short = $nm
        if ($short -like "*.$Domain") { $short = $short.Substring(0, $short.Length - ($Domain.Length + 1)) }
        W "----- '$short' (A) in $Domain -----"
        try {
            $recs = @(Get-DnsServerResourceRecord -ZoneName $Domain -Name $short -RRType A -ComputerName $env:COMPUTERNAME -ErrorAction Stop)
            if (-not $recs) { W "    (no A record -- name does not exist in zone)" }
            foreach ($rec in $recs) {
                $ip = ''
                try { if ($rec.RecordData -and $rec.RecordData.IPv4Address) { $ip = $rec.RecordData.IPv4Address.IPAddressToString } } catch {}
                W ("    HostName='{0}'  IPv4='{1}'  Timestamp='{2}'  TTL='{3}'  Type='{4}'" -f $rec.HostName, $ip, $rec.Timestamp, $rec.TimeToLive, $rec.RecordType)
            }
            # also dump the raw object for the first record so any odd shape is visible
            if ($recs) { W "    --- raw first record ---"; W (($recs[0] | Format-List * | Out-String)) }
        }
        catch { W "    ERR Get-DnsServerResourceRecord '$short': $($_.Exception.Message)" }
    }

    W "### ALL A-records in zone matching cluster/listener/node prefixes (catch duplicates / orphan blanks) ###"
    try {
        $prefixes = @()
        foreach ($nm in ($Names | Where-Object { $_ })) {
            $s = $nm
            if ($s -like "*.$Domain") { $s = $s.Substring(0, $s.Length - ($Domain.Length + 1)) }
            # use the first 3 chars (deployment prefix, e.g. PT3) plus the full short name
            if ($s.Length -ge 3) { $prefixes += $s.Substring(0, 3) }
            $prefixes += $s
        }
        $prefixes = @($prefixes | Select-Object -Unique)
        $allA = @(Get-DnsServerResourceRecord -ZoneName $Domain -RRType A -ComputerName $env:COMPUTERNAME -ErrorAction Stop)
        $match = @($allA | Where-Object { $h = $_.HostName; ($prefixes | Where-Object { $h -like "$_*" }).Count -gt 0 })
        foreach ($rec in $match) {
            $ip = ''
            try { if ($rec.RecordData -and $rec.RecordData.IPv4Address) { $ip = $rec.RecordData.IPv4Address.IPAddressToString } } catch {}
            W ("    {0,-24} IPv4='{1}'  Timestamp='{2}'" -f $rec.HostName, $ip, $rec.Timestamp)
        }
        if (-not $match) { W "(no matching A records)" }
    }
    catch { W "ERR all-A scan: $($_.Exception.Message)" }

    W "### DNS Server event log -- recent registration/update events (last 20) ###"
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'DNS Server' } -MaxEvents 20 -ErrorAction SilentlyContinue)
        foreach ($e in $ev) { W ("[{0}] Id={1} {2}: {3}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName, (($e.Message -split "`r?`n")[0])) }
        if (-not $ev) { W "(no DNS Server log events)" }
    }
    catch { W "ERR DNS Server log: $($_.Exception.Message)" }

    return ($out -join "`r`n")
}

# ---------------------------------------------------------------------------
#  Orchestrate
# ---------------------------------------------------------------------------
$collectedNames = New-Object System.Collections.Generic.List[string]
foreach ($e in $ExtraNames) { if ($e) { $collectedNames.Add($e) } }

foreach ($node in $NodeVm) {
    Write-Host "Collecting from SQLAO node '$node' ..." -ForegroundColor Cyan
    try {
        $res = Invoke-Command -VMName $node -Credential $cred -ScriptBlock $nodeScript -ErrorAction Stop
        Add-Section -Title "SQLAO node: $node" -Body $res.Text
        if ($res.ClusterName) { $collectedNames.Add($res.ClusterName) }
        foreach ($l in $res.Listeners) { if ($l) { $collectedNames.Add($l) } }
        foreach ($n in $res.Nodes) { if ($n) { $collectedNames.Add($n) } }
        # record discovered IPs in the header so the DC dump is interpretable
        Add-Content -Path $outFile -Value ("    [discovered on $node] Cluster='{0}' Listeners='{1}' ClusterIPs='{2}' AgIPs='{3}'" -f `
                $res.ClusterName, ($res.Listeners -join ','), ($res.ClusterIPs -join ','), ($res.AgIPs -join ','))
    }
    catch {
        Add-Section -Title "SQLAO node: $node -- COLLECTION FAILED" -Body $_.Exception.Message
    }
}

# Always include the node short-names themselves so the DC dumps their A-records too.
foreach ($node in $NodeVm) { $collectedNames.Add($node) }
$namesForDc = @($collectedNames | Where-Object { $_ } | Select-Object -Unique)
Add-Content -Path $outFile -Value "`r`nNames queried on DC: $($namesForDc -join ', ')"

Write-Host "Collecting from DC / DNS '$DcVm' ..." -ForegroundColor Cyan
try {
    $dcOut = Invoke-Command -VMName $DcVm -Credential $cred -ScriptBlock $dcScript -ArgumentList $Domain, $namesForDc -ErrorAction Stop
    Add-Section -Title "DC / DNS: $DcVm ($Domain)" -Body $dcOut
}
catch {
    Add-Section -Title "DC / DNS: $DcVm -- COLLECTION FAILED" -Body $_.Exception.Message
}

Write-Host ""
Write-Host "Diagnostic written to:" -ForegroundColor Green
Write-Host "  $outFile"
