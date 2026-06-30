# Configure-SSMS.ps1
# Pre-populates SSMS Registered Servers and MRU list with SQL instances discovered via AD SPNs.
# Sets TrustServerCertificate=True (always) so the checkbox is pre-checked.
# Idempotent: regenerates on each logon to pick up new SQL servers.

# --- Logging ---
$logDir = "C:\staging\Fix"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "Configure-SSMS.log"

function Write-Log {
    param([string]$Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
}

Write-Log "=== Configure-SSMS started (user: $env:USERNAME) ==="

# --- Detect installed SSMS version(s) ---
$ssmsVersions = @()
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 18; RegSrvrVersion = "150" }
    Write-Log "Detected SSMS 18"
}
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 19; RegSrvrVersion = "160" }
    Write-Log "Detected SSMS 19"
}
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 20; RegSrvrVersion = "170" }
    Write-Log "Detected SSMS 20"
}

if ($ssmsVersions.Count -eq 0) {
    Write-Log "No SSMS installation found. Exiting."
    return
}

# Ordered list of connection targets. Local SQL is added first (precedence),
# then every SQL endpoint discovered from MSSQLSvc SPNs across the domain.
# Dedupe is by connection string, first-wins, so a local instance shadows the
# domain SPN for the same box. Encryption is left Optional (EC=False) with
# Trust Server Certificate always on, so lab self-signed certs never block a
# connection.
$serverList = New-Object 'System.Collections.Generic.List[object]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

function Add-ServerEntry {
    param(
        [string]$Display,
        [string]$Instance,
        [ValidateSet('Local', 'Domain')] [string]$Kind,
        [bool]$Encrypt = $false
    )
    if ([string]::IsNullOrWhiteSpace($Instance)) { return }
    if (-not $seen.Add($Instance)) { return }
    $serverList.Add([pscustomobject]@{
            Display  = $Display
            Instance = $Instance
            Kind     = $Kind
            Encrypt  = $Encrypt
        }) | Out-Null
    Write-Log "  [$Kind] $Display -> $Instance"
}

function Add-WidSysadmin {
    # WID grants sysadmin only to BUILTIN\Administrators, which UAC token
    # filtering strips from a normal (non-elevated) logon -- so connecting to
    # WID in SSMS otherwise requires "Run as administrator". This script runs
    # elevated (scheduled task RunLevel Highest / Phase 10 fix), so the current
    # admin's full token is sysadmin on WID and can add an explicit login for
    # itself; future non-elevated SSMS sessions then connect without elevating.
    # WID's named pipe is local-only, so the current user is always the right
    # principal to grant. Idempotent.
    param([string]$PipeInstance)
    $login = "$env:USERDOMAIN\$env:USERNAME"
    Write-Log "Ensuring WID sysadmin login for $login (non-elevated SSMS access)..."
    $tsql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$login')
    CREATE LOGIN [$login] FROM WINDOWS;
IF IS_SRVROLEMEMBER('sysadmin', N'$login') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER [$login];
"@
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Data Source=np:$PipeInstance;Initial Catalog=master;Integrated Security=True;Connect Timeout=30"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $tsql
        [void]$cmd.ExecuteNonQuery()
        Write-Log "WID sysadmin login ensured for $login"
    }
    catch {
        Write-Log "WID sysadmin grant skipped/failed (needs elevated sysadmin on WID): $($_.Exception.Message)"
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
    }
}

# --- Local SQL instances first (precedence) ---
# SQL Express instances (e.g. CONFIGMGRSEC) and WID won't have AD SPNs, and
# the local box should always be at the top of the Connect list.
Write-Log "Discovering local SQL instances..."
$localServices = Get-Service -Name 'MSSQL$*', 'MSSQLSERVER' -ErrorAction SilentlyContinue
foreach ($svc in $localServices) {
    if ($svc.Name -eq 'MSSQLSERVER') {
        Add-ServerEntry -Display $env:COMPUTERNAME -Instance $env:COMPUTERNAME -Kind Local -Encrypt $false
    }
    elseif ($svc.Name -match '^MSSQL\$(.+)$') {
        $instName = $Matches[1]
        if ($instName -ieq 'MICROSOFT##WID') {
            # Windows Internal Database is only reachable via its named pipe.
            $widPipe = '\\.\pipe\MICROSOFT##WID\tsql\query'
            Add-ServerEntry -Display "$env:COMPUTERNAME\WID" -Instance $widPipe -Kind Local -Encrypt $false
            Add-WidSysadmin -PipeInstance $widPipe
        }
        else {
            Add-ServerEntry -Display "$env:COMPUTERNAME\$instName" -Instance "$env:COMPUTERNAME\$instName" -Kind Local -Encrypt $false
        }
    }
}

