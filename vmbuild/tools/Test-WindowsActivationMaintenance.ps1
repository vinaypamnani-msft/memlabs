<#
.SYNOPSIS
    Verifies air-gapped Windows activation skips without masking other failures.
.DESCRIPTION
    Executes the shipped fix with mocked licensing, DNS, TCP, slmgr, and sleeps.
    No network connections or host activation changes are made.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Assert-Activation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$Common = [pscustomobject]@{ IsAzureVM = $true }
$vmNote = [pscustomobject]@{ adminName = 'FixtureAdmin' }
$fixesToPerform = @()
. (Join-Path $RootPath 'Fixes\Fix_ActivateWindows.ps1')
Assert-Activation ($fixesToPerform.Count -eq 1 -and $fixesToPerform[0].FixName -eq 'Fix_ActivateWindows') 'Azure activation fix was not registered.'

function Write-FixLog {
    param([string]$Message)
    $script:Fixture.Logs.Add($Message)
}

function Get-CimInstance {
    [CmdletBinding()]
    param([Alias('Class')][string]$ClassName, [string]$Filter)
    switch ($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{ Name = 'Microsoft Windows 11 Pro' } }
        'SoftwareLicensingProduct' { [pscustomobject]@{ LicenseStatus = $script:Fixture.LicenseStatus } }
        default { throw "Unexpected CIM class '$ClassName'." }
    }
}

function cscript {
    $script:Fixture.CscriptCalls.Add(($args -join ' '))
    if ($args -contains '/ato') {
        $script:Fixture.AtoCalls++
        if ($script:Fixture.ActivationSucceeds) { $script:Fixture.LicenseStatus = 1 }
    }
    $global:LASTEXITCODE = 0
    'Synthetic slmgr output'
}

function ipconfig {}
function Start-Sleep { param([int]$Seconds) }

