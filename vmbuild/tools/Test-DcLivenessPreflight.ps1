<#
.SYNOPSIS
    Regresses DC liveness and preflight failure handling across partial-config reruns.

.DESCRIPTION
    A partial deployment rewrote an existing DC's persisted network, then generated a
    Phase 2 configuration that moved the guest to an impossible subnet. An existing DC's
    attached Hyper-V switch is authoritative even while the guest is off: switch X.Y.Z.0
    means DC X.Y.Z.1 and gateway X.Y.Z.200. Notes are fallback evidence, never config input.

    Functions and the New-Lab selection block are lifted from the shipped files so these
    fixtures cannot drift into testing copies of the production logic.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-DcEqual {
    param($Expected, $Actual, [string]$What)

    $passed = ("$Expected" -eq "$Actual")
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Get-DcSourceAst {
    param([string]$RelativePath)

    $path = Join-Path $RootPath $RelativePath
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $path).Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
        throw "$RelativePath has $(@($parseErrors).Count) parse error(s): $($parseErrors -join '; ')"
    }
    return $ast
}

function Get-DcSourceFunctionText {
    param(
        [System.Management.Automation.Language.ScriptBlockAst]$Ast,
        [string]$Name
    )

    $node = $Ast.Find({
            param($candidate)
            $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
        }, $true)
    if (-not $node) { throw "Function '$Name' was not found in the source." }
        return $node.Extent.Text
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Message,
        [switch]$Warning,
        [switch]$LogOnly,
        [switch]$Failure,
        [switch]$Success,
        [switch]$OutputStream,
        [switch]$Activity
    )
}

function Get-VM2 {
    [CmdletBinding()]
    param([string]$Name, [switch]$Fallback)
    if ($script:VmExists) { return [pscustomobject]@{ Name = $Name; State = $script:VmState } }
    return $null
}

function Get-VMIntegrationService {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { return [pscustomobject]@{ Name = 'Heartbeat'; Enabled = $true; PrimaryStatusDescription = 'OK' } }
}

function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$InputObject,
        [string]$VMName
    )
    process { return $script:Adapters }
}

function Get-VMNote {
    [CmdletBinding()]
    param([string]$VMName)
    if ($script:NoteMode -eq 'Responsive') { return $script:ResponsiveNote }
    return $script:ExistingNote
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs,
        [int]$Retries,
        [int]$RetryDelayMs
    )
    $script:TcpCalls.Add($ComputerName)
    return $ComputerName -eq $script:ResponsiveIp
}

$hyperVAst = Get-DcSourceAst 'common\Common.HyperV.ps1'
. ([scriptblock]::Create((Get-DcSourceFunctionText -Ast $hyperVAst -Name 'Get-VmDomainNetworkFromSwitch')))
. ([scriptblock]::Create((Get-DcSourceFunctionText -Ast $hyperVAst -Name 'Test-VmResponsive')))

$scriptBlocksAst = Get-DcSourceAst 'common\Common.ScriptBlocks.ps1'
$vmCreateCompletionCandidates = @($scriptBlocksAst.FindAll({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.IfStatementAst] -and
        $candidate.Clauses.Count -eq 1 -and
        $candidate.Clauses[0].Item1.Extent.Text -eq '$createVM' -and
        $candidate.Extent.Text -match 'VM Creation completed successfully' -and
        $candidate.Extent.Text -match 'Existing VM Preparation completed successfully'
    }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1)
$vmCreateCompletion = $vmCreateCompletionCandidates[0]
if (-not $vmCreateCompletion) { throw 'VM_Create completion branch was not found.' }
$newVmCompletion = $vmCreateCompletion.Clauses[0].Item2.Extent.Text
$existingVmCompletion = $vmCreateCompletion.ElseClause.Extent.Text
Assert-DcEqual $true ($newVmCompletion -match 'New-VmNote') `
    'Newly created Windows VM receives its completion note'
Assert-DcEqual $false ($existingVmCompletion -match 'New-VmNote') `
    'Phase 0 hidden existing VM does not rewrite its note'

