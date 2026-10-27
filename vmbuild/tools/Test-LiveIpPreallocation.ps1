<#
.SYNOPSIS
    Verifies that retained live VM addresses cannot be reallocated.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $root 'Common.ps1'
$phasesPath = Join-Path $root 'common\Common.Phases.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "$Path has parse errors: $($errors -join '; ')"
    }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) {
        throw "Expected one $Name definition, found $($functions.Count)."
    }
    [scriptblock]::Create($functions[0].Extent.Text)
}

. (Import-TestFunction -Path $commonPath -Name 'ConvertTo-IpSortable')
. (Import-TestFunction -Path $commonPath -Name 'Set-DeployConfigIPAddresses')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS  $Message"
}

$script:Logs = [System.Collections.Generic.List[object]]::new()
$script:Reservations = [System.Collections.Generic.List[object]]::new()
$script:ExistingVms = @()
$script:Adapters = @{}

function Write-Log {
    param(
        [Parameter(Position = 0)] $Message,
        [switch] $Warning,
        [switch] $Failure,
        [switch] $LogOnly
    )
    $script:Logs.Add([pscustomobject]@{
            Message = "$Message"
            Warning = $Warning.IsPresent
            Failure = $Failure.IsPresent
        })
}

function Get-Service {
    param($Name, $ErrorAction)
    [pscustomobject]@{ Status = 'Running' }
}

function Get-DhcpServerv4Scope {
    param($ScopeId, $ErrorAction)
    [pscustomobject]@{
        ScopeId    = [ipaddress]'192.168.50.0'
        Name       = 'cstest5.com'
        StartRange = [ipaddress]'192.168.50.20'
        EndRange   = [ipaddress]'192.168.50.199'
    }
}

function Get-DhcpServerv4ScopeStatistics {
    param($ScopeId, $ErrorAction)
    [pscustomobject]@{ Free = 180; InUse = 0; Reserved = $script:Reservations.Count }
}

function Get-List {
    param($Type, $DomainName, [switch] $SmartUpdate)
    @($script:ExistingVms)
}

function Get-VM2 {
    param($Name, $ErrorAction)
    if ($script:Adapters.ContainsKey("$Name")) {
        [pscustomobject]@{ Name = "$Name" }
    }
}

function Get-VM {
    foreach ($name in $script:Adapters.Keys) {
        [pscustomobject]@{ Name = "$name" }
    }
}

function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $VM)
    process { @($script:Adapters["$($VM.Name)"]) }
}

function Get-DhcpServerv4Reservation {
    param($ScopeId, $IPAddress, $ClientId, $ErrorAction)
    @($script:Reservations | Where-Object {
            (-not $ScopeId -or "$($_.ScopeId)" -eq "$ScopeId") -and
            (-not $IPAddress -or "$($_.IPAddress)" -eq "$IPAddress") -and
            (-not $ClientId -or "$($_.ClientId)" -eq "$ClientId")
        })
}

function Remove-DhcpServerv4Reservation {
    param($IPAddress, $ScopeId, $ClientId, $ErrorAction)
}

function Add-DHCPReservationIsolated {
    param(
        $ScopeId, $IPAddress, $Mac, $Description, $LogContext,
        [switch] $PurgeMacFirst, $KnownReservedMacs
    )
    if (-not ($script:Reservations | Where-Object {
                "$($_.ScopeId)" -eq "$ScopeId" -and
                "$($_.IPAddress)" -eq "$IPAddress" -and
                (("$($_.ClientId)" -replace '[-:]', '').ToUpper()) -eq
                (($Mac -replace '[-:]', '').ToUpper())
            })) {
        $script:Reservations.Add([pscustomobject]@{
                ScopeId    = "$ScopeId"
                IPAddress  = [ipaddress]"$IPAddress"
                ClientId   = "$Mac"
                Description = "$Description"
            })
    }
}

function Get-VMNote {
    param($VMName, $ErrorAction)
    $null
}

function Invoke-WithDhcpMutex {
    param($ScriptBlock)
    & $ScriptBlock
}

function Get-DhcpServerv4FreeIPAddress {
    param($ScopeId, $ErrorAction)
    foreach ($lastOctet in 23..30) {
        $candidate = "192.168.50.$lastOctet"
        if (-not ($script:Reservations | Where-Object {
                    "$($_.IPAddress)" -eq $candidate
                })) {
            return [ipaddress]$candidate
        }
    }
}

function Add-DhcpServerv4ExclusionRange {
    param($ScopeId, $StartRange, $EndRange, $ErrorAction)
}

function Remove-DhcpServerv4ExclusionRange {
    param($ScopeId, $StartRange, $EndRange, $ErrorAction, [switch] $PassThru)
}

function New-TestConfig {
    [pscustomobject]@{
        vmOptions = [pscustomobject]@{
            network = '192.168.50.0'
            domainName = 'cstest5.com'
        }
        virtualMachines = @(
            [pscustomobject]@{
                vmName = 'CT5-CS1SQLAO1'
                role = 'SQLAO'
                hidden = $true
            },
            [pscustomobject]@{
                vmName = 'CT5-LINUXDESK1'
                role = 'LinuxClient'
                network = '192.168.50.0'
                hidden = $false
            }
        )
    }
}

