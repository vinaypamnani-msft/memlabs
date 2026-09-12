<#
.SYNOPSIS
    Verifies locale-neutral principal resolution without changing host or AD state.
.DESCRIPTION
    Loads the shipped AddToAdminGroup class and maintenance scriptblocks through
    the PowerShell AST, then exercises them with mocked identity cmdlets. Run
    under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:Assertions = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $script:Assertions++
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Assert-True {
    param ([bool] $Condition, [string] $What)

    Assert-Equal -Expected $true -Actual $Condition -What $What
}

function Get-AssignedScriptBlock {
    param ([string] $Path, [string] $VariableName)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $assignments = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq $VariableName
            }, $true))
    if ($assignments.Count -ne 1) { throw "Expected one $VariableName assignment in $Path, found $($assignments.Count)." }
    return $assignments[0].Right.Expression.ScriptBlock.GetScriptBlock()
}

function Get-NestedScriptBlockPrefix {
    param ([string] $Path, [string] $Marker, [string] $StopCommand)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $blocks = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                $node.Extent.Text.Contains($Marker)
            }, $true) | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset })
    if ($blocks.Count -eq 0) { throw "Could not find a nested scriptblock containing '$Marker' in $Path." }
    $block = $blocks[0].ScriptBlock
    $stop = @($block.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $StopCommand
            }, $true) | Sort-Object { $_.Extent.StartOffset })
    if ($stop.Count -eq 0) { throw "Could not find stop command '$StopCommand' after '$Marker' in $Path." }
    $statements = @($block.EndBlock.Statements | Where-Object { $_.Extent.EndOffset -le $stop[0].Extent.StartOffset })
    if ($statements.Count -eq 0) { throw "No statements precede '$StopCommand' in the selected scriptblock." }
    return [scriptblock]::Create(($statements.Extent.Text -join [Environment]::NewLine))
}

function Get-VmConfigSysprepPreparationRoute {
    param ([string] $Path)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $assignments = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$result' -and
                $node.Extent.Text.Contains('CryptoSysPrep_Specialize')
            }, $true))
    if ($assignments.Count -ne 1) { throw "Expected one sysprep preparation assignment in $Path, found $($assignments.Count)." }
    $statementBlock = $assignments[0].Parent
    while ($statementBlock -and $statementBlock -isnot [Management.Automation.Language.StatementBlockAst]) { $statementBlock = $statementBlock.Parent }
    if (-not $statementBlock) { throw 'Could not locate the sysprep preparation statement block.' }
    $statements = @($statementBlock.Statements)
    $assignmentIndex = [array]::IndexOf($statements, $assignments[0])
    if ($assignmentIndex -lt 0 -or $assignmentIndex + 1 -ge $statements.Count) { throw 'Could not locate the sysprep preparation failure branch.' }
    $failureBranch = $statements[$assignmentIndex + 1]
    if ($failureBranch -isnot [Management.Automation.Language.IfStatementAst] -or
        -not $failureBranch.Extent.Text.Contains('Could not prepare the RID-500 Administrator account for sysprep')) {
        throw 'The statement after sysprep preparation is not its failure branch.'
    }
    return [scriptblock]::Create("$($assignments[0].Extent.Text)`n$($failureBranch.Extent.Text)`n'CONTINUED'")
}

function Get-TestClassDefinition {
    param ([string] $Path, [string] $ClassName)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.TypeDefinitionAst] -and
                $node.Name -eq $ClassName
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $ClassName class in $Path, found $($definitions.Count)." }
    return $definitions[0].Extent.Text
}

function Get-TestFunctionDefinition {
    param ([string] $Path, [string] $FunctionName)

    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $FunctionName function in $Path, found $($definitions.Count)." }
    return $definitions[0].Extent.Text
}

$script:DomainSid = 'S-1-5-21-111-222-333'
$script:DomainLookups = @()
$script:GroupLookups = @()
$script:UserLookups = @()
$script:ComputerLookups = @()
$script:MembershipCalls = @()
$script:GroupLookupThrows = $false
$script:MissingGroupDn = $false
$script:MembershipNonTerminatingFailure = $false
$script:UserLookupNonTerminatingFailure = $false
$script:ComputerLookupNonTerminatingFailure = $false
$script:SleepCalls = 0
$script:StatusMessages = @()

