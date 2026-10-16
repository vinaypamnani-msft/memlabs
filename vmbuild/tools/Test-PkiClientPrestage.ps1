#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definition = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true)
    return [scriptblock]::Create($definition.Extent.Text)
}
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
$hostPath = Join-Path $root 'common\Common.ScriptBlocks.ps1'
$guestPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
foreach ($name in @('Get-MemLabsClientCertificateReadinessBlock', 'Invoke-MemLabsClientCertificatePrestage')) {
    . (Import-TestFunction $hostPath $name)
}
. (Import-TestFunction $guestPath 'Wait-MemLabsClientCertificatePrestage')
function Write-Log { param($Message, [switch] $OutputStream, [switch] $Warning) }
function Write-DscStatus { param($Message) }

$script:TestRoot = Microsoft.PowerShell.Management\Join-Path ([IO.Path]::GetTempPath()) "memlabs-pki-prestage-$PID"
$null = New-Item -ItemType Directory -Path $script:TestRoot
$script:Now = [datetime]'2026-10-16T12:00:00'
$script:AutoReceipt = $true
$script:AutoSuccess = $true
$script:NativeCalls = 0
function Get-Date { $script:Now }
function Join-Path {
    param($Path, $ChildPath)
    if ($Path -eq 'C:\staging\DSC') { $Path = $script:TestRoot }
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
function Start-Sleep {
    param($Seconds)
    $script:Now = $script:Now.AddSeconds($Seconds)
    if ($script:AutoReceipt) {
        $request = Get-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-request.json') -Raw | ConvertFrom-Json
        @{ RunId = $request.RunId; RequestId = $request.RequestId; Success = $script:AutoSuccess; Detail = 'fixture' } |
            ConvertTo-Json | Set-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-result.json')
    }
}
try {
    Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets @('CLIENT1', 'CLIENT2')
    $script:AutoSuccess = $false
    $failure = $null
    try { Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets CLIENT1 }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'pre-stage failed') 'Failed host readiness allowed client push.'

    $script:AutoReceipt = $false
    @{ RunId = 'other-run'; RequestId = 'old-request'; Success = $true } |
        ConvertTo-Json | Set-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-result.json')
    $started = Get-Date
    $failure = $null
    try { Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets CLIENT1 }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'timed out' -and ((Get-Date) - $started).TotalSeconds -eq 240) 'A stale receipt bypassed the bounded handshake deadline.'

    @{ RunId = 'test-run'; RequestId = 'old-request'; Success = $true } |
        ConvertTo-Json | Set-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-result.json')
    $failure = $null
    try { Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets CLIENT1 }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'timed out') 'A stale request ID within the same deployment allowed client push.'

    $script:RequestedDomains = @()
    $script:Unready = $false
    $script:RequestRunId = 'test-run'
    $script:WriteFailed = $false
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, [switch] $AsJob, $TimeoutSeconds, [switch] $SuppressLog,
            $ScriptBlock, $DisplayName, $ArgumentList)
        if ($DisplayName -eq 'Read PKI pre-stage request') {
            return [pscustomobject]@{
                ScriptBlockFailed = $false
                ScriptBlockOutput = [pscustomobject]@{ RunId = $script:RequestRunId; RequestId = 'request'; Targets = @('CLIENT1', 'CLIENT2') }
            }
        }
        if ($DisplayName -eq 'Write PKI pre-stage receipt') {
            $script:Receipt = $ArgumentList[0] | ConvertFrom-Json
            return [pscustomobject]@{ ScriptBlockFailed = $script:WriteFailed }
        }
        $script:RequestedDomains += "$VmName=$VmDomainName"
        [pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{
                Ready = -not ($script:Unready -and $VmName -eq 'CLIENT2')
                CertFound = $true; ChainStatus = 'fixture'; Diagnostics = @()
            }
        }
    }
    $item = [pscustomobject]@{ vmName = 'PRI'; thisParams = @{ ClientPush = @('CLIENT1', 'CLIENT2') } }
    $config = @{ virtualMachines = @(
        @{ vmName = 'CLIENT1'; domain = 'first.test' }
        @{ vmName = 'CLIENT2'; domain = 'second.test' }
    ) }
    Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run'
    Assert-True ($script:Receipt.Success -and $script:Receipt.RequestId -eq 'request') 'Host did not acknowledge matching successful readiness.'
    Assert-True (($script:RequestedDomains -join ',') -eq 'CLIENT1=first.test,CLIENT2=second.test') 'Cross-forest targets used the site domain instead of their own domains.'
    $config.virtualMachines += $item
    Invoke-MemLabsClientCertificatePrestage -CurrentItem ([pscustomobject]@{ vmName = 'PRI' }) -DeployConfig $config -DomainName 'site.test' -RunId 'test-run'
    Assert-True $script:Receipt.Success 'Host could not resolve push configuration for a monitor item without thisParams.'
    $script:RequestRunId = 'stale-run'
    $failure = $null
    try { Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure) 'Host accepted a request from a different deployment.'
    $script:RequestRunId = 'test-run'
    $script:WriteFailed = $true
    $failure = $null
    try { Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'persist') 'Receipt transport failure was silently accepted.'
    $script:WriteFailed = $false
    $script:Unready = $true
    Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run'
    Assert-True (-not $script:Receipt.Success -and $script:Receipt.Results.Count -eq 2) 'One failed target was hidden by other successful targets.'
    $item.thisParams.ClientPush = @('CLIENT1')
    $failure = $null
    try { Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'unconfigured') 'Unconfigured request targets were executed.'

    Add-Type @'