# --- Dump every MSSQLSvc SPN in the domain and collapse per host ---
# SQL frequently runs under a domain service account, so its SPNs live on the
# account object, not the computer -- distinguishing "real server vs listener"
# from SPNs alone is unreliable. Instead, group all SPNs by host and emit ONE
# connection target per server: host\instance for a named instance, host,port
# for a non-default port, or bare host for the default instance on 1433. This
# drops the redundant :1433 / :MSSQLSERVER duplicates automatically and treats
# AG listeners exactly like any other host (e.g. KETCHUP,1500).
Write-Log "Querying AD for all MSSQLSvc SPNs..."
$spnHosts = @{}
try {
    $searcher = [adsisearcher]"(servicePrincipalName=MSSQLSvc/*)"
    $searcher.PageSize = 500
    [void]$searcher.PropertiesToLoad.Add("servicePrincipalName")
    $adResults = $searcher.FindAll()
    Write-Log "AD returned $($adResults.Count) object(s) with MSSQLSvc SPNs"
}
catch {
    Write-Log "ERROR: AD query failed: $($_.Exception.Message)"
    $adResults = @()
}

foreach ($result in $adResults) {
    foreach ($spn in $result.Properties["serviceprincipalname"]) {
        if ($spn -notmatch '^MSSQLSvc/([^:]+)(?::(.+))?$') { continue }
        $short = (($Matches[1]) -split '\.')[0]
        $suffix = $Matches[2]
        if (-not $spnHosts.ContainsKey($short)) {
            $spnHosts[$short] = @{ Named = @{}; Ports = @{}; HasDefault = $false }
        }
        $h = $spnHosts[$short]
        if (-not $suffix -or $suffix -ieq 'MSSQLSERVER') { $h.HasDefault = $true }
        elseif ($suffix -match '^\d+$') { $h.Ports[$suffix] = $true }
        else { $h.Named[$suffix] = $true }
    }
}

foreach ($short in ($spnHosts.Keys | Sort-Object)) {
    $h = $spnHosts[$short]
    $named = @($h.Named.Keys)
    $nonDefaultPorts = @($h.Ports.Keys | Where-Object { $_ -ne '1433' })
    if ($named.Count -gt 0) {
        # Named instance(s) -> connect via host\instance (SQL Browser resolves).
        foreach ($inst in $named) {
            Add-ServerEntry -Display "$short\$inst" -Instance "$short\$inst" -Kind Domain
        }
    }
    elseif ($nonDefaultPorts.Count -gt 0) {
        # Default-style endpoint (incl. AG listeners) on a non-default port.
        foreach ($p in $nonDefaultPorts) {
            Add-ServerEntry -Display "$short,$p" -Instance "$short,$p" -Kind Domain
        }
    }
    else {
        # Default instance on 1433 -> bare host (drops the :1433 duplicate).
        Add-ServerEntry -Display $short -Instance $short -Kind Domain
    }
}

