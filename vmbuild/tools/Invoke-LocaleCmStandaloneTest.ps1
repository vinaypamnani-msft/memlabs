<#
.SYNOPSIS
    Runs the non-SQLAO ConfigMgr locale matrix on a Windows Client host.

.DESCRIPTION
    Derives memory-safe core and additions configurations from the tracked
    standalone locale test configs. Five locale sets cover all 38 catalog
    locales across DC, BDC, file server, standalone SQL, member server,
    ConfigMgr primary, remote DP/MP, and Windows 11 client roles. Generated
    configurations reject every SQLAO role and topology property.
#>
#requires -Version 7.4
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $Configuration,
    [string] $AdditionsConfiguration,
    [ValidateRange(1, 5)]
    [int] $LocaleSet = 1,
    [ValidateSet('All', 'Core', 'Additions')]
    [string] $Stage = 'All',
    [ValidateRange(0, 11)]
    [int] $StartPhase = 0,
    [string] $VmStorageRoot = 'C:\VirtualMachines',
    [ValidateRange(1, 1440)]
    [int] $NoProgressMinutes = 45,
    [ValidateRange(1, 48)]
    [int] $MaxHours = 18,
    [ValidateRange(1, 120)]
    [int] $StageHandoffMinutes = 30,
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
if (-not $AdditionsConfiguration) {
    $AdditionsConfiguration = Join-Path $vmbuildRoot 'config\tests\Locale-CM-Standalone-Additions.json'
}
$coreSourcePath = [IO.Path]::GetFullPath($Configuration)
$additionsSourcePath = [IO.Path]::GetFullPath($AdditionsConfiguration)
foreach ($configurationPath in @($coreSourcePath, $additionsSourcePath)) {
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        throw "Configuration not found: $configurationPath"
    }
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

if ($Stage -eq 'All' -and $StartPhase -gt 0) {
    throw 'Select -Stage Core or -Stage Additions when resuming with -StartPhase.'
}

