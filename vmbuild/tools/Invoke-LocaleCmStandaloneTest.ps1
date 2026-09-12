<#
.SYNOPSIS
    Runs the non-SQLAO ConfigMgr locale matrix on a Windows Client host.

.DESCRIPTION
    Derives a temporary configuration from the tracked standalone locale test
    config. Five locale sets cover all 38 catalog locales across DC, BDC, file
    server, standalone SQL, member server, ConfigMgr primary, remote DP/MP, and
    Windows 11 client roles. The generated configuration rejects every SQLAO
    role and topology property before deployment.
#>
#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $Configuration,
    [ValidateRange(1, 5)]
    [int] $LocaleSet = 1,
    [ValidateRange(0, 11)]
    [int] $StartPhase = 0,
    [string] $VmStorageRoot = 'C:\VirtualMachines',
    [ValidateRange(1, 1440)]
    [int] $NoProgressMinutes = 45,
    [ValidateRange(1, 48)]
    [int] $MaxHours = 18,
    [switch] $PlanOnly,
    [Parameter(DontShow)]
    [string] $OutputDirectory,
    [Parameter(DontShow)]
    [string] $DeploymentRunner
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
if (-not $Configuration) {
    $Configuration = Join-Path $vmbuildRoot 'config\tests\Locale-CM-Standalone.json'
}
$sourcePath = [IO.Path]::GetFullPath($Configuration)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Configuration not found: $sourcePath"
}

$storagePath = [IO.Path]::GetFullPath($VmStorageRoot)
$storageRoot = [IO.Path]::GetPathRoot($storagePath)
if (-not $storageRoot) {
    throw "VM storage path has no drive root: $storagePath"
}

$totalMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
$storageFreeGB = $null
if (-not $PlanOnly) {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V PowerShell is unavailable.'
    }
    if (-not (Test-Path -LiteralPath $storageRoot -PathType Container)) {
        throw "Configured VM storage drive is unavailable: $storageRoot"
    }
    $hostOperatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($storageRoot -eq 'C:\' -and [int]$hostOperatingSystem.ProductType -ne 1) {
        throw 'C: VM storage is supported only when the Hyper-V host runs Windows Client.'
    }
    if ($totalMemoryGB -lt 56) {
        throw "The standalone locale matrix requires at least 56 GB host RAM; this host has $totalMemoryGB GB."
    }
    $storageDrive = Get-PSDrive -Name $storageRoot.TrimEnd('\').TrimEnd(':') -PSProvider FileSystem -ErrorAction Stop
    $storageFreeGB = [math]::Round([double]$storageDrive.Free / 1GB, 1)
}

$config = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -ErrorAction Stop
$expectedMatrix = [ordered]@{
    DC1     = [pscustomobject]@{ Role = 'DC'; OperatingSystem = 'Server 2025' }
    BDC1    = [pscustomobject]@{ Role = 'BDC'; OperatingSystem = 'Server 2022' }
    FS1     = [pscustomobject]@{ Role = 'FileServer'; OperatingSystem = 'Server 2022' }
    SQL1    = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Server 2022' }
    SRV1    = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Server 2022' }
    PS1SITE = [pscustomobject]@{ Role = 'Primary'; OperatingSystem = 'Server 2022' }
    DPMP1   = [pscustomobject]@{ Role = 'SiteSystem'; OperatingSystem = 'Server 2025' }
    CL1     = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Windows 11*' }
}
$configuredVms = @($config.virtualMachines | Where-Object { $null -ne $_ })
if ($configuredVms.Count -ne $expectedMatrix.Count) {
    throw "Standalone locale matrix requires exactly $($expectedMatrix.Count) VMs; found $($configuredVms.Count)."
}
foreach ($expectedVm in $expectedMatrix.GetEnumerator()) {
    $matrixMatches = @($configuredVms | Where-Object vmName -eq $expectedVm.Key)
    if ($matrixMatches.Count -ne 1) {
        throw "Standalone locale matrix requires exactly one '$($expectedVm.Key)' VM; found $($matrixMatches.Count)."
    }
    $vm = $matrixMatches[0]
    if ($vm.role -ne $expectedVm.Value.Role -or $vm.operatingSystem -notlike $expectedVm.Value.OperatingSystem -or $vm.hidden) {
        throw "Standalone locale matrix VM '$($expectedVm.Key)' must be one visible $($expectedVm.Value.Role) running $($expectedVm.Value.OperatingSystem)."
    }
}
$configuredMemoryBytes = (@($configuredVms | ForEach-Object { $_.memory / 1 }) | Measure-Object -Sum).Sum
if ($configuredMemoryBytes -ne 40GB) {
    throw "Standalone locale matrix requires exactly 40 GB configured VM memory; found $([math]::Round($configuredMemoryBytes / 1GB, 1)) GB."
}

