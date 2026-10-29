<#
.SYNOPSIS
    Exercises reporting diagnostics without a reporting server.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Consumed by the collector script during host invocations.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'tools\Get-ReportingDiagnostics.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw "Collector parse errors: $($parseErrors -join '; ')" }
foreach ($name in @('Get-ReportingCatalogEvidence', 'Get-ReportingPortalEvidence')) {
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one definition of $name." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$proxy = [pscustomobject]@{ Items = @(); Children = @(); FailListing = $false; RootType = 'Folder' }
$proxy | Add-Member ScriptMethod GetItemType { param($Path) $this.RootType }
$proxy | Add-Member ScriptMethod ListChildren {
    param($Path, $Recursive)
    if ($this.FailListing) { throw 'Catalog unavailable' }
    if ($Path -eq '/') { return $this.Items }
    if (-not $Recursive) { throw 'Report publication probe did not recurse into the ConfigMgr folder.' }
    $this.Children
}

$result = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode PS1
if ($result.ConfigMgrFolderFound -or $result.ReportCount -ne 0) { throw 'Empty SOAP root was mistaken for published ConfigMgr reports.' }
$proxy.Items = @(
    [pscustomobject]@{ Name = 'ConfigMgr_PS1'; Path = '/ConfigMgr_PS1'; TypeName = 'Folder' },
    [pscustomobject]@{ Name = 'ConfigMgr_PS2'; Path = '/ConfigMgr_PS2'; TypeName = 'Folder' }
)
$result = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode PS1
if (-not $result.ConfigMgrFolderFound -or $result.ReportCount -ne 0) { throw 'Empty ConfigMgr folder was mistaken for installed reports.' }
$proxy.Children = @(
    [pscustomobject]@{ Path = '/ConfigMgr_PS1/Hardware/Report'; TypeName = 'Report' },
    [pscustomobject]@{ Path = '/ConfigMgr_PS1/DataSource'; TypeName = 'DataSource' },
    [pscustomobject]@{ Path = '/ConfigMgr_PS1/Hardware'; TypeName = 'Folder' }
)
$result = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode PS1
if ($result.ReportCount -ne 1 -or $result.Folders.Count -ne 1 -or $result.Folders[0].Path -ne '/ConfigMgr_PS1') {
    throw 'Published report count or site scoping is incorrect.'
}
$result = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode XXX
if ($result.ConfigMgrFolderFound -or $result.ReportCount -ne 0) { throw 'A different site satisfied the expected publication.' }
$proxy.FailListing = $true
$threw = $false
try { $null = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode PS1 }
catch { $threw = $_.Exception.Message -match 'Catalog unavailable' }
if (-not $threw) { throw 'An unreadable catalog was converted to a zero report count.' }
$proxy.FailListing = $false
$proxy.RootType = 'Report'
$threw = $false
try { $null = Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode PS1 }
catch { $threw = $_.Exception.Message -match 'unexpected type' }
if (-not $threw) { throw 'Unexpected SOAP root type was accepted.' }

$webState = [pscustomobject]@{ RequestedUris = [System.Collections.Generic.List[string]]::new(); BrokenAsset = $false; MissingApi = $false }
function Invoke-WebRequest {
    param($Uri, [switch] $UseDefaultCredentials, [switch] $UseBasicParsing, $TimeoutSec, $ErrorAction)
    if (-not $UseDefaultCredentials -or -not $UseBasicParsing -or $TimeoutSec -gt 30) { throw 'Missing bounded authenticated HTTP probe.' }
    $webState.RequestedUris.Add("$Uri")
    $uriText = "$Uri"
    if ($uriText -match 'api/v2.0') {
        if ($webState.MissingApi) {
            $exception = [System.Exception]::new('HTTP 404')
            $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = 404 })
            throw $exception
        }
        return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{ 'Content-Type' = 'application/json' } }
    }
    if ($uriText -match 'main\.js') {
        if ($webState.BrokenAsset) { throw 'Script download failed' }
        return [pscustomobject]@{ StatusCode = 200; Content = 'console.log("loaded")'; Headers = @{ 'Content-Type' = 'application/javascript' } }
    }
    [pscustomobject]@{
        StatusCode = 200
        Content = '<title>Report Server Web Portal</title><base href="/Reports/"><script src="assets/main.js"></script><script src="https://external.example/script.js"></script>'
        BaseResponse = [pscustomobject]@{ ResponseUri = [uri] 'https://rp.example/Reports/browse/' }
    }
}
Set-Item -Path Function:\Invoke-WebRequest -Value (${function:Invoke-WebRequest}.GetNewClosure())
$result = Get-ReportingPortalEvidence -PortalUri 'https://rp.example/Reports/'
if ($result.Title -ne 'Report Server Web Portal' -or $result.ScriptAssets.Count -ne 2 -or $result.RestApi.Error) {
    throw 'Portal evidence is incomplete.'
}
if ('https://rp.example/Reports/assets/main.js' -notin $webState.RequestedUris) { throw 'Portal asset did not respect the HTML base URL.' }
if ($webState.RequestedUris | Where-Object { $_ -match 'external\.example' }) { throw 'Default credentials were sent to an external asset origin.' }
if (-not $result.ScriptAssets[1].Error) { throw 'Skipped external asset is not explicitly identified.' }
$webState.BrokenAsset = $true
$result = Get-ReportingPortalEvidence -PortalUri 'https://rp.example/Reports/'
if ($result.ScriptAssets[0].Error -notmatch 'Script download failed' -or $null -ne $result.ScriptAssets[0].StatusCode) {
    throw 'An unavailable script was given successful-looking evidence.'
}
$webState.MissingApi = $true
$result = Get-ReportingPortalEvidence -PortalUri 'https://rp.example/Reports/'
if ($result.RestApi.StatusCode -ne 404 -or -not $result.RestApi.Error) { throw 'Portal REST HTTP failure status was lost.' }
$webState.MissingApi = $false

