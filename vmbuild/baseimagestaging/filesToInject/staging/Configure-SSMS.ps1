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

# --- Discover SQL Server instances from AD SPNs ---
Write-Log "Querying AD for MSSQLSvc SPNs..."
try {
    $searcher = [adsisearcher]"(servicePrincipalName=MSSQLSvc/*)"
    $searcher.PropertiesToLoad.Add("dNSHostName") | Out-Null
    $searcher.PropertiesToLoad.Add("servicePrincipalName") | Out-Null
    $results = $searcher.FindAll()
    Write-Log "AD query returned $($results.Count) computer object(s) with MSSQLSvc SPNs"
}
catch {
    Write-Log "ERROR: AD query failed: $($_.Exception.Message)"
    return
}

# Ordered list of connection targets. Local instances take precedence (added
# first), then AG listeners, then domain SQL servers discovered via SPNs.
# Dedupe is by connection string, first-wins, so a local instance shadows the
# domain SPN for the same box.
$serverList = New-Object 'System.Collections.Generic.List[object]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

function Add-ServerEntry {
    param(
        [string]$Display,
        [string]$Instance,
        [ValidateSet('Local', 'Listener', 'Domain')] [string]$Kind,
        [bool]$Encrypt = $true
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

# Pass 1: record all computer dNSHostNames so AG listeners (whose port-based
# SPNs live on the SQL service account, not a computer object) can be told
# apart from a real server's port SPN.
$computerShortNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($result in $results) {
    $dns = ($result.Properties["dnshostname"] | Select-Object -First 1) -as [string]
    if ($dns) { [void]$computerShortNames.Add(($dns -split '\.')[0]) }
}

# Pass 2: walk every MSSQLSvc SPN. Non-port SPNs => real servers; port SPNs on
# a non-computer host => AG listener (added as 'name,port').
Write-Log "Processing $($results.Count) AD object(s) with MSSQLSvc SPNs..."
foreach ($result in $results) {
    $spns = $result.Properties["serviceprincipalname"]
    foreach ($spn in $spns) {
        if ($spn -notlike "MSSQLSvc/*") { continue }
        if ($spn -notmatch '^MSSQLSvc/([^:]+)(?::(.+))?$') { continue }
        $spnHost = $Matches[1]
        $suffix = $Matches[2]
        $shortHost = ($spnHost -split '\.')[0]

        if ($suffix -and $suffix -match '^\d+$') {
            # Port-based SPN. If the host is NOT a known computer object it is
            # an Availability Group listener; register it as Name,Port.
            if (-not $computerShortNames.Contains($shortHost)) {
                Add-ServerEntry -Display "$shortHost,$suffix" -Instance "$shortHost,$suffix" -Kind Listener -Encrypt $true
            }
            continue
        }

        if ($suffix -and $suffix -ne 'MSSQLSERVER') {
            Add-ServerEntry -Display "$shortHost\$suffix" -Instance "$shortHost\$suffix" -Kind Domain -Encrypt $true
        }
        else {
            Add-ServerEntry -Display $shortHost -Instance $shortHost -Kind Domain -Encrypt $true
        }
    }
}

# --- Prefer the relevant AG listener at the very top of the list when this box
#     is itself a SQLAO node, or uses an AG listener as its (CM) database server
#     (e.g. a Primary whose CM DB lives on the AG). Uses the authoritative
#     deployConfig.json injected for DSC; all names there are already prefixed. ---
$deployConfigPath = "C:\staging\DSC\deployConfig.json"
if (Test-Path $deployConfigPath) {
    try {
        $dc = Get-Content $deployConfigPath -Raw | ConvertFrom-Json
        $vms = $dc.virtualMachines
        $thisName = $dc.parameters.ThisMachineName
        if (-not $thisName) { $thisName = $env:COMPUTERNAME }
        $me = $vms | Where-Object { $_.vmName -ieq $thisName } | Select-Object -First 1
        if (-not $me) { $me = $vms | Where-Object { $_.vmName -ieq $env:COMPUTERNAME } | Select-Object -First 1 }

        $listenerOwner = $null
        if ($me) {
            if ($me.role -eq 'SQLAO') {
                # This box is a cluster node -> prefer its own AG listener. The
                # passive node carries no AlwaysOnListenerName, so fall back to
                # the partner node that does.
                if ($me.AlwaysOnListenerName) { $listenerOwner = $me }
                else { $listenerOwner = $vms | Where-Object { $_.OtherNode -ieq $me.vmName -and $_.AlwaysOnListenerName } | Select-Object -First 1 }
            }
            elseif ($me.remoteSQLVM) {
                # This box uses a remote SQL server. If that server is an AG
                # node, prefer the listener it serves its databases through.
                $rsql = $vms | Where-Object { $_.vmName -ieq $me.remoteSQLVM } | Select-Object -First 1
                if ($rsql) {
                    if ($rsql.AlwaysOnListenerName) { $listenerOwner = $rsql }
                    else { $listenerOwner = $vms | Where-Object { $_.OtherNode -ieq $rsql.vmName -and $_.AlwaysOnListenerName } | Select-Object -First 1 }
                }
            }
        }

        if ($listenerOwner -and $listenerOwner.AlwaysOnListenerName) {
            $lname = $listenerOwner.AlwaysOnListenerName
            $lport = if ($listenerOwner.sqlPort) { $listenerOwner.sqlPort } else { '1433' }
            $lInstance = "$lname,$lport"

            # Reuse the already-discovered listener entry (any port) if present,
            # otherwise synthesize one from config (covers labs where the
            # listener has no Kerberos SPN registered).
            $existing = $serverList | Where-Object { $_.Kind -eq 'Listener' -and (($_.Instance -split ',')[0] -ieq $lname) } | Select-Object -First 1
            if ($existing) {
                [void]$serverList.Remove($existing)
                $serverList.Insert(0, $existing)
                Write-Log "Preferred AG listener moved to top: $($existing.Instance)"
            }
            elseif ($seen.Add($lInstance)) {
                $serverList.Insert(0, [pscustomobject]@{ Display = $lInstance; Instance = $lInstance; Kind = 'Listener'; Encrypt = $true })
                Write-Log "Preferred AG listener added at top: $lInstance"
            }
        }
    }
    catch {
        Write-Log "deployConfig listener-preference failed: $($_.Exception.Message)"
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
