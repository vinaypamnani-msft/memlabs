<#
.SYNOPSIS
    Replays denied DP access, guarded permission repair, and PXE measurement offline.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production blocks consume fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path parse errors: $($errors -join '; ')" }
    return $ast
}
function Get-TestFunction {
    param($Ast, [string]$Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name function."
    return $definitions[0]
}
function Get-TestAssignedBlock {
    param($Ast, [string]$Name)
    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq "`$$Name"
            }, $true))
    Assert-True ($assignments.Count -eq 1) "Expected one $Name assignment."
    & ([scriptblock]::Create("$($assignments[0].Extent.Text)`n`$$Name"))
}

$functions = Get-TestAst (Join-Path $root 'DSC\phases\ScriptFunctions.ps1')
$shareFunction = Get-TestFunction $functions 'Get-CMDistributionPointShareAccess'
$workerNodes = @($shareFunction.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true))
Assert-True ($workerNodes.Count -eq 1) 'Expected one bounded DP share-probe worker.'
$worker = & ([scriptblock]::Create($workerNodes[0].Extent.Text))
& {
    $state = [pscustomobject]@{ Mode = 'Ready'; Paths = [System.Collections.Generic.List[string]]::new() }
    function Get-Item {
        param($LiteralPath, [switch]$Force, $ErrorAction)
        $state.Paths.Add($LiteralPath)
        Assert-True ($Force -and $ErrorAction -eq 'Stop') 'The share probe can hide a denied root.'
        if ($state.Mode -eq 'RootDenied') { throw [UnauthorizedAccessException]::new('Access is denied') }
        [pscustomobject]@{ FullName = $LiteralPath }
    }
    function Get-ChildItem {
        param($LiteralPath, [switch]$Force, $ErrorAction)
        if ($state.Mode -eq 'ListDenied') { throw [UnauthorizedAccessException]::new('Access is denied') }
        if ($state.Mode -eq 'Unavailable') { throw [IO.IOException]::new('SMB unavailable') }
        [pscustomobject]@{ Name = 'smsdp.dll' }
    }
    foreach ($mode in @('RootDenied', 'ListDenied', 'Unavailable', 'Ready')) {
        $state.Mode = $mode
        $result = & $worker 'NEWDP.memlabs.test'
        if ($mode -eq 'Ready') { Assert-True $result.Ready 'A readable DP bin directory was rejected.' }
        elseif ($mode -eq 'Unavailable') {
            Assert-True (-not $result.Ready -and $result.Category -eq 'Unreadable') 'An unknown SMB failure was misclassified as permission-repair evidence.'
        }
        else {
            Assert-True (-not $result.Ready -and $result.Category -eq 'AccessDenied' -and
                $result.Error -match 'Access is denied') "$mode lost the actual permission failure."
        }
    }
    Assert-True ($state.Paths[0] -eq '\\NEWDP.memlabs.test\SMS_DP$\sms\bin') 'The probe does not exercise the producer SMB path.'
}

. ([scriptblock]::Create($shareFunction.Extent.Text))
& {
    $state = [pscustomobject]@{ Timeout = $true; Stopped = 0; Removed = 0; InvalidResult = $false }
    function Start-Job { param($ArgumentList, $ScriptBlock) [pscustomobject]@{ State = 'Running' } }
    function Wait-Job {
        param($Job, $Timeout)
        Assert-True ($Timeout -eq 20) 'The SMB probe lost its 20-second host deadline.'
        if (-not $state.Timeout) { $Job.State = 'Completed'; return $Job }
    }
    function Receive-Job {
        param($Job, $ErrorAction)
        if ($state.InvalidResult) { return [pscustomobject]@{ Ready = 'true' } }
        [pscustomobject]@{ Ready = $true; Category = ''; Error = '' }
    }
    function Stop-Job { param($Job, $ErrorAction) $state.Stopped++ }
    function Remove-Job { param($Job, $ErrorAction) $state.Removed++ }
    $result = Get-CMDistributionPointShareAccess -ServerFQDN NEWDP.memlabs.test
    Assert-True (-not $result.Ready -and $result.Category -eq 'TimedOut' -and
        $state.Stopped -eq 1 -and $state.Removed -eq 1) 'A blocked SMB probe survived its deadline or passed readiness.'
    $state.Timeout = $false
    $result = Get-CMDistributionPointShareAccess -ServerFQDN NEWDP.memlabs.test
    Assert-True $result.Ready 'A successful bounded worker result was rejected.'
    $state.InvalidResult = $true
    $result = Get-CMDistributionPointShareAccess -ServerFQDN NEWDP.memlabs.test
    Assert-True (-not $result.Ready -and $result.Error -match 'structured') 'A success-shaped invalid worker result passed readiness.'
}