$proxy | Add-Member NoteProperty Timeout 0
$proxy | Add-Member ScriptMethod Dispose { }
$proxy.RootType = 'Folder'
$diagnosticProxy = $proxy
$webState.BrokenAsset = $false
function New-WebServiceProxy {
    param($Uri, [switch] $UseDefaultCredential, $ErrorAction)
    if (-not $UseDefaultCredential -or $Uri -notmatch 'ReportService2010\.asmx$') { throw 'Unexpected SOAP connection.' }
    $diagnosticProxy
}
Set-Item -Path Function:\New-WebServiceProxy -Value (${function:New-WebServiceProxy}.GetNewClosure())
function Get-CimInstance {
    param($ClassName, $Namespace, $Filter, $ErrorAction)
    switch ($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Test OS'; Version = '10.0.20348'; BuildNumber = '20348' } }
        'Win32_ComputerSystem' { [pscustomobject]@{ DNSHostName = 'rp'; Domain = 'example' } }
        'Win32_Service' { [pscustomobject]@{ Name = 'PowerBIReportServer'; State = 'Running'; StartMode = 'Auto'; PathName = 'test' } }
        '__NAMESPACE' { @() }
        default { throw "Unexpected CIM query '$ClassName' in '$Namespace' ($Filter)." }
    }
}
function Get-ScheduledTask {
    param($ErrorAction)
    [pscustomobject]@{ TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; TaskPath = '\'; State = 'Disabled' }
}
function Test-Path { param($LiteralPath) [System.IO.File]::Exists($LiteralPath) }

$outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "MemLabs-Reporting-Test-$([guid]::NewGuid().ToString('N')).json"
$originalProtocol = [System.Net.ServicePointManager]::SecurityProtocol
try {
    $null = & $sourcePath -SiteCode PS1 -OutputPath $outputPath
    $collected = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if ($collected.Endpoints.Count -ne 2 -or $collected.Endpoints[0].Catalog.ReportCount -ne 1 -or $collected.Endpoints[0].CatalogError) {
        throw "Full collector did not persist the measured report count: $($collected.Endpoints | ConvertTo-Json -Depth 4 -Compress)"
    }
    if ($collected.EdgeUpdateTasks[0].State -ne 'Disabled' -or -not $collected.CollectionErrors.Count) {
        throw 'Collector omitted disabled updates or unavailable local evidence.'
    }
    $jsonOutput = @(& $sourcePath -SiteCode PS1 -AsJson)
    if ($jsonOutput.Count -ne 1 -or $jsonOutput[0] -isnot [string] -or
        ($jsonOutput[0] | ConvertFrom-Json).Endpoints[0].Catalog.ReportCount -ne 1) {
        throw 'JSON transport mode did not return exactly one complete document.'
    }
    $proxy.FailListing = $true
    $null = & $sourcePath -SiteCode PS1 -OutputPath $outputPath
    $collected = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if ($null -ne $collected.Endpoints[0].Catalog -or $collected.Endpoints[0].CatalogError -notmatch 'Catalog unavailable') {
        throw 'Full collector persisted a success-shaped fallback for unavailable catalog evidence.'
    }
}
finally { Remove-Item -LiteralPath $outputPath -Force -ErrorAction Stop }
if ([System.Net.ServicePointManager]::SecurityProtocol -ne $originalProtocol) { throw 'Collector changed the caller TLS configuration.' }

$proxy.FailListing = $false
$fixturePassword = [System.Security.SecureString]::new()
$fixturePassword.AppendChar([char]120)
$fixtureCredential = [pscredential]::new('fixture-admin', $fixturePassword)
$hostCommon = [pscustomobject]@{ LocalAdmin = $fixtureCredential; FatalError = $null }
$Common = $hostCommon
$hostState = [pscustomobject]@{
    Calls = 0; Mode = 'Success'; Source = $null; Domain = 'example'
    CredentialLoads = 0; CredentialMode = 'Success'; UninitializedCalls = 0
}
function Get-LocalAdminCredential {
    $hostState.CredentialLoads++
    switch ($hostState.CredentialMode) {
        'Missing' { $hostCommon.FatalError = 'Cached guest credential unavailable'; return $false }
        'Empty' { return $true }
        'Exception' { throw 'Fixture credential cache read denied' }
        default { $hostCommon.LocalAdmin = $fixtureCredential; return $true }
    }
}
Set-Item -Path Function:\Get-LocalAdminCredential -Value (${function:Get-LocalAdminCredential}.GetNewClosure())
function Get-VMNote {
    param($VMName)
    if (-not $VMName) { throw 'VM name is required.' }
    [pscustomobject]@{ domain = $hostState.Domain }
}
Set-Item -Path Function:\Get-VMNote -Value (${function:Get-VMNote}.GetNewClosure())
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch] $AsJob,
        $TimeoutSeconds, [switch] $RequireDomainIdentity, [switch] $FailOnRemoteError, [switch] $SuppressLog,
        [switch] $RebootIfUnresponsive)
    if (-not $VmName -or $VmDomainName -ne 'example' -or -not $DisplayName -or -not $AsJob -or
        $TimeoutSeconds -ne 600 -or -not $RequireDomainIdentity -or -not $FailOnRemoteError -or
        -not $SuppressLog -or $RebootIfUnresponsive) {
        throw 'Host mode lost its bounded, domain-authenticated, read-only transport contract.'
    }
    $hostState.Calls++
    $hostState.Source = $ArgumentList[0]
    if (-not $hostCommon.LocalAdmin) {
        $hostState.UninitializedCalls++
        return $false
    }
    if ($hostState.Mode -eq 'Failure') {
        return [pscustomobject]@{ CommandResult = $false; ScriptBlockFailed = $true; ErrorDetails = 'Guest collection failed' }
    }
    $output = switch ($hostState.Mode) {
        'InvalidJson' { '{broken' }
        'InvalidShape' { '{"Passed":true}' }
        default { & $ScriptBlock @ArgumentList }
    }
    [pscustomobject]@{ CommandResult = $true; ScriptBlockFailed = $false; ScriptBlockOutput = $output }
}
Set-Item -Path Function:\Invoke-VmCommand -Value (${function:Invoke-VmCommand}.GetNewClosure())
$hostOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "MemLabs-Reporting-Host-Test-$([guid]::NewGuid().ToString('N')).json"
try {
    $null = & $sourcePath -VMName 'RP-TEST' -SiteCode PS1 -ReportServerUri 'http://rp.example/ReportServer' -OutputPath $hostOutputPath
    $hostJson = Get-Content -LiteralPath $hostOutputPath -Raw
    $collected = $hostJson | ConvertFrom-Json
    if ($hostState.Calls -ne 1 -or $hostState.Source -notmatch 'function Get-ReportingCatalogEvidence' -or
        $collected.Endpoints.Count -ne 1 -or $collected.Endpoints[0].Uri -ne 'http://rp.example/ReportServer' -or
        $collected.Endpoints[0].Catalog.ReportCount -ne 1) {
        throw 'Host mode did not execute the collector source and preserve its arguments/evidence.'
    }
    $jsonOutput = @(& $sourcePath -VMName 'RP-TEST' -SiteCode PS1 -AsJson)
    if ($jsonOutput.Count -ne 1 -or $jsonOutput[0] -isnot [string] -or
        ($jsonOutput[0] | ConvertFrom-Json).Endpoints.Count -ne 2) {
        throw 'Host JSON transport mode did not preserve the complete guest document.'
    }
    if ($hostState.CredentialLoads -ne 0) { throw 'An initialized host session unnecessarily reloaded its credentials.' }
    $hostCommon.LocalAdmin = $null
    $jsonOutput = @(& $sourcePath -VMName 'RP-TEST' -SiteCode PS1 -AsJson)
    if ($hostState.CredentialLoads -ne 1 -or $hostState.UninitializedCalls -ne 0 -or
        $jsonOutput.Count -ne 1 -or ($jsonOutput[0] | ConvertFrom-Json).Endpoints[0].Catalog.ReportCount -ne 1) {
        throw 'A standalone/lightweight host session did not initialize cached guest credentials before the VM call.'
    }
    foreach ($credentialMode in @('Missing', 'Empty', 'Exception')) {
        $hostCommon.LocalAdmin = $null
        $hostCommon.FatalError = $null
        $hostState.CredentialMode = $credentialMode
        $callCount = $hostState.Calls
        $threw = $false
        try { $null = & $sourcePath -VMName 'RP-TEST' -OutputPath $hostOutputPath }
        catch { $threw = $_.Exception.Message -match 'MemLabs guest.credential' }
        if (-not $threw -or $hostState.Calls -ne $callCount -or
            (Get-Content -LiteralPath $hostOutputPath -Raw) -ne $hostJson) {
            throw "Credential failure '$credentialMode' was hidden, attempted a guest call, or overwrote previous evidence."
        }
    }
    $hostCommon.LocalAdmin = $fixtureCredential
    $hostState.CredentialMode = 'Success'
    foreach ($mode in @('Failure', 'InvalidJson', 'InvalidShape')) {
        $hostState.Mode = $mode
        $threw = $false
        try { $null = & $sourcePath -VMName 'RP-TEST' -OutputPath $hostOutputPath }
        catch { $threw = $true }
        if (-not $threw -or (Get-Content -LiteralPath $hostOutputPath -Raw) -ne $hostJson) {
            throw "Host failure '$mode' was hidden or overwrote previously collected evidence."
        }
    }
    $hostState.Domain = ''
    $callCount = $hostState.Calls
    $threw = $false
    try { $null = & $sourcePath -VMName 'RP-TEST' -OutputPath $hostOutputPath }
    catch { $threw = $_.Exception.Message -match 'Cannot resolve a MemLabs domain' }
    if (-not $threw -or $hostState.Calls -ne $callCount) { throw 'Host mode attempted collection without domain identity metadata.' }
}
finally { Remove-Item -LiteralPath $hostOutputPath -Force -ErrorAction Stop }

$forbiddenCommands = @('Restart-Service', 'Start-Service', 'Stop-Service', 'Set-Service', 'Start-Process',
    'Install-Module', 'Set-RsDatabase', 'Initialize-Rs', 'Set-ItemProperty', 'New-ItemProperty', 'Copy-VMFile')
$mutations = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $forbiddenCommands
        }, $true))
if ($mutations.Count) { throw "Read-only collector contains mutation command(s): $($mutations.Extent.Text -join '; ')" }

Write-Host 'PASS -- local and host reporting collection preserve evidence, surface failures, and use domain-authenticated transport without guest file copies.'
