<#
.SYNOPSIS
    Verifies automatic host-boot startup planning and maintenance integration.
.DESCRIPTION
    Executes the shipped helpers with mocked inventory and Hyper-V commands.
    No live VMs, power states, or host settings are changed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'deployConfig', Justification = 'Read by the extracted New-Lab startup guard and note-update loop.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'WhatIf', Justification = 'Read by the extracted New-Lab startup guard.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-StartupFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Parse errors in '$Path': $parseErrors" }
    $node = $ast.Find({
            param($item)
            $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $Name
        }, $true)
    if (-not $node) { throw "Missing function '$Name' in '$Path'." }
    [scriptblock]::Create($node.Extent.Text)
}

. (Import-StartupFunction -Path (Join-Path $RootPath 'common\Common.Phases.ps1') -Name 'Get-CriticalVMs')
foreach ($name in @('Get-VM2', 'Get-VMAutomaticStartupPlan', 'Set-VMAutomaticStartup')) {
    . (Import-StartupFunction -Path (Join-Path $RootPath 'common\Common.HyperV.ps1') -Name $name)
}
. (Import-StartupFunction -Path (Join-Path $RootPath 'common\Common.Maintenance.ps1') -Name 'Start-Maintenance')

$script:Assertions = 0
function Assert-Startup {
    param([bool] $Condition, [string] $Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function New-StartupVM {
    param([string] $Name, [string] $Role, [string] $Domain = 'lab.test', [string] $SqlVersion)
    [pscustomobject]@{
        vmName = $Name; vmId = [guid]::NewGuid(); domain = $Domain; role = $Role
        vmBuild = $true; inProgress = $false; success = $true; hidden = $false
        State = 'Off'; remoteSQLVM = $null; OtherNode = $null
        remoteContentLibVM = $null; fileServerVM = $null; patchMyPCFileServer = $null
        sqlVersion = $SqlVersion
        memoryStartupGB = 2; diskUsedGB = 0
    }
}

function Reset-StartupFixture {
    param([object[]] $VMs)
    $script:StartupFixture = @{
        Inventory = $VMs
        Live = @{}
        Changes = [Collections.Generic.List[object]]::new()
        Logs = [Collections.Generic.List[object]]::new()
        Answer = 'n'; Prompts = 0; InventoryReads = 0
        Failure = ''; FailureVM = ''; MissingId = ''; HyperVReads = 0; SmartInventory = $null
        Answers = [Collections.Generic.Queue[string]]::new()
        GuestPending = $false; AllowGuestJobs = $false; GuestJobs = 0
    }
    foreach ($vm in $VMs) {
        $script:StartupFixture.Live["$($vm.vmId)"] = [pscustomobject]@{
            Id = $vm.vmId; VMId = $vm.vmId; Name = $vm.vmName; VMName = $vm.vmName; State = 'Off'
            MemoryAssigned = 0
            AutomaticStartAction = 'StartIfRunning'; AutomaticStartDelay = 0
            AutomaticStopAction = 'ShutDown'
            Notes = '{"lastUpdate":"fixture","appliedFixes":{"UnitStartup":"1.0"}}'
        }
    }
}

function Get-List {
    [CmdletBinding()]
    param($Type, $DomainName, [switch] $SmartUpdate, [switch] $FailOnError)
    $script:StartupFixture.InventoryReads++
    if ($script:StartupFixture.Failure -eq 'Inventory') { throw 'Synthetic inventory failure' }
    $vms = if ($SmartUpdate -and $script:StartupFixture.SmartInventory) {
        $script:StartupFixture.SmartInventory
    }
    else {
        $script:StartupFixture.Inventory
    }
    if ($DomainName) { $vms = @($vms | Where-Object { $_.domain -eq $DomainName }) }
    $vms
}

function Get-VM {
    [CmdletBinding()]
    param([Nullable[guid]] $Id)
    $script:StartupFixture.HyperVReads++
    if (-not $Id -and $script:StartupFixture.Failure -eq 'Enumeration') {
        throw 'Synthetic Hyper-V enumeration failure'
    }
    if (-not $Id -and $script:StartupFixture.Failure -eq 'EnumerationNonterminating') {
        Write-Error 'Synthetic nonterminating Hyper-V enumeration failure'
        return
    }
    if ($script:StartupFixture.Failure -eq 'Read' -or
        ($script:StartupFixture.Failure -eq 'Readback' -and $script:StartupFixture.Changes.Count -gt 0)) {
        throw 'Synthetic Hyper-V read failure'
    }
    if (-not $Id) { return @($script:StartupFixture.Live.Values) }
    if ("$Id" -eq $script:StartupFixture.MissingId) { return }
    $script:StartupFixture.Live["$Id"]
}

function Set-VM {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $VM, [string] $AutomaticStartAction, [int] $AutomaticStartDelay, [string] $Notes)
    process {
        if ($PSBoundParameters.ContainsKey('Notes')) {
            $VM.Notes = $Notes
            return
        }
        if ($VM.Name -eq $script:StartupFixture.FailureVM) {
            if ($script:StartupFixture.Failure -eq 'WriteError') {
                Write-Error 'Synthetic nonterminating Set-VM failure'
                return
            }
            throw 'Synthetic Set-VM failure'
        }
        $script:StartupFixture.Changes.Add([pscustomobject]@{
                Name = $VM.Name; Action = $AutomaticStartAction; Delay = $AutomaticStartDelay
            })
        if ($script:StartupFixture.Failure -ne 'DiscardWrite') {
            $VM.AutomaticStartAction = $AutomaticStartAction
            $VM.AutomaticStartDelay = $AutomaticStartDelay
        }
    }
}

function Write-Log {
    param($Message, [switch] $Verbose, [switch] $LogOnly, [switch] $Failure,
        [switch] $Success, [switch] $Warning, [switch] $Activity, [switch] $SubActivity)
    $script:StartupFixture.Logs.Add([pscustomobject]@{ Message = "$Message"; Failure = [bool]$Failure })
}
function Read-YesOrNoWithTimeout {
    param($Prompt, $Default, $timeout, [switch] $HideHelp)
    $script:StartupFixture.Prompts++
    Assert-Startup ($Default -eq 'n') 'Startup changes must default to No.'
    if ($script:StartupFixture.Answers.Count -gt 0) { return $script:StartupFixture.Answers.Dequeue() }
    $script:StartupFixture.Answer
}
function Start-VM { throw 'Automatic startup maintenance must not start VMs.' }
function Stop-VM { throw 'Automatic startup maintenance must not stop VMs.' }
function Start-VM2 { throw 'Automatic startup maintenance must not start VMs.' }
function Stop-VM2 { throw 'Automatic startup maintenance must not stop VMs.' }
function Start-NormalJobs {
    param($machines, $ScriptBlock, $Phase, $argument1, $argument2, $argument3,
        [switch] $PreferThreadJob, [switch] $MaintenanceDiagnostics)
    if (-not $script:StartupFixture.AllowGuestJobs) { throw 'No guest jobs should be necessary for this fixture.' }
    $script:StartupFixture.GuestJobs += @($machines).Count
    [pscustomobject]@{ Jobs = @(); AdditionalData = $null }
}
function Wait-Phase {
    param($Phase, $Jobs, $AdditionalData)
    [pscustomobject]@{ Success = $script:StartupFixture.GuestJobs; Failed = 0 }
}
function Start-Sleep { param($Seconds) }
function Clear-Host {}
function Get-VMFixes {
    param([switch] $ReturnDummyList)
    [pscustomobject]@{ FixName = 'UnitStartup'; FixVersion = '1.0'; AppliesToExisting = $true }
}
function Test-VMFixApplied { param($VMNote, $FixName, $FixVersion) return (-not $script:StartupFixture.GuestPending) }

$basic = @(
    New-StartupVM -Name 'WEB01' -Role 'DomainMember'
    New-StartupVM -Name 'SQL01' -Role 'DomainMember' -SqlVersion 'SQL Server 2022'
    New-StartupVM -Name 'DC01' -Role 'DC'
)
Reset-StartupFixture -VMs $basic

$duplicateNameId = [guid]::NewGuid()
$staleDuplicateId = [guid]::NewGuid()
$duplicateInventory = @(
    [pscustomobject]@{ vmName = 'DUPLICATE'; vmId = $staleDuplicateId }
    [pscustomobject]@{ vmName = 'DUPLICATE'; vmId = $duplicateNameId.ToString('N') }
    [pscustomobject]@{ vmName = 'DUPLICATE'; vmId = $duplicateNameId.ToString('B') }
    [pscustomobject]@{ vmName = 'DUPLICATE'; vmId = $staleDuplicateId }
)
Reset-StartupFixture -VMs $duplicateInventory
$script:StartupFixture.Live.Remove("$staleDuplicateId")
foreach ($formattedId in @($duplicateNameId.ToString('N'), $duplicateNameId.ToString('B'))) {
    $script:StartupFixture.Live.Remove($formattedId)
}
$script:StartupFixture.Live["$duplicateNameId"] = [pscustomobject]@{
    Id = $duplicateNameId; VMId = $duplicateNameId; Name = 'DUPLICATE'
}
Assert-Startup ((Get-VM2 -Name 'DUPLICATE').Id -eq $duplicateNameId) 'Duplicate cache rows were bound as an array instead of scalar VM IDs.'
Assert-Startup ($script:StartupFixture.HyperVReads -eq 2) 'Duplicate cache rows were not deduplicated and stale IDs were not skipped.'

$refreshId = [guid]::NewGuid()
$wrongNameId = [guid]::NewGuid()
Reset-StartupFixture -VMs @(
    [pscustomobject]@{ vmName = 'REFRESHED'; vmId = 'invalid-guid' }
    [pscustomobject]@{ vmName = 'REFRESHED'; vmId = $wrongNameId }
)
$script:StartupFixture.SmartInventory = @([pscustomobject]@{ vmName = 'REFRESHED'; vmId = $refreshId })
$script:StartupFixture.Live.Clear()
$script:StartupFixture.Live["$wrongNameId"] = [pscustomobject]@{ Id = $wrongNameId; Name = 'OTHER' }
$script:StartupFixture.Live["$refreshId"] = [pscustomobject]@{ Id = $refreshId; Name = 'REFRESHED' }
Assert-Startup ((Get-VM2 -Name 'REFRESHED').Id -eq $refreshId) 'Invalid or wrong-name cache rows did not advance to the smart refresh.'
Assert-Startup ($script:StartupFixture.HyperVReads -eq 2 -and $script:StartupFixture.InventoryReads -eq 2) 'Smart refresh did not use one scalar initial ID and one scalar refreshed ID.'

Reset-StartupFixture -VMs $basic
$plan = @(Get-VMAutomaticStartupPlan -VMs $basic)
Assert-Startup (($plan.VMName -join ',') -eq 'DC01,SQL01,WEB01') 'Basic startup ordering is incorrect.'
Assert-Startup (($plan.AutomaticStartDelay -join ',') -eq '0,120,240') 'Basic startup delays must be exactly 0/120/240.'
Assert-Startup ($script:StartupFixture.InventoryReads -eq 0) 'Planning must reuse the supplied inventory.'
$result = @(Set-VMAutomaticStartup)
Assert-Startup ($result.Count -eq 1 -and $result[0] -eq $true) 'Successful maintenance must return exactly one Boolean.'
Assert-Startup ($script:StartupFixture.InventoryReads -eq 1) 'Maintenance should enumerate managed inventory once.'
Assert-Startup ($script:StartupFixture.Changes.Count -eq 3) 'All three basic VMs should be configured.'
foreach ($vm in $script:StartupFixture.Live.Values) {
    Assert-Startup ($vm.AutomaticStartAction -eq 'Start') "$($vm.Name): startup action is incorrect."
    Assert-Startup ($vm.State -eq 'Off' -and $vm.AutomaticStopAction -eq 'ShutDown') "$($vm.Name): power state or stop action changed."
}
$result = Set-VMAutomaticStartup -Prompt
Assert-Startup ($result -and $script:StartupFixture.Changes.Count -eq 3 -and $script:StartupFixture.Prompts -eq 0) 'Already-correct settings must not be rewritten or prompt again.'

$infra = @(
    New-StartupVM -Name 'DC' -Role 'DC'
    New-StartupVM -Name 'BDC' -Role 'BDC'
    New-StartupVM -Name 'PROXY' -Role 'Proxy'
    New-StartupVM -Name 'FILES' -Role 'DomainMember'
    New-StartupVM -Name 'SQLAO1' -Role 'SQLAO'
    New-StartupVM -Name 'SQLAO2' -Role 'SQLAO'
    New-StartupVM -Name 'SQL-UNUSED' -Role 'DomainMember' -SqlVersion 'SQL Server 2022'
    New-StartupVM -Name 'CAS' -Role 'CAS'
    New-StartupVM -Name 'PRI' -Role 'Primary'
    New-StartupVM -Name 'CLIENT' -Role 'DomainMember'
)
($infra | Where-Object vmName -eq 'SQLAO1').OtherNode = 'SQLAO2'
($infra | Where-Object vmName -eq 'SQLAO1').fileServerVM = 'FILES'
($infra | Where-Object vmName -eq 'CAS').remoteSQLVM = 'SQLAO1'
($infra | Where-Object vmName -eq 'PRI').remoteSQLVM = 'SQLAO1'
$expected = @{ DC = 0; BDC = 0; PROXY = 0; FILES = 120; SQLAO1 = 240; SQLAO2 = 240; 'SQL-UNUSED' = 240; CAS = 360; PRI = 480; CLIENT = 600 }
$plan = @(Get-VMAutomaticStartupPlan -VMs $infra)
Assert-Startup ($plan.Count -eq $expected.Count) 'Infrastructure plan omitted or duplicated a VM.'
foreach ($item in $plan) {
    Assert-Startup ($item.AutomaticStartDelay -eq $expected[$item.VMName]) "$($item.VMName): incorrect infrastructure delay."
}
Reset-StartupFixture -VMs $infra
$critical = Get-CriticalVMs -domain 'lab.test'
Assert-Startup (($critical.FS.vmName -join ',') -eq 'FILES') 'Smart-start must retain SQLAO file-server dependencies after classifying SQL nodes.'

foreach ($property in @('remoteContentLibVM', 'fileServerVM', 'patchMyPCFileServer')) {
    $dependencyVMs = @(
        New-StartupVM -Name 'DC' -Role 'DC'
        New-StartupVM -Name 'FILES' -Role 'DomainMember'
        New-StartupVM -Name 'PRIMARY' -Role 'Primary' -SqlVersion 'SQL Server 2022'
    )
    ($dependencyVMs | Where-Object vmName -eq 'PRIMARY').$property = 'FILES'
    $plan = @(Get-VMAutomaticStartupPlan -VMs $dependencyVMs)
    Assert-Startup (($plan | Where-Object VMName -eq 'FILES').AutomaticStartDelay -eq 120) "$property must put its file server before the primary."
    Assert-Startup (($plan | Where-Object VMName -eq 'PRIMARY').AutomaticStartDelay -eq 240) 'Local SQL must not move a primary out of the primary tier.'
}

foreach ($fixtureName in @('MpReplicaTest-A-AllReplicaTypes.json', 'NOCM-G-SQLWSUSOSD.json')) {
    $config = Get-Content -LiteralPath (Join-Path $RootPath "config\tests\$fixtureName") -Raw | ConvertFrom-Json
    $configVMs = @(
        foreach ($vm in $config.virtualMachines) {
            $item = New-StartupVM -Name $vm.vmName -Role $vm.role -Domain $config.vmOptions.domainName
            foreach ($property in $vm.PSObject.Properties) {
                $item | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
            }
            $item
        }
    )
    $plan = @(Get-VMAutomaticStartupPlan -VMs $configVMs)
    $expectedDelays = if ($fixtureName -like 'MpReplica*') {
        @{ PS1SQL = 120; REPLSQL1 = 120; REPLSQL2 = 120; PS1SITE = 240; MPLOCAL = 360; MPREMOTE = 360; MPNAMED = 360 }
    }
    else { @{ W22SQL1 = 0; WSUS1 = 120 } }
    foreach ($name in $expectedDelays.Keys) {
        $matchingEntries = @($plan | Where-Object VMName -eq $name)
        Assert-Startup ($matchingEntries.Count -eq 1 -and $matchingEntries[0].AutomaticStartDelay -eq $expectedDelays[$name]) "$fixtureName : $name must retain the correct SQL/site/consumer tier."
    }
}

$excluded = @(
    New-StartupVM -Name 'ROOT' -Role 'StandaloneRootCA'
    New-StartupVM -Name 'OSD' -Role 'OSDClient'
    New-StartupVM -Name 'AAD' -Role 'AADClient'
    New-StartupVM -Name 'DHCP' -Role 'DhcpAppliance'
    New-StartupVM -Name 'UNMANAGED' -Role 'DomainMember'
    New-StartupVM -Name 'HIDDEN' -Role 'DomainMember'
    New-StartupVM -Name 'BUILDING' -Role 'Primary'
    New-StartupVM -Name 'FAILED' -Role 'CAS'
)
($excluded | Where-Object vmName -eq 'UNMANAGED').vmBuild = $false
($excluded | Where-Object vmName -eq 'HIDDEN').hidden = $true
($excluded | Where-Object vmName -eq 'BUILDING').inProgress = $true
($excluded | Where-Object vmName -eq 'FAILED').success = $false
$linux = New-StartupVM -Name 'LINUX' -Role 'LinuxServer'
$secondDomain = New-StartupVM -Name 'OTHER-DC' -Role 'DC' -Domain 'other.test'
Reset-StartupFixture -VMs @($basic + $excluded + @($linux, $secondDomain))
$result = Set-VMAutomaticStartup -DomainName 'lab.test'
Assert-Startup ($result -and $script:StartupFixture.Changes.Count -eq 4) 'Domain-scoped maintenance did not configure exactly the eligible Windows/Linux VMs.'
foreach ($vm in @($excluded + @($secondDomain))) {
    $live = $script:StartupFixture.Live["$($vm.vmId)"]
    Assert-Startup ($live.AutomaticStartAction -eq 'StartIfRunning') "$($vm.vmName): excluded VM was changed."
}
$plan = @(Get-VMAutomaticStartupPlan -VMs @($basic + @($secondDomain)))
Assert-Startup (($plan | Where-Object VMName -eq 'OTHER-DC').AutomaticStartDelay -eq 0) 'Each domain must start its delay sequence independently.'

foreach ($answer in @('n', '', 'ESCAPE', 'y', 'yes')) {
    Reset-StartupFixture -VMs $basic
    $script:StartupFixture.Answer = $answer
    $result = Set-VMAutomaticStartup -Prompt
    $expectedChanges = if ($answer -in @('y', 'yes')) { 3 } else { 0 }
    Assert-Startup ($result -and $script:StartupFixture.Changes.Count -eq $expectedChanges) "Unexpected confirmation behavior for '$answer'."
    Assert-Startup ($script:StartupFixture.Prompts -eq 1) 'Pending settings must require exactly one startup confirmation.'
}
Reset-StartupFixture -VMs $basic
$result = Set-VMAutomaticStartup -WhatIf -Prompt
Assert-Startup ($result -and $script:StartupFixture.Changes.Count -eq 0 -and $script:StartupFixture.Prompts -eq 0) 'WhatIf must neither mutate nor request startup confirmation.'

foreach ($failure in @('Inventory', 'Read', 'Write', 'WriteError', 'DiscardWrite', 'Readback', 'MissingVM')) {
    Reset-StartupFixture -VMs $basic
    $script:StartupFixture.Failure = $failure
    if ($failure -in @('Write', 'WriteError')) { $script:StartupFixture.FailureVM = 'DC01' }
    if ($failure -eq 'MissingVM') { $script:StartupFixture.MissingId = "$(($basic | Where-Object vmName -eq 'SQL01').vmId)" }
    $result = @(Set-VMAutomaticStartup)
    Assert-Startup ($result.Count -eq 1 -and $result[0] -eq $false) "$failure must return exactly one failure Boolean."
    Assert-Startup (@($script:StartupFixture.Logs | Where-Object Failure).Count -gt 0) "$failure must be explicitly logged."
    Assert-Startup ($script:StartupFixture.Changes.Count -le 1) "$failure must stop before configuring dependent VMs."
}
Reset-StartupFixture -VMs $basic
$script:StartupFixture.Failure = 'Write'
$script:StartupFixture.FailureVM = 'SQL01'
Assert-Startup (-not (Set-VMAutomaticStartup)) 'A partial write failure must be reported.'
Assert-Startup (($script:StartupFixture.Changes.Name -join ',') -eq 'DC01') 'A partial failure must stop before later dependents.'
$script:StartupFixture.Failure = ''
$script:StartupFixture.FailureVM = ''
Assert-Startup (Set-VMAutomaticStartup) 'A retry must repair a partial update.'
Assert-Startup (($script:StartupFixture.Changes.Name -join ',') -eq 'DC01,SQL01,WEB01') 'Retry must not rewrite a previously verified VM.'
Reset-StartupFixture -VMs $excluded
Assert-Startup (Set-VMAutomaticStartup) 'An all-excluded inventory should be a no-op.'
Assert-Startup ($script:StartupFixture.Changes.Count -eq 0) 'An all-excluded inventory changed settings.'
Reset-StartupFixture -VMs @()
Assert-Startup (Set-VMAutomaticStartup) 'An empty inventory should be a no-op.'
Assert-Startup (@(Get-VMAutomaticStartupPlan -VMs @()).Count -eq 0) 'An empty inventory produced a plan.'
$invalid = New-StartupVM -Name 'INVALID' -Role 'DC'
$invalid.vmId = $null
Reset-StartupFixture -VMs @($invalid)
Assert-Startup (-not (Set-VMAutomaticStartup)) 'Invalid managed metadata must fail, not disappear from the plan.'
$malformed = New-StartupVM -Name 'MALFORMED' -Role 'DC'
$malformed.vmId = 'not-a-guid'
Reset-StartupFixture -VMs @($malformed)
$result = @(Set-VMAutomaticStartup)
Assert-Startup ($result.Count -eq 1 -and $result[0] -eq $false -and
    $script:StartupFixture.HyperVReads -eq 0 -and
    ($script:StartupFixture.Logs | Where-Object Failure | Select-Object -ExpandProperty Message) -match 'invalid Hyper-V VM ID') 'A malformed VM ID was queried or did not fail explicitly.'
$validFirst = New-StartupVM -Name 'VALID-FIRST' -Role 'DC'
$malformedSecond = New-StartupVM -Name 'MALFORMED-SECOND' -Role 'DomainMember'
$malformedSecond.vmId = 'still-not-a-guid'
Reset-StartupFixture -VMs @($validFirst, $malformedSecond)
$result = @(Set-VMAutomaticStartup)
Assert-Startup ($result.Count -eq 1 -and $result[0] -eq $false -and
    $script:StartupFixture.HyperVReads -eq 0 -and $script:StartupFixture.Changes.Count -eq 0) 'A later malformed VM ID allowed an earlier Hyper-V query or startup write.'
foreach ($format in @('N', 'B')) {
    $alternate = New-StartupVM -Name "ALTERNATE-$format" -Role 'DC'
    $canonicalId = [guid]$alternate.vmId
    $formattedId = $canonicalId.ToString($format)
    if ($format -eq 'B') { $formattedId = " $formattedId " }
    $alternate.vmId = $formattedId
    Reset-StartupFixture -VMs @($alternate)
    $formattedLive = $script:StartupFixture.Live["$formattedId"]
    $script:StartupFixture.Live.Remove($formattedId)
    $formattedLive.Id = $canonicalId
    $formattedLive.VMId = $canonicalId
    $script:StartupFixture.Live["$canonicalId"] = $formattedLive
    Assert-Startup (Set-VMAutomaticStartup) "Valid '$format'-format Hyper-V VM ID failed startup maintenance."
    Assert-Startup ($script:StartupFixture.Changes.Count -eq 1 -and $script:StartupFixture.HyperVReads -eq 2) "Valid '$format'-format VM ID was not canonicalized for lookup and readback."
}

Reset-StartupFixture -VMs $basic
$script:StartupFixture.Answer = 'y'
$result = @(Start-Maintenance)
Assert-Startup ($script:StartupFixture.Changes.Count -eq 3) 'Existing maintenance must configure startup even when no guest fixes are pending.'
Assert-Startup ($result.Count -eq 0) 'Start-Maintenance leaked helper output.'
Reset-StartupFixture -VMs $basic
$script:StartupFixture.Answer = 'n'
Start-Maintenance
Assert-Startup ($script:StartupFixture.Changes.Count -eq 0 -and $script:StartupFixture.Prompts -eq 1) 'Declining startup maintenance must leave settings unchanged with no guest work.'
Reset-StartupFixture -VMs $basic
$script:StartupFixture.Failure = 'Inventory'
Start-Maintenance
Assert-Startup ($script:StartupFixture.InventoryReads -eq 1) 'Guest maintenance must not continue after host startup maintenance fails.'

$guestVM = New-StartupVM -Name 'AUTOSTART-FIXTURE-DC' -Role 'DC'
$guestVM.State = 'Running'
foreach ($startupAnswer in @('n', 'y')) {
    Reset-StartupFixture -VMs @($guestVM)
    $script:StartupFixture.GuestPending = $true
    $script:StartupFixture.AllowGuestJobs = $true
    $script:StartupFixture.Answers.Enqueue($startupAnswer)
    $script:StartupFixture.Answers.Enqueue('n')
    Start-Maintenance
    $expectedChanges = if ($startupAnswer -eq 'y') { 1 } else { 0 }
    Assert-Startup ($script:StartupFixture.Changes.Count -eq $expectedChanges -and $script:StartupFixture.GuestJobs -eq 0) 'Startup consent must not implicitly authorize guest fixes.'
    Assert-Startup ($script:StartupFixture.Prompts -eq 2) 'Startup and guest changes must have separate confirmations.'
}
Reset-StartupFixture -VMs @($guestVM)
$script:StartupFixture.GuestPending = $true
$script:StartupFixture.AllowGuestJobs = $true
$script:StartupFixture.Answers.Enqueue('n')
$script:StartupFixture.Answers.Enqueue('y')
Start-Maintenance
Assert-Startup ($script:StartupFixture.Changes.Count -eq 0 -and $script:StartupFixture.GuestJobs -eq 1) 'Guest consent must not implicitly authorize startup changes.'

$tokens = $null
$parseErrors = $null
$newLabAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'New-Lab.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Startup ($parseErrors.Count -eq 0) 'New-Lab.ps1 has parse errors.'
$startupCalls = @($newLabAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Set-VMAutomaticStartup'
        }, $true))
