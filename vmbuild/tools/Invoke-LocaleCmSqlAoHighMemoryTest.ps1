<#
.SYNOPSIS
    Runs the ConfigMgr SQLAO locale matrix with 16 GB pinned SQL nodes.

.DESCRIPTION
    Derives a temporary configuration from the tracked high-memory test config.
    Five locale sets cover all 38 catalog locales across DC, BDC, file server,
    SQLAO, ConfigMgr primary, remote DP/MP, and Windows 11 client roles. SQLAO
    nodes remain pinned at 16 GB. A fresh run refuses existing target VMs and
    hosts with less than 120 GB RAM.
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
    [ValidateRange(1, 1440)]
    [int] $NoProgressMinutes = 45,
    [ValidateRange(1, 48)]
    [int] $MaxHours = 18,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'

function Get-MemLabsHighMemoryStorageInfo {
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $MinimumFreeGB = 105
    )

    $storagePath = [IO.Path]::GetFullPath($Path)
    $storageRoot = [IO.Path]::GetPathRoot($storagePath)
    if (-not $storageRoot -or -not (Test-Path -LiteralPath $storageRoot -PathType Container)) {
        throw "Configured VM storage drive is unavailable: $storageRoot"
    }
    $storageDrive = Get-PSDrive -Name $storageRoot.TrimEnd('\').TrimEnd(':') -PSProvider FileSystem -ErrorAction Stop
    $storageFreeBytes = [double]$storageDrive.Free
    $storageFreeGB = [math]::Round($storageFreeBytes / 1GB, 1)
    if ($storageFreeBytes -lt ($MinimumFreeGB * 1GB)) {
        throw "High-memory locale testing requires at least $MinimumFreeGB GB free on $storageRoot; only $storageFreeGB GB is available."
    }
    return [pscustomobject]@{ Path = $storagePath; Root = $storageRoot; FreeGB = $storageFreeGB }
}

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
if (-not $Configuration) {
    $Configuration = Join-Path $vmbuildRoot 'config\tests\Locale-CM-SqlAo-HighMemory.json'
}
$sourcePath = [IO.Path]::GetFullPath($Configuration)
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Configuration not found: $sourcePath"
}

$totalMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
if (-not $PlanOnly -and $totalMemoryGB -lt 120) {
    throw "This SQLAO isolation test requires a 128 GB-class host (at least 120 GB visible); this host has $totalMemoryGB GB."
}
if (-not $PlanOnly -and -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell is unavailable.'
}

$config = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -ErrorAction Stop
$storagePath = [IO.Path]::GetFullPath([string]$config.vmOptions.basePath)
$storageFreeGB = $null
if (-not $PlanOnly) {
    $storageInfo = Get-MemLabsHighMemoryStorageInfo -Path $storagePath
    $storageFreeGB = $storageInfo.FreeGB
}
$localeSets = @{
    1 = @{ DC1 = 'pl-PL'; BDC1 = 'zh-TW'; FS1 = 'pt-BR'; SQL1 = 'pt-PT'; SQL2 = 'sv-SE'; PS1SITE = 'tr-TR'; DPMP1 = 'zh-CN'; CL1 = 'ar-SA' }
    2 = @{ DC1 = 'bg-BG'; BDC1 = 'cs-CZ'; FS1 = 'da-DK'; SQL1 = 'de-DE'; SQL2 = 'el-GR'; PS1SITE = 'es-ES'; DPMP1 = 'es-MX'; CL1 = 'et-EE' }
    3 = @{ DC1 = 'fi-FI'; BDC1 = 'fr-CA'; FS1 = 'he-IL'; SQL1 = 'hr-HR'; SQL2 = 'hu-HU'; PS1SITE = 'it-IT'; DPMP1 = 'ja-JP'; CL1 = 'ko-KR' }
    4 = @{ DC1 = 'lt-LT'; BDC1 = 'lv-LV'; FS1 = 'nb-NO'; SQL1 = 'nl-NL'; SQL2 = 'ro-RO'; PS1SITE = 'ru-RU'; DPMP1 = 'sk-SK'; CL1 = 'sl-SI' }
    5 = @{ DC1 = 'sr-Latn-RS'; BDC1 = 'th-TH'; FS1 = 'uk-UA'; SQL1 = 'en-GB'; SQL2 = 'en-US'; PS1SITE = 'fr-FR'; DPMP1 = 'ar-SA'; CL1 = 'tr-TR' }
}
$assignments = $localeSets[$LocaleSet]
$identity = [pscustomobject]@{
    Prefix   = "LH$LocaleSet-"
    Domain   = "locale$LocaleSet.lab"
    NetBios  = "LOC$LocaleSet"
    Network  = "10.221.$(210 + $LocaleSet).0"
    SiteCode = "L0$LocaleSet"
}
$config.vmOptions.prefix = $identity.Prefix
$config.vmOptions.domainName = $identity.Domain
$config.vmOptions.domainNetBiosName = $identity.NetBios
$config.vmOptions.network = $identity.Network
$config.domainDefaults.DomainName = $identity.Domain
$config.domainDefaults.Network = $identity.Network
foreach ($vm in $config.virtualMachines) {
    if (-not $assignments.ContainsKey([string]$vm.vmName)) { throw "Locale set $LocaleSet has no assignment for '$($vm.vmName)'." }
    $vm.locale = [string]$assignments[[string]$vm.vmName]
    $vm.localeAcquisition = if ($vm.operatingSystem -like 'Windows 11*') { 'WindowsUpdate' } else { 'MicrosoftMedia' }
    if ($vm.PSObject.Properties.Name -contains 'localeSettings') { $vm.PSObject.Properties.Remove('localeSettings') }
    if ($vm.PSObject.Properties.Name -contains 'siteCode') { $vm.siteCode = $identity.SiteCode }
}
$primary = $config.virtualMachines | Where-Object role -eq 'Primary' | Select-Object -First 1
$primary.siteName = "Locale High Memory Set $LocaleSet"
$sqlOwner = $config.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode } | Select-Object -First 1
$sqlOwner.AlwaysOnGroupName = "$($identity.SiteCode) Availability Group"
$sqlOwner.AlwaysOnListenerName = "$($identity.SiteCode)SQL"
$sqlOwner.SqlServiceAccount = "$($identity.SiteCode)SqlSvc"
$sqlOwner.SqlAgentAccount = "$($identity.SiteCode)SqlAgent"
foreach ($sqlNode in $config.virtualMachines | Where-Object role -eq 'SQLAO') {
    $sqlNode.SqlServiceAccount = $sqlOwner.SqlServiceAccount
    $sqlNode.SqlAgentAccount = $sqlOwner.SqlAgentAccount
}

