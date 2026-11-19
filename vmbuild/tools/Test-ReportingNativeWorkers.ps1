<#
.SYNOPSIS
    Exercises actual bounded host workers and native reporting evidence helpers.
#>
[CmdletBinding()]
param([string]$RootPath)
$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1')
. (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
function Import-ReportingTestDefinition {
    param([string]$Path,[string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "$Path does not parse." }
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if (-not $node) { throw "Missing $Name." }
    [scriptblock]::Create($node.Extent.Text)
}
$entryPath = Join-Path $PSScriptRoot 'Get-ReportingDiagnostics.ps1'
$primitiveSource = ''
foreach ($name in @('Get-ReportingSourceHash','New-ReportingSqlConnectionString','Invoke-ReportingWebRequest','Get-ReportingCatalogEvidence','Get-ReportingPortalEvidence')) {
    . (Import-ReportingTestDefinition $entryPath $name)
    $primitiveSource += "function $name { $((Get-Command $name).Definition) }`n"
}
$boundsPath = Join-Path $PSScriptRoot 'Test-ReportingProbeBounds.ps1'
$tokens = $null; $errors = $null
$boundsAst = [Management.Automation.Language.Parser]::ParseFile($boundsPath,[ref]$tokens,[ref]$errors)
$fixture = $boundsAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type'},$true)
if (-not ('MemLabs.ReportingHttpFixture' -as [type])) { . ([scriptblock]::Create($fixture.Extent.Text)) }
$password = [Security.SecureString]::new(); $password.AppendChar([char]120)
$credential = [pscredential]::new('fixture-user@fixture.invalid',$password)
$server = [MemLabs.ReportingHttpFixture]::new()
$server.StallApi = $false
$webArtifacts = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingWeb-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $webArtifacts -ItemType Directory
try {
    $uri = "http://127.0.0.1:$($server.Port)/ReportServer"
    foreach ($kind in @('ReportServerPage','Portal','Catalog')) {
        $result = Invoke-ReportingHostWorker -Operation Web -Parameters @{ Kind=$kind; Uri=$uri; SiteCode='PS1'; Credential=$credential; ArtifactDirectory=$webArtifacts; ArtifactPrefix='fixture' } `
            -PrimitiveSource $primitiveSource -TimeoutSeconds 20
        if ($kind -eq 'Catalog') {
            if (-not $result.Error -or $result.Output) { throw 'Malformed live SOAP metadata was treated as a valid empty catalog.' }
        }
        elseif ($result.Error -or $result.Output.StatusCode -ne 200) { throw "Actual $kind host worker failed: $($result.Error)" }
        if ($kind -eq 'Portal' -and (-not $result.Output.ScriptAssets[0].SavedResponse -or
            -not [IO.File]::Exists($result.Output.ScriptAssets[0].SavedResponse))) { throw 'Independent portal script response was not retained locally.' }
    }
    $server.SoapCatalog = $true
    foreach ($count in @(0,1,3)) {
        $server.ReportCount = $count
        $result = Invoke-ReportingHostWorker -Operation Web -Parameters @{ Kind='Catalog'; Uri=$uri; SiteCode='PS1'; Credential=$credential } `
            -PrimitiveSource $primitiveSource -TimeoutSeconds 20
        if ($result.Error -or -not $result.Output.ConfigMgrFolderFound -or $result.Output.ReportCount -ne $count) {
            throw "Actual SOAP worker lost the $count-report threshold or folder shape: $($result.Error)"
        }
    }
    $winrm = Invoke-ReportingHostWorker -Operation WinRM -Parameters @{
        Target='localhost'; Credential=$credential; Probe='throw "A fixture account must not authenticate."'; ProbeArguments=@()
    } -PrimitiveSource $primitiveSource -TimeoutSeconds 10
    if (-not $winrm.Error -or $winrm.Output) { throw 'Unavailable/unauthorized WinRM was treated as successful guest evidence.' }
}
finally { $server.Dispose(); Remove-Item -LiteralPath $webArtifacts -Recurse -Force -ErrorAction Stop }

& {
    $workerRoot = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingWorkerTimeout-$([guid]::NewGuid().ToString('N'))"
    $tools = Join-Path $workerRoot 'tools'; $dsc = Join-Path $workerRoot 'DSC\phases'
    $null = New-Item -Path $tools,$dsc -ItemType Directory -Force
    try {
        Copy-Item -LiteralPath (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1') -Destination (Join-Path $dsc 'ProcessFunctions.ps1')
        $fixture = "function Invoke-ReportingHostWorker { $((Get-Command Invoke-ReportingHostWorker).Definition) }`n"
        $fixture += @'
function Save-ReportingSmbEvidence {
    param($ManifestPath,$LogDirectory,[pscredential]$Credential)
    $complete = Join-Path $LogDirectory 'complete.log'
    [IO.File]::WriteAllText($complete,'durable completed file')
    $pending = Join-Path $LogDirectory 'pending.log'
    [IO.File]::WriteAllText("$pending.partial",'durable partial bytes')
    Write-MemLabsProcessProgress -Path $ManifestPath -Record @{
        Files=@(@{Source='\\fixture\C$\complete.log';Destination=$complete;CopiedBytes=22;Status='Copied'})
        PendingFile=@{Source='\\fixture\C$\pending.log';Destination=$pending;SourceBytes=1000}
        Errors=@(); Status='Running'; ChildProcessId=$PID
    }
    Start-Sleep -Seconds 30
}
'@
        $module = Join-Path $tools 'Common.ReportingDiagnostics.ps1'
        $fixture | Set-Content -LiteralPath $module -Encoding UTF8
        . $module
        $manifest = Join-Path $workerRoot 'timeout-files.json'
        $result = Invoke-ReportingHostWorker -Operation Files -Parameters @{
            ManifestPath=$manifest; LogDirectory=$workerRoot; Credential=$credential
        } -PrimitiveSource '# fixture worker' -TimeoutSeconds 10 -CheckpointPath $manifest
        if (-not $result.TimedOut -or $result.PartialOutput.Files.Count -ne 2 -or
            $result.PartialOutput.Files[1].Status -ne 'AbortedPartial' -or
            -not [IO.File]::Exists($result.PartialOutput.Files[0].Destination) -or
            -not [IO.File]::Exists($result.PartialOutput.Files[1].Destination)) {
            throw 'Actual timed-out copy worker discarded completed/partial bytes or lost its manifest.'
        }
        if (Get-Process -Id $result.ProcessId -ErrorAction Ignore) { throw 'Timed-out host worker was left running.' }
        $child = Get-Process -Id $result.PartialOutput.ChildProcessId -ErrorAction Ignore
        if ($child) {
            Stop-Process -Id $child.Id -Force -ErrorAction Stop
            throw 'The reporting copy worker left its compatibility-process descendant running after cancellation.'
        }
    }
    finally { Remove-Item -LiteralPath $workerRoot -Recurse -Force -ErrorAction Stop }
}

& {
    . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
    $filesRoot = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingShares-$([guid]::NewGuid().ToString('N'))"
    $output = Join-Path $filesRoot 'output'
    $null = New-Item -Path $output -ItemType Directory -Force
    try {
        foreach ($path in @('C\PBIRS\PBIRS\LogFiles','C\PBIRS\PBIRS\ReportServer','E\SMS_SRSRP\Logs','C\Windows\System32\winevt\Logs','C\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_powershell.exe_fixture')) {
            $null = New-Item -Path (Join-Path $filesRoot $path) -ItemType Directory -Force
        }
        'Fixture report service log' | Set-Content -LiteralPath (Join-Path $filesRoot 'C\PBIRS\PBIRS\LogFiles\ReportingServicesService_fixture.log')
        'Fixture ConfigMgr report publication log' | Set-Content -LiteralPath (Join-Path $filesRoot 'E\SMS_SRSRP\Logs\srsrp.log')
        '<Configuration><Dsn>fixture-private-dsn-not-for-export</Dsn><InstanceId>PBIRS</InstanceId><URLReservations><Application><Name>ReportServerWebService</Name><VirtualDirectory>ReportServer</VirtualDirectory></Application></URLReservations></Configuration>' |
            Set-Content -LiteralPath (Join-Path $filesRoot 'C\PBIRS\PBIRS\ReportServer\RSReportServer.config')
        [IO.File]::WriteAllBytes((Join-Path $filesRoot 'C\Windows\System32\winevt\Logs\Application.evtx'),[byte[]](1,2,3))
        'Fixture APPCRASH report' | Set-Content -LiteralPath (Join-Path $filesRoot 'C\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_powershell.exe_fixture\Report.wer')
        'Not collected' | Set-Content -LiteralPath (Join-Path $filesRoot 'C\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_powershell.exe_fixture\memory.dmp')
        function Invoke-ReportingNetworkIdentity {
            param([pscredential]$Credential,[scriptblock]$Action)
            if (-not $Credential) { throw 'Raw copy omitted explicit network credentials.' }
            & $Action
        }
        function Get-ReportingAdminSharePath {
            param($Target,$LocalPath)
            if ($Target -ne 'fixture.test') { throw 'Raw copy target changed.' }
            $driveRoot = Join-Path $filesRoot $LocalPath.Substring(0,1)
            if ($LocalPath.Length -eq 3) { return $driveRoot }
            Join-Path $driveRoot $LocalPath.Substring(3)
        }
        function Get-ReportingFileLocations {
            param($AdditionalPaths)
            [pscustomobject]@{Path='C:\PBIRS\PBIRS\LogFiles';Kind='ReportingLogs'}
            [pscustomobject]@{Path='E:\SMS_SRSRP\Logs';Kind='ReportingLogs'}
            [pscustomobject]@{Path='C:\MissingLogs';Kind='ReportingLogs'}
        }
        $manifestPath = Join-Path $output 'files.json'
        $manifest = Save-ReportingSmbEvidence -Target fixture.test -VMName FIXTURE -Credential $credential -LogDirectory $output -Prefix fixture -ManifestPath $manifestPath
        if ($manifest.Files.Count -ne 4 -or -not ($manifest.Files.Source | Where-Object { $_ -like '*Report.wer' }) -or
            ($manifest.Files.Source | Where-Object { $_ -like '*.dmp' }) -or -not ($manifest.Files.Source | Where-Object { $_ -like '*srsrp.log' }) -or
            -not ($manifest.Files.Source | Where-Object { $_ -like '*ReportingServicesService_fixture.log' })) {
            throw 'Raw-file capture lost C:/E: report/site logs or its whole event-log snapshot.'
        }
        $saved = Get-Content -LiteralPath $manifestPath -Raw
        if ($saved.Contains('fixture-private-dsn-not-for-export') -or -not $saved.Contains('PBIRS')) { throw 'Safe configuration capture exposed the raw DSN or lost non-secret configuration.' }
        foreach ($file in $manifest.Files) {
            if (-not [IO.File]::Exists($file.Destination) -or ([IO.FileInfo]$file.Destination).Length -ne $file.CopiedBytes) { throw 'Raw manifest references missing or incomplete bytes.' }
        }
    }
    finally { Remove-Item -LiteralPath $filesRoot -Recurse -Force -ErrorAction Stop }
}

& {
    . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
    $state = @{ Requests = [Collections.Generic.List[object]]::new() }
    function Get-WmiObject {
        param($ComputerName,[pscredential]$Credential,$Class,$Namespace,$Filter,$ErrorAction)
        if ($ComputerName -ne 'fixture.test' -or -not $Credential) { throw 'Native WMI lost its explicit target/credentials.' }
        $state.Requests.Add([pscustomobject]@{ Class=$Class; Namespace=$Namespace; Filter=$Filter })
        switch ($Class) {
            Win32_ComputerSystem { [pscustomobject]@{ Name='FIXTURE'; Domain='fixture.test' } }
            Win32_OperatingSystem { [pscustomobject]@{ Caption='Fixture'; Version='10.0.20348'; BuildNumber='20348' } }
            Win32_Service { [pscustomobject]@{ Name='PowerBIReportServer'; State='Running'; StartMode='Auto'; PathName='E:\PBIRS\PBIRS\RSHostingService.exe' } }
            __NAMESPACE {
                if ($Namespace -eq 'root\Microsoft\SqlServer\ReportServer') { [pscustomobject]@{ Name='RS_PBIRS' } }
                elseif ($Namespace -like '*RS_PBIRS') { [pscustomobject]@{ Name='v15' } }
            }
            MSReportServer_ConfigurationSetting { [pscustomobject]@{ InstanceName='PBIRS'; IsInitialized=$true; DatabaseServerName='SQL.fixture.test,1544'; DatabaseName='ReportServerCustom' } }
            default { throw "Unexpected WMI class $Class." }
        }
    }
    function Get-WinEvent {
        [CmdletBinding()]
        param($ComputerName,[pscredential]$Credential,$FilterHashtable,$MaxEvents)
        if ($ComputerName -ne 'fixture.test' -or -not $Credential -or $MaxEvents -ne 30) { throw 'Native event collection lost explicit credentials or its limit.' }
        [pscustomobject]@{ TimeCreated=[DateTime]::UtcNow; Id=1026; ProviderName='.NET Runtime'; Message='Fixture process exit' }
    }
    $root = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-ReportingNative-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -Path $root -ItemType Directory
    try {
        $record = Get-ReportingRpcEvidence -Target fixture.test -VMName FIXTURE -Credential $credential -CheckpointPath (Join-Path $root 'rpc.json')
        if (-not $record.IdentityVerified -or $record.Services[0].Name -ne 'PowerBIReportServer' -or
            $record.ReportServerConfiguration[0].DatabaseName -ne 'ReportServerCustom' -or $record.Events.Count -ne 3) {
            throw 'Native RPC evidence lost identity, reporting configuration, or events.'
        }
        $saved = Get-Content -LiteralPath (Join-Path $root 'rpc.json') -Raw | ConvertFrom-Json
        if ($saved.Status -ne 'Captured') { throw 'Native inventory did not retain its last checkpoint.' }
        $mismatch = Get-ReportingRpcEvidence -Target fixture.test -VMName OTHER -Credential $credential -ExpectedDomain fixture.test
        if ($mismatch.IdentityVerified -or $mismatch.Status -ne 'IdentityMismatch' -or $mismatch.Services.Count) { throw 'Wrong-machine native inventory was treated as authoritative.' }
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
}
Write-Host 'PASS -- actual bounded host web workers, explicit native WMI/event credentials, custom SQL target, and durable inventory checkpoints.'
