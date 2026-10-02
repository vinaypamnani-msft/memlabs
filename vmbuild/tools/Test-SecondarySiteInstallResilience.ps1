<#
.SYNOPSIS
    Verifies secondary-site provider retries and child-job completion handling.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$functionsPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
$installerPath = Join-Path $root 'DSC\phases\InstallSecondarySiteServer.ps1'
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$What)

    if ($Condition) {
        Write-Host "PASS  $What"
        return
    }
    $script:Failures++
    Write-Host "FAIL  $What"
}

function Assert-Like {
    param([string]$Expected, [string]$Actual, [string]$What)
    Assert-True -Condition ($Actual -like $Expected) -What $What
    if ($Actual -notlike $Expected) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$Path has $(@($errors).Count) parse error(s)." }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $functionsPath -Name 'Get-SecondarySiteInstallMonitorSnapshot')
. (Import-TestFunction -Path $functionsPath -Name 'Test-SecondarySiteReplicationActive')
. (Import-TestFunction -Path $functionsPath -Name 'Test-MPHttpsBinding')
. (Import-TestFunction -Path $functionsPath -Name 'Receive-SecondarySiteInstallJobResult')

$script:SiteReadFailure = $null
$script:StatusReadFailure = $null
function Get-CMSite {
    param([string]$SiteCode, $ErrorAction)
    [void]$ErrorAction
    if ($script:SiteReadFailure) { throw $script:SiteReadFailure }
    [pscustomobject]@{ SiteCode = $SiteCode; Status = 2 }
}
function Get-WmiObject {
    param([string]$ComputerName, [string]$Namespace, [string]$Class, [string]$Filter, $ErrorAction)
    [void]$ComputerName
    [void]$Namespace
    [void]$Class
    [void]$Filter
    [void]$ErrorAction
    if ($script:StatusReadFailure) { throw $script:StatusReadFailure }
    @(
        [pscustomobject]@{ MessageTime = '20260930140002.000000+000'; Status = 'second' },
        [pscustomobject]@{ MessageTime = '20260930140001.000000+000'; Status = 'first' }
    )
}

$script:SiteReadFailure = 'synthetic provider recycle'
$caught = $null
try {
    Get-SecondarySiteInstallMonitorSnapshot -SecondarySiteCode SEC -ProviderFqdn provider.test `
        -ProviderNamespacePath 'root\SMS\site_PRI'
}
catch {
    $caught = $_
}
Assert-Like "*Get-CMSite failed for secondary site 'SEC': *synthetic provider recycle*" "$($caught.Exception.Message)" 'site-row read failure retains actionable context'

$script:SiteReadFailure = $null
$snapshot = Get-SecondarySiteInstallMonitorSnapshot -SecondarySiteCode SEC -ProviderFqdn provider.test `
    -ProviderNamespacePath 'root\SMS\site_PRI'
Assert-True ($snapshot.SiteStatus.Status -eq 2) 'monitor snapshot returns the secondary site row'
Assert-True (@($snapshot.StatusHistory).Count -eq 2) 'monitor snapshot returns the full status history'
Assert-True ($snapshot.StatusHistory[0].Status -eq 'first') 'monitor snapshot sorts status history chronologically'

$script:StatusReadFailure = 'synthetic status query failure'
$caught = $null
try {
    Get-SecondarySiteInstallMonitorSnapshot -SecondarySiteCode SEC -ProviderFqdn provider.test `
        -ProviderNamespacePath 'root\SMS\site_PRI'
}
catch {
    $caught = $_
}
Assert-Like "*SMS_SecondarySiteStatus query failed for secondary site 'SEC': *synthetic status query failure*" "$($caught.Exception.Message)" 'status-history failure retains actionable context'
$script:StatusReadFailure = $null

$activeReplication = [pscustomobject]@{
    LinkStatus = 2
    Site1ToSite2GlobalState = 2
    Site2ToSite1GlobalState = 2
}
$incompleteReplication = [pscustomobject]@{
    LinkStatus = 2
    Site1ToSite2GlobalState = 2
    Site2ToSite1GlobalState = 4
}
Assert-True (Test-SecondarySiteReplicationActive -ReplicationStatus $activeReplication) 'three Active DRS states are ready'
Assert-True (-not (Test-SecondarySiteReplicationActive -ReplicationStatus $incompleteReplication)) 'one incomplete DRS direction is not ready'
Assert-True (-not (Test-SecondarySiteReplicationActive -ReplicationStatus $null)) 'missing DRS status is not ready'

$script:HttpsProbeResult = $true
function Invoke-Command { param($ComputerName, $ScriptBlock, $ErrorAction) return $script:HttpsProbeResult }
function Write-DscStatus { param($Status) }
Assert-True (Test-MPHttpsBinding -MPFQDN 'secondary.example.test') 'healthy Secondary HTTPS binding is accepted'
$script:HttpsProbeResult = $false
Assert-True (-not (Test-MPHttpsBinding -MPFQDN 'secondary.example.test')) 'missing or stale Secondary HTTPS binding fails readiness'
Remove-Item Function:\Invoke-Command -ErrorAction SilentlyContinue
Remove-Item Function:\Write-DscStatus -ErrorAction SilentlyContinue

$jobs = New-Object System.Collections.Generic.List[System.Management.Automation.Job]
try {
    $goodJob = Start-Job -Name 'SecondaryResilience-Good' -ScriptBlock {
        [pscustomobject]@{
            MemLabsSecondaryInstallResult = $true
            Succeeded = $true
            LastStep = 80
            LastStatus = 'Installing ConfigMgr services'
        }
    }
    $jobs.Add($goodJob)
    $goodResult = Receive-SecondarySiteInstallJobResult -Job $goodJob
    Assert-True $goodResult.Succeeded 'completed child job with success marker is accepted'

    $missingMarkerJob = Start-Job -Name 'SecondaryResilience-NoMarker' -ScriptBlock { 'noise only' }
    $jobs.Add($missingMarkerJob)
    $missingMarkerResult = Receive-SecondarySiteInstallJobResult -Job $missingMarkerJob
    Assert-True (-not $missingMarkerResult.Succeeded) 'completed child job without marker is rejected'
    Assert-Like '*did not return its completion marker*' $missingMarkerResult.Reason 'missing marker explains why completion was rejected'

    $failedJob = Start-Job -Name 'SecondaryResilience-Failed' -ScriptBlock { throw 'synthetic child failure' }
    $jobs.Add($failedJob)
    $failedResult = Receive-SecondarySiteInstallJobResult -Job $failedJob
    Assert-True (-not $failedResult.Succeeded) 'failed child job is rejected'
    Assert-Like '*synthetic child failure*' $failedResult.Reason 'failed child reason is preserved'

    $timedOutJob = Start-Job -Name 'SecondaryResilience-Timeout' -ScriptBlock { Start-Sleep -Seconds 30 }
    $jobs.Add($timedOutJob)
    $timedOutResult = Receive-SecondarySiteInstallJobResult -Job $timedOutJob -TimeoutSeconds 1
    Assert-True (-not $timedOutResult.Succeeded) 'timed-out child job is rejected'
    Assert-Like '*did not finish within 1 seconds and was stopped*' $timedOutResult.Reason 'job timeout is explicit and bounded'
}
finally {
    foreach ($job in $jobs) {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

$installerText = Get-Content -LiteralPath $installerPath -Raw
Assert-True ($installerText -match '\$providerReadFailureStart') 'installer tracks consecutive provider-read failure time'
Assert-True ($installerText -match 'providerReadFailureSec\s+-ge\s+\$providerReadTimeoutSec') 'provider-read retries remain bounded'
Assert-True ($installerText -match 'Reset-CMSiteProviderConnection\s+-SiteCode\s+\$SiteCode') 'provider-read retry rebuilds the CMSite drive'
Assert-True ($installerText -match '\$recoveryObservedInProgress') 'recovery must enter an in-progress state before Active is accepted'
Assert-True ($installerText -match 'if\s*\(-not \$installed\s+-and\s+-not \$recoveryRequested\)') 'recovery does not fall through into a duplicate New-CMSecondarySite request'
Assert-True ($installerText -match 'Test-DrsLinkHealthyViaSql\s+-SqlDataSource') 'lagging DRS summary has a SQL ground-truth fallback'
Assert-True ($installerText -match 'if\s*\(\$drsActive\)[\s\S]{0,4000}Wait-CMRoleRegistered\s+-RoleName\s+''Secondary DP''') 'child success requires Active DRS and a provider-visible Secondary DP'
Assert-True ($installerText -match 'SMS_DistributionPointInfo') 'Secondary DP readiness uses the authoritative provider class'
Assert-True ($installerText -match 'if\s*\(\$usePKI\)[\s\S]{0,1800}Confirm-MPHttpsBinding\s+-MPFQDN\s+\$secondaryFQDN') 'PKI resume always ensures the Secondary MP HTTPS binding'
Assert-True ($installerText -match 'Test-MPHttpsBinding\s+-MPFQDN\s+\$secondaryFQDN') 'PKI Secondary success verifies binding health after repair'
Assert-True ($installerText -match 'Restart-Service\s+-Name\s+SMS_SITE_COMPONENT_MANAGER[\s\S]{0,400}retry implicit HTTPS MP provisioning') 'PKI resume forces the Secondary MP installer out of backoff'
Assert-True ($installerText -match 'Wait-CMRoleRegistered\s+-RoleName\s+''Secondary MP''[\s\S]{0,300}Get-CMManagementPoint\s+-SiteSystemServerName\s+\$secondaryFQDN') 'child success requires a provider-visible Secondary MP'
Assert-True ($installerText -match 'Wait-CMRoleRegistered\s+-RoleName\s+''Secondary MP IIS''[\s\S]{0,500}Get-WebApplication\s+-Site\s+''Default Web Site''\s+-Name\s+''SMS_MP''') 'child success requires the Secondary SMS_MP IIS application'
Assert-True ($installerText -match 'if\s*\(\$secondaryDp\s+-and\s+\$secondaryMp\s+-and\s+\$secondaryMpIis\s+-and\s+\$secondaryHttpsReady\)') 'secondary completion requires DP, MP, MP IIS, and HTTPS readiness together'
Assert-True ($installerText -match 'Receive-SecondarySiteInstallJobResult\s+-Job\s+\$secondaryJob') 'parent drains and validates each exact child job'
Assert-True ($installerText -match 'if\s*\(\$secondaryJobsSucceeded\)[\s\S]{0,500}InstallSecondary''\s+-Status\s+''Completed''') 'InstallSecondary completion is gated on validated child results'

if ($script:Failures -gt 0) {
    throw "$($script:Failures) secondary-site resilience check(s) failed."
}
Write-Host 'PASS -- secondary provider recycling is retryable and child-job completion is authoritative.'
