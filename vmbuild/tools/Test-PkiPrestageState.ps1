#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$guestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSC\phases\ScriptFunctions.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($guestPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Guest functions have parse errors: $($errors -join '; ')" }
foreach ($name in @(
        'Write-ScriptWorkflowJsonAtomic', 'Read-ScriptWorkflowData',
        'New-MemLabsClientCertificateMutex', 'Invoke-MemLabsClientCertificateStateLock', 'Assert-MemLabsClientCertificateReceipt',
        'Publish-MemLabsClientCertificateReceipt'
    )) {
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $name definition." }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-DscStatus { param($Message, [switch]$NoStatus) }

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-pki-state-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $stateRoot -ItemType Directory
try {
    $aclMutex = New-MemLabsClientCertificateMutex -Name "Global\MemLabsPkiAclTest_$([guid]::NewGuid().ToString('N'))"
    try {
        $security = if ($PSVersionTable.PSEdition -eq 'Core') {
            [Threading.ThreadingAclExtensions]::GetAccessControl($aclMutex)
        }
        else { $aclMutex.GetAccessControl() }
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            Assert-True (@($rules | Where-Object {
                        $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' -and
                        ($_.MutexRights -band [Security.AccessControl.MutexRights]::FullControl) -eq [Security.AccessControl.MutexRights]::FullControl
                    }).Count -gt 0) "The PKI state lock is inaccessible to administrative caller $sid."
        }
    }
    finally { $aclMutex.Dispose() }
    $runPath = Join-Path $stateRoot 'ScriptWorkflow.expected.runid'
    $requestPath = Join-Path $stateRoot 'ScriptWorkflow.pki-request.json'
    $receiptPath = Join-Path $stateRoot 'ScriptWorkflow.pki-result.json'
    [IO.File]::WriteAllText($runPath, 'run')
    $request = @{ RunId = 'run'; RequestId = 'current'; Targets = @('CLIENT1', 'CLIENT2') }
    Write-ScriptWorkflowJsonAtomic -Configuration $request -ConfigurationFile $requestPath
    $receipt = @{
        RunId = 'run'; RequestId = 'current'; Success = $true; Detail = 'verified'
        Results = @(
            @{ Target = 'client1'; Ready = $true; Detail = 'certificate verified' },
            @{ Target = 'CLIENT2'; Ready = $true; Detail = 'certificate verified' }
        )
    }
    $json = $receipt | ConvertTo-Json -Depth 6
    $parameters = @{ Root = $stateRoot; Json = $json; ExpectedRunId = 'run'; ExpectedRequestId = 'current' }
    $ack = @(Publish-MemLabsClientCertificateReceipt @parameters)
    Assert-True ($ack.Count -eq 1 -and $ack[0].Status -eq 'Written' -and
        $ack[0].RunId -eq 'run' -and $ack[0].RequestId -eq 'current') 'A successful receipt commit had an invalid acknowledgement.'
    $saved = Read-ScriptWorkflowData -ConfigurationFile $receiptPath
    Assert-MemLabsClientCertificateReceipt -Receipt $saved -RunId run -RequestId current -Targets CLIENT1,CLIENT2
    Assert-True ($saved.Success -is [bool] -and $saved.Results.Count -eq 2) 'Persisted receipt lost its typed result shape.'

    $request.RequestId = 'replacement'
    Write-ScriptWorkflowJsonAtomic -Configuration $request -ConfigurationFile $requestPath
    $replacement = $receipt.Clone()
    $replacement.RequestId = 'replacement'
    Write-ScriptWorkflowJsonAtomic -Configuration $replacement -ConfigurationFile $receiptPath
    $before = [IO.File]::ReadAllText($receiptPath)
    $ack = Publish-MemLabsClientCertificateReceipt @parameters
    Assert-True ($ack.Status -eq 'Superseded' -and $ack.CurrentRequestId -eq 'replacement' -and
        [IO.File]::ReadAllText($receiptPath) -eq $before) 'A late writer overwrote a newer request receipt.'

    [IO.File]::WriteAllText($runPath, 'other-run')
    $failure = $null
    try { $null = Publish-MemLabsClientCertificateReceipt @parameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'Deployment changed' -and [IO.File]::ReadAllText($receiptPath) -eq $before) `
        'A stale deployment wrote a receipt or lost its explicit failure.'
    [IO.File]::WriteAllText($runPath, 'run')

    $request.RequestId = 'current'
    $request.Targets = @('CLIENT1', 'DIFFERENT')
    Write-ScriptWorkflowJsonAtomic -Configuration $request -ConfigurationFile $requestPath
    $failure = $null
    try { $null = Publish-MemLabsClientCertificateReceipt @parameters }
    catch { $failure = $_.Exception.Message }
    Assert-True ($failure -match 'target result' -and [IO.File]::ReadAllText($receiptPath) -eq $before) `
        'A reused request ID with changed targets accepted unrelated certificate evidence.'
    $request.Targets = @('CLIENT1', 'CLIENT2')
    Write-ScriptWorkflowJsonAtomic -Configuration $request -ConfigurationFile $requestPath

    $lock = [IO.File]::Open($receiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $failure = $null
        try { $null = Publish-MemLabsClientCertificateReceipt @parameters }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'atomically persist') 'A locked receipt was acknowledged as successfully committed.'
    }
    finally { $lock.Dispose() }
    Assert-True ([IO.File]::ReadAllText($receiptPath) -eq $before) 'A failed atomic replacement damaged the previous receipt.'
    Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -File -Force | Where-Object Name -match '\.tmp(?:\.bak)?$').Count -eq 0) `
        'Receipt publication left request-specific temporary or backup files behind.'

    Add-Type @'
public sealed class MemLabsPkiMutexFixture : System.IDisposable {
    public bool Abandoned;
    public bool Disposed;
    public bool Released;
    public bool WaitOne(System.TimeSpan timeout) {
        if (Abandoned) throw new System.Threading.AbandonedMutexException();
        return false;
    }
    public void ReleaseMutex() { Released = true; }
    public void Dispose() { Disposed = true; }
}
'@
    & {
        $script:LockBodyRan = $false
        $script:FakeMutex = [MemLabsPkiMutexFixture]::new()
        function New-MemLabsClientCertificateMutex {
            param($Name)
            if ($Name -notlike 'Global\MemLabs_PkiPrestage_*') { throw "Unexpected mutex $Name" }
            return $script:FakeMutex
        }
        $failure = $null
        try {
            Invoke-MemLabsClientCertificateStateLock -StateDirectory $stateRoot -TimeoutSeconds 0 `
                -ScriptBlock { $script:LockBodyRan = $true }
        }
        catch { $failure = $_.Exception.Message }
        Assert-True ($failure -match 'state lock' -and -not $script:LockBodyRan -and
            $script:FakeMutex.Disposed -and -not $script:FakeMutex.Released) 'The PKI state mutex failed open after acquisition timed out.'
        $script:FakeMutex.Abandoned = $true
        $script:FakeMutex.Disposed = $false
        Invoke-MemLabsClientCertificateStateLock -StateDirectory $stateRoot -TimeoutSeconds 0 `
            -ScriptBlock { $script:LockBodyRan = $true }
        Assert-True ($script:LockBodyRan -and $script:FakeMutex.Disposed -and $script:FakeMutex.Released) `
            'Abandoned PKI lock recovery failed or did not release owned state.'
    }
}
finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- PKI receipts commit atomically, reject stale requests/deployments, and use fail-closed state locking.'
