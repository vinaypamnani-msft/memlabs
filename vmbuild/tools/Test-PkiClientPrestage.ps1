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
foreach ($name in @(
        'Write-ScriptWorkflowJsonAtomic', 'Read-ScriptWorkflowData',
        'New-MemLabsClientCertificateMutex', 'Invoke-MemLabsClientCertificateStateLock', 'Assert-MemLabsClientCertificateReceipt',
        'Wait-MemLabsClientCertificatePrestage'
    )) {
    . (Import-TestFunction $guestPath $name)
}
function Write-Log {
    param($Message, [switch] $OutputStream, [switch] $Warning, [switch] $Failure)
    if ($OutputStream) {
        if (-not $script:ReceiptWritten) { $script:EarlyProgressCount++ }
        [pscustomobject]@{
            Message = "$Message"
            LogLevel = $(if ($Failure) { 3 } elseif ($Warning) { 2 } else { 1 })
        }
    }
}
function Write-DscStatus { param($Message) }

$script:TestRoot = Microsoft.PowerShell.Management\Join-Path ([IO.Path]::GetTempPath()) "memlabs-pki-prestage-$PID"
$null = New-Item -ItemType Directory -Path $script:TestRoot
$script:Now = [datetime]'2026-10-16T12:00:00'
$script:AutoReceipt = $true
$script:AutoSuccess = $true
$script:ReceiptMode = 'Normal'
$script:NativeCalls = 0
function Get-Date { $script:Now }
function Join-Path {
    param($Path, $ChildPath)
    if ($Path -eq 'C:\staging\DSC') { $Path = $script:TestRoot }
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
function Start-Sleep {
    param($Seconds, $Milliseconds)
    $script:Now = $script:Now.AddSeconds($Seconds).AddMilliseconds($Milliseconds)
    if ($script:AutoReceipt) {
        $request = Get-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-request.json') -Raw | ConvertFrom-Json
        $receipt = @{
            RunId = $request.RunId; RequestId = $request.RequestId
            Success = $script:AutoSuccess; Detail = 'fixture'
            Results = @($request.Targets | ForEach-Object {
                    [pscustomobject]@{ Target = "$_"; Ready = [bool]$script:AutoSuccess; Detail = 'fixture' }
                })
        }
        switch ($script:ReceiptMode) {
            'StringSuccess' { $receipt.Success = 'true' }
            'MissingResults' { $receipt.Remove('Results') }
            'PartialResults' { $receipt.Results = @($receipt.Results[0]) }
            'DuplicateResults' { $receipt.Results = @($receipt.Results[0], $receipt.Results[0]) }
            'WrongTarget' { $receipt.Results[0].Target = 'UNREQUESTED' }
            'FalseReady' { $receipt.Results[0].Ready = $false }
            'StringReady' { $receipt.Results[0].Ready = 'true' }
            'FalseSummary' { $receipt.Success = $false }
        }
        $receipt | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-result.json')
    }
}
try {
    Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets @('CLIENT1', 'CLIENT2')
    Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets @('CLIENT1', 'client1')
    $normalizedRequest = Get-Content (Join-Path $script:TestRoot 'ScriptWorkflow.pki-request.json') -Raw | ConvertFrom-Json
    Assert-True (@($normalizedRequest.Targets).Count -eq 1) 'Case-only duplicate targets were probed and budgeted multiple times.'
    foreach ($mode in @('StringSuccess', 'MissingResults', 'PartialResults', 'DuplicateResults', 'WrongTarget', 'FalseReady', 'StringReady', 'FalseSummary')) {
        $script:ReceiptMode = $mode
        $failure = $null
        try { Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets @('CLIENT1', 'CLIENT2') }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) "Malformed successful PKI receipt ($mode) allowed client push."
        if ($mode -eq 'FalseSummary') {
            Assert-True ($failure -match 'failure summary contradicts') 'Contradictory failure evidence was misreported as a certificate fault.'
        }
    }
    $script:ReceiptMode = 'Normal'
    $script:AutoSuccess = $false
    $failure = $null
    try { Wait-MemLabsClientCertificatePrestage -RunId 'test-run' -Targets CLIENT1 }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'pre-stage failed') 'Failed host readiness allowed client push.'
    Assert-True ($failure -match 'host per-target PKI readiness diagnostics' -and $failure -notmatch 'Fix template enrollment') `
        'Every failed pre-stage receipt is still being misreported as an enrollment-policy fault.'

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
    $script:WriteMissing = $false
    $script:WriteSuperseded = $false
    $script:WriteAckMissing = $false
    $script:ReadMode = 'Normal'
    $script:ProbeMode = 'Normal'
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, [switch] $AsJob, $TimeoutSeconds, [switch] $SuppressLog,
            $ScriptBlock, $DisplayName, $ArgumentList)
        if ($DisplayName -eq 'Read PKI pre-stage request') {
            $request = [pscustomobject]@{ RunId = $script:RequestRunId; RequestId = 'request'; Targets = @('CLIENT1', 'CLIENT2') }
            if ($script:ReadMode -eq 'Multiple') { $request = @($request, $request) }
            if ($script:ReadMode -eq 'EmptyId') { $request.RequestId = ' ' }
            if ($script:ReadMode -eq 'InvalidTarget') { $request.Targets = @(1, 'CLIENT2') }
            if ($script:ReadMode -eq 'DuplicateTarget') { $request.Targets = @('CLIENT1', 'client1', 'CLIENT2') }
            return [pscustomobject]@{
                ScriptBlockFailed = $false
                ScriptBlockOutput = $request
            }
        }
        if ($DisplayName -eq 'Write PKI pre-stage receipt') {
            $script:Receipt = $ArgumentList[0] | ConvertFrom-Json
            if ($script:WriteMissing) { return $null }
            $script:ReceiptWritten = -not $script:WriteSuperseded
            $ack = [pscustomobject]@{
                Status = $(if ($script:WriteSuperseded) { 'Superseded' } else { 'Written' })
                RunId = $ArgumentList[1]; RequestId = $ArgumentList[2]
            }
            if ($script:WriteAckMissing) { $ack = $null }
            return [pscustomobject]@{ ScriptBlockFailed = $script:WriteFailed; ScriptBlockOutput = $ack }
        }
        $script:RequestedDomains += "$VmName=$VmDomainName"
        $state = [pscustomobject]@{
            Ready = -not ($script:Unready -and $VmName -eq 'CLIENT2')
            CertFound = $true; ChainOk = $true; ChainStatus = 'fixture'; Diagnostics = @(); Thumbprint = "fixture-$VmName"
        }
        if ($script:ProbeMode -eq 'Multiple') { $state = @($state, $state) }
        if ($script:ProbeMode -eq 'StringReady') { $state.Ready = 'false' }
        if ($script:ProbeMode -eq 'Missing') { $state = $null }
        if ($script:ProbeMode -eq 'Inconsistent') { $state.ChainOk = $false }
        [pscustomobject]@{
            ScriptBlockFailed = ($script:ProbeMode -eq 'Transport')
            ScriptBlockOutput = $state
            ErrorDetails = 'Synthetic certificate-probe transport error'
        }
    }
    $item = [pscustomobject]@{ vmName = 'PRI'; thisParams = @{ ClientPush = @('CLIENT1', 'CLIENT2') } }
    $config = @{ virtualMachines = @(
        @{ vmName = 'CLIENT1'; domain = 'first.test' }
        @{ vmName = 'CLIENT2'; domain = 'second.test' }
    ) }
    $targetResults = @(Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run')
    Assert-True ($script:Receipt.Success -and $script:Receipt.RequestId -eq 'request') 'Host did not acknowledge matching successful readiness.'
    Assert-True ($script:Receipt.Results.Count -eq 2 -and $targetResults.Count -eq 2 -and
        @($script:Receipt.Results | Where-Object { -not $_.Target -or $_.Ready -isnot [bool] }).Count -eq 0 -and
        @($targetResults | Where-Object { $_.PSObject.Properties.Name -contains 'LogLevel' }).Count -eq 0) `
        'Console log objects leaked into per-target certificate readiness results.'
    Assert-True (($script:RequestedDomains -join ',') -eq 'CLIENT1=first.test,CLIENT2=second.test') 'Cross-forest targets used the site domain instead of their own domains.'
    $tokens = $null; $errors = $null
    $hostAst = [Management.Automation.Language.Parser]::ParseFile($hostPath, [ref]$tokens, [ref]$errors)
    $prestageFunction = $hostAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-MemLabsClientCertificatePrestage'
        }, $true)
    $logEmitters = @($prestageFunction.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-Log' -and
                @($node.CommandElements | Where-Object {
                        $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'OutputStream'
                    }).Count -gt 0
            }, $true))
    Assert-True ($logEmitters.Count -eq 0) 'The result-producing certificate helper still emits console log objects.'
    $branches = @($hostAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -match '^\$currentStatusTrimmed -match ''MEMLABS-PULSE-CERTS'''
            }, $true))
    Assert-True ($branches.Count -eq 1) 'The host monitor PKI request branch was not found.'
    $monitor = [scriptblock]::Create(
        'param($currentItem, $deployConfig, $domainName, $expectedRunId)' + [Environment]::NewLine +
        '$currentStatusTrimmed = "MEMLABS-PULSE-CERTS"; $certPulseDone = ""; $Phase = 8' + [Environment]::NewLine +
        $branches[0].Extent.Text)
    $script:ReceiptWritten = $false
    $script:EarlyProgressCount = 0
    $console = @(& $monitor $item $config 'site.test' 'test-run')
    Assert-True ($console.Count -eq 2 -and
        @($console | Where-Object { $_.LogLevel -ne 1 -or $_.Message -notmatch 'PKI pre-stage ready=True' }).Count -eq 0 -and
        $script:EarlyProgressCount -eq 2 -and $script:Receipt.Success -and $script:Receipt.Results.Count -eq 2) `
        'The production monitor lost per-target console progress or mixed it into the readiness receipt.'
    $config.virtualMachines += $item
    $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem ([pscustomobject]@{ vmName = 'PRI' }) -DeployConfig $config -DomainName 'site.test' -RunId 'test-run'
    Assert-True $script:Receipt.Success 'Host could not resolve push configuration for a monitor item without thisParams.'
    $script:RequestRunId = 'stale-run'
    $failure = $null
    try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ([bool]$failure) 'Host accepted a request from a different deployment.'
    $script:RequestRunId = 'test-run'
    $script:ReadMode = 'DuplicateTarget'
    $duplicateResults = @(Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run')
    Assert-True ($duplicateResults.Count -eq 2 -and $script:Receipt.Results.Count -eq 2) 'Case-only request duplicates escaped host normalization.'
    foreach ($mode in @('Multiple', 'EmptyId', 'InvalidTarget')) {
        $script:ReadMode = $mode
        $failure = $null
        try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
        catch { $failure = $_.Exception.Message }
        Assert-True ([bool]$failure) "$mode malformed request was accepted."
    }
    $script:ReadMode = 'Normal'
    $script:WriteFailed = $true
    $failure = $null
    try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'persist') 'Receipt transport failure was silently accepted.'
    $script:WriteFailed = $false
    $script:WriteMissing = $true
    $failure = $null
    try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'persist') 'A missing receipt-write response was silently accepted.'
    $script:WriteMissing = $false
    $script:WriteAckMissing = $true
    $failure = $null
    try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'acknowledgement') 'An unacknowledged receipt write was accepted.'
    $script:WriteAckMissing = $false
    $script:WriteSuperseded = $true
    $staleConsole = @(& $monitor $item $config 'site.test' 'test-run')
    Assert-True (@($staleConsole | Where-Object LogLevel -eq 3).Count -eq 0 -and
        @($staleConsole | Where-Object { $_.LogLevel -eq 2 -and $_.Message -match 'superseded' }).Count -eq 1) `
        'A replaced request caused a false deployment failure instead of a warning.'
    $script:WriteSuperseded = $false
    foreach ($mode in @('Multiple', 'StringReady', 'Missing', 'Transport', 'Inconsistent')) {
        $script:ProbeMode = $mode
        $invalidResults = @(Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run')
        Assert-True (-not $script:Receipt.Success -and $script:Receipt.Results.Count -eq 2 -and
            @($invalidResults | Where-Object Ready).Count -eq 0) "$mode probe output bypassed fail-closed readiness."
        if ($mode -eq 'Transport') {
            Assert-True ($script:Receipt.Detail -match 'Synthetic certificate-probe transport error') `
                'Probe transport failure detail was discarded.'
        }
    }
    $script:ProbeMode = 'Normal'
    $script:Unready = $true
    $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run'
    Assert-True (-not $script:Receipt.Success -and $script:Receipt.Results.Count -eq 2) 'One failed target was hidden by other successful targets.'
    $item.thisParams.ClientPush = @('CLIENT1')
    $failure = $null
    try { $null = Invoke-MemLabsClientCertificatePrestage -CurrentItem $item -DeployConfig $config -DomainName 'site.test' -RunId 'test-run' }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'unconfigured') 'Unconfigured request targets were executed.'

    Add-Type @'
namespace MemLabs {
    public class ClientChainTest : System.IDisposable {
        public static bool ThrowForUntrusted = false;
        public System.Security.Cryptography.X509Certificates.X509ChainPolicy ChainPolicy =
            new System.Security.Cryptography.X509Certificates.X509ChainPolicy();
        public object[] ChainStatus = new object[0];
        public bool Build(bool trusted) {
            if (!trusted && ThrowForUntrusted)
                throw new System.Security.Cryptography.CryptographicException("Synthetic invalid certificate");
            return trusted;
        }
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
    $script:NativeThrows = $false
    $script:EventsFail = $false
    function gpupdate.exe {
        if ($script:NativeThrows) { throw 'Synthetic gpupdate invocation error' }
        $global:LASTEXITCODE = 0; $script:NativeCalls++; 'GP refreshed'
    }
    function certutil.exe {
        if ($script:NativeThrows) { throw 'Synthetic certutil invocation error' }
        $global:LASTEXITCODE = 5; $script:NativeCalls++; 'enrollment not ready'
    }
    function Get-WinEvent {
        param($FilterHashtable, $MaxEvents, $ErrorAction)
        if ($script:EventsFail) { throw 'Synthetic event-log access error' }
        @()
    }
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
    Assert-True (@($state).Count -eq 1 -and $state.Ready -and $state.Thumbprint -eq 'usable' -and $script:CertificateReads -eq 3) 'Delayed autoenrollment did not converge to one readiness result within bounded retries.'
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
    Assert-True (($state.Diagnostics -join ' ') -match 'No recent AutoEnrollment events found') `
        'An empty autoenrollment event query was not distinguished from a failed query.'
    $script:Candidates[0].NotAfter = $script:Now.AddDays(30)
    $badCert = $script:Candidates[0].PSObject.Copy()
    $badCert.Trusted = $false; $badCert.Thumbprint = 'broken'; $badCert.NotAfter = $script:Now.AddDays(60)
    $script:Candidates = @($badCert, $script:Candidates[0])
    [MemLabs.ClientChainTest]::ThrowForUntrusted = $true
    $state = & $readiness
    Assert-True ($state.Ready -and $state.Thumbprint -eq 'usable' -and
        ($state.Diagnostics -join ' ') -match 'broken.*Synthetic invalid certificate') `
        'A broken first certificate prevented selection of another usable client-auth certificate.'
    [MemLabs.ClientChainTest]::ThrowForUntrusted = $false
    $script:Candidates = @()
    $script:NativeThrows = $true
    $script:EventsFail = $true
    $state = & $readiness
    Assert-True (-not $state.Ready -and ($state.Diagnostics -join ' ') -match 'gpupdate invocation failed' -and
        ($state.Diagnostics -join ' ') -match 'certutil.*invocation failed' -and
        ($state.Diagnostics -join ' ') -match 'event query failed') `
        'Enrollment or event-log execution failures lost their diagnostic context.'
    Assert-True ($readinessText -match 'UrlRetrievalTimeout = \[TimeSpan\]::FromSeconds\(10\)') `
        'Certificate-chain URL retrieval has no bounded timeout.'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
}
Write-Host 'PASS -- PKI push waits for matching per-run host readiness; enrollment, private keys and trust fail closed.'
