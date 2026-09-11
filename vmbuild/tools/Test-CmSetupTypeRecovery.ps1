#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$sourcePath = Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$sourcePath has $($errors.Count) parse error(s)." }
$functionAsts = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in 'Test-CmServiceNotFoundError', 'Get-CmDatabaseStateForRetry', 'Repair-StaleCmSetupTypeForRetry', 'Start-CmSetupProcessWithBreadcrumb' }, $true))
if ($functionAsts.Count -ne 4) { throw "Expected four recovery functions, found $($functionAsts.Count)." }
foreach ($functionName in 'Test-CmServiceNotFoundError', 'Get-CmDatabaseStateForRetry', 'Repair-StaleCmSetupTypeForRetry', 'Start-CmSetupProcessWithBreadcrumb') {
    $functionAst = @($functionAsts | Where-Object Name -eq $functionName)
    if ($functionAst.Count -ne 1) { throw "Expected one $functionName function, found $($functionAst.Count)." }
    . ([scriptblock]::Create($functionAst[0].Extent.Text))
}
$databaseAbsent = [pscustomobject]@{ Reached = $true; Exists = $false; Target = 'sql.test'; Error = '' }

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

$script:SetupType = 0
$script:Services = @()
$script:Site = $null
$script:RoleChildren = @()
$script:ProviderChildren = @()
$script:Writes = 0
$script:ProbeFailure = ''
$script:ObservedErrorActions = [Collections.Generic.List[string]]::new()
$script:SetupTypePresent = $true
function Get-ItemProperty {
    param([string]$Path, $ErrorAction)
    $script:ObservedErrorActions.Add("setup-read=$ErrorAction")
    if ($script:ProbeFailure -eq 'setup-read') { throw 'Setup Type read failed' }
    if (-not $script:SetupTypePresent) { return [pscustomobject]@{} }
    return [pscustomobject]@{ Type = $script:SetupType }
}
function Get-ItemPropertyValue {
    param([string]$Path, [string]$Name, $ErrorAction)
    $script:ObservedErrorActions.Add("setup-verify=$ErrorAction")
    return $script:SetupType
}
function Get-Service {
    param($Name, $ErrorAction)
    $script:ObservedErrorActions.Add("service=$ErrorAction")
    if ($script:ProbeFailure -eq 'service') {
        $record = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('service probe failed'), 'ServiceProbeFailed', [Management.Automation.ErrorCategory]::ReadError, $null)
        throw $record
    }
    if ($script:ProbeFailure -eq 'service-prefix') {
        $record = [Management.Automation.ErrorRecord]::new([Microsoft.PowerShell.Commands.ServiceCommandException]::new('alternate failure'), 'NoServiceFoundForGivenNameAlternate', [Management.Automation.ErrorCategory]::ReadError, $null)
        throw $record
    }
    $match = @($script:Services | Where-Object { $_.Name -eq $Name })
    if ($match.Count -eq 0) {
        return $null
    }
    return $match[0]
}
function Get-CimInstance {
    param($Namespace, $ClassName, $ErrorAction)
    $script:ObservedErrorActions.Add("wmi=$ErrorAction")
    if ($script:ProbeFailure -eq 'wmi') { throw [InvalidOperationException]::new('WMI probe failed') }
    if ($script:ProbeFailure -eq 'wmi-other') {
        $exception = [Microsoft.Management.Infrastructure.CimException]::new('Access denied')
        $statusField = $exception.GetType().GetField('<NativeErrorCode>k__BackingField', [Reflection.BindingFlags]'Instance,NonPublic')
        $statusField.SetValue($exception, [Enum]::ToObject($statusField.FieldType, 2))
        throw $exception
    }
    if ($script:Site) { return $script:Site }
    $exception = [Microsoft.Management.Infrastructure.CimException]::new('Invalid namespace')
    $statusField = $exception.GetType().GetField('<NativeErrorCode>k__BackingField', [Reflection.BindingFlags]'Instance,NonPublic')
    $statusField.SetValue($exception, [Enum]::ToObject($statusField.FieldType, 3))
    throw $exception
}
function Get-ChildItem {
    param([string]$Path, $ErrorAction)
    $script:ObservedErrorActions.Add("children=$ErrorAction")
    if ($script:ProbeFailure -eq 'role' -and $Path -like '*Management Server Role') { throw 'role probe failed' }
    if ($script:ProbeFailure -eq 'provider' -and $Path -like '*Providers\Sites') { throw 'provider probe failed' }
    if ($Path -like '*Management Server Role') { return $script:RoleChildren }
    if ($Path -like '*Providers\Sites') { return $script:ProviderChildren }
    return @()
}
function Test-Path {
    param([string]$Path, $ErrorAction)
    $script:ObservedErrorActions.Add("path=$ErrorAction")
    if ($script:ProbeFailure -eq 'path') { throw 'registry path probe failed' }
    if ($script:ProbeFailure -eq 'setup-path' -and $Path -like '*\SMS\Setup') { throw 'Setup path probe failed' }
    if ($script:ProbeFailure -eq 'setup-path-missing' -and $Path -like '*\SMS\Setup') { return $false }
    if ($Path -like '*\SMS\Setup') { return $true }
    if ($script:ProbeFailure -eq 'role' -and $Path -like '*Management Server Role') { return $true }
    if ($script:ProbeFailure -eq 'provider' -and $Path -like '*Providers\Sites') { return $true }
    return ($Path -like '*Management Server Role' -or $Path -like '*Providers\Sites')
}
function Set-ItemProperty {
    param([string]$Path, [string]$Name, [string]$Type, $Value, $ErrorAction)
    $script:Writes++
    $script:SetupType = [int]$Value
}

