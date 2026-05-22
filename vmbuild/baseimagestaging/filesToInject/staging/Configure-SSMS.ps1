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

$sqlServers = @{}
foreach ($result in $results) {
    $spns = $result.Properties["serviceprincipalname"]
    $hostName = ($result.Properties["dnshostname"] | Select-Object -First 1) -as [string]
    Write-Log "  Computer: $hostName"
    foreach ($spn in $spns) {
        if ($spn -notlike "MSSQLSvc/*") { continue }
        Write-Log "    SPN: $spn"
        # SPN format: MSSQLSvc/hostname:port or MSSQLSvc/hostname:instance
        if ($spn -match '^MSSQLSvc/([^:]+)(?::(.+))?$') {
            $server = $Matches[1]
            $instanceOrPort = $Matches[2]

            # Skip port-based SPNs (numeric) to avoid duplicates; keep instance names and bare host
            if ($instanceOrPort -and $instanceOrPort -match '^\d+$') {
                Write-Log "      Skipped (port-only SPN)"
                continue
            }

            if ($instanceOrPort -and $instanceOrPort -ne "MSSQLSERVER") {
                $serverName = "$server\$instanceOrPort"
            }
            else {
                $serverName = $server
            }
            # Use short name (without domain suffix) as display
            $displayName = ($serverName -split '\.')[0]
            if ($serverName -match '\\') {
                $parts = $serverName -split '\\'
                $displayName = (($parts[0] -split '\.')[0]) + '\' + $parts[1]
            }
            $sqlServers[$displayName] = $serverName
            Write-Log "      Added: $displayName -> $serverName"
        }
    }
}

Write-Log "Total unique SQL servers discovered: $($sqlServers.Count)"
if ($sqlServers.Count -eq 0) {
    Write-Log "No SQL servers found. Exiting."
    return
}
foreach ($entry in $sqlServers.GetEnumerator() | Sort-Object Name) {
    Write-Log "  Server: $($entry.Key)"
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

foreach ($entry in $sqlServers.GetEnumerator() | Sort-Object Name) {
    $serverElement = $xml.CreateElement("RegisteredServers", "RegisteredServer", $ns)
    $serverElement.SetAttribute("id", (New-Guid).ToString())
    $serverElement.SetAttribute("name", $entry.Key)
    $serverElement.SetAttribute("description", "")

    $connInfo = $xml.CreateElement("RegisteredServers", "ConnectionInformation", $ns)

    $typeEl = $xml.CreateElement("RegisteredServers", "ServerType", $ns)
    $typeEl.InnerText = $dbEngineTypeId
    $connInfo.AppendChild($typeEl) | Out-Null

    $nameEl = $xml.CreateElement("RegisteredServers", "ServerName", $ns)
    $nameEl.InnerText = $entry.Key
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

# --- SSMS 20: Update UserSettings.xml (Trust Certificate + MRU server list) ---
if ($ssmsVersions | Where-Object { $_.Major -eq 20 }) {
    $ssms20Dir = Join-Path $env:APPDATA "Microsoft\SQL Server Management Studio\20.0"
    $settingsFile = Join-Path $ssms20Dir "UserSettings.xml"
    if (Test-Path $settingsFile) {
        Write-Log "Found SSMS 20 UserSettings.xml at: $settingsFile"
        try {
            $settingsXml = [xml](Get-Content $settingsFile -Raw)

            # Set AddTrustServerCertificate to Always (auto-checks the box)
            $trustNode = $settingsXml.SelectSingleNode("//CommandOptions/AddTrustServerCertificate")
            if ($trustNode) {
                if ($trustNode.InnerText -ne "Always") {
                    $trustNode.InnerText = "Always"
                    Write-Log "Set AddTrustServerCertificate = Always"
                }
                else {
                    Write-Log "AddTrustServerCertificate already set to Always"
                }
            }
            else {
                Write-Log "WARNING: AddTrustServerCertificate node not found in UserSettings.xml"
            }

            # Add servers to MRU list in ConnectionOptions/ServerTypes
            $serverTypesNode = $settingsXml.SelectSingleNode("//ConnectionOptions/ServerTypes")
            if ($serverTypesNode) {
                # Find the Database Engine Element (guid 8c91a03d-...)
                $dbEngineElement = $serverTypesNode.SelectSingleNode("Element[Key/guid='8c91a03d-f9b4-46c0-a305-b5dcc79ff907']")
                if ($dbEngineElement) {
                    $serversNode = $dbEngineElement.SelectSingleNode("Value/ServerTypeItem/Servers")
                    if ($serversNode) {
                        # Get existing server names
                        $existingServers = @()
                        foreach ($el in $serversNode.SelectNodes("Element/Item/ServerConnectionItem/Instance")) {
                            $existingServers += $el.InnerText
                        }
                        Write-Log "Existing MRU servers: $($existingServers -join ', ')"

                        $added = 0
                        foreach ($entry in $sqlServers.GetEnumerator() | Sort-Object Name) {
                            if ($entry.Key -notin $existingServers) {
                                $newElement = $settingsXml.CreateElement("Element")

                                $timeEl = $settingsXml.CreateElement("Time")
                                $longEl = $settingsXml.CreateElement("long")
                                $longEl.InnerText = [DateTime]::Now.Ticks.ToString()
                                $timeEl.AppendChild($longEl) | Out-Null
                                $newElement.AppendChild($timeEl) | Out-Null

                                $itemEl = $settingsXml.CreateElement("Item")
                                $sciEl = $settingsXml.CreateElement("ServerConnectionItem")
                                $instEl = $settingsXml.CreateElement("Instance")
                                $instEl.InnerText = $entry.Key
                                $sciEl.AppendChild($instEl) | Out-Null

                                $authMethodEl = $settingsXml.CreateElement("AuthenticationMethod")
                                $authMethodEl.InnerText = "0"
                                $sciEl.AppendChild($authMethodEl) | Out-Null

                                $connsEl = $settingsXml.CreateElement("Connections")
                                $sciEl.AppendChild($connsEl) | Out-Null

                                $itemEl.AppendChild($sciEl) | Out-Null
                                $newElement.AppendChild($itemEl) | Out-Null

                                $serversNode.AppendChild($newElement) | Out-Null
                                $added++
                            }
                        }
                        Write-Log "Added $added new server(s) to MRU list"
                    }
                }
                else {
                    Write-Log "WARNING: Database Engine ServerType element not found in ConnectionOptions"
                }
            }

            $settingsXml.Save($settingsFile)
            Write-Log "Saved updated UserSettings.xml"
        }
        catch {
            Write-Log "ERROR updating UserSettings.xml: $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "SSMS 20 UserSettings.xml not found at: $settingsFile (SSMS may not have been launched yet)"
    }
}

Write-Log "=== Configure-SSMS completed ==="