Assert-Startup ($startupCalls.Count -eq 1) 'New builds must have one automatic startup maintenance integration point.'
$guard = $startupCalls[0].Parent
while ($guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
Assert-Startup ($guard.Clauses[0].Item1.Extent.Text -match '^\$phase11Passed -and') 'New builds must configure startup only after Phase 11 passes.'
$phase11Assignments = @($newLabAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$phase11Passed'
        }, $true))
Assert-Startup ($phase11Assignments.Count -eq 2 -and $phase11Assignments[0].Right.Extent.Text -eq '$false' -and
    $phase11Assignments[1].Right.Extent.Text -eq '$true') 'The Phase 11 completion flag must be reset for each run.'
$phaseGuard = $phase11Assignments[1].Parent
while ($phaseGuard -and $phaseGuard -isnot [System.Management.Automation.Language.IfStatementAst]) { $phaseGuard = $phaseGuard.Parent }
Assert-Startup ($phaseGuard.Clauses[0].Item1.Extent.Text -eq '$i -eq 11') 'Only successful Phase 11 may set the startup-finalization flag.'
Assert-Startup ($startupCalls[0].Extent.Text -match '-WhatIf:\$WhatIf') 'New-build startup settings must honor WhatIf.'
$updateLoop = $newLabAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.Extent.Text -eq '$vm' -and $node.Body.Extent.Text -match '\$updatableEntry'
    }, $true)
