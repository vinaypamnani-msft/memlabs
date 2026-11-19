<#
.SYNOPSIS
    Exercises local reporting probes and host entry-point initialization.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','Common',Justification='Consumed by the collector entry point.')]
[CmdletBinding()]
param([string]$RootPath)
$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
if ($PSVersionTable.PSEdition -eq 'Core') {
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $PSCommandPath -RootPath $RootPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell reporting probe/entry-point regression failed.' }
    return
}
$sourcePath = Join-Path $RootPath 'tools\Get-ReportingDiagnostics.ps1'
. (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw "Collector parser errors: $($errors -join '; ')" }
foreach ($name in @('Get-ReportingSourceHash','New-ReportingSqlConnectionString','Invoke-ReportingWebRequest','Get-ReportingCatalogEvidence','Get-ReportingPortalEvidence')) {
    $nodes = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if ($nodes.Count -ne 1) { throw "Expected one $name definition." }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$connectionString = New-ReportingSqlConnectionString -Server 'fixture\REPORTING,1544' -Database 'ReportServer;Custom' -ConnectTimeout 15
$parsedConnection = [Data.SqlClient.SqlConnectionStringBuilder]::new($connectionString)
if ($parsedConnection.DataSource -ne 'fixture\REPORTING,1544' -or $parsedConnection.InitialCatalog -ne 'ReportServer;Custom' -or
    -not $parsedConnection.IntegratedSecurity -or -not $parsedConnection.TrustServerCertificate -or $parsedConnection.ConnectTimeout -ne 15 -or
    ($parsedConnection.ContainsKey('Password') -and $parsedConnection.Password)) {
    throw 'The actual SQL connection-string builder lost safe keyword handling or its target/authentication contract.'
}
$proxy = [pscustomobject]@{ Items=@(); Children=@(); FailListing=$false; RootType='Folder'; Timeout=0 }
$proxy | Add-Member ScriptMethod GetItemType { param($Path); $this.RootType }
$proxy | Add-Member ScriptMethod ListChildren {
    param($Path,$Recursive)
    if ($this.FailListing) { throw 'Fixture catalog unavailable' }
    if ($Path -eq '/') { return $this.Items }
    if (-not $Recursive) { throw 'Catalog query did not recurse.' }
    $this.Children
}
$proxy | Add-Member ScriptMethod Dispose { }
$empty = Get-ReportingCatalogEvidence $proxy -SiteCode PS1
if ($empty.ConfigMgrFolderFound -or $empty.ReportCount -ne 0) { throw 'Empty root became published reports.' }
$proxy.Items = @(
    [pscustomobject]@{ Name='ConfigMgr_PS1'; Path='/ConfigMgr_PS1'; TypeName='Folder' },
    [pscustomobject]@{ Name='ConfigMgr_PS2'; Path='/ConfigMgr_PS2'; TypeName='Folder' }
)
if ((Get-ReportingCatalogEvidence $proxy -SiteCode PS1).ReportCount -ne 0) { throw 'Empty site folder became installed reports.' }
$proxy.Children = @(
    [pscustomobject]@{ Path='/ConfigMgr_PS1/Hardware/Report'; TypeName='Report' },
    [pscustomobject]@{ Path='/ConfigMgr_PS1/DataSource'; TypeName='DataSource' }
)
$catalog = Get-ReportingCatalogEvidence $proxy -SiteCode PS1
if ($catalog.ReportCount -ne 1 -or $catalog.Folders.Count -ne 1) { throw 'Report count or site filtering is wrong.' }
if ((Get-ReportingCatalogEvidence $proxy -SiteCode XXX).ConfigMgrFolderFound) { throw 'Another site satisfied the expected folder.' }
$proxy.FailListing = $true
$threw = $false
try { $null = Get-ReportingCatalogEvidence $proxy -SiteCode PS1 } catch { $threw = $_.Exception.Message -match 'Fixture catalog unavailable' }
if (-not $threw) { throw 'Unreadable catalog became a zero report count.' }
$proxy.FailListing = $false
$proxy.RootType = 'Report'
$threw = $false
try { $null = Get-ReportingCatalogEvidence $proxy -SiteCode PS1 } catch { $threw = $_.Exception.Message -match 'unexpected type' }
if (-not $threw) { throw 'Invalid SOAP root was accepted.' }
$proxy.RootType = 'Folder'

$web = [pscustomobject]@{ Uris=[Collections.Generic.List[string]]::new(); BrokenAsset=$false; Api404=$false; Redirect=''; CredentialSeen=$false; Script='console.log("loaded")' }
function Invoke-WebRequest {
    param($Uri,[switch]$UseDefaultCredentials,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction,$MaximumRedirection,[pscredential]$Credential)
    if (-not $UseBasicParsing -or $TimeoutSec -gt 30 -or $MaximumRedirection -ne 0) { throw 'Unbounded/automatically redirecting HTTP request.' }
    $web.CredentialSeen = $web.CredentialSeen -or $null -ne $Credential
    $web.Uris.Add("$Uri")
    if ($web.Redirect) { return [pscustomobject]@{ StatusCode=302; Headers=@{Location=$web.Redirect} } }
    if ("$Uri" -match 'api/v2.0') {
        if ($web.Api404) {
            $exception = [Exception]::new('HTTP 404')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode=404 })
            throw $exception
        }
        return [pscustomobject]@{ StatusCode=200; Content='{"value":[]}'; Headers=@{'Content-Type'='application/json'} }
    }
    if ("$Uri" -match 'main\.js') {
        if ($web.BrokenAsset) { throw 'Fixture script download failed' }
        return [pscustomobject]@{ StatusCode=200; Content=$web.Script; Headers=@{'Content-Type'='application/javascript'} }
    }
    [pscustomobject]@{
        StatusCode=200; Content='<title>Report Server</title><base href="/Reports/"><script src="assets/main.js"></script><script src="https://external.invalid/script.js"></script>'
        BaseResponse=[pscustomobject]@{ ResponseUri=[uri]'https://rp.fixture/Reports/browse/' }
    }
}
Set-Item Function:\Invoke-WebRequest (${function:Invoke-WebRequest}.GetNewClosure())
$page = Get-ReportingPortalEvidence -PortalUri 'https://rp.fixture/Reports/'
if ($page.Title -ne 'Report Server' -or $page.ScriptAssets.Count -ne 2 -or $page.RestApi.Error) { throw 'Portal evidence is incomplete.' }
if ('https://rp.fixture/Reports/assets/main.js' -notin $web.Uris -or ($web.Uris | Where-Object { $_ -match 'external\.invalid' })) {
    throw 'Asset base resolution failed or credentials reached another origin.'
}
if ($page.ScriptAssets[0].ClassStaticInitializationBlocks -ne 0 -or $page.ScriptAssets[0].MinimumChromiumMajor) { throw 'A modern syntax requirement was invented for a plain script.' }
$web.Script='class Portal { static { this.factory = 1; } static { this.provider = 2; } }'
$asset=(Get-ReportingPortalEvidence -PortalUri 'https://rp.fixture/Reports/').ScriptAssets[0]
if ($asset.ClassStaticInitializationBlocks -ne 2 -or $asset.MinimumChromiumMajor -ne 94) { throw 'The captured portal syntax incompatibility was not measured correctly.' }
$web.Script='console.log("loaded")'
$web.BrokenAsset = $true
if ((Get-ReportingPortalEvidence -PortalUri 'https://rp.fixture/Reports/').ScriptAssets[0].Error -notmatch 'download failed') { throw 'Broken script became successful evidence.' }
$web.BrokenAsset = $false; $web.Api404 = $true
if ((Get-ReportingPortalEvidence -PortalUri 'https://rp.fixture/Reports/').RestApi.StatusCode -ne 404) { throw 'REST failure status was lost.' }
$web.Api404 = $false; $web.Redirect = 'https://external.invalid/'
$threw = $false
try { $null = Invoke-ReportingWebRequest -Uri 'https://rp.fixture/Reports/' } catch { $threw = $_.Exception.Message -match 'another origin' }
if (-not $threw) { throw 'Authenticated cross-origin redirect was followed.' }
$web.Redirect = ''
$password = [Security.SecureString]::new(); $password.AppendChar([char]120)
$fixtureCredential = [pscredential]::new('fixture-admin',$password)
$null = Get-ReportingPortalEvidence -PortalUri 'https://rp.fixture/Reports/' -Credential $fixtureCredential
if (-not $web.CredentialSeen) { throw 'Host HTTP credentials were not passed to its own origin.' }