function Reset-GroupMocks {
    $script:DomainLookups = @()
    $script:GroupLookups = @()
    $script:UserLookups = @()
    $script:ComputerLookups = @()
    $script:MembershipCalls = @()
    $script:GroupLookupThrows = $false
    $script:MissingGroupDn = $false
    $script:MembershipNonTerminatingFailure = $false
    $script:UserLookupNonTerminatingFailure = $false
    $script:ComputerLookupNonTerminatingFailure = $false
    $script:SleepCalls = 0
    $script:StatusMessages = @()
}

function Write-Status {
    param ([string] $Message)
    $script:StatusMessages += $Message
}

function Start-Sleep {
    param ([int] $Seconds)
    $script:SleepCalls++
}

function Get-ADDomain {
    [CmdletBinding()]
    param ([string] $Server, [string] $AuthType, [pscredential] $Credential)
    $script:DomainLookups += [pscustomobject]@{ Server = $Server; AuthType = $AuthType; Credential = $Credential }
    return [pscustomobject]@{ DomainSID = [pscustomobject]@{ Value = $script:DomainSid } }
}

function Get-ADGroup {
    [CmdletBinding()]
    param ($Identity, [string] $Server, [string] $AuthType, [pscredential] $Credential)
    $script:GroupLookups += [pscustomobject]@{ Identity = "$Identity"; Server = $Server; AuthType = $AuthType; Credential = $Credential }
    if ($script:GroupLookupThrows) { throw 'simulated group lookup failure' }
    $distinguishedName = if ($script:MissingGroupDn) { $null } else { "CN=Localized Group,DC=memlabs,DC=test" }
    return [pscustomobject]@{ DistinguishedName = $distinguishedName }
}

function Get-ADUser {
    [CmdletBinding()]
    param ($Identity, [string] $Server, [string] $AuthType, [pscredential] $Credential)
    $user = [pscustomobject]@{ SamAccountName = "$Identity" }
    $script:UserLookups += [pscustomobject]@{ Identity = "$Identity"; Server = $Server; AuthType = $AuthType; Credential = $Credential; Result = $user }
    if ($script:UserLookupNonTerminatingFailure) { Write-Error 'simulated nonterminating user lookup failure' }
    return $user
}

function Get-ADComputer {
    [CmdletBinding()]
    param ($Identity, [string] $Server, [string] $AuthType, [pscredential] $Credential)
    $computer = [pscustomobject]@{ SamAccountName = "$Identity" }
    $script:ComputerLookups += [pscustomobject]@{ Identity = "$Identity"; Server = $Server; AuthType = $AuthType; Credential = $Credential; Result = $computer }
    if ($script:ComputerLookupNonTerminatingFailure) { Write-Error 'simulated nonterminating computer lookup failure' }
    return $computer
}

function Add-ADGroupMember {
    [CmdletBinding()]
    param ($Identity, $Members, [string] $Server, [string] $AuthType, [pscredential] $Credential)
    $script:MembershipCalls += [pscustomobject]@{
        Identity = "$Identity"
        Member = "$($Members.SamAccountName)"
        Server = $Server
        AuthType = $AuthType
        Credential = $Credential
    }
    if ($script:MembershipNonTerminatingFailure) { Write-Error 'simulated nonterminating membership failure' }
}

$templatePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
Invoke-Expression (Get-TestClassDefinition -Path $templatePath -ClassName 'AddToAdminGroup')
Invoke-Expression (Get-TestClassDefinition -Path $templatePath -ClassName 'AddUserToLocalAdminGroup')

