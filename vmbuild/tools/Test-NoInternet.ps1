[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'These host-policy tests require PowerShell 7.4+.' }

function Import-PolicyTestFunction {
    param([string]$File, [string]$Name)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath $File), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "$File does not parse: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $File." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-Policy {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Checks++
}

function Assert-PolicyThrows {
    param([scriptblock]$Operation, [string]$Message)
    $threw = $false
    try { $null = & $Operation } catch { $threw = $true }
    Assert-Policy $threw $Message
}

. (Join-Path $RootPath 'common\Common.Internet.ps1')
$script:RecoveryInstaller = (Get-Command Install-MemLabsInternetRecovery).ScriptBlock
$script:EventWriter = (Get-Command Write-MemLabsInternetEvent).ScriptBlock
foreach ($name in @('Set-VmProxyEnforcement', 'Set-VmProxyEnforcementForAllLabs')) {
    . (Import-PolicyTestFunction -File 'common\Common.HyperV.ps1' -Name $name)
}
. (Import-PolicyTestFunction -File 'common\Common.Validation.ps1' -Name 'Test-ValidVmInternetPolicy')
. (Import-PolicyTestFunction -File 'common\Common.GenConfig.AddVM.ps1' -Name 'Test-ConfigNeedsProxy')

$script:Checks = 0
$script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("MemLabs-NoInternet-" + [guid]::NewGuid().ToString('N'))
$script:VMs = @(
    [pscustomobject]@{
        Name = 'OFFLINE1'; Id = [guid]::NewGuid(); State = 'Off'
        AutomaticStartAction = 'Start'; AutomaticStartDelay = 120
        Notes = '{"vmName":"OFFLINE1","role":"DomainMember","operatingSystem":"Windows 11 Latest (64-bit)","noInternet":true,"useProxy":false}'
    },
    [pscustomobject]@{
        Name = 'CONNECTED1'; Id = [guid]::NewGuid(); State = 'Running'
        AutomaticStartAction = 'Start'; AutomaticStartDelay = 120
        Notes = '{"vmName":"CONNECTED1","role":"DomainMember","noInternet":false,"useProxy":false}'
    }
)
$script:Adapters = @(
    [pscustomobject]@{ Id = 'offline-primary'; VMName = 'OFFLINE1'; Name = 'Network Adapter'; SwitchName = '10.10.0.0' },
    [pscustomobject]@{ Id = 'offline-cluster'; VMName = 'OFFLINE1'; Name = 'Cluster'; SwitchName = 'ClusterV2' },
    [pscustomobject]@{ Id = 'connected-primary'; VMName = 'CONNECTED1'; Name = 'Network Adapter'; SwitchName = '10.10.0.0' }
)
$script:Acls = [hashtable]::Synchronized(@{})
foreach ($adapter in $script:Adapters) { $script:Acls[$adapter.Id] = @() }
$script:Adds = 0
$script:BaselineRemovals = 0
$script:RemoveFailure = $false
$script:AddFailure = $false
$script:Messages = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:Inventory = @()
$script:ValidationErrors = @()
$script:CacheFacts = [pscustomobject]@{ CachedUrls = @(); DotNetReady = $false; AdkReady = $false; SsmsReady = $false; PbirsReady = $false }

function Get-MemLabsInternetStateRoot { return $script:FixtureRoot }
function Initialize-MemLabsInternetStateRoot { $null = New-Item -ItemType Directory -Path $script:FixtureRoot -Force }
function Get-MemLabsInternetBootId { return 'test-boot' }
function Install-MemLabsInternetRecovery { $script:RecoveryVerified = $true }
function Get-VmInternetCacheFacts { param($VMName, $VMDomain, $Urls); return $script:CacheFacts }
function Get-VM {
    [CmdletBinding()]
    param([string]$Name, [guid]$Id)
    if ($Name) {
        $found = @($script:VMs | Where-Object Name -eq $Name)
        if ($found.Count -ne 1) { throw "Fixture VM '$Name' missing." }
        return $found[0]
    }
    if ($PSBoundParameters.ContainsKey('Id')) {
        $found = @($script:VMs | Where-Object Id -eq $Id)
        if ($found.Count -ne 1) { throw "Fixture VM '$Id' missing." }
        return $found[0]
    }
    return $script:VMs
}
function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param($VM, [string]$VMName)
    if ($VM) { $VMName = $VM.Name }
    return @($script:Adapters | Where-Object VMName -eq $VMName)
}
function Get-VMNetworkAdapterExtendedAcl {
    [CmdletBinding()]
    param($VMNetworkAdapter, [string]$VMName)
    if ($VMNetworkAdapter) { return @($script:Acls[$VMNetworkAdapter.Id]) }
    foreach ($adapter in @($script:Adapters | Where-Object VMName -eq $VMName)) { $script:Acls[$adapter.Id] }
}
function Add-VMNetworkAdapterExtendedAcl {
    [CmdletBinding()]
    param($VMNetworkAdapter, $Action, $Direction, $RemoteIPAddress, $RemotePort, $Protocol, $Weight, [bool]$Stateful)
    $script:Adds++
    if ($script:AddFailure -and $Weight -ge 6001) { throw 'Injected partial grant failure.' }
    $script:Acls[$VMNetworkAdapter.Id] += [pscustomobject]@{
        AdapterId = $VMNetworkAdapter.Id
        Action = $Action; Direction = $Direction; RemoteIPAddress = $RemoteIPAddress
        RemotePort = $RemotePort; Protocol = $Protocol; Weight = $Weight
    }
}
function Remove-VMNetworkAdapterExtendedAcl {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($script:RemoveFailure -and $InputObject.Weight -ge 6000 -and
            (-not $script:RemoveFailureAdapter -or $InputObject.AdapterId -eq $script:RemoveFailureAdapter)) { throw 'Injected revocation failure.' }
        if ($InputObject.Weight -ge 5000 -and $InputObject.Weight -le 5099) { $script:BaselineRemovals++ }
        $key = Get-MemLabsInternetAclKey -Rule $InputObject
        $script:Acls[$InputObject.AdapterId] = @($script:Acls[$InputObject.AdapterId] |
            Where-Object { (Get-MemLabsInternetAclKey -Rule $_) -cne $key })
    }
}
function Set-VM {
    [CmdletBinding()]
    param($VM, $AutomaticStartAction, $AutomaticStartDelay)
    if ($PSBoundParameters.ContainsKey('AutomaticStartAction')) { $VM.AutomaticStartAction = $AutomaticStartAction }
    if ($PSBoundParameters.ContainsKey('AutomaticStartDelay')) { $VM.AutomaticStartDelay = $AutomaticStartDelay }
}
function Write-Log {
    param($Message, [switch]$Failure, [switch]$Warning, [switch]$Verbose, [switch]$Success)
    $script:Messages.Enqueue("$Message")
}
function Get-List { param($Type, [switch]$FailOnError); return $script:Inventory }
function Test-VmUsesProxy { param($Vm); return $Vm.useProxy -eq $true }
function Add-ValidationMessage { param($Message, $ReturnObject, [switch]$Failure); $script:ValidationErrors += $Message }
function Add-VmNamePrefix { param($Name, $Prefix); if ($Name.StartsWith("$Prefix")) { return $Name }; return "$Prefix$Name" }
function Resolve-DnsName {
    [CmdletBinding()]
    param($Name, $Type, [switch]$QuickTimeout)
    [pscustomobject]@{ IPAddress = '203.0.113.10' }
    [pscustomobject]@{ IPAddress = '2001:db8::10' }
}
function Stop-VM { throw 'Policy must never stop a VM.' }
function Suspend-VM { throw 'Policy must never pause a VM.' }
function Disconnect-VMNetworkAdapter { throw 'Policy must never disconnect a VM.' }