Assert-Startup ($updateLoop -and $updateLoop.Extent.EndOffset -lt $startupCalls[0].Extent.StartOffset) 'Startup planning must run after existing-VM dependency notes are saved.'
foreach ($case in @(
        @{ Passed = $false; Failure = '' }
        @{ Passed = $true; Failure = '' }
        @{ Passed = $true; Failure = 'Write' }
    )) {
    Reset-StartupFixture -VMs $basic
    $script:StartupFixture.Failure = $case.Failure
    if ($case.Failure) { $script:StartupFixture.FailureVM = 'DC01' }
    $deployConfig = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'lab.test' } }
    $WhatIf = $false
    $phase11Passed = $case.Passed
    $threw = $false
    try { . ([scriptblock]::Create($guard.Extent.Text)) }
    catch {
        $threw = $true
        Assert-Startup ($_.Exception.Message -like 'Automatic startup maintenance failed after Phase 11*') 'Unexpected new-build finalization error.'
    }
    Assert-Startup ($threw -eq [bool]$case.Failure) 'New-build startup failure must prevent successful finalization.'
    $expectedChanges = if ($phase11Passed -and -not $case.Failure) { 3 } else { 0 }
    Assert-Startup ($script:StartupFixture.Changes.Count -eq $expectedChanges) 'Partial runs must not configure startup before Phase 11 passes.'
}

