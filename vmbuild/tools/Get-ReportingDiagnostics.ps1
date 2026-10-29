<#
.SYNOPSIS
    Collects reporting evidence locally or from the Hyper-V host.
.DESCRIPTION
    With VMName, run elevated on the MemLabs Hyper-V host. Uses PowerShell Direct
    and the existing MemLabs domain credentials; no guest file copy or WinRM needed.
    Without VMName, run locally in Windows PowerShell 5.1 as a domain administrator.
    Does not install software, restart services, modify databases, or change
    configuration. Writes JSON on the calling machine, or returns JSON with AsJson.
    Does not launch a browser or modify its profile.
    SOAP/catalog access, HTTP responses, and browser versions are recorded
    separately: a working SOAP root does not prove reports exist or the portal works.
.EXAMPLE
    .\vmbuild\tools\Get-ReportingDiagnostics.ps1 -VMName PKIPS1SQL -SiteCode PS1
.EXAMPLE
    powershell.exe -NoProfile -File .\Get-ReportingDiagnostics.ps1 -SiteCode PS1
.EXAMPLE
    .\Get-ReportingDiagnostics.ps1 -SiteCode PS1 -ReportServerUri http://localhost/ReportServer
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $VMName,
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string] $SiteCode,
    [uri] $ReportServerUri,
    [string] $OutputPath,
    [switch] $AsJson
)

$ErrorActionPreference = 'Stop'

function Get-ReportingCatalogEvidence {
    param([Parameter(Mandatory)] $Proxy, [string] $SiteCode)

    $rootType = "$($Proxy.GetItemType('/'))"
    if ($rootType -ne 'Folder') { throw "SOAP root has unexpected type '$rootType'." }
    $rootItems = @($Proxy.ListChildren('/', $false))
    $expectedFolder = if ($SiteCode) { "/ConfigMgr_$SiteCode" } else { $null }
    $folders = @($rootItems | Where-Object {
            $_.TypeName -eq 'Folder' -and
            $(if ($expectedFolder) { $_.Path -eq $expectedFolder } else { $_.Name -like 'ConfigMgr_*' })
        })
    $folderEvidence = @(
        foreach ($folder in $folders) {
            $items = @($Proxy.ListChildren($folder.Path, $true))
            $reports = @($items | Where-Object { $_.TypeName -eq 'Report' })
            [pscustomobject]@{
                Path = $folder.Path
                ReportCount = $reports.Count
                ReportSamples = @($reports | Select-Object -First 5 -ExpandProperty Path)
            }
        }
    )
    $reportCount = 0
    foreach ($folder in $folderEvidence) { $reportCount += $folder.ReportCount }
    [pscustomobject]@{
        RootType = $rootType
        ExpectedFolder = $expectedFolder
        ConfigMgrFolderFound = ($folders.Count -gt 0)
        ReportCount = $reportCount
        Folders = $folderEvidence
    }
}

function Get-ReportingPortalEvidence {
    param([Parameter(Mandatory)][uri] $PortalUri)

    $page = Invoke-WebRequest -Uri $PortalUri -UseDefaultCredentials -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $html = [string] $page.Content
    $baseUri = $PortalUri
    if ($page.BaseResponse.ResponseUri) { $baseUri = $page.BaseResponse.ResponseUri }
    $baseMatch = [regex]::Match($html, '(?is)<base\b[^>]*\bhref\s*=\s*["'']([^"'']+)')
    if ($baseMatch.Success) { $baseUri = [uri]::new($baseUri, $baseMatch.Groups[1].Value) }
    $scripts = @(
        foreach ($match in [regex]::Matches($html, '(?is)<script\b[^>]*\bsrc\s*=\s*["'']([^"'']+)') | Select-Object -First 8) {
            $assetUri = [uri]::new($baseUri, [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value))
            $asset = [ordered]@{ Uri = $assetUri.AbsoluteUri; StatusCode = $null; ContentType = $null; Error = $null }
            if ($assetUri.Authority -ne $PortalUri.Authority -or $assetUri.Scheme -ne $PortalUri.Scheme) {
                $asset.Error = 'External asset not requested; credentials are only sent to the portal origin.'
            }
            else {
                try {
                    $response = Invoke-WebRequest -Uri $assetUri -UseDefaultCredentials -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $asset.StatusCode = [int] $response.StatusCode
                    $asset.ContentType = [string] $response.Headers['Content-Type']
                    if (-not $response.Content -or $asset.ContentType -match 'text/html') {
                        $asset.Error = 'Script request returned an empty body or HTML rather than JavaScript.'
                    }
                }
                catch {
                    $asset.Error = $_.Exception.ToString()
                    if ($_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                        $asset.StatusCode = [int] $_.Exception.Response.StatusCode
                    }
                }
            }
            [pscustomobject] $asset
        }
    )
    $api = [ordered]@{ Uri = "$($PortalUri.AbsoluteUri.TrimEnd('/'))/api/v2.0/CatalogItems?`$top=1"; StatusCode = $null; Error = $null }
    try {
        $response = Invoke-WebRequest -Uri $api.Uri -UseDefaultCredentials -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $api.StatusCode = [int] $response.StatusCode
        $document = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if ('value' -notin $document.PSObject.Properties.Name) { throw 'Portal REST response has no OData value collection.' }
    }
    catch {
        $api.Error = $_.Exception.ToString()
        if ($_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
            $api.StatusCode = [int] $_.Exception.Response.StatusCode
        }
    }
    [pscustomobject]@{
        Uri = $PortalUri.AbsoluteUri
        StatusCode = [int] $page.StatusCode
        HtmlLength = $html.Length
        Title = [regex]::Match($html, '(?is)<title[^>]*>(.*?)</title>').Groups[1].Value
        ScriptAssets = $scripts
        RestApi = [pscustomobject] $api
        Note = 'HTTP/asset success is not a browser-rendering test.'
    }
}