$repairFunction = Get-TestFunction $functions 'Repair-CMDistributionPointAccess'
$repair = Get-TestAssignedBlock $repairFunction 'repairScript'
& {
    $siteSid = 'S-1-5-21-10-20-30-1001'
    $readerSid = 'S-1-5-21-10-20-30-2001'
    $readerRights = [Security.AccessControl.FileSystemAccessRule]::new(
        ([Security.Principal.SecurityIdentifier]$readerSid),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.AccessControlType]::Allow).FileSystemRights
    $adminAccount = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
    $state = [pscustomobject]@{
        Root = 'C:\SMS_DP$'; Members = @(); ShareAccess = @(); Acls = @{}
        Added = 0; Granted = 0; Written = [System.Collections.Generic.List[string]]::new()
        IgnoreAclWrite = $false; DenyAclRead = $false
    }
    function Reset-Fixture {
        $state.Root = 'C:\SMS_DP$'
        $state.Members = @([pscustomobject]@{ Name = 'MEMLABS\SITESERVER$'; SID = 'S-1-5-21-10-20-30-9999' })
        $state.ShareAccess = @()
        $state.Acls = @{}
        $state.Added = 0
        $state.Granted = 0
        $state.Written.Clear()
        $state.IgnoreAclWrite = $false
        $state.DenyAclRead = $false
        foreach ($path in @('C:\SMS_DP$', 'C:\SMS_DP$\sms', 'C:\SMS_DP$\sms\bin')) {
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $readerSid)) {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        ([Security.Principal.SecurityIdentifier]$sid),
                        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                        [Security.AccessControl.AccessControlType]::Allow))
            }
            $state.Acls[$path] = $acl
        }
    }
    function Get-LocalGroup { param($SID, $ErrorAction) [pscustomobject]@{ Name = 'Administrators' } }
    function Get-LocalGroupMember { param($Group, $ErrorAction) return $state.Members }
    function Add-LocalGroupMember {
        param($Group, $Member, $ErrorAction)
        Assert-True ($Member -eq $siteSid) 'The repair granted membership to an unrelated principal.'
        $state.Added++
        $state.Members += [pscustomobject]@{ SID = $Member }
    }
    function Get-SmbShare { param($Name, $ErrorAction) [pscustomobject]@{ Path = $state.Root } }
    function Get-SmbShareAccess { param($Name, $ErrorAction) return $state.ShareAccess }
    function Grant-SmbShareAccess {
        param($Name, $AccountName, $AccessRight, [switch]$Force, $ErrorAction)
        Assert-True ($Name -eq 'SMS_DP$' -and $AccountName -eq $adminAccount -and $AccessRight -eq 'Full') 'The repair broadened an unrelated share or principal.'
        $state.Granted++
        $state.ShareAccess += [pscustomobject]@{ AccountName = $AccountName; AccessRight = 'Full'; AccessControlType = 'Allow' }
    }
    function Get-Acl {
        param($LiteralPath, $ErrorAction)
        if ($state.DenyAclRead) { throw [UnauthorizedAccessException]::new('security descriptor denied') }
        Assert-True ($state.Acls.ContainsKey($LiteralPath)) "ACL repair escaped its scope: $LiteralPath"
        $copy = [Security.AccessControl.DirectorySecurity]::new()
        $copy.SetSecurityDescriptorSddlForm($state.Acls[$LiteralPath].GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All))
        return $copy
    }
    function Set-Acl {
        param($LiteralPath, $AclObject, $ErrorAction)
        $state.Written.Add($LiteralPath)
        if (-not $state.IgnoreAclWrite) { $state.Acls[$LiteralPath] = $AclObject }
    }
    Reset-Fixture
    $result = & $repair 'MEMLABS\SITESERVER$' $siteSid
    Assert-True ($result.Succeeded -and $state.Added -eq 1 -and $state.Granted -eq 1 -and
        $state.Written.Count -eq 3) "Missing required DP grants were not restored: $($result.Error)"
    foreach ($acl in $state.Acls.Values) {
        Assert-True $acl.AreAccessRulesProtected 'The repair disabled an existing protected ACL.'
        $reader = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                Where-Object { $_.IdentityReference.Value -eq $readerSid })
        Assert-True ($reader.Count -eq 1 -and $reader[0].FileSystemRights -eq $readerRights) 'An unrelated principal was removed or elevated.'
    }
    $result = & $repair 'MEMLABS\SITESERVER$' $siteSid
    Assert-True ($result.Succeeded -and $result.Changes.Count -eq 0 -and $state.Written.Count -eq 3) 'Healthy standard permissions are not idempotent.'

    foreach ($mode in @('ShareDeny', 'NtfsDeny', 'UnreadableAcl', 'WrongRoot')) {
        Reset-Fixture
        switch ($mode) {
            'ShareDeny' { $state.ShareAccess = @([pscustomobject]@{ AccessControlType = 'Deny' }) }
            'NtfsDeny' {
                $state.Acls['C:\SMS_DP$\sms\bin'].AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        ([Security.Principal.SecurityIdentifier]'S-1-5-32-545'),
                        [Security.AccessControl.FileSystemRights]::Write,
                        [Security.AccessControl.AccessControlType]::Deny))
            }
            'UnreadableAcl' { $state.DenyAclRead = $true }
            'WrongRoot' { $state.Root = 'C:\' }
        }
        $result = & $repair 'MEMLABS\SITESERVER$' $siteSid
        Assert-True (-not $result.Succeeded -and $result.Error -and
            $state.Added -eq 0 -and $state.Granted -eq 0 -and $state.Written.Count -eq 0) "$mode did not fail before permission changes."
    }
    Reset-Fixture
    $state.IgnoreAclWrite = $true
    $result = & $repair 'MEMLABS\SITESERVER$' $siteSid
    Assert-True (-not $result.Succeeded -and $result.Error -match 'Could not verify') 'A no-op ACL write was reported as repaired.'
    Reset-Fixture
    $result = & $repair "MEMLABS\$env:COMPUTERNAME`$" $siteSid
    Assert-True ($result.Succeeded -and $state.Added -eq 0) 'A site-server-local DP unnecessarily granted its own computer network-administrator membership.'
}