$coreConfig = Get-Content -LiteralPath $coreSourcePath -Raw | ConvertFrom-Json -ErrorAction Stop
$additionsConfig = Get-Content -LiteralPath $additionsSourcePath -Raw | ConvertFrom-Json -ErrorAction Stop
$expectedCore = [ordered]@{
    DC1     = [pscustomobject]@{ Role = 'DC'; OperatingSystem = 'Server 2025' }
    SQL1    = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Server 2022' }
    PS1SITE = [pscustomobject]@{ Role = 'Primary'; OperatingSystem = 'Server 2022' }
}
$expectedAdditions = [ordered]@{
    BDC1    = [pscustomobject]@{ Role = 'BDC'; OperatingSystem = 'Server 2022' }
    FS1     = [pscustomobject]@{ Role = 'FileServer'; OperatingSystem = 'Server 2022' }
    SRV1    = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Server 2022' }
    DPMP1   = [pscustomobject]@{ Role = 'SiteSystem'; OperatingSystem = 'Server 2025' }
    CL1     = [pscustomobject]@{ Role = 'DomainMember'; OperatingSystem = 'Windows 11*' }
}
$stageDefinitions = @(
    [pscustomobject]@{ Name = 'Core'; Config = $coreConfig; Expected = $expectedCore; MemoryBytes = 22GB }
    [pscustomobject]@{ Name = 'Additions'; Config = $additionsConfig; Expected = $expectedAdditions; MemoryBytes = 15GB }
)
foreach ($stageDefinition in $stageDefinitions) {
    $configuredVms = @($stageDefinition.Config.virtualMachines | Where-Object { $null -ne $_ })
    if ($configuredVms.Count -ne $stageDefinition.Expected.Count) {
        throw "$($stageDefinition.Name) locale stage requires exactly $($stageDefinition.Expected.Count) VMs; found $($configuredVms.Count)."
    }
    foreach ($expectedVm in $stageDefinition.Expected.GetEnumerator()) {
        $matrixMatches = @($configuredVms | Where-Object vmName -eq $expectedVm.Key)
        if ($matrixMatches.Count -ne 1) {
            throw "$($stageDefinition.Name) locale stage requires exactly one '$($expectedVm.Key)' VM; found $($matrixMatches.Count)."
        }
        $vm = $matrixMatches[0]
        if ($vm.role -ne $expectedVm.Value.Role -or $vm.operatingSystem -notlike $expectedVm.Value.OperatingSystem -or $vm.hidden) {
            throw "$($stageDefinition.Name) locale stage VM '$($expectedVm.Key)' must be one visible $($expectedVm.Value.Role) running $($expectedVm.Value.OperatingSystem)."
        }
    }
    $configuredMemoryBytes = (@($configuredVms | ForEach-Object { $_.memory / 1 }) | Measure-Object -Sum).Sum
    if ($configuredMemoryBytes -ne $stageDefinition.MemoryBytes) {
        throw "$($stageDefinition.Name) locale stage requires exactly $($stageDefinition.MemoryBytes / 1GB) GB configured VM memory; found $([math]::Round($configuredMemoryBytes / 1GB, 1)) GB."
    }
}
$allVms = @($coreConfig.virtualMachines) + @($additionsConfig.virtualMachines)
$allVmNames = @($allVms | ForEach-Object { [string]$_.vmName })
if (@($allVmNames | Sort-Object -Unique).Count -ne 8) {
    throw 'Core and additions locale stages must define eight unique VM names.'
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

foreach ($stageConfig in @($coreConfig, $additionsConfig)) {
    $stageConfig.vmOptions.prefix = $identity.Prefix
    $stageConfig.vmOptions.basePath = $storagePath
    $stageConfig.vmOptions.domainName = $identity.Domain
    $stageConfig.vmOptions.domainNetBiosName = $identity.NetBios
    $stageConfig.vmOptions.network = $identity.Network
    $stageConfig.domainDefaults.DomainName = $identity.Domain
    $stageConfig.domainDefaults.Network = $identity.Network
    foreach ($vm in $stageConfig.virtualMachines) {
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
}
$primary = @($coreConfig.virtualMachines | Where-Object role -eq 'Primary')
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
$sqlAoRoles = @($allVms | Where-Object role -eq 'SQLAO')
$sqlAoProperties = @(foreach ($vm in $allVms) {
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
$remoteSql = @($coreConfig.virtualMachines | Where-Object vmName -eq $remoteSqlName)
if ($remoteSql.Count -ne 1 -or $remoteSql[0].role -ne 'DomainMember' -or -not $remoteSql[0].sqlVersion) {
    throw "Primary remoteSQLVM '$remoteSqlName' must resolve to one standalone SQL DomainMember."
}

$catalogPath = Join-Path $vmbuildRoot 'common\LocaleCatalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
foreach ($vm in $allVms) {
    if (-not $catalog.PSObject.Properties[[string]$vm.locale]) {
        throw "Locale '$($vm.locale)' is absent from LocaleCatalog.json."
    }
}

$prefix = [string]$coreConfig.vmOptions.prefix
$coreTargetNames = @($coreConfig.virtualMachines | ForEach-Object { "$prefix$($_.vmName)" })
$additionsTargetNames = @($additionsConfig.virtualMachines | ForEach-Object { "$prefix$($_.vmName)" })
if (-not $PlanOnly) {
    $existingNames = @(Get-VM -Name @($coreTargetNames + $additionsTargetNames) -ErrorAction SilentlyContinue | Where-Object { $null -ne $_ } | Select-Object -ExpandProperty Name)
    $selectedTargets = if ($Stage -eq 'Core') { $coreTargetNames } elseif ($Stage -eq 'Additions') { $additionsTargetNames } else { @($coreTargetNames + $additionsTargetNames) }
    if ($Stage -eq 'Additions') {
        $missingCore = @($coreTargetNames | Where-Object { $_ -notin $existingNames })
        if ($missingCore.Count -gt 0) {
            throw "Additions stage requires completed core VM(s): $($missingCore -join ', ')."
        }
    }
    if ($StartPhase -eq 0) {
        $existingTargets = @($selectedTargets | Where-Object { $_ -in $existingNames })
        if ($existingTargets.Count -gt 0) {
            throw "Fresh $Stage stage refused because target VM(s) already exist: $($existingTargets -join ', '). Remove them intentionally or resume the selected stage with -StartPhase."
        }
    }
    else {
        $missingNames = @($selectedTargets | Where-Object { $_ -notin $existingNames })
        if ($missingNames.Count -gt 0) {
            throw "$Stage stage resume from Phase $StartPhase refused because target VM(s) are missing: $($missingNames -join ', ')."
        }
    }
}

$outputRoot = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $vmbuildRoot 'temp' }
$coreGeneratedPath = Join-Path $outputRoot "Locale-CM-Standalone-Core-Set$LocaleSet.json"
$additionsGeneratedPath = Join-Path $outputRoot "Locale-CM-Standalone-Additions-Set$LocaleSet.json"
if (-not $PlanOnly) {
    $null = New-Item -Path $outputRoot -ItemType Directory -Force
    $coreConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $coreGeneratedPath -Encoding UTF8
    $additionsConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $additionsGeneratedPath -Encoding UTF8
}

Write-Host 'Standalone ConfigMgr locale test'
Write-Host "  Host RAM     : $totalMemoryGB GB"
Write-Host "  VM storage   : $storagePath$(if ($null -ne $storageFreeGB) { " ($storageFreeGB GB free)" })"
Write-Host "  Locale set   : $LocaleSet"
Write-Host "  Stage        : $Stage"
Write-Host "  Identity     : $($identity.Prefix) / $($identity.Domain) / $($identity.Network)"
Write-Host "  SQL topology : $remoteSqlName (standalone remote SQL)"
Write-Host '  Memory stages: Core=22 GB, Additions=15 GB'
Write-Host "  Assignments  : $(@($allVms | ForEach-Object { "$($_.vmName)=$($_.locale)" }) -join ', ')"
Write-Host "  Core config  : $(if ($PlanOnly) { '<plan only>' } else { $coreGeneratedPath })"
Write-Host "  Additions    : $(if ($PlanOnly) { '<plan only>' } else { $additionsGeneratedPath })"
Write-Host "  Start phase  : $(if ($StartPhase) { $StartPhase } else { 'fresh' })"
if ($PlanOnly) { return }

$runner = if ($DeploymentRunner) { [IO.Path]::GetFullPath($DeploymentRunner) } else { Join-Path $PSScriptRoot 'Invoke-MemLabsMonitoredDeployment.ps1' }
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Deployment runner not found: $runner"
}
function Invoke-LocaleStage {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Path, [int] $ResumePhase)

    Write-Host "Starting $Name locale stage: $Path"
    $arguments = @{
        Configuration          = $Path
        NoProgressMinutes      = $NoProgressMinutes
        PollSeconds            = 60
        MaxHours               = $MaxHours
        ExpectedCompletedPhase = 11
        KeepFailedVMs          = $true
    }
    if ($ResumePhase -gt 0) { $arguments.StartPhase = $ResumePhase }
    & $runner @arguments
}

function Wait-LocaleStageCapacity {
    param([double] $RequiredAvailableGB, [int] $TimeoutMinutes)

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $requiredAvailableBytes = [int64]($RequiredAvailableGB * 1GB)
    $qualifyingSamples = 0
    do {
        $remainingSeconds = [math]::Floor(($deadline - (Get-Date)).TotalSeconds)
        if ($remainingSeconds -le 0) { break }
        $probeTimeoutSeconds = [int][math]::Min(15, $remainingSeconds)
        $probeJob = Start-ThreadJob -ScriptBlock {
            try { return [double]((Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue * 1MB) }
            catch { return [double]((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1KB) }
        }
        $availableBytes = $null
        try {
            if (Wait-Job -Job $probeJob -Timeout $probeTimeoutSeconds) {
                $probeOutput = @(Receive-Job -Job $probeJob -ErrorAction Stop)
                if ($probeOutput.Count -ne 1 -or [double]$probeOutput[0] -le 0) {
                    throw "Memory availability probe returned $($probeOutput.Count) unusable result(s)."
                }
                $availableBytes = [double]$probeOutput[0]
            }
        }
        finally {
            Stop-Job -Job $probeJob -ErrorAction SilentlyContinue
            Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue
        }
        if ((Get-Date) -gt $deadline) { break }
        if ($null -eq $availableBytes) {
            $qualifyingSamples = 0
            Write-Host "Stage handoff memory: probe did not complete within $probeTimeoutSeconds second(s); qualifying sample 0 of 3."
        }
        else {
            $rawAvailableGB = [math]::Round($availableBytes / 1GB, 2)
            if ($availableBytes -ge $requiredAvailableBytes) { $qualifyingSamples++ } else { $qualifyingSamples = 0 }
            Write-Host "Stage handoff memory: $rawAvailableGB GB raw available; $RequiredAvailableGB GB required; qualifying sample $qualifyingSamples of 3."
        }
        if ($qualifyingSamples -ge 3) { return }
        $sleepSeconds = [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($sleepSeconds -gt 0) { Start-Sleep -Seconds ([int][math]::Min(30, $sleepSeconds)) }
    } while ((Get-Date) -lt $deadline)
    throw "Additions stage cannot start: raw available memory remained below $RequiredAvailableGB GB for $TimeoutMinutes minute(s)."
}

switch ($Stage) {
    'Core' { Invoke-LocaleStage -Name Core -Path $coreGeneratedPath -ResumePhase $StartPhase }
    'Additions' {
        Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes $StageHandoffMinutes
        Invoke-LocaleStage -Name Additions -Path $additionsGeneratedPath -ResumePhase $StartPhase
    }
    'All' {
        Invoke-LocaleStage -Name Core -Path $coreGeneratedPath
        Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes $StageHandoffMinutes
        Invoke-LocaleStage -Name Additions -Path $additionsGeneratedPath
    }
}