function Get-ReportingSqlReportCount {
    param([Parameter(Mandatory)] $Configuration, [string] $SiteCode)

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder.DataSource = $Configuration.DatabaseServerName
    $builder.InitialCatalog = $Configuration.DatabaseName
    $builder.IntegratedSecurity = $true
    $builder.TrustServerCertificate = $true
    $builder.ConnectTimeout = 15
    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $command = $connection.CreateCommand()
    try {
        $command.CommandTimeout = 20
        $command.CommandText = 'SELECT COUNT_BIG(*) FROM dbo.Catalog WHERE [Type] = 2 AND LEFT([Path], LEN(@Prefix)) = @Prefix'
        $prefix = if ($SiteCode) { "/ConfigMgr_$SiteCode/" } else { '/ConfigMgr_' }
        $null = $command.Parameters.Add('@Prefix', [System.Data.SqlDbType]::NVarChar, 425)
        $command.Parameters['@Prefix'].Value = $prefix
        $connection.Open()
        [long] $command.ExecuteScalar()
    }
    finally { $command.Dispose(); $connection.Dispose() }
}

if ($ReportServerUri -and (-not $ReportServerUri.IsAbsoluteUri -or $ReportServerUri.Scheme -notin @('http', 'https') -or $ReportServerUri.UserInfo)) {
    throw 'ReportServerUri must be an absolute HTTP(S) URL without embedded credentials.'
}
if ($AsJson -and $PSBoundParameters.ContainsKey('OutputPath')) {
    throw 'Use either AsJson or OutputPath, not both.'
}
if ($VMName) {
    $targetVmName = $VMName
    $collectorSource = Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction Stop
    if (-not (Get-Command Invoke-VmCommand -ErrorAction Ignore) -or -not (Get-Command Get-VMNote -ErrorAction Ignore)) {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.ps1') -InJob
    }
    $note = Get-VMNote -VMName $targetVmName
    if (-not $note -or [string]::IsNullOrWhiteSpace("$($note.domain)") -or $note.domain -eq 'WORKGROUP') {
        throw "Cannot resolve a MemLabs domain for '$targetVmName'. Run elevated on its Hyper-V host; local collection remains available without VMName."
    }
    $guestCollector = {
        param($Source, $SiteCode, $ReportServerUri)
        $collectorArguments = @{ AsJson = $true }
        if ($SiteCode) { $collectorArguments.SiteCode = $SiteCode }
        if ($ReportServerUri) { $collectorArguments.ReportServerUri = $ReportServerUri }
        & ([scriptblock]::Create($Source)) @collectorArguments
    }
    $vmResult = Invoke-VmCommand -VmName $targetVmName -VmDomainName $note.domain `
        -ScriptBlock $guestCollector -ArgumentList $collectorSource, $SiteCode, "$ReportServerUri" `
        -DisplayName 'Collect reporting diagnostics' -AsJob -TimeoutSeconds 600 `
        -RequireDomainIdentity -FailOnRemoteError -SuppressLog
    if (-not $vmResult -or -not $vmResult.CommandResult -or $vmResult.ScriptBlockFailed) {
        $detail = if ($vmResult.ErrorDetails) { $vmResult.ErrorDetails -join '; ' } else { 'No successful guest result was returned.' }
        throw "Reporting diagnostics failed on '$targetVmName': $detail"
    }
    $payload = @($vmResult.ScriptBlockOutput)
    if ($payload.Count -ne 1 -or $payload[0] -isnot [string] -or [string]::IsNullOrWhiteSpace($payload[0])) {
        throw "Reporting diagnostics on '$targetVmName' did not return one JSON document."
    }
    $document = $payload[0] | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @('ComputerName', 'CollectedAt', 'Endpoints', 'CollectionErrors')) {
        if ($property -notin $document.PSObject.Properties.Name) {
            throw "Reporting diagnostics on '$targetVmName' returned JSON without '$property'."
        }
    }
    if ($AsJson) { return $payload[0] }
    if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP "$targetVmName-ReportingDiagnostics.json" }
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $payload[0] | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
    Write-Host "Reporting evidence for $targetVmName saved on the host to $OutputPath"
    Get-Item -LiteralPath $OutputPath -ErrorAction Stop
    return
}
if (-not (Get-Command New-WebServiceProxy -ErrorAction Ignore)) {
    throw 'For local collection, use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7. Host collection with VMName supports PowerShell 7.'
}
if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP "$env:COMPUTERNAME-ReportingDiagnostics.json" }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$evidence = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    CollectedAt = (Get-Date).ToString('o')
    SiteCode = $SiteCode
    OperatingSystem = $null
    Services = @()
    EdgeUpdateTasks = @()
    Browsers = @()
    ReportServerConfiguration = @()
    Endpoints = @()
    SqlCatalog = @()
    Logs = @()
    CollectionErrors = [System.Collections.Generic.List[string]]::new()
    Note = 'Collection only; no service, database, browser-update, or Reporting Services configuration is changed.'
}
try {
    $evidence.OperatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop |
        Select-Object Caption, Version, BuildNumber
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $fqdn = "$($computer.DNSHostName).$($computer.Domain)"
}
catch { throw "Cannot identify the local reporting VM: $($_.Exception.Message)" }
try {
    $evidence.Services = @(Get-CimInstance Win32_Service -Filter "Name='PowerBIReportServer' OR Name='SQLServerReportingServices' OR Name LIKE 'ReportServer%' OR Name='edgeupdate' OR Name='edgeupdatem' OR Name='MicrosoftEdgeElevationService'" -ErrorAction Stop |
            Select-Object Name, State, StartMode, PathName)
}
catch { $evidence.CollectionErrors.Add("Service inventory: $($_.Exception.Message)") }
try {
    $evidence.EdgeUpdateTasks = @(Get-ScheduledTask -ErrorAction Stop |
            Where-Object { $_.TaskName -like '*MicrosoftEdgeUpdate*' } | Select-Object TaskName, TaskPath, State)
}
catch { $evidence.CollectionErrors.Add("Edge Update tasks: $($_.Exception.Message)") }
foreach ($directory in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) | Where-Object { $_ } | Select-Object -Unique) {
    $path = Join-Path $directory 'Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $path) {
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        $evidence.Browsers += [pscustomobject]@{ Path = $file.FullName; Version = $file.VersionInfo.ProductVersion }
    }
}
if (-not $evidence.Browsers.Count) { $evidence.CollectionErrors.Add('No installed Edge executable found; browser rendering cannot be tested.') }
try {
    $root = 'root\Microsoft\SqlServer\ReportServer'
    foreach ($instance in @(Get-CimInstance -Namespace $root -ClassName __NAMESPACE -ErrorAction Stop)) {
        foreach ($version in @(Get-CimInstance -Namespace "$root\$($instance.Name)" -ClassName __NAMESPACE -ErrorAction Stop | Where-Object { $_.Name -match '^v\d+$' })) {
            $evidence.ReportServerConfiguration += @(Get-CimInstance -Namespace "$root\$($instance.Name)\$($version.Name)\Admin" `
                    -ClassName MSReportServer_ConfigurationSetting -ErrorAction Stop |
                    Select-Object InstanceName, Version, IsInitialized, DatabaseServerName, DatabaseName, VirtualDirectoryReportServer, VirtualDirectoryReportManager, SecureConnectionLevel)
        }
    }
}
catch { $evidence.CollectionErrors.Add("Report Server WMI configuration: $($_.Exception.Message)") }

