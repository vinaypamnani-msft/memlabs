#requires -Version 5.1
<#
.SYNOPSIS
    Verifies interrupted cache writes preserve complete data and bad caches rebuild.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Read by source-extracted cache writers inside the isolated cancellation runspace.')]
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.Config.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Common.Config.ps1 parse errors: $($errors -join '; ')" }
$definitions = @{}
foreach ($name in @('Test-VMResourceCacheMetrics', 'Save-VMListDiskCache', 'Read-VMListDiskCache', 'Get-VMSizeCached', 'Test-CacheValid', 'Get-List', 'Get-VMFromHyperV', 'Update-VMFromHyperV')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
    if (-not $definition) { throw "Missing $name." }
    $definitions[$name] = $definition.Extent.Text
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:Logs = [Collections.Generic.List[string]]::new()
function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [switch]$LogOnly, [switch]$HostOnly, [switch]$Failure)
    $script:Logs.Add($Message)
}
function Flush-LogBuffer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Mocks the shared logging API.')]
    param([switch]$All)
}
function Invoke-VMNetworkBulkWarmup {}
function Get-VMNetworkCached { param($vm) [pscustomobject]@{ SwitchName = 'cache.test' } }
function Update-VMFromHyperV {
    param($vm, $vmObject, $vmNoteObject)
    $vmObject | Add-Member -NotePropertyName Domain -NotePropertyValue 'cache.test' -Force
    $vmObject | Add-Member -NotePropertyName Role -NotePropertyValue 'DomainMember' -Force
}
function Get-VM { [CmdletBinding()]param() $script:InventoryReads++; $script:LiveVM }
function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Path)
    if ($LiteralPath -eq $script:DiskPath) {
        $script:DiskReads++
        return [pscustomobject]@{ Length = 12GB }
    }
    if ($PSBoundParameters.ContainsKey('LiteralPath')) {
        return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
    }
    Microsoft.PowerShell.Management\Get-Item -Path $Path
}

function Invoke-CancelledCacheWrite {
    param([ValidateSet('Inventory', 'Size')][string]$Kind, [string]$Directory)
    $signalPath = Join-Path $Directory 'writer-ready'
    $worker = [powershell]::Create()
    try {
        $null = $worker.AddScript({
                param($Definitions, $Kind, $Directory, $SignalPath, $VmId)
                foreach ($name in @('Test-VMResourceCacheMetrics', 'Save-VMListDiskCache', 'Get-VMSizeCached', 'Test-CacheValid')) {
                    . ([scriptblock]::Create($Definitions[$name]))
                }
                $Common = [pscustomobject]@{ CachePath = $Directory; InJob = $false }
                $global:vm_List = @([pscustomobject]@{ vmName = 'NEW'; vmId = $VmId; memoryStartupGB = 8; diskUsedGB = 24 })
                function Write-Log {
                    [CmdletBinding()]
                    param([string]$Message, [switch]$LogOnly, [switch]$HostOnly)
                }
                function Export-Clixml {
                    [CmdletBinding()]
                    param([string]$LiteralPath, [switch]$Force, [int]$Depth, [Parameter(ValueFromPipeline = $true)]$InputObject)
                    begin {
                        [IO.File]::WriteAllText($LiteralPath, '<Objs>interrupted')
                        [IO.File]::WriteAllText($SignalPath, 'ready')
                        Start-Sleep -Seconds 30
                    }
                }
                function Out-File {
                    [CmdletBinding()]
                    param([string]$LiteralPath, [switch]$Force, [Parameter(ValueFromPipeline = $true)]$InputObject)
                    begin {
                        [IO.File]::WriteAllText($LiteralPath, '{"diskSize":')
                        [IO.File]::WriteAllText($SignalPath, 'ready')
                        Start-Sleep -Seconds 30
                    }
                }
                if ($Kind -eq 'Inventory') { Save-VMListDiskCache }
                else {
                    Get-VMSizeCached -vm ([pscustomobject]@{
                            vmID = $VmId; Name = 'NEW'; MemoryStartup = 8GB; HardDrives = @()
                        }) | Out-Null
                }
            }).AddArgument($definitions).AddArgument($Kind).AddArgument($Directory).AddArgument($signalPath).AddArgument($script:VmId)
        $pending = $worker.BeginInvoke()
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not [IO.File]::Exists($signalPath) -and -not $pending.IsCompleted -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        Assert-True ([IO.File]::Exists($signalPath)) "$Kind cancellation did not reach the actual cache serializer."
        $worker.Stop()
        try { $null = $worker.EndInvoke($pending) }
        catch [Management.Automation.PipelineStoppedException] { }
    }
    finally {
        $worker.Dispose()
        if ([IO.File]::Exists($signalPath)) { [IO.File]::Delete($signalPath) }
    }
}

