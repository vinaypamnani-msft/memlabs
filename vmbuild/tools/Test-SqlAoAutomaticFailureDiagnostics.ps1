#requires -Version 5.1
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture globals are consumed by an AST-extracted production function.')]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-AutomaticDiagnostic {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

$functionalPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($functionalPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "$functionalPath has parse errors: $($parseErrors.Message -join '; ')" }
$source = Get-Content -LiteralPath $functionalPath -Raw
$helperAst = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-SqlAoFailureDiagnostics'
        }, $true))
Assert-AutomaticDiagnostic ($helperAst.Count -eq 1) 'functional validation defines one SQLAO failure diagnostic helper'
Assert-AutomaticDiagnostic ($source -match 'Start-Job' -and $source -match 'Wait-Job.+?-Timeout \$TimeoutSeconds' -and
    $source -match 'Receive-Job.+?-ErrorAction SilentlyContinue' -and
    $source -match 'Remove-Job.+?-Force') 'diagnostic helper is bounded and always drains its job'
Assert-AutomaticDiagnostic ($source -match 'Write-Log \$message -Warning -LogOnly') 'Phase 5 and Phase 11 diagnostic outcomes are warning-level logs'
Assert-AutomaticDiagnostic ($source -match 'phase5-terminal-failure-\$VMName' -and
    $source -match 'phase11-before-recovery-\$VMName' -and
    $source -match 'phase11-terminal-failure-\$VMName') 'Phase 5 and Phase 11 use labeled failure stages'
Assert-AutomaticDiagnostic ([regex]::Matches($source, '\$null = Invoke-SqlAoFailureDiagnostics').Count -ge 7) 'all failure hooks suppress helper output from validation return values'
Assert-AutomaticDiagnostic ($source -match "shared cluster/AG validation and recovery are owned by") 'Phase 11 retains configured-owner serialization'