$script:VmExists = $true
$script:VmState = 'Off'
$script:Adapters = @([pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @() })
Assert-DcEqual '192.168.110.0' (Get-VmDomainNetworkFromSwitch -VmName 'PT1-DC1') `
    'Powered-off DC network resolves from its attached switch'

$script:Adapters = @(
    [pscustomobject]@{ SwitchName = 'ClusterV2'; IPAddresses = @() },
    [pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @() }
)
Assert-DcEqual '192.168.110.0' (Get-VmDomainNetworkFromSwitch -VmName 'PT1-DC1') `
    'Cluster NIC is excluded from the DC domain-switch source'

$script:Adapters = @(
    [pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @() },
    [pscustomobject]@{ SwitchName = '192.168.111.0'; IPAddresses = @() }
)
$ambiguousSwitchThrew = $false
try { $null = Get-VmDomainNetworkFromSwitch -VmName 'PT1-DC1' }
catch { $ambiguousSwitchThrew = $true }
Assert-DcEqual $true $ambiguousSwitchThrew 'Multiple IPv4 domain switches are rejected as ambiguous'

$script:VmState = 'Running'
$script:NoteMode = 'Responsive'
$script:ResponsiveNote = [pscustomobject]@{ AssignedIP = '192.168.111.1'; LastKnownIP = '192.168.111.1' }
$script:Adapters = @([pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @('192.168.110.1') })
$script:ResponsiveIp = '192.168.110.1'
$script:TcpCalls = New-Object System.Collections.Generic.List[string]
$responsive = Test-VmResponsive -VmName 'PT1-DC1' -TimeoutSeconds 15
Assert-DcEqual $true $responsive 'Live Hyper-V address is tried before stale note addresses'
Assert-DcEqual '192.168.110.1' ($script:TcpCalls -join ',') 'Successful live address avoids note fallbacks'

$script:ResponsiveNote = [pscustomobject]@{ AssignedIP = '192.168.110.1'; LastKnownIP = '192.168.110.1' }
$script:Adapters = @([pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @() })
$script:ResponsiveIp = '192.168.110.1'
$script:TcpCalls = New-Object System.Collections.Generic.List[string]
$responsive = Test-VmResponsive -VmName 'PT1-DC1' -TimeoutSeconds 15
Assert-DcEqual $true $responsive 'VM-note address remains available as a liveness fallback'
Assert-DcEqual '192.168.110.1' ($script:TcpCalls -join ',') 'Note fallback runs only without a live address'

$script:ResponsiveNote = [pscustomobject]@{ AssignedIP = '192.168.110.1'; LastKnownIP = '192.168.110.1' }
$script:Adapters = @([pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @('192.168.111.1') })
$script:ResponsiveIp = '192.168.120.1'
$script:TcpCalls = New-Object System.Collections.Generic.List[string]
$responsive = Test-VmResponsive -VmName 'PT1-DC1' -TimeoutSeconds 15
Assert-DcEqual $false $responsive 'All candidate addresses failing remains unresponsive'
Assert-DcEqual '192.168.111.1,192.168.110.1' ($script:TcpCalls -join ',') 'A genuine failure exhausts live then fallback candidates'

$commonAst = Get-DcSourceAst 'Common.ps1'
. ([scriptblock]::Create((Get-DcSourceFunctionText -Ast $commonAst -Name 'New-VmNote')))

function Set-VMNote {
    param([string]$VmName, $VmNote, [switch]$Force)
    $script:SavedNote = $VmNote
}

$global:Common = [pscustomobject]@{ MemLabsVersion = 'test' }
$script:NoteMode = 'Existing'
$script:ExistingNote = [pscustomobject]@{ network = '192.168.110.0'; lastPhaseComplete = 11 }
$script:SavedNote = $null
$dc = [pscustomobject]@{
    vmName         = 'PT1-DC1'
    role           = 'DC'
    operatingSystem = 'Server 2022'
    AssignedIP     = '192.168.110.1'
}
$deployConfig = [pscustomobject]@{
    virtualMachines = @($dc)
    vmOptions        = [pscustomobject]@{
        network           = '192.168.111.0'
        domainName        = 'pstest1.com'
        domainNetBiosName = 'PT1'
        adminName         = 'admin'
        prefix            = 'PT1-'
    }
    pkiOptions       = $null
    domainDefaults   = $null
    cmOptions        = $null
}
New-VmNote -VmName 'PT1-DC1' -DeployConfig $deployConfig -Successful $true -Phase 0
Assert-DcEqual '192.168.110.0' $script:SavedNote.network 'Partial config preserves an existing VM network'