$serverUris = if ($ReportServerUri) { @($ReportServerUri) } else { @([uri] "https://$fqdn/ReportServer", [uri] "http://$fqdn/ReportServer") }
$originalProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
    [System.Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    foreach ($serverUri in $serverUris) {
        $endpoint = [ordered]@{
            Uri = $serverUri.AbsoluteUri
            Catalog = $null
            CatalogError = $null
            ReportServerPage = $null
            ReportServerPageError = $null
            Portal = $null
            PortalError = $null
        }
        $proxy = $null
        try {
            $proxy = New-WebServiceProxy -Uri "$($serverUri.AbsoluteUri.TrimEnd('/'))/ReportService2010.asmx" -UseDefaultCredential -ErrorAction Stop
            $proxy.Timeout = 30000
            $endpoint.Catalog = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode $SiteCode
        }
        catch { $endpoint.CatalogError = $_.Exception.ToString() }
        finally { if ($proxy) { $proxy.Dispose() } }
        try {
            $page = Invoke-WebRequest -Uri $serverUri -UseDefaultCredentials -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $endpoint.ReportServerPage = [pscustomobject]@{
                StatusCode = [int] $page.StatusCode
                HtmlLength = ([string] $page.Content).Length
                Title = [regex]::Match([string] $page.Content, '(?is)<title[^>]*>(.*?)</title>').Groups[1].Value
            }
        }
        catch { $endpoint.ReportServerPageError = $_.Exception.ToString() }
        $portalUri = [uri]::new($serverUri, '/Reports/')
        try { $endpoint.Portal = Get-ReportingPortalEvidence -PortalUri $portalUri }
        catch { $endpoint.PortalError = $_.Exception.ToString() }
        $evidence.Endpoints += [pscustomobject] $endpoint
    }
}
finally { [System.Net.ServicePointManager]::SecurityProtocol = $originalProtocol }
foreach ($configuration in $evidence.ReportServerConfiguration) {
    $sql = [ordered]@{ Server = $configuration.DatabaseServerName; Database = $configuration.DatabaseName; ReportCount = $null; Error = $null }
    try { $sql.ReportCount = Get-ReportingSqlReportCount -Configuration $configuration -SiteCode $SiteCode }
    catch { $sql.Error = $_.Exception.ToString() }
    $evidence.SqlCatalog += [pscustomobject] $sql
}