$administratorHelperText = Get-TestFunctionDefinition -Path $templatePath -FunctionName 'Get-MemLabsBuiltinAdministratorsGroup'
& {
    $script:TestAdministratorGroups = @()
    function Get-CimInstance { return $script:TestAdministratorGroups }
    Invoke-Expression $administratorHelperText

    $missingGroupError = $null
    try { Get-MemLabsBuiltinAdministratorsGroup } catch { $missingGroupError = $_.Exception.Message }
    Assert-True ($missingGroupError -match 'found 0 distinct name') 'missing built-in Administrators SID match fails closed'

    $script:TestAdministratorGroups = @(
        [pscustomobject]@{ Name = 'Administrateurs' },
        [pscustomobject]@{ Name = 'ADMINISTRATEURS' }
    )
    $duplicateGroupError = $null
    try { $null = Get-MemLabsBuiltinAdministratorsGroup } catch { $duplicateGroupError = $_.Exception.Message }
    Assert-Equal $null $duplicateGroupError 'duplicate WMI rows for the same localized Administrators name collapse to one identity'

    $script:TestAdministratorGroups = @(
        [pscustomobject]@{ Name = 'Administrators A' },
        [pscustomobject]@{ Name = 'Administrators B' }
    )
    $ambiguousGroupError = $null
    try { Get-MemLabsBuiltinAdministratorsGroup } catch { $ambiguousGroupError = $_.Exception.Message }
    Assert-True ($ambiguousGroupError -match 'found 2 distinct name') 'conflicting built-in Administrators SID names fail closed'

    $script:TestAdministratorGroups = @(
        [pscustomobject]@{ Name = 'Administrateurs' },
        [pscustomobject]@{ Name = '' }
    )
    $blankGroupError = $null
    try { Get-MemLabsBuiltinAdministratorsGroup } catch { $blankGroupError = $_.Exception.Message }
    Assert-True ($blankGroupError -match 'blank name') 'mixed valid and blank built-in Administrators SID names fail closed'
}