$dc | Add-Member -MemberType NoteProperty -Name network -Value '192.168.112.0'
New-VmNote -VmName 'PT1-DC1' -DeployConfig $deployConfig -Successful $true -Phase 0
Assert-DcEqual '192.168.110.0' $script:SavedNote.network 'Explicit config cannot move an existing DC to another network'

$genConfigAst = Get-DcSourceAst 'common\Common.GenConfig.ps1'
$roleSwitch = $genConfigAst.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.SwitchStatementAst] -and
        $candidate.Extent.Text -match 'DCIPAddress'
    }, $true)
$dcClause = $roleSwitch.Clauses | Where-Object { $_.Item1.Extent.Text -eq '"DC"' } | Select-Object -First 1
if (-not $dcClause) { throw 'ConvertTo-DeployConfigEx DC clause was not found.' }
$dcClauseText = $dcClause.Item2.Extent.Text
$dcClauseText = $dcClauseText.Substring(1, $dcClauseText.Length - 2)

function Get-List2 { param($DeployConfig) return @() }

function Invoke-DcProducerCase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Locals are consumed by the source-lifted DC producer block.')]
    param(
        [bool]$VmExists,
        [string[]]$AttachedSwitch,
        [string]$ConfigNetwork,
        [string]$ExpectedIP,
        [string]$ExpectedGateway,
        [bool]$ShouldThrow = $false,
        [string]$What
    )

    $script:VmExists = $VmExists
    $script:VmState = 'Off'
    $script:Adapters = @($AttachedSwitch | Where-Object { $_ } |
        ForEach-Object { [pscustomobject]@{ SwitchName = $_; IPAddresses = @() } })
    $thisVM = [pscustomobject]@{ vmName = 'PT1-DC1'; role = 'DC'; hidden = $VmExists }
    $deployConfig = [pscustomobject]@{
        virtualMachines = @($thisVM)
        vmOptions        = [pscustomobject]@{ DomainName = 'pstest1.com'; network = $ConfigNetwork }
        pkiOptions       = $null
    }
    $thisParams = [pscustomobject]@{}
    $accountLists = [pscustomobject]@{
        LocalAdminAccounts = @(); DomainAccounts = @(); DomainAdmins = @(); SchemaAdmins = @()
    }
    $SQLAO = @()
    $DomainName = 'pstest1.com'
    $threw = $false
    try { . ([scriptblock]::Create($dcClauseText)) }
    catch { $threw = $true }
    Assert-DcEqual $ShouldThrow $threw "$What failure contract"
    if ($threw) { return }
    Assert-DcEqual $ExpectedIP $thisParams.DCIPAddress "$What IP"
    Assert-DcEqual $ExpectedGateway $thisParams.DCDefaultGateway "$What gateway"
}

Invoke-DcProducerCase -VmExists $true -AttachedSwitch '192.168.110.0' -ConfigNetwork '192.168.111.0' `
    -ExpectedIP '192.168.110.1' -ExpectedGateway '192.168.110.200' `
    -What 'Off existing DC ignores conflicting config and emits switch-derived'
Invoke-DcProducerCase -VmExists $false -AttachedSwitch '' -ConfigNetwork '192.168.111.0' `
    -ExpectedIP '192.168.111.1' -ExpectedGateway '192.168.111.200' `
    -What 'New DC initializes from requested config'
Invoke-DcProducerCase -VmExists $true -AttachedSwitch @() -ConfigNetwork '192.168.111.0' `
    -ShouldThrow $true -What 'Existing DC with no domain switch'
Invoke-DcProducerCase -VmExists $true -AttachedSwitch @('192.168.110.0', '192.168.111.0') `
    -ConfigNetwork '192.168.112.0' -ShouldThrow $true -What 'Existing DC with ambiguous domain switches'