$catalogPath = Join-Path $vmbuildRoot 'common\LocaleCatalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
foreach ($vm in $config.virtualMachines) {
    if (-not $catalog.PSObject.Properties[[string]$vm.locale]) { throw "Locale '$($vm.locale)' is absent from LocaleCatalog.json." }
}
$sqlNodes = @($config.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })
if ($sqlNodes.Count -ne 2) {
    throw "Expected exactly two SQLAO nodes, found $($sqlNodes.Count)."
}
foreach ($sqlNode in $sqlNodes) {
    $sqlNode.memory = '16GB'
    $sqlNode.dynamicMinRam = '16GB'
}

$prefix = [string]$config.vmOptions.prefix
$targetNames = @($config.virtualMachines | Where-Object { -not $_.hidden } | ForEach-Object { "$prefix$($_.vmName)" })
$existingNames = @()
if (-not $PlanOnly) {
    $existingNames = @(Get-VM -Name $targetNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
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

$tempRoot = Join-Path $vmbuildRoot 'temp'
$generatedPath = Join-Path $tempRoot "Locale-CM-SqlAo-HighMemory-Set$LocaleSet.json"
if (-not $PlanOnly) {
    $null = New-Item -Path $tempRoot -ItemType Directory -Force
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $generatedPath -Encoding UTF8
}

$rendered = $config
if (-not $PlanOnly) { $rendered = Get-Content -LiteralPath $generatedPath -Raw | ConvertFrom-Json -ErrorAction Stop }
$invalidSqlNodes = @($rendered.virtualMachines | Where-Object {
        $_.role -eq 'SQLAO' -and ($_.memory -ne '16GB' -or $_.dynamicMinRam -ne '16GB')
    })
if ($invalidSqlNodes.Count -gt 0) {
    throw "Generated high-memory config did not preserve the 16 GB SQL floor: $($invalidSqlNodes.vmName -join ', ')."
}

Write-Host "High-memory locale SQLAO test"
Write-Host "  Host RAM     : $totalMemoryGB GB"
Write-Host "  VM storage   : $storagePath$(if ($null -ne $storageFreeGB) { " ($storageFreeGB GB free)" })"
Write-Host "  Locale set   : $LocaleSet"
Write-Host "  Identity     : $($identity.Prefix) / $($identity.Domain) / $($identity.Network)"
Write-Host "  SQL nodes    : $($sqlNodes.vmName -join ', ') (16 GB pinned each)"
Write-Host "  Assignments  : $(@($config.virtualMachines | ForEach-Object { "$($_.vmName)=$($_.locale)" }) -join ', ')"
Write-Host "  Configuration: $(if ($PlanOnly) { '<plan only>' } else { $generatedPath })"
Write-Host "  Start phase  : $(if ($StartPhase) { $StartPhase } else { 'fresh' })"
if ($PlanOnly) { return }

$runner = Join-Path $PSScriptRoot 'Invoke-MemLabsMonitoredDeployment.ps1'
$arguments = @{
    Configuration          = $generatedPath
    NoProgressMinutes      = $NoProgressMinutes
    PollSeconds            = 60
    MaxHours               = $MaxHours
    ExpectedCompletedPhase = 11
    KeepFailedVMs          = $true
}
if ($StartPhase -gt 0) { $arguments.StartPhase = $StartPhase }

& $runner @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
