<#
.SYNOPSIS
    Rejects locale-dependent Windows built-in principal names used as identities.

.DESCRIPTION
    Windows resolves well-known principals by SID, but their account names vary by
    installed language. Passing English names such as Everyone, Administrators, or
    Domain Admins to SMB, ACL, local-group, ADSI, LDAP, or AD cmdlets therefore
    breaks localized guests. This scanner checks direct command arguments, DSC
    identity properties, identity-like assignments, ADSI/LDAP paths, and native ACL
    commands. Display text and comments are not findings.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Quiet,
    [switch]$SelfTest,
    [switch]$Staged
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$principalNames = @(
    'Administrator', 'Guest', 'Everyone', 'Authenticated Users', 'Anonymous Logon',
    'Administrators', 'Users', 'Guests', 'Power Users', 'Account Operators',
    'Server Operators', 'Print Operators', 'Backup Operators', 'Replicator',
    'Remote Desktop Users', 'Network Configuration Operators', 'Performance Monitor Users',
    'Performance Log Users', 'Distributed COM Users', 'IIS_IUSRS',
    'Cryptographic Operators', 'Event Log Readers', 'Certificate Service DCOM Access',
    'Hyper-V Administrators', 'Access Control Assistance Operators', 'Remote Management Users',
    'System Managed Accounts Group', 'Storage Replica Administrators',
    'Domain Admins', 'Domain Users', 'Domain Guests', 'Domain Computers',
    'Domain Controllers', 'Cert Publishers', 'Schema Admins', 'Enterprise Admins',
    'Group Policy Creator Owners', 'Read-only Domain Controllers',
    'Enterprise Read-only Domain Controllers', 'Allowed RODC Password Replication Group',
    'Denied RODC Password Replication Group', 'RAS and IAS Servers',
    'Pre-Windows 2000 Compatible Access', 'Windows Authorization Access Group',
    'Terminal Server License Servers', 'Incoming Forest Trust Builders',
    'Key Admins', 'Enterprise Key Admins', 'DnsAdmins', 'DnsUpdateProxy'
)
$localBuiltIns = @(
    'Administrator', 'Guest', 'Administrators', 'Users', 'Guests', 'Power Users',
    'Account Operators', 'Server Operators', 'Print Operators', 'Backup Operators',
    'Replicator', 'Remote Desktop Users', 'Network Configuration Operators',
    'Performance Monitor Users', 'Performance Log Users', 'Distributed COM Users',
    'IIS_IUSRS', 'Cryptographic Operators', 'Event Log Readers',
    'Hyper-V Administrators', 'Access Control Assistance Operators',
    'Remote Management Users', 'System Managed Accounts Group', 'Storage Replica Administrators'
)

$principalSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $principalNames) {
    [void]$principalSet.Add($name)
    if ($name -in $localBuiltIns) { [void]$principalSet.Add("BUILTIN\$name") }
}
$namePattern = (($principalSet | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|')
$adNamePattern = (($principalNames | Where-Object { $_ -match '^(?:Domain |Enterprise |Schema |Cert |Group Policy |Read-only |Allowed |Denied |RAS |Pre-Windows |Windows Authorization |Terminal |Incoming |Key |Dns)' } |
        Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|')
$commonParameterNames = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer',
    'PipelineVariable', 'WhatIf', 'Confirm'
)
$commonSwitchParameters = @('Verbose', 'Debug', 'WhatIf', 'Confirm')
$identityCommandSignatures = @{
    'New-SmbShare' = @{
        Parameters = @('Name', 'Path', 'ScopeName', 'Description', 'ConcurrentUserLimit', 'FolderEnumerationMode', 'CachingMode', 'ContinuouslyAvailable', 'EncryptData', 'CompressData', 'CATimeout', 'DirectoryHandleLeasing', 'LeasingMode', 'QoSFlowScope', 'QoSPolicyId', 'SecurityDescriptor', 'FullAccess', 'ChangeAccess', 'ReadAccess', 'NoAccess', 'Temporary', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('FullAccess', 'ChangeAccess', 'ReadAccess', 'NoAccess')
        PositionalIdentity = @{}
        Switches = @('ContinuouslyAvailable', 'EncryptData', 'CompressData', 'DirectoryHandleLeasing', 'Temporary', 'AsJob')
    }
    'Grant-SmbShareAccess' = @{
        Parameters = @('Name', 'ScopeName', 'InputObject', 'AccountName', 'AccessRight', 'Force', 'SmbInstance', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('AccountName')
        PositionalIdentity = @{}
        Switches = @('Force', 'AsJob')
    }
    'Revoke-SmbShareAccess' = @{
        Parameters = @('Name', 'ScopeName', 'InputObject', 'AccountName', 'Force', 'SmbInstance', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('AccountName')
        PositionalIdentity = @{}
        Switches = @('Force', 'AsJob')
    }
    'Block-SmbShareAccess' = @{
        Parameters = @('Name', 'ScopeName', 'InputObject', 'AccountName', 'Force', 'SmbInstance', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('AccountName')
        PositionalIdentity = @{}
        Switches = @('Force', 'AsJob')
    }
    'Get-LocalGroupMember' = @{
        Parameters = @('Group', 'Name', 'SID', 'Member')
        Identity = @('Group', 'Name', 'Member')
        PositionalIdentity = @{ 0 = 'Group'; 1 = 'Member' }
        Switches = @()
    }
    'Add-LocalGroupMember' = @{
        Parameters = @('Group', 'Name', 'SID', 'Member')
        Identity = @('Group', 'Name', 'Member')
        PositionalIdentity = @{ 0 = 'Group'; 1 = 'Member' }
        Switches = @()
    }
    'Remove-LocalGroupMember' = @{
        Parameters = @('Group', 'Name', 'SID', 'Member')
        Identity = @('Group', 'Name', 'Member')
        PositionalIdentity = @{ 0 = 'Group'; 1 = 'Member' }
        Switches = @()
    }
    'Get-LocalGroup' = @{
        Parameters = @('Name', 'SID')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Set-LocalGroup' = @{
        Parameters = @('InputObject', 'Name', 'SID', 'Description')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Remove-LocalGroup' = @{
        Parameters = @('InputObject', 'Name', 'SID')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Get-LocalUser' = @{
        Parameters = @('Name', 'SID')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Set-LocalUser' = @{
        Parameters = @('InputObject', 'Name', 'SID', 'AccountExpires', 'AccountNeverExpires', 'Description', 'FullName', 'Password', 'PasswordNeverExpires', 'UserMayChangePassword')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @('AccountNeverExpires', 'PasswordNeverExpires', 'UserMayChangePassword')
    }
    'Enable-LocalUser' = @{
        Parameters = @('InputObject', 'Name', 'SID')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Disable-LocalUser' = @{
        Parameters = @('InputObject', 'Name', 'SID')
        Identity = @('Name')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @()
    }
    'Rename-LocalUser' = @{
        Parameters = @('InputObject', 'Name', 'SID', 'NewName')
        Identity = @('Name', 'NewName')
        PositionalIdentity = @{ 0 = 'Name'; 1 = 'NewName' }
        Switches = @()
    }
    'Get-ADGroup' = @{
        Parameters = @('Identity', 'Filter', 'LDAPFilter', 'SearchBase', 'SearchScope', 'Properties', 'ResultSetSize', 'Partition', 'Server', 'Credential', 'AuthType')
        Identity = @('Identity')
        PositionalIdentity = @{ 0 = 'Identity' }
        Switches = @()
    }
    'Set-ADGroup' = @{
        Parameters = @('Identity', 'DisplayName', 'SamAccountName', 'Description', 'GroupCategory', 'GroupScope', 'ManagedBy', 'Add', 'Remove', 'Replace', 'Clear', 'Partition', 'Server', 'Credential', 'AuthType', 'PassThru')
        Identity = @('Identity', 'SamAccountName')
        PositionalIdentity = @{ 0 = 'Identity' }
        Switches = @('PassThru')
    }
    'New-ADGroup' = @{
        Parameters = @('Name', 'SamAccountName', 'GroupCategory', 'GroupScope', 'DisplayName', 'Description', 'Path', 'ManagedBy', 'OtherAttributes', 'Instance', 'Server', 'Credential', 'AuthType', 'PassThru')
        Identity = @('Name', 'SamAccountName')
        PositionalIdentity = @{ 0 = 'Name' }
        Switches = @('PassThru')
    }
    'Add-ADGroupMember' = @{
        Parameters = @('Identity', 'Members', 'MemberTimeToLive', 'Partition', 'Server', 'Credential', 'AuthType', 'PassThru', 'DisablePermissiveModify')
        Identity = @('Identity', 'Members')
        PositionalIdentity = @{ 0 = 'Identity'; 1 = 'Members' }
        Switches = @('PassThru', 'DisablePermissiveModify')
    }
    'Remove-ADGroupMember' = @{
        Parameters = @('Identity', 'Members', 'Partition', 'Server', 'Credential', 'AuthType', 'PassThru')
        Identity = @('Identity', 'Members')
        PositionalIdentity = @{ 0 = 'Identity'; 1 = 'Members' }
        Switches = @('PassThru')
    }
    'Add-CertificateTemplateAcl' = @{
        Parameters = @('InputObject', 'Identity', 'AccessType', 'AccessMask')
        Identity = @('Identity')
        PositionalIdentity = @{}
        Switches = @()
    }
    'New-ScheduledTaskPrincipal' = @{
        Parameters = @('UserId', 'GroupId', 'LogonType', 'RunLevel', 'ProcessTokenSidType', 'RequiredPrivilege', 'Id', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('UserId', 'GroupId')
        PositionalIdentity = @{ 0 = 'UserId' }
        Switches = @('AsJob')
    }
    'Register-ScheduledTask' = @{
        Parameters = @('TaskName', 'TaskPath', 'InputObject', 'Action', 'Trigger', 'Settings', 'Principal', 'Description', 'User', 'Password', 'Force', 'CimSession', 'ThrottleLimit', 'AsJob')
        Identity = @('User')
        PositionalIdentity = @{}
        Switches = @('Force', 'AsJob')
    }
}

function Get-Ancestor {
    param([Management.Automation.Language.Ast]$Node, [type]$Type)
    $current = $Node.Parent
    while ($current) {
        if ($Type.IsInstanceOfType($current)) { return $current }
        $current = $current.Parent
    }
    return $null
}

function Test-AllowedCompatibilityLiteral {
    param([string]$RelativePath, [Management.Automation.Language.Ast]$Node, [string]$Value)

    if ($RelativePath -ieq 'vmbuild/DSC/phases/Phase4.ps1' -and $Value -ieq 'BUILTIN\Administrators') {
        $assignment = Get-Ancestor -Node $Node -Type ([Management.Automation.Language.AssignmentStatementAst])
        return $assignment -and $assignment.Left.Extent.Text -eq '$managedSQLSysAdminAccounts'
    }
    return $false
}

function Get-PrincipalScope {
    param(
        [Management.Automation.Language.Ast]$Node,
        [Management.Automation.Language.ScriptBlockAst]$Root
    )

    $current = $Node
    while ($current) {
        if ($current -is [Management.Automation.Language.ScriptBlockAst] -and
            ($current.Parent -is [Management.Automation.Language.FunctionDefinitionAst] -or
             $current.Parent -is [Management.Automation.Language.ScriptBlockExpressionAst])) {
            return $current
        }
        $current = $current.Parent
    }
    return $Root
}

function Get-ParentPrincipalScope {
    param(
        [Management.Automation.Language.ScriptBlockAst]$Scope,
        [Management.Automation.Language.ScriptBlockAst]$Root
    )

    $current = $Scope.Parent
    while ($current) {
        if ($current -is [Management.Automation.Language.ScriptBlockAst]) { return $current }
        $current = $current.Parent
    }
    if (-not [object]::ReferenceEquals($Scope, $Root)) { return $Root }
    return $null
}

function Get-PrincipalAssignment {
    param(
        [Management.Automation.Language.VariableExpressionAst]$Variable,
        [Management.Automation.Language.Ast]$UseNode,
        [Management.Automation.Language.ScriptBlockAst]$Root,
        [int]$BeforeOffset
    )

    $variableName = $Variable.VariablePath.UserPath
    $scope = Get-PrincipalScope -Node $UseNode -Root $Root
    while ($scope) {
        $assignments = @($scope.FindAll({
                    param($candidate)
                    $candidate -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $candidate.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $candidate.Left.VariablePath.UserPath -ieq $variableName -and
                    $candidate.Extent.StartOffset -lt $BeforeOffset
                }, $true) | Where-Object {
                    [object]::ReferenceEquals((Get-PrincipalScope -Node $_ -Root $Root), $scope)
                } | Sort-Object { $_.Extent.StartOffset } -Descending)
        if ($assignments.Count -gt 0) { return $assignments[0] }
        if ($scope.ParamBlock -and @($scope.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ieq $variableName }).Count -gt 0) {
            return $null
        }
        $scope = Get-ParentPrincipalScope -Scope $scope -Root $Root
    }
    return $null
}

function Get-StaticPrincipalValues {
    param(
        [Management.Automation.Language.Ast]$Node,
        [Management.Automation.Language.ScriptBlockAst]$Root,
        [int]$BeforeOffset,
        [Collections.Generic.HashSet[string]]$Visiting
    )

    if ($null -eq $Node) { return }
    while ($true) {
        if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression; continue }
        if ($Node -is [Management.Automation.Language.ConvertExpressionAst]) { $Node = $Node.Child; continue }
        if ($Node -is [Management.Automation.Language.AttributedExpressionAst]) { $Node = $Node.Child; continue }
        if ($Node -is [Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { $Node = $Node.PipelineElements[0]; continue }
        if ($Node -is [Management.Automation.Language.StatementBlockAst] -and $Node.Statements.Count -eq 1) { $Node = $Node.Statements[0]; continue }
        if ($Node -is [Management.Automation.Language.ParenExpressionAst]) { $Node = $Node.Pipeline; continue }
        break
    }

    if ($Node -is [Management.Automation.Language.StringConstantExpressionAst]) {
        return [string]$Node.Value
    }
    if ($Node -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $Node.NestedExpressions.Count -eq 0) {
        return [string]$Node.Value
    }
    if ($Node -is [Management.Automation.Language.BinaryExpressionAst] -and
        $Node.Operator -eq [Management.Automation.Language.TokenKind]::Plus) {
        $leftValues = @(Get-StaticPrincipalValues -Node $Node.Left -Root $Root -BeforeOffset $BeforeOffset -Visiting $Visiting)
        $rightValues = @(Get-StaticPrincipalValues -Node $Node.Right -Root $Root -BeforeOffset $BeforeOffset -Visiting $Visiting)
        foreach ($leftValue in $leftValues) {
            foreach ($rightValue in $rightValues) { "$leftValue$rightValue" }
        }
        return
    }
    if ($Node -is [Management.Automation.Language.VariableExpressionAst]) {
        $assignment = Get-PrincipalAssignment -Variable $Node -UseNode $Node -Root $Root -BeforeOffset $BeforeOffset
        if ($null -eq $assignment) { return }
        $scope = Get-PrincipalScope -Node $assignment -Root $Root
        $visitKey = "$($scope.Extent.StartOffset)|$($Node.VariablePath.UserPath)|$($assignment.Extent.StartOffset)"
        if (-not $Visiting.Add($visitKey)) { return }
        try {
            Get-StaticPrincipalValues -Node $assignment.Right -Root $Root -BeforeOffset $assignment.Extent.StartOffset -Visiting $Visiting
        }
        finally {
            [void]$Visiting.Remove($visitKey)
        }
        return
    }

    try {
        $safeValue = $Node.SafeGetValue()
        foreach ($item in @($safeValue)) {
            if ($item -is [string]) { [string]$item }
        }
    }
    catch { }
}

function Get-StaticPrincipalHashtable {
    param(
        [Management.Automation.Language.Ast]$Node,
        [Management.Automation.Language.ScriptBlockAst]$Root,
        [int]$BeforeOffset,
        [Collections.Generic.HashSet[string]]$Visiting
    )

    if ($null -eq $Node) { return $null }
    while ($true) {
        if ($Node -is [Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression; continue }
        if ($Node -is [Management.Automation.Language.ConvertExpressionAst]) { $Node = $Node.Child; continue }
        if ($Node -is [Management.Automation.Language.AttributedExpressionAst]) { $Node = $Node.Child; continue }
        if ($Node -is [Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) { $Node = $Node.PipelineElements[0]; continue }
        if ($Node -is [Management.Automation.Language.StatementBlockAst] -and $Node.Statements.Count -eq 1) { $Node = $Node.Statements[0]; continue }
        if ($Node -is [Management.Automation.Language.ParenExpressionAst]) { $Node = $Node.Pipeline; continue }
        break
    }
    if ($Node -is [Management.Automation.Language.HashtableAst]) { return $Node }
    if ($Node -isnot [Management.Automation.Language.VariableExpressionAst]) { return $null }

    $assignment = Get-PrincipalAssignment -Variable $Node -UseNode $Node -Root $Root -BeforeOffset $BeforeOffset
    if ($null -eq $assignment) { return $null }
    $scope = Get-PrincipalScope -Node $assignment -Root $Root
    $visitKey = "$($scope.Extent.StartOffset)|$($Node.VariablePath.UserPath)|$($assignment.Extent.StartOffset)"
    if (-not $Visiting.Add($visitKey)) { return $null }
    try {
        return Get-StaticPrincipalHashtable -Node $assignment.Right -Root $Root -BeforeOffset $assignment.Extent.StartOffset -Visiting $Visiting
    }
    finally {
        [void]$Visiting.Remove($visitKey)
    }
}

function Get-NormalizedPrincipalCommandName {
    param([string]$CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName)) { return '' }
    return ($CommandName -split '\\')[-1]
}

function Resolve-PrincipalParameterName {
    param([string]$CommandName, [string]$ParameterName)

    $normalizedCommand = Get-NormalizedPrincipalCommandName -CommandName $CommandName
    if (-not $identityCommandSignatures.ContainsKey($normalizedCommand) -or [string]::IsNullOrWhiteSpace($ParameterName)) { return '' }
    $signature = $identityCommandSignatures[$normalizedCommand]
    $parameters = @($signature.Parameters) + $commonParameterNames
    $exact = @($parameters | Where-Object { $_ -ieq $ParameterName } | Select-Object -Unique)
    if ($exact.Count -eq 1) { return $exact[0] }
    $parameterMatches = @($parameters | Where-Object { $_.StartsWith($ParameterName, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -Unique)
    if ($parameterMatches.Count -eq 1) { return $parameterMatches[0] }
    return ''
}

function Test-PrincipalSwitchParameter {
    param([string]$CommandName, [string]$ParameterName)

    $normalizedCommand = Get-NormalizedPrincipalCommandName -CommandName $CommandName
    if (-not $identityCommandSignatures.ContainsKey($normalizedCommand)) { return $false }
    $canonical = Resolve-PrincipalParameterName -CommandName $normalizedCommand -ParameterName $ParameterName
    return $canonical -and ($canonical -in $commonSwitchParameters -or $canonical -in @($identityCommandSignatures[$normalizedCommand].Switches))
}

function Get-PrincipalFindings {
    param([string]$SourceName, [string]$RelativePath, [Management.Automation.Language.ScriptBlockAst]$Ast)

    $results = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($node in $Ast.FindAll({
                param($candidate)
                $candidate -is [Management.Automation.Language.StringConstantExpressionAst] -or
                $candidate -is [Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true)) {
        $value = [string]$node.Value
        $reason = ''
        $isKnownExact = $principalSet.Contains($value)
        $command = Get-Ancestor -Node $node -Type ([Management.Automation.Language.CommandAst])
        $commandName = if ($command) { Get-NormalizedPrincipalCommandName -CommandName $command.GetCommandName() } else { '' }
        $assignment = Get-Ancestor -Node $node -Type ([Management.Automation.Language.AssignmentStatementAst])
        $assignmentTarget = if ($assignment) { $assignment.Left.Extent.Text } else { '' }
        $invocation = Get-Ancestor -Node $node -Type ([Management.Automation.Language.InvokeMemberExpressionAst])
        $contextText = @($command, $invocation | Where-Object { $_ } | ForEach-Object { $_.Extent.Text }) -join ' '

        if ($isKnownExact -and $node.Parent -is [Management.Automation.Language.MemberExpressionAst] -and
            $node.Parent.Member -eq $node -and $node.Parent.Expression.Extent.Text -match 'WindowsBuiltInRole') {
            continue
        }
        if ($isKnownExact -and (Test-AllowedCompatibilityLiteral -RelativePath $RelativePath -Node $node -Value $value)) {
            continue
        }
        if ($isKnownExact -and $contextText -match '(?i)(FileSystemAccessRule|RegistryAccessRule|NTAccount|IdentityReference|SetOwner|SetAccessRule|AddAccessRule)') {
            $reason = "literal '$value' passed to an ACL/principal API"
        }
        elseif ($isKnownExact -and $assignmentTarget -match '(?i)(account|identit|principal|member|group|user|admin|owner|trustee|access)') {
            $reason = "literal '$value' assigned to identity-like target $assignmentTarget"
        }
        elseif ($isKnownExact -and $assignmentTarget -match '(?i)(GroupName|TargetGroup|MembersToInclude|MembersToExclude|UserName)') {
            $reason = "literal '$value' assigned to DSC identity property $assignmentTarget"
        }
        elseif ($value -match ('(?i)WinNT://[^\r\n''"]*/(?:{0})(?:,|/|$)' -f $namePattern)) {
            $reason = 'localized built-in name embedded in a WinNT ADSI path'
        }
        elseif ($value -match "(?i)(?:LDAP://)?CN=(?:$adNamePattern)(?:,|$)") {
            $reason = 'localized default AD group embedded in an LDAP distinguished name'
        }
        elseif ($assignmentTarget -match '(?i)(?:^|\.)Filter$' -and $value -match "(?i)(?:cn|sAMAccountName)=(?:$adNamePattern)(?:\)|$)") {
            $reason = 'localized default AD group embedded in an LDAP filter'
        }
        elseif ($commandName -match '^(?:icacls(?:\.exe)?|subinacl(?:\.exe)?)$' -and $value -match "(?i)^(?:$namePattern):") {
            $reason = "localized built-in name passed to $commandName"
        }
        elseif ($value -match "(?im)\b(?:icacls(?:\.exe)?|subinacl(?:\.exe)?)\b[^\r\n]*(?:$namePattern):") {
            $reason = 'localized built-in name embedded in a native ACL command'
        }
        elseif (
            $value -match ("(?im)\bNew-SmbShare\b[^\r\n]*-(?:ReadAccess|FullAccess|ChangeAccess|NoAccess)\s+[^\r\n]*(?:{0})" -f $namePattern) -or
            $value -match ("(?im)\b(?:Grant-SmbShareAccess|Revoke-SmbShareAccess|Block-SmbShareAccess)\b[^\r\n]*-AccountName\s+[^\r\n]*(?:{0})" -f $namePattern) -or
            $value -match ("(?im)\b(?:Get-LocalGroupMember|Add-LocalGroupMember|Remove-LocalGroupMember)\b[^\r\n]*-(?:Group|Member)\s+[^\r\n]*(?:{0})" -f $namePattern) -or
            $value -match ("(?im)\b(?:Get-LocalUser|Set-LocalUser|Enable-LocalUser|Disable-LocalUser|Rename-LocalUser)\b[^\r\n]*-Name\s+[^\r\n]*(?:{0})" -f $namePattern) -or
            $value -match ("(?im)\b(?:Get-ADGroup|Add-ADGroupMember|Remove-ADGroupMember|Add-CertificateTemplateAcl)\b[^\r\n]*-Identity\s+[^\r\n]*(?:{0})" -f $namePattern) -or
            $value -match ("(?im)\bNew-ScheduledTaskPrincipal\b[^\r\n]*-(?:GroupId|UserId)\s+[^\r\n]*(?:{0})" -f $namePattern)
        ) {
            $reason = 'localized built-in identity embedded in generated PowerShell'
        }
        elseif ($value -match ('(?im)\b(?:GroupName|TargetGroup|MembersToInclude|MembersToExclude|UserName)\s*=\s*[''"](?:{0})[''"]' -f $namePattern)) {
            $reason = 'localized built-in DSC identity embedded in generated PowerShell'
        }
        elseif ($value -match ('(?im)\b(?:FileSystemAccessRule|RegistryAccessRule|NTAccount)\s*\(\s*[''"](?:{0})[''"]' -f $namePattern)) {
            $reason = 'localized built-in principal API call embedded in generated PowerShell'
        }

        if (-not $reason) { continue }
        $key = "$SourceName|$($node.Extent.StartOffset)|$reason"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $lineText = ($node.Extent.Text -split "`r?`n" | Select-Object -First 1).Trim()
        $results.Add([pscustomobject]@{
                Source = $SourceName
                Line   = $node.Extent.StartLineNumber
                Text   = $lineText
                Reason = $reason
            })
    }

    foreach ($command in $Ast.FindAll({ param($candidate) $candidate -is [Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = Get-NormalizedPrincipalCommandName -CommandName $command.GetCommandName()
        if (-not $identityCommandSignatures.ContainsKey($commandName)) { continue }
        $signature = $identityCommandSignatures[$commandName]
        $pendingParameter = ''
        $positionalOrdinal = 0
        foreach ($originalElement in @($command.CommandElements | Select-Object -Skip 1)) {
            $element = $originalElement
            if ($element -is [Management.Automation.Language.CommandParameterAst]) {
                $canonicalParameter = Resolve-PrincipalParameterName -CommandName $commandName -ParameterName $element.ParameterName
                if ($null -eq $element.Argument) {
                    if (Test-PrincipalSwitchParameter -CommandName $commandName -ParameterName $element.ParameterName) {
                        $pendingParameter = ''
                    }
                    else {
                        $pendingParameter = if ($canonicalParameter) { $canonicalParameter } else { '<unknown>' }
                    }
                    continue
                }
                $element = $element.Argument
                $pendingParameter = $canonicalParameter
            }

            if ($element -is [Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) {
                $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $hashtable = Get-StaticPrincipalHashtable -Node $element -Root $Ast -BeforeOffset $element.Extent.StartOffset -Visiting $visiting
                if ($hashtable) {
                    foreach ($pair in $hashtable.KeyValuePairs) {
                        $keyValues = @(Get-StaticPrincipalValues -Node $pair.Item1 -Root $Ast -BeforeOffset $pair.Item1.Extent.StartOffset -Visiting $visiting)
                        $canonicalKey = @($keyValues | ForEach-Object { Resolve-PrincipalParameterName -CommandName $commandName -ParameterName $_ } |
                                Where-Object { $_ -and $_ -in @($signature.Identity) } | Select-Object -First 1)
                        if ($canonicalKey.Count -eq 0) { continue }
                        $values = @(Get-StaticPrincipalValues -Node $pair.Item2 -Root $Ast -BeforeOffset $element.Extent.StartOffset -Visiting $visiting)
                        foreach ($value in $values) {
                            if (-not $principalSet.Contains([string]$value)) { continue }
                            $reason = "indirect literal '$value' reaches $commandName -$($canonicalKey[0]) through a splatted hashtable"
                            $key = "$SourceName|$($element.Extent.StartOffset)|$reason"
                            if ($seen.ContainsKey($key)) { continue }
                            $seen[$key] = $true
                            [void]$results.Add([pscustomobject]@{ Source = $SourceName; Line = $element.Extent.StartLineNumber; Text = $command.Extent.Text.Trim(); Reason = $reason })
                        }
                    }
                }
                $pendingParameter = ''
                continue
            }

            $identityParameter = ''
            if ($pendingParameter) {
                if ($pendingParameter -in @($signature.Identity)) { $identityParameter = $pendingParameter }
                $pendingParameter = ''
            }
            else {
                if ($signature.PositionalIdentity.ContainsKey($positionalOrdinal)) {
                    $identityParameter = $signature.PositionalIdentity[$positionalOrdinal]
                }
                $positionalOrdinal++
            }
            if (-not $identityParameter) { continue }

            $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $values = @(Get-StaticPrincipalValues -Node $element -Root $Ast -BeforeOffset $element.Extent.StartOffset -Visiting $visiting)
            foreach ($value in $values) {
                if (-not $principalSet.Contains([string]$value)) { continue }
                $isDirect = $element -is [Management.Automation.Language.StringConstantExpressionAst] -or
                    ($element -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $element.NestedExpressions.Count -eq 0)
                $reason = if ($isDirect) {
                    "literal '$value' passed to $commandName"
                }
                else {
                    "indirect literal '$value' reaches $commandName -$identityParameter"
                }
                $key = "$SourceName|$($element.Extent.StartOffset)|$reason"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                [void]$results.Add([pscustomobject]@{ Source = $SourceName; Line = $element.Extent.StartLineNumber; Text = $command.Extent.Text.Trim(); Reason = $reason })
            }
        }
    }
    return $results.ToArray()
}

function Invoke-PrincipalGitBytes {
    param([string]$WorkingDirectory, [string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'git.exe did not start.' }
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $standardError" }
        return , $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$sources = [Collections.Generic.List[object]]::new()
$parseErrorFiles = 0
$parseDiagnostics = [Collections.Generic.List[object]]::new()
if ($SelfTest) {
    $fixture = @'
New-SmbShare -Name Data -Path C:\Data -ReadAccess 'Everyone'
$identities = @('BUILTIN\Administrators')
$group = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
& icacls.exe C:\Data /grant "Users:F"
$searcher.Filter = "(&(objectClass=group)(cn=Domain Admins))"
Get-LocalUser -Name 'Administrator'
$world = [Security.Principal.SecurityIdentifier]'S-1-1-0'
$admins = Get-LocalGroupMember -SID 'S-1-5-32-544'
Write-Host 'Administrators are ready'
$requiredProperties = 'Guests'
New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount
$generated = @"
New-SmbShare -Name Generated -Path C:\Generated -ReadAccess 'Everyone'
"@
$indirect = 'Everyone'
New-SmbShare -Name Indirect -Path C:\Indirect -ReadAccess $indirect
$prefix = 'Admin'
$suffix = 'istrators'
$combined = $prefix + $suffix
Add-LocalGroupMember -Group $combined -Member 'MEMLABS\user'
$shareArgs = @{ ReadAccess = 'Everyone' }
New-SmbShare -Name Splatted -Path C:\Splatted @shareArgs
New-SmbShare -Name 'Users' -Path C:\Users
Microsoft.PowerShell.LocalAccounts\Add-LocalGroupMember -Group 'Administrators' -Member 'MEMLABS\user'
Add-LocalGroupMember -Gro 'Administrators' -Member 'MEMLABS\user'
Add-LocalGroupMember 'Administrators' 'MEMLABS\user'
$orderedArgs = [ordered]@{ Group = 'Administrators'; Member = 'MEMLABS\user' }
Add-LocalGroupMember @orderedArgs
$castArgs = [hashtable]@{ ReadAccess = 'Everyone' }
SmbShare\New-SmbShare -Name CastSplat -Path C:\CastSplat @castArgs
$captured = 'Everyone'
& { SmbShare\New-SmbShare -Name Captured -Path C:\Captured -ReadA $captured }
$shadowed = 'Everyone'
& { param($shadowed) New-SmbShare -Name Shadowed -Path C:\Shadowed -ReadAccess $shadowed } 'S-1-1-0'
'@
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($fixture, '<self-test>', [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Self-test fixture has $($errors.Count) parse error(s)." }
    $sources.Add([pscustomobject]@{ Name = '<self-test>'; RelativePath = '<self-test>'; Ast = $ast })
}
elseif ($Staged) {
    $rootPath = (& git -C $Path rev-parse --show-toplevel 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $rootPath) { throw "Could not resolve Git root from '$Path'." }
    $nameBytes = Invoke-PrincipalGitBytes -WorkingDirectory $rootPath -Arguments @('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z', '--')
    $stagedPaths = @([Text.Encoding]::UTF8.GetString($nameBytes).Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($relative in $stagedPaths) {
        if ([IO.Path]::GetExtension($relative) -notin '.ps1', '.psm1', '.psd1') { continue }
        $normalized = $relative.Replace('\', '/')
        if ($normalized -match '^(?:temp|vmbuild/(?:logs|logs2|temp|azureFiles|cache))/' -or
            $normalized -match '^vmbuild/(?:tools|DSC)/Test-[^/]*\.ps(?:1|m1|d1)$') { continue }
        $contentBytes = Invoke-PrincipalGitBytes -WorkingDirectory $rootPath -Arguments @('cat-file', 'blob', ":$relative")
        $offset = if ($contentBytes.Count -ge 3 -and $contentBytes[0] -eq 0xEF -and $contentBytes[1] -eq 0xBB -and $contentBytes[2] -eq 0xBF) { 3 } else { 0 }
        $content = [Text.Encoding]::UTF8.GetString($contentBytes, $offset, $contentBytes.Count - $offset)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($content, $relative, [ref]$null, [ref]$errors)
        if ($errors.Count -gt 0) {
            $parseErrorFiles++
            foreach ($errorRecord in $errors) {
                $parseDiagnostics.Add([pscustomobject]@{ Source = $relative; Line = $errorRecord.Extent.StartLineNumber; ErrorId = $errorRecord.ErrorId; Message = $errorRecord.Message })
            }
        }
        if ($null -ne $ast) { $sources.Add([pscustomobject]@{ Name = "$relative [staged]"; RelativePath = $normalized; Ast = $ast }) }
    }
    if ($sources.Count -eq 0) {
        if (-not $Quiet) { Write-Host "Staged principal checks: PASS (0 applicable PowerShell source(s) among $($stagedPaths.Count) staged path(s))." }
        exit 0
    }
}
else {
    $target = Get-Item -LiteralPath $Path -ErrorAction Stop
    $files = @()
    if (-not $target.PSIsContainer) {
        $files = @($target)
        $rootPath = Split-Path $target.FullName -Parent
    }
    else {
        $rootPath = $target.FullName.TrimEnd('\')
        $gitRoot = (& git -C $rootPath rev-parse --show-toplevel 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $gitRoot -and [IO.Path]::GetFullPath($gitRoot) -eq [IO.Path]::GetFullPath($rootPath)) {
            $repoPaths = @(& git -C $rootPath ls-files --cached --others --exclude-standard)
            $files = @($repoPaths | Where-Object { [IO.Path]::GetExtension($_) -in '.ps1', '.psm1', '.psd1' } | ForEach-Object { Get-Item -LiteralPath (Join-Path $rootPath $_) })
        }
        else {
            $files = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Include *.ps1, *.psm1, *.psd1)
        }
    }

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\').Replace('\', '/')
        if ($relative -match '^(?:temp|vmbuild/(?:logs|logs2|temp|azureFiles|cache))/' -or
            $relative -match '^vmbuild/(?:tools|DSC)/Test-[^/]*\.ps(?:1|m1|d1)$') { continue }
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if ($errors.Count -gt 0) {
            $parseErrorFiles++
            foreach ($errorRecord in $errors) {
                $parseDiagnostics.Add([pscustomobject]@{
                        Source  = $file.FullName
                        Line    = $errorRecord.Extent.StartLineNumber
                        ErrorId = $errorRecord.ErrorId
                        Message = $errorRecord.Message
                    })
            }
        }
        if ($null -ne $ast) {
            $sources.Add([pscustomobject]@{ Name = $file.FullName; RelativePath = $relative; Ast = $ast })
        }
    }
}

if ($sources.Count -eq 0) {
    Write-Host "FAIL: scanned 0 PowerShell sources under '$Path'." -ForegroundColor Red
    exit 1
}

$findings = @()
foreach ($source in $sources) {
    $findings += @(Get-PrincipalFindings -SourceName $source.Name -RelativePath $source.RelativePath -Ast $source.Ast)
}

if ($SelfTest) {
    $expectedLines = @(1, 2, 3, 4, 5, 6, 12, 16, 20, 22, 24, 25, 26, 28, 30, 32)
    $actualLines = @($findings.Line | Sort-Object -Unique)
    $missed = @($expectedLines | Where-Object { $actualLines -notcontains $_ })
    $extra = @($actualLines | Where-Object { $expectedLines -notcontains $_ })
    if ($missed.Count -gt 0 -or $extra.Count -gt 0) {
        Write-Host "SELF-TEST FAILED. missed=[$($missed -join ', ')] unexpected=[$($extra -join ', ')]" -ForegroundColor Red
        $findings | ForEach-Object { Write-Host "  $($_.Line): $($_.Reason)" }
        exit 1
    }
    Write-Host 'SELF-TEST PASSED - caught 16 identity-name defects and left SID/display/schema controls alone.'
    exit 0
}

if (-not $Quiet) {
    $scopeLabel = if ($Staged) { 'staged PowerShell source(s)' } else { 'PowerShell source(s)' }
    Write-Host "Scanned $($sources.Count) $scopeLabel for localized built-in identity names (parse-error files still inspected: $parseErrorFiles)."
    foreach ($diagnostic in $parseDiagnostics) {
        Write-Host ("  parser: {0}:{1} [{2}] {3}" -f $diagnostic.Source, $diagnostic.Line, $diagnostic.ErrorId, $diagnostic.Message) -ForegroundColor DarkGray
    }
}
if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host 'OK - no localized built-in name flows into a principal-resolution boundary.' }
    exit 0
}

Write-Host "FAIL - $($findings.Count) localized built-in identity name use(s):" -ForegroundColor Red
foreach ($finding in $findings | Sort-Object Source, Line) {
    Write-Host ("  {0}:{1}: {2}" -f $finding.Source, $finding.Line, $finding.Reason) -ForegroundColor Yellow
    Write-Host ("      {0}" -f $finding.Text) -ForegroundColor DarkGray
}
Write-Host 'Resolve a well-known SID/RID and pass the SID directly, or translate it on the target only when the API requires an NTAccount name.' -ForegroundColor Yellow
exit 1