$newLabAst = Get-DcSourceAst 'New-Lab.ps1'
$dnsIf = $newLabAst.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.IfStatementAst] -and
        $candidate.Extent.Text -match '^if \(\$existingDC\)' -and
        $candidate.Extent.Text -match 'Get-VmDomainNetworkFromSwitch' -and
        $candidate.Extent.Text -match '\$DNSServer'
    }, $true)
if (-not $dnsIf) { throw 'New-Lab DC DNS selection block was not found.' }
$dnsSelection = [scriptblock]::Create($dnsIf.Extent.Text)

function Invoke-NewLabDnsCase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Locals are consumed by the source-lifted New-Lab block.')]
    param(
        [bool]$VmExists,
        [string]$Expected,
        [string]$What
    )

    $script:Adapters = @([pscustomobject]@{ SwitchName = '192.168.110.0'; IPAddresses = @() })
    $existingDC = if ($VmExists) { [pscustomobject]@{ Name = 'PT1-DC1'; State = 'Off' } } else { $null }
    $DC = [pscustomobject]@{ VmName = 'PT1-DC1'; Network = '192.168.111.0' }
    $deployConfig = [pscustomobject]@{ vmOptions = [pscustomobject]@{ network = '192.168.111.0' } }
    $DNSServer = $null
    . $dnsSelection
    Assert-DcEqual $Expected $DNSServer $What
}

Invoke-NewLabDnsCase -VmExists $true -Expected '192.168.110.1' `
    -What 'Existing DC DNS address comes from its attached switch'
Invoke-NewLabDnsCase -VmExists $false -Expected '192.168.111.1' `
    -What 'New DC DNS address comes from its requested network'

$defaultDhcpCall = $newLabAst.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.CommandAst] -and
        $candidate.GetCommandName() -eq 'Add-SwitchAndDhcp' -and
        $candidate.Extent.Text -match '-NetworkName \$deployConfig\.vmOptions\.network' -and
        $candidate.Extent.Text -match '-DNSServer \$DNSServer'
    }, $true)
Assert-DcEqual $true ([bool]$defaultDhcpCall) 'Default DHCP slow path receives switch-derived DC DNS address'

$phasesAst = Get-DcSourceAst 'common\Common.Phases.ps1'
. ([scriptblock]::Create((Get-DcSourceFunctionText -Ast $phasesAst -Name 'Get-ConfigurationData')))

function Get-Phase3ConfigurationData {
    param($DeployConfig)
    return @{ AllNodes = @(@{ NodeName = 'PT1-DC1'; Role = 'DC' }) }
}
function Get-CriticalVMs { param($Domain, $VmNames) return @([pscustomobject]@{ VmName = 'PT1-DC1' }) }
function Get-List { param($Type, $DomainName, [switch]$SmartUpdate) return @() }
function Invoke-SmartStartVMs { param($CritList) return 0 }
function Write-Progress2 { param($Activity, $Status, $PercentComplete, [switch]$Log) }
function Start-Sleep { param($Milliseconds, $Seconds) }
function Test-VmResponsive { param($VmName, $TimeoutSeconds) return $false }
function Restart-UnresponsiveVm { param($VmName, $WaitTimeSeconds) return $false }

$global:Common = [pscustomobject]@{ VerboseEnabled = $false }
$global:StartPhase = $false
$global:preparePhasePercent = 0
$preflightConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainNetBiosName = 'PT1'; domainName = 'pstest1.com' }
}
$threw = $false
try { $null = Get-ConfigurationData -Phase 3 -deployConfig $preflightConfig }
catch { $threw = $true }
Assert-DcEqual $true $threw 'Failed DC recovery terminates configuration preflight'

$startPhaseJobs = $phasesAst.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq 'Start-PhaseJobs'
    }, $true)
$dcIpGuard = $startPhaseJobs.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.IfStatementAst] -and
        $candidate.Extent.Text -match '^if \(\$Phase -eq 2\)' -and
        $candidate.Extent.Text -match 'DC addressing is immutable'
    }, $true)