$script:DatabaseProbeResult = 0
$script:DatabaseProbeFailure = $false
$script:DatabaseProbeSequence = $null
$script:DatabaseProbeSequenceIndex = 0
$script:DatabaseCloseFailureSequence = $null
$script:DatabaseCloseFailureSequenceIndex = 0
$script:FakeDatabaseParameters = [pscustomobject]@{}
$script:FakeDatabaseParameters | Add-Member -MemberType ScriptMethod -Name Add -Value {
    param([string]$Name, $Type, [int]$Size)
    [pscustomobject]@{ Value = $null }
}
$script:FakeDatabaseCommand = [pscustomobject]@{ CommandText = ''; Parameters = $script:FakeDatabaseParameters }
$script:FakeDatabaseCommand | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value {
    if ($script:DatabaseProbeFailure) { throw 'database scalar probe failed' }
    if ($null -ne $script:DatabaseProbeSequence) {
        $value = $script:DatabaseProbeSequence[$script:DatabaseProbeSequenceIndex]
        $script:DatabaseProbeSequenceIndex++
        return $value
    }
    return $script:DatabaseProbeResult
}
$script:FakeDatabaseConnection = [pscustomobject]@{}
$script:FakeDatabaseConnection | Add-Member -MemberType ScriptMethod -Name Open -Value { }
$script:FakeDatabaseConnection | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value { return $script:FakeDatabaseCommand }
$script:FakeDatabaseConnection | Add-Member -MemberType ScriptMethod -Name Close -Value {
    if ($null -ne $script:DatabaseCloseFailureSequence) {
        $closeFails = $script:DatabaseCloseFailureSequence[$script:DatabaseCloseFailureSequenceIndex]
        $script:DatabaseCloseFailureSequenceIndex++
        if ($closeFails) { throw 'database connection close failed' }
    }
}
function New-Object {
    param([string]$TypeName, $ArgumentList)
    if ($TypeName -ne 'System.Data.SqlClient.SqlConnection') { throw "Unexpected New-Object type in test: $TypeName" }
    return $script:FakeDatabaseConnection
}

foreach ($databaseProbeCase in @(
        [pscustomobject]@{ Name = 'zero'; Value = [int]0; Failure = $false; Reached = $true; Exists = $false }
        [pscustomobject]@{ Name = 'positive'; Value = [int]1; Failure = $false; Reached = $true; Exists = $true }
        [pscustomobject]@{ Name = 'null'; Value = $null; Failure = $false; Reached = $false; Exists = $false }
        [pscustomobject]@{ Name = 'DBNull'; Value = [DBNull]::Value; Failure = $false; Reached = $false; Exists = $false }
        [pscustomobject]@{ Name = 'malformed'; Value = '0'; Failure = $false; Reached = $false; Exists = $false }
        [pscustomobject]@{ Name = 'negative'; Value = [int]-1; Failure = $false; Reached = $false; Exists = $false }
        [pscustomobject]@{ Name = 'exception'; Value = [int]0; Failure = $true; Reached = $false; Exists = $false }
    )) {
    $script:DatabaseProbeResult = $databaseProbeCase.Value
    $script:DatabaseProbeFailure = $databaseProbeCase.Failure
    $databaseProbeState = Get-CmDatabaseStateForRetry -DatabaseName CM_LMT -Targets 'sql.test'
    Assert-Equal $databaseProbeCase.Reached $databaseProbeState.Reached "$($databaseProbeCase.Name) database scalar reached state"
    Assert-Equal $databaseProbeCase.Exists $databaseProbeState.Exists "$($databaseProbeCase.Name) database scalar existence state"
    if (-not $databaseProbeCase.Reached) {
        Assert-Equal $true (-not [string]::IsNullOrWhiteSpace($databaseProbeState.Error)) "$($databaseProbeCase.Name) database scalar retains failure evidence"
    }
}
$script:DatabaseProbeFailure = $false

