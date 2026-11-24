#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
class MemLabsSqlTestMember {
    [string]$ADsPath
    MemLabsSqlTestMember([string]$Path) { $this.ADsPath = $Path }
}
class MemLabsSqlTestGroup {
    [Collections.Generic.List[MemLabsSqlTestMember]]$Members = [Collections.Generic.List[MemLabsSqlTestMember]]::new()
    [Collections.Generic.List[string]]$Added = [Collections.Generic.List[string]]::new()
    [object[]] Invoke([string]$Method) {
        if ($Method -ne 'Members') { throw "Unexpected directory operation '$Method'." }
        return $this.Members.ToArray()
    }
    [void] Add([string]$Path) {
        $this.Added.Add($Path)
        $this.Members.Add([MemLabsSqlTestMember]::new($Path))
    }
}
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
    (Join-Path $root 'common\Common.Phases.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Phase helper parse errors: $($errors -join '; ')" }
$definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-MemLabsExistingSqlPrerequisite'
    }, $true)
if (-not $definition) { throw 'Existing SQL prerequisite helper was not found.' }
. ([scriptblock]::Create($definition.Extent.Text))
$rpc = $definition.Body.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-VmCommand'
    }, $true)
$native = @($rpc.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] })[0].ScriptBlock
# ADSI's type accelerator is not mockable; replace only the native directory-object acquisition.
$nativeText = $native.Extent.Text.Trim().Substring(1)
$nativeText = $nativeText.Substring(0, $nativeText.LastIndexOf('}'))
$directoryBinding = '$group = [ADSI]("WinNT://$env:COMPUTERNAME/$groupName,group")'
if (-not $nativeText.Contains($directoryBinding)) { throw 'The SQL authorization fixture must bind exactly the production ADSI acquisition.' }
$nativeFixture = [scriptblock]::Create($nativeText.Replace($directoryBinding, '$group = $script:SqlTestGroup'))
foreach ($case in @('ExistingMember', 'MissingOldBinding', 'NewBinding', 'StoppedSql', 'BrokenTrust', 'StoppedOwner')) {
    & {
        param($Case)
        $script:SqlTestCase = $Case
        $script:SqlTestGroup = [MemLabsSqlTestGroup]::new()
        $script:SqlTestGroup.Members.Add([MemLabsSqlTestMember]::new('WinNT://FIXTURE/UNRELATED$'))
        if ($Case -eq 'ExistingMember') {
            $script:SqlTestGroup.Members.Add([MemLabsSqlTestMember]::new('WinNT://FIXTURE/NEWPRI$'))
        }
        $script:SqlRpcCalls = 0
        function Get-VM {
            param($Name, $ErrorAction)
            return [pscustomobject]@{ State = $(if ($script:SqlTestCase -eq 'StoppedOwner') { 'Off' } else { 'Running' }) }
        }
        function Get-Service {
            param($Name, $ErrorAction)
            Assert-True ($Name -eq 'MSSQL$APP') 'SQL service proof ignored the configured named instance.'
            return [pscustomobject]@{ Status = $(if ($script:SqlTestCase -eq 'StoppedSql') { 'Stopped' } else { 'Running' }) }
        }
        function Test-ComputerSecureChannel { param($ErrorAction); return $script:SqlTestCase -ne 'BrokenTrust' }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, [switch]$RequireDomainIdentity, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries,
                [switch]$RebootIfUnresponsive, [switch]$FailOnRemoteError, [switch]$SuppressLog, $ScriptBlock, $ArgumentList)
            $script:SqlRpcCalls++
            Assert-True ($VmName -eq 'SQL1' -and $RequireDomainIdentity -and $SessionMaxRetries -eq 1 -and -not $RebootIfUnresponsive) `
                'SQL dependency preflight widened its target or enabled recovery.'
            $output = @(& $nativeFixture @ArgumentList)
            return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output }
        }
        function Start-Service { throw 'Existing SQL services must not be repaired.' }
        function Restart-Service { throw 'Existing SQL services must not be restarted.' }
        function Reset-ComputerMachinePassword { throw 'Existing SQL domain trust must not be repaired.' }
        function Start-VM2 { throw 'Existing SQL VMs must not be started.' }
        $failure = ''
        try {
            Assert-MemLabsExistingSqlPrerequisite -VM ([pscustomobject]@{ vmName = 'SQL1'; sqlInstanceName = 'APP' }) `
                -Domain 'fixture.test' -Account 'FIXTURE\NEWPRI$' -ProvisionNewSiteAccount:($Case -ne 'MissingOldBinding')
        }
        catch { $failure = $_.Exception.Message }
        Assert-True ((-not $failure) -eq ($Case -in @('ExistingMember', 'NewBinding'))) "SQL prerequisite '$Case' was not classified correctly: $failure"
        $expectedAdds = if ($Case -eq 'NewBinding') { 1 } else { 0 }
        Assert-True ($script:SqlTestGroup.Added.Count -eq $expectedAdds -and
            @($script:SqlTestGroup.Members | Where-Object ADsPath -eq 'WinNT://FIXTURE/UNRELATED$').Count -eq 1) `
            'SQL authorization changed old memberships or skipped the one requested new principal.'
        if ($expectedAdds) { Assert-True ($script:SqlTestGroup.Added[0] -eq 'WinNT://FIXTURE/NEWPRI$') 'SQL authorization granted a different account.' }
        if ($Case -eq 'StoppedOwner') { Assert-True ($script:SqlRpcCalls -eq 0) 'Stopped SQL dependency reached guest mutation.' }
    } $case
}
$provenance = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$newSiteAccount'
    }, $true)
if (-not $provenance) { throw 'New-site authorization provenance check was not found.' }
foreach ($existing in @($true, $false)) {
    foreach ($phase in @($null, 'invalid', 0, 1, 7, 8, 11)) {
        $ss = [pscustomobject]@{ ExistingVM = $existing }
        $siteNote = if ($null -eq $phase) { $null } else { [pscustomobject]@{ lastPhaseComplete = $phase } }
        $lastCompleted = 0
        . ([scriptblock]::Create($provenance.Extent.Text))
        Assert-True ([bool]$newSiteAccount -eq (-not $existing -and $phase -in @(1, 7))) `
            'An existing/unprepared site could request new-site SQL principal provisioning.'
    }
}
Write-Host "PASS -- $script:Assertions existing-SQL prerequisite/authorization assertions on PowerShell $($PSVersionTable.PSVersion)."