. ([scriptblock]::Create((Get-TestFunction $functions 'Confirm-CMDistributionPointAccess').Extent.Text))
& {
    $state = [pscustomobject]@{
        Repaired = $true; Accessible = $false; Calls = 0
        Failures = [System.Collections.Generic.List[string]]::new()
    }
    function Repair-CMDistributionPointAccess {
        param($ServerFQDN)
        $state.Calls++
        [pscustomobject]@{ Succeeded = $state.Repaired; Changes = @(); Error = 'fixture repair failure' }
    }
    function Get-CMDistributionPointReadiness {
        param($ServerFQDN, $SiteCode)
        [pscustomobject]@{ AccessReady = $state.Accessible; Detail = 'fixture access denied' }
    }
    function Write-DscStatus {
        param($Message, [switch]$Warning, [switch]$Failure)
        if ($Failure) { $state.Failures.Add($Message) }
    }
    $arguments = @{ ServerFQDN = 'NEWDP.memlabs.test'; SiteCode = 'PRI' }
    $denied = [pscustomobject]@{ AccessErrorCategory = 'AccessDenied' }
    Assert-True (-not (Confirm-CMDistributionPointAccess @arguments -Readiness $denied)) 'A successful ACL API call replaced the actual post-repair access check.'
    Assert-True (($state.Failures -join ' ') -match 'access remains unverified') 'Persistent authentication failure was hidden.'
    $state.Accessible = $true
    Assert-True (Confirm-CMDistributionPointAccess @arguments -Readiness $denied) 'Verified post-repair access did not allow provisioning to continue.'
    $state.Repaired = $false
    Assert-True (-not (Confirm-CMDistributionPointAccess @arguments -Readiness $denied)) 'A failed repair was reported as usable access.'
    $before = $state.Calls
    $unknown = [pscustomobject]@{ AccessErrorCategory = 'Unreadable' }
    $null = Confirm-CMDistributionPointAccess @arguments -Readiness $unknown
    Assert-True ($state.Calls -eq $before) 'An unknown failure triggered permission changes.'
}
foreach ($name in @('Install-DP', 'Install-PullDP')) {
    $installer = Get-TestFunction $functions $name
    $guards = @($installer.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Confirm-CMDistributionPointAccess'
            }, $true))
    Assert-True ($guards.Count -eq 1) "$name does not use the verified access-recovery gate."
}

$validation = Get-TestAst (Join-Path $root 'common\Common.Validation.Functional.ps1')
$payloadLoops = @($validation.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'root' -and
            $node.Extent.Text.Contains('$payloadProbeErrors')
        }, $true))
$errorGuards = @($validation.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$payloadProbeErrors.Count'
        }, $true))
Assert-True ($payloadLoops.Count -eq 1 -and $errorGuards.Count -eq 1) 'Expected one production physical-payload measurement and error verdict.'
$measurePayload = [scriptblock]::Create($payloadLoops[0].Extent.Text)
$recordErrors = [scriptblock]::Create($errorGuards[0].Extent.Text)
& {
    $state = [pscustomobject]@{ Mode = 'Denied' }
    function Get-Item {
        param($LiteralPath, [switch]$Force, $ErrorAction)
        if ($state.Mode -eq 'Denied') { throw [UnauthorizedAccessException]::new('Access is denied') }
        if ($LiteralPath -like '*\SMSBoot') { throw [Management.Automation.ItemNotFoundException]::new('No payload directory') }
        [pscustomobject]@{ FullName = $LiteralPath }
    }
    foreach ($mode in @('Denied', 'Missing')) {
        $state.Mode = $mode
        $tftpRoots = @('C:\SMS_DP$\sms\bin')
        $bootFiles = @()
        $smsBootDirs = @()
        $payloadProbeErrors = @()
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        . $measurePayload
        . $recordErrors
        if ($mode -eq 'Denied') {
            Assert-True (-not $results.Passed -and ($results.Details -join ' ') -match 'Access is denied' -and
                ($results.Details -join ' ') -match 'not a missing payload') 'A denied root still produces a false missing-payload diagnosis.'
        }
        else {
            Assert-True ($payloadProbeErrors.Count -eq 0 -and $bootFiles.Count -eq 0) 'A positively missing payload was mistaken for a denied probe.'
        }
    }
}

Write-Host 'PASS -- denied SMB access fails readiness, bounded repair preserves policy, and unreadable PXE paths are not called missing.'