$script:DatabaseProbeSequence = @([int]1, [int]0)
$script:DatabaseProbeSequenceIndex = 0
$script:DatabaseCloseFailureSequence = @($true, $false)
$script:DatabaseCloseFailureSequenceIndex = 0
$presentThenCloseFailure = Get-CmDatabaseStateForRetry -DatabaseName CM_LMT -Targets 'sql.first', 'sql.second'
Assert-Equal $true $presentThenCloseFailure.Reached 'present database followed by cleanup failure remains measured'
Assert-Equal $true $presentThenCloseFailure.Exists 'present database followed by cleanup failure remains present'
Assert-Equal 'sql.first' $presentThenCloseFailure.Target 'present database cleanup failure does not advance to an absent target'
$script:SetupType = 1
$writesBeforePresentDatabase = $script:Writes
$presentDatabaseCaught = $null
try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $presentThenCloseFailure }
catch { $presentDatabaseCaught = $_ }
Assert-Equal $true ([bool]$presentDatabaseCaught) 'present database cleanup failure blocks Setup Type recovery'
Assert-Equal $writesBeforePresentDatabase $script:Writes 'present database cleanup failure performs no Setup Type write'

$script:DatabaseProbeSequence = @([int]0, [int]1)
$script:DatabaseProbeSequenceIndex = 0
$script:DatabaseCloseFailureSequence = @($false, $false)
$script:DatabaseCloseFailureSequenceIndex = 0
$absentThenPresent = Get-CmDatabaseStateForRetry -DatabaseName CM_LMT -Targets 'sql.listener', 'sql.node'
Assert-Equal $true $absentThenPresent.Reached 'later present database remains measured after an earlier absent target'
Assert-Equal $true $absentThenPresent.Exists 'later present database wins over an earlier absent target'
Assert-Equal 'sql.node' $absentThenPresent.Target 'later present database identifies the physical target'

$script:DatabaseProbeSequence = @([int]0, $null)
$script:DatabaseProbeSequenceIndex = 0
$script:DatabaseCloseFailureSequence = @($false, $false)
$script:DatabaseCloseFailureSequenceIndex = 0
$absentThenUnreachable = Get-CmDatabaseStateForRetry -DatabaseName CM_LMT -Targets 'sql.listener', 'sql.node'
Assert-Equal $false $absentThenUnreachable.Reached 'absent listener plus unmeasured node is not reported as measured absence'
Assert-Equal $false $absentThenUnreachable.Exists 'absent listener plus unmeasured node does not invent database presence'
Assert-Equal $true ($absentThenUnreachable.Error -like 'sql.node:*') 'unmeasured physical target retains target-specific failure evidence'

$script:DatabaseProbeSequence = $null
$script:DatabaseCloseFailureSequence = $null
$script:SetupType = 0

Assert-Equal $false (Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent) 'already-clear Setup Type is unchanged'
Assert-Equal 0 $script:Writes 'already-clear Setup Type performs no write'

$clearTypePresentDatabaseCaught = $null
try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState ([pscustomobject]@{ Reached = $true; Exists = $true; Target = 'sql.test'; Error = '' }) }
catch { $clearTypePresentDatabaseCaught = $_ }
Assert-Equal $true ([bool]$clearTypePresentDatabaseCaught) 'already-clear Setup Type cannot bypass an existing partial database'
Assert-Equal 0 $script:Writes 'existing database with clear Setup Type performs no Setup Type write'

$clearTypeUnmeasuredDatabaseCaught = $null
try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState ([pscustomobject]@{ Reached = $false; Exists = $false; Target = ''; Error = 'probe failed' }) }
catch { $clearTypeUnmeasuredDatabaseCaught = $_ }
Assert-Equal $true ([bool]$clearTypeUnmeasuredDatabaseCaught) 'already-clear Setup Type cannot bypass an unmeasured database state'
Assert-Equal 0 $script:Writes 'unmeasured database with clear Setup Type performs no Setup Type write'

