<#
.SYNOPSIS
    Collects reporting evidence locally or from the Hyper-V host.
.DESCRIPTION
    Run elevated on the MemLabs Hyper-V host with VMName. Raw reporting/site/setup
    logs and selected live event-log snapshots are copied through SMB before any
    guest PowerShell runs. Cached MemLabs credentials and Hyper-V network addresses
    are used; no manual guest script copy is required.

    Independent host RPC/WMI/events, HTTP/SOAP/REST, and read-only SQL probes run
    in bounded workers and checkpoint evidence in host logs after each stage.
    Missing facts use isolated PowerShell Direct probes, then existing WinRM.
    A broken Direct channel is not repeatedly retried. Fresh crash events are
    requested through native RPC, not through the broken guest process.

    Full files up to 32 MiB are copied; larger text logs retain their last 8 MiB.
    Live EVTX snapshots must fit 64 MiB and are never tailed. Per-copy-pass data
    is limited to 256 MiB. Missing, unreadable, truncated and aborted files are
    explicit in the manifests. Security.evtx and raw encrypted RS configuration
    are not exported. No VM, service, firewall, DNS, trust or database settings
    are changed. Does not launch a browser.

    Host JSON, raw files and per-run partial checkpoints default to the build
    logs directory for synchronization. Critical unavailable facts create a
    separate failure JSON; earlier successful output is preserved. AsJson returns
    one document with explicit CollectionStatus/CollectionFailed flags, while
    retaining raw files and checkpoints. Without VMName, local Windows PowerShell
    5.1 collection remains available. HTTP success is not a browser-rendering test.
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

function Get-ReportingSourceHash {
    param([Parameter(Mandatory)][string] $Source)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-ReportingTransportFailureEvidence {
    param(
        [Parameter(Mandatory)][string] $VMName,
        [Parameter(Mandatory)][string] $Domain,
        [Parameter(Mandatory)][string] $StartedAt
    )

    $report = [ordered]@{
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        HostState = $null
        Guest = $null
        Errors = [System.Collections.Generic.List[string]]::new()
    }
    try { $report.HostState = Get-VmHostSideDiag -VmName $VMName }
    catch { $report.Errors.Add("Hyper-V state: $($_.Exception.Message)") }
    $memorySource = ''
    try { $memorySource = (Get-MemLabsMemoryDiagnosticProbe).ToString() }
    catch { $report.Errors.Add("Memory collector source: $($_.Exception.Message)") }
    $probe = {
        param($SinceUtc, $MemorySource)
        $result = @{
            ComputerName = $env:COMPUTERNAME
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            LastBootUpTime = $null
            Memory = $null
            EventLogs = @()
            Errors = [System.Collections.Generic.List[string]]::new()
        }
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
            $result.LastBootUpTime = $os.LastBootUpTime
        }
        catch { $result.Errors.Add("Guest boot time: $($_.Exception.Message)") }
        foreach ($query in @(
                @{ Name = 'Application'; Id = @(1000, 1001, 1026) },
                @{ Name = 'System'; Id = @(41, 1074, 6008, 7031, 7034) },
                @{ Name = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1116, 1117, 1121, 1122) }
            )) {
            $log = [ordered]@{ LogName = $query.Name; Available = $false; Events = @(); Error = $null }
            try {
                $events = @(Get-WinEvent -FilterHashtable @{
                        LogName = $query.Name; Id = $query.Id
                        StartTime = [DateTimeOffset]::Parse($SinceUtc).UtcDateTime.AddMinutes(-2)
                    } -MaxEvents 20 -ErrorAction Stop)
                $log.Events = @($events | ForEach-Object {
                        $message = "$($_.Message)"
                        if ($message.Length -gt 4000) { $message = $message.Substring(0, 4000) }
                        [pscustomobject]@{
                            TimeCreated = $_.TimeCreated
                            Id = $_.Id
                            Provider = $_.ProviderName
                            Message = $message
                        }
                    })
                $log.Available = $true
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $log.Available = $true }
                else { $log.Error = $_.Exception.Message }
            }
            $result.EventLogs += [pscustomobject] $log
        }
        if ($MemorySource) {
            try { $result.Memory = & ([scriptblock]::Create($MemorySource)) }
            catch { $result.Errors.Add("Guest memory evidence: $($_.Exception.Message)") }
        }
        return $result
    }
    try {
        $response = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain -ScriptBlock $probe `
            -ArgumentList $StartedAt, $memorySource -DisplayName 'Collect reporting transport failure evidence' `
            -AsJob -TimeoutSeconds 60 -SessionMaxRetries 1 -RequireDomainIdentity -FailOnRemoteError -SuppressLog
        if ($response.CommandResult -and -not $response.ScriptBlockFailed -and
            $response.ScriptBlockOutput -is [Collections.IDictionary] -and
            $response.ScriptBlockOutput.Contains('ComputerName')) {
            $report.Guest = $response.ScriptBlockOutput
        }
        else {
            $detail = if ($response.ErrorDetails) { $response.ErrorDetails -join '; ' } else { 'No valid guest event/memory response was returned.' }
            $report.Errors.Add("Post-failure guest capture: $detail")
        }
    }
    catch { $report.Errors.Add("Post-failure guest capture: $($_.Exception.Message)") }
    [pscustomobject] $report
}

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

