#requires -Version 5.1
<#
.SYNOPSIS
    Verifies unreadable VM inventory cannot remove remote connection data.
#>
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

foreach ($entry in @(
        @{ Path = 'common\Common.Config.ps1'; Names = @('Get-List') },
        @{ Path = 'common\Common.RdcMan.ps1'; Names = @('Remove-MissingServersFromGroup', 'Remove-MissingDomainsFromFile') },
        @{ Path = 'common\Common.mRemoteNG.ps1'; Names = @('Remove-MissingConnectionsFromMRemoteNG', 'Remove-MissingDomainsFromMRemoteNG', 'New-MRemoteNGFileFromHyperV', 'New-MRemoteNGXmlDocument', 'Set-MRemoteNGNodeOrder') }
    )) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RootPath $entry.Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in $($entry.Path): $($errors -join '; ')" }
    foreach ($name in $entry.Names) {
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        if (-not $definition) { throw "Missing $name in $($entry.Path)." }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

function Invoke-InventoryFixture {
    param(
        [ValidateSet('Throw', 'WriteError', 'Empty', 'Success', 'Recover')][string]$Read = 'Throw',
        [switch]$Cached,
        [switch]$DiskSeed,
        [switch]$InJob,
        [string]$CaseRoot,
        [scriptblock]$Action
    )

    $state = @{
        Calls = 0; Saves = 0; ProcessReads = 0; Successes = 0
        Stops = 0; Encryptions = 0; Installs = 0; ExternalApps = 0
        Read = $Read; DiskSeed = $DiskSeed.IsPresent
        Logs = [System.Collections.Generic.List[object]]::new()
        Seed = [pscustomobject]@{
            vmName = 'KEEP-DC'; vmID = [guid]'e4c4d7aa-383a-4e9c-91d3-7a449e2d5cd3'
            Domain = 'keep.test'; Role = 'DC'; source = 'hyperv'
        }
    }
    $global:Common = [pscustomobject]@{
        InJob = $InJob.IsPresent; CachePath = $CaseRoot; LogPath = (Join-Path $CaseRoot 'fixture.log')
    }
    $global:DisableSmartUpdate = $false
    $global:vm_List = $null
    $global:vm_List_LastUpdate = $null
    $global:vm_List_Dirty = $false
    if ($Cached) {
        $global:vm_List = @($state.Seed)
        $global:vm_List_LastUpdate = Get-Date
    }

    function Read-VMListDiskCache { if ($state.DiskSeed) { @($state.Seed) } }
    function Save-VMListDiskCache { $state.Saves++ }
    function Invoke-VMNetworkBulkWarmup {}
    function Flush-LogBuffer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Mocks the existing shared logging API.')]
        [CmdletBinding()]
        param([switch]$All)
    }
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
    function Write-Log {
        [CmdletBinding()]
        param([string]$Text, [switch]$Failure, [switch]$LogOnly, [switch]$Activity, [switch]$Warning, [switch]$Success)
        $state.Logs.Add([pscustomobject]@{ Text = $Text; Failure = $Failure.IsPresent })
    }
    function Get-VM {
        [CmdletBinding()]
        param()
        $state.Calls++
        if ($state.Read -eq 'Throw' -or ($state.Read -eq 'Recover' -and $state.Calls -eq 1)) {
            throw [IO.IOException]::new('Synthetic inventory read failure.')
        }
        if ($state.Read -eq 'WriteError') {
            Write-Error 'Synthetic non-terminating inventory failure.'
            return
        }
        if ($state.Read -eq 'Empty') { return }
        [pscustomobject]@{ Name = $state.Seed.vmName; Id = $state.Seed.vmID; vmID = $state.Seed.vmID }
    }
    function Get-VMFromHyperV { param($vm) $state.Seed }
    function Update-VMFromHyperV { param($vm, $vmObject) }
    function Get-MRemoteNGPassword { $state.Encryptions++; 'encrypted-fixture-value' }
    function Get-RDCSettings {
        [pscustomobject]@{
            DefaultGrouping = $true; AllVMsGroup = $false; RoleGroups = $false
            OSGroups = $false; SubnetGroups = $false; SiteCodeGroups = $false
        }
    }
    function Get-MRNGFileFingerprint { param([string]$Path) $null }
    function Format-MRNGFingerprint { param($Fingerprint) 'fixture' }
    function Write-MRNGDiag { param([string]$Text) }
    function Repair-MRemoteNGPasswords {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The existing parameter carries ciphertext, not a credential.')]
        [CmdletBinding()]
        param([xml]$Doc, [string]$FreshEncryptedPassword)
        $false
    }
    function Install-MRemoteNG { $state.Installs++ }
    function Set-MRemoteNGExternalApps { $state.ExternalApps++ }
    function Write-GreenCheck { param([string]$Text, $ForegroundColor) $state.Successes++ }
    function Write-RedX { param([string]$Text) throw $Text }
    function Get-Process { [CmdletBinding()]param([string]$Name) $state.ProcessReads++ }
    function Stop-Process { [CmdletBinding()]param([int]$Id, [switch]$Force) $state.Stops++; throw 'Unexpected process stop.' }
    function Test-Path {
        [CmdletBinding()]
        param([string]$Path, [string]$LiteralPath)
        $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
        $desktopCopy = Join-Path ([Environment]::GetFolderPath('Desktop')) 'memlabs-mremoteng.xml'
        if ($target -eq $desktopCopy) { return $false }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $target -ErrorAction Stop
    }

    # A caller's Continue preference must not turn native cmdlet errors into empty inventory.
    $ErrorActionPreference = 'Continue'
    & $Action $state
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-connection-inventory-' + [guid]::NewGuid().ToString('N'))
$previousCommon = $global:Common
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot -ErrorAction Stop
    foreach ($read in @('Throw', 'WriteError')) {
        Invoke-InventoryFixture -Read $read -CaseRoot $fixtureRoot -Action {
            param($state)
            foreach ($kind in @('RdcDomains', 'RdcServers', 'MrngDomains', 'MrngServers')) {
                [xml]$rdg = '<RDCMan><file><group><properties><name>keep.test</name></properties><server><properties><name>KEEP-DC</name><displayName>KEEP-DC</displayName></properties></server></group></file></RDCMan>'
                [xml]$mrng = '<Connections><Node Name="keep.test" Type="Container"><Node Name="KEEP-DC" Hostname="KEEP-DC" Type="Connection" /><Node Name="nested" Type="Container"><Node Name="KEEP-DC" Hostname="KEEP-DC" Type="Connection" /></Node></Node></Connections>'
                $rdgBefore = $rdg.OuterXml; $mrngBefore = $mrng.OuterXml
                $caught = $null
                try {
                    switch ($kind) {
                        'RdcDomains' { $null = Remove-MissingDomainsFromFile -file $rdg.RDCMan.file }
                        'RdcServers' { $null = Remove-MissingServersFromGroup -findgroup $rdg.RDCMan.file.group }
                        'MrngDomains' { $null = Remove-MissingDomainsFromMRemoteNG -Doc $mrng }
                        'MrngServers' { $null = Remove-MissingConnectionsFromMRemoteNG -Container $mrng.Connections.Node }
                    }
                }
                catch { $caught = $_ }
                Assert-True ($null -ne $caught) "$($state.Read)/$kind hid an unreadable inventory."
                Assert-True ($rdg.OuterXml -ceq $rdgBefore -and $mrng.OuterXml -ceq $mrngBefore) "$($state.Read)/$kind changed existing connection data."
            }
            Assert-True (@($state.Logs | Where-Object Failure).Count -gt 0) 'Inventory failures were not logged.'
        }
    }
    foreach ($cache in @('Memory', 'Disk', 'JobDisk')) {
        Invoke-InventoryFixture -Cached:($cache -eq 'Memory') -DiskSeed:($cache -ne 'Memory') `
            -InJob:($cache -eq 'JobDisk') -CaseRoot $fixtureRoot -Action {
                param($state)
                $caught = $null
                try { $null = Get-List -Type VM -SmartUpdate -FailOnError }
                catch { $caught = $_ }
                Assert-True ($null -ne $caught -and $state.Calls -gt 0) 'Strict inventory trusted an unreadable cache or skipped a live read.'
                Assert-True ($state.Saves -eq 0) 'Failed inventory persisted a success-shaped cache.'
            }
    }
    Invoke-InventoryFixture -Read Throw -CaseRoot $fixtureRoot -Action {
        param($state)
        $legacy = Get-List -Type VM -SmartUpdate
        Assert-True ($null -eq $legacy -and @($state.Logs | Where-Object Failure).Count -gt 0) 'Legacy inventory callers no longer retain their logged null-result contract.'
    }
    Invoke-InventoryFixture -Read Recover -CaseRoot $fixtureRoot -Action {
        param($state)
        $vms = @(Get-List -Type VM -SmartUpdate -FailOnError)
        Assert-True ($state.Calls -eq 2 -and $vms.Count -eq 1 -and $vms[0].vmName -eq 'KEEP-DC') 'A bounded transient inventory retry did not recover.'
    }
    Invoke-InventoryFixture -Read Success -CaseRoot $fixtureRoot -Action {
        param($state)
        $global:DisableSmartUpdate = $true
        $vms = @(Get-List -Type VM -FailOnError)
        Assert-True ($state.Calls -eq 1 -and $vms.Count -eq 1) 'Disabled smart updates made strict inventory skip its authoritative read.'
    }
    Invoke-InventoryFixture -Read Empty -CaseRoot $fixtureRoot -Action {
        param($state)
        $vms = @(Get-List -Type VM -SmartUpdate -FailOnError)
        Assert-True ($vms.Count -eq 0 -and $state.Calls -eq 1) 'A genuine empty host was not distinguished from an unreadable host.'
        [xml]$rdg = '<RDCMan><file><group><properties><name>retired.test</name></properties></group></file></RDCMan>'
        [xml]$mrng = '<Connections><Node Name="retired.test" Type="Container" /><Node Name="UnknownVMs" Type="Container" /></Connections>'
        Assert-True (Remove-MissingDomainsFromFile -file $rdg.RDCMan.file -VmInventory $vms) 'Verified empty inventory did not prune retired RDCMan domains.'
        Assert-True (Remove-MissingDomainsFromMRemoteNG -Doc $mrng -VmInventory $vms) 'Verified empty inventory did not prune retired mRemoteNG domains.'
        Assert-True ($rdg.SelectNodes('/RDCMan/file/group').Count -eq 0 -and $mrng.SelectNodes('/Connections/Node[@Name="UnknownVMs"]').Count -eq 1) 'Empty-inventory pruning changed its intended behavior.'
        Assert-True (@($state.Logs | Where-Object Failure).Count -eq 0) 'An empty host was reported as a failure.'
    }
    Invoke-InventoryFixture -Read Throw -CaseRoot $fixtureRoot -Action {
        param($state)
        $vms = @($state.Seed)
        [xml]$rdg = '<group><server><properties><name>KEEP-DC</name><displayName>KEEP-DC</displayName></properties></server><server><properties><name>retired</name><displayName>retired</displayName></properties></server></group>'
        [xml]$mrng = '<Node Type="Container"><Node Name="nested" Type="Container"><Node Name="KEEP-DC" Hostname="KEEP-DC" Type="Connection" /><Node Name="retired" Hostname="retired" Type="Connection" /></Node></Node>'
        Assert-True (Remove-MissingServersFromGroup -findgroup $rdg.group -VmInventory $vms) 'Snapshot server pruning did not remove a retired server.'
        Assert-True (Remove-MissingConnectionsFromMRemoteNG -Container $mrng.Node -VmInventory $vms) 'Recursive snapshot pruning did not remove a retired connection.'
        Assert-True ($state.Calls -eq 0 -and $rdg.SelectNodes('//server').Count -eq 1 -and $mrng.SelectNodes('//Node[@Type="Connection"]').Count -eq 1) 'Pruning re-read inventory or discarded live snapshot entries.'
        [xml]$rdgDomains = '<RDCMan><file><group><properties><name>keep.test</name></properties></group><group><properties><name>retired.test</name></properties></group></file></RDCMan>'
        [xml]$mrngDomains = '<Connections><Node Name="keep.test" Type="Container" /><Node Name="retired.test" Type="Container" /></Connections>'
        Assert-True (Remove-MissingDomainsFromFile -file $rdgDomains.RDCMan.file -VmInventory $vms) 'RDCMan snapshot domain pruning did not remove a retired domain.'
        Assert-True (Remove-MissingDomainsFromMRemoteNG -Doc $mrngDomains -VmInventory $vms) 'mRemoteNG snapshot domain pruning did not remove a retired domain.'
        Assert-True ($state.Calls -eq 0 -and $rdgDomains.SelectNodes('/RDCMan/file/group').Count -eq 1 -and
            $mrngDomains.SelectNodes('/Connections/Node[@Name="keep.test"]').Count -eq 1) 'Snapshot domain pruning discarded a live domain or re-read inventory.'
    }
    foreach ($read in @('Throw', 'WriteError')) {
        foreach ($overwrite in @($false, $true)) {
            $caseRoot = Join-Path $fixtureRoot "$read-$overwrite"
            $null = New-Item -ItemType Directory -Path $caseRoot -ErrorAction Stop
            Invoke-InventoryFixture -Read $read -CaseRoot $caseRoot -Action {
                param($state)
                $target = Join-Path $Common.CachePath 'connections.xml'
                $original = '<Connections><Node Name="keep.test" Type="Container"><Node Name="KEEP-DC" Type="Connection" /></Node></Connections>'
                [IO.File]::WriteAllText($target, $original)
                $caught = $null
                try { New-MRemoteNGFileFromHyperV -MRemoteNGFile $target -OverWrite:$overwrite -NoActivity }
                catch { $caught = $_ }
                Assert-True ($null -ne $caught) 'mRemoteNG export hid failed inventory.'
                Assert-True ([IO.File]::ReadAllText($target) -ceq $original) 'mRemoteNG export changed a file before inventory was verified.'
                Assert-True ($state.ProcessReads -eq 0 -and $state.Stops -eq 0 -and $state.Successes -eq 0 -and
                    $state.Installs -eq 0 -and $state.ExternalApps -eq 0) 'mRemoteNG touched a client or reported success after failed inventory.'
            }
        }
    }
    Invoke-InventoryFixture -Read Empty -CaseRoot $fixtureRoot -Action {
        param($state)
        $target = Join-Path $Common.CachePath 'empty-connections.xml'
        [IO.File]::WriteAllText($target, '<Connections><Node Name="retired.test" Type="Container" /></Connections>')
        New-MRemoteNGFileFromHyperV -MRemoteNGFile $target -NoActivity
        [xml]$result = [IO.File]::ReadAllText($target)
        Assert-True ($state.Calls -eq 1 -and $result.DocumentElement.Name -eq 'Connections' -and $result.SelectNodes('/Connections/Node').Count -eq 0) 'A verified empty mRemoteNG export failed or added a blank unknown VM.'
        Assert-True ($state.Successes -eq 1 -and $state.Stops -eq 0) 'Empty export changed client restart behavior.'
    }
}
finally {
    $global:Common = $previousCommon
    $global:vm_List = $null
    $global:vm_List_LastUpdate = $null
    $global:vm_List_Dirty = $false
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions connection inventory safety assertions."
