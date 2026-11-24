#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'DSC\phases\ScriptFunctions.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Guest function parse errors: $($errors -join '; ')" }
foreach ($name in @('Test-MemLabsWorkflowContextOnlyVM', 'Get-MemLabsRetainedCasContext',
        'Assert-MemLabsRetainedCasNativePrerequisites', 'Assert-MemLabsSelectedSupPrerequisite', 'Wait-MemLabsNewChildReplicationNative')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
    if (-not $definition) { throw "Required helper '$name' was not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Get-VmSqlConnectionTarget {
    param($SiteVm, $DeployConfig, $DomainFullName)
    return 'SQL1.fixture.test,1544'
}
function Write-DscStatus { param($Status, $RetrySeconds) }
function Restart-Service { throw 'Existing CAS services must not be repaired.' }
function Invoke-CMDatabaseReplicationSynchronization { throw 'Existing DRS must not be reinitialized.' }
function Read-ScriptWorkflowData { throw 'Retained CAS workflow receipts must not be read.' }
$cas = [pscustomobject]@{ vmName = 'CAS1'; role = 'CAS'; siteCode = 'CAS'; hidden = $true }
$child = [pscustomobject]@{
    vmName = 'NEWPRI'; role = 'Primary'; siteCode = 'NEW'; parentSiteCode = 'CAS'
    thisParams = [pscustomobject]@{ ParentSiteServer = 'CAS1' }
}
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'fixture.test' }
    virtualMachines = @($cas, $child)
}
$context = Get-MemLabsRetainedCasContext -DeployConfig $config -ChildPrimaryVM $child
Assert-True ($context.Fqdn -eq 'CAS1.fixture.test' -and $context.SqlDataSource -eq 'SQL1.fixture.test,1544') `
    'Retained CAS context lost exact site identity or non-default SQL addressing.'
foreach ($mode in @('NoSelection', 'NullSelection', 'Success', 'OtherSiteFailed', 'PrereqOnlySuccess',
        'PrereqOnlyWarning', 'Installing', 'MissingCatalog', 'MissingLocal', 'MissingState', 'Ambiguous',
        'PrereqNotOnly', 'NoSqlAccess', 'WrongCas', 'ProviderError')) {
    & {
        param($Mode)
        $script:CasMode = $Mode
        function Invoke-Command {
            param($ComputerName, $ArgumentList, $ErrorAction, $ScriptBlock)
            Assert-True ($ComputerName -eq 'CAS1.fixture.test') 'Native prerequisite query selected an unrelated CAS.'
            return [pscustomobject]@{ SiteCode = 'CAS'; FullVersion = '5.0.9142.1000'; InstallDir = 'C:\ConfigMgr'; SourceShare = 'SMS_CAS' }
        }
        function Get-WmiObject {
            param($ComputerName, $Namespace, $Class, $Filter, $ErrorAction)
            if ($script:CasMode -eq 'ProviderError') { throw 'Deliberately broken CAS provider.' }
            if ($Class -eq 'SMS_ProviderLocation') {
                return [pscustomobject]@{ ProviderForLocalSite = $true; SiteCode = 'CAS'; Machine = 'CAS1.fixture.test' }
            }
            return [pscustomobject]@{
                Type = 4; Status = $(if ($script:CasMode -eq 'WrongCas') { 3 } else { 1 })
                ServerName = 'CAS1.fixture.test'; Version = '5.0.9142.1000'
            }
        }
        function Get-MemLabsRetainedCasSqlState {
            param($CasContext)
            $row = [pscustomobject]@{
                SelectedPackageGuid = 'selected'; CatalogPackageGuid = 'selected'; CasStatusPackageGuid = 'selected'
                CasLocalState = 196612; PrereqFlag = 0
            }
            $rows = @($row)
            switch ($script:CasMode) {
                NoSelection { $rows = @() }
                NullSelection { $row.SelectedPackageGuid = $null }
                OtherSiteFailed { $row | Add-Member NoteProperty OverallOtherSiteFailure 262143 }
                PrereqOnlySuccess { $row.CasLocalState = 131074; $row.PrereqFlag = 1 }
                PrereqOnlyWarning { $row.CasLocalState = 131075; $row.PrereqFlag = 1 }
                Installing { $row.CasLocalState = 196609 }
                MissingCatalog { $row.CatalogPackageGuid = $null }
                MissingLocal { $row.CasStatusPackageGuid = $null }
                MissingState { $row.CasLocalState = $null }
                Ambiguous { $rows = @($row, $row) }
                PrereqNotOnly { $row.CasLocalState = 131074 }
            }
            return [pscustomobject]@{
                SiteCode = 'CAS'; IsSysadmin = $(if ($script:CasMode -eq 'NoSqlAccess') { 0 } else { 1 })
                Updates = $rows
            }
        }
        $failure = ''
        try { Assert-MemLabsRetainedCasNativePrerequisites -CasContext $context }
        catch { $failure = $_.Exception.Message }
        $accepted = $Mode -in @('NoSelection', 'NullSelection', 'Success', 'OtherSiteFailed', 'PrereqOnlySuccess', 'PrereqOnlyWarning')
        Assert-True ((-not $failure) -eq $accepted) "CAS native selected/local state '$Mode' was classified incorrectly."
    } $mode
}
foreach ($mode in @('Active', 'Initializing', 'SiteDataNotReady', 'WrongPair', 'MissingDirection', 'Failed', 'ReadError')) {
    & {
        param($Mode)
        $script:LinkMode = $Mode
        $script:LinkReads = 0
        function Get-WmiObject {
            param($ComputerName, $Namespace, $Class, $Filter, $ErrorAction)
            $script:LinkReads++
            Assert-True ($Filter -eq "Site1='CAS' AND Site2='NEW'") 'Replication observation broadened beyond the one new link.'
            if ($script:LinkMode -eq 'ReadError') { throw 'Deliberately broken link read.' }
            $row = [pscustomobject]@{
                Site1 = 'CAS'; Site2 = 'NEW'; SiteType1 = 4; SiteType2 = 2
                LinkStatus = 2; Site1ToSite2GlobalState = 2; Site2ToSite1GlobalState = 2; Site2ToSite1SiteState = 2
            }
            switch ($script:LinkMode) {
                Initializing { if ($script:LinkReads -eq 1) { $row.LinkStatus = 4 } }
                SiteDataNotReady { $row.Site2ToSite1SiteState = 8 }
                WrongPair { $row.Site2 = 'OLD-BROKEN' }
                MissingDirection { $row.PSObject.Properties.Remove('Site2ToSite1SiteState') }
                Failed { $row.LinkStatus = 9 }
            }
            return $row
        }
        function Start-Sleep {
            param($Seconds)
            if ($script:LinkMode -ne 'Initializing') { throw 'Unverified current link was observed, never repaired or accepted.' }
        }
        $failure = ''
        try { Wait-MemLabsNewChildReplicationNative -CasContext $context -TimeoutMinutes 1 }
        catch { $failure = $_.Exception.Message }
        Assert-True ((-not $failure) -eq ($Mode -in @('Active', 'Initializing'))) `
            "Current native link '$Mode' was accepted without the required real data flow."
    } $mode
}
foreach ($case in @('Ready', 'NlbSsl', 'UnrelatedBrokenSup', 'NoDefault', 'Disabled', 'MissingRole',
        'AmbiguousRole', 'AmbiguousWcm', 'WrongWcm', 'InvalidPort', 'BrokenEndpoint', 'Busy', 'InvalidProof')) {
    & {
        param($Case)
        $script:SupCase = $Case
        $script:SupApiCalls = 0
        function Get-WmiObject {
            param($ComputerName, $Namespace, $Class, $Filter, $ErrorAction)
            if ($Class -eq 'SMS_ProviderLocation') {
                return [pscustomobject]@{ SiteCode = 'CAS'; ProviderForLocalSite = $true; Machine = 'CAS1.fixture.test' }
            }
            if ($Class -eq 'SMS_SCI_Component') {
                Assert-True ($Filter -like "*Name='SMS Site Server'*" -and $Filter -notlike '*FileType*') `
                    'CAS WCM was selected by a physical hostname or incorrect legacy FileType instead of its native logical key.'
                $row = [pscustomobject]@{
                    FileType = 2; Name = 'SMS Site Server'; ItemName = 'SMS_WSUS_CONFIGURATION_MANAGER|SMS Site Server'
                    Props = @([pscustomobject]@{
                            PropertyName = 'DefaultWSUS'; Value = 'not-the-pointer'
                            Value2 = $(if ($script:SupCase -eq 'NoDefault') { '' } else { 'UPSTREAM.fixture.test' })
                        })
                }
                if ($script:SupCase -eq 'WrongWcm') { $row.ItemName = 'unrelated-component' }
                $row
                if ($script:SupCase -eq 'AmbiguousWcm') { $row }
                return
            }
            if ($Class -ne 'SMS_SCI_SysResUse') { throw "Unexpected upstream prerequisite read '$Class'." }
            if ($script:SupCase -eq 'MissingRole') { return }
            $props = @(
                [pscustomobject]@{ PropertyName = 'Enabled'; Value = $(if ($script:SupCase -eq 'Disabled') { 0 } else { 1 }) },
                [pscustomobject]@{ PropertyName = 'SSLWSUS'; Value = $(if ($script:SupCase -eq 'NlbSsl') { 1 } else { 0 }) },
                [pscustomobject]@{ PropertyName = 'WSUSIISPort'; Value = $(if ($script:SupCase -eq 'InvalidPort') { 0 } else { 8530 }) },
                [pscustomobject]@{ PropertyName = 'WSUSIISSSLPort'; Value = 8531 },
                [pscustomobject]@{ PropertyName = 'NLBVIP'; Value2 = $(if ($script:SupCase -eq 'NlbSsl') { 'WSUS-VIP.fixture.test' } else { '' }) }
            )
            $row = [pscustomobject]@{ NetworkOSPath = '\\UPSTREAM.fixture.test'; Props = $props }
            $row
            if ($script:SupCase -eq 'AmbiguousRole') { $row }
            if ($script:SupCase -eq 'UnrelatedBrokenSup') { [pscustomobject]@{ NetworkOSPath = '\\INTENTIONALLY-BROKEN.fixture.test'; Props = @() } }
        }
        function Invoke-CMRoleTargetCommand {
            param($ComputerName, $ArgumentList, $ScriptBlock)
            $script:SupApiCalls++
            $ssl = $script:SupCase -eq 'NlbSsl'
            $expectedServer = if ($ssl) { 'WSUS-VIP.fixture.test' } else { 'UPSTREAM.fixture.test' }
            Assert-True ($ComputerName -eq $env:COMPUTERNAME -and $ArgumentList[0] -eq $expectedServer -and
                $ArgumentList[1] -eq $ssl -and $ArgumentList[2] -eq $(if ($ssl) { 8531 } else { 8530 })) `
                'CAS upstream proof used another SUP, ignored its native endpoint, or claimed a CAS-local probe was a child probe.'
            if ($script:SupCase -eq 'BrokenEndpoint') { throw 'Deliberately broken selected CAS SUP endpoint.' }
            if ($script:SupCase -eq 'InvalidProof') { return [pscustomobject]@{ State = 0 } }
            return [pscustomobject]@{ State = $(if ($script:SupCase -eq 'Busy') { 'Busy' } else { 'Ready' }) }
        }
        function Set-CMSoftwareUpdatePointComponent { throw 'Existing CAS SUP configuration must not be changed.' }
        function Sync-CMSoftwareUpdate { throw 'Existing CAS SUP synchronization must not be triggered.' }
        function Confirm-CMWsusPoolHardening { throw 'Existing CAS WSUS configuration must not be hardened.' }
        $failure = ''
        try { Assert-MemLabsSelectedSupPrerequisite -SiteContext $context }
        catch { $failure = $_.Exception.Message }
        Assert-True ((-not $failure) -eq ($Case -in @('Ready', 'NlbSsl', 'UnrelatedBrokenSup'))) `
            "Required selected CAS SUP '$Case' was not classified correctly: $failure"
        if ($Case -in @('NoDefault', 'Disabled', 'MissingRole', 'AmbiguousRole', 'AmbiguousWcm', 'WrongWcm', 'InvalidPort')) {
            Assert-True ($script:SupApiCalls -eq 0) 'Invalid CAS SUP topology fell back to an arbitrary endpoint.'
        }
    } $case
}
Write-Host "PASS -- $script:Assertions retained-CAS native dependency assertions on PowerShell $($PSVersionTable.PSVersion)."