$domainRoleHelperText = Get-TestFunctionDefinition -Path $templatePath -FunctionName 'Test-MemLabsIsDomainController'
& {
    $script:TestComputerSystems = @()
    function Get-CimInstance { return $script:TestComputerSystems }
    Invoke-Expression $domainRoleHelperText

    foreach ($invalidCase in @(
        @{ Name = 'missing instance'; Systems = @(); Pattern = 'found 0' },
        @{ Name = 'multiple instances'; Systems = @([pscustomobject]@{ DomainRole = 3 }, [pscustomobject]@{ DomainRole = 4 }); Pattern = 'found 2' },
        @{ Name = 'null role'; Systems = @([pscustomobject]@{ DomainRole = $null }); Pattern = 'invalid DomainRole' },
        @{ Name = 'blank role'; Systems = @([pscustomobject]@{ DomainRole = '' }); Pattern = 'invalid DomainRole' },
        @{ Name = 'nonnumeric role'; Systems = @([pscustomobject]@{ DomainRole = 'member' }); Pattern = 'invalid DomainRole' },
        @{ Name = 'out-of-range role'; Systems = @([pscustomobject]@{ DomainRole = 6 }); Pattern = 'invalid DomainRole' }
    )) {
        $script:TestComputerSystems = @($invalidCase.Systems)
        $roleError = $null
        try { Test-MemLabsIsDomainController } catch { $roleError = $_.Exception.Message }
        Assert-True ($roleError -match $invalidCase.Pattern) "$($invalidCase.Name) fails domain-role classification closed"
    }
    foreach ($domainRole in 0..5) {
        $script:TestComputerSystems = @([pscustomobject]@{ DomainRole = $domainRole })
        Assert-Equal -Expected ($domainRole -in 4, 5) -Actual (Test-MemLabsIsDomainController) -What "DomainRole $domainRole classification"
    }
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
Write-Host "source : $templatePath"
Write-Host ''

Reset-GroupMocks
$sidResource = New-Object -TypeName AddToAdminGroup
$sidResource.DomainName = 'NONE'
$sidResource.AccountNames = @('usuario-localizado')
$sidResource.TargetGroup = 'SID:S-1-5-32-544'
$sidOutput = @($sidResource.Set())
Assert-Equal 0 $sidOutput.Count 'SID selector emits no success-stream output'
Assert-Equal 0 $script:DomainLookups.Count 'SID selector bypasses domain SID lookup'
Assert-Equal 'S-1-5-32-544' ($script:GroupLookups.Identity -join ',') 'SID selector resolves the exact well-known SID'
Assert-Equal 'CN=Localized Group,DC=memlabs,DC=test' ($script:MembershipCalls.Identity -join ',') 'SID selector adds membership through the resolved group DN'
Assert-Equal 'usuario-localizado' ($script:MembershipCalls.Member -join ',') 'SID selector preserves the requested localized member name'

Reset-GroupMocks
$securePassword = ConvertTo-SecureString -String 'test-only' -AsPlainText -Force
$remoteCredential = New-Object System.Management.Automation.PSCredential('MEMLABS\tester', $securePassword)
$ridResource = New-Object -TypeName AddToAdminGroup
$ridResource.DomainName = 'child.memlabs.test'
$ridResource.RemoteCreds = $remoteCredential
$ridResource.AccountNames = @('usuario-remoto')
$ridResource.TargetGroup = 'RID:512'
$ridOutput = @($ridResource.Set())
Assert-Equal 0 $ridOutput.Count 'RID selector emits no success-stream output'
Assert-Equal 1 $script:DomainLookups.Count 'RID selector reads the local target domain SID once'
Assert-Equal '' ($script:DomainLookups.Server -join ',') 'RID selector does not resolve the target through the foreign member domain'
Assert-Equal "$script:DomainSid-512" ($script:GroupLookups.Identity -join ',') 'RID selector combines the local target domain SID and RID'
Assert-Equal '' ($script:GroupLookups.Server -join ',') 'RID selector resolves the target group locally'
Assert-Equal 'CN=Localized Group,DC=memlabs,DC=test' ($script:MembershipCalls.Identity -join ',') 'RID selector adds membership through the resolved group DN'
Assert-Equal '' ($script:MembershipCalls.Server -join ',') 'RID membership mutation targets the local group'
Assert-Equal 'child.memlabs.test' ($script:UserLookups.Server -join ',') 'RID selector resolves the member through the foreign domain'
Assert-True ($script:UserLookups.Credential -contains $remoteCredential) 'RID selector uses the supplied foreign-domain credential for the member only'

Reset-GroupMocks
$script:MissingGroupDn = $true
$missingDnError = $null
try { $sidResource.Set() } catch { $missingDnError = $_.Exception.Message }
Assert-True (-not [string]::IsNullOrWhiteSpace($missingDnError)) 'missing target group DN is terminal after bounded retries'
Assert-Equal 120 $script:GroupLookups.Count 'missing target group DN is attempted exactly 120 times'
Assert-Equal 119 $script:SleepCalls 'missing target group DN sleeps only between attempts'
Assert-Equal 0 $script:MembershipCalls.Count 'missing target group DN never attempts membership mutation'

Reset-GroupMocks
$script:GroupLookupThrows = $true
$lookupError = $null
try { $sidResource.Set() } catch { $lookupError = $_.Exception.Message }
Assert-True ($lookupError -like '*simulated group lookup failure*') 'group lookup failure remains visible after bounded retries'
Assert-Equal 120 $script:GroupLookups.Count 'group lookup failure is attempted exactly 120 times'
Assert-Equal 119 $script:SleepCalls 'group lookup failure sleeps only between attempts'
Assert-Equal 0 $script:MembershipCalls.Count 'group lookup failure never attempts membership mutation'

Reset-GroupMocks
$script:MembershipNonTerminatingFailure = $true
$membershipError = $null
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    try { $sidResource.Set() } catch { $membershipError = $_.Exception.Message }
}
finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
Assert-True ($membershipError -like '*simulated nonterminating membership failure*') 'nonterminating membership failure remains visible under Continue'
Assert-Equal 120 $script:MembershipCalls.Count 'nonterminating membership failure is attempted exactly 120 times'
Assert-Equal 119 $script:SleepCalls 'membership failure sleeps only between attempts'