$logDirectories = @(
    'C:\PBIRS\PBIRS\LogFiles', 'C:\PBIRS\PBIRS\ReportServer\LogFiles',
    "$env:ProgramFiles\Microsoft Power BI Report Server\PBIRS\LogFiles",
    "$env:ProgramFiles\Microsoft SQL Server Reporting Services\SSRS\LogFiles",
    'C:\SMS\Logs', "$env:ProgramFiles\SMS_SRSRP\Logs"
)
$setupPath = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
if (Test-Path -LiteralPath $setupPath) {
    try {
        $installDirectory = (Get-ItemProperty -LiteralPath $setupPath -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory'
        $logDirectories += Join-Path $installDirectory 'Logs'
    }
    catch { $evidence.CollectionErrors.Add("ConfigMgr log location: $($_.Exception.Message)") }
}
foreach ($directory in $logDirectories | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $directory)) { continue }
    foreach ($pattern in @('srsrp*.log', 'ReportServerService*.log', 'ReportingServicesService*.log', '*Portal*.log')) {
        try {
            foreach ($log in @(Get-ChildItem -LiteralPath $directory -Filter $pattern -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)) {
                $tail = @(Get-Content -LiteralPath $log.FullName -Tail 200 -ErrorAction Stop)
                $errors = @($tail | Where-Object { $_ -match '(?i)error|exception|fail|fatal' } | Select-Object -Last 25)
                $evidence.Logs += [pscustomobject]@{ Path = $log.FullName; LastWriteTime = $log.LastWriteTime; Errors = $errors; Tail = @($tail | Select-Object -Last 25) }
            }
        }
        catch { $evidence.CollectionErrors.Add("Log collection '$directory' / '$pattern': $($_.Exception.Message)") }
    }
}
if (-not ($evidence.Logs | Where-Object { $_.Path -match '\\srsrp[^\\]*\.log$' })) {
    $evidence.CollectionErrors.Add('No srsrp.log found locally. If publication is missing, collect srsrp.log from the ConfigMgr site server too.')
}

$json = $evidence | ConvertTo-Json -Depth 12
if ($AsJson) { return $json }
$json | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
Write-Host "Reporting evidence saved to $OutputPath"
Write-Host 'No configuration changes were made. CollectionErrors and per-probe errors identify unavailable evidence, not successful checks.'
Get-Item -LiteralPath $OutputPath -ErrorAction Stop
