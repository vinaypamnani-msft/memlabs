#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Tag', Justification = 'Read by the extracted perfloading policy-reconciliation helper.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-TestAst {
    param($Path)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    return $ast
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$perf = Read-TestAst (Join-Path $root 'DSC\phases\perfloading.ps1')
$validation = Read-TestAst (Join-Path $root 'common\Common.Validation.Functional.ps1')
foreach ($entry in @(
    @{ Ast = $perf; Name = 'Sync-MemLabsClientScriptPolicy' },
    @{ Ast = $validation; Name = 'Get-ClientScriptValidationProbe' },
    @{ Ast = $validation; Name = 'Test-ClientScriptFunctionality' }
)) {
    $definition = @($entry.Ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $entry.Name
    })
    Assert-True ($definition.Count -eq 1) "Expected one script-scope $($entry.Name) helper."
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$script:Fixture = $null
$Tag = '[perfloading]'
function New-PolicyFixture {
    [pscustomobject]@{
        Exists = $true; Duplicate = $false; SettingsId = 42; ServerPolicy = 1; Embedded = $false
        Deployed = $true; CreateNoOp = $false; SetNoOp = $false; DeployNoOp = $false; SettingReadFails = $false
        Creates = 0; PolicyWrites = 0; DeploymentWrites = 0
        ClientPresent = $true; ClientRunning = $true; ServiceReadFails = $false
        ClientPolicies = @(1); ReceiveAt = -1; PolicyReadFails = $false; MachinePolicy = 'Undefined'
        BaselineReadFails = $false; EventReadFails = $false; RefreshReturn = 0
        Seconds = 0; Refreshes = 0; Events = @(); Baselines = @(
            [pscustomobject]@{ Name = 'Baseline_healthy'; LastComplianceStatus = 1; LastEvalTime = 'now'; ComplianceDetails = '' }
        )
        Messages = [Collections.Generic.List[object]]::new()
    }
}
function Write-DscStatus {
    param($Message, [switch]$Warning)
    $script:Fixture.Messages.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}
function Get-CMClientSetting {
    [CmdletBinding()]
    param($Name, $Id, $Setting)
    if ($script:Fixture.SettingReadFails) { throw 'fixture client-setting read denied' }
    if ($Setting) {
        Assert-True ($Id -eq '42' -and $Setting -eq 'ComputerAgent') 'Computer Agent readback used the wrong identity/category.'
        if ($null -eq $script:Fixture.ServerPolicy) { return }
        $agent = [pscustomobject]@{ PowerShellExecutionPolicy = $script:Fixture.ServerPolicy }
        if ($script:Fixture.Embedded) { return [pscustomobject]@{ AgentConfigurations = @($agent) } }
        return $agent
    }
    Assert-True ($Name -eq 'MEMLABS-powershellbypass') 'Reconciliation touched another client setting.'
    if ($script:Fixture.Exists) { [pscustomobject]@{ Name = $Name; SettingsID = $script:Fixture.SettingsId } }
    if ($script:Fixture.Duplicate) { [pscustomobject]@{ Name = $Name; SettingsID = 43 } }
}
function New-CMClientSetting {
    [CmdletBinding()]
    param($Name, $Description, $Type)
    Assert-True ($Name -eq 'MEMLABS-powershellbypass' -and $Type -eq 'Device') 'Creation changed setting scope/type.'
    $script:Fixture.Creates++
    if (-not $script:Fixture.CreateNoOp) { $script:Fixture.Exists = $true }
}
function Set-CMClientSettingComputerAgent {
    [CmdletBinding()]
    param($PowerShellExecutionPolicy, $Name)
    Assert-True ($Name -eq 'MEMLABS-powershellbypass' -and $PowerShellExecutionPolicy -eq 'Bypass') 'Reconciliation changed unrelated client settings.'
    $script:Fixture.PolicyWrites++
    if (-not $script:Fixture.SetNoOp) { $script:Fixture.ServerPolicy = 1 }
}
function Get-CMClientSettingDeployment {
    [CmdletBinding()]
    param($Id, $CollectionId)
    Assert-True ($Id -eq '42' -and $CollectionId -eq 'SMS00001') 'Deployment readback lost its settings/collection scope.'
    if ($script:Fixture.Deployed) { [pscustomobject]@{ ClientSettingsID = 42; CollectionID = 'SMS00001' } }
}
function New-CMClientSettingDeployment {
    [CmdletBinding()]
    param($Name, $CollectionId)
    Assert-True ($Name -eq 'MEMLABS-powershellbypass' -and $CollectionId -eq 'SMS00001') 'Deployment changed collection scope.'
    $script:Fixture.DeploymentWrites++
    if (-not $script:Fixture.DeployNoOp) { $script:Fixture.Deployed = $true }
}