foreach ($lookupKind in @('user', 'computer')) {
    Reset-GroupMocks
    if ($lookupKind -eq 'user') {
        $sidResource.AccountNames = @('usuario-localizado')
        $script:UserLookupNonTerminatingFailure = $true
    }
    else {
        $sidResource.AccountNames = @('equipo-localizado$')
        $script:ComputerLookupNonTerminatingFailure = $true
    }
    $memberLookupError = $null
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        try { $sidResource.Set() } catch { $memberLookupError = $_.Exception.Message }
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-True ($memberLookupError -like "*simulated nonterminating $lookupKind lookup failure*") "local $lookupKind lookup failure remains visible under Continue"
    $lookupCount = if ($lookupKind -eq 'user') { $script:UserLookups.Count } else { $script:ComputerLookups.Count }
    Assert-Equal 120 $lookupCount "local $lookupKind lookup failure is attempted exactly 120 times"
    Assert-Equal 119 $script:SleepCalls "local $lookupKind lookup failure sleeps only between attempts"
    Assert-Equal 0 $script:MembershipCalls.Count "local $lookupKind lookup failure never attempts membership mutation"
}
$sidResource.AccountNames = @('usuario-localizado')

$script:LocalGroupMemberPaths = @()
$script:AddLocalGroupPaths = @()
$script:AddLocalGroupFailure = $false
$script:AddLocalGroupNoOp = $false
$script:IsDomainController = $false
$script:DomainRoleThrows = $false
$script:SecureChannelCalls = 0
$script:SecureChannelHealthy = $true
$script:SecureChannelThrows = $false

function Get-MemLabsBuiltinAdministratorsGroup {
    $group = [pscustomobject]@{}
    $group | Add-Member -MemberType ScriptMethod -Name IsMember -Value {
        param([string] $Path)
        return $script:LocalGroupMemberPaths -contains $Path
    }
    $group | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param([string] $Path)
        $script:AddLocalGroupPaths += $Path
        if ($script:AddLocalGroupFailure) { throw 'simulated ADSI membership failure' }
        if (-not $script:AddLocalGroupNoOp) { $script:LocalGroupMemberPaths += $Path }
    }
    return $group
}

function Test-MemLabsIsDomainController {
    if ($script:DomainRoleThrows) { throw 'simulated domain role lookup failure' }
    return $script:IsDomainController
}

function Test-ComputerSecureChannel {
    [CmdletBinding()]
    param()
    $script:SecureChannelCalls++
    if ($script:SecureChannelThrows) { throw 'computer is not domain joined' }
    return $script:SecureChannelHealthy
}

$localGroupResource = New-Object -TypeName AddUserToLocalAdminGroup
$localGroupResource.Name = 'AdministradorLab'
$localGroupResource.NetbiosDomainName = 'EQUIPO'
Assert-Equal $false $localGroupResource.Test() 'localized local administrator membership starts absent'
$localGroupOutput = @($localGroupResource.Set())
Assert-Equal 0 $localGroupOutput.Count 'local Administrators membership emits no success-stream output'
Assert-Equal 'WinNT://EQUIPO/AdministradorLab' ($script:AddLocalGroupPaths -join ',') 'local Administrators membership uses the locale-neutral WinNT principal path'
Assert-Equal $true $localGroupResource.Test() 'localized local administrator membership verifies after add'
$null = $localGroupResource.Set()
Assert-Equal 1 $script:AddLocalGroupPaths.Count 'local Administrators membership is idempotent on rerun'

$script:LocalGroupMemberPaths = @()
$script:AddLocalGroupPaths = @()
$localGroupResource.Name = 'NODE$'
$null = $localGroupResource.Set()
Assert-Equal 'WinNT://EQUIPO/NODE$' ($script:AddLocalGroupPaths -join ',') 'computer account path preserves its trailing dollar sign'
$localGroupResource.Name = 'AdministradorLab'

$script:LocalGroupMemberPaths = @()
$script:AddLocalGroupPaths = @()
$script:AddLocalGroupNoOp = $true
$silentNoOpError = $null
try { $localGroupResource.Set() } catch { $silentNoOpError = $_.Exception.Message }
Assert-True ($silentNoOpError -match 'still not a member') 'silent ADSI add no-op fails its postcondition'
$script:AddLocalGroupNoOp = $false

