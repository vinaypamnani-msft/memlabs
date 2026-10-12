<#
.SYNOPSIS
    Diagnoses whether a VM's expected IP resolves to another Hyper-V VM.
.EXAMPLE
    .\Probe-VmIpOwnership.ps1 -VmName CT5-LINUXDESK1 -IPAddress 192.168.50.23
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $VmName,
    [string] $IPAddress,
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

function Normalize-Mac {
    param($Value)
    if (-not $Value) { return '' }
    ("$Value" -replace '[-:.\s]', '').ToUpperInvariant()
}

function Test-ProbeTcpPort {
    param([string] $Address, [int] $Port, [int] $TimeoutMs = 2000)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return [pscustomobject]@{ Port = $Port; Open = $false; Error = 'timeout' }
        }
        $client.EndConnect($pending)
        [pscustomobject]@{ Port = $Port; Open = $client.Connected; Error = '' }
    }
    catch {
        [pscustomobject]@{ Port = $Port; Open = $false; Error = $_.Exception.Message }
    }
    finally {
        $client.Dispose()
    }
}

$vm = Get-VM -Name $VmName -ErrorAction Stop
$targetAdapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
if (-not $IPAddress) {
    $IPAddress = @($targetAdapters.IPAddresses | Where-Object {
            $_ -match '^\d+\.\d+\.\d+\.\d+$' -and
            $_ -notlike '127.*' -and $_ -notlike '169.254.*'
        } | Select-Object -First 1)
}
if (-not $IPAddress) {
    throw "$VmName has no reported non-APIPA IPv4 address. Pass -IPAddress explicitly."
}

$expectedMacs = @($targetAdapters | ForEach-Object {
        Normalize-Mac $_.MacAddress
    } | Where-Object { $_ } | Select-Object -Unique)
$allAdapters = @(Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue)

$samples = [System.Collections.Generic.List[object]]::new()
foreach ($sampleNumber in 1..5) {
    $null = Test-Connection -ComputerName $IPAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $neighbors = @(Get-NetNeighbor -IPAddress $IPAddress -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -notin @('Unreachable', 'Incomplete') -and
            (Normalize-Mac $_.LinkLayerAddress)
        })
    foreach ($neighbor in $neighbors) {
        $observedMac = Normalize-Mac $neighbor.LinkLayerAddress
        $owners = @($allAdapters | Where-Object {
                (Normalize-Mac $_.MacAddress) -eq $observedMac
            } | ForEach-Object {
                "$($_.VMName)[$($_.SwitchName)]"
            } | Select-Object -Unique)
        $samples.Add([pscustomobject]@{
                Sample      = $sampleNumber
                Time        = Get-Date
                Interface   = $neighbor.InterfaceAlias
                State       = "$($neighbor.State)"
                ObservedMac = $observedMac
                ExpectedMac = $observedMac -in $expectedMacs
                Owners      = $owners
            })
    }
    Start-Sleep -Milliseconds 500
}

$scopeId = (($IPAddress.Split('.') | Select-Object -First 3) -join '.') + '.0'
$reservations = @()
$leases = @()
if (Get-Command Get-DhcpServerv4Reservation -ErrorAction SilentlyContinue) {
    $reservations = @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue |
        Where-Object { "$($_.IPAddress)" -eq $IPAddress } |
        Select-Object IPAddress, ClientId, Name, Description)
}
if (Get-Command Get-DhcpServerv4Lease -ErrorAction SilentlyContinue) {
    $leases = @(Get-DhcpServerv4Lease -ScopeId $scopeId -ErrorAction SilentlyContinue |
        Where-Object { "$($_.IPAddress)" -eq $IPAddress } |
        Select-Object IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime)
}

$result = [ordered]@{
    CapturedAt       = (Get-Date).ToString('o')
    VmName           = $VmName
    VmState          = "$($vm.State)"
    VmHeartbeat      = "$($vm.Heartbeat)"
    IPAddress        = $IPAddress
    ExpectedMacs     = $expectedMacs
    TargetAdapters   = @($targetAdapters | Select-Object VMName, SwitchName, MacAddress, IPAddresses, Status)
    NeighborSamples  = $samples.ToArray()
    TcpPorts         = @(22, 445, 3389 | ForEach-Object {
            Test-ProbeTcpPort -Address $IPAddress -Port $_
        })
    DhcpReservations = $reservations
    DhcpLeases       = $leases
}

$resultObject = [pscustomobject]$result
$resultObject | Format-List
Write-Host '--- Neighbor ownership samples ---'
$samples | Format-Table -AutoSize
Write-Host '--- TCP probes ---'
$resultObject.TcpPorts | Format-Table -AutoSize

$wrongOwners = @($samples | Where-Object { -not $_.ExpectedMac -and $_.Owners })
if ($wrongOwners.Count -gt 0) {
    Write-Warning "$IPAddress resolves to another Hyper-V VM MAC: $(@($wrongOwners.Owners | Select-Object -Unique) -join ', '). Expected $VmName MAC(s): $($expectedMacs -join ', ')."
}
elseif (@($samples).Count -eq 0) {
    Write-Warning "No usable neighbor entry was observed for $IPAddress."
}
elseif (@($samples | Where-Object ExpectedMac).Count -eq 0) {
    Write-Warning "$IPAddress resolved to an unknown MAC rather than $VmName."
}
else {
    Write-Host "$IPAddress resolved to $VmName's expected MAC." -ForegroundColor Green
}

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $resultObject | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Wrote $OutputPath"
}
