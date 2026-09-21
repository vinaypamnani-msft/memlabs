#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$sourcePath = Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$sourcePath has $($errors.Count) parse error(s)." }
$functionNames = @('Get-CmSiteUpdateByPackageGuid', 'Start-CmSiteUpdatePackageDownload')
$functionAsts = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames
        }, $true))
if ($functionAsts.Count -ne $functionNames.Count) { throw "Expected $($functionNames.Count) site-update functions, found $($functionAsts.Count)." }
foreach ($functionName in $functionNames) {
    $functionAst = @($functionAsts | Where-Object Name -eq $functionName)
    if ($functionAst.Count -ne 1) { throw "Expected one $functionName function, found $($functionAst.Count)." }
    . ([scriptblock]::Create($functionAst[0].Extent.Text))
}

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

$script:Packages = @()
$script:GetCalls = 0
$script:GetFailuresRemaining = 0
$script:DownloadCalls = 0
$script:DownloadFailuresRemaining = 0
$script:LastDownloadInput = $null
$script:Sleeps = @()
$script:StatusMessages = @()

function Get-CMSiteUpdate {
    [CmdletBinding()]
    param([switch]$Fast)
    $script:GetCalls++
    if ($script:GetFailuresRemaining -gt 0) {
        $script:GetFailuresRemaining--
        throw [ArgumentNullException]::new('key')
    }
    return $script:Packages
}

function Invoke-CMSiteUpdateDownload {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]$InputObject,
        [switch]$Force
    )
    process {
        $script:DownloadCalls++
        $script:LastDownloadInput = $InputObject
        if ($script:DownloadFailuresRemaining -gt 0) {
            $script:DownloadFailuresRemaining--
            throw [ArgumentNullException]::new('key')
        }
    }
}

function Start-Sleep {
    param([int]$Seconds)
    $script:Sleeps += $Seconds
}

function Write-DscStatus {
    param([string]$Status, [switch]$Failure)
    $script:StatusMessages += [pscustomobject]@{ Text = $Status; Failure = $Failure.IsPresent }
}

$targetPackage = [pscustomobject]@{ Name = 'Configuration Manager 2503'; PackageGuid = 'target-guid'; State = 327682 }
$sameNameWrongPackage = [pscustomobject]@{ Name = 'Configuration Manager 2503'; PackageGuid = 'wrong-guid'; State = 327682 }
$script:Packages = @($sameNameWrongPackage, $targetPackage)
$result = Start-CmSiteUpdatePackageDownload -UpdatePackage $targetPackage -MaximumAttempts 2 -RetrySeconds 0
Assert-Equal 'target-guid' $result.PackageGuid 'download selects the update by stable PackageGuid'
Assert-Equal 'target-guid' $script:LastDownloadInput.PackageGuid 'download cmdlet receives the keyed provider object through the pipeline'
Assert-Equal 1 $script:GetCalls 'successful download refreshes the provider object once'
Assert-Equal 1 $script:DownloadCalls 'successful download invokes the cmdlet once'

$script:GetCalls = 0
$script:DownloadCalls = 0
$script:DownloadFailuresRemaining = 1
$script:Sleeps = @()
$script:StatusMessages = @()
$result = Start-CmSiteUpdatePackageDownload -UpdatePackage $targetPackage -MaximumAttempts 3 -RetrySeconds 7
Assert-Equal 'target-guid' $result.PackageGuid 'null-key failure is retried with a refreshed keyed object'
Assert-Equal 2 $script:GetCalls 'each retry refreshes through the unfiltered provider query'
Assert-Equal 2 $script:DownloadCalls 'one transient failure causes exactly one retry'
Assert-Equal '7' ($script:Sleeps -join ',') 'transient failure waits only between attempts'
Assert-Equal $true ([bool]($script:StatusMessages | Where-Object { $_.Text -like '*download invocation failed*attempt 1/3*Value cannot be null*' })) 'download failure is attributed and remains visible in the DSC log'