function Update-VMNoteProperty {
    param($VMName, $PropertyName, $PropertyValue)
    $target = $script:StartupFixture.Inventory | Where-Object vmName -eq $VMName
    $target.$PropertyName = $PropertyValue
}
$updatedVMs = @(
    New-StartupVM -Name 'DC01' -Role 'DC'
    New-StartupVM -Name 'PRI01' -Role 'Primary'
    New-StartupVM -Name 'FS01' -Role 'DomainMember'
)
Reset-StartupFixture -VMs $updatedVMs
$Global:Common = [pscustomobject]@{ Supported = [pscustomobject]@{ PropsToUpdate = @('patchMyPCFileServer') } }
$deployConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'lab.test' }
    VirtualMachines = @([pscustomobject]@{ vmName = 'PRI01'; ExistingVM = $true; patchMyPCFileServer = 'FS01' })
}
$phase11Passed = $true
Assert-Startup $phase11Passed 'The dependency-update fixture must represent a validated deployment.'
. ([scriptblock]::Create($updateLoop.Extent.Text))
. ([scriptblock]::Create($guard.Extent.Text))
Assert-Startup (($script:StartupFixture.Changes | Where-Object Name -eq 'FS01').Delay -eq 120) 'Finalization must use a newly saved existing-VM file-server dependency.'
Assert-Startup (($script:StartupFixture.Changes | Where-Object Name -eq 'PRI01').Delay -eq 240) 'An updated primary must boot after its newly selected file server.'

