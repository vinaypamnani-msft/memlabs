#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Consumed by the shipped scoped-action host runner.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'siteCode', Justification = 'Consumed by the shipped dot-sourced guest connection block.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'common\Common.ExistingHierarchy.ps1')
$script:ProductionSupport = ${function:Get-MemLabsExistingActionSupportSource}
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Test-MemLabsContextOnlyVM { param($VM); return $VM.hidden -eq $true }
function Get-MemLabsRequestedDeploymentVMs { param($DeployConfig); $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } }
function Get-MemLabsExistingSiteConnectionScript { { param($ExpectedSiteCode); $siteCode = $ExpectedSiteCode } }
function Get-MemLabsExistingActionSupportSource {
    return (@{
            'ProcessFunctions.ps1' = 'function Test-ScopedSupport { return ''support-ready'' }'
            'ScriptFunctions.ps1' = 'function Write-DscStatus { param($Status,[switch]$Failure); if($Failure){$global:MemLabsFailureSequence++;$global:MemLabsLastFailureStatus=$Status} }'
        } | ConvertTo-Json -Compress)
}
$password = [Security.SecureString]::new()
$password.AppendChar([char]120)
$Common = [pscustomobject]@{ LocalAdmin = [pscredential]::new('FixtureAdmin', $password) }
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'fixture.test'; domainNetBiosName = 'FIXTURE'; adminName = 'FixtureAdmin' }
    parameters = [pscustomobject]@{}
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'; hidden = $true; adminName = 'RecordedAdmin' },
        [pscustomobject]@{ vmName = 'NEW1'; role = 'SiteSystem' },
        [pscustomobject]@{ vmName = 'NEW2'; role = 'SiteSystem' }
    )
}
$before = $config | ConvertTo-Json -Depth 10 -Compress
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-scoped-runtime-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
$previousProgramData = $env:ProgramData
$env:ProgramData = $testRoot
try {
    $existingReceipt = Join-Path $testRoot 'existing-workflow.receipt'
    Set-Content -LiteralPath $existingReceipt -Value 'deliberately-broken-existing-workflow' -Encoding ASCII
    foreach ($mode in @('Completed', 'CompletedMultiple', 'RealSupport', 'ConfigWriteFailure', 'SupportFailure', 'PrerequisiteFailure', 'ReportedFailure', 'InvalidReceipt', 'WrongTarget', 'OmittedTarget', 'StoppedOwner', 'HostFailure')) {
        & {
            param($Mode)
            $script:RuntimeMode = $Mode
            $script:RpcCalls = 0
            $script:ConfigWrites = 0
            $fixtureSupport = Get-MemLabsExistingActionSupportSource
            function Get-MemLabsExistingActionSupportSource {
                if ($script:RuntimeMode -eq 'RealSupport') { return & $script:ProductionSupport }
                if ($script:RuntimeMode -eq 'SupportFailure') {
                    return (@{ 'ProcessFunctions.ps1' = 'function BrokenSupport {'; 'ScriptFunctions.ps1' = '' } | ConvertTo-Json -Compress)
                }
                return $fixtureSupport
            }
            function Set-Content {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline)]$Value, $LiteralPath, $Encoding)
                process {
                    Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop
                    if ((Split-Path $LiteralPath -Leaf) -eq 'deployConfig.json') {
                        $script:ConfigWrites++
                        if ($script:RuntimeMode -eq 'ConfigWriteFailure') { throw 'Synthetic write-then-throw configuration fault.' }
                    }
                }
            }
            function Write-Log { param($Text, [switch]$OutputStream) }
            function Get-VM {
                param($Name, $ErrorAction)
                return [pscustomobject]@{ State = $(if ($script:RuntimeMode -eq 'StoppedOwner') { 'Off' } else { 'Running' }) }
            }
            function Get-Acl {
                param($LiteralPath, $ErrorAction)
                $acl = [pscustomobject]@{}
                $acl | Add-Member ScriptMethod SetAccessRuleProtection { param($Protected, $Preserve) }
                $acl | Add-Member ScriptMethod AddAccessRule { param($Rule) }
                return $acl
            }
            function Set-Acl {
                param($LiteralPath, $AclObject, $ErrorAction)
                Assert-True ($LiteralPath.StartsWith($testRoot)) 'Runtime ACL changes escaped the owned temporary action directory.'
            }
            function Invoke-VmCommand {
                param($VmName, $VmDomainName, $VmDomainAccount, [switch]$RequireDomainIdentity, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries,
                    [switch]$RebootIfUnresponsive, [switch]$FailOnRemoteError, $ScriptBlock, $ArgumentList)
                $script:RpcCalls++
                Assert-True ($VmName -eq 'PRI1' -and $RequireDomainIdentity -and $VmDomainAccount -eq 'RecordedAdmin' -and -not $RebootIfUnresponsive -and
                    $SessionMaxRetries -eq 1 -and $TimeoutSeconds -eq 120) 'Runtime widened its owner, retries, power recovery, or timeout.'
                Assert-True ($ArgumentList[8].UserName -eq 'fixture.test\RecordedAdmin') 'Scoped runtime replaced the recorded owner administrator with a different domain principal.'
                try {
                    $output = @(& $ScriptBlock @ArgumentList)
                    return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output }
                }
                catch { return [pscustomobject]@{ ScriptBlockFailed = $true; ErrorDetails = $_.Exception.Message } }
            }
            function Restart-Service { throw 'Existing service repair must not run.' }
            function Start-VM2 { throw 'Existing power changes must not run.' }
            function Start-DscConfiguration { throw 'Existing LCM must not be used by action runtime.' }
            $requestedTargets = if ($Mode -in @('CompletedMultiple', 'OmittedTarget')) { @('NEW1', 'NEW2') } else { @('NEW1') }
            $payload = [pscustomobject]@{ Mode = $Mode; TargetVMNames = $requestedTargets }
            $action = [pscustomobject]@{
                Kind = 'BitLocker'; OwnerVMName = 'PRI1'; SiteCode = 'PRI'; TargetVMNames = $requestedTargets
                Payload = $payload; TimeoutSeconds = 120
                HostPreflightText = $(if ($Mode -eq 'HostFailure') { "param(`$Payload); throw 'Required existing relay is deliberately broken.'" } else { '' })
                HandlerText = @'
param($Payload)
if ($Payload.Mode -eq 'RealSupport') {
    if (-not (Get-Command Get-MemLabsWorkflowRequestedVMs -CommandType Function -ErrorAction Stop)) { throw 'Shipped support definitions were not loaded.' }
}
elseif ((Test-ScopedSupport) -ne 'support-ready') { throw 'Support definitions were not loaded.' }
if (-not $PSScriptRoot -or $PSScriptRoot -notlike '*MemLabs*Actions*') { throw 'Handler did not run from its isolated source directory.' }
switch ($Payload.Mode) {
    PrerequisiteFailure { throw 'Required existing site prerequisite is deliberately broken.' }
    ReportedFailure { Write-DscStatus 'Required role operation failed.' -Failure }
    InvalidReceipt { return 'not a completion receipt' }
}
$targets = switch ($Payload.Mode) {
    WrongTarget { 'UNRELATED' }
    OmittedTarget { 'NEW1' }
    default { $Payload.TargetVMNames }
}
[pscustomobject]@{Status='Completed';TargetVMNames=$targets}
'@
            }
            $failure = ''
            try { Invoke-MemLabsExistingHierarchyActions -DeployConfig $config -Actions @($action) }
            catch { $failure = $_.Exception.Message }
            if ($Mode -in @('Completed', 'CompletedMultiple', 'RealSupport')) {
                Assert-True (-not $failure -and $script:RpcCalls -eq 1) "Valid scoped runtime did not complete its exact requested action: $failure"
                Assert-True ($script:ConfigWrites -eq 1) 'Positive pipeline-bound configuration-write control did not execute.'
            }
            else {
                Assert-True ([bool]$failure) "Runtime '$Mode' returned success instead of a specific blocker."
                if ($Mode -in @('StoppedOwner', 'HostFailure')) {
                    Assert-True ($script:RpcCalls -eq 0) 'A blocked owner/host prerequisite still reached guest mutation.'
                }
                if ($Mode -eq 'ConfigWriteFailure') {
                    Assert-True ($script:ConfigWrites -eq 1 -and $failure -like '*write-then-throw*') 'The intended pre-handler write failure was not exercised.'
                }
            }
            $actionRoot = Join-Path $testRoot 'MemLabs\Actions'
            $secrets = @(Get-ChildItem -LiteralPath $actionRoot -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('deployConfig.json', 'cm_svc.txt') })
            Assert-True ($secrets.Count -eq 0) 'Runtime retained temporary secret-bearing configuration after completion/failure.'
            Assert-True ((Get-Content -LiteralPath $existingReceipt -Raw).Trim() -eq 'deliberately-broken-existing-workflow') `
                'Runtime changed existing hierarchy workflow state.'
        } $mode
    }
    Assert-True (($config | ConvertTo-Json -Depth 10 -Compress) -eq $before) 'Runtime mutated the host deployment/context configuration.'
}
finally {
    $env:ProgramData = $previousProgramData
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions isolated existing-hierarchy runtime assertions on PowerShell $($PSVersionTable.PSVersion)."