$script:LocalGroupMemberPaths = @()
$script:AddLocalGroupPaths = @()
$script:AddLocalGroupFailure = $true
$script:IsDomainController = $false
$script:SecureChannelCalls = 0
$script:SecureChannelHealthy = $false
$global:DSCMachineStatus = 0
$localGroupError = $null
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    try { $localGroupResource.Set() } catch { $localGroupError = $_.Exception.Message }
}
finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
Assert-True ($localGroupError -like '*simulated ADSI membership failure*') 'local Administrators membership failure is terminal under Continue'
Assert-Equal 1 $script:AddLocalGroupPaths.Count 'failed local Administrators membership is attempted once'
Assert-Equal 1 $script:SecureChannelCalls 'member failure checks the secure channel once'
Assert-Equal 1 $global:DSCMachineStatus 'broken secure channel requests recovery reboot before failing'
Remove-Variable -Name DSCMachineStatus -Scope Global -ErrorAction SilentlyContinue

$script:LocalGroupMemberPaths = @()
$script:AddLocalGroupPaths = @()
$script:AddLocalGroupFailure = $true
$script:IsDomainController = $true
$script:SecureChannelCalls = 0
$script:SecureChannelHealthy = $false
$global:DSCMachineStatus = 0
$domainControllerError = $null
try { $localGroupResource.Set() } catch { $domainControllerError = $_.Exception.Message }
Assert-True ($domainControllerError -like '*simulated ADSI membership failure*') 'domain controller membership failure remains terminal'
Assert-Equal 0 $script:SecureChannelCalls 'domain controller failure skips the member-only secure channel API'
Assert-Equal 0 $global:DSCMachineStatus 'domain controller membership failure does not request a false secure-channel reboot'
Remove-Variable -Name DSCMachineStatus -Scope Global -ErrorAction SilentlyContinue

$script:DomainRoleThrows = $true
$script:SecureChannelCalls = 0
$global:DSCMachineStatus = 0
$unknownRoleError = $null
try { $localGroupResource.Set() } catch { $unknownRoleError = $_.Exception.Message }
Assert-True ($unknownRoleError -like '*simulated ADSI membership failure*') 'unknown-role membership failure remains terminal'
Assert-Equal 0 $script:SecureChannelCalls 'unknown domain role fails closed without secure-channel diagnosis'
Assert-Equal 0 $global:DSCMachineStatus 'unknown domain role does not request a speculative reboot'
Assert-True ([bool]($script:StatusMessages -match 'Domain role could not be determined')) 'unknown domain role is reported explicitly'
Remove-Variable -Name DSCMachineStatus -Scope Global -ErrorAction SilentlyContinue

$templateSource = Get-Content -LiteralPath $templatePath -Raw
Assert-True ($templateSource -match '(?s)function Get-MemLabsBuiltinAdministratorsGroup.*?Win32_Group.*?S-1-5-32-544.*?WinNT://\$env:COMPUTERNAME/\$groupName,group') 'production helper resolves localized Administrators through SID and ADSI'
Assert-True ($templateSource -notmatch '(?s)class AddUserToLocalAdminGroup.*?(?:Get|Add)-LocalGroupMember') 'local Administrators resource does not depend on the member-server LocalAccounts group API'

$script:LocalUsers = @()
$script:SetLocalUserCalls = @()
$script:EnableLocalUserCalls = @()
$script:FixLogMessages = @()

function Get-LocalUser {
    [CmdletBinding()]
    param ($SID)
    if ($PSBoundParameters.ContainsKey('SID')) {
        return @($script:LocalUsers | Where-Object { $_.SID.Value -eq $SID.Value })[0]
    }
    return $script:LocalUsers
}

function Disable-LocalUser {
    [CmdletBinding()]
    param ($SID)
    $script:DisableLocalUserCalls += [pscustomobject]@{ SID = $SID }
    if ($script:DisableLocalUserNonTerminatingFailure) { Write-Error 'simulated Disable-LocalUser failure' }
    foreach ($user in $script:LocalUsers) {
        if ($user.SID.Value -eq $SID.Value) { $user.Enabled = $false }
    }
}

function Set-LocalUser {
    [CmdletBinding()]
    param ($SID, [securestring] $Password)
    $script:SetLocalUserCalls += [pscustomobject]@{ SID = $SID; Password = $Password }
}