function Invoke-ReportingWebRequest {
    param([Parameter(Mandatory)][uri]$Uri, [pscredential]$Credential, [int]$TimeoutSeconds = 20)
    $current = $Uri
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        $arguments = @{
            Uri = $current; UseBasicParsing = $true; TimeoutSec = $TimeoutSeconds
            MaximumRedirection = 0; ErrorAction = 'Stop'
        }
        if ($Credential) { $arguments.Credential = $Credential }
        else { $arguments.UseDefaultCredentials = $true }
        $response = $null
        $requestError = $null
        try { $response = Invoke-WebRequest @arguments }
        catch {
            $requestError = $_
            $response = $_.Exception.Response
            if (-not $response) { throw }
            if ([int]$response.StatusCode -ge 400) {
                $content = ''; $bodyError = $null; $reader = $null
                try {
                    if ($response.PSObject.Methods['GetResponseStream']) {
                        $reader = [IO.StreamReader]::new($response.GetResponseStream())
                        $buffer = [char[]]::new(16384)
                        $used = 0
                        while ($used -lt $buffer.Length) {
                            $count = $reader.Read($buffer,$used,$buffer.Length-$used)
                            if ($count -eq 0) { break }
                            $used += $count
                        }
                        if ($used -gt 0) { $content = [string]::new($buffer,0,$used) }
                    }
                    else { $bodyError = 'HTTP error response did not expose a readable body stream.' }
                }
                catch { $bodyError = $_.Exception.Message }
                finally { if ($reader) { $reader.Dispose() } }
                return [pscustomobject]@{
                    StatusCode=[int]$response.StatusCode; Content=$content; Headers=$response.Headers
                    BaseResponse=[pscustomobject]@{ResponseUri=$current}
                    HttpError=$requestError.Exception.Message; BodyReadError=$bodyError
                }
            }
            if ([int]$response.StatusCode -notin @(301,302,303,307,308)) { throw }
        }
        if ([int]$response.StatusCode -notin @(301,302,303,307,308)) { return $response }
        $location = [string]$response.Headers['Location']
        if (-not $location) {
            if ($requestError) { throw $requestError }
            throw "Reporting redirect from '$current' did not specify a Location."
        }
        $next = [uri]::new($current,$location)
        if ($next.Scheme -ne $Uri.Scheme -or $next.Authority -ne $Uri.Authority -or $next.UserInfo) {
            throw "Reporting redirect to another origin was not followed with credentials: '$current' -> '$next'."
        }
        $current = $next
    }
    throw "Reporting request exceeded five same-origin redirects: $Uri"
}