$script:GetCalls = 0
$script:GetFailuresRemaining = 1
$script:DownloadCalls = 0
$script:DownloadFailuresRemaining = 0
$script:StatusMessages = @()
$result = Start-CmSiteUpdatePackageDownload -UpdatePackage $targetPackage -MaximumAttempts 2 -RetrySeconds 0
Assert-Equal 'target-guid' $result.PackageGuid 'provider null-key failure is retried by the download owner'
Assert-Equal 2 $script:GetCalls 'provider null-key retry performs a fresh unfiltered query'
Assert-Equal 1 $script:DownloadCalls 'download starts only after provider refresh succeeds'
Assert-Equal 0 @($script:StatusMessages | Where-Object Failure).Count 'caller-owned provider retry does not emit a premature JOBFAILURE'
Assert-Equal $true ([bool]($script:StatusMessages | Where-Object { $_.Text -like '*provider refresh failed*attempt 1/2*Value cannot be null*' })) 'provider refresh failure is attributed accurately'

$script:GetCalls = 0
$script:DownloadCalls = 0
$script:DownloadFailuresRemaining = 5
$script:Sleeps = @()
$caught = $null
try { Start-CmSiteUpdatePackageDownload -UpdatePackage $targetPackage -MaximumAttempts 2 -RetrySeconds 0 | Out-Null }
catch { $caught = $_ }
Assert-Equal $true ([bool]$caught) 'retry exhaustion throws instead of returning success'
Assert-Equal $true ($caught.Exception.Message -like "Could not request the download for 'Configuration Manager 2503'*after 2 attempts*download invocation*key*") 'retry exhaustion preserves package identity, stage, and the last error'
Assert-Equal 2 $script:DownloadCalls 'retry exhaustion honors the attempt bound'

$script:Packages = @()
$script:GetCalls = 0
$script:GetFailuresRemaining = 0
$script:StatusMessages = @()
$caught = $null
try { Get-CmSiteUpdateByPackageGuid -PackageGuid 'missing-guid' -PackageName 'Configuration Manager 2503' -MaximumAttempts 2 -RetrySeconds 0 | Out-Null }
catch { $caught = $_ }
Assert-Equal $true ([bool]$caught) 'provider refresh exhaustion throws'
Assert-Equal 2 $script:GetCalls 'provider refresh exhaustion honors its attempt bound'
Assert-Equal 1 @($script:StatusMessages | Where-Object Failure).Count 'unowned provider refresh exhaustion emits one JOBFAILURE'
Assert-Equal 1 (@($script:StatusMessages | Where-Object Failure).Count) 'provider refresh exhaustion emits one JOBFAILURE'
$source = Get-Content -LiteralPath $sourcePath -Raw
Assert-Equal 0 @([regex]::Matches($source, 'Invoke-CMSiteUpdateDownload\s+-Name')).Count 'download avoids the cmdlet name-search parameter set'
Assert-Equal 0 @([regex]::Matches($source, 'Get-CMSiteUpdate\s+(?:-Fast\s+)?-Name')).Count 'state refresh avoids name-filtered provider queries'
Assert-Equal 2 @([regex]::Matches($source, 'Get-CmSiteUpdateByPackageGuid[^\r\n]+-SuppressFailureStatus')).Count 'only caller-owned retry paths suppress refresh failure status'
Assert-Equal $true ($source -match '(?s)catch \{\s*\$downloadFailure = \$_\.Exception\.Message\s*Write-DscStatus.+?-Failure\s*return\s*\}') 'download exhaustion writes JOBFAILURE and stops Phase 8'

if ($script:Failures -gt 0) { throw "$script:Failures ConfigMgr site-update download regression assertion(s) failed." }
Write-Host 'ALL CONFIGMGR SITE-UPDATE DOWNLOAD TESTS PASSED'