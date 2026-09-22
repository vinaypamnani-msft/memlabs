#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$collectorPath = Join-Path $RootPath 'vmbuild\common\Common.ScriptBlocks.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$collectorPath has $($errors.Count) parse error(s)." }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-CMSetupLogsFromVm'
        }, $true))
if ($definition.Count -ne 1) { throw "Expected one Save-CMSetupLogsFromVm function, found $($definition.Count)." }
. ([scriptblock]::Create($definition[0].Extent.Text))

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

$collectorText = Get-Content -LiteralPath $collectorPath -Raw
foreach ($logName in @('SMSProv.log', 'SMSProv.lo_', 'dmpdownloader.log', 'dmpdownloader.lo_', 'cmupdate.log', 'cmupdate.lo_', 'hman.log', 'hman.lo_', 'distmgr.log', 'smsexec.log', 'ConfigMgrPrereq.log', 'SmsAdminUI')) {
    Assert-Equal $true $collectorText.Contains($logName) "failure collector names $logName"
}
foreach ($className in @('SMS_CM_UpdatePackages', 'SMS_CM_UpdatePackDownloadMonitoring', 'SMS_CM_UpdatePackTopLevelMonitoring', 'SMS_CM_UpdatePackDetailedMonitoring')) {
    Assert-Equal $true $collectorText.Contains("'$className'") "failure snapshot queries $className"
}
Assert-Equal $true ($collectorText -match "Mode -eq 'Failure'[\s\S]+CmArtifacts") 'ConfigMgr product diagnostics are failure-only'
Assert-Equal $true ($collectorText.Contains('$Mode -eq ''Failure'' -and $Phase -eq 8')) 'product diagnostics are scoped to Phase 8 failure'
Assert-Equal $true ($collectorText -match "-AsJob -TimeoutSeconds 120 -SessionMaxRetries 1 -SuppressLog -DisplayName 'Capture ConfigMgr provider state'") 'provider snapshot runs separately with a hard host timeout'
Assert-Equal $true ($collectorText -match "-AsJob -TimeoutSeconds 180 -SessionMaxRetries 1 -SuppressLog -DisplayName 'Pull ConfigMgr failure diagnostics'") 'large product-log transfer is isolated and bounded'
Assert-Equal $true ($collectorText -match 'OperationTimeoutSec 10') 'each direct provider query has a bounded operation timeout'
Assert-Equal $true ($collectorText -match 'DirectCimErrors') 'provider snapshot records per-class failures'
Assert-Equal $true ($collectorText -match 'ProductLogInventory') 'static snapshot inventories missing and unreadable product logs'
Assert-Equal $true ($collectorText -match 'tailLines=4000') 'product-log transfer uses bounded 4000-line tails'
Assert-Equal $true ($collectorText -match 'Get-CMSiteUpdate -Fast -ErrorAction Stop') 'provider snapshot replays the broad cmdlet query'
Assert-Equal $true ($collectorText -match 'Get-CMSiteUpdate -Name \$packageName -Fast -ErrorAction Stop') 'provider snapshot replays the name-filtered cmdlet query'
Assert-Equal $true ($collectorText.Contains("Join-Path `$_ 'AdminUILog'")) 'console trace search includes the registered UI installation directory'
Assert-Equal $true ($collectorText -match 'systemprofile\\AppData\\Local\\Temp') 'console trace search includes the LocalSystem temp directory'
Assert-Equal 0 @([regex]::Matches($collectorText, '(?:\||^)\s*Invoke-CMSiteUpdateDownload\s', [Text.RegularExpressions.RegexOptions]::Multiline)).Count 'diagnostic provider probe invokes no mutating download command'
Assert-Equal $true ($collectorText -match 'DownloadParameterSets') 'provider snapshot records installed download parameter sets without invoking them'
Assert-Equal $true ($collectorText -match 'Remove-PSDrive -Name \$probe\.SiteCode') 'provider probe removes the CMSite drive it creates'
Assert-Equal $true ($collectorText -match 'Remove-Module -ModuleInfo \$module') 'provider probe removes the ConfigurationManager module it imports'
Assert-Equal $true ($collectorText -match 'HostSerializationFailed.+BaselineCapture') 'baseline fallback survives host JSON serialization failure'
Assert-Equal $true ($collectorText -match 'HostSerializationFailed.+ConfigMgrProductLogs') 'product-log fallback survives host JSON serialization failure'

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('cm-failure-diag-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir
try {
    $script:Common = [pscustomobject]@{ LogPath = Join-Path $workDir 'VMBuild.test.log' }
    $script:CollectorMessages = New-Object System.Collections.Generic.List[string]
    $script:CollectorInvocations = New-Object System.Collections.Generic.List[object]
    $script:FailBaselineCapture = $false
    $script:FailProductCapture = $false
    $script:FailProviderCapture = $false
    function Write-Log {
        param([string]$Message, [switch]$Warning, [switch]$OutputStream)
        $script:CollectorMessages.Add($Message)
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, [switch]$SuppressLog, $DisplayName, [switch]$AsJob, [int]$TimeoutSeconds, [int]$SessionMaxRetries)
        $script:CollectorInvocations.Add([pscustomobject]@{ DisplayName = $DisplayName; AsJob = $AsJob.IsPresent; TimeoutSeconds = $TimeoutSeconds; SessionMaxRetries = $SessionMaxRetries })
        if ($DisplayName -eq 'Capture ConfigMgr provider state') {
            if ($script:FailProviderCapture) {
                return [pscustomobject]@{
                    ScriptBlockFailed = $true
                    ScriptBlockOutput = $null
                    TimedOut          = $true
                    ErrorDetails      = @('synthetic provider timeout')
                }
            }
            return [pscustomobject]@{
                ScriptBlockFailed = $false
                ScriptBlockOutput = '{"ProbeStatus":"Completed","DirectCimErrors":{"SMS_CM_UpdatePackages":"synthetic provider error"}}'
                TimedOut          = $false
                ErrorDetails      = @()
            }
        }
        if ($DisplayName -eq 'Pull ConfigMgr failure diagnostics' -and $script:FailProductCapture) {
            return [pscustomobject]@{
                ScriptBlockFailed = $true
                ScriptBlockOutput = $null
                TimedOut          = $true
                ErrorDetails      = @('synthetic product-log timeout')
            }
        }
        if ($DisplayName -like 'Pull CM setup logs*' -and $script:FailBaselineCapture) {
            return [pscustomobject]@{
                ScriptBlockFailed = $true
                ScriptBlockOutput = $null
                TimedOut          = $true
                ErrorDetails      = @('synthetic baseline timeout')
            }
        }
        $output = [pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{
                SetupExists      = $false
                WrapperExists    = $false
                DscLogExists     = $false
                AdkArtifacts     = @()
                CmArtifacts      = @(
                    [pscustomobject]@{ Name = 'SMSProv.log'; Bytes = 2048; TailLines = 8000; Content = 'provider method evidence' }
                    [pscustomobject]@{ Name = 'dmpdownloader.log'; Bytes = 4096; TailLines = 8000; Content = 'download engine evidence' }
                    [pscustomobject]@{ Name = 'cmupdate.log'; Bytes = 1024; TailLines = 8000; Content = 'update engine evidence' }
                )
                UpdateDiagnostics = '{"SiteCode":"PS1","ConsoleLogSearchDirectories":["E:\\ConfigMgr\\AdminConsole\\AdminUILog"],"ProductLogInventory":[{"SourcePath":"E:\\ConfigMgr\\Logs\\SMSProv.log","Exists":true,"Collected":true,"Bytes":2048,"Error":""}]}'
            }
        }
        return $output
    }

    Save-CMSetupLogsFromVm -VmName 'DIAG-PS1SITE' -DomainName 'example.test' -Phase 8 -Mode 'Failure'
    $baseInvocation = @($script:CollectorInvocations | Where-Object DisplayName -like 'Pull CM setup logs*')
    Assert-Equal 1 $baseInvocation.Count 'baseline logs use their existing independent transfer'
    if ($baseInvocation.Count -eq 1) {
        Assert-Equal $true $baseInvocation[0].AsJob 'baseline log transfer uses the bounded job path'
        Assert-Equal 300 $baseInvocation[0].TimeoutSeconds 'baseline log transfer has a 300-second hard timeout'
        Assert-Equal 1 $baseInvocation[0].SessionMaxRetries 'baseline log transfer does not repeat the full connection ladder'
    }
    $productInvocation = @($script:CollectorInvocations | Where-Object DisplayName -eq 'Pull ConfigMgr failure diagnostics')
    Assert-Equal 1 $productInvocation.Count 'product logs use a second independent transfer'
    if ($productInvocation.Count -eq 1) {
        Assert-Equal $true $productInvocation[0].AsJob 'product-log transfer uses the bounded job path'
        Assert-Equal 180 $productInvocation[0].TimeoutSeconds 'product-log transfer has a 180-second hard timeout'
        Assert-Equal 1 $productInvocation[0].SessionMaxRetries 'product-log transfer does not repeat the full connection ladder'
    }
    foreach ($name in @('SMSProv.log', 'dmpdownloader.log', 'cmupdate.log')) {
        $files = @(Get-ChildItem -LiteralPath $workDir -Filter "DIAG-PS1SITE-Phase8-*-$name" -File)
        Assert-Equal 1 $files.Count "host collector writes $name"
    }
    $snapshot = @(Get-ChildItem -LiteralPath $workDir -Filter 'DIAG-PS1SITE-Phase8-*-ConfigMgrUpdateDiagnostics.json' -File)
    Assert-Equal 1 $snapshot.Count 'host collector writes the structured update snapshot'
    if ($snapshot.Count -eq 1) {
        $snapshotJson = Get-Content -LiteralPath $snapshot[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'PS1' $snapshotJson.SiteCode 'structured snapshot content survives host transfer'
        Assert-Equal 'E:\ConfigMgr\AdminConsole\AdminUILog' $snapshotJson.ConsoleLogSearchDirectories[0] 'structured snapshot preserves console-log search locations'
        Assert-Equal $true $snapshotJson.ProductLogInventory[0].Collected 'structured snapshot preserves product-log collection status'
    }
    $providerSnapshot = @(Get-ChildItem -LiteralPath $workDir -Filter 'DIAG-PS1SITE-Phase8-*-ConfigMgrProviderState.json' -File)
    Assert-Equal 1 $providerSnapshot.Count 'host collector writes the independently bounded provider snapshot'
    if ($providerSnapshot.Count -eq 1) {
        $providerJson = Get-Content -LiteralPath $providerSnapshot[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'synthetic provider error' $providerJson.DirectCimErrors.SMS_CM_UpdatePackages 'provider snapshot preserves provider-query errors'
    }
    $providerInvocation = @($script:CollectorInvocations | Where-Object DisplayName -eq 'Capture ConfigMgr provider state')
    Assert-Equal 1 $providerInvocation.Count 'collector invokes the provider snapshot independently'
    if ($providerInvocation.Count -eq 1) {
        Assert-Equal $true $providerInvocation[0].AsJob 'provider snapshot uses the bounded job path'
        Assert-Equal 120 $providerInvocation[0].TimeoutSeconds 'provider snapshot has a 120-second hard timeout'
        Assert-Equal 1 $providerInvocation[0].SessionMaxRetries 'provider snapshot does not repeat the full connection ladder'
    }
    $messages = @($script:CollectorMessages) -join "`n"
    Assert-Equal $true ($messages -match 'Pulled ConfigMgr diagnostic SMSProv\.log') 'collector reports product-log capture'
    Assert-Equal $true ($messages -match 'Pulled ConfigMgr update/provider state') 'collector reports snapshot capture'
    Assert-Equal $true ($messages -match 'Captured bounded ConfigMgr provider state') 'collector reports independently bounded provider capture'

    $failureWorkDir = Join-Path $workDir 'baseline-failure'
    $null = New-Item -ItemType Directory -Path $failureWorkDir
    $script:Common.LogPath = Join-Path $failureWorkDir 'VMBuild.test.log'
    $script:CollectorInvocations.Clear()
    $script:CollectorMessages.Clear()
    $script:FailBaselineCapture = $true
    Save-CMSetupLogsFromVm -VmName 'FAIL-PS1SITE' -DomainName 'example.test' -Phase 8 -Mode 'Failure'
    Assert-Equal 1 @($script:CollectorInvocations | Where-Object DisplayName -eq 'Pull ConfigMgr failure diagnostics').Count 'baseline failure does not suppress product-log capture'
    Assert-Equal 1 @($script:CollectorInvocations | Where-Object DisplayName -eq 'Capture ConfigMgr provider state').Count 'baseline failure does not suppress provider-state capture'
    $baselineFailure = @(Get-ChildItem -LiteralPath $failureWorkDir -Filter 'FAIL-PS1SITE-Phase8-*-BaselineCaptureStatus.json' -File)
    Assert-Equal 1 $baselineFailure.Count 'baseline failure writes a self-describing status artifact'
    if ($baselineFailure.Count -eq 1) {
        $baselineFailureJson = Get-Content -LiteralPath $baselineFailure[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'HostInvocationFailed' $baselineFailureJson.CaptureStatus 'baseline fallback records invocation failure'
        Assert-Equal $true $baselineFailureJson.TimedOut 'baseline fallback records timeout state'
        Assert-Equal 'synthetic baseline timeout' $baselineFailureJson.ErrorDetails[0] 'baseline fallback retains host error details'
    }
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $failureWorkDir -Filter 'FAIL-PS1SITE-Phase8-*-SMSProv.log' -File).Count 'baseline failure still preserves product logs'

    $diagnosticFailureWorkDir = Join-Path $workDir 'diagnostic-failure'
    $null = New-Item -ItemType Directory -Path $diagnosticFailureWorkDir
    $script:Common.LogPath = Join-Path $diagnosticFailureWorkDir 'VMBuild.test.log'
    $script:CollectorInvocations.Clear()
    $script:CollectorMessages.Clear()
    $script:FailBaselineCapture = $false
    $script:FailProductCapture = $true
    $script:FailProviderCapture = $true
    Save-CMSetupLogsFromVm -VmName 'TIMEOUT-PS1SITE' -DomainName 'example.test' -Phase 8 -Mode 'Failure'
    $productFailure = @(Get-ChildItem -LiteralPath $diagnosticFailureWorkDir -Filter 'TIMEOUT-PS1SITE-Phase8-*-ConfigMgrUpdateDiagnostics.json' -File)
    Assert-Equal 1 $productFailure.Count 'product-log timeout writes a self-describing fallback artifact'
    if ($productFailure.Count -eq 1) {
        $productFailureJson = Get-Content -LiteralPath $productFailure[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'HostInvocationFailed' $productFailureJson.CaptureStatus 'product-log fallback records invocation failure'
        Assert-Equal $true $productFailureJson.TimedOut 'product-log fallback records timeout state'
        Assert-Equal 'synthetic product-log timeout' $productFailureJson.ErrorDetails[0] 'product-log fallback retains host error details'
    }
    $providerFailure = @(Get-ChildItem -LiteralPath $diagnosticFailureWorkDir -Filter 'TIMEOUT-PS1SITE-Phase8-*-ConfigMgrProviderState.json' -File)
    Assert-Equal 1 $providerFailure.Count 'provider timeout writes a self-describing fallback artifact'
    if ($providerFailure.Count -eq 1) {
        $providerFailureJson = Get-Content -LiteralPath $providerFailure[0].FullName -Raw | ConvertFrom-Json
        Assert-Equal 'HostInvocationFailed' $providerFailureJson.ProbeStatus 'provider fallback records invocation failure'
        Assert-Equal $true $providerFailureJson.TimedOut 'provider fallback records timeout state'
        Assert-Equal 'synthetic provider timeout' $providerFailureJson.ErrorDetails[0] 'provider fallback retains host error details'
    }
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) { throw "$script:Failures ConfigMgr failure-diagnostic assertion(s) failed." }
Write-Host 'ALL CONFIGMGR FAILURE-DIAGNOSTIC TESTS PASSED'