function Enable-LocalUser {
    [CmdletBinding()]
    param ($SID)
    $script:EnableLocalUserCalls += [pscustomobject]@{ SID = $SID }
    foreach ($user in $script:LocalUsers) {
        if ($user.SID.Value -eq $SID.Value) { $user.Enabled = $true }
    }
}

function Write-FixLog {
    param ([string] $Message, [string] $Level)
    $script:FixLogMessages += [pscustomobject]@{ Message = $Message; Level = $Level }
}

$localFixPath = Join-Path $RootPath 'Fixes\Fix_LocalAdminAccount.ps1'
$localFix = Get-AssignedScriptBlock -Path $localFixPath -VariableName '$Fix_LocalAdminAccount'
$localizedAdminSid = [pscustomobject]@{ Value = 'S-1-5-21-444-555-666-500' }
$script:LocalUsers = @([pscustomobject]@{ Name = 'Administrador'; SID = $localizedAdminSid; Enabled = $false; PasswordLastSet = $null })
$localFixResult = @(& $localFix 'test-password')
Assert-Equal 1 $localFixResult.Count 'local RID-500 maintenance returns one result'
Assert-Equal $true $localFixResult[0].Success 'localized RID-500 maintenance succeeds'
Assert-Equal 'S-1-5-21-444-555-666-500' ($script:SetLocalUserCalls.SID.Value -join ',') 'local password reset targets the RID-500 SID'
Assert-Equal 'S-1-5-21-444-555-666-500' ($script:EnableLocalUserCalls.SID.Value -join ',') 'local account enable targets the RID-500 SID'

foreach ($invalidCount in @(0, 2)) {
    $script:SetLocalUserCalls = @()
    $script:EnableLocalUserCalls = @()
    $script:LocalUsers = @()
    for ($index = 0; $index -lt $invalidCount; $index++) {
        $script:LocalUsers += [pscustomobject]@{ Name = "Cuenta$index"; SID = [pscustomobject]@{ Value = "S-1-5-21-444-555-666-500" }; Enabled = $false }
    }
    $invalidResult = @(& $localFix 'test-password')
    Assert-Equal 1 $invalidResult.Count "RID-500 count $invalidCount returns one failure result"
    Assert-Equal $false $invalidResult[0].Success "RID-500 count $invalidCount fails closed"
    Assert-Equal 0 $script:SetLocalUserCalls.Count "RID-500 count $invalidCount does not reset a password"
    Assert-Equal 0 $script:EnableLocalUserCalls.Count "RID-500 count $invalidCount does not enable an account"
}

$commonScriptBlocksPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$sysprepAdministratorPrep = Get-NestedScriptBlockPrefix -Path $commonScriptBlocksPath -Marker 'CryptoSysPrep_Specialize' -StopCommand 'Set-MpPreference'
$script:DisableLocalUserCalls = @()
$script:DisableLocalUserNonTerminatingFailure = $false
$script:LocalUsers = @([pscustomobject]@{ Name = 'Administrador'; SID = $localizedAdminSid; Enabled = $true })
$sysprepOutput = @(& $sysprepAdministratorPrep)
Assert-Equal 0 $sysprepOutput.Count 'sysprep RID-500 prerequisite emits no success-stream output'
Assert-Equal 'S-1-5-21-444-555-666-500' ($script:DisableLocalUserCalls.SID.Value -join ',') 'sysprep disables the localized built-in Administrator by RID-500 SID'
Assert-Equal $false $script:LocalUsers[0].Enabled 'sysprep verifies the RID-500 account is disabled'

foreach ($invalidCount in @(0, 2)) {
    $script:DisableLocalUserCalls = @()
    $script:LocalUsers = @()
    for ($index = 0; $index -lt $invalidCount; $index++) {
        $script:LocalUsers += [pscustomobject]@{ Name = "Cuenta$index"; SID = [pscustomobject]@{ Value = 'S-1-5-21-444-555-666-500' }; Enabled = $true }
    }
    $sysprepError = $null
    try { $null = & $sysprepAdministratorPrep } catch { $sysprepError = $_.Exception.Message }
    Assert-True ($sysprepError -like "*found $invalidCount*") "sysprep fails closed when RID-500 match count is $invalidCount"
    Assert-Equal 0 $script:DisableLocalUserCalls.Count "sysprep does not disable an ambiguous RID-500 account at count $invalidCount"
}