function Get-ReportingPortalEvidence {
    param([Parameter(Mandatory)][uri] $PortalUri, [string] $ProgressPath, [pscredential]$Credential,
        [string]$ArtifactDirectory,[string]$ArtifactPrefix)

    $request = {
        param($Uri, $TimeoutSeconds)
        if ($ProgressPath) {
            Write-MemLabsProcessProgress -Path $ProgressPath -Record @{
                Id = 'reporting'; Stage = 'Portal'; Message = "GET $Uri"; UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        Invoke-ReportingWebRequest -Uri $Uri -Credential $Credential -TimeoutSeconds $TimeoutSeconds
    }
    $page = & $request $PortalUri 30
    $html = [string] $page.Content
    $baseUri = $PortalUri
    if ($page.BaseResponse.ResponseUri) { $baseUri = $page.BaseResponse.ResponseUri }
    $baseMatch = [regex]::Match($html, '(?is)<base\b[^>]*\bhref\s*=\s*["'']([^"'']+)')
    if ($baseMatch.Success) { $baseUri = [uri]::new($baseUri, $baseMatch.Groups[1].Value) }
    $scripts = @(
        foreach ($match in [regex]::Matches($html, '(?is)<script\b[^>]*\bsrc\s*=\s*["'']([^"'']+)') | Select-Object -First 8) {
            $assetUri = [uri]::new($baseUri, [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value))
            $asset = [ordered]@{ Uri = $assetUri.AbsoluteUri; StatusCode = $null; ContentType = $null; Error = $null; SavedResponse = $null; ResponseTruncated = $false }
            if ($assetUri.Authority -ne $PortalUri.Authority -or $assetUri.Scheme -ne $PortalUri.Scheme) {
                $asset.Error = 'External asset not requested; credentials are only sent to the portal origin.'
            }
            else {
                try {
                    $response = & $request $assetUri 20
                    $asset.StatusCode = [int] $response.StatusCode
                    $asset.ContentType = [string] $response.Headers['Content-Type']
                    if (-not $response.Content -or $asset.ContentType -match 'text/html') {
                        $asset.Error = 'Script request returned an empty body or HTML rather than JavaScript.'
                    }
                    if ($ArtifactDirectory -and $ArtifactPrefix) {
                        $body = [Text.Encoding]::UTF8.GetBytes([string]$response.Content)
                        $asset.ResponseTruncated = $body.Length -gt 2MB
                        $suffix = (Get-ReportingSourceHash -Source $assetUri.AbsoluteUri).Substring(0,12)
                        $asset.SavedResponse = Join-Path $ArtifactDirectory "$ArtifactPrefix-$suffix-script.response.txt"
                        $output = [IO.File]::Open("$($asset.SavedResponse).partial",[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                        try { $output.Write($body,0,[int][math]::Min(2MB,$body.Length)) }
                        finally { $output.Dispose() }
                        [IO.File]::Move("$($asset.SavedResponse).partial",$asset.SavedResponse)
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
        $response = & $request $api.Uri 30
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
        HtmlExcerpt = $html.Substring(0,[math]::Min(16384,$html.Length))
        HttpError = $page.HttpError
        BodyReadError = $page.BodyReadError
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

function Get-ReportingEndpointEvidence {
    param(
        [Parameter(Mandatory)][uri] $ServerUri,
        [string] $SiteCode,
        [ValidateRange(1, 90)][int] $TimeoutSeconds = 60
    )

    $endpoint = [ordered]@{
        Uri = $ServerUri.AbsoluteUri
        Catalog = $null
        CatalogError = $null
        ReportServerPage = $null
        ReportServerPageError = $null
        Portal = $null
        PortalError = $null
        Probes = @()
    }
    $helperSource = "function Get-ReportingCatalogEvidence { ${function:Get-ReportingCatalogEvidence} }`nfunction Invoke-ReportingWebRequest { ${function:Invoke-ReportingWebRequest} }`nfunction Get-ReportingPortalEvidence { ${function:Get-ReportingPortalEvidence} }`nfunction Write-MemLabsProcessProgress { ${function:Write-MemLabsProcessProgress} }"
    $probe = {
        param($Stage, $ServerUri, $SiteCode, $HelperSource, $ProgressPath)
        $ProgressPreference = 'SilentlyContinue'
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        . ([scriptblock]::Create($HelperSource))
        Write-MemLabsProcessProgress -Path $ProgressPath -Record @{
            Id = 'reporting'; Stage = $Stage; Message = "$Stage at $ServerUri"; UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        switch ($Stage) {
            'Catalog' {
                $proxy = $null
                try {
                    $proxy = New-WebServiceProxy -Uri "$($ServerUri.AbsoluteUri.TrimEnd('/'))/ReportService2010.asmx" -UseDefaultCredential -ErrorAction Stop
                    $proxy.Timeout = 30000
                    Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode $SiteCode
                }
                finally { if ($proxy) { $proxy.Dispose() } }
            }
            'ReportServerPage' {
                $page = Invoke-WebRequest -Uri $ServerUri -UseDefaultCredentials -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                [pscustomobject]@{
                    StatusCode = [int] $page.StatusCode
                    HtmlLength = ([string] $page.Content).Length
                    Title = [regex]::Match([string] $page.Content, '(?is)<title[^>]*>(.*?)</title>').Groups[1].Value
                }
            }
            'Portal' { Get-ReportingPortalEvidence -PortalUri ([uri]::new($ServerUri, '/Reports/')) -ProgressPath $ProgressPath }
        }
    }
    foreach ($stage in @('Catalog', 'ReportServerPage', 'Portal')) {
        $progressPath = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-Reporting-$([guid]::NewGuid().ToString('N')).json"
        try {
            $result = Invoke-MemLabsBoundedPowerShell -ProbeScript $probe -Parameters @{
                Stage = $stage; ServerUri = $ServerUri; SiteCode = $SiteCode; HelperSource = $helperSource; ProgressPath = $progressPath
            } -TimeoutSeconds $TimeoutSeconds -ProgressPath $progressPath -ProgressId 'reporting'
        }
        finally { [IO.File]::Delete($progressPath) }
        $endpoint.Probes += [pscustomobject]@{
            Name = $stage
            ProcessId = $result.ProcessId
            ElapsedSeconds = $result.ElapsedSeconds
            TimedOut = $result.TimedOut
            Error = $result.Error
            LastRequest = $result.Progress.Message
        }
        if ($result.Error) {
            $lastRequest = if ($result.Progress.Message) { " Last request: $($result.Progress.Message)" } else { '' }
            $endpoint["${stage}Error"] = "$stage probe at '$ServerUri': $($result.Error)$lastRequest"
        }
        else { $endpoint[$stage] = $result.Output }
    }
    [pscustomobject] $endpoint
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
    $processSource = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\ProcessFunctions.ps1') -Raw -ErrorAction Stop
    . ([scriptblock]::Create($processSource))
    if (-not (Get-Command Invoke-VmCommand -ErrorAction Ignore) -or -not (Get-Command Get-VMNote -ErrorAction Ignore)) {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.ps1') -InJob
    }
    $note = Get-VMNote -VMName $targetVmName
    if (-not $note -or [string]::IsNullOrWhiteSpace("$($note.domain)") -or $note.domain -eq 'WORKGROUP') {
        throw "Cannot resolve a MemLabs domain for '$targetVmName'. Run elevated on its Hyper-V host; local collection remains available without VMName."
    }
    if ($Common.LocalAdmin -isnot [pscredential] -or $Common.LocalAdmin.Password.Length -eq 0) {
        if (-not (Get-Command Get-LocalAdminCredential -ErrorAction Ignore)) {
            . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.ps1') -InJob
        }
        try { $credentialLoaded = Get-LocalAdminCredential }
        catch { throw "MemLabs guest-credential initialization failed on this host for '$targetVmName': $($_.Exception.Message)" }
        if ($credentialLoaded -isnot [bool] -or -not $credentialLoaded -or
            $Common.LocalAdmin -isnot [pscredential] -or $Common.LocalAdmin.Password.Length -eq 0) {
            $reason = if ($Common.FatalError) { "$($Common.FatalError)" } else { 'The credential loader returned no usable cached credential.' }
            throw "MemLabs guest credentials are unavailable on this host for '$targetVmName'. $reason"
        }
    }
    $targetPath = if ($OutputPath) { [IO.Path]::GetFullPath($OutputPath) }
    else {
        $logDirectory = if ($Common.LogPath) { Split-Path $Common.LogPath -Parent }
        else { Join-Path (Split-Path -Parent $PSScriptRoot) 'logs' }
        $null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
        Join-Path $logDirectory "$targetVmName-ReportingDiagnostics.json"
    }
    . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
    Invoke-ReportingHostCollection -VMName $targetVmName -Note $note -Credential $Common.LocalAdmin `
        -CollectorSource $collectorSource -ProcessSource $processSource -TargetPath $targetPath `
        -SiteCode $SiteCode -ReportServerUri $ReportServerUri -AsJson:$AsJson
    return
}
if ($PSVersionTable.PSEdition -eq 'Core' -or -not (Get-Command New-WebServiceProxy -ErrorAction Ignore)) {
    throw 'For local collection, use Windows PowerShell 5.1 (powershell.exe), not PowerShell 7. Host collection with VMName supports PowerShell 7.'
}
if (-not (Get-Command Invoke-MemLabsBoundedPowerShell -ErrorAction Ignore)) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\ProcessFunctions.ps1')
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
    $evidence.OperatingSystem = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop |
        Select-Object Caption, Version, BuildNumber
    $computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
    $fqdn = "$($computer.DNSHostName).$($computer.Domain)"
}
catch { throw "Cannot identify the local reporting VM: $($_.Exception.Message)" }
try {
    $evidence.Services = @(Get-CimInstance Win32_Service -Filter "Name='PowerBIReportServer' OR Name='SQLServerReportingServices' OR Name LIKE 'ReportServer%' OR Name='edgeupdate' OR Name='edgeupdatem' OR Name='MicrosoftEdgeElevationService'" -OperationTimeoutSec 15 -ErrorAction Stop |
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
    foreach ($instance in @(Get-CimInstance -Namespace $root -ClassName __NAMESPACE -OperationTimeoutSec 15 -ErrorAction Stop)) {
        foreach ($version in @(Get-CimInstance -Namespace "$root\$($instance.Name)" -ClassName __NAMESPACE -OperationTimeoutSec 15 -ErrorAction Stop | Where-Object { $_.Name -match '^v\d+$' })) {
            $evidence.ReportServerConfiguration += @(Get-CimInstance -Namespace "$root\$($instance.Name)\$($version.Name)\Admin" `
                    -ClassName MSReportServer_ConfigurationSetting -OperationTimeoutSec 15 -ErrorAction Stop |
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
        $evidence.Endpoints += Get-ReportingEndpointEvidence -ServerUri $serverUri -SiteCode $SiteCode
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