function Invoke-RebuildRetryCase {
    param([string]$FailureStage, [switch]$DisableSmart, [switch]$RecoverEmpty)

    $state = @{
        Fail = $true; Stage = $FailureStage; Empty = $RecoverEmpty.IsPresent
        Reads = 0; Measurements = 0
    }
    function Get-VM {
        [CmdletBinding()]
        param()
        $state.Reads++
        if ($state.Fail -and $state.Stage -eq 'Enumerate') { throw 'Synthetic rebuild enumeration failure.' }
        if (-not $state.Fail -and $state.Empty) { return }
        $script:LiveVM
    }
    function Get-VMSizeCached {
        param($vm)
        $state.Measurements++
        if ($state.Fail -and $state.Stage -eq 'Measure') { throw 'Synthetic rebuild measurement failure.' }
        [pscustomobject]@{ diskSize = 24GB; MemoryStartup = 6GB }
    }
    function Start-Sleep { param([int]$Seconds) }

    $global:vm_List = @($entry)
    Save-VMListDiskCache
    $before = [IO.File]::ReadAllText($cachePath)
    $global:vm_List = @([pscustomobject]@{
            vmName = 'CACHE-VM'; vmId = $script:VmId; memoryStartupGB = 0; diskUsedGB = 0
        })
    $global:vm_List_LastUpdate = Get-Date
    $global:vm_List_Dirty = $false
    $global:DisableSmartUpdate = $DisableSmart.IsPresent
    $label = "$FailureStage/disabled=$DisableSmart/empty=$RecoverEmpty"
    foreach ($attempt in 1..2) {
        $result = Get-List -Type VM -SmartUpdate
        Assert-True ($null -eq $result -and -not $global:vm_List -and
            $global:vm_List_Dirty -and $null -eq $global:vm_List_LastUpdate) "$label failure $attempt lost its pending full rebuild."
        Assert-True ([IO.File]::ReadAllText($cachePath) -ceq $before) "$label failure $attempt published incomplete or reseeded metrics."
    }
    $readsBefore = $state.Reads
    $measurementsBefore = $state.Measurements
    $state.Fail = $false
    $result = @(Get-List -Type VM -SmartUpdate)
    Assert-True ($state.Reads -gt $readsBefore -and -not $global:vm_List_Dirty -and
        $null -ne $global:vm_List_LastUpdate) "$label recovery did not complete a new full inventory read."
    if ($RecoverEmpty) {
        Assert-True ($result.Count -eq 0 -and $state.Measurements -eq $measurementsBefore -and
            -not [IO.File]::Exists($cachePath)) "$label resurrected a disk seed after empty-host recovery."
    }
    else {
        $persisted = @(Read-VMListDiskCache)
        Assert-True ($result.Count -eq 1 -and $result[0].memoryStartupGB -eq 6 -and $result[0].diskUsedGB -eq 24 -and
            $state.Measurements -gt $measurementsBefore) "$label recovery skipped fresh measurement."
        Assert-True ($persisted.Count -eq 1 -and $persisted[0].memoryStartupGB -eq 6 -and
            $persisted[0].diskUsedGB -eq 24) "$label recovery did not persist the measured replacement."
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-cache-integrity-' + [guid]::NewGuid().ToString('N'))
$previousCommon = $global:Common
$previousVMList = $global:vm_List
$previousUpdate = $global:vm_List_LastUpdate
$previousDirty = $global:vm_List_Dirty
$previousDisable = $global:DisableSmartUpdate
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $global:Common = [pscustomobject]@{ CachePath = $fixtureRoot; InJob = $false }
    $global:DisableSmartUpdate = $false
    $script:VmId = [guid]::NewGuid()
    $script:DiskPath = Join-Path $fixtureRoot 'disk.vhdx'
    [IO.File]::WriteAllText($script:DiskPath, 'Synthetic disk metadata is supplied by Get-Item.')
    $script:DiskReads = 0
    $script:InventoryReads = 0
    $script:LiveVM = [pscustomobject]@{
        vmID = $script:VmId; Id = $script:VmId; Name = 'CACHE-VM'; MemoryStartup = 4GB
        MemoryAssigned = 3GB; HardDrives = @([pscustomobject]@{ Path = $script:DiskPath })
    }
    $cachePath = Join-Path $fixtureRoot 'vm-list-cache.clixml'
    $sizePath = Join-Path $fixtureRoot "$script:VmId.disk.json"
    $entry = [pscustomobject]@{ vmName = 'CACHE-VM'; vmId = $script:VmId; memoryStartupGB = 4; diskUsedGB = 12; Prefix = 0 }
    $global:vm_List = @($entry)
    Save-VMListDiskCache
    $read = @(Read-VMListDiskCache)
    Assert-True ($read.Count -eq 1 -and $read[0].memoryStartupGB -eq 4 -and $read[0].diskUsedGB -eq 12) 'Healthy inventory failed to round-trip.'
    Assert-True ($read[0].Prefix -is [string] -and $read[0].Prefix -eq '') 'Legacy prefix repair regressed.'
    $global:vm_List = @($entry, [pscustomobject]@{ vmName = 'SECOND'; vmId = [guid]::NewGuid(); memoryStartupGB = 2; diskUsedGB = 5 })
    Save-VMListDiskCache
    Assert-True (@(Read-VMListDiskCache).Count -eq 2) "Inventory replacement did not publish all entries. $($script:Logs -join ' | ')"

    foreach ($kind in @('Inventory', 'Size')) {
        $caseRoot = Join-Path $fixtureRoot $kind
        $null = New-Item -ItemType Directory -Path $caseRoot
        $target = Join-Path $caseRoot 'vm-list-cache.clixml'
        if ($kind -eq 'Inventory') { @($entry) | Export-Clixml -LiteralPath $target }
        else {
            $target = Join-Path $caseRoot "$script:VmId.disk.json"
            [pscustomobject]@{ vmId = $script:VmId; diskSize = 12GB; MemoryStartup = 4GB; EntryAdded = '01/01/2000 00:00' } |
                ConvertTo-Json | Set-Content -LiteralPath $target
        }
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($target))
        Invoke-CancelledCacheWrite -Kind $kind -Directory $caseRoot
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq $before) "$kind pipeline cancellation damaged the previous cache."
        Assert-True (@(Get-ChildItem -LiteralPath $caseRoot -Filter '*.tmp' -Force).Count -eq 0) "$kind cancellation orphaned a partial temporary cache."
        [IO.File]::Delete($target)
        Invoke-CancelledCacheWrite -Kind $kind -Directory $caseRoot
        Assert-True (-not [IO.File]::Exists($target)) "$kind cancellation published a partial first cache."
    }

    $global:vm_List = @($entry)
    Save-VMListDiskCache
    $before = [IO.File]::ReadAllText($cachePath)
    $lock = [IO.File]::Open($cachePath, 'Open', 'Read', 'ReadWrite')
    try {
        $global:vm_List = @([pscustomobject]@{ vmName = 'REPLACEMENT'; vmId = $script:VmId; memoryStartupGB = 8; diskUsedGB = 24 })
        Save-VMListDiskCache
    }
    finally { $lock.Dispose() }
    Assert-True ([IO.File]::ReadAllText($cachePath) -ceq $before) 'Blocked inventory replacement truncated the live cache.'
    Assert-True (@($script:Logs | Where-Object { $_ -like '*Failed to write disk cache*' }).Count -gt 0) 'Blocked inventory publication was not logged.'

    $badSizes = @(
        '{"diskSize":'
        '{}'
        ([pscustomobject]@{ vmId = $script:VmId; diskSize = 128; MemoryStartup = 0 } | ConvertTo-Json)
        ([pscustomobject]@{ vmId = $script:VmId; diskSize = 128; MemoryStartup = 4GB; EntryAdded = 'invalid' } | ConvertTo-Json)
        ([pscustomobject]@{ vmId = $script:VmId; diskSize = 0; MemoryStartup = 4GB; EntryAdded = (Get-Date -Format 'MM/dd/yyyy HH:mm') } | ConvertTo-Json)
    )
    Assert-True ($badSizes.Count -eq 5) 'The size-cache negative fixture count changed.'
    $zeroStartup = $badSizes[2] | ConvertFrom-Json
    $badTimestamp = $badSizes[3] | ConvertFrom-Json
    Assert-True ($zeroStartup.MemoryStartup -eq 0 -and $badTimestamp.EntryAdded -eq 'invalid' -and
        $zeroStartup.vmId -eq $script:VmId -and $badTimestamp.vmId -eq $script:VmId) 'Well-formed negative size fixtures do not reach their intended branches.'
    foreach ($badSize in $badSizes) {
        [IO.File]::WriteAllText($sizePath, $badSize)
        $size = Get-VMSizeCached -vm $script:LiveVM
        Assert-True ($size.diskSize -eq 12GB -and $size.MemoryStartup -eq 4GB) 'Bad size cache was reused instead of measured again.'
        $savedSize = Get-Content -LiteralPath $sizePath -Raw | ConvertFrom-Json
        Assert-True ($savedSize.diskSize -eq 12GB -and $savedSize.MemoryStartup -eq 4GB) 'Recovered size data was not durably published.'
    }
    $readsBefore = $script:DiskReads
    $script:LiveVM.MemoryStartup = 6GB
    $size = Get-VMSizeCached -vm $script:LiveVM
    Assert-True ($size.MemoryStartup -eq 6GB -and $script:DiskReads -eq $readsBefore) 'A healthy size cache hid changed startup RAM or unnecessarily reread disks.'
    [pscustomobject]@{ vmId = $script:VmId; diskSize = 1GB; MemoryStartup = 4GB; EntryAdded = '01/01/2000 00:00' } |
        ConvertTo-Json | Set-Content -LiteralPath $sizePath
    $before = [IO.File]::ReadAllText($sizePath)
    $lock = [IO.File]::Open($sizePath, 'Open', 'Read', 'ReadWrite')
    try { $size = Get-VMSizeCached -vm $script:LiveVM }
    finally { $lock.Dispose() }
    Assert-True ($size.diskSize -eq 12GB -and [IO.File]::ReadAllText($sizePath) -ceq $before) 'Blocked size-cache replacement damaged the previous cache or hid measured totals.'
    Assert-True (@($script:Logs | Where-Object { $_ -like '*Could not save size cache*' }).Count -gt 0) 'Blocked size-cache replacement was not logged.'
    $size = Get-VMSizeCached -vm $script:LiveVM
    Assert-True ($size.diskSize -eq 12GB -and (Get-Content -LiteralPath $sizePath -Raw | ConvertFrom-Json).diskSize -eq 12GB) 'Size-cache publication did not recover after the lock was released.'

    foreach ($badInventory in @('Truncated', 'ZeroTotals', 'MissingMetrics')) {
        if ($badInventory -eq 'Truncated') { [IO.File]::WriteAllText($cachePath, '<Objs>') }
        else {
            $badEntry = [pscustomobject]@{ vmName = 'CACHE-VM'; vmId = $script:VmId }
            if ($badInventory -eq 'ZeroTotals') {
                $badEntry | Add-Member -NotePropertyName memoryStartupGB -NotePropertyValue 0
                $badEntry | Add-Member -NotePropertyName diskUsedGB -NotePropertyValue 0
            }
            @($badEntry) | Export-Clixml -LiteralPath $cachePath
        }
        Assert-True ($null -eq (Read-VMListDiskCache)) "$badInventory inventory was accepted."
        $global:vm_List = $null
        $global:vm_List_LastUpdate = $null
        $global:vm_List_Dirty = $false
        $recovered = @(Get-List -Type VM -SmartUpdate -FailOnError)
        Assert-True ($recovered.Count -eq 1 -and $recovered[0].memoryStartupGB -eq 6 -and
            $recovered[0].diskUsedGB -eq 12) "$badInventory inventory did not recover actual resource totals."
        Assert-True (@(Read-VMListDiskCache).Count -eq 1) "$badInventory recovery was not persistent."
    }
    $invalidMetrics = @(
        @{ Name = 'null'; Value = $null }
        @{ Name = 'blank'; Value = '' }
        @{ Name = 'whitespace'; Value = ' ' }
        @{ Name = 'numeric-string'; Value = '12' }
        @{ Name = 'nonnumeric'; Value = 'invalid' }
        @{ Name = 'true'; Value = $true }
        @{ Name = 'false'; Value = $false }
        @{ Name = 'NaN'; Value = [double]::NaN }
        @{ Name = 'positive-infinity'; Value = [double]::PositiveInfinity }
        @{ Name = 'negative-infinity'; Value = [double]::NegativeInfinity }
        @{ Name = 'negative'; Value = -1 }
        @{ Name = 'array'; Value = @(1) }
        @{ Name = 'object'; Value = [pscustomobject]@{ value = 12 } }
        @{ Name = 'enum'; Value = [DayOfWeek]::Tuesday }
    )
    foreach ($metric in @('memoryStartupGB', 'diskUsedGB')) {
        $cases = @($invalidMetrics)
        if ($metric -eq 'memoryStartupGB') { $cases += @{ Name = 'zero'; Value = 0 } }
        foreach ($case in $cases) {
            foreach ($mode in @('Disk', 'Resident', 'ResidentDisabled')) {
                $badEntry = [pscustomobject]@{
                    vmName = 'CACHE-VM'; vmId = $script:VmId; memoryStartupGB = 6; diskUsedGB = 12
                }
                $badEntry.$metric = $case.Value
                $entries = @($entry, $badEntry)
                $global:vm_List = @($entry)
                Save-VMListDiskCache
                if ($mode -eq 'Disk') {
                    $entries | Export-Clixml -LiteralPath $cachePath
                    Assert-True ($null -eq (Read-VMListDiskCache)) "$metric/$($case.Name) mixed disk inventory was accepted."
                    $global:vm_List = $null
                }
                else { $global:vm_List = $entries }
                $global:vm_List_LastUpdate = Get-Date
                $global:vm_List_Dirty = $false
                $global:DisableSmartUpdate = $mode -eq 'ResidentDisabled'
                $readsBefore = $script:InventoryReads
                $recovered = @(Get-List -Type VM -SmartUpdate)
                $label = "$mode/$metric/$($case.Name)"
                Assert-True ($recovered.Count -eq 1 -and $recovered[0].memoryStartupGB -eq 6 -and
                    $recovered[0].diskUsedGB -eq 12 -and $script:InventoryReads -gt $readsBefore) "$label did not rebuild measured totals."
                $persisted = @(Read-VMListDiskCache)
                Assert-True ($persisted.Count -eq 1 -and $persisted[0].memoryStartupGB -eq 6 -and
                    $persisted[0].diskUsedGB -eq 12 -and -not $global:vm_List_Dirty) "$label did not persist complete recovered inventory."
            }
        }
    }
    $global:DisableSmartUpdate = $false
    $diskless = [pscustomobject]@{ vmName = 'DISKLESS'; vmId = $script:VmId; memoryStartupGB = 6; diskUsedGB = 0 }
    $global:vm_List = @($diskless)
    Save-VMListDiskCache
    Assert-True (@(Read-VMListDiskCache).Count -eq 1) 'Legitimate numeric-zero disk usage was rejected.'
    foreach ($number in @([byte]1, [int16]2, [int]3, [long]4, [single]0.5, [double]1.5, [decimal]2.5)) {
        Assert-True (Test-VMResourceCacheMetrics -MemoryStartup $number -DiskSize $number) 'A finite numeric metric type was rejected.'
    }
    foreach ($failureStage in @('Enumerate', 'Measure')) {
        foreach ($disabled in @($false, $true)) {
            foreach ($empty in @($false, $true)) {
                Invoke-RebuildRetryCase -FailureStage $failureStage -DisableSmart:$disabled -RecoverEmpty:$empty
            }
        }
    }
    & {
        . ([scriptblock]::Create($definitions['Update-VMFromHyperV']))
        function Test-SiteSystemClientOperatingSystem { param($VirtualMachine); return $false }
        function Get-VMFromHyperV { throw 'Refreshing an existing VM must not rebuild its resource cache.' }
        function Get-VMSizeCached { throw 'Refreshing RAM must not remeasure disks.' }
        function Set-VM { throw 'Cache refresh must not modify Hyper-V or VM notes.' }
        foreach ($case in @('ExternalChange', 'Stopped', 'DiskSeed', 'DirtyWhileEditing', 'Throttled', 'Editing', 'WorkerEditing')) {
            $global:Common.InJob = $case -eq 'WorkerEditing'
            $global:DisableSmartUpdate = $case -in @('DirtyWhileEditing', 'Editing', 'WorkerEditing')
            $global:vm_List_Dirty = $case -in @('DirtyWhileEditing', 'WorkerEditing')
            $global:vm_List_LastUpdate = if ($case -in @('Throttled', 'DirtyWhileEditing', 'WorkerEditing')) { Get-Date } else { (Get-Date).AddSeconds(-10) }
            $script:LiveVM | Add-Member -NotePropertyName State -NotePropertyValue $(if ($case -eq 'Stopped') { 'Off' } else { 'Running' }) -Force
            $script:LiveVM.MemoryStartup = if ($case -eq 'Stopped') { 2GB } else { 8GB }
            $script:LiveVM.MemoryAssigned = if ($case -eq 'Stopped') { 0 } else { 6GB + 2MB }
            $script:LiveVM | Add-Member -NotePropertyName Notes -NotePropertyValue (
                [pscustomobject]@{
                    role = 'DomainMember'; domain = 'cache.test'; memory = '4GB'; dynamicMinRam = '4GB'
                    memoryStartupGB = 4.001953125; memoryGB = 4
                } | ConvertTo-Json -Compress) -Force
            $global:vm_List = @([pscustomobject]@{
                    vmName = 'CACHE-VM'; vmId = $script:VmId; domain = 'cache.test'; role = 'DomainMember'
                    memoryStartupGB = 4.001953125; memoryGB = 4; diskUsedGB = 12
                })
            if ($case -eq 'DiskSeed') {
                Save-VMListDiskCache
                $global:vm_List = $null
                $global:vm_List_LastUpdate = $null
            }
            $notesBefore = $script:LiveVM.Notes
            $readsBefore = $script:InventoryReads
            $disksBefore = $script:DiskReads
            $result = @(Get-List -Type VM -DomainName 'cache.test' -SmartUpdate -ErrorAction Stop)
            $refreshExpected = $case -notin @('Throttled', 'Editing', 'WorkerEditing')
            $expectedStartup = if ($refreshExpected) { $script:LiveVM.MemoryStartup / 1GB } else { 4.001953125 }
            $expectedAssigned = if ($refreshExpected) { $script:LiveVM.MemoryAssigned / 1GB } else { 4 }
            Assert-True ($result.Count -eq 1 -and $result[0].memoryStartupGB -eq $expectedStartup -and
                $result[0].memoryGB -eq $expectedAssigned) "$case kept stale RAM, lost precision, or bypassed an ordinary editing/throttle guard."
            $expectedReads = if ($case -eq 'DiskSeed') { 2 } elseif ($refreshExpected) { 1 } else { 0 }
            Assert-True ($script:InventoryReads - $readsBefore -eq $expectedReads -and
                $script:DiskReads -eq $disksBefore) "$case introduced extra inventory or disk reads for RAM."
            Assert-True ($script:LiveVM.Notes -ceq $notesBefore) "$case rewrote desired VM-note settings while refreshing observed RAM."
            if ($refreshExpected) {
                $persisted = @(Read-VMListDiskCache)
                Assert-True ($persisted.Count -eq 1 -and $persisted[0].memoryStartupGB -eq $expectedStartup -and
                    $persisted[0].memoryGB -eq $expectedAssigned -and -not $global:vm_List_Dirty) "$case did not persist the live RAM refresh and clear the dirty flag."
            }
        }
        $global:Common.InJob = $false
        $global:DisableSmartUpdate = $false
    }
    $global:DisableSmartUpdate = $false
    $global:vm_List = @($entry)
    Save-VMListDiskCache
    $before = [IO.File]::ReadAllText($cachePath)
    $global:Common.InJob = $true
    $global:vm_List = @([pscustomobject]@{ vmName = 'JOB'; memoryStartupGB = 0; diskUsedGB = 0 })
    Save-VMListDiskCache
    Assert-True ([IO.File]::ReadAllText($cachePath) -ceq $before) 'A background worker overwrote host resource totals.'
    Assert-True (@(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force |
            Where-Object { $_.Name -match '\.(tmp|bak)$' }).Count -eq 0) 'Cache operations left temporary or backup files.'
}
finally {
    $global:Common = $previousCommon
    $global:vm_List = $previousVMList
    $global:vm_List_LastUpdate = $previousUpdate
    $global:vm_List_Dirty = $previousDirty
    $global:DisableSmartUpdate = $previousDisable
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions cache integrity assertions, including real pipeline cancellation."
