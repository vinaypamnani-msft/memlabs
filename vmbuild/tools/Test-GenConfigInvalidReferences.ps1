<#
.SYNOPSIS
    Verifies that invalid GenConfig VM references produce visible validation failures.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'InternalUseOnly', Justification = 'Consumed by the AST-imported deployment menu builder.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$commonPath = Join-Path $RootPath 'common'

function Import-TestFunction {
    param([string] $File, [string] $Name)

    $path = Join-Path $commonPath $File
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)

    $script:Assertions++
    if ("$Expected" -ne "$Actual") { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

function Assert-ValidationError {
    Assert-Equal $true (@($global:GenConfigErrorMessages | Where-Object Level -eq 'ERROR').Count -gt 0) 'The invalid edit did not produce an ERROR in the menu.'
    Assert-Equal $true (@($global:PendingValidationErrors | Where-Object Level -eq 'ERROR').Count -gt 0) 'The invalid edit will disappear on the next main-menu redraw.'
}

function Get-FixtureState {
    $global:Config | ConvertTo-Json -Depth 10 -Compress
}

function Reset-Fixture {
    $global:GenConfigErrorMessages = @()
    $global:PendingValidationErrors = @()
    $script:Inventory = @()
    $script:Responses = New-Object System.Collections.Queue
    $script:Rendered = New-Object 'System.Collections.Generic.List[string]'
    $script:Prompts = 0
    $script:ValidationMode = 'Valid'
    $script:PipelineMode = 'Valid'
    $script:Enhancements = 0
    $script:ExceptionsLogged = 0
    $script:RenderMenuErrors = $false
    $script:ActionFailure = 'Binding'
    $global:DisableSmartUpdate = $false
    $global:TestConfigFastCache = $null
    $global:Config = [pscustomobject]@{
        vmOptions       = [pscustomobject]@{ domainName = 'example.test'; domainNetBiosName = 'EXAMPLE'; prefix = 'T-'; network = '10.100.0.0' }
        domainDefaults  = [pscustomobject]@{ DefaultSqlVersion = 'SQL Server 2022'; IncludeSSMSOnNONSQL = $false; UseDynamicMemory = $false }
        parameters      = [pscustomobject]@{}
        virtualMachines = @(
            [pscustomobject]@{
                vmName = 'PS1SITE'; Role = 'Primary'; SiteCode = 'PS1'; sqlVersion = 'SQL Server 2022'
                sqlInstanceName = 'MSSQLSERVER'; sqlPort = '1433'; memory = '10GB'; virtualProcs = 8
                dynamicMinRam = '4GB'; additionalDisks = [pscustomobject]@{ E = '600GB'; F = '100GB' }
                InstallSUP = $false; InstallMP = $false; InstallDP = $false; network = '10.100.0.0'
            },
            [pscustomobject]@{ vmName = 'SQL1'; Role = 'DomainMember'; sqlVersion = 'SQL Server 2022'; memory = '6GB' }
        )
    }
}

function Set-Responses {
    param([object[]] $Values)
    foreach ($value in $Values) { $script:Responses.Enqueue($value) }
}

function Write-Log {
    param($Message, [switch] $LogOnly, [switch] $Warning, [switch] $Failure, [switch] $Activity, [switch] $NoNewLine, [switch] $Success, [switch] $Verbose)
}
function Write-Host2 {
    param($Message, $ForegroundColor, [switch] $NoNewLine)
    $script:Rendered.Add("$Message")
}
function Write-RedX {
    param($Message, $ForegroundColor)
    $script:Rendered.Add("$Message")
}
function Write-OrangePoint {
    param($Message, $ForegroundColor)
    $script:Rendered.Add("$Message")
}
function Write-Progress2 {
    param($Activity, $Status, $PercentComplete, [switch] $Completed)
}
function Write-Exception {
    param($ExceptionInfo)
    $script:ExceptionsLogged++
}
function Get-List {
    param($Type, $Domain, $DomainName, [switch] $SmartUpdate)
    if ($Type -eq 'UniqueDomain') { return @('example.test') }
    $script:Inventory
}
function Get-List2 {
    param($deployConfig, [switch] $SmartUpdate)
    @($deployConfig.virtualMachines) + @($script:Inventory)
}
function Get-Menu2 {
    param($MenuName, $Prompt, $OptionArray, $CurrentValue, [bool] $Test, $additionalOptions, [switch] $return)
    $null = $args
    if ($script:RenderMenuErrors) { Show-GenConfigErrorMessages }
    if ($script:Responses.Count -eq 0) { throw "Unexpected menu prompt: $MenuName" }
    $script:Responses.Dequeue()
}
function Test-RequiresName {
    param([Parameter(Mandatory = $true)][string] $VmName)
    $null = $VmName
}
function Test-Configuration {
    param($InputObject, [switch] $Fast)
    if ($script:ValidationMode -eq 'EmptyResult') { return $null }
    if ($script:ValidationMode -eq 'BindingFailure') { Test-RequiresName -VmName '' }
    if ($script:ValidationMode -eq 'UnexpectedFailure') { throw [System.IO.IOException]::new('Unexpected implementation failure') }
    [pscustomobject]@{ Valid = $true; Failures = 0; Warnings = 0; Message = '' }
}
function Get-SupportedOperatingSystemsForRole {
    param($Role)
    @('Server 2022')
}
function Get-ConfigCmOptions {
    param($Config)
    [pscustomobject]@{ OfflineSCP = $false }
}
function Get-ValidCASSiteCodes {
    param($Config, $Domain)
    @('CS1')
}
function Select-RolesForNewList { @('Primary') }
function Read-YesOrNoWithTimeout {
    param($Prompt, [switch] $HideHelp, $Default)
    $script:Prompts++
    'y'
}
function Get-NewMachineName {
    param($VM)
    "$($VM.SiteCode)SITE"
}
function Rename-VirtualMachine {
    param($VM)
    $VM.vmName
}
function Test-VmIsLinux {
    param($VM)
    $false
}
function Test-ValidSiteRoleFlags {
    param($VM, $ConfigObject, $ReturnObject)
}
function New-ValidationResult {
    [pscustomobject]@{ Valid = $false; Problems = 0; Failures = 0; Warnings = 0; Message = New-Object System.Text.StringBuilder }
}

foreach ($name in 'Add-ErrorMessage', 'Get-GenConfigSiteServer', 'Get-GenConfigSqlVM', 'Get-AdditionalValidations', 'Get-TestResult') {
    . (Import-TestFunction 'Common.GenConfig.Validation.ps1' $name)
}
foreach ($name in 'Get-SupportedOperatingSystemsForRole', 'Set-SiteServerLocalSql', 'Set-SiteServerRemoteSQL', 'Get-remoteSQLVM', 'Get-WsusDBName', 'Get-ReplicaSQLVM', 'Get-TargetSitesForDomain',
    'Get-ValidSiteCodesForRP', 'Get-OperatingSystemMenuClient', 'Get-OperatingSystemMenuServer', 'Get-OperatingSystemMenu', 'Set-ParentSiteCodeMenu',
    'Get-ParentSiteCodeMenu', 'Get-SqlVersionMenu', 'Get-ForestTrustMenu', 'Get-CMVersionMenu', 'Get-RoleMenu', 'Get-SiteCodeForDPMP') {
    . (Import-TestFunction 'Common.GenConfig.CmMenus.ps1' $name)
}
foreach ($name in 'Remove-VMFromConfig', 'Invoke-ProxyOptInCleanup') {
    . (Import-TestFunction 'Common.GenConfig.VMList.ps1' $name)
}
foreach ($name in 'Add-NewVMForRole', 'Get-NetworkForVM', 'Clear-StaleValidationMessagesForVM') {
    . (Import-TestFunction 'Common.GenConfig.AddVM.ps1' $name)
}
foreach ($name in 'select-PullDPMenu', 'select-ReplicaSQLMenu', 'Get-ListOfPossibleSQLServers', 'Get-ListOfPossibleDPMP') {
    . (Import-TestFunction 'Common.GenConfig.RoleMenus.ps1' $name)
}
foreach ($name in 'Get-VMFromList2', 'Get-SiteServerForSiteCode', 'Get-SqlServerForSiteCode', 'Get-ParentSiteServerForSiteCode', 'Get-ActiveSiteServerForSiteCode') {
    . (Import-TestFunction 'Common.Config.ps1' $name)
}
foreach ($name in 'Add-ValidationMessage', 'Test-MachineNameExists', 'Test-ValidMachineName', 'Test-ValidVmSupported', 'Test-ValidUserName') {
    . (Import-TestFunction 'Common.Validation.ps1' $name)
}
. (Import-TestFunction 'Common.Menu.ps1' 'Show-GenConfigErrorMessages')

$savedGlobals = @{}
foreach ($name in 'Config', 'Common', 'GenConfigErrorMessages', 'PendingValidationErrors', 'DisableSmartUpdate', 'TestConfigFastCache', 'MemLabsSkipValidation', 'existingMachines', 'StartOver', 'GoBack') {
    $variable = Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    $savedGlobals[$name] = [pscustomobject]@{ Exists = ($null -ne $variable); Value = $variable.Value }
}
$script:Assertions = 0
try {
    $global:Common = [pscustomobject]@{
        InJob = $true
        Colors = [pscustomobject]@{ GenConfigTip = 'Yellow' }
        Supported = [pscustomobject]@{
            OperatingSystems = @('Server 2022'); SqlVersions = @('SQL Server 2022'); CmVersions = @()
            Roles = @('DomainMember', 'Primary', 'CAS', 'SQLAO', 'SiteSystem', 'WSUS')
        }
    }
    foreach ($invalidName in @($null, '', ' ', 'MissingVM')) {
        Reset-Fixture
        $before = Get-FixtureState
        Remove-VMFromConfig -vmName $invalidName
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'An invalid removal modified the configuration.'

        Reset-Fixture
        $before = Get-FixtureState
        Set-SiteServerRemoteSQL -virtualMachine $global:Config.virtualMachines[0] -vmName $invalidName
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'An invalid SQL target modified the configuration.'
    }
    Reset-Fixture
    $global:Config.virtualMachines += [pscustomobject]@{ vmName = 'SQL1'; Role = 'DomainMember'; sqlVersion = 'SQL Server 2022' }
    $before = Get-FixtureState
    Remove-VMFromConfig -vmName 'SQL1'
    Assert-ValidationError
    Assert-Equal $before (Get-FixtureState) 'An ambiguous removal deleted multiple VMs.'
    Set-SiteServerRemoteSQL -virtualMachine $global:Config.virtualMachines[0] -vmName 'SQL1'
    Assert-Equal $before (Get-FixtureState) 'An ambiguous SQL target modified the configuration.'

    foreach ($target in 'PS1SITE', 'NoSqlVM') {
        Reset-Fixture
        $global:Config.virtualMachines += [pscustomobject]@{ vmName = 'NoSqlVM'; Role = 'DomainMember' }
        $before = Get-FixtureState
        Set-SiteServerRemoteSQL -virtualMachine $global:Config.virtualMachines[0] -vmName $target
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'A self-reference or non-SQL target changed database settings.'
    }
    foreach ($invalidVm in @($null, [pscustomobject]@{ vmName = '' })) {
        Reset-Fixture
        $before = Get-FixtureState
        Set-SiteServerLocalSql -virtualMachine $invalidVm
        Set-SiteServerRemoteSQL -virtualMachine $invalidVm -vmName 'SQL1'
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'An unnamed site-server edit modified the configuration.'
    }
    Reset-Fixture
    $site = $global:Config.virtualMachines[0]
    $site.InstallSUP = $true
    $site | Add-Member -NotePropertyName wsusDataBaseServer -NotePropertyValue 'PS1SITE'
    $existingSql = [pscustomobject]@{ vmName = 'EXISTINGSQL'; Role = 'DomainMember'; sqlVersion = 'SQL Server 2022'; InstallRP = $false; InstallSMSProv = $true }
    $script:Inventory = @($existingSql)
    $before = $existingSql | ConvertTo-Json -Compress
    Set-SiteServerRemoteSQL -virtualMachine $site -vmName 'EXISTINGSQL'
    Assert-Equal 'EXISTINGSQL' $site.remoteSQLVM 'An existing domain SQL VM was incorrectly rejected.'
    Assert-Equal 'EXISTINGSQL' $site.wsusDataBaseServer 'Selecting existing SQL did not update the SUP database.'
    Assert-Equal $before ($existingSql | ConvertTo-Json -Compress) 'SQL selection mutated the deployed VM inventory.'

    foreach ($field in 'SqlServiceAccount', 'SqlAgentAccount', 'sqlVersion', 'sqlInstanceName', 'sqlPort', 'sqlInstanceDir', 'network') {
        foreach ($primaryNode in $true, $false) {
            Reset-Fixture
            $node = [pscustomobject]@{ vmName = 'SQLAO1'; Role = 'SQLAO' }
            if ($primaryNode) { $node | Add-Member -NotePropertyName OtherNode -NotePropertyValue 'MissingNode' }
            $node | Add-Member -NotePropertyName $field -NotePropertyValue 'Changed'
            $global:Config.virtualMachines = @($node)
            Get-AdditionalValidations -property $node -name $field -CurrentValue 'Original'
            Assert-ValidationError
            Assert-Equal 'Original' $node.$field 'A SQLAO edit was not rolled back when its partner was missing.'
        }
        Reset-Fixture
        $node = [pscustomobject]@{ vmName = 'SQLAO1'; Role = 'SQLAO'; OtherNode = 'SQLAO2' }
        $node | Add-Member -NotePropertyName $field -NotePropertyValue 'Changed'
        $partner = [pscustomobject]@{ vmName = 'SQLAO2'; Role = 'SQLAO' }
        $global:Config.virtualMachines = @($node, $partner)
        Get-AdditionalValidations -property $node -name $field -CurrentValue 'Original'
        $expected = if ($field -eq 'sqlPort') { '1433' } else { 'Changed' }
        Assert-Equal $expected $partner.$field 'A SQLAO partner with an unset property could not be updated safely.'
    }
    foreach ($missingPartner in $false, $true) {
        Reset-Fixture
        $site = $global:Config.virtualMachines[0]
        $site.SiteCode = 'PS2'
        $site | Add-Member -NotePropertyName remoteSQLVM -NotePropertyValue 'SQL1'
        if ($missingPartner) { $global:Config.virtualMachines[1] | Add-Member -NotePropertyName OtherNode -NotePropertyValue 'MissingNode' }
        else { $global:Config.virtualMachines = @($site) }
        Get-AdditionalValidations -property $site -name 'siteCode' -CurrentValue 'PS1'
        Assert-ValidationError
        Assert-Equal 'PS1' $site.SiteCode 'A site-code change was not rolled back when SQL dependencies were missing.'
        Assert-Equal 0 $script:Prompts 'An invalid dependency reached an interactive rename prompt.'
    }
    Reset-Fixture
    $site = $global:Config.virtualMachines[0]
    $site.SiteCode = 'PS2'
    $site | Add-Member -NotePropertyName remoteSQLVM -NotePropertyValue 'SQL1'
    $global:Config.virtualMachines[1] | Add-Member -NotePropertyName OtherNode -NotePropertyValue 'SQL2'
    $global:Config.virtualMachines += [pscustomobject]@{ vmName = 'SQL2'; Role = 'SQLAO' }
    Get-AdditionalValidations -property $site -name 'siteCode' -CurrentValue 'PS1'
    Assert-Equal 'PS2SQLAO1' $site.remoteSQLVM 'A valid SQLAO site-code change did not rename the SQL reference.'
    Assert-Equal 'PS2SQLAO2' $global:Config.virtualMachines[2].vmName 'A valid SQLAO site-code change did not rename the partner.'

    foreach ($siteCode in @($null, '', ' ', 'BAD')) {
        Reset-Fixture
        $vm = [pscustomobject]@{ vmName = 'SUP1'; Role = 'SiteSystem'; SiteCode = $siteCode; wsusDataBaseServer = 'SQL1' }
        $global:Config.virtualMachines += $vm
        Assert-Equal 'REFRESH' (Get-WsusDBName -property $vm -name 'wsusDataBaseServer') 'An unresolved WSUS site did not return safely to its menu.'
        Assert-Equal 'ESCAPE' (select-PullDPMenu -CurrentVM $vm) 'An unresolved Pull DP site did not return safely to its menu.'
        Assert-Equal 'ESCAPE' (select-ReplicaSQLMenu -CurrentVM $vm) 'An unresolved replica site did not return safely to its menu.'
        Assert-ValidationError
    }
    foreach ($role in 'PassiveSite', 'SiteSystem') {
        Reset-Fixture
        $vm = [pscustomobject]@{ vmName = 'NEWVM'; Role = $role; SiteCode = 'BAD' }
        Assert-Equal $null (Get-NetworkForVM -vm $vm -ReturnIfNotNeeded:$true) 'A missing site should not invent a network.'
        Assert-ValidationError
    }
    Reset-Fixture
    $global:Config.virtualMachines = @()
    $script:Inventory = @([pscustomobject]@{ vmName = 'EXISTINGSITE'; Role = 'Primary'; SiteCode = 'PS1'; network = '10.200.0.0' })
    $vm = [pscustomobject]@{ vmName = 'PASSIVE1'; Role = 'PassiveSite'; SiteCode = 'PS1' }
    Assert-Equal '10.200.0.0' (Get-NetworkForVM -vm $vm -ReturnIfNotNeeded:$true) 'A valid existing site was rejected by the dependency guard.'
    Reset-Fixture
    $global:Config.virtualMachines[0].InstallDP = $true
    $before = Get-FixtureState
    Set-Responses @('ESCAPE')
    Assert-Equal 'ESCAPE' (select-PullDPMenu -CurrentVM $global:Config.virtualMachines[0]) 'Cancelling a source-DP selection did not return to the menu.'
    Assert-Equal $before (Get-FixtureState) 'Cancelling a source-DP selection changed the configuration.'
    foreach ($field in 'installSUP', 'installMP', 'installDP', 'useDatabaseReplica', 'enablePullDP') {
        Reset-Fixture
        $vm = [pscustomobject]@{ vmName = 'ROLE1'; Role = 'SiteSystem'; SiteCode = 'BAD' }
        $vm | Add-Member -NotePropertyName $field -NotePropertyValue $true
        Get-AdditionalValidations -property $vm -name $field -CurrentValue $false
        Assert-ValidationError
        Assert-Equal $false $vm.$field 'A role edit with an invalid site was not rolled back.'
    }
    foreach ($handler in 'Get-WsusDBName', 'Get-ReplicaSQLVM') {
        Reset-Fixture
        $vm = [pscustomobject]@{ vmName = 'SUPMP1'; Role = 'SiteSystem'; SiteCode = 'PS1'; wsusDataBaseServer = 'SQL1'; replicaSqlServerVM = 'SQL1' }
        $global:Config.virtualMachines += $vm
        $before = Get-FixtureState
        Set-Responses @('MissingSQL')
        & $handler -property $vm -name 'wsusDataBaseServer' | Out-Null
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'A stale SQL menu selection changed the previous database settings.'
    }
    foreach ($selection in 'N', 'A') {
        Reset-Fixture
        $site = $global:Config.virtualMachines[0]
        $site.SiteCode = ''
        $before = Get-FixtureState
        Set-Responses @($selection)
        Get-remoteSQLVM -property $site
        Assert-ValidationError
        Assert-Equal $before (Get-FixtureState) 'An empty site code created remote SQL VMs.'
    }

    Reset-Fixture
    $wsus = $global:Config.virtualMachines[0]
    $wsus.Role = 'WSUS'
    $wsus | Add-Member -NotePropertyName remoteSQLVM -NotePropertyValue 'SQL1'
    Set-Responses @('W')
    Get-remoteSQLVM -property $wsus
    Assert-Equal $null $wsus.PSObject.Properties['sqlVersion'] 'Standalone WSUS did not switch safely from SQL to WID.'
    Assert-Equal $null $wsus.PSObject.Properties['remoteSQLVM'] 'Standalone WSUS retained the remote SQL reference after choosing WID.'

    Reset-Fixture
    $site = $global:Config.virtualMachines[0]
    $site | Add-Member -NotePropertyName remoteSQLVM -NotePropertyValue 'SQL1'
    $global:Config.virtualMachines[1] | Add-Member -NotePropertyName installRP -NotePropertyValue $true
    $global:Config.virtualMachines += [pscustomobject]@{ vmName = 'PS2SITE'; Role = 'Primary'; SiteCode = 'PS2' }
    Assert-Equal 'PS2' (Get-ValidSiteCodesForRP -Config $global:Config) 'The reporting-point site menu did not handle a remote SQL RP without its own site code.'

    foreach ($handler in 'Get-OperatingSystemMenuClient', 'Get-OperatingSystemMenuServer', 'Get-OperatingSystemMenu', 'Set-ParentSiteCodeMenu',
        'Get-SqlVersionMenu', 'Get-ForestTrustMenu', 'Get-CMVersionMenu', 'Get-RoleMenu') {
        Reset-Fixture
        Set-Responses @('ESCAPE')
        & $handler -property $global:Config.virtualMachines[0] -name 'testProperty' -CurrentValue $null | Out-Null
        Assert-Equal 0 @($global:GenConfigErrorMessages).Count "Cancelling $handler with an empty current value produced an error."
    }
    Reset-Fixture
    $before = Get-FixtureState
    Set-Responses @($null)
    Get-RoleMenu -property $global:Config.virtualMachines[0] -name 'Role' -CurrentValue 'Primary' | Out-Null
    Assert-ValidationError
    Assert-Equal $before (Get-FixtureState) 'An empty role selection deleted or replaced the original VM.'
    foreach ($field in 'E', 'F', 'G', 'memory', 'dynamicMinRam') {
        Reset-Fixture
        $property = [pscustomobject]@{ memory = '12GB'; dynamicMinRam = '4GB' }
        $property | Add-Member -NotePropertyName $field -NotePropertyValue '8' -Force
        Get-AdditionalValidations -property $property -name $field -CurrentValue $null
        Assert-ValidationError
        Assert-Equal $null $property.$field 'A size without an existing unit was not rolled back.'
        $global:GenConfigErrorMessages = @()
        $property | Add-Member -NotePropertyName $field -NotePropertyValue '8GB' -Force
        Get-AdditionalValidations -property $property -name $field -CurrentValue $null
        Assert-Equal '8GB' $property.$field 'An explicit size could not repair an empty previous value.'
        Assert-Equal 0 @($global:GenConfigErrorMessages).Count 'A valid explicit size generated a validation error.'
    }
    foreach ($action in 'Proxy', 'ClearMessages', 'Domain', 'AddRole', 'AddDomain', 'AddPrefix', 'PullSite', 'OsRole', 'SiteDomain') {
        Reset-Fixture
        switch ($action) {
            'Proxy' { Invoke-ProxyOptInCleanup -ProxyVmName '' }
            'ClearMessages' { Clear-StaleValidationMessagesForVM -VmName '' }
            'Domain' { Get-TargetSitesForDomain -property $global:Config.virtualMachines[0] -Domain '' }
            'AddRole' { Add-NewVMForRole -Role '' -Domain 'example.test' }
            'AddDomain' { Add-NewVMForRole -Role 'SqlServer' -Domain '' }
            'AddPrefix' { $global:Config.vmOptions.prefix = ''; Add-NewVMForRole -Role 'SqlServer' -Domain 'example.test' }
            'PullSite' { Get-ListOfPossibleDPMP -siteCode '' }
            'OsRole' { Get-SupportedOperatingSystemsForRole -role '' }
            'SiteDomain' { Get-SiteCodeForDPMP -Domain '' }
        }
        Assert-ValidationError
    }

    Reset-Fixture
    Remove-VMFromConfig -vmName ''
    Show-GenConfigErrorMessages
    Assert-Equal $true (($script:Rendered -join ' ') -like '*ERROR: Validation Failures were encountered:*') 'A rejected edit was not rendered as a validation failure.'
    Assert-Equal 1 @($global:PendingValidationErrors).Count 'Rendering the error erased its carry-over notification.'
    Add-ErrorMessage -property 'vmName' -Persist $global:PendingValidationErrors[0].Message
    Assert-Equal 1 @($global:PendingValidationErrors).Count 'Persisting the same rejected edit duplicated its carry-over notification.'

    foreach ($validator in 'Test-MachineNameExists', 'Test-ValidMachineName') {
        foreach ($name in @($null, '', ' ', 'MissingVM')) {
            Reset-Fixture
            $result = New-ValidationResult
            if ($validator -eq 'Test-MachineNameExists') {
                Test-MachineNameExists -name $name -ReturnObject $result -config $global:Config
            }
            elseif ($name -ne 'MissingVM') {
                Test-ValidMachineName -name $name -ReturnObject $result
            }
            else { continue }
            Assert-Equal 1 $result.Failures 'An empty or missing name was not a blocking validation failure.'
        }
    }
    foreach ($reference in 'remoteSQLVM', 'replicaSqlServerVM', 'wsusDataBaseServer', 'fileServerVM', 'pullDPSourceDP', 'OtherNode', 'remoteContentLibVM', 'PatchMyPCFileServer') {
        foreach ($value in '', 'MissingVM') {
            Reset-Fixture
            $vm = [pscustomobject]@{ vmName = 'MEM1'; Role = 'DomainMember'; operatingSystem = 'Server 2022' }
            $vm | Add-Member -NotePropertyName $reference -NotePropertyValue $value
            $result = New-ValidationResult
            Test-ValidVmSupported -VM $vm -ConfigObject $global:Config -ReturnObject $result
            Assert-Equal $true ($result.Failures -gt 0) "Invalid $reference was not a blocking validation failure."
        }
    }
    Reset-Fixture
    $script:ValidationMode = 'EmptyResult'
    Assert-Equal $false (Get-TestResult -SuccessOnWarning) 'An empty validation result was treated as successful validation.'
    Assert-ValidationError
    Reset-Fixture
    $script:ValidationMode = 'BindingFailure'
    Assert-Equal $false (Get-TestResult -SuccessOnWarning) 'An argument-binding failure was reported as successful validation.'
    Assert-ValidationError
    $script:ValidationMode = 'UnexpectedFailure'
    $unexpectedVisible = $false
    try { Get-TestResult | Out-Null }
    catch [System.IO.IOException] { $unexpectedVisible = $true }
    Assert-Equal $true $unexpectedVisible 'An unexpected implementation error was silently swallowed.'

    . (Import-TestFunction '..\genconfig.ps1' 'Select-MainMenu')
    . (Import-TestFunction 'Common.Validation.ps1' 'Convert-ValidationMessages')
    function Add-OfflineRootCAVMIfMissing { param($ConfigToModify) }
    function Remove-OfflineRootCAVMIfAutoAdded { param($ConfigToModify) }
    function Add-ProxyVMIfMissing { param($ConfigToModify) }
    function Remove-ProxyVMIfAutoAdded { param($ConfigToModify) }
    function Build-MainMenuOptions {
        [pscustomobject]@{ PreOptions = [ordered]@{}; Options = [ordered]@{}; VMNameToNumberMap = @{} }
    }
    function Select-VirtualMachines {
        param($Response, $NewValue)
        if ($script:ActionFailure -eq 'Unexpected') { throw [System.IO.IOException]::new('Unexpected menu implementation failure') }
        Test-RequiresName -VmName ''
    }
    Reset-Fixture
    $global:existingMachines = @([pscustomobject]@{ vmName = 'EXISTING' })
    $script:RenderMenuErrors = $true
    $before = Get-FixtureState
    Set-Responses @('N', 'S')
    Assert-Equal $false (Select-MainMenu) 'The menu did not remain usable after an unanticipated argument-binding failure.'
    Assert-Equal $before (Get-FixtureState) 'The menu exception boundary modified the configuration.'
    Assert-Equal $true (($script:Rendered -join ' ') -like '*ERROR: Validation Failures were encountered:*') 'The menu boundary did not render a validation failure after its redraw.'
    Assert-Equal $true (($script:Rendered -join ' ') -like '*Cannot complete menu action*') 'The menu boundary lost the failed-action diagnostic.'
    Reset-Fixture
    $global:existingMachines = @([pscustomobject]@{ vmName = 'EXISTING' })
    $script:ActionFailure = 'Unexpected'
    Set-Responses @('N')
    $unexpectedVisible = $false
    try { Select-MainMenu | Out-Null }
    catch [System.IO.IOException] { $unexpectedVisible = $true }
    Assert-Equal $true $unexpectedVisible 'The menu boundary hid an unrelated implementation error.'

    . (Import-TestFunction 'Common.Validation.ps1' 'Test-Configuration')
    function New-DeployConfig {
        param($configObject)
        if ($script:PipelineMode -eq 'Throw') { throw [System.ArgumentException]::new('Invalid VM dependency during normalization') }
        $configObject
    }
    function Test-ValidVmOptions {
        param($ConfigObject, $ReturnObject)
        if ($script:PipelineMode -eq 'Failure') {
            Add-ValidationMessage -Message 'VM Validation: Required dependency is missing.' -ReturnObject $ReturnObject -Failure
        }
    }
    function Test-ValidVmMemory { param($VM, $ReturnObject) }
    function Test-ValidVmDisks { param($VM, $ReturnObject) }
    function Test-ValidVmProcs { param($VM, $ReturnObject) }
    function Test-ValidRoleDC { param($ConfigObject, $ReturnObject) }
    function Test-ValidDiskSpace { param($ConfigObject, $ReturnObject) }
    function Add-ExistingVMsToDeployConfig { param($Config) }
    function ConvertTo-DeployConfigEx {
        param($deployConfig)
        $script:Enhancements++
        $deployConfig
    }

    $global:DisableSmartUpdate = $false
    $global:TestConfigFastCache = $null
    $global:MemLabsSkipValidation = $false

    $tokens = $null
    $errors = $null
    $menuAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'genconfig.ps1'), [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "genconfig.ps1 has parse errors: $($errors -join '; ')" }
    $actionValidators = @($menuAst.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst] -or $node.GetCommandName() -ne 'Test-Configuration') { return $false }
                $parent = $node.Parent
                while ($parent) {
                    if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $false }
                    $parent = $parent.Parent
                }
                return $true
            }, $true))
    Assert-Equal 1 $actionValidators.Count 'Expected one validation command after the deployment menu returns.'
    $validateMenuAction = [scriptblock]::Create($actionValidators[0].Extent.Text)

    foreach ($emptyState in 'Null', 'Empty', 'Missing') {
        Reset-Fixture
        switch ($emptyState) {
            'Null' { $global:Config.virtualMachines = $null }
            'Empty' { $global:Config.virtualMachines = @() }
            'Missing' { $global:Config.PSObject.Properties.Remove('virtualMachines') }
        }
        $before = Get-FixtureState
        foreach ($fast in $false, $true) {
            $result = Test-Configuration -InputObject $global:Config -Fast:$fast
            Assert-Equal $true $result.Valid "$emptyState VM lists must be allowed while editing or saving a draft."
            Assert-Equal 0 $result.Failures "$emptyState VM lists were mistaken for unnamed VM entries."
        }
        Assert-Equal $true (Get-TestResult) 'Property-menu validation rejected an empty deployment draft.'
        $global:existingMachines = @([pscustomobject]@{ vmName = 'T-UNCHANGED' })
        $script:RenderMenuErrors = $true
        Set-Responses @('S')
        Assert-Equal $false (Select-MainMenu) 'An empty draft could not leave the menu using Save.'
        Assert-Equal 0 @($global:GenConfigErrorMessages).Count 'Browsing an empty deployment rendered a validation error.'
        Assert-Equal $before (Get-FixtureState) 'Empty-draft validation changed the configuration.'

        foreach ($deployNow in $false, $true) {
            $return = [pscustomobject]@{ DeployNow = $deployNow }
            $script:Enhancements = 0
            $result = & $validateMenuAction
            Assert-Equal (-not $deployNow) $result.Valid 'The actual menu action validator did not distinguish Save from Deploy.'
            if ($deployNow) {
                Assert-Equal 1 $result.Failures 'An empty deployment must produce one blocking failure.'
                Assert-Equal $true ($result.Message -like '*Nothing to deploy or update*') 'The empty-deployment error did not explain how to proceed.'
                Assert-Equal 0 $script:Enhancements 'An empty deployment reached dependency enhancement.'
            }
        }
        $result = Test-Configuration -InputObject $global:Config -Final
        Assert-Equal $false $result.Valid 'The New-Lab final validation path accepted an empty deployment.'
        Assert-Equal $true ($result.Message -like '*Nothing to deploy or update*') 'Final validation did not report the empty deployment.'

        $global:DisableSmartUpdate = $true
        $preview = Test-Configuration -InputObject $global:Config -Fast
        Assert-Equal $true $preview.Valid 'The cached empty-draft preview was invalid.'
        $result = Test-Configuration -InputObject $global:Config -Fast -RequireDeploymentTargets
        Assert-Equal $false $result.Valid 'A cached valid draft bypassed the deployment-target requirement.'
    }

    foreach ($candidate in @($null, [pscustomobject]@{ vmName = '' }, [pscustomobject]@{ vmName = ' ' })) {
        Reset-Fixture
        $global:Config.virtualMachines = @($candidate)
        $result = Test-Configuration -InputObject $global:Config
        Assert-Equal $false $result.Valid 'An unnamed VM was reported as a valid configuration.'
        Assert-Equal 1 $result.Failures 'An unnamed VM was not counted as a validation failure.'
        Assert-Equal $true ($result.Message -like '*non-empty vmName*') 'An unnamed VM did not produce an actionable validation message.'
    }
    foreach ($mode in 'Throw', 'Failure', 'Valid') {
        Reset-Fixture
        $global:Config.virtualMachines = @([pscustomobject]@{ vmName = 'MEM1'; Role = 'DomainMember'; operatingSystem = 'Server 2022' })
        $script:PipelineMode = $mode
        $script:Enhancements = 0
        $script:ExceptionsLogged = 0
        $result = Test-Configuration -InputObject $global:Config
        if ($mode -eq 'Valid') {
            Assert-Equal $true $result.Valid 'The guarded validation pipeline rejected a valid configuration.'
            Assert-Equal 1 $script:Enhancements 'The guarded validation pipeline skipped enhancement of a valid configuration.'
        }
        else {
            Assert-Equal $false $result.Valid 'An invalid configuration passed validation.'
            Assert-Equal $true ($result.Failures -gt 0) 'An invalid configuration did not increment Failures.'
            Assert-Equal 0 $script:Enhancements 'An invalid configuration reached dependency enhancement.'
            Assert-Equal $false (Get-TestResult -SuccessOnWarning) 'SuccessOnWarning incorrectly bypassed a validation failure.'
        }
    }

    foreach ($name in 'Add-ModifiedExistingVMsToConfig', 'Test-AnyExistingVMModified', 'Build-MainMenuOptions') {
        . (Import-TestFunction '..\genconfig.ps1' $name)
    }
    . (Import-TestFunction 'Common.GenConfig.Validation.ps1' 'get-IsExistingVMModified')
    foreach ($name in 'ConvertFrom-MemLabsVmNoteScalar', 'Add-ModifiedExistingVMToDeployConfig') {
        . (Import-TestFunction 'Common.Config.ps1' $name)
    }
    function Get-VMOptionsSummary { '' }
    function Get-PKIOptionsSummary { '' }
    function Get-VMString {
        param($Config, $VirtualMachine, [switch] $Colors)
        $VirtualMachine.vmName
    }
    function Start-VM2 {
        param($Name)
        throw "The isolated menu test must not start VM '$Name'."
    }
    $InternalUseOnly = [switch] $true
    foreach ($includeNewVM in $false, $true) {
        Reset-Fixture
        $global:Config.virtualMachines = $null
        if ($includeNewVM) {
            $global:Config.virtualMachines = @([pscustomobject]@{ vmName = 'NEW1'; Role = 'DomainMember'; operatingSystem = 'Server 2022' })
        }
        $existingVM = [pscustomobject]@{
            vmName = 'T-MEM1'; Role = 'DomainMember'; operatingSystem = 'Server 2022'; state = 'Running'
            ExistingVM = $true; useProxy = $true; 'useProxy-Original' = $false
        }
        $global:existingMachines = @($existingVM)
        $script:Inventory = @($existingVM)
        $built = Build-MainMenuOptions
        Assert-Equal $true ($built.Options['D'] -like '*Apply Changes*') 'The shared action does not advertise existing-VM updates.'
        Assert-Equal $true ($built.Options['HD'] -like '*existing VMs*') 'The shared action help does not explain existing-VM updates.'
        Assert-Equal $true (Test-AnyExistingVMModified) 'An existing-VM edit was not detected.'
        Set-Responses @('D')
        Assert-Equal $true (Select-MainMenu) 'The shared action did not queue existing-VM changes.'
        Assert-Equal (1 + [int] $includeNewVM) @($global:Config.virtualMachines).Count 'Staging an existing-VM edit added an unexpected VM.'
        $stagedVM = $global:Config.virtualMachines | Where-Object vmName -eq 'T-MEM1'
        Assert-Equal $true $stagedVM.hidden 'An existing VM was staged as a new VM.'
        Assert-Equal $true $stagedVM.ExistingVM 'The staged VM lost its existing-VM update marker.'
        Assert-Equal $true $stagedVM.useProxy 'The staged VM lost its edited property.'
        Assert-Equal $true $stagedVM.phase11Validate 'The staged VM was not scheduled for post-update validation.'
        Assert-Equal $null $stagedVM.PSObject.Properties['useProxy-Original'] 'An edit-session marker leaked into the saved configuration.'
        $return = [pscustomobject]@{ DeployNow = $true }
        $result = & $validateMenuAction
        Assert-Equal $true $result.Valid "Existing-VM updates were rejected (includes new VM: $includeNewVM): $($result.Message)"
        Add-ModifiedExistingVMsToConfig
        Assert-Equal (1 + [int] $includeNewVM) @($global:Config.virtualMachines).Count 'Staging the same update twice duplicated the existing VM.'
    }

    Reset-Fixture
    $global:Config.virtualMachines = $null
    $global:existingMachines = @([pscustomobject]@{
            vmName = 'T-MEM1'; ExistingVM = $true; useProxy = $false; 'useProxy-Original' = $false
        })
    Assert-Equal $false (Test-AnyExistingVMModified) 'A reverted edit was still treated as modified.'
    Set-Responses @('D')
    Assert-Equal $true (Select-MainMenu) 'The menu did not return the selected deployment action.'
    Assert-Equal 0 @($global:Config.virtualMachines | Where-Object { $_ }).Count 'An unchanged existing VM was queued for deployment.'
    $return = [pscustomobject]@{ DeployNow = $true }
    $result = & $validateMenuAction
    Assert-Equal $false $result.Valid 'Unchanged existing inventory made an empty deployment valid.'
    Convert-ValidationMessages -TestObject $result
    Show-GenConfigErrorMessages
    Assert-Equal $true (($script:Rendered -join ' ') -like '*Nothing to deploy or update*') 'The empty-deployment failure was not visible to the operator.'
    Write-Host "PASS: $($script:Assertions) assertions cover invalid VM references, empty drafts, shared deploy/update actions, menu error rendering, edit rollback and fail-closed validation." -ForegroundColor Green
}
finally {
    foreach ($name in $savedGlobals.Keys) {
        if ($savedGlobals[$name].Exists) { Set-Variable -Name $name -Scope Global -Value $savedGlobals[$name].Value }
        else { Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue }
    }
}
