[CmdletBinding()]
param ([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.Maintenance.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw "Maintenance source has $(@($parseErrors).Count) parse errors." }
foreach ($name in @('Get-VMMaintenanceNote', 'Write-VMMaintenanceNoteSnapshot', 'Write-VMMaintenanceHostDiagnostics', 'Write-VMMaintenanceIdentityDiagnostics', 'Start-VMMaintenance')) {
    $node = $ast.Find({
        param ($item)
        $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name
    }, $true)
    if (-not $node) { throw "$name was not found." }
    . ([scriptblock]::Create($node.Extent.Text))
}

function Assert {
    param ([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}

function New-VMFixture {
    param ([string] $Notes = '{"lastUpdate":"today","role":"DomainMember","domain":"fixture.test","domainAdmin":"legacy-admin","password":"SECRET_NOT_FOR_LOGS"}')
    [pscustomobject]@{ Name = 'fixture-vm'; Id = 'fixture-id'; State = 'Running'; ComputerName = 'fixture-host'; Notes = $Notes }
}

function Reset-Fixture {
    $script:ReadCount = 0
    $script:ReadResults = @()
    $script:Logs = [Collections.Generic.List[string]]::new()
    $script:Delays = [Collections.Generic.List[int]]::new()
    $script:SnapshotCount = 0
    $script:RemovedJobs = 0
    $script:StoppedJobs = 0
    $script:SnapshotTimeout = $false
    $script:InventoryFails = $false
    $script:ServiceFails = $false
    $script:EventsFail = $false
    $script:SnapshotStartFails = $false
    $script:FixCalls = 0
    $script:FixNote = $null
    $script:SelectionNote = $null
    $script:Common = [pscustomobject]@{ InJob = $true }
}

function Write-Log {
    param ([string] $Message, [switch] $Warning, [switch] $LogOnly, [switch] $Success, [switch] $Verbose)
    $script:Logs.Add($Message)
}
function Start-Sleep { param ([int] $Seconds) $script:Delays.Add($Seconds) }
function Get-VM {
    [CmdletBinding()]
    param ([string] $Name)
    if (-not $Name) {
        if ($script:InventoryFails) { throw 'inventory provider unavailable' }
        return New-VMFixture
    }
    $index = [Math]::Min($script:ReadCount, $script:ReadResults.Count - 1)
    $script:ReadCount++
    $result = $script:ReadResults[$index]
    if ($result -is [string]) { throw $result }
    return $result
}
function Get-Service {
    [CmdletBinding()]
    param ([string] $Name)
    if ($script:ServiceFails) { throw 'VMMS status unavailable' }
    [pscustomobject]@{ Status = 'Running' }
}
function Get-WinEvent {
    [CmdletBinding()]
    param ([hashtable] $FilterHashtable, [int] $MaxEvents)
    Assert ($MaxEvents -eq 20 -and $FilterHashtable.StartTime -gt (Get-Date).AddMinutes(-16)) 'event query is limited to 20 recent records'
    if ($script:EventsFail) { throw 'event channel inaccessible' }
    [pscustomobject]@{
        TimeCreated = Get-Date
        Id = 123
        RecordId = 456
        ProviderName = 'fixture-provider'
        LevelDisplayName = 'Error'
        Message = 'SECRET_NOT_FOR_LOGS'
    }
}
function Start-Job {
    [CmdletBinding()]
    param ([scriptblock] $ScriptBlock)
    $script:SnapshotCount++
    if ($script:SnapshotStartFails) { throw 'worker creation failed' }
    [pscustomobject]@{ State = 'Completed'; Output = @(& $ScriptBlock) }
}
function Wait-Job {
    [CmdletBinding()]
    param ([object] $Job, [int] $Timeout)
    Assert ($Timeout -eq 20) 'host evidence worker has a 20-second wait limit'
    if ($script:SnapshotTimeout) { $Job.State = 'Running'; return $null }
    return $Job
}
function Receive-Job {
    [CmdletBinding()]
    param ([object] $Job)
    $Job.Output
}
function Stop-Job {
    [CmdletBinding()]
    param ([object] $Job)
    $script:StoppedJobs++
    $Job.State = 'Stopped'
}
function Remove-Job {
    [CmdletBinding()]
    param ([object] $Job, [switch] $Force)
    $script:RemovedJobs++
}
function Write-Progress2 { param ([switch] $Log, [int] $PercentComplete, [string] $Activity, [string] $Status, [switch] $Force) }
function Get-VMFixes {
    param ([bool] $NewVM, [string] $VMName, [object] $VMNote)
    $script:SelectionNote = $VMNote
    [pscustomobject]@{ AppliesToExisting = $true; NeededOnFreshDeploy = $true }
}
function Start-VMFixes {
    param ([string] $VMName, [object] $VMFixes, [object] $VMNote, [switch] $FreshDeployOnly)
    $script:FixCalls++
    $script:FixNote = $VMNote
    return $true
}
function Get-VM2 { param ([string] $Name, [string] $ErrorAction) [pscustomobject]@{ State = 'Off' } }
function Get-CimSession { }
function Get-PSSession { }

Reset-Fixture
$script:ReadResults = @(New-VMFixture)
$result = Start-VMMaintenance -VMName 'fixture-vm'
Assert ($result -eq $true -and $script:ReadCount -eq 1 -and $script:Delays.Count -eq 0) 'healthy maintenance needs one metadata lookup and no delay'
Assert ($script:FixCalls -eq 1 -and $script:FixNote.adminName -eq 'legacy-admin') 'legacy admin property remains supported'
Assert ([object]::ReferenceEquals($script:FixNote, $script:SelectionNote)) 'fix selection and execution reuse the validated metadata'
Assert ($script:SnapshotCount -eq 0) 'healthy maintenance collects no failure snapshot'
$text = $script:Logs -join "`n"
Assert ($text.Contains('VM Notes snapshot') -and $text.Contains('"role":"DomainMember"') -and $text.Contains('"domain":"fixture.test"')) 'useful allowlisted Notes values are captured'
Assert ($text -match 'notesSha256=[a-f0-9]{64}') 'Notes fingerprint is recorded for comparison across attempts'
Assert (-not $text.Contains('SECRET_NOT_FOR_LOGS') -and -not $text.Contains('"password"') -and -not $text.Contains('legacy-admin')) 'credential fields are excluded from the Notes snapshot'

Reset-Fixture
$script:ReadResults = @('original provider failure', (New-VMFixture))
$result = Start-VMMaintenance -VMName 'fixture-vm'
$text = $script:Logs -join "`n"
Assert ($result -eq $true -and $script:ReadCount -eq 2 -and $script:FixCalls -eq 1) 'transient lookup failure recovers and applies fixes only once'
Assert (($script:Delays -join ',') -eq '2') 'first retry waits two seconds'
Assert ($text.Contains('original provider failure') -and $text.Contains('errorId=') -and $text.Contains('hresult=') -and $text.Contains('recovered=True')) 'original lookup error and successful recovery are logged'
Assert ($text.Contains('"identity":') -and $text.Contains('"vmms":"Running"') -and $script:SnapshotCount -eq 0) 'recovered failures retain host context without launching an evidence worker'

Reset-Fixture
$script:ReadResults = @('first failure', 'second failure', (New-VMFixture))
$result = Get-VMMaintenanceNote -VMName 'fixture-vm'
Assert ($null -ne $result -and ($script:Delays -join ',') -eq '2,4') 'third attempt recovers after bounded two/four-second backoff'

foreach ($case in @(
    @{ Name = 'missing VM'; Result = $null; Expected = 'lookupMatchCount=0' }
    @{ Name = 'lookup exception'; Result = 'Hyper-V provider unavailable'; Expected = 'stage=lookup' }
    @{ Name = 'empty notes'; Result = (New-VMFixture -Notes ''); Expected = 'notes=empty' }
    @{ Name = 'unmanaged notes'; Result = (New-VMFixture -Notes 'SECRET_NOT_FOR_LOGS'); Expected = 'managedNoteMarker=missing' }
    @{ Name = 'malformed JSON'; Result = (New-VMFixture -Notes '{"lastUpdate": SECRET_NOT_FOR_LOGS}'); Expected = 'stage=parse' }
    @{ Name = 'JSON array'; Result = (New-VMFixture -Notes '[{"lastUpdate":"today"},{"lastUpdate":"yesterday"}]'); Expected = 'managedNoteSchema=invalid' }
    @{ Name = 'single-element JSON array'; Result = (New-VMFixture -Notes '[{"lastUpdate":"today"}]'); Expected = 'managedNoteSchema=invalid' }
    @{ Name = 'false marker'; Result = (New-VMFixture -Notes '{"unrelated":"lastUpdate"}'); Expected = 'managedNoteSchema=invalid' }
    @{ Name = 'missing lastUpdate property'; Result = (New-VMFixture -Notes '{"role":"DomainMember","domain":"fixture.test","password":"SECRET_NOT_FOR_LOGS"}'); Expected = 'managedNoteSchema=invalid' }
)) {
    Reset-Fixture
    $script:ReadResults = @( $case.Result )
    $result = Start-VMMaintenance -VMName 'fixture-vm'
    $text = $script:Logs -join "`n"
    Assert ($result -eq $false -and $script:ReadCount -eq 3 -and $script:FixCalls -eq 0) "$($case.Name): retries exhausted without applying fixes"
    Assert ($text.Contains($case.Expected) -and $text.Contains('attempt=1/3') -and $text.Contains('attempt=3/3')) "$($case.Name): all failed attempts retain their classifications"
    Assert ($script:SnapshotCount -eq 1 -and $script:RemovedJobs -eq 1) "$($case.Name): failure evidence collected and worker removed"
    Assert ($text.Contains('Maintenance host context:') -and $text.Contains('"kind":"inventory"') -and $text.Contains('"kind":"vmms"') -and $text.Contains('"kind":"events"')) "$($case.Name): execution context, inventory, VMMS, and events are logged"
    Assert (-not $text.Contains('SECRET_NOT_FOR_LOGS')) "$($case.Name): no Notes or event payloads leak into logs"
    if ($case.Name -eq 'missing lastUpdate property') {
        Assert ($text.Contains('"role":"DomainMember"')) 'parsed diagnostic Notes are retained even when the managed marker is missing'
    }
}

Reset-Fixture
$script:ReadResults = @(New-VMFixture -Notes '{"lastUpdate":"today","role":"DomainMember"}')
Assert ((Start-VMMaintenance -VMName 'fixture-vm') -eq $false -and $script:FixCalls -eq 0) 'missing maintenance domain fails instead of reporting success'
Assert (($script:Logs -join "`n").Contains('missing or invalid required fields: domain')) 'missing field names are logged without values'
Reset-Fixture
$script:ReadResults = @(New-VMFixture -Notes '{"lastUpdate":"today","role":"DomainMember","domain":{"unexpected":"SECRET_NOT_FOR_LOGS"}}')
Assert ((Start-VMMaintenance -VMName 'fixture-vm') -eq $false -and $script:FixCalls -eq 0) 'non-string maintenance domain cannot reach fixes'
Assert (-not ($script:Logs -join "`n").Contains('SECRET_NOT_FOR_LOGS')) 'invalid field values are not logged'
Reset-Fixture
$script:ReadResults = @(New-VMFixture -Notes ('{"lastUpdate":"today","role":"DomainMember","domain":"' + ('a' * 300) + '"}'))
$null = Get-VMMaintenanceNote -VMName 'fixture-vm'
Assert (-not ($script:Logs -join "`n").Contains('a' * 257)) 'allowlisted string values are bounded to 256 characters'

Reset-Fixture
$script:ReadResults = @(New-VMFixture -Notes '{"lastUpdate":"today","role":"Proxy"}')
Assert ((Start-VMMaintenance -VMName 'fixture-vm') -eq $true -and $script:FixCalls -eq 0) 'Linux skip behavior is preserved'
Reset-Fixture
$script:ReadResults = @(New-VMFixture -Notes '{"lastUpdate":"today","role":"StandaloneRootCA"}')
Assert ((Start-VMMaintenance -VMName 'fixture-vm') -eq $true -and $script:FixCalls -eq 0) 'offline root CA skip behavior is preserved'

Reset-Fixture
$script:SnapshotTimeout = $true
Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm'
Assert ($script:StoppedJobs -eq 1 -and $script:RemovedJobs -eq 1) 'timed-out evidence worker is stopped and removed'
Assert (($script:Logs -join "`n").Contains('timed out after 20 seconds')) 'partial evidence is explicitly labeled'

Reset-Fixture
$script:InventoryFails = $true
$script:ServiceFails = $true
$script:EventsFail = $true
Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm'
$text = $script:Logs -join "`n"
Assert ($text.Contains('inventory provider unavailable') -and $text.Contains('VMMS status unavailable') -and $text.Contains('event channel inaccessible')) 'individual evidence failures are retained'
Reset-Fixture
$script:SnapshotStartFails = $true
Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm'
Assert (($script:Logs -join "`n").Contains('worker creation failed')) 'evidence worker launch failure is explicit'

Assert ($ast.Extent.Text.Contains('if (-not $vmNote) { $vmNote = Get-VMNote -VMName $vmName }')) 'existing fix callers retain fallback metadata reads'

Reset-Fixture
Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm'
$text = $script:Logs -join "`n"
Assert ($text.Contains('"notes_domain":"fixture.test"') -and $text.Contains('notesSha256')) 'inventory contains safe Notes identity and fingerprint even when target lookup fails'
Assert (-not $text.Contains('SECRET_NOT_FOR_LOGS') -and -not $text.Contains('legacy-admin')) 'inventory never exports credential-bearing Notes'

$identityId = [guid]::NewGuid()
$global:vm_List = @([pscustomobject]@{ vmName = 'CT5-DC1'; vmId = $identityId; domain = 'fixture.test'; role = 'DC'; state = 'Running' })
$script:IdentityQueries = [Collections.Generic.List[string]]::new()
function Get-VM {
    [CmdletBinding()]
    param ([string] $Name, [guid] $Id)
    if ($Name) {
        $script:IdentityQueries.Add("name:$Name")
        throw 'registered name differs'
    }
    $script:IdentityQueries.Add("id:$Id")
    if ($Id -ne $identityId) { throw 'stale identity' }
    [pscustomobject]@{
        Name = 'DC1'; Id = $identityId; ComputerName = 'fixture-host'; State = 'Running'
        Notes = '{"vmName":"CT5-DC1","role":"DC","domain":"fixture.test","lastUpdate":"today","password":"SECRET_NOT_FOR_LOGS"}'
    }
}
Reset-Fixture
$target = [pscustomobject]@{ vmName = 'CT5-DC1' }
$parent = Write-VMMaintenanceIdentityDiagnostics -Target $target -Stage parent
$text = $script:Logs -join "`n"
Assert ($parent.resolvedIdentities.Count -eq 1 -and $parent.resolvedIdentities[0].Name -eq 'DC1') 'parent captures the registered identity despite failed name lookup'
Assert ($text.Contains('registered name differs') -and $text.Contains('"vmName":"CT5-DC1"') -and $text.Contains("registeredName='DC1'")) 'name, GUID and Notes divergence are all visible'
Assert (-not $text.Contains('SECRET_NOT_FOR_LOGS')) 'identity diagnostics exclude credentials'
Assert ($script:FixCalls -eq 0 -and $target.vmName -eq 'CT5-DC1' -and $global:vm_List[0].vmName -eq 'CT5-DC1') 'diagnostics do not rename targets, mutate cache or apply fixes'
$savedDefaults = $PSDefaultParameterValues
try {
    $PSDefaultParameterValues = @{
        'Get-VM:ComputerName' = @('fixture-host', 'second-host')
        'Get-VM:CimSession' = { throw 'Default must not be evaluated' }
    }
    Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm' -ContextOnly
    $text = $script:Logs -join "`n"
    Assert ($text.Contains('"vmCacheCount":1') -and $text.Contains('"vmCache":') -and $text.Contains([string]$identityId)) 'context preserves safe cache name/GUID mapping'
    Assert ($text.Contains('second-host') -and $text.Contains('unsupported value (not evaluated or logged)') -and -not $text.Contains('Default must not be evaluated')) 'endpoint arrays are recorded without evaluating dynamic defaults'
}
finally { $PSDefaultParameterValues = $savedDefaults }
$global:vm_List = $null
$script:IdentityQueries.Clear()
$worker = Write-VMMaintenanceIdentityDiagnostics -Target $target -Stage worker -ParentIdentity $parent
Assert ($worker.resolvedIdentities.Count -eq 1 -and $script:IdentityQueries.Contains("id:$identityId")) 'worker probes the parent GUID even without a worker cache'
Assert (($script:Logs -join "`n").Contains('"parentIdentity":')) 'worker records the parent comparison'
Reset-Fixture
$staleTarget = [pscustomobject]@{ vmName = 'CT5-DC1'; vmId = [guid]::NewGuid() }
$stale = Write-VMMaintenanceIdentityDiagnostics -Target $staleTarget -Stage parent
Assert ($stale.resolvedIdentities.Count -eq 0 -and ($script:Logs -join "`n").Contains('stale identity')) 'stale GUID lookup failure is explicit without fallback success'

function Get-VM {
    [CmdletBinding()]
    param ([string] $Name, [guid] $Id)
    New-VMFixture -Notes '{"vmName": SECRET_NOT_FOR_LOGS}'
}
Reset-Fixture
$null = Write-VMMaintenanceIdentityDiagnostics -Target $target -Stage parent
Assert (($script:Logs -join "`n").Contains('Notes parse failed') -and -not ($script:Logs -join "`n").Contains('SECRET_NOT_FOR_LOGS')) 'identity parse errors retain metadata without echoing raw Notes'

$scriptBlocksPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'
foreach ($path in @($scriptBlocksPath, $phasePath)) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert (@($errors).Count -eq 0) "$path parses"
}
$workerSource = Get-Content -LiteralPath $scriptBlocksPath -Raw
$phaseSource = Get-Content -LiteralPath $phasePath -Raw
Assert ($workerSource.Contains('-Target $currentItem -Stage worker -ParentIdentity $MaintenanceIdentity')) 'Phase10 worker receives and logs parent identity'
Assert (@([regex]::Matches($phaseSource, 'Phase10Job.*-ArgumentList.*\$PSScriptRoot, \$maintenanceIdentity')).Count -eq 2) 'both process and thread job dispatch pass parent identity'
Assert ($ast.Extent.Text.Contains('-argument3 $false -PreferThreadJob -MaintenanceDiagnostics')) 'launcher maintenance supplies the Boolean worker placeholder and enables parent identity capture'
Assert (@([regex]::Matches($phaseSource, '-ScriptBlock \$scriptBlock.*-ArgumentList.*\$PSScriptRoot, \$maintenanceIdentity')).Count -eq 2) 'launcher maintenance passes identity in both job modes'

foreach ($name in @('Wait-Job', 'Receive-Job', 'Stop-Job', 'Remove-Job')) {
    Remove-Item -LiteralPath "Function:\$name"
}
function Start-Job {
    [CmdletBinding()]
    param ([scriptblock] $ScriptBlock)
    Microsoft.PowerShell.Core\Start-Job -ScriptBlock {
        [pscustomobject]@{
            kind = 'worker-smoke-test'
            nested = [pscustomobject]@{ vmId = 'fixture-id'; state = 'Running' }
        }
    } -ErrorAction Stop
}
Reset-Fixture
$existingJobIds = @(Get-Job | Select-Object -ExpandProperty Id)
Write-VMMaintenanceHostDiagnostics -VMName 'fixture-vm'
$text = $script:Logs -join "`n"
Assert ($text.Contains('"kind":"worker-smoke-test"') -and $text.Contains('"vmId":"fixture-id"')) 'real job output survives serialization into the log'
Assert (-not $text.Contains('capture failed') -and -not $text.Contains('timed out')) 'real evidence-worker receive and cleanup succeed'
Assert (@(Get-Job | Where-Object { $_.Id -notin $existingJobIds }).Count -eq 0) 'real evidence worker leaves no job behind'

$identitySource = $ast.Find({ param ($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-VMMaintenanceIdentityDiagnostics' }, $true).Extent.Text
$snapshotSource = $ast.Find({ param ($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-VMMaintenanceNoteSnapshot' }, $true).Extent.Text
$transportProbe = {
    param ($Target, $Parent, $IdentitySource, $SnapshotSource)
    . ([scriptblock]::Create($IdentitySource))
    . ([scriptblock]::Create($SnapshotSource))
    $script:WorkerLogs = [Collections.Generic.List[string]]::new()
    function Write-Log {
        param ([string] $Message, [switch] $Warning, [switch] $LogOnly)
        $script:WorkerLogs.Add($Message)
    }
    function Get-VM {
        [CmdletBinding()]
        param ([string] $Name, [guid] $Id)
        if ($Name) { throw 'registered name differs in worker' }
        [pscustomobject]@{
            Name = $Parent.resolvedIdentities[0].Name
            Id = $Id
            ComputerName = 'fixture-host'
            State = 'Running'
            Notes = '{"vmName":"CT5-DC1","domain":"fixture.test","role":"DC","password":"SECRET_NOT_FOR_LOGS"}'
        }
    }
    $global:vm_List = $null
    $result = Write-VMMaintenanceIdentityDiagnostics -Target $Target -Stage worker -ParentIdentity $Parent
    [pscustomobject]@{
        requestedName = $Target.vmName
        parentName = $result.resolvedIdentities[0].Name
        parentId = [string]$result.resolvedIdentities[0].Id
        log = $script:WorkerLogs -join "`n"
    }
}
foreach ($mode in @('process', 'thread')) {
    if ($mode -eq 'thread' -and -not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Write-Host 'ThreadJob unavailable in this shell; transport covered in PowerShell 7.'
        continue
    }
    $job = $null
    try {
        if ($mode -eq 'process') { $job = Microsoft.PowerShell.Core\Start-Job -ScriptBlock $transportProbe -ArgumentList $target, $parent, $identitySource, $snapshotSource }
        else { $job = Start-ThreadJob -ScriptBlock $transportProbe -ArgumentList $target, $parent, $identitySource, $snapshotSource }
        $completed = Wait-Job -Job $job -Timeout 20
        Assert ($null -ne $completed -and $job.State -eq 'Completed') "$mode identity transport completes"
        $output = @(Receive-Job -Job $job -ErrorAction Stop)
        Assert ($output.Count -eq 1 -and $output[0].requestedName -eq 'CT5-DC1' -and $output[0].parentName -eq 'DC1' -and $output[0].parentId -eq [string]$identityId) "$mode job preserves requested name and parent live GUID/name"
        Assert ($output[0].log.Contains('registered name differs in worker') -and $output[0].log.Contains("registeredName='DC1'") -and -not $output[0].log.Contains('SECRET_NOT_FOR_LOGS')) "$mode worker captures GUID/name disagreement without credential leakage"
    }
    finally {
        if ($job) {
            if ($job.State -eq 'Running') { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
    }
}
Write-Host 'ALL VM MAINTENANCE METADATA TESTS PASSED'