if ($helperAst.Count -eq 1) {
    $invokeDiagnostic = $helperAst[0].Body.GetScriptBlock()
    $Common = [pscustomobject]@{
        LocalAdmin = [PSCredential]::new('vmbuildadmin', [Security.SecureString]::new())
    }
    $primary = [pscustomobject]@{
        vmName = 'FAB-PS1SQLAO1'
        OtherNode = 'FAB-PS1SQLAO2'
        AlwaysOnGroupName = 'PS1 Availability Group'
        AlwaysOnListenerName = 'FAB-ALWAYSON'
        ClusterName = 'FAB-SQLCLUSTER'
        SQLAOPort = 1500
        sqlInstanceName = 'MSSQLSERVER'
    }
    $deploy = [pscustomobject]@{
        vmOptions = [pscustomobject]@{
            domainName = 'fabrikam.com'
            domainNetBiosName = 'fabrikam'
            adminName = 'admin'
        }
        virtualMachines = @(
            $primary,
            [pscustomobject]@{ vmName = 'FAB-PS1SQLAO2'; role = 'SQLAO' },
            [pscustomobject]@{ vmName = 'FAB-DC1'; role = 'DC'; domain = 'fabrikam.com'; hidden = $false },
            [pscustomobject]@{ vmName = 'FAB-DC2'; role = 'OtherDC'; domain = 'fabrikam.com'; hidden = $true }
        )
    }
    $script:JobState = 'Completed'
    $script:WaitCompletes = $true
    $script:CollectionComplete = $true
    $script:StopCalls = 0
    $script:RemoveCalls = 0
    $script:ReceiveCalls = 0
    $script:CollectorParameters = $null
    $script:LogMessages = [Collections.Generic.List[object]]::new()
    $script:OutputMessages = [Collections.Generic.List[string]]::new()
    $script:FakeJob = [pscustomobject]@{
        State = 'Completed'
        ChildJobs = @([pscustomobject]@{ JobStateInfo = [pscustomobject]@{ Reason = $null } })
    }
    function Get-SqlAoConfigValue {
        param($Vm, $Name)
        switch ($Name) {
            'AlwaysOnGroupName' { return $Vm.AlwaysOnGroupName }
            'AlwaysOnListenerName' { return $Vm.AlwaysOnListenerName }
            'ClusterName' { return $Vm.ClusterName }
            'SQLAOPort' { return $Vm.SQLAOPort }
        }
    }
    function Test-Path { param($LiteralPath); return $true }
    function Start-Job {
        param($ScriptBlock, $ArgumentList)
        $script:CollectorParameters = $ArgumentList[1]
        $script:FakeJob.State = $script:JobState
        return $script:FakeJob
    }
    function Wait-Job {
        param($Job, $Timeout)
        if ($script:WaitCompletes) { return $Job }
        return $null
    }
    function Stop-Job { param($Job, $ErrorAction); $script:StopCalls++ }
    function Receive-Job {
        param($Job, $ErrorAction)
        $script:ReceiveCalls++
        [pscustomobject]@{
            ReportPath = 'report.txt'
            ArchivePath = 'report.zip'
            CollectionComplete = $script:CollectionComplete
            CollectionErrors = if ($script:CollectionComplete) { @() } else { @('injected section failure') }
        }
    }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction); $script:RemoveCalls++ }
    function Write-Log {
        param($Message, [switch]$Warning, [switch]$LogOnly)
        $script:LogMessages.Add([pscustomobject]@{ Message = [string]$Message; Warning = [bool]$Warning })
    }
    function Add-Phase11Output { param($Text, $Level); $script:OutputMessages.Add("$Level|$Text") }
    try {
        $result = & $invokeDiagnostic -DeployConfig $deploy -PrimaryAO $primary `
            -SnapshotLabel 'phase11-before-recovery-FAB-PS1SQLAO1' -Phase 11
        Assert-AutomaticDiagnostic ($result.Captured -and $result.CollectionComplete -and
            $script:CollectorParameters.NodeVm -join ',' -eq 'FAB-PS1SQLAO1,FAB-PS1SQLAO2' -and
            $script:CollectorParameters.DcVm -eq 'FAB-DC1' -and
            ($script:CollectorParameters.ExtraNames -join ',') -eq 'FAB-ALWAYSON,FAB-SQLCLUSTER' -and
            $script:CollectorParameters.Credential.UserName -eq 'fabrikam\admin') 'helper forwards exact topology and deployment credential'
        Assert-AutomaticDiagnostic ($script:RemoveCalls -eq 1 -and $script:ReceiveCalls -eq 2 -and
            $script:LogMessages[-1].Warning -and $script:LogMessages[-1].Message -match 'report.txt' -and
            $script:OutputMessages[-1] -match '^Warning\|') 'successful Phase 11 capture is warning-logged, surfaced, and drained'

        $script:CollectionComplete = $false
        $result = & $invokeDiagnostic -DeployConfig $deploy -PrimaryAO $primary `
            -SnapshotLabel 'phase5-terminal-failure-FAB-PS1SQLAO1' -Phase 5
        Assert-AutomaticDiagnostic ($result.Captured -and -not $result.CollectionComplete -and
            $result.Error -match 'injected section failure') 'incomplete artifacts are preserved without changing the caller verdict'

        $script:WaitCompletes = $false
        $result = & $invokeDiagnostic -DeployConfig $deploy -PrimaryAO $primary `
            -SnapshotLabel 'phase11-terminal-failure-FAB-PS1SQLAO1' -Phase 11 -TimeoutSeconds 60
        Assert-AutomaticDiagnostic (-not $result.Captured -and $result.Error -match 'exceeded 60s' -and
            $script:StopCalls -eq 1 -and $script:RemoveCalls -eq 3 -and
            $script:ReceiveCalls -eq 5) 'timeout is bounded, drained, reported, and cannot escape job cleanup'

        $script:WaitCompletes = $true
        $script:JobState = 'Failed'
        $result = & $invokeDiagnostic -DeployConfig $deploy -PrimaryAO $primary `
            -SnapshotLabel 'phase11-terminal-failure-FAB-PS1SQLAO1' -Phase 11
        Assert-AutomaticDiagnostic (-not $result.Captured -and $result.Error -match "ended in state 'Failed'" -and
            $script:RemoveCalls -eq 4 -and $script:ReceiveCalls -eq 6) 'failed collector job is drained and removed without throwing into validation'

        $hiddenOnlyDeploy = [pscustomobject]@{
            vmOptions = $deploy.vmOptions
            virtualMachines = @($primary, $deploy.virtualMachines[1], $deploy.virtualMachines[3])
        }
        $script:JobState = 'Completed'
        $result = & $invokeDiagnostic -DeployConfig $hiddenOnlyDeploy -PrimaryAO $primary `
            -SnapshotLabel 'phase5-terminal-failure-FAB-PS1SQLAO1' -Phase 5
        Assert-AutomaticDiagnostic ($result.Captured -and
            $script:CollectorParameters.DcVm -eq 'FAB-DC2') 'existing hidden DC remains eligible for automatic diagnostics'
    }
    finally {
        'Get-SqlAoConfigValue', 'Test-Path', 'Start-Job', 'Wait-Job', 'Stop-Job',
        'Receive-Job', 'Remove-Job', 'Write-Log', 'Add-Phase11Output' |
            ForEach-Object { Remove-Item -LiteralPath "Function:\$_" -Force }
    }
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) automatic SQLAO diagnostic assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All automatic SQLAO failure diagnostic tests passed.'