$localeSets = @{
    1 = @{ DC1 = 'pl-PL'; BDC1 = 'zh-TW'; FS1 = 'pt-BR'; SQL1 = 'pt-PT'; SRV1 = 'sv-SE'; PS1SITE = 'tr-TR'; DPMP1 = 'zh-CN'; CL1 = 'ar-SA' }
    2 = @{ DC1 = 'bg-BG'; BDC1 = 'cs-CZ'; FS1 = 'da-DK'; SQL1 = 'de-DE'; SRV1 = 'el-GR'; PS1SITE = 'es-ES'; DPMP1 = 'es-MX'; CL1 = 'et-EE' }
    3 = @{ DC1 = 'fi-FI'; BDC1 = 'fr-CA'; FS1 = 'he-IL'; SQL1 = 'hr-HR'; SRV1 = 'hu-HU'; PS1SITE = 'it-IT'; DPMP1 = 'ja-JP'; CL1 = 'ko-KR' }
    4 = @{ DC1 = 'lt-LT'; BDC1 = 'lv-LV'; FS1 = 'nb-NO'; SQL1 = 'nl-NL'; SRV1 = 'ro-RO'; PS1SITE = 'ru-RU'; DPMP1 = 'sk-SK'; CL1 = 'sl-SI' }
    5 = @{ DC1 = 'sr-Latn-RS'; BDC1 = 'th-TH'; FS1 = 'uk-UA'; SQL1 = 'en-GB'; SRV1 = 'en-US'; PS1SITE = 'fr-FR'; DPMP1 = 'ar-SA'; CL1 = 'tr-TR' }
}
$assignments = $localeSets[$LocaleSet]
$identity = [pscustomobject]@{
    Prefix   = "LS$LocaleSet-"
    Domain   = "standalone$LocaleSet.lab"
    NetBios  = "LCS$LocaleSet"
    Network  = "10.221.$(220 + $LocaleSet).0"
    SiteCode = "S0$LocaleSet"
}

$config.vmOptions.prefix = $identity.Prefix
$config.vmOptions.basePath = $storagePath
$config.vmOptions.domainName = $identity.Domain
$config.vmOptions.domainNetBiosName = $identity.NetBios
$config.vmOptions.network = $identity.Network
$config.domainDefaults.DomainName = $identity.Domain
$config.domainDefaults.Network = $identity.Network
foreach ($vm in $config.virtualMachines) {
    if (-not $assignments.ContainsKey([string]$vm.vmName)) {
        throw "Locale set $LocaleSet has no assignment for '$($vm.vmName)'."
    }
    $vm.locale = [string]$assignments[[string]$vm.vmName]
    $vm.localeAcquisition = if ($vm.operatingSystem -like 'Windows 11*') { 'WindowsUpdate' } else { 'MicrosoftMedia' }
    if ($vm.PSObject.Properties.Name -contains 'localeSettings') {
        $vm.PSObject.Properties.Remove('localeSettings')
    }
    if ($vm.PSObject.Properties.Name -contains 'siteCode') {
        $vm.siteCode = $identity.SiteCode
    }
}
$primary = @($config.virtualMachines | Where-Object role -eq 'Primary')
if ($primary.Count -ne 1) {
    throw "Expected exactly one ConfigMgr primary, found $($primary.Count)."
}
$primary[0].siteName = "Standalone Locale Set $LocaleSet"