if (-not $dcIpGuard) { throw 'Start-PhaseJobs immutable DC address guard was not found.' }
. ([scriptblock]::Create("function Invoke-DcIpGuard { param(`$Phase, `$deployConfig) $($dcIpGuard.Extent.Text); 'CONTINUED' }"))

function Test-DcIpGuardCase {
    param(
        [bool]$VmExists,
        [string]$AttachedSwitch,
        [string]$ConfiguredIP,
        [bool]$ShouldFail,
        [string]$What
    )

    $script:VmExists = $VmExists
    $script:VmState = 'Off'
    $script:Adapters = @()
    if ($AttachedSwitch) {
        $script:Adapters = @([pscustomobject]@{ SwitchName = $AttachedSwitch; IPAddresses = @() })
    }
    $dcConfig = [pscustomobject]@{
        vmName    = 'PT1-DC1'
        role      = 'DC'
        thisParams = [pscustomobject]@{ DCIPAddress = $ConfiguredIP }
    }
    $guardConfig = [pscustomobject]@{ virtualMachines = @($dcConfig) }
    $result = @(Invoke-DcIpGuard -Phase 2 -deployConfig $guardConfig)
    $failed = $result.Count -eq 1 -and $result[0].PreflightFailed -eq $true -and $result[0].Jobs -eq 0
    $continued = $result -contains 'CONTINUED'
    $actual = if ($failed -and -not $continued) { 'FAIL' } elseif ($continued -and -not $failed) { 'CONTINUE' } else { 'INVALID' }
    $expected = if ($ShouldFail) { 'FAIL' } else { 'CONTINUE' }
    Assert-DcEqual $expected $actual $What
}

Test-DcIpGuardCase -VmExists $true -AttachedSwitch '192.168.110.0' -ConfiguredIP '192.168.111.1' -ShouldFail $true `
    -What 'Existing DC address mismatch aborts before dispatch'
Test-DcIpGuardCase -VmExists $true -AttachedSwitch '192.168.110.0' -ConfiguredIP '' -ShouldFail $true `
    -What 'Missing generated address for an existing DC aborts before dispatch'
Test-DcIpGuardCase -VmExists $true -AttachedSwitch '192.168.110.0' -ConfiguredIP '192.168.110.1' -ShouldFail $false `
    -What 'Unchanged existing DC address remains an idempotent check'
Test-DcIpGuardCase -VmExists $true -AttachedSwitch '' -ConfiguredIP '192.168.110.1' -ShouldFail $true `
    -What 'Existing DC without a resolvable domain switch aborts instead of guessing'
Test-DcIpGuardCase -VmExists $false -AttachedSwitch '' -ConfiguredIP '192.168.110.1' -ShouldFail $false `
    -What 'A new DC may initialize its requested address'

$mapsPreflightFailure = $startPhaseJobs.Extent.Text -match 'Configuration preflight FAILED' -and
    $startPhaseJobs.Extent.Text -match 'PreflightFailed\s*=\s*\$true'
Assert-DcEqual $true $mapsPreflightFailure 'Start-PhaseJobs returns the established PreflightFailed result'

$startPhase = $phasesAst.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq 'Start-Phase'
    }, $true)
$preflightStop = $startPhase.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.IfStatementAst] -and
        $candidate.Extent.Text -match '\$start\.PreflightFailed' -and
        $candidate.Extent.Text -match 'return \$false'
    }, $true)
$waitPhaseCall = $startPhase.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.CommandAst] -and
        $candidate.GetCommandName() -eq 'Wait-Phase'
    }, $true)
$stopsBeforeWait = $preflightStop -and $waitPhaseCall -and
    $preflightStop.Extent.EndOffset -lt $waitPhaseCall.Extent.StartOffset
Assert-DcEqual $true $stopsBeforeWait 'Start-Phase propagates preflight failure before waiting or advancing'

if ($script:Failures -gt 0) {
    Write-Host "FAILED: $script:Failures DC liveness regression(s)" -ForegroundColor Red
    exit 1
}

Write-Host 'ALL DC LIVENESS REGRESSIONS PASSED' -ForegroundColor Green
exit 0