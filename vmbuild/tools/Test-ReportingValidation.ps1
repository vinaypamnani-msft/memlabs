<#
.SYNOPSIS
    Exercises automatic Phase 11 reporting validation and retained diagnostics.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Read by the imported Phase 11 functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'role', Justification = 'Read by the extracted dispatcher block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'validationActivity', Justification = 'Read by the extracted dispatcher block.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw "Validation parse errors: $($parseErrors -join '; ')" }
function Get-TestDefinition {
    param([string] $Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    $definitions[0]
}
foreach ($name in @('Test-ReportingDiagnosticEvidence', 'Format-TestResult', 'Add-Phase11Output', 'Save-Phase11GuestLogs')) {
    . ([scriptblock]::Create((Get-TestDefinition $name).Extent.Text))
}
function New-TestEvidence {
    [pscustomobject]@{
        ComputerName = 'SQL1'; CollectedAt = '2026-10-29T12:00:00Z'; CollectionErrors = @()
        Browsers = @([pscustomobject]@{ Version = '94.0.0.0' })
        Services = @([pscustomobject]@{ Name = 'PowerBIReportServer'; State = 'Running' })
        Endpoints = @([pscustomobject]@{
                Uri = 'https://SQL1.adatum.com/ReportServer'; CatalogError = $null; PortalError = $null
                Catalog = [pscustomobject]@{ RootType = 'Folder'; ExpectedFolder = '/ConfigMgr_PS1'; ConfigMgrFolderFound = $true; ReportCount = 3 }
                Portal = [pscustomobject]@{
                    Uri = 'https://SQL1.adatum.com/Reports/'; StatusCode = 200; HtmlLength = 100
                    ScriptAssets = @([pscustomobject]@{ StatusCode = 200; Error = $null })
                    RestApi = [pscustomobject]@{ StatusCode = 200; Error = $null }
                }
            })
    }
}
$evidence = New-TestEvidence
if (-not (Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'Healthy reporting failed.' }
$evidence.Endpoints[0].Catalog.ReportCount = 1
if (-not (Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'The one-published-report boundary failed.' }
foreach ($case in @('EmptyRoot', 'EmptyFolder', 'WrongSite', 'UnreadableCatalog', 'EmptyPortal', 'MissingAssets', 'BrokenAsset', 'BrokenApi')) {
    $evidence = New-TestEvidence
    switch ($case) {
        'EmptyRoot' { $evidence.Endpoints[0].Catalog.ConfigMgrFolderFound = $false; $evidence.Endpoints[0].Catalog.ReportCount = 0 }
        'EmptyFolder' { $evidence.Endpoints[0].Catalog.ReportCount = 0 }
        'WrongSite' { $evidence.Endpoints[0].Catalog.ExpectedFolder = '/ConfigMgr_PS2' }
        'UnreadableCatalog' { $evidence.Endpoints[0].Catalog = $null; $evidence.Endpoints[0].CatalogError = 'Access denied' }
        'EmptyPortal' { $evidence.Endpoints[0].Portal.HtmlLength = 0 }
        'MissingAssets' { $evidence.Endpoints[0].Portal.ScriptAssets = @() }
        'BrokenAsset' { $evidence.Endpoints[0].Portal.ScriptAssets[0].Error = '404' }
        'BrokenApi' { $evidence.Endpoints[0].Portal.RestApi.Error = 'API unavailable' }
    }
    $verdict = Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1
    if ($verdict.Passed -or -not ($verdict.Details | Where-Object { $_ -like 'FAIL:*' })) { throw "Reporting case '$case' did not fail explicitly." }
}
$evidence = New-TestEvidence
$evidence.Services[0].Name = 'ReportServer'
$evidence.Endpoints[0].Portal.RestApi.StatusCode = 404
$evidence.Endpoints[0].Portal.RestApi.Error = 'Not found'
if (-not (Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'Legacy integrated SSRS without v2 REST regressed.' }
$evidence.Endpoints[0].Portal.RestApi.StatusCode = 500
if ((Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'Legacy API failure other than unsupported v2 was accepted.' }
$evidence = New-TestEvidence
$evidence.Endpoints = @([pscustomobject]@{ Uri = 'http://unconfigured'; CatalogError = 'Unavailable' }) + $evidence.Endpoints
$verdict = Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1
if (-not $verdict.Passed -or ($verdict.Details | Where-Object { $_ -like 'FAIL:*' })) { throw 'An unused protocol invalidated the working endpoint.' }
$evidence.Endpoints = @()
if ((Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'Absent evidence was treated as healthy.' }
$evidence = New-TestEvidence
$evidence.Endpoints[0].Catalog = $null
$evidence.Endpoints[0].CatalogError = 'SOAP transport unavailable'
$evidence | Add-Member NoteProperty SqlCatalog @([pscustomobject]@{
    Source='HostSQL'; Server='SQL1.fixture'; Database='ReportServer'; VerificationSucceeded=$true
    ExpectedFolder='/ConfigMgr_PS1'; FolderExists=$true; ReportCount=1
})
if (-not (Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw 'Verified independent SQL publication did not satisfy an unavailable SOAP transport.' }
foreach ($case in @('WrongSite','Unverified','NoFolder','Empty')) {
    $sql = $evidence.SqlCatalog[0]
    $sql.ExpectedFolder='/ConfigMgr_PS1'; $sql.VerificationSucceeded=$true; $sql.FolderExists=$true; $sql.ReportCount=1
    switch ($case) {
        WrongSite { $sql.ExpectedFolder='/ConfigMgr_PS2' }
        Unverified { $sql.VerificationSucceeded=$false }
        NoFolder { $sql.FolderExists=$false }
        Empty { $sql.ReportCount=0 }
    }
    if ((Test-ReportingDiagnosticEvidence $evidence -SiteCode PS1).Passed) { throw "Invalid SQL fallback '$case' was accepted." }
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MemLabs-ReportingValidation-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $fixtureRoot -ItemType Directory
$null = New-Item -Path (Join-Path $fixtureRoot 'tools') -ItemType Directory
$logDir = Join-Path $fixtureRoot 'logs'
$null = New-Item -Path $logDir -ItemType Directory
$fixturePassword = [System.Security.SecureString]::new()
$fixturePassword.AppendChar([char]120)
$Common = [pscustomobject]@{
    LogPath = (Join-Path $logDir 'VMBuild.adatum.com.log')
    LocalAdmin = [pscredential]::new('fixture-admin', $fixturePassword)
}
$fixtureCollector = @'
[CmdletBinding()]
param([string]$VMName, [string]$SiteCode, [uri]$ReportServerUri, [switch]$AsJson)
if (-not $AsJson) { throw 'Automatic collection must use JSON transport.' }
$root = Split-Path -Parent $PSScriptRoot
[pscustomobject]@{ VMName = $VMName; SiteCode = $SiteCode; ReportServerUri = "$ReportServerUri" } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'Arguments.json') -Encoding UTF8
if (Test-Path -LiteralPath (Join-Path $root 'Throw.txt')) { throw 'Fixture collector transport failure' }
Get-Content -LiteralPath (Join-Path $root 'Evidence.json') -Raw
'@
$fixtureCollector | Set-Content -LiteralPath (Join-Path $fixtureRoot 'tools\Get-ReportingDiagnostics.ps1') -Encoding UTF8
$definition = Get-TestDefinition 'Test-ReportingFunctionality'
$functionText = $definition.Extent.Text.Replace('(Split-Path $PSScriptRoot -Parent)', "'$($fixtureRoot.Replace("'", "''"))'")
. ([scriptblock]::Create($functionText))
$collectorAssignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$Phase11ReportingSiteLogCollector'
    }, $true)
. ([scriptblock]::Create($collectorAssignment.Extent.Text))
$primary = [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PS1'; remoteSQLVM = 'SQL1'; domain = 'adatum.com' }
$rp = [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember'; installRP = $true }
$config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'adatum.com' }; virtualMachines = @($primary, $rp) }
$script:ReportingState = @{ ServicePassed = $true; RolePassed = $true; Existing = @(); Calls = [System.Collections.Generic.List[object]]::new() }
$reportingState = $script:ReportingState
function Write-Log { param($Text, [switch]$LogOnly, [switch]$Failure, [switch]$Warning) }
function Get-List {
    param($Type, $DomainName)
    if ($Type -ne 'VM' -or $DomainName -ne 'adatum.com') { throw 'Reporting owner lookup lost domain scope.' }
    $script:ReportingState.Existing
}
function Get-SiteServerForSiteCode {
    param($deployConfig, $SiteCode, $DomainName, $type)
    if (-not $deployConfig -or $SiteCode -ne 'PS1' -or $DomainName -ne 'adatum.com' -or $type -ne 'VM') { throw 'Incorrect site-server resolution arguments.' }
    $primary
}
function Get-VMNote { param($VMName); [pscustomobject]@{ vmName = $VMName; domain = 'adatum.com' } }
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds,
        [switch]$RequireDomainIdentity, [switch]$FailOnRemoteError)
    if (-not $ScriptBlock -or $VmDomainName -ne 'adatum.com' -or -not $AsJob -or -not $SuppressLog) {
        throw 'Unexpected validation or log-capture transport.'
    }
    $reportingState.Calls.Add([pscustomobject]@{ VMName = $VmName; DisplayName = $DisplayName; Arguments = $ArgumentList })
    if (-not (Get-ChildItem -LiteralPath $logDir -Filter '*ReportingDiagnostics.json')) { throw 'Reporting validation invoked guest PowerShell before retaining the file-first diagnostic snapshot.' }
    if ($DisplayName -eq 'Collect reporting diagnostics') {
        if ($TimeoutSeconds -ne 600 -or -not $RequireDomainIdentity -or -not $FailOnRemoteError -or
            $ArgumentList[0] -notmatch 'function Get-ReportingCatalogEvidence' -or $ArgumentList[1] -ne 'PS1') {
            throw 'Real collector host integration lost its source, site, or safe transport flags.'
        }
        return [pscustomobject]@{
            CommandResult = $true; ScriptBlockFailed = $false
            ScriptBlockOutput = (Get-Content -LiteralPath (Join-Path $fixtureRoot 'Evidence.json') -Raw)
        }
    }
    if ($TimeoutSeconds -gt 300) { throw 'Unexpected validation/log-capture timeout.' }
    $details = [System.Collections.Generic.List[string]]::new()
    switch ($DisplayName) {
        'Phase11-RP-Test' {
            if (-not $reportingState.ServicePassed) { $details.Add('FAIL: Reporting service unavailable') }
            $output = @{ Passed = $reportingState.ServicePassed; Details = $details; ReportServerUri = 'https://SQL1.adatum.com/ReportServer' }
        }
        'Phase11-RP-CMRole-Test' {
            if (-not $reportingState.RolePassed) { $details.Add('FAIL: Reporting role missing') }
            $output = @{ Passed = $reportingState.RolePassed; Details = $details }
        }
        'Pull RP-Site logs' {
            $output = @{ 'srsrp.log' = 'Report publication log'; 'srsrpsetup.log' = 'Role setup log'; 'sitecomp.log' = 'Site component log' }
        }
        default { throw "Unexpected reporting call '$DisplayName'." }
    }
    [pscustomobject]@{ CommandResult = $true; ScriptBlockFailed = $false; ScriptBlockOutput = $output }
}
Set-Item -Path Function:\Invoke-VmCommand -Value (${function:Invoke-VmCommand}.GetNewClosure())
function Invoke-TestReporting {
    param([object]$Evidence = (New-TestEvidence))
    $Evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixtureRoot 'Evidence.json') -Encoding UTF8
    $script:Phase11OutputBuffer = [System.Collections.Generic.List[hashtable]]::new()
    $script:ReportingState.Calls.Clear()
    $before = @(Get-ChildItem -LiteralPath $logDir -Filter '*ReportingDiagnostics.json')
    $output = @(Test-ReportingFunctionality -VMName SQL1 -Domain adatum.com -CurrentItem $rp -DeployConfig $config)
    if ($output.Count -ne 1 -or $output[0] -isnot [bool]) { throw 'Reporting validation polluted its boolean return.' }
    $snapshots = @(Get-ChildItem -LiteralPath $logDir -Filter '*ReportingDiagnostics.json')
    if ($snapshots.Count -ne $before.Count + 1) { throw 'Every reporting validation must retain one snapshot beside the build log.' }
    $latest = $snapshots | Sort-Object Name -Descending | Select-Object -First 1
    [pscustomobject]@{ Passed = $output[0]; Snapshot = (Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json) }
}
try {
    $run = Invoke-TestReporting
    if (-not $run.Passed -or $run.Snapshot.Endpoints[0].Catalog.ReportCount -ne 3 -or $run.Snapshot.Browsers[0].Version -ne '94.0.0.0') {
        throw 'Healthy SQL-hosted RP did not retain report/browser evidence and pass.'
    }
    $arguments = Get-Content -LiteralPath (Join-Path $fixtureRoot 'Arguments.json') -Raw | ConvertFrom-Json
    if ($arguments.SiteCode -ne 'PS1' -or $arguments.ReportServerUri) { throw 'Automatic collector lost its inferred site or forced a URL before file-first collection.' }
    if (@($script:ReportingState.Calls | Where-Object { $_.VMName -eq 'PRI1' }).Count -ne 2 -or
        @((Get-ChildItem -LiteralPath $logDir -Filter 'PRI1-Phase11-*-srsrp.log')).Count -ne 1 -or
        -not ($script:Phase11OutputBuffer | Where-Object { $_.Text -match 'Reporting diagnostic snapshot ->' })) {
        throw 'Owning-site role check, reporting log retention, or human-visible evidence path is missing.'
    }
    $smsDir = Join-Path $fixtureRoot 'SMS'
    $null = New-Item -Path (Join-Path $smsDir 'Logs') -ItemType Directory -Force
    foreach ($name in @('srsrp.log', 'srsrpsetup.log', 'sitecomp.log')) {
        "Fixture $name" | Set-Content -LiteralPath (Join-Path $smsDir "Logs\$name")
    }
    $siteEvidence = & {
        param($Collector, $Directory)
        function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction); @{ 'Installation Directory' = $Directory } }
        & $Collector
    } $Phase11ReportingSiteLogCollector $smsDir
    if ($siteEvidence.Count -ne 3 -or $siteEvidence['srsrp.log'] -ne 'Fixture srsrp.log') {
        throw 'Site reporting collector did not read its required log files.'
    }
    $siteUnavailable = & {
        param($Collector)
        function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction); throw 'Registry unavailable' }
        & $Collector
    } $Phase11ReportingSiteLogCollector
    if ($siteUnavailable['ReportingSiteDiagnostics.txt'] -notmatch 'Registry unavailable') { throw 'Site log collector hid unavailable evidence.' }
    $missing = New-TestEvidence
    $missing.Endpoints[0].Catalog.ReportCount = 0
    if ((Invoke-TestReporting $missing).Passed) { throw 'Empty report publication passed main validation.' }
    $broken = New-TestEvidence
    $broken.Endpoints[0].Portal.RestApi.Error = 'Portal API failure'
    if ((Invoke-TestReporting $broken).Passed) { throw 'Broken portal passed main validation.' }
    foreach ($failure in @('ServicePassed', 'RolePassed')) {
        $script:ReportingState[$failure] = $false
        if ((Invoke-TestReporting).Passed) { throw "Reporting '$failure' failure was overwritten by a healthy snapshot." }
        $script:ReportingState[$failure] = $true
    }
    'Fail' | Set-Content -LiteralPath (Join-Path $fixtureRoot 'Throw.txt')
    $failed = Invoke-TestReporting
    if ($failed.Passed -or -not $failed.Snapshot.CollectionFailed -or $failed.Snapshot.CollectionErrors[0] -notmatch 'transport failure') {
        throw 'Collector failure was hidden or not retained on the host.'
    }
    Remove-Item -LiteralPath (Join-Path $fixtureRoot 'Throw.txt')
    $malformed = Invoke-TestReporting ([pscustomobject]@{ Unexpected = $true })
    if ($malformed.Passed -or -not $malformed.Snapshot.CollectionFailed) { throw 'Malformed evidence did not leave an explicit failure snapshot.' }
    $config.virtualMachines = @($rp)
    $script:ReportingState.Existing = @($primary)
    if (-not (Invoke-TestReporting).Passed) { throw 'Partial-config reporting failed to resolve its existing owning site.' }
    $config.virtualMachines = @($primary, $rp)
    $primary.remoteSQLVM = 'SQL2'
    $rp | Add-Member NoteProperty OtherNode 'SQL2'
    if (-not (Invoke-TestReporting).Passed) { throw 'Reporting on the SQL Always On partner lost its owning site.' }
    $primary.remoteSQLVM = 'SQL1'
    $rp.OtherNode = $null
    $secondOwner = [pscustomobject]@{ vmName = 'PRI2'; role = 'Primary'; siteCode = 'PS2'; remoteSQLVM = 'SQL1' }
    $config.virtualMachines = @($primary, $secondOwner, $rp)
    if ((Invoke-TestReporting).Passed) { throw 'Ambiguous reporting ownership was silently accepted.' }
}
finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop }

$guestAssignment = $definition.Body.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$scriptBlock'
    }, $true)
$guest = & ([scriptblock]::Create($guestAssignment.Extent.Text + "`nreturn `$scriptBlock"))
& {
    function Get-Service { param($Name, $ErrorAction); [pscustomobject]@{ Name = 'PowerBIReportServer'; Status = 'Running' } }
    function Get-WmiObject { param($Class); [pscustomobject]@{ Domain = 'adatum.com' } }
    $proxy = [pscustomobject]@{}
    $proxy | Add-Member ScriptMethod GetItemType { param($Path) 'Folder' }
    function New-WebServiceProxy { param($Uri, [switch]$UseDefaultCredential, $ErrorAction); $proxy }
    $guestResult = & $guest
    if (-not $guestResult.Passed -or $guestResult.ReportServerUri -ne "https://$env:COMPUTERNAME.adatum.com/ReportServer") {
        throw 'SOAP warmup no longer returns its verified report-server URL.'
    }
}
$roleAssignment = $definition.Body.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$rpRoleScript'
    }, $true)
$guestRole = & ([scriptblock]::Create($roleAssignment.Extent.Text + "`nreturn `$rpRoleScript"))
& {
    function Get-WmiObject {
        param($Namespace, $Class, $Filter, $ErrorAction)
        if ($Namespace -ne 'root\SMS\site_PS1' -or $Class -ne 'SMS_SystemResourceList' -or
            $Filter -ne "RoleName='SMS SRS Reporting Point' AND (ServerName='SQL1' OR ServerName='SQL1.adatum.com')") {
            throw 'Reporting role query lost exact server/site scope.'
        }
        [pscustomobject]@{ ServerName = 'SQL1.adatum.com' }
    }
    function Start-Sleep { param($Seconds) }
    if (-not (& $guestRole PS1 SQL1 adatum.com).Passed) { throw 'Exact reporting-role registration probe failed.' }
}
$dispatch = (Get-TestDefinition 'Test-VmFunctionality').Body.Find({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$CurrentItem.installRP'
    }, $true)
if (-not $dispatch) { throw 'Reporting diagnostics are still gated by an earlier role validation success.' }
& {
    function Write-ValidationStep { param($VMName, $RoleLabel, $Activity, $Status) }
    function Test-ReportingFunctionality { param($VMName, $Domain, $CurrentItem, $DeployConfig); $script:DispatchCount++; $true }
    $script:DispatchCount = 0
    $testsPassed = $false
    $CurrentItem = [pscustomobject]@{ installRP = $true }
    $VMName = 'SQL1'; $role = 'DomainMember'; $validationActivity = 'Fixture'; $domain = 'adatum.com'; $DeployConfig = @{}
    . ([scriptblock]::Create($dispatch.Extent.Text))
    if ($testsPassed -or $script:DispatchCount -ne 1) { throw 'Earlier role failure skipped RP capture or was overwritten.' }
}
Write-Host 'PASS -- Phase 11 retains reporting evidence on every check, validates publication/portal health, resolves SQL-hosted RPs, and preserves failures.'