foreach ($setupState in @(
        [pscustomobject]@{ Name = 'missing Setup path'; Present = $true; ProbeFailure = 'setup-path-missing' }
        [pscustomobject]@{ Name = 'missing Setup Type'; Present = $false; ProbeFailure = '' }
    )) {
    $script:SetupType = 0
    $script:SetupTypePresent = $setupState.Present
    $script:ProbeFailure = $setupState.ProbeFailure
    foreach ($databaseState in @(
            [pscustomobject]@{ Name = 'present database'; State = [pscustomobject]@{ Reached = $true; Exists = $true; Target = 'sql.test'; Error = '' } }
            [pscustomobject]@{ Name = 'unmeasured database'; State = [pscustomobject]@{ Reached = $false; Exists = $false; Target = ''; Error = 'probe failed' } }
        )) {
        $caught = $null
        try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseState.State }
        catch { $caught = $_ }
        Assert-Equal $true ([bool]$caught) "$($setupState.Name) with $($databaseState.Name) refuses setup retry"
    }
}
$script:SetupTypePresent = $true
$script:ProbeFailure = ''

foreach ($breadcrumbFailure in 'directory', 'content') {
    $startCalls = 0
    $caught = $null
    try {
        & {
            param($FunctionDefinition, $Failure, [ref]$StartCalls)
            function Test-Path { param($LiteralPath) return $false }
            function New-Item {
                param($ItemType, $Path, [switch]$Force, $ErrorAction)
                if ($Failure -eq 'directory') { throw 'injected directory creation failure' }
            }
            function Set-Content {
                param($LiteralPath, $Value, [switch]$Force, $ErrorAction)
                if ($Failure -eq 'content') { throw 'injected breadcrumb write failure' }
            }
            function Start-Process {
                param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $ErrorAction)
                $StartCalls.Value++
                return [pscustomobject]@{ ExitCode = 0 }
            }
            . $FunctionDefinition
            Start-CmSetupProcessWithBreadcrumb -BreadcrumbPath 'C:\staging\DSC\InstallSCCM.setupexe.started' -FilePath 'setup.exe' -ArgumentList '/test'
        } ([scriptblock]::Create(@($functionAsts | Where-Object Name -eq 'Start-CmSetupProcessWithBreadcrumb')[0].Extent.Text)) $breadcrumbFailure ([ref]$startCalls)
    }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$breadcrumbFailure breadcrumb failure is terminating"
    Assert-Equal 0 $startCalls "$breadcrumbFailure breadcrumb failure prevents Start-Process"
}

$script:SetupTypePresent = $false
Assert-Equal $false (Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent) 'missing Setup Type value is unchanged'
Assert-Equal 0 $script:Writes 'missing Setup Type performs no write'
$script:SetupTypePresent = $true

$script:SetupType = 1
$script:ProbeFailure = 'setup-path-missing'
Assert-Equal $false (Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent) 'missing Setup path is unchanged'
Assert-Equal 0 $script:Writes 'missing Setup path performs no write'
$script:ProbeFailure = ''

foreach ($siteType in 1, 2, 8) {
    $script:SetupType = $siteType
    $writesBefore = $script:Writes
    Assert-Equal $true (Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent) "orphaned Setup Type $siteType is cleared"
    Assert-Equal 0 $script:SetupType "orphaned Setup Type $siteType verifies as zero"
    Assert-Equal ($writesBefore + 1) $script:Writes "orphaned Setup Type $siteType writes once"
}

foreach ($case in @(
    @{ Name = 'SMS_EXECUTIVE service'; Setup = { $script:Services = @([pscustomobject]@{ Name = 'SMS_EXECUTIVE' }) }; Reset = { $script:Services = @() } }
    @{ Name = 'SMS_SITE_COMPONENT_MANAGER service'; Setup = { $script:Services = @([pscustomobject]@{ Name = 'SMS_SITE_COMPONENT_MANAGER' }) }; Reset = { $script:Services = @() } }
        @{ Name = 'site WMI'; Setup = { $script:Site = [pscustomobject]@{ SiteCode = 'LMT' } }; Reset = { $script:Site = $null } }
        @{ Name = 'server role'; Setup = { $script:RoleChildren = @([pscustomobject]@{ Name = 'SMS Site Server' }) }; Reset = { $script:RoleChildren = @() } }
        @{ Name = 'provider site'; Setup = { $script:ProviderChildren = @([pscustomobject]@{ Name = 'LMT' }) }; Reset = { $script:ProviderChildren = @() } }
    )) {
    $script:SetupType = 1
    & $case.Setup
    $caught = $null
    try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$($case.Name) marker blocks Setup Type recovery"
    Assert-Equal 1 $script:SetupType "$($case.Name) blocker preserves Setup Type"
    & $case.Reset
}