& {
    foreach ($name in @('Test-VMResourceCacheMetrics', 'Get-List', 'Get-VMFromHyperV', 'Update-VMFromHyperV')) {
        . (Import-StartupFunction -Path (Join-Path $RootPath 'common\Common.Config.ps1') -Name $name)
    }
    foreach ($name in @('Get-VMNote', 'Set-VMNote', 'Update-VMNoteProperty')) {
        . (Import-StartupFunction -Path (Join-Path $RootPath 'Common.ps1') -Name $name)
    }
    function Get-VM2 {
        param([string] $Name, [switch] $Fallback)
        $script:StartupFixture.Live.Values | Where-Object Name -eq $Name
    }
    function Read-VMListDiskCache { $script:StartupFixture.DiskCache }
    function Save-VMListDiskCache {}
    function Flush-LogBuffer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Mocks the existing production command by its exact name.')]
        [CmdletBinding()]
        param([switch] $All)
    }
    function Invoke-VMNetworkBulkWarmup {}
    function Get-VMSizeCached { param($vm) [pscustomobject]@{ diskSize = 0; MemoryStartup = 2GB } }
    function Get-VMNetworkCached { param($vm) [pscustomobject]@{ SwitchName = 'Fixture'; IPAddress = $null } }
    function Test-SiteSystemClientOperatingSystem { param($VirtualMachine) return $false }

    function Reset-LiveInventoryFixture {
        param([string] $CacheMode)
        $records = @(
            New-StartupVM -Name 'DC01' -Role 'DC'
            New-StartupVM -Name 'PRI01' -Role 'Primary'
            New-StartupVM -Name 'FS01' -Role 'DomainMember'
        )
        Reset-StartupFixture -VMs $records
        foreach ($vm in $records) {
            $note = $vm.PSObject.Copy()
            $note | Add-Member -MemberType NoteProperty -Name lastUpdate -Value 'fixture'
            $note | Add-Member -MemberType NoteProperty -Name adminName -Value 'FixtureAdmin'
            $script:StartupFixture.Live["$($vm.vmId)"].Notes = $note | ConvertTo-Json -Depth 5
        }
        $Global:Common = [pscustomobject]@{
            InJob = $CacheMode -eq 'cold-in-job'
            Supported = [pscustomobject]@{ PropsToUpdate = @('patchMyPCFileServer') }
        }
        $global:vm_List = @($records | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        $global:vm_List_LastUpdate = Get-Date
        $global:vm_List_Dirty = $CacheMode -eq 'dirty'
        $global:DisableSmartUpdate = $CacheMode -eq 'disabled'
        $script:StartupFixture.DiskCache = @()
        if ($CacheMode -eq 'old') { $global:vm_List_LastUpdate = (Get-Date).AddSeconds(-10) }
        if ($CacheMode -eq 'disk') {
            $script:StartupFixture.DiskCache = $global:vm_List
            $global:vm_List = $null
        }
        if ($CacheMode -in @('cold', 'cold-in-job')) { $global:vm_List = $null }
    }

    foreach ($cacheMode in @('recent', 'old', 'dirty', 'disabled', 'cold', 'disk', 'cold-in-job')) {
        Reset-LiveInventoryFixture -CacheMode $cacheMode
        . ([scriptblock]::Create($updateLoop.Extent.Text))
        $persisted = ($script:StartupFixture.Live.Values | Where-Object Name -eq 'PRI01').Notes | ConvertFrom-Json
        Assert-Startup ($persisted.patchMyPCFileServer -eq 'FS01') "$cacheMode : the real note writer must persist the dependency."
        if ($cacheMode -eq 'recent') {
            Assert-Startup (-not ($global:vm_List | Where-Object vmName -eq 'PRI01').patchMyPCFileServer) 'The recent-cache fixture must still contain the pre-update metadata.'
        }
        . ([scriptblock]::Create($guard.Extent.Text))
        Assert-Startup (($script:StartupFixture.Changes | Where-Object Name -eq 'FS01').Delay -eq 120) "$cacheMode : live inventory must put the updated file-server dependency first."
        Assert-Startup (($script:StartupFixture.Changes | Where-Object Name -eq 'PRI01').Delay -eq 240) "$cacheMode : finalization must use refreshed primary metadata."
    }

    foreach ($cacheMode in @('recent', 'cold', 'disk')) {
        foreach ($failure in @('Enumeration', 'EnumerationNonterminating')) {
            Reset-LiveInventoryFixture -CacheMode $cacheMode
            $script:StartupFixture.Failure = $failure
            $threw = $false
            try { . ([scriptblock]::Create($guard.Extent.Text)) }
            catch {
                $threw = $true
                Assert-Startup ($_.Exception.Message -like 'Automatic startup maintenance failed after Phase 11*') 'Unexpected inventory-failure finalization error.'
            }
            Assert-Startup $threw "$cacheMode / $failure : failed inventory must prevent successful finalization."
            Assert-Startup ($script:StartupFixture.Changes.Count -eq 0) "$cacheMode / $failure : failed inventory must not change startup settings."
            Assert-Startup (@($script:StartupFixture.Logs | Where-Object Failure).Count -gt 0) "$cacheMode / $failure : inventory failure must be logged."
        }
        Reset-LiveInventoryFixture -CacheMode $cacheMode
        $script:StartupFixture.Live.Clear()
        . ([scriptblock]::Create($guard.Extent.Text))
        Assert-Startup ($script:StartupFixture.Changes.Count -eq 0) "$cacheMode : a genuinely empty live inventory must remain a successful no-op."
        Assert-Startup (@($global:vm_List).Count -eq 0) "$cacheMode : stale VMs must not survive the empty-inventory refresh."
    }
}

Write-Host "PASS: $script:Assertions automatic startup assertions (mocked; no live VM changes)."