# --- Float the SQL endpoints THIS machine's roles use to the top ---
# Detect the databases this box actually talks to and pull them to the front in
# priority order:
#   1. A SQLAO node's own AG listener.
#   2. The ConfigMgr site database (used by a Site Server itself, and by the
#      Management Point / Reporting point / SMS Provider site systems of that
#      site).
#   3. The WSUS / SUSDB (which may be WID) -- so WID lands right after a role DB
#      when the box has both, or first when WSUS is its only DB.
# We only ever MOVE already-discovered entries (matched by host), so SPN ports
# are preserved and no duplicate is created. deployConfig.json is used purely
# for this ordering; discovery above is pure SPN + local services. All config
# names are already prefixed.
$deployConfigPath = "C:\staging\DSC\deployConfig.json"
if (Test-Path $deployConfigPath) {
    try {
        $dc = Get-Content $deployConfigPath -Raw | ConvertFrom-Json
        $vms = $dc.virtualMachines
        $thisName = $dc.parameters.ThisMachineName
        if (-not $thisName) { $thisName = $env:COMPUTERNAME }
        $me = $vms | Where-Object { $_.vmName -ieq $thisName } | Select-Object -First 1
        if (-not $me) { $me = $vms | Where-Object { $_.vmName -ieq $env:COMPUTERNAME } | Select-Object -First 1 }

        # Resolve a SQL-hosting VM to its connection host: AG listener if it is
        # an AlwaysOn node (or the partner of one), otherwise the VM's own name.
        function Resolve-SqlHost {
            param($sqlVm)
            if (-not $sqlVm) { return $null }
            if ($sqlVm.AlwaysOnListenerName) { return $sqlVm.AlwaysOnListenerName }
            $partner = $vms | Where-Object { $_.OtherNode -ieq $sqlVm.vmName -and $_.AlwaysOnListenerName } | Select-Object -First 1
            if ($partner) { return $partner.AlwaysOnListenerName }
            return $sqlVm.vmName
        }

        $siteRoles = @('CAS', 'Primary', 'Secondary')
        $targets = New-Object 'System.Collections.Generic.List[object]'

        if ($me) {
            # 1. SQLAO node -> its own AG listener.
            if ($me.role -eq 'SQLAO') {
                $ln = Resolve-SqlHost $me
                if ($ln) { $targets.Add(@{ Type = 'Host'; Value = $ln }) }
            }

            # 2. ConfigMgr site DB (Site Server itself, or the MP / RP / SMS
            #    Provider site systems belonging to the same site).
            $siteServer = $null
            if ($me.role -in $siteRoles) { $siteServer = $me }
            elseif ($me.siteCode) {
                $siteServer = $vms | Where-Object { $_.role -in $siteRoles -and $_.siteCode -ieq $me.siteCode } | Select-Object -First 1
            }
            if ($siteServer) {
                if ($siteServer.remoteSQLVM) {
                    $sqlVm = $vms | Where-Object { $_.vmName -ieq $siteServer.remoteSQLVM } | Select-Object -First 1
                    if ($sqlVm) { $targets.Add(@{ Type = 'Host'; Value = (Resolve-SqlHost $sqlVm) }) }
                    else { $targets.Add(@{ Type = 'Host'; Value = $siteServer.remoteSQLVM }) }
                }
                else {
                    $targets.Add(@{ Type = 'Host'; Value = $siteServer.vmName })
                }
            }

            # 3. WSUS / SUSDB (WID floats here, so it lands after a site DB).
            $hasWsus = ($me.role -eq 'WSUS') -or ($me.installSUP -eq $true)
            if ($hasWsus) {
                if ($me.wsusDataBaseServer -and $me.wsusDataBaseServer -ieq 'WID') { $targets.Add(@{ Type = 'WID' }) }
                elseif ($me.wsusDataBaseServer) { $targets.Add(@{ Type = 'Host'; Value = $me.wsusDataBaseServer }) }
                elseif ($me.sqlVersion) { $targets.Add(@{ Type = 'Host'; Value = $me.vmName }) }
                elseif ($me.remoteSQLVM) {
                    $sqlVm = $vms | Where-Object { $_.vmName -ieq $me.remoteSQLVM } | Select-Object -First 1
                    if ($sqlVm) { $targets.Add(@{ Type = 'Host'; Value = (Resolve-SqlHost $sqlVm) }) }
                    else { $targets.Add(@{ Type = 'Host'; Value = $me.remoteSQLVM }) }
                }
                else { $targets.Add(@{ Type = 'WID' }) }
            }
        }

        # Match each target to a discovered entry (skipping dupes) in priority
        # order, then move the matched set to the very front keeping that order.
        $promoted = New-Object 'System.Collections.Generic.List[object]'
        $promotedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $targets) {
            $hit = $null
            if ($t.Type -eq 'WID') {
                $hit = $serverList | Where-Object { $_.Instance -like '*MICROSOFT##WID*' -and -not $promotedKeys.Contains($_.Instance) } | Select-Object -First 1
            }
            elseif ($t.Value) {
                $hn = $t.Value
                $hit = $serverList | Where-Object { (($_.Instance -split '[\\,]')[0]) -ieq $hn -and -not $promotedKeys.Contains($_.Instance) } | Select-Object -First 1
            }
            if ($hit) { [void]$promoted.Add($hit); [void]$promotedKeys.Add($hit.Instance) }
        }

        if ($promoted.Count -gt 0) {
            foreach ($p in $promoted) { [void]$serverList.Remove($p) }
            for ($i = $promoted.Count - 1; $i -ge 0; $i--) { $serverList.Insert(0, $promoted[$i]) }
            Write-Log ("Prioritized this machine's role DBs to top: " + (($promoted | ForEach-Object { $_.Instance }) -join ', '))
        }
    }
    catch {
        Write-Log "deployConfig preference failed: $($_.Exception.Message)"
    }
}