try {
    $null = New-Item -ItemType Directory -Path $script:FixtureRoot
    $addresses = @(Resolve-MemLabsInternetDestinations -HostNames @('download.example.test'))
    Assert-Policy ($addresses.Count -eq 2) 'Destination resolution lost an address family.'
    Assert-PolicyThrows { Resolve-MemLabsInternetDestinations -HostNames @('*') } 'Wildcard destinations must not become broad permits.'
    Assert-PolicyThrows { Resolve-MemLabsInternetDestinations } 'An empty scope must not grant an exception.'
    function Resolve-MemLabsInternetDestinations { param($HostNames, $Urls); return @('203.0.113.10', '2001:db8::10') }

    $newVM = [pscustomobject]@{ vmName = 'NEW1'; role = 'DomainMember'; operatingSystem = 'Server 2025'; noInternet = $true; useProxy = $false }
    $config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ prefix = ''; domainName = 'lab.test' }; virtualMachines = @($newVM); URLS = @{ DotNet = 'https://download.example.test/net.exe' } }
    Test-ValidVmInternetPolicy -VM $newVM -ConfigObject $config -ReturnObject @{}
    Assert-Policy ($script:ValidationErrors.Count -eq 0) 'A supported new Windows VM without a proxy was rejected.'
    Assert-Policy (-not (Test-ConfigNeedsProxy -ConfigToModify $config)) 'noInternet must not request or auto-add a Proxy VM.'
    $newVM.useProxy = $true
    Test-ValidVmInternetPolicy -VM $newVM -ConfigObject $config -ReturnObject @{}
    Assert-Policy ([bool]($script:ValidationErrors -match 'mutually exclusive')) 'Conflicting proxy and noInternet flags were accepted.'
    $newVM.useProxy = $false
    $newVM.noInternet = 'false'
    $script:ValidationErrors = @()
    Test-ValidVmInternetPolicy -VM $newVM -ConfigObject $config -ReturnObject @{}
    Assert-Policy ([bool]($script:ValidationErrors -match 'JSON boolean')) 'A string false must not opt in or silently default.'
    $newVM.noInternet = $true
    foreach ($role in @('DC', 'BDC', 'StandaloneRootCA', 'OSDClient', 'AADClient', 'InternetClient', 'Proxy', 'DHCPRelay', 'LinuxServer', 'LinuxClient')) {
        $newVM.role = $role
        Assert-Policy (-not (Test-VmNoInternetEligible -VM $newVM)) "$role must remain outside v1."
    }
    $newVM.role = 'DomainMember'
    $script:Inventory = @([pscustomobject]@{ vmName = 'NEW1'; noInternet = $false })
    $script:ValidationErrors = @()
    Test-ValidVmInternetPolicy -VM $newVM -ConfigObject $config -ReturnObject @{}
    Assert-Policy ([bool]($script:ValidationErrors -match 'already deployed')) 'Retrofitting a connected VM must be rejected.'
    $script:Inventory = @()
    $roundTrip = $config | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    Assert-Policy ($roundTrip.virtualMachines[0].noInternet -is [bool] -and $roundTrip.virtualMachines[0].noInternet) 'Saved noInternet intent did not round-trip as a boolean.'
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 2)) 'Domain join must not open an Internet exception.'
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 8)) 'A plain member must not get a ConfigMgr setup exception.'
    $argsForPhase3 = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3
    Assert-Policy ($argsForPhase3.Purpose -eq 'DeploymentPrerequisites' -and $argsForPhase3.Urls.Count -eq 1) 'Prerequisite exceptions must be derived from resolved deployment URLs.'
    $script:CacheFacts.CachedUrls = @($config.URLS.DotNet)
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3)) 'Warm-cache member deployment must not request online access.'
    $config.URLS.VCredist = 'https://download.example.test/vc.exe'
    $mixed = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3
    Assert-Policy ($mixed.Urls.Count -eq 1 -and $mixed.Urls[0] -eq $config.URLS.VCredist) 'Mixed cache must authorize only missing payload URLs.'
    $newVM.role = 'WorkgroupMember'
    $script:CacheFacts.CachedUrls = @()
    $workgroup = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 2
    Assert-Policy ($workgroup.Urls.Count -eq 1 -and $workgroup.Urls[0] -eq $config.URLS.DotNet) 'Cold-cache older workgroup images need .NET authorization in Phase2.'
    $script:CacheFacts.DotNetReady = $true
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 2)) 'Installed .NET must not request a workgroup download exception.'
    $script:CacheFacts.DotNetReady = $false
    $newVM.role = 'DomainMember'
    $newVM | Add-Member -NotePropertyName installRP -NotePropertyValue $true
    $config.URLS.PBIRS = 'https://download.example.test/pbirs.exe'
    $reporting = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 7
    Assert-Policy ($reporting.Urls.Count -eq 1 -and $reporting.Urls[0] -eq $config.URLS.PBIRS) 'Cold-cache reporting installation needs authorization in Phase7, not Phase8.'
    $script:CacheFacts.PbirsReady = $true
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 7)) 'An installed PBIRS configuration must not require an offline rerun download.'
    $script:CacheFacts.PbirsReady = $false
    $newVM.installRP = $false
    $oldUrls = $config.URLS
    $config.URLS = @{}
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3)) 'A zero-payload member must not require online authorization.'
    $config.URLS = $oldUrls
    $newVM | Add-Member -NotePropertyName sqlVersion -NotePropertyValue 'SQL Server 2022'
    $newVM | Add-Member -NotePropertyName thisParams -NotePropertyValue ([pscustomobject]@{
        sqlCUURL = 'https://download.example.test/sqlcu.exe'
        backupSolutionURL = 'https://download.example.test/maintenance.sql'
    })
    $sqlDownloads = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 4
    Assert-Policy ($sqlDownloads.Urls.Count -eq 2) 'Phase4 must authorize the actual SQL CU and maintenance-solution download resources.'
    $newVM.sqlVersion = 'SQL Server 2016'
    $sqlLegacy = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 4
    Assert-Policy ($sqlLegacy.Urls.Count -eq 1 -and $sqlLegacy.Urls[0] -eq $newVM.thisParams.sqlCUURL) 'Pre-2017 SQL must not authorize its skipped backup-solution script.'
    $newVM.sqlVersion = ''
    $newVM.role = 'Primary'
    $config.URLS.ODBC = 'https://download.example.test/odbc.msi'
    $foreign = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 9
    Assert-Policy ($foreign.Purpose -eq 'ConfigMgrSetup' -and $foreign.Urls -contains $config.URLS.ODBC) 'Cross-forest Phase9 must authorize its actual prerequisite resources.'
    $newVM.role = 'DomainMember'
    $newVM | Add-Member -NotePropertyName installSSMS -NotePropertyValue $true
    $config.URLS.SSMS = 'https://download.example.test/ssms.exe'
    $script:CacheFacts.CachedUrls = @($config.URLS.Values)
    $script:CacheFacts.SsmsReady = $true
    Assert-Policy ($null -eq (Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3)) 'An installed SSMS rerun with other cached payloads must not require an online grant.'
    $script:CacheFacts.SsmsReady = $false
    $nativeSsms = Get-VmDeploymentInternetException -VM $newVM -DeployConfig $config -Phase 3
    Assert-Policy ($nativeSsms.Urls -contains $config.URLS.SSMS) 'A missing SSMS installation must retain its native downloader authorization.'
    $newVM.installSSMS = $false
    $script:CacheFacts.CachedUrls = @()

    Initialize-VmNoInternetPolicy -VMName OFFLINE1
    foreach ($adapter in @($script:Adapters | Where-Object VMName -eq OFFLINE1)) {
        Assert-Policy ($script:Acls[$adapter.Id].Count -eq 11) 'Baseline must cover every adapter, including SQLAO heartbeat NICs.'
    }
    Assert-Policy ($script:Acls['connected-primary'].Count -eq 0) 'The connected VM was modified.'
    $before = $script:Adds
    $script:Adapters[0].SwitchName = '192.168.75.0'
    Assert-Policy (Set-VmProxyEnforcement -VMName OFFLINE1) 'Existing coverage could not be reconciled after a subnet move.'
    Assert-Policy ($script:Adds -eq $before) 'Moving a vNIC to another subnet must not detach or regenerate VM-scoped policy.'
    $script:Acls['offline-primary'][0].RemotePort = 9999
    Assert-Policy (Set-VmProxyEnforcement -VMName OFFLINE1) 'Incomplete/mismatched rules were not repaired.'
    Assert-VmNoInternetPolicy -VMName OFFLINE1
    $script:Inventory = @([pscustomobject]@{ vmName = 'OFFLINE1'; role = 'DomainMember'; noInternet = $true; useProxy = $false })
    Assert-Policy (Set-VmProxyEnforcementForAllLabs -VMNames @('OFFLINE1')) 'Proxy reconciliation must retain noInternet rules even with useProxy=false.'
    Assert-VmNoInternetPolicy -VMName OFFLINE1

    $baselineRemovals = $script:BaselineRemovals
    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
    $state = Read-MemLabsInternetState -VMId $handle.VMId
    Assert-Policy ($script:RecoveryVerified -and $state.Status -eq 'ExceptionActive') 'An exception was not durably granted after independent recovery readiness.'
    Assert-Policy ($state.Lease.Rules.Count -eq 4 -and @($state.Lease.Rules | Where-Object { $_.Protocol -ne 'TCP' -or $_.RemotePort -notin @(80, 443) }).Count -eq 0) 'An exception exceeded its destination/TCP-web scope.'
    Assert-Policy ($script:BaselineRemovals -eq $baselineRemovals) 'Opening an exception must never remove baseline denies.'
    Assert-Policy ($script:VMs[0].AutomaticStartAction -eq 'Nothing') 'An exception must establish the host-reboot startup interlock.'
    Assert-PolicyThrows { Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('other.example.test') } 'Nested exceptions must not bypass shared ownership.'
    $handle.LastHeartbeatTick -= 31000
    Update-VmInternetExceptionHeartbeat
    $renewed = Read-MemLabsInternetState -VMId $handle.VMId
    Assert-Policy ($renewed.Lease.DeadlineTick -eq $state.Lease.DeadlineTick) 'Renewal must not reset the hard operation budget.'
    Stop-VmInternetException -Handle $handle
    Assert-VmNoInternetPolicy -VMName OFFLINE1
    Assert-Policy ($script:VMs[0].AutomaticStartAction -eq 'Start' -and $script:VMs[0].AutomaticStartDelay -eq 120) 'Closing an exception did not restore original startup settings.'

    foreach ($failure in @('Expiry', 'Heartbeat', 'Owner', 'HostReboot', 'Budget')) {
        $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
        $state = Read-MemLabsInternetState -VMId $handle.VMId
        switch ($failure) {
            'Expiry' { $state.Lease.ExpiresTick = [Environment]::TickCount64 - 1 }
            'Heartbeat' { $state.Lease.HeartbeatTick = [Environment]::TickCount64 - 50000 }
            'Owner' { $state.Lease.Owner.StartTicks = '1' }
            'HostReboot' { $state.Lease.BootId = 'previous-boot' }
            'Budget' { $state.Lease.DeadlineTick = [Environment]::TickCount64 - 1 }
        }
        Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $handle.VMId) -Value $state
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Repair-MemLabsInternetPolicies
        Assert-VmNoInternetPolicy -VMName OFFLINE1
        Assert-Policy ($timer.Elapsed.TotalSeconds -lt 60) "$failure recovery exceeded the agreed bound."
        Assert-PolicyThrows { Stop-VmInternetException -Handle $handle } "$failure must not be reported as a successful completed operation."
    }

    $script:AddFailure = $true
    Assert-PolicyThrows { Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test') } 'A partial ACL grant must fail.'
    $script:AddFailure = $false
    Assert-VmNoInternetPolicy -VMName OFFLINE1
    Assert-Policy ($script:VMs[0].AutomaticStartAction -eq 'Start') 'A partial grant stranded the startup hold.'

    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Maintenance -HostNames @('download.example.test')
    $script:VMs[0].State = 'Running'
    $script:RemoveFailure = $true
    Assert-PolicyThrows { Stop-VmInternetException -Handle $handle } 'A failed revocation must fail the operation.'
    $degraded = Read-MemLabsInternetState -VMId $handle.VMId
    Assert-Policy ($degraded.Status -eq 'Degraded' -and $degraded.Lease) 'Residual permits must remain durably recorded as degraded.'
    Assert-Policy ($script:VMs[0].State -eq 'Running') 'Failed recovery must keep the VM running.'
    Assert-PolicyThrows { Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test') } 'Degraded enforcement must refuse new exceptions.'
    $script:RemoveFailure = $false
    Repair-MemLabsInternetPolicies
    Assert-VmNoInternetPolicy -VMName OFFLINE1
    Assert-Policy ([bool]($script:Messages -match 'temporary connectivity may remain')) 'Revocation failure was not prominently reported.'

    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
    $statePath = Get-MemLabsInternetStatePath -VMId $handle.VMId
    $goodState = Get-Content -LiteralPath $statePath -Raw
    [IO.File]::WriteAllText($statePath, '{invalid')
    Assert-PolicyThrows { Repair-MemLabsInternetPolicies } 'Unreadable recovery metadata must not report success.'
    Assert-Policy (@($script:Acls['offline-primary'] | Where-Object Weight -ge 6000).Count -eq 0) 'Corrupt metadata left orphan permits installed.'
    [IO.File]::WriteAllText($statePath, $goodState)
    Stop-VmInternetException -Handle $handle
    Assert-Policy ($script:Acls['connected-primary'].Count -eq 0) 'Exception recovery touched a connected neighbor.'

    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
    $validState = Read-MemLabsInternetState -VMId $handle.VMId
    foreach ($invalidRules in @(
            [pscustomobject]@{ Rules = $null },
            [pscustomobject]@{ Rules = @() },
            [pscustomobject]@{ Rules = @($null) },
            [pscustomobject]@{ Rules = @($validState.Lease.Rules[0], $null) },
            [pscustomobject]@{ Rules = 'not-an-acl' }
        )) {
        $bad = $validState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $bad.Lease.Rules = $invalidRules.Rules
        Write-MemLabsInternetJson -Path $statePath -Value $bad
        Assert-PolicyThrows { Read-MemLabsInternetState -VMId $handle.VMId } 'Null/empty/malformed journal rules must fail closed.'
    }
    Write-MemLabsInternetJson -Path $statePath -Value $validState
    Stop-VmInternetException -Handle $handle

    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
    $expired = Read-MemLabsInternetState -VMId $handle.VMId
    $expired.Lease.DeadlineTick = [Environment]::TickCount64 - 1
    Write-MemLabsInternetJson -Path $statePath -Value $expired
    Assert-PolicyThrows { Stop-VmInternetException -Handle $handle } 'Finishing after the hard budget must fail even before the next watchdog sweep.'
    Assert-VmNoInternetPolicy -VMName OFFLINE1

    & {
        $retiredId = [guid]::NewGuid()
        $retiredPath = Get-MemLabsInternetStatePath -VMId $retiredId
        Write-MemLabsInternetJson -Path $retiredPath -Value @{ VMId = "$retiredId" }
        function Write-MemLabsInternetEvent {
            param($State, $EventName, $Message, [switch]$Failure)
            if ($EventName -eq 'Retired') { throw 'Injected unrelated retirement audit failure.' }
            & $script:EventWriter -State $State -EventName $EventName -Message $Message -Failure:$Failure
        }
        $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
        $expired = Read-MemLabsInternetState -VMId $lease.VMId
        $expired.Lease.ExpiresTick = [Environment]::TickCount64 - 1
        Write-MemLabsInternetJson -Path $statePath -Value $expired
        Assert-PolicyThrows { Repair-MemLabsInternetPolicies } 'A retirement failure must be reported.'
        Assert-VmNoInternetPolicy -VMName OFFLINE1
        Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'Expired live neighbor must have been revoked despite retirement failure.'
        Remove-Item -LiteralPath $retiredPath -Force
    }

    & {
        $cacheFolder = Join-Path $script:FixtureRoot 'cache-probe'
        $null = New-Item -ItemType Directory -Path $cacheFolder
        $payload = Join-Path $cacheFolder 'net.exe'
        [IO.File]::WriteAllText($payload, 'verified-cache-payload')
        $url = 'https://download.example.test/net.exe'
        $manifest = @{ files = @{ $url = @{ file = 'net.exe'; size = (Get-Item $payload).Length; sha1 = (Get-FileHash $payload -Algorithm SHA1).Hash } } }
        Write-MemLabsInternetJson -Path (Join-Path $cacheFolder 'manifest.json') -Value $manifest
        function Get-CimInstance {
            [CmdletBinding()]param($ClassName, $Filter)
            [pscustomobject]@{ VolumeName = 'MEMLABSCACHE'; DeviceID = $cacheFolder }
        }
        $probe = Get-MemLabsInternetCacheProbe
        $facts = & $probe -Urls @($url, 'https://download.example.test/missing.exe')
        Assert-Policy ($facts.CachedUrls.Count -eq 1 -and $facts.CachedUrls[0] -eq $url) 'The shipped cache probe must distinguish verified content from a missing URL.'
        [IO.File]::WriteAllText($payload, 'corrupt')
        $facts = & $probe -Urls @($url)
        Assert-Policy ($facts.CachedUrls.Count -eq 0 -and $facts.Issues.Count -eq 1) 'The shipped cache probe must reject and report corrupt cached payloads.'
        & {
            $missing = ''
            function Test-Path {
                [CmdletBinding()]param($LiteralPath, $PathType)
                if ($LiteralPath -like 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\*') {
                    return $LiteralPath -notlike "*$missing" -or -not $missing
                }
                if ($PathType) { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
                else { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
            }
            $healthyAdk = & $probe -Urls @() -Registry32Reader { 'C:\Windows Kits\10\' }
            Assert-Policy $healthyAdk.AdkReady 'The cache probe must accept the same complete ADK directories/registry state as DSC.'
            $missing = 'User State Migration Tool'
            $partialAdk = & $probe -Urls @() -Registry32Reader { 'C:\Windows Kits\10\' }
            Assert-Policy (-not $partialAdk.AdkReady) 'Missing USMT must not suppress an ADK installation/download.'
            $missing = ''
            $missingRegistry = & $probe -Urls @() -Registry32Reader { '' }
            Assert-Policy (-not $missingRegistry.AdkReady) 'Missing Registry32 KitsRoot10 must not be treated as installed ADK.'
        }
    }

    & {
        . (Join-Path $RootPath 'common\Common.Maintenance.ps1')
        function Get-VMNote { param($VMName); [pscustomobject]@{ vmName = $VMName; domain = 'lab.test'; role = 'DomainMember'; noInternet = $true } }
        function ConvertTo-MemLabsVersion { param($Version); [version]$Version }
        function Test-VMFixApplied { param($VMNote, $FixName, $FixVersion); $false }
        function Start-VMIfNotRunning {
            param($VMName, $VMDomain, [switch]$WaitForConnect, [switch]$Quiet)
            $started = $script:VMs[0].State -ne 'Running'
            $script:VMs[0].State = 'Running'
            [pscustomobject]@{ StartedVM = $started; StartFailed = $false; ConnectFailed = $false }
        }
        function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch]$Log, [switch]$Force) }
        function Copy-ItemSafe { param($VmName, $VMDomainName, $Path, $Destination, [switch]$Recurse, [switch]$Container, [switch]$Force); $true }
        function Invoke-VmCommand {
            param($VmName, $VMDomainName, $DisplayName, $ScriptBlock, [switch]$ShowVMSessionError,
                [switch]$CommandReturnsBool, [switch]$AsJob, $TimeoutSeconds, [switch]$FailOnRemoteError)
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $true }
        }
        function New-VMFixScriptBlock { param($FixName, $Body); $Body }
        function Get-VMFixExecutionTimeout { param($FixName); 0 }
        function Get-VMFixResultMarker { throw 'Failed closure must precede fix success/stamping.' }
        function Set-VMNote { throw 'A failed lifecycle must not stamp a fix.' }
        function Start-VMFixesBatched { throw 'An Internet fix must not use a maintenance-wide bypass.' }
        function Start-Sleep { param($Milliseconds, $Seconds) }
        function Stop-VM2 { param($Name, $retryCount, $retrySeconds); throw 'Degraded maintenance must keep its VM running.' }
        $fix = [pscustomobject]@{
            FixName = 'UnitNetworkFix'; FixVersion = '1.0'; AppliesToThisVM = $true
            DependentVMs = @(); ScriptBlock = { $true }
            InternetAccess = [pscustomobject]@{ HostNames = @('download.example.test'); Urls = @(); MaximumMinutes = 20 }
        }
        foreach ($initial in @('Off', 'Running')) {
            $script:VMs[0].State = $initial
            $script:RemoveFailure = $true
            $worked = Start-VMFixes -VMName OFFLINE1 -VMFixes @($fix)
            Assert-Policy (-not $worked -and $script:VMs[0].State -eq 'Running') "Maintenance must keep an initially $initial VM running after failed revocation."
            $script:RemoveFailure = $false
            Repair-MemLabsInternetPolicies
            Assert-VmNoInternetPolicy -VMName OFFLINE1
        }
    }

    $script:VMs += [pscustomobject]@{
        Name = 'OFFLINE2'; Id = [guid]::NewGuid(); State = 'Off'
        AutomaticStartAction = 'Start'; AutomaticStartDelay = 240
        Notes = '{"vmName":"OFFLINE2","role":"DomainMember","operatingSystem":"Server 2025","noInternet":true,"useProxy":false}'
    }
    $script:Adapters += [pscustomobject]@{ Id = 'offline2-primary'; VMName = 'OFFLINE2'; Name = 'Network Adapter'; SwitchName = '10.20.0.0' }
    $script:Acls['offline2-primary'] = @()
    Initialize-VmNoInternetPolicy -VMName OFFLINE2
    $mockText = @(
        foreach ($name in @('Get-MemLabsInternetStateRoot', 'Initialize-MemLabsInternetStateRoot', 'Get-MemLabsInternetBootId',
                'Install-MemLabsInternetRecovery', 'Resolve-MemLabsInternetDestinations', 'Get-VM', 'Get-VMNetworkAdapter',
                'Get-VMNetworkAdapterExtendedAcl', 'Add-VMNetworkAdapterExtendedAcl', 'Remove-VMNetworkAdapterExtendedAcl', 'Set-VM', 'Write-Log')) {
            "function $name { $((Get-Command $name).ScriptBlock.ToString()) }"
        }
    ) -join "`n"
    $sync = [hashtable]::Synchronized(@{ ReleaseA = $false; ReleaseB = $false; Stop = $false })
    $workerArguments = @($RootPath, $script:FixtureRoot, $script:VMs, $script:Adapters, $script:Acls, $script:Messages, $mockText, $sync)
    $parallelWorker = {
        param($Root, $StateRoot, $VMs, $Adapters, $Acls, $Messages, $Mocks, $Sync, $VMName, $Slot, $Release)
        $ErrorActionPreference = 'Stop'
        $script:FixtureRoot = $StateRoot; $script:VMs = $VMs; $script:Adapters = $Adapters
        $script:Acls = $Acls; $script:Messages = $Messages; $script:RemoveFailure = $false
        $script:AddFailure = $false; $script:Adds = 0; $script:BaselineRemovals = 0
        . (Join-Path $Root 'common\Common.Internet.ps1')
        . ([scriptblock]::Create($Mocks))
        $handle = Start-VmInternetException -VMName $VMName -Purpose Download -HostNames @('download.example.test')
        $Sync[$Slot] = $handle
        try {
            while (-not $Sync[$Release]) { Update-VmInternetExceptionHeartbeat; Start-Sleep -Milliseconds 50 }
        }
        finally {
            try { Stop-VmInternetException -Handle $handle }
            catch {
                if ($Sync.ExpectedRevocation -eq $Slot -and $_.Exception.Message -match 'ownership changed|already revoked') {
                    $Sync["Revoked$Slot"] = $true
                }
                else { throw }
            }
        }
    }
    $jobs = @()
    try {
        $jobs += Start-ThreadJob -ScriptBlock $parallelWorker -ArgumentList @($workerArguments + @('OFFLINE1', 'A', 'ReleaseA'))
        $jobs += Start-ThreadJob -ScriptBlock $parallelWorker -ArgumentList @($workerArguments + @('OFFLINE2', 'B', 'ReleaseB'))
        $ready = [Diagnostics.Stopwatch]::StartNew()
        while ((-not $sync.A -or -not $sync.B) -and $ready.Elapsed.TotalSeconds -lt 15) {
            if (@($jobs | Where-Object State -eq 'Failed').Count) { throw (@($jobs | Receive-Job -Keep 2>&1) -join '; ') }
            Start-Sleep -Milliseconds 50
        }
        Assert-Policy ([bool]$sync.A -and [bool]$sync.B -and $sync.A.RunspaceId -ne $sync.B.RunspaceId) 'Parallel maintenance runspaces must independently own different VM leases.'
        Assert-Policy ($null -eq (Get-VmInternetExceptionHandle)) 'Another runspace must not expose its lease to this operation.'
        $beforeHeartbeat = (Read-MemLabsInternetState -VMId $sync.A.VMId).Lease.HeartbeatTick
        Update-VmInternetExceptionHeartbeat -Force
        Assert-Policy ((Read-MemLabsInternetState -VMId $sync.A.VMId).Lease.HeartbeatTick -eq $beforeHeartbeat) 'Unrelated runspaces must not renew another VM owner.'
        $sync.ReleaseA = $true
        $null = Wait-Job -Job $jobs[0] -Timeout 10
        $null = Receive-Job -Job $jobs[0] -ErrorAction Stop
        Assert-VmNoInternetPolicy -VMName OFFLINE1
        Assert-Policy ((Read-MemLabsInternetState -VMId $sync.B.VMId).Status -eq 'ExceptionActive') 'Closing A must not clear, revoke or stop B.'
        $sync.ReleaseB = $true
        $null = Wait-Job -Job $jobs[1] -Timeout 10
        $null = Receive-Job -Job $jobs[1] -ErrorAction Stop
        Assert-VmNoInternetPolicy -VMName OFFLINE2
    }
    finally {
        $sync.ReleaseA = $true; $sync.ReleaseB = $true
        foreach ($job in $jobs) {
            if ($job.State -eq 'Running') { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
    }

    & {
        $writer = (Get-Command Write-MemLabsInternetJson).ScriptBlock
        $script:DiagnosticFailurePath = Join-Path $script:FixtureRoot "$($script:VMs[0].Id).failure.json"
        function Write-MemLabsInternetJson {
            param($Path, $Value)
            if ($Path -eq $script:DiagnosticFailurePath) { throw 'Injected diagnostic write failure.' }
            & $writer -Path $Path -Value $Value
        }
        $sync.B = $null; $sync.ReleaseB = $false; $sync.ExpectedRevocation = 'B'; $sync.RevokedB = $false
        $worker = $null
        $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
        try {
            $worker = Start-ThreadJob -ScriptBlock $parallelWorker -ArgumentList @($workerArguments + @('OFFLINE2', 'B', 'ReleaseB'))
            $ready = [Diagnostics.Stopwatch]::StartNew()
            while (-not $sync.B -and $ready.Elapsed.TotalSeconds -lt 15) {
                if ($worker.State -eq 'Failed') { throw (@($worker | Receive-Job -Keep 2>&1) -join '; ') }
                Start-Sleep -Milliseconds 50
            }
            Assert-Policy ([bool]$sync.B) 'Neighbor lease fixture did not start.'
            foreach ($id in @($lease.VMId, $sync.B.VMId)) {
                $expired = Read-MemLabsInternetState -VMId $id
                $expired.Lease.ExpiresTick = [Environment]::TickCount64 - 1
                Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $id) -Value $expired
            }
            $script:RemoveFailure = $true; $script:RemoveFailureAdapter = 'offline-primary'
            Assert-PolicyThrows { Repair-MemLabsInternetPolicies } 'A VM recovery/diagnostic failure must be reported.'
            Assert-VmNoInternetPolicy -VMName OFFLINE2
            Assert-Policy ((Read-MemLabsInternetState -VMId $lease.VMId).Status -eq 'Degraded') 'The failing VM must retain explicit degraded state.'
            $script:RemoveFailure = $false; $script:RemoveFailureAdapter = $null
            Repair-MemLabsInternetPolicies
            Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'Expired owner must not claim success after recovery.'
        }
        finally {
            $script:RemoveFailure = $false; $script:RemoveFailureAdapter = $null
            $sync.ReleaseB = $true
            if ($worker) {
                $null = Wait-Job -Job $worker -Timeout 10
                if ($worker.State -eq 'Running') { Stop-Job -Job $worker }
                $null = Receive-Job -Job $worker -ErrorAction Stop
                Remove-Job -Job $worker -Force
            }
            $sync.ExpectedRevocation = $null
        }
    }

    & {
        . (Import-PolicyTestFunction -File 'common\Common.HyperV.ps1' -Name 'Set-VMAutomaticStartup')
        function Get-List {
            [CmdletBinding()]param($Type, [switch]$FailOnError)
            [pscustomobject]@{ vmName = 'OFFLINE1'; vmId = $script:VMs[0].Id; noInternet = $true; domain = 'lab.test'; role = 'DomainMember' }
        }
        function Get-VMAutomaticStartupPlan {
            param($VMs)
            [pscustomobject]@{ VMName = 'OFFLINE1'; VMId = $script:VMs[0].Id; AutomaticStartAction = 'Start'; AutomaticStartDelay = 0 }
        }
        function Read-YesOrNoWithTimeout {
            param($Prompt, [switch]$HideHelp, $Default, $timeout)
            $script:PromptLease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
            'y'
        }
        Assert-Policy (-not (Set-VMAutomaticStartup -Prompt)) 'A lease granted during confirmation must make startup reconciliation fail safely.'
        Assert-Policy ($script:VMs[0].AutomaticStartAction -eq 'Nothing') 'The final startup write must not overwrite an exception reboot hold.'
        Stop-VmInternetException -Handle $script:PromptLease
    }

    $handle = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
    $sweeper = $null
    $sync.Stop = $false
    try {
        $sweeper = Start-ThreadJob -ArgumentList $workerArguments -ScriptBlock {
            param($Root, $StateRoot, $VMs, $Adapters, $Acls, $Messages, $Mocks, $Sync)
            $ErrorActionPreference = 'Stop'
            $script:FixtureRoot = $StateRoot; $script:VMs = $VMs; $script:Adapters = $Adapters
            $script:Acls = $Acls; $script:Messages = $Messages; $script:RemoveFailure = $false
            . (Join-Path $Root 'common\Common.Internet.ps1')
            . ([scriptblock]::Create($Mocks))
            while (-not $Sync.Stop) { Repair-MemLabsInternetPolicies; Start-Sleep -Seconds 1 }
        }
        & {
            . (Import-PolicyTestFunction -File 'common\Common.HyperV.ps1' -Name 'Wait-ForHeartbeat')
            $clock = [Diagnostics.Stopwatch]::StartNew()
            function Get-VM2 {
                param($Name)
                [pscustomobject]@{ Heartbeat = $(if ($clock.Elapsed.TotalSeconds -ge 47) { 'OkApplicationsHealthy' } else { 'NoContact' }) }
            }
            Assert-Policy (Wait-ForHeartbeat -VMName OFFLINE1 -TimeoutSeconds 60 -PollSeconds 5) 'A healthy reboot longer than the heartbeat-loss threshold must complete.'
        }
        Assert-Policy ((Read-MemLabsInternetState -VMId $handle.VMId).Status -eq 'ExceptionActive') 'Concurrent recovery must not revoke a lease maintained through a healthy long host wait.'
        Stop-VmInternetException -Handle $handle
    }
    finally {
        $sync.Stop = $true
        if ($sweeper) {
            $null = Wait-Job -Job $sweeper -Timeout 5
            if ($sweeper.State -eq 'Running') { Stop-Job -Job $sweeper }
            $null = Receive-Job -Job $sweeper -ErrorAction Stop
            Remove-Job -Job $sweeper -Force
        }
    }

    & {
        $script:Task = $null
        $script:Registers = 0
        $script:BadReady = $false
        $script:Signature = Get-MemLabsInternetRuntimeSignature -Library (Join-Path $RootPath 'common\Common.Internet.ps1') -EntryPoint (Join-Path $RootPath 'tools\Repair-VmInternetPolicy.ps1')
        function Get-ScheduledTask { [CmdletBinding()]param($TaskName); $script:Task }
        function New-ScheduledTaskAction { param($Execute, $Argument); [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
        function New-ScheduledTaskTrigger { param([switch]$AtStartup); [pscustomobject]@{ CimClass = @{ CimClassName = 'MSFT_TaskBootTrigger' }; Enabled = $true } }
        function New-ScheduledTaskSettingsSet {
            param($ExecutionTimeLimit, $RestartCount, $RestartInterval, $MultipleInstances,
                [switch]$StartWhenAvailable, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
            [pscustomobject]@{
                ExecutionTimeLimit = [Xml.XmlConvert]::ToString($ExecutionTimeLimit)
                RestartInterval = [Xml.XmlConvert]::ToString($RestartInterval)
                RestartCount = $RestartCount; MultipleInstances = $MultipleInstances
                Enabled = $true; AllowDemandStart = $true; StartWhenAvailable = $StartWhenAvailable.IsPresent
                DisallowStartIfOnBatteries = -not $AllowStartIfOnBatteries; StopIfGoingOnBatteries = -not $DontStopIfGoingOnBatteries
            }
        }
        function Register-ScheduledTask {
            [CmdletBinding()]param($TaskName, $Action, $Trigger, $Settings, $User, $RunLevel, [switch]$Force)
            $script:Registers++
            $script:Task = [pscustomobject]@{
                Actions = @($Action); Triggers = @($Trigger); Settings = $Settings; State = 'Ready'
                Principal = [pscustomobject]@{ UserId = $User; RunLevel = $RunLevel; LogonType = 'ServiceAccount' }
            }
        }
        function Start-ScheduledTask { [CmdletBinding()]param($TaskName) }
        function Stop-ScheduledTask { [CmdletBinding()]param($TaskName) }
        function Start-Sleep { param($Seconds); throw 'Recovery readiness was not accepted.' }
        function Test-Path {
            [CmdletBinding()]param($LiteralPath, $Path, $PathType)
            $p = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($p -eq (Join-Path $script:FixtureRoot 'recovery.ready.json')) {
                $owner = Get-Process -Id $PID
                Write-MemLabsInternetJson -Path $p -Value @{
                    Signature = $(if ($script:BadReady) { 'wrong' } else { $script:Signature })
                    BootId = 'test-boot'; Tick = [Environment]::TickCount64
                    Owner = @{ Id = $PID; StartTicks = $owner.StartTime.ToUniversalTime().Ticks.ToString() }
                }
            }
            if ($PathType) { Microsoft.PowerShell.Management\Test-Path -LiteralPath $p -PathType $PathType }
            else { Microsoft.PowerShell.Management\Test-Path -LiteralPath $p }
        }
        & $script:RecoveryInstaller
        Assert-Policy ($script:Registers -eq 1) 'The shipped installer must register a verified recovery task.'
        foreach ($defect in @('Principal', 'Trigger', 'Disabled', 'Battery', 'Restart', 'ExecutionLimit')) {
            switch ($defect) {
                'Principal' { $script:Task.Principal.UserId = 'NotSystem' }
                'Trigger' { $script:Task.Triggers = @() }
                'Disabled' { $script:Task.Settings.Enabled = $false }
                'Battery' { $script:Task.Settings.DisallowStartIfOnBatteries = $true }
                'Restart' { $script:Task.Settings.RestartCount = 0 }
                'ExecutionLimit' { $script:Task.Settings.ExecutionTimeLimit = 'PT1M' }
            }
            $before = $script:Registers
            & $script:RecoveryInstaller
            Assert-Policy ($script:Registers -eq $before + 1) "Existing $defect task defect must be repaired even with matching action bytes."
        }
        $script:BadReady = $true
        Assert-PolicyThrows { & $script:RecoveryInstaller } 'A matching task without fresh matching recovery readiness must not authorize access.'
    }

    & {
        . (Import-PolicyTestFunction -File 'common\Common.HyperV.ps1' -Name 'Stop-VM2')
        $script:GracefulWaits = 0; $script:HardStops = 0
        function Get-VM2 { param($Name, [switch]$Fallback); $script:VMs[0] }
        function Stop-VM {
            [CmdletBinding()]param($VM, [switch]$Force, [switch]$AsJob, [switch]$TurnOff)
            if ($TurnOff) { $script:HardStops++; throw 'Hard power-off after lease failure is forbidden.' }
            [pscustomobject]@{ State = 'Failed'; ChildJobs = @([pscustomobject]@{ JobStateInfo = @{ Reason = @{ Message = 'Graceful attempt failed' } } }) }
        }
        function Wait-MemLabsInternetJob {
            param($Job, $TimeoutSeconds)
            $script:GracefulWaits++
            if ($script:GracefulWaits -eq 2) {
                $lease = Get-VmInternetExceptionHandle
                $state = Read-MemLabsInternetState -VMId $lease.VMId
                $state.Status = 'Degraded'
                Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $lease.VMId) -Value $state
                throw 'Internet lease degraded during final graceful wait.'
            }
        }
        function Remove-CompletedHyperVJob { param($Job, $Context) }
        function Write-Exception { param($ExceptionInfo) }
        function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch]$Force) }
        function Start-Sleep { param($Seconds) }
        $script:VMs[0].State = 'Running'
        $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
        $stopped = Stop-VM2 -Name OFFLINE1 -Passthru
        Assert-Policy ($script:GracefulWaits -eq 2 -and (Read-MemLabsInternetState -VMId $lease.VMId).Status -eq 'Degraded') 'The shutdown fixture must reach degradation during the final graceful wait.'
        Assert-Policy (-not $stopped -and $script:HardStops -eq 0 -and $script:VMs[0].State -eq 'Running') 'A lost/degraded lease must not enter hard-stop escalation after the final graceful attempt.'
        Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'Degraded shutdown must fail its lease closure.'
        Repair-MemLabsInternetPolicies
        Assert-VmNoInternetPolicy -VMName OFFLINE1
    }

    & {
        foreach ($name in @('Invoke-VmCommand', 'Get-VmPipelineFailureAutopsy', 'Invoke-VmSessionCredentialDiagnostics')) {
            . (Import-PolicyTestFunction -File 'Common.ps1' -Name $name)
        }
        $Common = [pscustomobject]@{ LocalAdmin = [pscredential]::Empty }
        $script:Dispatches = [Collections.Generic.List[bool]]::new()
        $script:Evictions = [Collections.Generic.List[object]]::new()
        function Get-VmSession { param($VmName, $VmDomainName, $VmDomainAccount, $ShowVMSessionError, $MaxRetries, $LocalOnly, $RequireDomainIdentity, $Diagnostics, $Quiet); $script:ProbeSession }
        function Enter-VmSessionInflight { param($Session, $DisplayName) }
        function Exit-VmSessionInflight { param($Token) }
        function Set-VmSessionPipelineEvent { param($Session, $Kind, $Op) }
        function Write-VmJobLedger { param($Op, $Job, $VmName, $DisplayName, $Detail) }
        function Get-VmHostSideDiag { param($VmName); 'mock host diagnostic' }
        function Get-VmSessionConcurrencyDiag { param($Session, $SelfToken, $OutputWasNull); 'mock concurrency diagnostic' }
        function Invoke-Command {
            [CmdletBinding()]param($Session, $ScriptBlock, [switch]$AsJob)
            $script:Dispatches.Add($AsJob.IsPresent)
            if (-not $AsJob) { throw 'Unbounded synchronous guest dispatch during a lease.' }
            $probe = $ScriptBlock.ToString().Trim() -eq '1'
            if ($probe) { $script:ProbeAttempts++ }
            $state = if (($probe -and $script:ProbeMode -eq 'Stall') -or (-not $probe -and $script:ProbeMode -eq 'PrimaryLoss')) { 'Running' } else { 'Completed' }
            $errors = @()
            if ($probe -and $script:ProbeMode -eq 'Transient' -and $script:ProbeAttempts -eq 1) { $errors = @('creating the pipeline') }
            $job = [pscustomobject]@{
                State = $state; IsProbe = $probe; StopRequested = $false
                ChildJobs = @([pscustomobject]@{ Error = $errors })
            }
            $job | Add-Member -MemberType ScriptMethod -Name StopJobAsync -Value { $this.StopRequested = $true }
            if (-not $probe -and $script:ProbeMode -eq 'PrimaryLoss') {
                $current = Get-VmInternetExceptionHandle
                $policy = Read-MemLabsInternetState -VMId $current.VMId
                $policy.Status = 'Degraded'
                Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $current.VMId) -Value $policy
            }
            return $job
        }
        function Wait-Job {
            [CmdletBinding()]param([Parameter(ValueFromPipeline)]$Job, $Timeout)
            process {
                if ($Job.State -eq 'Completed') { return $Job }
                Start-Sleep -Milliseconds 100
            }
        }
        function Receive-Job {
            [CmdletBinding()]param($Job)
            if ($Job.IsProbe) {
                if ($script:ProbeMode -eq 'Expiry') {
                    $current = Get-VmInternetExceptionHandle
                    $state = Read-MemLabsInternetState -VMId $current.VMId
                    $state.Lease.DeadlineTick = [Environment]::TickCount64 - 1
                    Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $current.VMId) -Value $state
                }
                return 1
            }
            return 'primary-result'
        }
        function Remove-Job { [CmdletBinding()]param($Job, [switch]$Force); if ($Job.State -ne 'Completed') { throw 'Must not dispose an in-flight readiness job.' } }
        function Remove-VmSessionFromCache {
            param($VmName, [switch]$LeakSession, $AbandonedJob)
            $script:Evictions.Add([pscustomobject]@{ Leak = $LeakSession.IsPresent; Job = $AbandonedJob })
            $global:ps_cache.Clear()
        }
        function Add-OrphanRunspace { param($Runspace, $Session, $Job, $Reason, $VmName); $script:Evictions.Add([pscustomobject]@{ Leak = $true; Job = $Job }) }
        $previousCache = Get-Variable ps_cache -Scope Global -ErrorAction SilentlyContinue
        $previousCacheValue = if ($previousCache) { $previousCache.Value } else { $null }
        $previousTimeline = Get-Variable ps_pipelineTimeline -Scope Global -ErrorAction SilentlyContinue
        $previousTimelineValue = if ($previousTimeline) { $previousTimeline.Value } else { $null }
        $global:ps_pipelineTimeline = [hashtable]::Synchronized(@{})
        try {
            foreach ($mode in @('Healthy', 'Transient', 'Stall', 'Expiry')) {
                $script:ProbeMode = $mode; $script:ProbeAttempts = 0
                $script:Dispatches.Clear(); $script:Evictions.Clear()
                $script:ProbeSession = [pscustomobject]@{
                    Runspace = [pscustomobject]@{ RunspaceStateInfo = @{ State = 'Opened' }; RunspaceAvailability = 'Available' }
                    Availability = 'Available'; State = 'Opened'; _OwnerRunspace = [object]::new()
                }
                $global:ps_cache = @{ 'OFFLINE1-test' = $script:ProbeSession }
                $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
                $deadline = (Read-MemLabsInternetState -VMId $lease.VMId).Lease.DeadlineTick
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $outcome = Invoke-VmCommand -VmName OFFLINE1 -VmDomainName lab.test -ScriptBlock { 'primary' } -SuppressLog
                Assert-Policy ($script:Dispatches.Count -ge 2 -and -not $script:Dispatches.Contains($false)) "$mode must bound every primary and nested guest dispatch."
                Assert-Policy ($timer.Elapsed.TotalSeconds -lt 10) "$mode readiness must not turn a five-second retry deadline into an unbounded guest call."
                if ($mode -in @('Healthy', 'Transient')) {
                    Assert-Policy ($outcome.CommandResult -and -not $outcome.ScriptBlockFailed) "$mode readiness should preserve successful primary-command semantics."
                    Assert-Policy ((Read-MemLabsInternetState -VMId $lease.VMId).Lease.DeadlineTick -eq $deadline) 'Readiness retries must not reset the lease hard deadline.'
                    $script:Dispatches.Clear()
                    $autopsy = Get-VmPipelineFailureAutopsy -Session $script:ProbeSession -VmName OFFLINE1 -Errors @()
                    Assert-Policy ($script:Dispatches.Count -eq 1 -and -not $script:Dispatches.Contains($false) -and $autopsy -match 'postFailTrivial=\[ok') "Leased failure-autopsy probes must use the same bounded guest path: $autopsy"
                    $script:Dispatches.Clear()
                    $diagnostics = @(Invoke-VmSessionCredentialDiagnostics -VmName OFFLINE1 -VmId $lease.VMId -VmDomainName lab.test `
                        -RequestedAccount vmbuildadmin -ConnectOperation { throw 'Optional credential connect must not run inside a lease.' })
                    Assert-Policy ($diagnostics.Count -eq 0 -and $script:Dispatches.Count -eq 0) 'Optional alternate-credential diagnostics must not introduce another unbounded guest path.'
                    Stop-VmInternetException -Handle $lease
                }
                else {
                    Assert-Policy (-not $outcome.CommandResult -and $outcome.ScriptBlockFailed -and $outcome.ErrorDetails) "$mode readiness must report failure, not successful primary output."
                    if ($mode -eq 'Stall') {
                        Assert-Policy ($script:Evictions.Count -eq 1 -and $script:Evictions[0].Leak -and
                            $script:Evictions[0].Job.StopRequested) 'A stalled nested probe must be retained with its session, never disposed live.'
                        Stop-VmInternetException -Handle $lease
                    }
                    else { Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'An expired nested probe must retain failed-operation semantics through closure.' }
                }
                Assert-VmNoInternetPolicy -VMName OFFLINE1
            }
            foreach ($poll in @($false, $true)) {
                $script:ProbeMode = 'PrimaryLoss'
                $script:Dispatches.Clear(); $script:Evictions.Clear()
                $script:ProbeSession = [pscustomobject]@{
                    Runspace = [pscustomobject]@{ RunspaceStateInfo = @{ State = 'Opened' }; RunspaceAvailability = 'Available' }
                    Availability = 'Available'; State = 'Opened'; _OwnerRunspace = [object]::new()
                }
                $global:ps_cache = @{ 'OFFLINE1-test' = $script:ProbeSession }
                $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
                $outcome = Invoke-VmCommand -VmName OFFLINE1 -VmDomainName lab.test -ScriptBlock { 'primary' } -SuppressLog -PollProgress:$poll
                Assert-Policy (-not $outcome.CommandResult -and $outcome.ScriptBlockFailed) 'Both primary polling modes must expose lease-loss failure.'
                Assert-Policy ($script:Evictions.Count -eq 1 -and $script:Evictions[0].Job.StopRequested -and $global:ps_cache.Count -eq 0) 'A primary wait exception must asynchronously stop and retain the live transport before worker cleanup.'
                Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'Primary wait degradation must not return successful lease closure.'
                Repair-MemLabsInternetPolicies
            }
        }
        finally {
            if ($previousCache) { $global:ps_cache = $previousCacheValue }
            else { Remove-Variable ps_cache -Scope Global -ErrorAction SilentlyContinue }
            if ($previousTimeline) { $global:ps_pipelineTimeline = $previousTimelineValue }
            else { Remove-Variable ps_pipelineTimeline -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    & {
        . (Import-PolicyTestFunction -File 'Common.ps1' -Name 'New-PSSessionWithTimeout')
        $script:Connections = [Collections.Generic.List[object]]::new()
        function Add-OrphanRunspace { param($Runspace, $PowerShell, $Reason, $VmName); $script:Connections.Add([pscustomobject]@{ Runspace = $Runspace; PowerShell = $PowerShell }) }
        function Wait-MemLabsInternetHandle {
            param($Handle, $TimeoutSeconds)
            $lease = Get-VmInternetExceptionHandle
            $state = Read-MemLabsInternetState -VMId $lease.VMId
            $state.Status = 'Degraded'
            Write-MemLabsInternetJson -Path (Get-MemLabsInternetStatePath -VMId $lease.VMId) -Value $state
            throw 'Planted connection-wait lease loss.'
        }
        $lease = Start-VmInternetException -VMName OFFLINE1 -Purpose Download -HostNames @('download.example.test')
        try {
            Assert-PolicyThrows {
                New-PSSessionWithTimeout -Name OFFLINE1 -VMId $script:VMs[0].Id -Credential ([pscredential]::Empty) `
                    -ConnectOperation { param($Name, $VMId, $Cred); Start-Sleep -Seconds 60 }
            } 'A failed leased connection wait must propagate failure.'
            Assert-Policy ($script:Connections.Count -eq 1 -and $script:Connections[0].Runspace.RunspaceStateInfo.State -eq 'Opened') 'A launched connection interrupted by lease loss must be tracked, not silently leaked or disposed live.'
            Assert-PolicyThrows { Stop-VmInternetException -Handle $lease } 'Connection-wait degradation must not report successful closure.'
            Repair-MemLabsInternetPolicies
        }
        finally {
            foreach ($connection in $script:Connections) {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while ($connection.PowerShell.InvocationStateInfo.State -in @('Running', 'Stopping') -and $watch.Elapsed.TotalSeconds -lt 5) {
                    Start-Sleep -Milliseconds 100
                }
                Assert-Policy ($connection.PowerShell.InvocationStateInfo.State -notin @('Running', 'Stopping')) 'The test connection worker did not acknowledge asynchronous cancellation.'
                $connection.PowerShell.Dispose(); $connection.Runspace.Dispose()
            }
        }
    }

    $source = Get-Content -LiteralPath (Join-Path $RootPath 'Common.ps1') -Raw
    Assert-Policy ($source.IndexOf('Initialize-VmNoInternetPolicy -VMName $VmName') -lt $source.IndexOf('$started = Start-VM2 -Name $VmName')) 'NoInternet baseline must be initialized before the first VM start.'
    $errors = $null
    $scriptAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'), [ref]$null, [ref]$errors)
    $create = @($scriptAst.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$global:VM_Create' }, $true))
    $configure = @($scriptAst.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$global:VM_Config' }, $true))
    Assert-Policy ($create.Count -eq 1 -and $create[0].Extent.Text -notmatch 'Assert-VmNoInternetPolicy') 'Creation must not require policy state before the VM exists.'
    Assert-Policy ($configure.Count -eq 1 -and $configure[0].Extent.Text -match 'Assert-VmNoInternetPolicy') 'Phase resumes must verify persisted noInternet enforcement.'
    Assert-Policy ($configure[0].Extent.Text.IndexOf('Start-VmInternetException @internetExceptionArguments') -lt
        $configure[0].Extent.Text.IndexOf('ScriptBlock $DSC_ClearStatus')) 'Exceptions must be ready before the node publishes its DSC ready token.'
    Write-Host "PASS: $script:Checks noInternet checks; Hyper-V, scheduled tasks, DNS and downloads mocked. No live lab changes."
}
finally {
    $key = Get-MemLabsInternetLeaseKey
    if ($key) { [AppDomain]::CurrentDomain.SetData($key, $null) }
    if (Test-Path -LiteralPath $script:FixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $script:FixtureRoot -Recurse -Force
    }
}