$script:ExistingVms = @([pscustomobject]@{
        vmName = 'CT5-CS1SQLAO1'
        role = 'SQLAO'
    })
$script:Adapters = @{
    'CT5-CS1SQLAO1' = @(
        [pscustomobject]@{
            VMName = 'CT5-CS1SQLAO1'
            SwitchName = '192.168.50.0'
            MacAddress = '00155D0004D4'
            IPAddresses = @('192.168.50.23', '169.254.1.24')
        },
        [pscustomobject]@{
            VMName = 'CT5-CS1SQLAO1'
            SwitchName = 'ClusterV2'
            MacAddress = '00155D0004D3'
            IPAddresses = @('10.250.250.20')
        }
    )
}

$config = New-TestConfig
$safeResult = Set-DeployConfigIPAddresses -DeployConfig $config
$linux = $config.virtualMachines | Where-Object vmName -eq 'CT5-LINUXDESK1'

Assert-True $safeResult 'safe retained address protection returns success'
Assert-True ([bool]($script:Reservations | Where-Object {
            "$($_.IPAddress)" -eq '192.168.50.23' -and
            $_.ClientId -eq '00155D0004D4'
        })) 'retained SQLAO live address is converted to a durable reservation'
Assert-True ($linux.AssignedIP -eq '192.168.50.24') 'new Linux VM skips the retained SQLAO address'
Assert-True (-not ($script:Logs | Where-Object Failure)) 'safe retained address protection emits no failure'

$script:Logs.Clear()
$script:Reservations.Clear()
$script:ExistingVms = @([pscustomobject]@{
        vmName = 'VM-RERUN'
        role = 'DomainMember'
    })
$script:Adapters = @{
    'VM-RERUN' = @([pscustomobject]@{
            VMName = 'VM-RERUN'
            SwitchName = '192.168.50.0'
            MacAddress = '00155D000026'
            IPAddresses = @('192.168.50.26')
        })
}
$rerunConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{
        network = '192.168.50.0'
        domainName = 'cstest5.com'
    }
    virtualMachines = @([pscustomobject]@{
            vmName = 'VM-RERUN'
            role = 'DomainMember'
            network = '192.168.50.0'
            hidden = $false
        })
}
$rerunResult = Set-DeployConfigIPAddresses -DeployConfig $rerunConfig
$rerunVm = $rerunConfig.virtualMachines[0]

Assert-True $rerunResult 'existing-owner reuse returns success'
Assert-True ($rerunVm.AssignedIP -eq '192.168.50.26') 'existing non-hidden VM reuses its own live address'
Assert-True ([bool]($script:Reservations | Where-Object {
            "$($_.IPAddress)" -eq '192.168.50.26' -and
            $_.ClientId -eq '00155D000026'
        })) 'existing non-hidden VM live address becomes a durable reservation'
Assert-True (-not ($script:Logs | Where-Object Failure)) 'existing-owner reuse does not self-collide'

$script:Logs.Clear()
$script:Reservations.Clear()
$script:ExistingVms = @(
    [pscustomobject]@{ vmName = 'VM-A'; role = 'SQLAO' },
    [pscustomobject]@{ vmName = 'VM-B'; role = 'DomainMember' }
)
$script:Adapters = @{
    'VM-A' = @([pscustomobject]@{
            VMName = 'VM-A'
            SwitchName = '192.168.50.0'
            MacAddress = '00155D000001'
            IPAddresses = @('192.168.50.23')
        })
    'VM-B' = @([pscustomobject]@{
            VMName = 'VM-B'
            SwitchName = '192.168.50.0'
            MacAddress = '00155D000002'
            IPAddresses = @('192.168.50.23')
        })
}
$collisionConfig = New-TestConfig
$collisionResult = Set-DeployConfigIPAddresses -DeployConfig $collisionConfig
$collisionLinux = $collisionConfig.virtualMachines |
    Where-Object vmName -eq 'CT5-LINUXDESK1'

Assert-True (-not $collisionResult) 'existing live collision returns failure'
Assert-True (-not $collisionLinux.PSObject.Properties['AssignedIP']) 'existing live collision stops new allocation'
$collisionLog = $script:Logs | Where-Object {
    $_.Failure -and $_.Message -like '*LIVE IP COLLISION*'
} | Select-Object -First 1
Assert-True ([bool]($collisionLog -and
        $collisionLog.Message -like '*VM-A*' -and
        $collisionLog.Message -like '*VM-B*')) 'existing live collision is attributed to both owners'

$phaseSource = Get-Content -LiteralPath $phasesPath -Raw
Assert-True ($phaseSource -match
    '(?s)\$ipAllocationReady\s*=\s*Set-DeployConfigIPAddresses.+?if\s*\(-not\s+\$ipAllocationReady\).+?return\s+\$false') `
    'Phase 1 aborts before VM creation when IP ownership is unproven'

Write-Host 'PASS: live retained VM addresses are protected before DHCP allocation.'