Write-Log "Total connection targets discovered: $($serverList.Count)"
if ($serverList.Count -eq 0) {
    Write-Log "No SQL servers found. Exiting."
    return
}

# --- Build RegSrvr.xml content ---
$ns = "http://schemas.microsoft.com/sqlserver/RegisteredServers/2007/08"
$dbEngineTypeId = "8c91a03d-f9b4-46c0-a305-b5dcc79ff907"

$xml = [xml]@"
<?xml version="1.0" encoding="utf-8"?>
<RegisteredServers:RegisteredServers xmlns:RegisteredServers="$ns">
  <RegisteredServers:ServerType id="$dbEngineTypeId" name="Database Engine">
    <RegisteredServers:Group id="$(New-Guid)" name="DatabaseEngineServerGroup" description="" isSystemGroup="true">
    </RegisteredServers:Group>
  </RegisteredServers:ServerType>
</RegisteredServers:RegisteredServers>
"@

$groupNode = $xml.SelectSingleNode("//*[local-name()='Group']")

foreach ($entry in $serverList) {
    $serverElement = $xml.CreateElement("RegisteredServers", "RegisteredServer", $ns)
    $serverElement.SetAttribute("id", (New-Guid).ToString())
    $serverElement.SetAttribute("name", $entry.Display)
    $serverElement.SetAttribute("description", "")

    $connInfo = $xml.CreateElement("RegisteredServers", "ConnectionInformation", $ns)

    $typeEl = $xml.CreateElement("RegisteredServers", "ServerType", $ns)
    $typeEl.InnerText = $dbEngineTypeId
    $connInfo.AppendChild($typeEl) | Out-Null

    $nameEl = $xml.CreateElement("RegisteredServers", "ServerName", $ns)
    $nameEl.InnerText = $entry.Instance
    $connInfo.AppendChild($nameEl) | Out-Null

    $authEl = $xml.CreateElement("RegisteredServers", "AuthenticationType", $ns)
    $authEl.InnerText = "0" # Windows Authentication
    $connInfo.AppendChild($authEl) | Out-Null

    $userEl = $xml.CreateElement("RegisteredServers", "UserName", $ns)
    $userEl.InnerText = ""
    $connInfo.AppendChild($userEl) | Out-Null

    $passEl = $xml.CreateElement("RegisteredServers", "Password", $ns)
    $passEl.InnerText = ""
    $connInfo.AppendChild($passEl) | Out-Null

    $advEl = $xml.CreateElement("RegisteredServers", "AdvancedOptions", $ns)
    $advEl.InnerText = ";COLUMN ENCRYPTION SETTING=Disabled;TRUST SERVER CERTIFICATE=True"
    $connInfo.AppendChild($advEl) | Out-Null

    $serverElement.AppendChild($connInfo) | Out-Null
    $groupNode.AppendChild($serverElement) | Out-Null
}

