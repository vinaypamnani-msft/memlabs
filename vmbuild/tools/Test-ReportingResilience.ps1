<#
.SYNOPSIS
    Exercises file-first reporting capture, independent fallbacks, and persistence.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1')
. (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
$tokens = $null; $errors = $null
$collectorPath = Join-Path $PSScriptRoot 'Get-ReportingDiagnostics.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($collectorPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw "Collector parser errors: $($errors -join '; ')" }
foreach ($name in @('Get-ReportingSourceHash','New-ReportingSqlConnectionString','Invoke-ReportingWebRequest','Get-ReportingCatalogEvidence','Get-ReportingPortalEvidence')) {
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            },$true))
    if ($definition.Count -ne 1) { throw "Expected one $name definition." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
function Assert-ReportingTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingResilience-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $testRoot -ItemType Directory
$password = [Security.SecureString]::new(); $password.AppendChar([char]120)
$credential = [pscredential]::new('fixture-user',$password)
try {
    $source = Join-Path $testRoot 'source.log'
    [IO.File]::WriteAllBytes($source,[byte[]](0..31))
    $locked = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $budget = @{ Bytes = 0L }
        $copy = Copy-ReportingEvidenceFile -Source $source -Destination (Join-Path $testRoot 'copy.log') -Budget $budget -MaxFileBytes 32 -TailBytes 8 -MaxTotalBytes 64
        Assert-ReportingTest ($copy.CopiedBytes -eq 32 -and -not $copy.Truncated -and $budget.Bytes -eq 32) 'A readable locked log or exact full-file boundary failed.'
        $locked.Position = 32; $locked.WriteByte(32); $locked.Flush()
        $tail = Copy-ReportingEvidenceFile -Source $source -Destination (Join-Path $testRoot 'tail.log') -Budget $budget -MaxFileBytes 32 -TailBytes 8 -MaxTotalBytes 64
        Assert-ReportingTest ($tail.Truncated -and $tail.Offset -eq 25 -and $tail.CopiedBytes -eq 8 -and
            ([IO.File]::ReadAllBytes($tail.Destination) -join ',') -eq '25,26,27,28,29,30,31,32') 'Tail snapshot threshold/bytes are incorrect.'
        $failed = $false
        try { $null = Copy-ReportingEvidenceFile -Source $source -Destination (Join-Path $testRoot 'oversize.evtx') -Budget $budget -MaxFileBytes 32 -RequireWholeFile }
        catch { $failed = $_.Exception.Message -match 'Whole-file evidence exceeds' }
        Assert-ReportingTest ($failed -and -not [IO.File]::Exists((Join-Path $testRoot 'oversize.evtx'))) 'Oversized EVTX was silently truncated or retained as a complete file.'
        $failed = $false
        try { $null = Copy-ReportingEvidenceFile -Source $source -Destination (Join-Path $testRoot 'budget.log') -Budget $budget -MaxFileBytes 32 -TailBytes 8 -MaxTotalBytes 47 }
        catch { $failed = $_.Exception.Message -match 'aggregate limit' }
        Assert-ReportingTest $failed 'Aggregate byte limit was not enforced exactly.'
    }
    finally { $locked.Dispose() }
    $identityBefore = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $output = @(Invoke-ReportingNetworkIdentity -Credential ([pscredential]::new('fixture-user@fixture.invalid',$password)) -Action { 'fixture-network-context' })
        Assert-ReportingTest ($output.Count -eq 1 -and $output[0] -eq 'fixture-network-context' -and
            [Security.Principal.WindowsIdentity]::GetCurrent().Name -eq $identityBefore) 'Network-only credential scope did not restore the caller identity.'
    }

    & {
        param($ScenarioRoot,[pscredential]$Credential,$RootPath,$CollectorPath)
        . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
        $state = [pscustomobject]@{
            Mode = 'Native'; Calls = [Collections.Generic.List[object]]::new()
            GuestCalls = 0; Source = (Join-Path $ScenarioRoot 'source.log'); PrefixRoot = ''
        }
        function Write-Log { param($Text,[switch]$LogOnly,[switch]$Warning) }
        function Get-ReportingCollectionTargets {
            param($VMName,$Note,$SiteCode)
            [pscustomobject]@{ VMName = $VMName; Note = $Note; Kind = 'ReportingServer'; Addresses = @('192.0.2.1','fixture-rp.fixture.test') }
            [pscustomobject]@{ VMName = 'SITE1'; Note = [pscustomobject]@{ siteCode = 'PS1' }; Kind = 'SiteServer'; Addresses = @('192.0.2.2') }
        }
        function New-Result {
            param($Output,[Alias('Error')][string]$Failure = '',[bool]$TimedOut = $false)
            [pscustomobject]@{ Output = $Output; Error = $Failure; TimedOut = $TimedOut; ElapsedSeconds = 0.1 }
        }
        function Get-FixtureInventory {
            @{
                ComputerName = 'RP1'; IdentityVerified = $true
                OperatingSystem = [pscustomobject]@{ Caption = 'Fixture OS' }
                Services = @([pscustomobject]@{ Name = 'PowerBIReportServer'; State = 'Running' })
                ReportServerConfiguration = @([pscustomobject]@{ DatabaseServerName = 'RP1.fixture.test,1544'; DatabaseName = 'ReportServer' })
                Events = @()
            }
        }
        function Get-FixtureWeb {
            param($Kind)
            switch ($Kind) {
                Catalog { [pscustomobject]@{ RootType = 'Folder'; ExpectedFolder = '/ConfigMgr_PS1'; ConfigMgrFolderFound = $true; ReportCount = 3 } }
                Portal { [pscustomobject]@{ Uri = 'https://RP1.fixture.test/Reports/'; StatusCode = 200; HtmlLength = 100; ScriptAssets = @([pscustomobject]@{ StatusCode = 200; Error = $null }); RestApi = [pscustomobject]@{ StatusCode = 200; Error = $null } } }
                ReportServerPage { [pscustomobject]@{ StatusCode = 200; HtmlLength = 100 } }
            }
        }
        function Invoke-ReportingHostWorker {
            param($Operation,$Parameters,$PrimitiveSource,$TimeoutSeconds,$CheckpointPath)
            $state.Calls.Add([pscustomobject]@{ Operation = $Operation; Parameters = $Parameters })
            if ($Operation -ne 'Files' -and -not (Get-ChildItem -LiteralPath $state.PrefixRoot -Filter '*-files-*.json')) {
                throw 'A non-file probe ran before the raw-file capture manifest was durable.'
            }
            switch ($Operation) {
                Files {
                    Write-MemLabsProcessProgress -Path $Parameters.ManifestPath -Record @{ Files = @(); Status = 'Running' }
                    if ($state.Mode -eq 'SmbFallback' -and $Parameters.Target -eq '192.0.2.1') { return (New-Result -Error 'Fixture first SMB address failed') }
                    if ($state.Mode -eq 'NoSmb') { return (New-Result -Error 'Fixture SMB blocked') }
                    $dest = Join-Path $Parameters.LogDirectory "$($Parameters.Prefix)-$($Parameters.VMName)-raw.log"
                    $copy = Copy-ReportingEvidenceFile -Source $state.Source -Destination $dest -Budget @{Bytes=0L}
                    $copy.Source = "\\$($Parameters.Target)\C`$\fixture.log"
                    $manifest = @{ Files = @($copy); BrowserVersions = @([pscustomobject]@{ Version = '94.0.0.0'; Source = 'SMB' }); Status = 'Captured' }
                    Write-MemLabsProcessProgress -Path $Parameters.ManifestPath -Record $manifest
                    if ($state.Mode -eq 'FileTimeout') {
                        $result = New-Result -Error 'Fixture file worker timed out' -TimedOut $true
                        $result | Add-Member NoteProperty PartialOutput ([pscustomobject]$manifest)
                        return $result
                    }
                    return (New-Result ([pscustomobject]$manifest))
                }
                Inventory {
                    if ($state.Mode -in @('WinRMRecovery','AllGuestFail','NoEvidence')) { return (New-Result -Error 'Fixture RPC unavailable') }
                    return (New-Result (Get-FixtureInventory))
                }
                Events { return (New-Result ([pscustomobject]@{ Method='NativeEventRPC'; Target=$Parameters.Target; EventLogs=@(); Errors=@() })) }
                Web {
                    if ($state.Mode -in @('WinRMRecovery','NoEvidence') -or
                        ($state.Mode -eq 'HostDnsFailure' -and $Parameters.Uri -match 'RP1\.fixture\.test') -or
                        ($state.Mode -eq 'AllGuestFail' -and $Parameters.Kind -eq 'Catalog')) {
                        return (New-Result -Error 'Fixture host HTTP unavailable')
                    }
                    return (New-Result (Get-FixtureWeb $Parameters.Kind))
                }
                Sql {
                    if ($state.Mode -eq 'NoEvidence') { return (New-Result -Error 'Fixture SQL unavailable') }
                    if ($state.Mode -eq 'HostDnsFailure' -and $Parameters.Server -match '^RP1\.') { return (New-Result -Error 'Fixture host DNS unavailable') }
                    Assert-ReportingTest ($Parameters.Server -match ',1544$') 'SQL target lost its configured non-default port.'
                    return (New-Result ([pscustomobject]@{ Server = $Parameters.Server; Database = 'ReportServer'; ExpectedFolder = '/ConfigMgr_PS1'; FolderExists = $true; ReportCount = 3; VerificationSucceeded = $true; Source = 'HostSQL' }))
                }
                WinRM {
                    if ($state.Mode -in @('AllGuestFail','NoEvidence')) { return (New-Result -Error 'Fixture WinRM unavailable') }
                    $kind = $Parameters.ProbeArguments[1]
                    if ($kind -eq 'RP1') { return (New-Result (Get-FixtureInventory)) }
                    if ($kind -in @('Catalog','ReportServerPage','Portal')) { return (New-Result (Get-FixtureWeb $kind)) }
                    throw "Unexpected WinRM fixture kind '$kind'."
                }
                default { throw "Unexpected operation '$Operation'." }
            }
        }
        function Invoke-VmCommand {
            param($VmName,$VmDomainName,$ScriptBlock,$ArgumentList,$DisplayName,[switch]$AsJob,$TimeoutSeconds,
                $SessionMaxRetries,[switch]$RequireDomainIdentity,[switch]$FailOnRemoteError,[switch]$SuppressLog,[switch]$RebootIfUnresponsive)
            $state.GuestCalls++
            Assert-ReportingTest (-not $RebootIfUnresponsive -and $AsJob -and $SessionMaxRetries -eq 1 -and
                $RequireDomainIdentity -and $FailOnRemoteError -and $TimeoutSeconds -le 50) 'Guest fallback lost its bounded, non-restarting contract.'
            $manifests = @(Get-ChildItem -LiteralPath $state.PrefixRoot -Filter '*-files-*.json')
            if ($state.Mode -ne 'NoSmb') { Assert-ReportingTest ($manifests.Count -gt 0) 'Guest PowerShell started before file capture.' }
            if ($state.Mode -eq 'NoSmb' -and $DisplayName -like '*LogFiles') {
                return [pscustomobject]@{
                    CommandResult = $true; ScriptBlockFailed = $false
                    ScriptBlockOutput = [pscustomobject]@{ Files = @([pscustomobject]@{ Source='C:\fixture.log'; SourceBytes=3; CopiedBytes=3; Offset=0; Truncated=$false; ContentBase64=[Convert]::ToBase64String([byte[]](1,2,3)) }); Errors=@() }
                }
            }
            [pscustomobject]@{ CommandResult = $false; ScriptBlockFailed = $true; ChannelBroken = $true; ErrorDetails = 'Fixture Hyper-V socket target process has ended' }
        }
        $note = [pscustomobject]@{ domain = 'fixture.test'; role = 'DomainMember'; sqlVersion = 'Sql Server 2022'; sqlPort = 1544; sqlInstanceName = 'MSSQLSERVER' }
        $collectorSource = Get-Content -LiteralPath $CollectorPath -Raw
        $processSource = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1') -Raw
        foreach ($mode in @('Native','SmbFallback','FileTimeout','WinRMRecovery','AllGuestFail','NoSmb','NoEvidence','HostDnsFailure')) {
            $state.Mode = $mode; $state.GuestCalls = 0; $state.Calls.Clear()
            $directory = Join-Path $ScenarioRoot $mode
            $null = New-Item -Path $directory -ItemType Directory
            $state.PrefixRoot = $directory
            $output = @(Invoke-ReportingHostCollection -VMName RP1 -Note $note -Credential $Credential -CollectorSource $collectorSource `
                    -ProcessSource $processSource -TargetPath (Join-Path $directory 'report.json') -SiteCode PS1 -AsJson)
            Assert-ReportingTest ($output.Count -eq 1 -and $output[0] -is [string]) "$mode polluted its JSON return."
            $report = $output[0] | ConvertFrom-Json
            $checkpoints = @(Get-ChildItem -LiteralPath $directory -Filter '*.partial.json')
            Assert-ReportingTest ($checkpoints.Count -eq 1 -and $report.SchemaVersion -eq 2) "$mode did not retain a valid durable checkpoint."
            $saved = Get-Content -LiteralPath $checkpoints[0].FullName -Raw | ConvertFrom-Json
            Assert-ReportingTest ($saved.CurrentStage -eq $report.CurrentStage) "$mode checkpoint did not retain its last state."
            Assert-ReportingTest ($report.RawFiles.Count -gt 0) "$mode lost raw files despite an available copy path."
            foreach ($file in $report.RawFiles) { Assert-ReportingTest ([IO.File]::Exists($file.Destination)) "$mode references a raw file that was not saved." }
            if ($mode -eq 'Native') { Assert-ReportingTest ($state.GuestCalls -eq 0 -and -not $report.CollectionFailed) 'Healthy native paths unnecessarily invoked guest PowerShell.' }
            if ($mode -eq 'WinRMRecovery') { Assert-ReportingTest (-not $report.CollectionFailed -and $state.GuestCalls -gt 0 -and @($report.Attempts | Where-Object Method -eq 'PowerShellDirect').Count -gt 0) 'WinRM did not recover isolated PowerShell Direct failures.' }
            if ($mode -eq 'AllGuestFail') { Assert-ReportingTest (-not $report.CollectionFailed -and $report.SqlCatalog[0].VerificationSucceeded) 'Independent SQL/portal/file evidence was discarded after every guest PowerShell method failed.' }
            if ($mode -in @('AllGuestFail','WinRMRecovery','NoEvidence')) {
                Assert-ReportingTest ($state.GuestCalls -eq 1 -and @($report.Attempts | Where-Object Name -eq 'PostFailureEvents').Count -eq 1) 'A broken PowerShell Direct channel was retried or its fresh native crash events were not collected.'
            }
            if ($mode -eq 'HostDnsFailure') { Assert-ReportingTest (@($report.SqlCatalog | Where-Object { $_.VerificationSucceeded -and $_.Server -eq '192.0.2.1,1544' }).Count -eq 1) 'SQL IP fallback lost the non-default port or authoritative count.' }
            if ($mode -eq 'NoEvidence') { Assert-ReportingTest ($report.CollectionFailed -and $report.CollectionStatus -eq 'Partial' -and $report.CollectionErrors.Count -gt 0) 'Unavailable facts became an empty healthy inventory.' }
            if ($mode -eq 'NoEvidence') {
                $latest = Join-Path $directory 'report.json'
                [IO.File]::WriteAllText($latest,'earlier known-good evidence')
                $message = ''
                try {
                    $null = Invoke-ReportingHostCollection -VMName RP1 -Note $note -Credential $Credential -CollectorSource $collectorSource `
                        -ProcessSource $processSource -TargetPath $latest -SiteCode PS1
                }
                catch { $message = $_.Exception.Message }
                Assert-ReportingTest ($message -match 'Evidence: (.+\.json); checkpoint:') 'Standalone failure did not name its durable evidence.'
                $failedFile = $Matches[1]
                $failure = Get-Content -LiteralPath $failedFile -Raw | ConvertFrom-Json
                Assert-ReportingTest ($failure.CollectionFailed -and $failure.RawFiles.Count -gt 0 -and
                    [IO.File]::ReadAllText($latest) -eq 'earlier known-good evidence') 'Standalone partial capture overwrote previous success or discarded its raw logs.'
            }
        }
    } $testRoot $credential $RootPath $collectorPath
    & {
        . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
        function Write-Log { param($Text,[switch]$Warning,[switch]$LogOnly) }
        function Get-VMNetworkAdapter { param($VMName,$ErrorAction); [pscustomobject]@{IPAddresses=@('192.0.2.10')} }
        function Get-VM {
            param($ErrorAction)
            [pscustomobject]@{Name='OTHER';Notes='{"domain":"fixture.test","role":"Primary","siteCode":"BAD"}'}
            [pscustomobject]@{Name='UNMANAGED';Notes='Not a MemLabs JSON note'}
            [pscustomobject]@{Name='SITE1';Notes='{"domain":"fixture.test","role":"Primary","siteCode":"PS1","remoteSQLVM":"RP1"}'}
        }
        $note = [pscustomobject]@{domain='fixture.test';AssignedIP='192.0.2.99'}
        $targets = @(Get-ReportingCollectionTargets -VMName RP1 -Note $note)
        Assert-ReportingTest ($targets.Count -eq 2 -and $targets[1].VMName -eq 'SITE1') 'A missing remoteSQLVM/OtherNode matched an unrelated local-SQL site or malformed note aborted discovery.'
        Assert-ReportingTest ('192.0.2.10' -in $targets[0].Addresses -and '192.0.2.99' -notin $targets[0].Addresses) 'A stale note IP overrode current Hyper-V address evidence.'
    }
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
Write-Host 'PASS -- locked file capture, exact limits, file-first ordering, independent transports, partial checkpoints, and fallback evidence retention.'