function Resolve-DnsName {
    [CmdletBinding()]
    param([string]$Name, [string]$Type)
    $script:Fixture.DnsCalls++
    if ($script:Fixture.DnsErrorId) {
        $message = 'Synthetic DNS failure; error detection must not depend on localized text'
        $exception = if ($null -ne $script:Fixture.DnsErrorCode) {
            [System.ComponentModel.Win32Exception]::new($script:Fixture.DnsErrorCode, $message)
        }
        else {
            [System.InvalidOperationException]::new($message)
        }
        $record = [System.Management.Automation.ErrorRecord]::new(
            $exception, $script:Fixture.DnsErrorId, [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $Name)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    [pscustomobject]@{ IPAddress = '192.0.2.10' }
}

function New-Object {
    param([string]$TypeName)
    if ($TypeName -ne 'System.Net.Sockets.TcpClient') { throw "Unexpected type '$TypeName'." }
    $script:Fixture.TcpCalls++
    $waitHandle = [pscustomobject]@{ Reachable = $script:Fixture.TcpReachable }
    $waitHandle | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { $this.Reachable }
    $client = [pscustomobject]@{
        Connected = $script:Fixture.TcpReachable
        PendingConnection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
    }
    $client | Add-Member -MemberType ScriptMethod -Name BeginConnect -Value { $this.PendingConnection }
    $client | Add-Member -MemberType ScriptMethod -Name EndConnect -Value {}
    $client | Add-Member -MemberType ScriptMethod -Name Close -Value {}
    $client
}

$cases = @(
    @{ Name = 'DNS refusal error ID'; DnsErrorId = 'DNS_ERROR_RCODE_REFUSED'; Success = $true; Dns = 1; Tcp = 0; Ato = 0; Skip = $true }
    @{ Name = 'DNS refusal native code'; DnsErrorId = 'DnsQueryFailed'; DnsErrorCode = 9005; Success = $true; Dns = 1; Tcp = 0; Ato = 0; Skip = $true }
    @{ Name = 'DNS timeout'; DnsErrorId = 'ERROR_TIMEOUT'; DnsErrorCode = 1460; Success = $false; Dns = 4; Tcp = 4; Ato = 1 }
    @{ Name = 'DNS name not found'; DnsErrorId = 'DNS_ERROR_RCODE_NAME_ERROR'; DnsErrorCode = 9003; Success = $false; Dns = 4; Tcp = 4; Ato = 1 }
    @{ Name = 'DNS server failure'; DnsErrorId = 'DNS_ERROR_RCODE_SERVER_FAILURE'; DnsErrorCode = 9002; Success = $false; Dns = 4; Tcp = 4; Ato = 1 }
    @{ Name = 'Unexpected DNS failure'; DnsErrorId = 'UnexpectedDnsFailure'; Success = $false; Dns = 4; Tcp = 4; Ato = 1 }
    @{ Name = 'TCP blocked without DNS refusal'; TcpReachable = $false; Success = $false; Dns = 4; Tcp = 4; Ato = 1 }
    @{ Name = 'Reachable KMS but still unlicensed'; Success = $false; Dns = 4; Tcp = 4; Ato = 4 }
    @{ Name = 'Activation verified'; ActivationSucceeds = $true; Success = $true; Dns = 1; Tcp = 1; Ato = 1 }
    @{ Name = 'Already activated'; AlreadyActivated = $true; Success = $true; Dns = 0; Tcp = 0; Ato = 0 }
)

foreach ($case in $cases) {
    $script:Fixture = @{
        Logs = [System.Collections.Generic.List[string]]::new()
        CscriptCalls = [System.Collections.Generic.List[string]]::new()
        DnsCalls = 0
        TcpCalls = 0
        AtoCalls = 0
        DnsErrorId = $case.DnsErrorId
        DnsErrorCode = $case.DnsErrorCode
        TcpReachable = $case.TcpReachable -ne $false
        LicenseStatus = if ($case.AlreadyActivated) { 1 } else { 0 }
        ActivationSucceeds = [bool]$case.ActivationSucceeds
    }
    $output = @(& $fixesToPerform[0].ScriptBlock)
    Assert-Activation ($output.Count -eq 1) "$($case.Name): fix must return exactly one structured result."
    $result = $output[0]
    Assert-Activation ($result.Success -is [bool] -and $result.Success -eq $case.Success) "$($case.Name): incorrect success result."
    Assert-Activation (-not [string]::IsNullOrWhiteSpace($result.Message)) "$($case.Name): result message is missing."
    Assert-Activation ($script:Fixture.DnsCalls -eq $case.Dns) "$($case.Name): incorrect DNS attempt count."
    Assert-Activation ($script:Fixture.TcpCalls -eq $case.Tcp) "$($case.Name): incorrect TCP probe count."
    Assert-Activation ($script:Fixture.AtoCalls -eq $case.Ato) "$($case.Name): incorrect activation attempt count."
    if ($case.Skip) {
        Assert-Activation ($result.Message -match 'DNS.+refused.+air-gapped.+activation skipped') "$($case.Name): success must explain the air-gapped activation skip."
        Assert-Activation ($script:Fixture.Logs[-1] -eq $result.Message) "$($case.Name): transcript must explain the skip."
        Assert-Activation ($script:Fixture.LicenseStatus -eq 0) "$($case.Name): the skip must not claim Windows is licensed."
    }
    elseif (-not $case.Success) {
        Assert-Activation ($result.Message -like 'Activation failed after 4 attempts*') "$($case.Name): exhausted retries must remain a failure."
    }
    elseif ($case.AlreadyActivated) {
        Assert-Activation ($script:Fixture.CscriptCalls.Count -eq 0) "$($case.Name): licensed Windows must not run slmgr."
    }
    else {
        Assert-Activation ($result.Message -like '*verified LicenseStatus=1*') "$($case.Name): activation success must still verify the license."
    }
    Write-Host "PASS: $($case.Name)"
}

Write-Host "Windows activation maintenance checks passed ($($cases.Count) cases)."