foreach ($probe in 'service', 'wmi', 'role', 'provider') {
    $script:SetupType = 1
    $script:ProbeFailure = $probe
    $caught = $null
    try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$probe probe failure blocks Setup Type recovery"
    Assert-Equal 1 $script:SetupType "$probe probe failure preserves Setup Type"
    $script:ProbeFailure = ''
}

$realMissingServiceError = $null
try { Microsoft.PowerShell.Management\Get-Service -Name ('MemLabsMissing-' + [guid]::NewGuid().ToString('N')) -ErrorAction Stop }
catch { $realMissingServiceError = $_ }
Assert-Equal $true ([bool]$realMissingServiceError) 'real missing-service cmdlet error was measured'
Assert-Equal $true (Test-CmServiceNotFoundError -ErrorRecord $realMissingServiceError) 'exact real missing-service FQID is accepted as absence'
$samePrefixError = [pscustomobject]@{ FullyQualifiedErrorId = 'NoServiceFoundForGivenNameAlternate,Microsoft.PowerShell.Commands.GetServiceCommand' }
Assert-Equal $false (Test-CmServiceNotFoundError -ErrorRecord $samePrefixError) 'same-prefix missing-service FQID is rejected'

foreach ($probe in 'service-prefix') {
    $script:SetupType = 1
    $script:ProbeFailure = $probe
    $caught = $null
    try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$probe FQID is rejected"
    Assert-Equal 1 $script:SetupType "$probe FQID preserves Setup Type"
    $script:ProbeFailure = ''
}

foreach ($probe in 'wmi-other', 'path', 'setup-path', 'setup-read') {
    $script:SetupType = 1
    $script:ProbeFailure = $probe
    $caught = $null
    try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseAbsent }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$probe error blocks Setup Type recovery"
    Assert-Equal 1 $script:SetupType "$probe error preserves Setup Type"
    $script:ProbeFailure = ''
}

Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'service=Stop' }).Count -gt 0) 'service probe uses ErrorAction Stop'
Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'wmi=Stop' }).Count -gt 0) 'WMI probe uses ErrorAction Stop'
Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'path=Stop' }).Count -gt 0) 'registry path probe uses ErrorAction Stop'
Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'children=Stop' }).Count -gt 0) 'registry enumeration uses ErrorAction Stop'
Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'setup-read=Stop' }).Count -gt 0) 'Setup Type read uses ErrorAction Stop'
Assert-Equal $true (@($script:ObservedErrorActions | Where-Object { $_ -eq 'setup-verify=Stop' }).Count -gt 0) 'Setup Type verification uses ErrorAction Stop'

foreach ($databaseState in @(
        [pscustomobject]@{ Name = 'unmeasured'; State = [pscustomobject]@{ Reached = $false; Exists = $false; Target = ''; Error = 'probe failed' } }
        [pscustomobject]@{ Name = 'present'; State = [pscustomobject]@{ Reached = $true; Exists = $true; Target = 'sql.test'; Error = '' } }
    )) {
    $script:SetupType = 1
    $caught = $null
    try { Repair-StaleCmSetupTypeForRetry -SiteCode LMT -DatabaseState $databaseState.State }
    catch { $caught = $_ }
    Assert-Equal $true ([bool]$caught) "$($databaseState.Name) database state blocks Setup Type recovery"
    Assert-Equal 1 $script:SetupType "$($databaseState.Name) database state preserves Setup Type"
}

$source = Get-Content -LiteralPath $sourcePath -Raw
Assert-Equal $true ($source -match '(?s)preLaunchDatabaseState\s*=\s*Get-CmDatabaseStateForRetry.+?Repair-StaleCmSetupTypeForRetry.+?-DatabaseState \$preLaunchDatabaseState.+?Set Install action as Running') 'NotStart path repairs stale Setup Type only after pre-launch database measurement'
Assert-Equal $true ($source -match '(?s)Start-CmSetupProcessWithBreadcrumb.+?catch \{.+?Write-DscStatus.+?mandatory breadcrumb.+?-Failure\s*\r?\n\s*return') 'breadcrumb launch failure is reported as fatal before setup can continue'

if ($script:Failures -gt 0) { throw "$script:Failures ConfigMgr Setup Type recovery test(s) failed." }
Write-Host 'ALL CONFIGMGR SETUP TYPE RECOVERY TESTS PASSED'