namespace MemLabs {
    public class ClientChainTest : System.IDisposable {
        public System.Security.Cryptography.X509Certificates.X509ChainPolicy ChainPolicy =
            new System.Security.Cryptography.X509Certificates.X509ChainPolicy();
        public object[] ChainStatus = new object[0];
        public bool Build(bool trusted) { return trusted; }
        public void Dispose() {}
    }
}
'@
    $readinessText = (Get-MemLabsClientCertificateReadinessBlock).ToString().Replace(
        '[Security.Cryptography.X509Certificates.X509Chain]', '[MemLabs.ClientChainTest]').Replace(
        '.Build($cert)', '.Build([bool]$cert.Trusted)')
    $readiness = [scriptblock]::Create($readinessText)
    $script:Candidates = @()
    $script:CertificateReads = 0
    $script:EnrollAfter = 0
    function Get-ChildItem {
        param($Path, $ErrorAction)
        $script:CertificateReads++
        if ($script:EnrollAfter -and $script:CertificateReads -lt $script:EnrollAfter) { return @() }
        return $script:Candidates
    }
    function gpupdate.exe { $global:LASTEXITCODE = 0; $script:NativeCalls++; 'GP refreshed' }
    function certutil.exe { $global:LASTEXITCODE = 5; $script:NativeCalls++; 'enrollment not ready' }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) @() }
    $script:Candidates = @(
        [pscustomobject]@{
            EnhancedKeyUsageList = @{ ObjectId = @('1.3.6.1.5.5.7.3.2') }
            Subject = 'leaf'; Issuer = 'CA'; HasPrivateKey = $true
            NotBefore = $script:Now.AddDays(-1); NotAfter = $script:Now.AddDays(30)
            Thumbprint = 'usable'; Trusted = $true
        }
    )
    $script:EnrollAfter = 3
    $state = & $readiness
    Assert-True ($state.Ready -and $state.Thumbprint -eq 'usable' -and $script:CertificateReads -eq 3) 'Delayed autoenrollment did not converge within bounded retries.'
    Assert-True (($state.Diagnostics -join ' ') -match 'exit=5') 'Native enrollment failure exit codes were lost.'
    $script:Candidates[0].HasPrivateKey = $false
    $script:CertificateReads = 0
    $state = & $readiness
    Assert-True (-not $state.Ready -and $script:CertificateReads -eq 4) 'A certificate without its private key passed readiness.'
    $script:Candidates[0].HasPrivateKey = $true
    $script:Candidates[0].Trusted = $false
    $state = & $readiness
    Assert-True (-not $state.Ready) 'An untrusted certificate chain passed readiness.'
    $script:Candidates[0].Trusted = $true
    $script:Candidates[0].NotAfter = $script:Now.AddSeconds(-1)
    $state = & $readiness
    Assert-True (-not $state.Ready) 'An expired certificate passed readiness.'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
}
Write-Host 'PASS -- PKI push waits for matching per-run host readiness; enrollment, private keys and trust fail closed.'