function New-WebServiceProxy {
    param($Uri,[switch]$UseDefaultCredential,$ErrorAction)
    if (-not $UseDefaultCredential -or $Uri -notmatch 'ReportService2010.asmx$') { throw 'Unexpected SOAP connection.' }
    $proxy
}
Set-Item Function:\New-WebServiceProxy (${function:New-WebServiceProxy}.GetNewClosure())
function Get-CimInstance {
    param($ClassName,$Namespace,$Filter,$OperationTimeoutSec,$ErrorAction)
    if ($OperationTimeoutSec -ne 15) { throw 'CIM inventory lost its timeout.' }
    switch ($ClassName) {
        Win32_OperatingSystem { [pscustomobject]@{ Caption='Fixture'; Version='10.0.20348'; BuildNumber='20348' } }
        Win32_ComputerSystem { [pscustomobject]@{ DNSHostName='rp'; Domain='fixture' } }
        Win32_Service { [pscustomobject]@{ Name='PowerBIReportServer'; State='Running'; StartMode='Auto' } }
        __NAMESPACE { @() }
        default { throw "Unexpected CIM class $ClassName." }
    }
}
function Get-ScheduledTask { param($ErrorAction); [pscustomobject]@{ TaskName='MicrosoftEdgeUpdateCore'; State='Disabled' } }
function Test-Path { param($LiteralPath); [IO.File]::Exists($LiteralPath) }
function Invoke-MemLabsBoundedPowerShell {
    param($ProbeScript,$Parameters,$TimeoutSeconds,$ProgressPath,$ProgressId)
    if ($TimeoutSeconds -ne 60 -or -not $ProgressPath -or $ProgressId -ne 'reporting') { throw 'Local web probes lost their limit/checkpoint.' }
    try { [pscustomobject]@{ Output=(& $ProbeScript @Parameters); Error=''; ElapsedSeconds=0.1; TimedOut=$false } }
    catch { [pscustomobject]@{ Output=$null; Error=$_.Exception.ToString(); ElapsedSeconds=0.1; TimedOut=$false } }
}
$root = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingEntry-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $root -ItemType Directory
try {
    $out = Join-Path $root 'local.json'
    $null = & $sourcePath -SiteCode PS1 -OutputPath $out
    $document = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    if ($document.Endpoints.Count -ne 2 -or $document.Endpoints[0].Catalog.ReportCount -ne 1) { throw 'Local collector lost measured reports.' }
    $proxy.FailListing = $true
    $json = @(& $sourcePath -SiteCode PS1 -AsJson)
    if ($json.Count -ne 1 -or ($json[0] | ConvertFrom-Json).Endpoints[0].CatalogError -notmatch 'Fixture catalog unavailable') { throw 'Local JSON mode lost an unavailable catalog.' }
    $proxy.FailListing = $false

    $tools = Join-Path $root 'tools'; $dsc = Join-Path $root 'DSC\phases'
    $null = New-Item -Path $tools,$dsc -ItemType Directory -Force
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $tools 'Get-ReportingDiagnostics.ps1')
    Copy-Item -LiteralPath (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1') -Destination (Join-Path $dsc 'ProcessFunctions.ps1')
    @'
function Invoke-ReportingHostCollection {
    param($VMName,$Note,[pscredential]$Credential,$CollectorSource,$ProcessSource,$TargetPath,$SiteCode,$ReportServerUri,[switch]$AsJson)
    if ($VMName -ne 'RP-TEST' -or $Note.domain -ne 'fixture.test' -or -not $Credential.Password -or
        $CollectorSource -notmatch 'Get-ReportingCatalogEvidence' -or $ProcessSource -notmatch 'Invoke-MemLabsBoundedPowerShell') {
        throw 'Host entry-point arguments were not preserved.'
    }
    $json = [pscustomobject]@{ VMName=$VMName; SiteCode=$SiteCode; TargetPath=$TargetPath; Uri="$ReportServerUri" } | ConvertTo-Json
    if ($AsJson) { return $json }
    $json | Set-Content -LiteralPath $TargetPath -Encoding UTF8
    Get-Item -LiteralPath $TargetPath
}
'@ | Set-Content -LiteralPath (Join-Path $tools 'Common.ReportingDiagnostics.ps1') -Encoding UTF8
    $hostState = [pscustomobject]@{ CredentialLoads=0; Domain='fixture.test'; FailCredential=$false }
    $Common = [pscustomobject]@{ LocalAdmin=$fixtureCredential; LogPath=(Join-Path $root 'VMBuild.log'); FatalError=$null }
    $hostCommon = $Common
    function Invoke-VmCommand { throw 'The entry point must delegate instead of starting the old monolithic guest call.' }
    function Get-VMNote { param($VMName); [pscustomobject]@{ domain=$hostState.Domain } }
    Set-Item Function:\Get-VMNote (${function:Get-VMNote}.GetNewClosure())
    function Get-LocalAdminCredential {
        $hostState.CredentialLoads++
        if ($hostState.FailCredential) { return $false }
        $hostCommon.LocalAdmin = $fixtureCredential
        $true
    }
    Set-Item Function:\Get-LocalAdminCredential (${function:Get-LocalAdminCredential}.GetNewClosure())
    $entry = Join-Path $tools 'Get-ReportingDiagnostics.ps1'
    $default = @(& $entry -VMName RP-TEST -SiteCode PS1)
    if ($default.Count -ne 1 -or $default[0].FullName -ne (Join-Path $root 'RP-TEST-ReportingDiagnostics.json')) { throw 'Default host output left synced logs.' }
    $hostCommon.LocalAdmin = $null
    $json = @(& $entry -VMName RP-TEST -SiteCode PS1 -ReportServerUri 'http://rp.fixture/ReportServer' -AsJson)
    if ($hostState.CredentialLoads -ne 1 -or $json.Count -ne 1 -or ($json[0] | ConvertFrom-Json).Uri -ne 'http://rp.fixture/ReportServer') { throw 'Host credential bootstrap or JSON delegation failed.' }
    $hostCommon.LocalAdmin = $null; $hostState.FailCredential = $true
    $threw = $false
    try { $null = & $entry -VMName RP-TEST -AsJson } catch { $threw = $_.Exception.Message -match 'guest credentials are unavailable' }
    if (-not $threw) { throw 'Unusable credentials were silently accepted.' }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
Write-Host 'PASS -- catalog/portal measurement, authenticated origin boundaries, local collection, and file-first host delegation/bootstrap.'