$script:Fixture = New-PolicyFixture
Assert-True (Sync-MemLabsClientScriptPolicy) 'Healthy existing policy failed reconciliation.'
Assert-True ($script:Fixture.Creates -eq 0 -and $script:Fixture.PolicyWrites -eq 0 -and $script:Fixture.DeploymentWrites -eq 0) 'Healthy existing policy was rewritten.'
$script:Fixture = New-PolicyFixture
$script:Fixture.Exists = $false; $script:Fixture.ServerPolicy = $null; $script:Fixture.Deployed = $false
Assert-True (Sync-MemLabsClientScriptPolicy) 'A fresh setting did not reconcile.'
Assert-True ($script:Fixture.Creates -eq 1 -and $script:Fixture.PolicyWrites -eq 1 -and $script:Fixture.DeploymentWrites -eq 1) 'Fresh policy/deployment creation was incomplete.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ServerPolicy = 0; $script:Fixture.Deployed = $false; $script:Fixture.Embedded = $true
Assert-True (Sync-MemLabsClientScriptPolicy) 'An existing AllSigned setting or missing deployment was skipped.'
Assert-True ($script:Fixture.Creates -eq 0 -and $script:Fixture.PolicyWrites -eq 1 -and $script:Fixture.DeploymentWrites -eq 1) 'Existing setting repair created a duplicate or lost its deployment.'
foreach ($fault in @('SettingReadFails', 'SetNoOp', 'DeployNoOp', 'CreateNoOp', 'Duplicate')) {
    $script:Fixture = New-PolicyFixture
    $script:Fixture.$fault = $true
    if ($fault -eq 'SetNoOp') { $script:Fixture.ServerPolicy = 0 }
    if ($fault -eq 'DeployNoOp') { $script:Fixture.Deployed = $false }
    if ($fault -eq 'CreateNoOp') { $script:Fixture.Exists = $false }
    Assert-True (-not (Sync-MemLabsClientScriptPolicy)) "$fault produced false-success policy reconciliation."
    Assert-True (@($script:Fixture.Messages | Where-Object Warning).Count -eq 1) "$fault was not surfaced as a warning."
}
$policyCall = @($perf.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Sync-MemLabsClientScriptPolicy'
}, $true))
$baselineDeploys = @($perf.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-CMBaselineDeployment'
}, $true))
Assert-True ($policyCall.Count -eq 1 -and $baselineDeploys.Count -gt 0 -and
    $policyCall[0].Extent.StartOffset -lt $baselineDeploys[0].Extent.StartOffset) 'Policy reconciliation does not precede baseline deployment.'
$callParent = $policyCall[0].Parent
while ($callParent -and $callParent -isnot [Management.Automation.Language.IfStatementAst]) { $callParent = $callParent.Parent }
Assert-True ($callParent.Clauses[0].Item1.Extent.Text -eq '$isTopLevel') 'Child primaries can modify hierarchy-wide client settings.'