$forbiddenProperties = @(
    'OtherNode',
    'AlwaysOnName',
    'ClusterName',
    'ClusterIPAddress',
    'AGIPAddress',
    'fileServerVM',
    'AlwaysOnGroupName',
    'AlwaysOnListenerName',
    'SqlServiceAccount',
    'SqlAgentAccount'
)
$sqlAoRoles = @($config.virtualMachines | Where-Object role -eq 'SQLAO')
$sqlAoProperties = @(foreach ($vm in $config.virtualMachines) {
        foreach ($property in $forbiddenProperties) {
            if ($vm.PSObject.Properties.Name -contains $property) {
                "$($vm.vmName).$property"
            }
        }
    })
if ($sqlAoRoles.Count -gt 0 -or $sqlAoProperties.Count -gt 0) {
    $details = @($sqlAoRoles | ForEach-Object { "$($_.vmName).role=SQLAO" }) + $sqlAoProperties
    throw "Standalone locale testing refuses SQLAO topology: $($details -join ', ')."
}

$remoteSqlName = [string]$primary[0].remoteSQLVM
$remoteSql = @($config.virtualMachines | Where-Object vmName -eq $remoteSqlName)
if ($remoteSql.Count -ne 1 -or $remoteSql[0].role -ne 'DomainMember' -or -not $remoteSql[0].sqlVersion) {
    throw "Primary remoteSQLVM '$remoteSqlName' must resolve to one standalone SQL DomainMember."
}

$catalogPath = Join-Path $vmbuildRoot 'common\LocaleCatalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
foreach ($vm in $config.virtualMachines) {
    if (-not $catalog.PSObject.Properties[[string]$vm.locale]) {
        throw "Locale '$($vm.locale)' is absent from LocaleCatalog.json."
    }
}

$prefix = [string]$config.vmOptions.prefix
$targetNames = @($config.virtualMachines | Where-Object { -not $_.hidden } | ForEach-Object { "$prefix$($_.vmName)" })
$existingNames = @()
if (-not $PlanOnly) {
    $existingNames = @(Get-VM -Name $targetNames -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ } | Select-Object -ExpandProperty Name)
    if ($StartPhase -eq 0 -and $existingNames.Count -gt 0) {
        throw "Fresh test refused because target VM(s) already exist: $($existingNames -join ', '). Remove them intentionally or resume with -StartPhase."
    }
    if ($StartPhase -gt 0) {
        $missingNames = @($targetNames | Where-Object { $_ -notin $existingNames })
        if ($missingNames.Count -gt 0) {
            throw "Resume from Phase $StartPhase refused because target VM(s) are missing: $($missingNames -join ', ')."
        }
    }
}

$outputRoot = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $vmbuildRoot 'temp' }
$generatedPath = Join-Path $outputRoot "Locale-CM-Standalone-Set$LocaleSet.json"
if (-not $PlanOnly) {
    $null = New-Item -Path $outputRoot -ItemType Directory -Force
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $generatedPath -Encoding UTF8
}

Write-Host 'Standalone ConfigMgr locale test'
Write-Host "  Host RAM     : $totalMemoryGB GB"
Write-Host "  VM storage   : $storagePath$(if ($null -ne $storageFreeGB) { " ($storageFreeGB GB free)" })"
Write-Host "  Locale set   : $LocaleSet"
Write-Host "  Identity     : $($identity.Prefix) / $($identity.Domain) / $($identity.Network)"
Write-Host "  SQL topology : $remoteSqlName (standalone remote SQL)"
Write-Host "  Assignments  : $(@($config.virtualMachines | ForEach-Object { "$($_.vmName)=$($_.locale)" }) -join ', ')"
Write-Host "  Configuration: $(if ($PlanOnly) { '<plan only>' } else { $generatedPath })"
Write-Host "  Start phase  : $(if ($StartPhase) { $StartPhase } else { 'fresh' })"
if ($PlanOnly) { return }

$runner = if ($DeploymentRunner) { [IO.Path]::GetFullPath($DeploymentRunner) } else { Join-Path $PSScriptRoot 'Invoke-MemLabsMonitoredDeployment.ps1' }
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Deployment runner not found: $runner"
}
$arguments = @{
    Configuration          = $generatedPath
    NoProgressMinutes      = $NoProgressMinutes
    PollSeconds            = 60
    MaxHours               = $MaxHours
    ExpectedCompletedPhase = 11
    KeepFailedVMs          = $true
}
if ($StartPhase -gt 0) {
    $arguments.StartPhase = $StartPhase
}

& $runner @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }