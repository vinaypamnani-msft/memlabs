# Configure-SSMS.ps1
# Pre-populates SSMS Registered Servers with all SQL instances discovered via AD SPNs.
# Sets TrustServerCertificate=True on each registered connection.
# Idempotent: regenerates the file on each logon to pick up new SQL servers.

# --- Detect installed SSMS version(s) ---
$ssmsVersions = @()
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 18; RegSrvrVersion = "150" }
}
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 19; RegSrvrVersion = "160" }
}
if (Test-Path "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe") {
    $ssmsVersions += @{ Major = 20; RegSrvrVersion = "170" }
}

if ($ssmsVersions.Count -eq 0) { return }

# --- Discover SQL Server instances from AD SPNs ---
try {
    $searcher = [adsisearcher]"(servicePrincipalName=MSSQLSvc/*)"
    $searcher.PropertiesToLoad.Add("dNSHostName") | Out-Null
    $searcher.PropertiesToLoad.Add("servicePrincipalName") | Out-Null
    $results = $searcher.FindAll()
}
catch {
    return # AD not available (workgroup, network issue)
}

$sqlServers = @{}
foreach ($result in $results) {
    $spns = $result.Properties["serviceprincipalname"]
    $hostName = ($result.Properties["dnshostname"] | Select-Object -First 1) -as [string]
    foreach ($spn in $spns) {
        # SPN format: MSSQLSvc/hostname:port or MSSQLSvc/hostname:instance
        if ($spn -match '^MSSQLSvc/([^:]+)(?::(.+))?$') {
            $server = $Matches[1]
            $instanceOrPort = $Matches[2]

            # Skip port-based SPNs (numeric) to avoid duplicates; keep instance names
            if ($instanceOrPort -and $instanceOrPort -match '^\d+$') { continue }

            if ($instanceOrPort -and $instanceOrPort -ne "MSSQLSERVER") {
                $serverName = "$server\$instanceOrPort"
            }
            else {
                $serverName = $server
            }
            # Use short name (without domain suffix) as display, full as connection
            $displayName = ($serverName -split '\.')[0]
            if ($serverName -match '\\') {
                $parts = $serverName -split '\\'
                $displayName = (($parts[0] -split '\.')[0]) + '\' + $parts[1]
            }
            $sqlServers[$displayName] = $serverName
        }
    }
}

if ($sqlServers.Count -eq 0) { return }

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
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$nsMgr.AddNamespace("rs", $ns)

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
}

# --- SSMS 20: Also set TrustServerCertificate in user settings ---
if ($ssmsVersions | Where-Object { $_.Major -eq 20 }) {
    $ssms20Dir = Join-Path $env:APPDATA "Microsoft\SQL Server Management Studio\20.0"
    if (Test-Path $ssms20Dir) {
        $settingsFile = Join-Path $ssms20Dir "UserSettings.json"
        if (Test-Path $settingsFile) {
            try {
                $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
                if (-not $settings.PSObject.Properties['trustServerCertificate']) {
                    $settings | Add-Member -NotePropertyName 'trustServerCertificate' -NotePropertyValue $true
                    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
                }
                elseif ($settings.trustServerCertificate -ne $true) {
                    $settings.trustServerCertificate = $true
                    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
                }
            }
            catch {}
        }
    }
}