# --- Write RegSrvr.xml for each installed SSMS version ---
foreach ($ver in $ssmsVersions) {
    $regSrvrDir = Join-Path $env:APPDATA "Microsoft\Microsoft SQL Server\$($ver.RegSrvrVersion)\Tools\Shell"
    if (-not (Test-Path $regSrvrDir)) {
        New-Item -Path $regSrvrDir -ItemType Directory -Force | Out-Null
    }
    $regSrvrPath = Join-Path $regSrvrDir "RegSrvr.xml"
    $xml.Save($regSrvrPath)
    Write-Log "Wrote RegSrvr.xml to: $regSrvrPath"
}

# --- Update SSMS UserSettings.xml MRU ("Connect to Server" list) ---
# SSMS stores the MRU as a deeply-nested ServerConnectionItem with a populated
# Connections/ServerConnectionSettings/Advanced block. Anything that does not
# match that schema is silently discarded by SSMS on its next save, so we emit
# the exact structure SSMS itself writes (TSC=True pre-checks Trust Cert).

function New-MruEntryXml {
    param(
        [string]$Instance,
        [bool]$Encrypt,
        [long]$TimeLong,
        [string]$UserName,
        [string]$ServerTypeGuid
    )
    $inst = [System.Security.SecurityElement]::Escape($Instance)
    $user = [System.Security.SecurityElement]::Escape($UserName)
    $ec = if ($Encrypt) { 'True' } else { 'False' }
    return @"
        <Element>
          <Time>
            <long>$TimeLong</long>
          </Time>
          <Item>
            <ServerConnectionItem>
              <Instance>$inst</Instance>
              <AuthenticationMethod>0</AuthenticationMethod>
              <Connections>
                <Element>
                  <Time>
                    <long>$TimeLong</long>
                  </Time>
                  <Item>
                    <ServerConnectionSettings>
                      <Instance>$inst</Instance>
                      <UserName>$user</UserName>
                      <ServerType>$ServerTypeGuid</ServerType>
                      <AuthenticationMethod>0</AuthenticationMethod>
                      <Database />
                      <Advanced>
                        <Element><Key><string>IniDb</string></Key><Value /></Element>
                        <Element><Key><string>CT</string></Key><Value><string>30</string></Value></Element>
                        <Element><Key><string>ET</string></Key><Value><string>0</string></Value></Element>
                        <Element><Key><string>PSize</string></Key><Value><string>4096</string></Value></Element>
                        <Element><Key><string>EC</string></Key><Value><string>$ec</string></Value></Element>
                        <Element><Key><string>UCCC</string></Key><Value><string>False</string></Value></Element>
                        <Element><Key><string>CCC</string></Key><Value><string>-986896</string></Value></Element>
                        <Element><Key><string>TSC</string></Key><Value><string>True</string></Value></Element>
                        <Element><Key><string>HNIC</string></Key><Value><string /></Value></Element>
                        <Element><Key><string>UCTI</string></Key><Value><string>False</string></Value></Element>
                        <Element><Key><string>CTI</string></Key><Value><string /></Value></Element>
                        <Element><Key><string>CES</string></Key><Value /></Element>
                        <Element><Key><string>CESEnclave</string></Key><Value /></Element>
                        <Element><Key><string>CESProtocol</string></Key><Value /></Element>
                        <Element><Key><string>CESUrl</string></Key><Value /></Element>
                        <Element><Key><string>SCV</string></Key><Value><string>5</string></Value></Element>
                        <Element><Key><string>Prot</string></Key><Value /></Element>
                      </Advanced>
                    </ServerConnectionSettings>
                  </Item>
                </Element>
              </Connections>
            </ServerConnectionItem>
          </Item>
        </Element>
"@
}

function Update-UserSettings {
    param(
        [string]$SettingsFile,
        $ServerList,
        [string]$ServerTypeGuid
    )

    $userName = "$env:USERDOMAIN\$env:USERNAME"
    # Descending Time so the first (local) entries sort to the top of the MRU.
    $baseTicks = [DateTime]::UtcNow.Ticks
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $ServerList.Count; $i++) {
        $e = $ServerList[$i]
        $t = $baseTicks - ($i * 10000000)
        [void]$sb.AppendLine((New-MruEntryXml -Instance $e.Instance -Encrypt $e.Encrypt -TimeLong $t -UserName $userName -ServerTypeGuid $ServerTypeGuid))
    }
    $serversInner = $sb.ToString()

    if (-not (Test-Path $SettingsFile)) {
        # SSMS has never been launched, so the file doesn't exist yet. Lay down
        # a minimal skeleton; SSMS fills in defaults for everything else on load.
        $dir = Split-Path $SettingsFile -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $skeleton = @"
<?xml version="1.0"?>
<SqlStudio xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <SSMS>
    <CommandOptions>
      <AddTrustServerCertificate>Always</AddTrustServerCertificate>
    </CommandOptions>
    <ConnectionOptions>
      <LastServerType>$ServerTypeGuid</LastServerType>
      <LastAuthenticationMethod>0</LastAuthenticationMethod>
      <ServerTypes>
        <Element>
          <Key>
            <guid>$ServerTypeGuid</guid>
          </Key>
          <Value>
            <ServerTypeItem>
              <Servers>
$serversInner
              </Servers>
            </ServerTypeItem>
          </Value>
        </Element>
      </ServerTypes>
    </ConnectionOptions>
  </SSMS>
</SqlStudio>
"@
        Set-Content -Path $SettingsFile -Value $skeleton -Encoding UTF8
        Write-Log "Created UserSettings.xml skeleton with $($ServerList.Count) server(s): $SettingsFile"
        return
    }

    try {
        $settingsXml = [xml](Get-Content $SettingsFile -Raw)

        $trustNode = $settingsXml.SelectSingleNode("//CommandOptions/AddTrustServerCertificate")
        if ($trustNode) { $trustNode.InnerText = "Always" }

        $serverTypesNode = $settingsXml.SelectSingleNode("//ConnectionOptions/ServerTypes")
        if (-not $serverTypesNode) {
            Write-Log "WARNING: ConnectionOptions/ServerTypes missing in $SettingsFile"
            return
        }

        $dbEngineElement = $serverTypesNode.SelectSingleNode("Element[Key/guid='$ServerTypeGuid']")
        if (-not $dbEngineElement) {
            $frag = $settingsXml.CreateDocumentFragment()
            $frag.InnerXml = "<Element><Key><guid>$ServerTypeGuid</guid></Key><Value><ServerTypeItem><Servers></Servers></ServerTypeItem></Value></Element>"
            $serverTypesNode.AppendChild($frag) | Out-Null
            $dbEngineElement = $serverTypesNode.SelectSingleNode("Element[Key/guid='$ServerTypeGuid']")
        }

        $serversNode = $dbEngineElement.SelectSingleNode("Value/ServerTypeItem/Servers")
        if (-not $serversNode) {
            Write-Log "WARNING: Servers node missing in $SettingsFile"
            return
        }

        # Authoritative rebuild: regenerate the list from current lab inventory
        # each logon (drops stale/broken entries, applies local-first ordering).
        $serversNode.RemoveAll()
        $frag = $settingsXml.CreateDocumentFragment()
        $frag.InnerXml = $serversInner
        $serversNode.AppendChild($frag) | Out-Null

        $settingsXml.Save($SettingsFile)
        Write-Log "Updated UserSettings.xml ($($ServerList.Count) servers): $SettingsFile"
    }
    catch {
        Write-Log "ERROR updating UserSettings.xml ($SettingsFile): $($_.Exception.Message)"
    }
}

foreach ($ver in $ssmsVersions) {
    $settingsFile = Join-Path $env:APPDATA "Microsoft\SQL Server Management Studio\$($ver.Major).0\UserSettings.xml"
    Update-UserSettings -SettingsFile $settingsFile -ServerList $serverList -ServerTypeGuid $dbEngineTypeId
}

Write-Log "=== Configure-SSMS completed ==="