$probe = Get-ClientScriptValidationProbe
$baseUtc = ([datetime]'2026-11-06T04:14:00Z').ToUniversalTime()
function Get-Date { $baseUtc.AddSeconds($script:Fixture.Seconds) }
function Start-Sleep {
    param($Seconds)
    Assert-True ($Seconds -gt 0 -and $Seconds -le 5) 'Policy wait used an invalid or unbounded delay.'
    $script:Fixture.Seconds += $Seconds
    if ($script:Fixture.Seconds -gt 60) { throw 'Policy wait exceeded 60 seconds.' }
}
function Write-Progress { param($Activity, $Status, [switch]$Completed) }
function Get-Service {
    [CmdletBinding()]
    param()
    if ($script:Fixture.ServiceReadFails) { throw 'fixture service enumeration denied' }
    if ($script:Fixture.ClientPresent) {
        $status = if ($script:Fixture.ClientRunning) { 'Running' } else { 'Stopped' }
        [pscustomobject]@{ Name = 'CcmExec'; Status = $status }
    }
}
function Get-ExecutionPolicy {
    [CmdletBinding()]
    param([switch]$List)
    [pscustomobject]@{ Scope = 'MachinePolicy'; ExecutionPolicy = $script:Fixture.MachinePolicy }
    [pscustomobject]@{ Scope = 'UserPolicy'; ExecutionPolicy = 'Undefined' }
}
function Set-ExecutionPolicy { throw 'Validation must never change OS/Group Policy.' }
function Get-CimInstance {
    [CmdletBinding()]
    param($Namespace, $ClassName, $OperationTimeoutSec)
    Assert-True ($OperationTimeoutSec -eq 10) 'Client policy/outcome reads lost their operation deadline.'
    if ($ClassName -eq 'CCM_ClientAgentConfig') {
        Assert-True ($Namespace -eq 'root\ccm\Policy\Machine\ActualConfig') 'Client policy was read from RequestedConfig instead of ActualConfig.'
        if ($script:Fixture.PolicyReadFails) { throw 'fixture client policy unreadable' }
        if ($script:Fixture.ReceiveAt -ge 0 -and $script:Fixture.Seconds -ge $script:Fixture.ReceiveAt) {
            return [pscustomobject]@{ PowerShellExecutionPolicy = 1 }
        }
        foreach ($policy in $script:Fixture.ClientPolicies) { [pscustomobject]@{ PowerShellExecutionPolicy = $policy } }
        return
    }
    if ($ClassName -eq 'SMS_DesiredConfiguration') {
        Assert-True ($Namespace -eq 'root\ccm\dcm') 'Baseline outcomes were not read from the client.'
        if ($script:Fixture.BaselineReadFails) { throw 'fixture client baseline unreadable' }
        return $script:Fixture.Baselines
    }
    throw "Unexpected client class $ClassName"
}
function Invoke-CimMethod {
    [CmdletBinding()]
    param($Namespace, $ClassName, $MethodName, $Arguments, $OperationTimeoutSec)
    Assert-True ($Namespace -eq 'root\ccm' -and $ClassName -eq 'SMS_Client' -and $MethodName -eq 'TriggerSchedule' -and
        $Arguments.sScheduleID -in @('{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}')) 'Validation triggered an unrelated client operation.'
    $script:Fixture.Refreshes++
    [pscustomobject]@{ ReturnValue = $script:Fixture.RefreshReturn }
}
function Get-WinEvent {
    [CmdletBinding()]
    param($FilterHashtable, $MaxEvents)
    Assert-True ($FilterHashtable.LogName -eq 'Microsoft-Windows-PowerShell/Operational' -and
        $FilterHashtable.Id -eq 4100 -and $MaxEvents -eq 1000) 'Client exception inventory lost its event filter/cap.'
    if ($script:Fixture.EventReadFails) { throw 'fixture PowerShell events denied' }
    return @($script:Fixture.Events | Where-Object { $_.TimeCreated -ge $FilterHashtable.StartTime })
}
function New-RejectionEvent {
    param([int]$Id, [string]$Payload, [int]$MinutesAgo = 7)
    $escaped = [Security.SecurityElement]::Escape($Payload)
    $eventRecord = [pscustomobject]@{
        RecordId = $Id; TimeCreated = $baseUtc.AddMinutes(-$MinutesAgo)
        Xml = "<Event><EventData><Data Name=`"Payload`">$escaped</Data></EventData></Event>"
    }
    $eventRecord | Add-Member ScriptMethod ToXml { return $this.Xml }
    return $eventRecord
}
function Invoke-ClientFixture {
    param([bool]$ExpectBypass = $true)
    $result = & $probe $ExpectBypass
    Assert-True ($result.Passed -and @($result.Details | Where-Object { $_ -like 'FAIL:*' }).Count -eq 0) 'Client-script checks violated the warning-only contract.'
    return $result
}
$script:Fixture = New-PolicyFixture
$healthy = Invoke-ClientFixture
Assert-True (@($healthy.Details | Where-Object { $_ -like 'WARN:*' }).Count -eq 0 -and $script:Fixture.Refreshes -eq 0) 'Healthy client policy/outcomes warned or caused needless refresh.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0); $script:Fixture.ReceiveAt = 15
$received = Invoke-ClientFixture
Assert-True ($script:Fixture.Refreshes -eq 2 -and $script:Fixture.Seconds -eq 15 -and
    ($received.Details -join ' ') -match 'RECOVERED: Client received effective Bypass') 'A pending client policy did not receive bounded refresh/readback.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0); $script:Fixture.ReceiveAt = 60
Assert-True (((Invoke-ClientFixture).Details -join ' ') -match 'RECOVERED: Client received effective Bypass') 'Policy arriving at the exact deadline was missed.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0)
$blocked = Invoke-ClientFixture
Assert-True ($script:Fixture.Seconds -eq 60 -and ($blocked.Details -join ' ') -match 'WARN: Effective ConfigMgr PowerShellExecutionPolicy=0') 'An unchanged AllSigned client was silently accepted.'
$script:Fixture = New-PolicyFixture
$script:Fixture.MachinePolicy = 'AllSigned'
$gpo = Invoke-ClientFixture
Assert-True ($script:Fixture.Refreshes -eq 0 -and ($gpo.Details -join ' ') -match 'WARN: PowerShell MachinePolicy=AllSigned') 'A blocking GPO was hidden or pointless refresh was attempted.'
Assert-True (@($gpo.Details | Where-Object { $_ -like 'OK:*PowerShell*' }).Count -eq 0) 'A blocking GPO still produced a script-policy success line.'

foreach ($fault in @('ServiceReadFails', 'PolicyReadFails', 'BaselineReadFails', 'EventReadFails')) {
    $script:Fixture = New-PolicyFixture
    $script:Fixture.$fault = $true
    $result = Invoke-ClientFixture
    Assert-True (($result.Details -join ' ') -match 'WARN:.*fixture') "$fault was silently ignored."
}
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0, 1)
Assert-True (((Invoke-ClientFixture).Details -join ' ') -match 'conflicting values') 'Ambiguous effective policies were guessed.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @()
Assert-True (((Invoke-ClientFixture).Details -join ' ') -match 'policy is not present') 'Missing policy was guessed as a default.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0); $script:Fixture.RefreshReturn = 5
Assert-True (((Invoke-ClientFixture).Details -join ' ') -match 'machine-policy refresh failed') 'A nonzero client schedule return was treated as success.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPolicies = @(0)
Assert-True (@((Invoke-ClientFixture -ExpectBypass $false).Details | Where-Object { $_ -like 'WARN:*' }).Count -eq 0) 'A non-prepopulated lab was forced to use Bypass.'

$script:Fixture = New-PolicyFixture
$script:Fixture.Baselines = @(
    [pscustomobject]@{ Name = 'rule_false'; LastComplianceStatus = 2; LastEvalTime = 'now'; ComplianceDetails = '' },
    [pscustomobject]@{ Name = 'script_error'; LastComplianceStatus = 4; LastEvalTime = 'now'; ComplianceDetails = '' },
    [pscustomobject]@{ Name = 'discovery_error'; LastComplianceStatus = 2; LastEvalTime = 'now'; ComplianceDetails = '<Result DiscoveryFailure="True" />' }
)
$outcomes = Invoke-ClientFixture
Assert-True (@($outcomes.Details | Where-Object { $_ -like 'WARN:*execution/discovery error*' }).Count -eq 2) 'Runtime/discovery errors were confused with genuine non-compliance.'
$script:Fixture = New-PolicyFixture
$script:Fixture.Baselines[0].ComplianceDetails = '<Result DiscoveryFailure="True" />'
Assert-True (@((Invoke-ClientFixture).Details | Where-Object { $_ -like 'WARN:*execution/discovery error*' }).Count -eq 0) 'A current Compliant baseline was treated as a continuing historical discovery failure.'
$script:Fixture = New-PolicyFixture
$script:Fixture.Baselines = @()
Assert-True (((Invoke-ClientFixture).Details -join ' ') -match 'WARN: No client baseline evaluation') 'An unevaluated client was called healthy.'

$script:Fixture = New-PolicyFixture
$script:Fixture.Events = @(
    foreach ($id in 1..6) {
        New-RejectionEvent -Id (9370 + $id) -Payload "Error Message = File C:\Windows\CCM\SystemTemp\11111111-1111-1111-1111-11111111111$id.ps1 is not digitally signed.`nFully Qualified Error ID = UnauthorizedAccess"
    }
    New-RejectionEvent -Id 9000 -Payload 'Error Message = System error.'
    New-RejectionEvent -Id 9001 -Payload 'Error Message = Other script cannot load. Fully Qualified Error ID = UnauthorizedAccess'
    New-RejectionEvent -Id 9002 -MinutesAgo 180 -Payload 'Error Message = C:\Windows\CCM\SystemTemp\11111111-1111-1111-1111-111111111111.ps1 is not digitally signed.'
)
$rejections = Invoke-ClientFixture
Assert-True (($rejections.Details -join ' ') -match 'WARN: 6 ConfigMgr client PowerShell script rejection') 'The six captured event-only rejections were not surfaced or were polluted by unrelated/historical events.'
$script:Fixture = New-PolicyFixture
$script:Fixture.ClientPresent = $false
Assert-True ((Invoke-ClientFixture).Skipped) 'A VM without a ConfigMgr client was forced into client-policy validation.'

$script:HostOutput = [Collections.Generic.List[object]]::new()
$script:HostResult = $null
$script:TransportFails = $false
$script:ExpectedBypass = $null
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds, [switch]$PollProgress)
    $script:ExpectedBypass = $ArgumentList
    if ($script:TransportFails) { throw 'fixture PSDirect transport unavailable' }
    return $script:HostResult
}
function Add-Phase11Output { param($Text, $Level); $script:HostOutput.Add([pscustomobject]@{ Text = $Text; Level = $Level }) }
function Write-Log { param($Message, [switch]$LogOnly) }
$item = [pscustomobject]@{ cmOptions = [pscustomobject]@{ PrePopulateObjects = $true } }
$config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'lab.test' } }
Assert-True (Test-ClientScriptFunctionality -VMName 'PS1SITE' -CurrentItem $item -DeployConfig $config) 'An unreadable probe changed the role verdict.'
Assert-True ($script:HostOutput.Count -eq 1 -and $script:HostOutput[0].Level -eq 'Warning') 'An unreadable probe was not surfaced on the host.'
$script:HostOutput.Clear()
$script:HostResult = [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $rejections }
Assert-True (Test-ClientScriptFunctionality -VMName 'PS1SITE' -CurrentItem $item -DeployConfig $config) 'Observed client-script warnings changed the role verdict.'
Assert-True (@($script:HostOutput | Where-Object { $_.Level -eq 'Warning' }).Count -gt 0 -and
    @($script:HostOutput | Where-Object { $_.Level -eq 'Failure' }).Count -eq 0) 'Warning-only evidence did not reach the Phase 11 output buffer.'
$script:HostOutput.Clear()
$script:TransportFails = $true
Assert-True (Test-ClientScriptFunctionality -VMName 'PS1SITE' -CurrentItem $item -DeployConfig $config) 'A thrown transport error violated the warning-only contract.'
Assert-True (($script:HostOutput.Text -join ' ') -match 'WARN: Client script probe failed.*fixture PSDirect') 'A thrown transport error was hidden.'
$script:TransportFails = $false
$external = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'client.test' }
    cmOptions = [pscustomobject]@{ PrePopulateObjects = $false }
    virtualMachines = @(
        [pscustomobject]@{
            role = 'DC'; domain = 'client.test'; externalDomainJoinSiteCode = 'PRI'
            thisParams = [pscustomobject]@{ ExternalSiteServer = 'REMOTE-PRI.site.test' }
        },
        [pscustomobject]@{
            vmName = 'REMOTE-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'client.test'
            cmOptions = [pscustomobject]@{ PrePopulateObjects = $false }
        },
        [pscustomobject]@{
            vmName = 'REMOTE-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'site.test'
            cmOptions = [pscustomobject]@{ PrePopulateObjects = $true }
        }
    )
}
$externalClient = [pscustomobject]@{ role = 'DomainMember' }
[void](Test-ClientScriptFunctionality -VMName 'CLIENT' -CurrentItem $externalClient -DeployConfig $external)
Assert-True $script:ExpectedBypass 'Cross-forest clients inherited the local forest policy instead of the configured managing site.'
$dispatcher = @($validation.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Test-ClientScriptFunctionality'
}, $true))
Assert-True ($dispatcher.Count -eq 1) 'Client-script checks are not wired exactly once into the role dispatcher.'
$dispatchIf = $dispatcher[0].Parent
while ($dispatchIf -and $dispatchIf -isnot [Management.Automation.Language.IfStatementAst]) { $dispatchIf = $dispatchIf.Parent }
Assert-True (-not $dispatchIf.Clauses[0].Item1.Extent.Text.Contains('$testsPassed') -and
    $dispatchIf.Clauses[0].Item1.Extent.Text.Contains('$vmIsLinux')) 'Site-server errors suppress client-script evidence, or Linux receives Windows checks.'
Write-Host 'PASS -- idempotent early policy/deployment reconciliation, effective client readback, bounded refresh, GPO preservation, runtime/event evidence, and warning-only dispatch.'