$script:DisableLocalUserCalls = @()
$script:DisableLocalUserNonTerminatingFailure = $true
$script:LocalUsers = @([pscustomobject]@{ Name = 'Administrador'; SID = $localizedAdminSid; Enabled = $true })
$sysprepError = $null
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    try { $null = & $sysprepAdministratorPrep } catch { $sysprepError = $_.Exception.Message }
}
finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
Assert-True ($sysprepError -like '*simulated Disable-LocalUser failure*') 'sysprep RID-500 disable failure is terminal under Continue'
$commonScriptBlocks = Get-Content -LiteralPath $commonScriptBlocksPath -Raw
Assert-True ($commonScriptBlocks -match '(?s)Could not prepare the RID-500 Administrator account for sysprep.*?-Failure -OutputStream\s+return') 'VM configuration stops after a failed sysprep RID-500 prerequisite'

$script:VmCommandCalls = 0
function Invoke-VmCommand {
    param($VmName, $VmDomainName, [scriptblock]$ScriptBlock)
    $script:VmCommandCalls++
    return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = 'simulated RID-500 preparation failure' }
}
function Write-Log {
    param([string]$Message, [switch]$Failure, [switch]$OutputStream)
    if ($OutputStream) {
        return [pscustomobject]@{ LogLevel = $(if ($Failure) { 3 } else { 1 }); Text = $Message }
    }
}
$currentItem = [pscustomobject]@{ vmName = 'CLIENTE1' }
$domainName = 'WORKGROUP'
$Phase = 2
$sysprepRoute = Get-VmConfigSysprepPreparationRoute -Path $commonScriptBlocksPath
$routeOutput = @(& $sysprepRoute)
Assert-Equal 1 $script:VmCommandCalls 'VM configuration invokes sysprep RID-500 preparation once'
Assert-Equal 1 $routeOutput.Count 'failed sysprep RID-500 preparation emits exactly one result'
Assert-Equal 3 $routeOutput[0].LogLevel 'failed sysprep RID-500 preparation emits a failure object'
Assert-True ($routeOutput[0].Text -like '*simulated RID-500 preparation failure*') 'failed sysprep RID-500 preparation preserves guest diagnostics'
Assert-True ($routeOutput -notcontains 'CONTINUED') 'failed sysprep RID-500 preparation returns before later VM configuration'

$script:DomainAccountCalls = @()
function Set-ADUser {
    [CmdletBinding()]
    param ($Identity, [bool] $PasswordNeverExpires, [bool] $CannotChangePassword)
    $script:DomainAccountCalls += "$Identity"
}

$domainFixPath = Join-Path $RootPath 'Fixes\Fix-DomainAccounts.ps1'
$domainFix = Get-AssignedScriptBlock -Path $domainFixPath -VariableName '$Fix_DomainAccount'
$script:DomainAccountCalls = @()
$domainFixResult = @(& $domainFix 'AdministrateurLab')
Assert-Equal 1 $domainFixResult.Count 'domain-account maintenance returns one result'
Assert-Equal $true $domainFixResult[0].Success 'domain-account maintenance succeeds with a localized configured name'
Assert-Equal 4 $script:DomainAccountCalls.Count 'domain-account maintenance updates each unique managed identity once'
Assert-True ($script:DomainAccountCalls -contains "$script:DomainSid-500") 'domain-account maintenance targets the built-in Administrator by domain SID and RID 500'
Assert-True ($script:DomainAccountCalls -contains 'AdministrateurLab') 'domain-account maintenance preserves the configured localized administrator name'
Assert-True ($script:DomainAccountCalls -notcontains 'Administrator') 'domain-account maintenance does not synthesize the English Administrator name'

Write-Host ''
Write-Host "assertions : $script:Assertions"
if ($script:Failures -ne 0) { throw "$script:Failures localized principal resolution test(s) failed" }
Write-Host 'ALL LOCALIZED PRINCIPAL RESOLUTION TESTS PASSED' -ForegroundColor Green
