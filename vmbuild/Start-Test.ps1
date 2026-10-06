<#
.SYNOPSIS
    Runs MemLabs deployment test fixtures.

.EXAMPLE
    .\Start-Test.ps1 -All

    Runs the curated Core suite. Use -Suite Full for every ordinary test family.

.EXAMPLE
    .\Start-Test.ps1 -Suite Upgrade -CrossRevisionPlanOnly

    Prints the curated exact-main to develop upgrade matrix without touching Hyper-V.

.EXAMPLE
    .\Start-Test.ps1 -Continuous

    Continuously selects the highest-value test that fits current host memory.
    Runs only while this foreground Start-Test process remains open.

.EXAMPLE
    .\Start-Test.ps1 -Continuous -ContinuousPlanOnly

    Displays the ranked candidates and exits without touching Hyper-V.

.EXAMPLE
    .\Start-Test.ps1 -All -MainToDevelopExpansion -CrossRevisionPlanOnly

    Prints the Core suite's pinned main-to-develop expansion matrix without touching Hyper-V.

.EXAMPLE
    .\Start-Test.ps1 -Test NOCM -MainToDevelopExpansion

    Deploys NOCM-A once with pinned main, then runs develop's NOCM B+ fixtures
    twice before validating and removing the family.

.EXAMPLE
    .\Start-Test.ps1 -All -MainToDevelopExpansion

    Runs every family that has an A fixture in pinned main and B+ fixtures in
    pinned develop. Completed stages are checkpointed under
    ProgramData\MemLabs\CrossRevision. If exact-main A is interrupted, remove
    that family lab and reset its state; the runner will not replay or adopt an
    uncheckpointed baseline.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Prefix of tests to perform", ParameterSetName = 'TestName')]
    [ArgumentCompleter( {
            param ( $CommandName,
                $ParameterName,
                $WordToComplete,
                $CommandAst,
                $FakeBoundParameters
            )

            $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name }
            $Tests = @()
            foreach ($name  in $ConfigPaths.Name) {
             
                $Testname = ($name -split "-")[0]
                if ($Testname.contains("json")) {
                    continue
                }
                if ($Testname.Contains("storageconfig")) {
                    continue
                }
                $Tests += $Testname
            }                        
            $Tests = $Tests | Select-Object -Unique


            if ($WordToComplete) {                
                $Tests = $Tests | Where-Object { $_.ToLowerInvariant().StartsWith($WordToComplete.ToLowerInvariant()) 
                } }
            return [string[]] $Tests
        })]   
    [string]$Test,

    [Parameter(Mandatory = $true, HelpMessage = "Prefix of tests to perform", ParameterSetName = 'ALL')]
    [switch]$All,

    [Parameter(Mandatory = $true, HelpMessage = "Curated test suite", ParameterSetName = 'Suite')]
    [ValidateSet('Core', 'Upgrade', 'Specialized', 'Stress', 'Full')]
    [string]$Suite,

    [Parameter(Mandatory = $true, HelpMessage = "Continuously run the highest-value test that fits the host", ParameterSetName = 'Continuous')]
    [switch]$Continuous,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [switch]$ContinuousPlanOnly,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [int]$ContinuousMaxIterations = 0,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [double]$MinimumRetentionFreeGB = 250,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [int]$MaximumRetainedLabs = 2,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [int]$RetentionDays = 7,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [string]$TestHistoryPath,

    [Parameter(Mandatory = $false, ParameterSetName = 'Continuous')]
    [string]$TestRetentionPath,

    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'Suite')]
    [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            # Fast path: read CM versions from cache file instead of loading Common.ps1
            $versions = @()
            if ($global:Common.Supported.CMVersions) {
                $versions = @($global:Common.Supported.CMVersions)
            }
            else {
                $cacheFile = Join-Path $PSScriptRoot "cache\supported-options.json"
                if (Test-Path $cacheFile) {
                    try {
                        $cached = Get-Content $cacheFile -ErrorAction SilentlyContinue | ConvertFrom-Json
                        if ($cached.Supported.CMVersions) { $versions = @($cached.Supported.CMVersions) }
                    } catch {}
                }
            }
            $versions = $versions | Sort-Object -Descending
            return $versions | Where-Object { $_ -like "$WordToComplete*" }
        })]        
    [string]$cmVersion,

    [Parameter(Mandatory = $false, HelpMessage = "Override Dynamic Memory", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Dynamic Memory", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Dynamic Memory", ParameterSetName = 'Suite')]
    [switch]$dynamicMemory,

    [Parameter(Mandatory = $false, HelpMessage = "Override Install CM", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Install CM", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Install CM", ParameterSetName = 'Suite')]
    [switch]$DoNotInstallCM,

    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'Suite')]
    [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            # Not -InJob: the completer needs Get-SupportedOperatingSystemsForRole, which
            # Common.ps1 only loads outside a job.
            . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false -StartupProfile Fast
            $argument = @(Get-SupportedOperatingSystemsForRole "DC")
            $newArgument = @()
            foreach ($arg in $argument) {
                if ($arg -like "* *") {
                    $newArgument += "'$arg'"
                }
                else {
                    $newArgument += $arg
                }
            }
            $WordToComplete = $WordToComplete -replace '''',''
            return $newArgument | Where-Object { $_ -match $WordToComplete }
        })]        
    [string]$serverVersion,

    [Parameter(Mandatory = $false, HelpMessage = "Enable BitLocker Management (BLM) on the site + a BitLocker client", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Enable BitLocker Management (BLM) on the site + a BitLocker client", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Enable BitLocker Management (BLM) on the site + a BitLocker client", ParameterSetName = 'Suite')]
    [switch]$EnableBLM,

    [Parameter(Mandatory = $false, HelpMessage = "Add a Proxy server and route Windows clients through it", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Add a Proxy server and route Windows clients through it", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Add a Proxy server and route Windows clients through it", ParameterSetName = 'Suite')]
    [switch]$EnableProxy,

    [Parameter(Mandatory = $false, HelpMessage = "Two-tier PKI: issuing CA on the DC + offline standalone root CA", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Two-tier PKI: issuing CA on the DC + offline standalone root CA", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Two-tier PKI: issuing CA on the DC + offline standalone root CA", ParameterSetName = 'Suite')]
    [switch]$TwoTierPKI,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy Microsoft 365 Apps (Office) to Windows clients", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Deploy Microsoft 365 Apps (Office) to Windows clients", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Deploy Microsoft 365 Apps (Office) to Windows clients", ParameterSetName = 'Suite')]
    [switch]$Office,

    [Parameter(Mandatory = $false, HelpMessage = "Enable BLM + Proxy + Two-tier PKI + Office together", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Enable BLM + Proxy + Two-tier PKI + Office together", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Enable BLM + Proxy + Two-tier PKI + Office together", ParameterSetName = 'Suite')]
    [switch]$TheWorks,

    [Parameter(Mandatory = $true, HelpMessage = "Run only the main-to-develop VM-note compatibility tests", ParameterSetName = 'VMNoteCompatibility')]
    [switch]$VMNoteCompatibilityOnly,

    [Parameter(Mandatory = $false, HelpMessage = "Skip the main-to-develop VM-note compatibility preflight", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Skip the main-to-develop VM-note compatibility preflight", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Skip the main-to-develop VM-note compatibility preflight", ParameterSetName = 'Suite')]
    [switch]$SkipVMNoteCompatibility,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy each A fixture with pinned main, then its B+ fixtures twice with pinned develop", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Deploy each A fixture with pinned main, then its B+ fixtures twice with pinned develop", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Deploy each A fixture with pinned main, then its B+ fixtures twice with pinned develop", ParameterSetName = 'Suite')]
    [switch]$MainToDevelopExpansion,

    [Parameter(Mandatory = $false, HelpMessage = "Print the mixed-revision expansion plan without changing worktrees or Hyper-V", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Print the mixed-revision expansion plan without changing worktrees or Hyper-V", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Print the mixed-revision expansion plan without changing worktrees or Hyper-V", ParameterSetName = 'Suite')]
    [switch]$CrossRevisionPlanOnly,

    [Parameter(Mandatory = $false, HelpMessage = "Reset the in-progress family checkpoint after deliberately removing its lab", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Reset the selected family checkpoint after deliberately removing its lab", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Reset the in-progress family checkpoint after deliberately removing its lab", ParameterSetName = 'Suite')]
    [switch]$ResetCrossRevisionState,

    [Parameter(Mandatory = $false, ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, ParameterSetName = 'Suite')]
    [string]$CrossRevisionStateRoot,

    [Parameter(Mandatory = $false, ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, ParameterSetName = 'Suite')]
    [string]$DevelopRevision,

    [Parameter(Mandatory = $false, HelpMessage = "Require every deployment to use clean/current source with machine-readable provenance", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Require every deployment to use clean/current source with machine-readable provenance", ParameterSetName = 'TestName')]
    [Parameter(Mandatory = $false, HelpMessage = "Require every deployment to use clean/current source with machine-readable provenance", ParameterSetName = 'Suite')]
    [switch]$RequireCleanSource,

    [Parameter(Mandatory = $false, HelpMessage = "Do not prompt after a failed fixture; return failure to the caller", ParameterSetName = 'TestName')]
    [switch]$Automated,

    [Parameter(Mandatory = $false, HelpMessage = "Remove successful test domains before returning", ParameterSetName = 'TestName')]
    [switch]$CleanupOnSuccess,

    [string]$MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf'
)

. (Join-Path $PSScriptRoot 'tools\Common.TestSuites.ps1')
. (Join-Path $PSScriptRoot 'tools\Common.TestHistory.ps1')
. (Join-Path $PSScriptRoot 'tools\Common.AttachedProcess.ps1')
$script:StartTestVmbuildRoot = $PSScriptRoot
$resolvedTestSuite = $null
if ($Suite) {
    $resolvedTestSuite = Resolve-MemLabsTestSuite -VmbuildRoot $PSScriptRoot -Name $Suite
}
elseif ($All.IsPresent) {
    $resolvedTestSuite = Resolve-MemLabsTestSuite -VmbuildRoot $PSScriptRoot -Name 'Core'
}
$runCrossRevision = $MainToDevelopExpansion.IsPresent -or
    ($resolvedTestSuite -and $resolvedTestSuite.Mode -eq 'CrossRevision')

if ($Continuous.IsPresent) {
    $continuousPath = Join-Path $PSScriptRoot 'tools\Invoke-MemLabsContinuousTests.ps1'
    $continuousArguments = @(
        '-NoLogo', '-NoProfile', '-File', $continuousPath,
        '-VmbuildRoot', $PSScriptRoot,
        '-MaxIterations', $ContinuousMaxIterations,
        '-MinimumFreeStorageGB', $MinimumRetentionFreeGB,
        '-MaximumRetainedLabs', $MaximumRetainedLabs,
        '-RetentionDays', $RetentionDays
    )
    if ($ContinuousPlanOnly.IsPresent) { $continuousArguments += '-PlanOnly' }
    if ($TestHistoryPath) { $continuousArguments += @('-HistoryPath', $TestHistoryPath) }
    if ($TestRetentionPath) { $continuousArguments += @('-RetentionPath', $TestRetentionPath) }
    do {
        $continuousExit = Invoke-MemLabsAttachedPowerShell -Arguments $continuousArguments
        if ($continuousExit -eq 57) {
            Write-Host 'Reloading the continuous scheduler after a source update.' -ForegroundColor Yellow
        }
    } while ($continuousExit -eq 57)
    exit $continuousExit
}


# ============================================================
# Feature override helpers (-EnableBLM / -EnableProxy / -TwoTierPKI / -Office / -TheWorks)
# Each mutates the in-memory config (PSCustomObject from ConvertFrom-Json) BEFORE it is
# written to c:\temp and handed to New-Lab.ps1, so any selected test can opt into these
# features without maintaining a separate config file.
# ============================================================
function Get-UniqueVmName {
    param([object]$Config, [string]$Base)
    $existing = @($Config.virtualMachines | ForEach-Object { $_.vmName })
    if ($existing -notcontains $Base) { return $Base }
    for ($i = 2; $i -le 99; $i++) {
        $candidate = "$Base$i"
        if ($existing -notcontains $candidate) { return $candidate }
    }
    return "$Base$(Get-Random -Minimum 100 -Maximum 999)"
}

function Get-CmOptionTargets {
    # cmOptions can live at the root (test configs) and/or on the top-level CAS/Primary
    # site-server VM (post-migration). Return every cmOptions object so toggles apply to both.
    param([object]$Config)
    $targets = @()
    if ($Config.cmOptions) { $targets += $Config.cmOptions }
    foreach ($vm in $Config.virtualMachines) {
        if ($vm.cmOptions -and ($vm.role -eq 'CAS' -or $vm.role -eq 'Primary') -and -not $vm.parentSiteCode) {
            $targets += $vm.cmOptions
        }
    }
    return @($targets)
}

function Set-CmOption {
    param([object]$Config, [string]$Name, $Value)
    $targets = Get-CmOptionTargets -Config $Config
    foreach ($t in $targets) { $t | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
    return ($targets.Count -gt 0)
}

function Resolve-ServerOS {
    # Reuse a known-valid server OS string already present in the config so validation passes.
    param([object]$Config)
    if ($Config.domainDefaults.DefaultServerOS) { return $Config.domainDefaults.DefaultServerOS }
    $dc = $Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
    if ($dc -and $dc.operatingSystem) { return $dc.operatingSystem }
    return "Server 2022"
}

function Resolve-Win11OS {
    param([object]$Config)
    if ($Config.domainDefaults.DefaultClientOS -and $Config.domainDefaults.DefaultClientOS -like 'Windows 11*') {
        return $Config.domainDefaults.DefaultClientOS
    }
    $existing = $Config.virtualMachines | Where-Object { $_.operatingSystem -like 'Windows 11*' } | Select-Object -First 1
    if ($existing) { return $existing.operatingSystem }
    return "Windows 11 Latest"
}

function Get-WindowsClient {
    param([object]$Config)
    return @($Config.virtualMachines | Where-Object { $_.role -eq 'DomainMember' -and ($_.operatingSystem -like 'Windows*') })
}

function Add-DomainMemberClient {
    # Append a new Gen2 Windows 11 DomainMember client and return it.
    param([object]$Config, [string]$BaseName = 'TESTCLI')
    $name = Get-UniqueVmName -Config $Config -Base $BaseName
    $os = Resolve-Win11OS -Config $Config
    $vm = [PSCustomObject][ordered]@{
        vmName          = $name
        role            = 'DomainMember'
        operatingSystem = $os
        memory          = '4GB'
        virtualProcs    = 2
        tpmEnabled      = $true
        vmGeneration    = '2'
    }
    $Config.virtualMachines = @($Config.virtualMachines) + $vm
    Write-Host "    [+] Added DomainMember client '$name' ($os)" -ForegroundColor DarkCyan
    return $vm
}

function Enable-TwoTierPKI {
    param([object]$Config)
    $dc = $Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
    if (-not $dc) {
        Write-Host "  [PKI] No DC in config - cannot enable PKI; skipping" -ForegroundColor Yellow
        return
    }
    # Offline Root CA host (StandaloneRootCA, workgroup)
    $root = $Config.virtualMachines | Where-Object { $_.role -eq 'StandaloneRootCA' } | Select-Object -First 1
    if (-not $root) {
        $rootName = Get-UniqueVmName -Config $Config -Base 'ROOTCA'
        $root = [PSCustomObject][ordered]@{
            vmName          = $rootName
            role            = 'StandaloneRootCA'
            operatingSystem = (Resolve-ServerOS -Config $Config)
            memory          = '2GB'
            virtualProcs    = 2
        }
        $Config.virtualMachines = @($Config.virtualMachines) + $root
        Write-Host "    [+] Added StandaloneRootCA VM '$rootName'" -ForegroundColor DarkCyan
    }
    $pki = [PSCustomObject][ordered]@{
        EnablePKI       = $true
        IssuingCAVM     = $dc.vmName
        UseOfflineRoot  = $true
        OfflineRootCAVM = $root.vmName
    }
    $Config | Add-Member -NotePropertyName 'pkiOptions' -NotePropertyValue $pki -Force
    $dc | Add-Member -NotePropertyName 'InstallCA'      -NotePropertyValue $true -Force
    $dc | Add-Member -NotePropertyName 'UseOfflineRoot' -NotePropertyValue $true -Force
    [void](Set-CmOption -Config $Config -Name 'UsePKI' -Value $true)
    Write-Host "  [PKI] Two-tier PKI: IssuingCA=$($dc.vmName), OfflineRoot=$($root.vmName); cmOptions.UsePKI=true" -ForegroundColor Green
}

function Enable-BLM {
    param([object]$Config)
    if (-not (Set-CmOption -Config $Config -Name 'EnableBLM' -Value $true)) {
        Write-Host "  [BLM] No cmOptions (no ConfigMgr) in this config - skipping BLM" -ForegroundColor Yellow
        return
    }
    # Client BitLocker needs Gen2 + TPM => target Windows 11 clients only.
    $win11 = @(Get-WindowsClient -Config $Config | Where-Object { $_.operatingSystem -like 'Windows 11*' })
    if ($win11.Count -eq 0) {
        $win11 = @(Add-DomainMemberClient -Config $Config -BaseName 'BLMCLI')
    }
    foreach ($vm in $win11) {
        $vm | Add-Member -NotePropertyName 'tpmEnabled'   -NotePropertyValue $true -Force
        $vm | Add-Member -NotePropertyName 'vmGeneration' -NotePropertyValue '2'   -Force
        $vm | Add-Member -NotePropertyName 'BitLocker'    -NotePropertyValue $true -Force
    }
    Write-Host "  [BLM] cmOptions.EnableBLM=true; BitLocker on: $(@($win11 | ForEach-Object { $_.vmName }) -join ', ')" -ForegroundColor Green
}

function Enable-Proxy {
    param([object]$Config)
    $proxy = $Config.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    if (-not $proxy) {
        $proxyName = Get-UniqueVmName -Config $Config -Base 'PROXY'
        $proxy = [PSCustomObject][ordered]@{
            vmName          = $proxyName
            role            = 'Proxy'
            operatingSystem = 'Ubuntu Server 24.04 LTS'
            osFamily        = 'Linux'
            memory          = '1GB'
            virtualProcs    = 1
        }
        $Config.virtualMachines = @($Config.virtualMachines) + $proxy
        Write-Host "    [+] Added Proxy VM '$proxyName' (Ubuntu Server 24.04 LTS)" -ForegroundColor DarkCyan
    }
    $clients = @(Get-WindowsClient -Config $Config)
    if ($clients.Count -eq 0) {
        $clients = @(Add-DomainMemberClient -Config $Config -BaseName 'PROXYCLI')
    }
    foreach ($vm in $clients) { $vm | Add-Member -NotePropertyName 'useProxy' -NotePropertyValue $true -Force }
    Write-Host "  [Proxy] Proxy=$($proxy.vmName); useProxy=true on: $(@($clients | ForEach-Object { $_.vmName }) -join ', ')" -ForegroundColor Green
}

function Enable-Office {
    param([object]$Config)
    # installOffice validation requires PrePopulateObjects enabled.
    if (-not (Set-CmOption -Config $Config -Name 'PrePopulateObjects' -Value $true)) {
        Write-Host "  [Office] No cmOptions (no ConfigMgr) in this config - skipping Office" -ForegroundColor Yellow
        return
    }
    $clients = @(Get-WindowsClient -Config $Config)
    if ($clients.Count -eq 0) {
        $clients = @(Add-DomainMemberClient -Config $Config -BaseName 'OFFCLI')
    }
    # Office deploys via SCCM, so each target needs the client agent pushed to it.
    # Set pushClient=$true per-VM (Get-UserConfiguration resolves it to a real site
    # code) so validation doesn't strip installOffice -- required when the config's
    # cmOptions.pushClientToDomainMembers is false (e.g. legacy CSTest configs).
    foreach ($vm in $clients) {
        $vm | Add-Member -NotePropertyName 'installOffice' -NotePropertyValue 'Current' -Force
        $vm | Add-Member -NotePropertyName 'pushClient'    -NotePropertyValue $true     -Force
    }
    Write-Host "  [Office] cmOptions.PrePopulateObjects=true; installOffice=Current + pushClient=true on: $(@($clients | ForEach-Object { $_.vmName }) -join ', ')" -ForegroundColor Green
}

function Set-FeatureOverrides {
    # Apply the -EnableBLM / -EnableProxy / -TwoTierPKI / -Office / -TheWorks switches to a config.
    param([object]$Config, [string]$ConfigName)
    $applyPKI    = $TwoTierPKI -or $TheWorks
    $applyBLM    = $EnableBLM  -or $TheWorks
    $applyProxy  = $EnableProxy -or $TheWorks
    $applyOffice = $Office     -or $TheWorks
    if (-not ($applyPKI -or $applyBLM -or $applyProxy -or $applyOffice)) { return }
    Write-Host "Applying feature overrides to $ConfigName" -ForegroundColor Cyan
    if ($applyPKI)    { Enable-TwoTierPKI -Config $Config }
    if ($applyBLM)    { Enable-BLM -Config $Config }
    if ($applyProxy)  { Enable-Proxy -Config $Config }
    if ($applyOffice) { Enable-Office -Config $Config }
}

function Resolve-TestConfigNetworks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ConfigName
    )

    $domainName = "$($Config.vmOptions.domainName)"
    $defaultNetwork = "$($Config.vmOptions.network)"
    if ([string]::IsNullOrWhiteSpace($domainName) -or [string]::IsNullOrWhiteSpace($defaultNetwork)) {
        return
    }

    if ($null -eq $script:TestNetworkMap) {
        $script:TestNetworkMap = @{}
    }

    $existingVMs = @(Get-List -Type VM -SmartUpdate)

    # Live VMs cannot see a subnet whose lab was deleted but whose switch/scope
    # survived, and that leftover collides just as hard -- its DHCP scope still
    # hands out the dead lab's DNS server. Value is the owning domain (switch
    # note), or empty when nothing claims it.
    $hostSubnets = @{}
    foreach ($sw in @(Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue)) {
        if ($sw.Name -match '^\d{1,3}(\.\d{1,3}){3}$') { $hostSubnets[$sw.Name] = "$($sw.Notes)" }
    }
    if (-not (Test-MemLabsUsesDhcpAppliance)) {
        foreach ($scope in @(Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
            $scopeId = "$($scope.ScopeId)"
            if ($scopeId -and -not $hostSubnets.ContainsKey($scopeId)) { $hostSubnets[$scopeId] = '' }
        }
    }

    $networkUses = @([PSCustomObject]@{ Source = $defaultNetwork; VM = $null })
    foreach ($vm in @($Config.virtualMachines)) {
        $vmNetwork = $defaultNetwork
        if ($vm.network) { $vmNetwork = "$($vm.network)" }
        $networkUses += [PSCustomObject]@{ Source = $vmNetwork; VM = $vm }
    }

    $declaredNetworks = @()
    foreach ($networkUse in $networkUses) {
        if ($networkUse.Source -and $declaredNetworks -notcontains $networkUse.Source) {
            $declaredNetworks += $networkUse.Source
        }
    }

    foreach ($sourceNetwork in $declaredNetworks) {
        $mapKey = "$($domainName.ToLowerInvariant())|$($sourceNetwork.ToLowerInvariant())"
        if ($script:TestNetworkMap.ContainsKey($mapKey)) { continue }

        # A prior run may already have created this config on a remapped subnet.
        # Matching VM names are authoritative; existing VMs cannot be moved safely.
        $matchingNetworks = @()
        foreach ($networkUse in @($networkUses | Where-Object { $_.Source -eq $sourceNetwork -and $_.VM })) {
            $configVM = $networkUse.VM
            if ($configVM.Hidden -or $configVM.role -in @('InternetClient', 'AADClient')) { continue }
            $expectedName = "$($configVM.vmName)"
            $prefix = "$($Config.vmOptions.prefix)"
            if ($prefix -and -not $expectedName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $expectedName = $prefix + $expectedName
            }
            $existingVM = $existingVMs | Where-Object {
                $_.vmName -ieq $expectedName -and $_.Domain -ieq $domainName
            } | Select-Object -First 1
            if ($existingVM -and $existingVM.Network) {
                $matchingNetworks += "$($existingVM.Network)"
            }
        }
        $matchingNetworks = @($matchingNetworks | Sort-Object -Unique)

        if ($matchingNetworks.Count -eq 1) {
            $targetNetwork = $matchingNetworks[0]
            $script:TestNetworkMap[$mapKey] = $targetNetwork
            if ($targetNetwork -ne $sourceNetwork) {
                Write-Host "  [Network] $ConfigName`: reusing $targetNetwork for fixture subnet $sourceNetwork (matching $domainName VM already exists)." -ForegroundColor DarkCyan
            }
            continue
        }
        if ($matchingNetworks.Count -gt 1) {
            throw "$ConfigName maps fixture subnet $sourceNetwork to multiple existing $domainName networks: $($matchingNetworks -join ', ')."
        }

        $owners = @($existingVMs | Where-Object {
            $_.Network -eq $sourceNetwork -and -not [string]::IsNullOrWhiteSpace("$($_.Domain)")
        } | ForEach-Object { "$($_.Domain)" } | Sort-Object -Unique)

        if ($owners -contains $domainName) {
            $script:TestNetworkMap[$mapKey] = $sourceNetwork
            continue
        }

        if ($owners.Count -eq 0) {
            $hostNote = $hostSubnets[$sourceNetwork]
            if ($null -eq $hostNote -or $hostNote -eq $domainName) {
                $script:TestNetworkMap[$mapKey] = $sourceNetwork
                continue
            }
            if ([string]::IsNullOrWhiteSpace($hostNote)) {
                $owners = @("an orphaned switch/scope on this host")
            }
            else {
                $owners = @($hostNote)
            }
        }

        # Get-ValidSubnets only excludes host subnets that still have a vSwitch
        # adapter IP, so hand it every subnet the host knows about.
        $reservedTargets = @($script:TestNetworkMap.Values) + @($hostSubnets.Keys)
        $targetNetwork = @(Get-ValidSubnets -ConfigToCheck $Config -ExcludeList $reservedTargets | Select-Object -First 1)[0]
        if ([string]::IsNullOrWhiteSpace("$targetNetwork")) {
            throw "$ConfigName cannot replace fixture subnet $sourceNetwork, which is owned by [$($owners -join ', ')]: no unused subnet is available."
        }

        $script:TestNetworkMap[$mapKey] = "$targetNetwork"
        Write-Host "  [Network] $ConfigName`: fixture subnet $sourceNetwork is owned by [$($owners -join ', ')]; using $targetNetwork for $domainName." -ForegroundColor Yellow
    }

    $defaultMapKey = "$($domainName.ToLowerInvariant())|$($defaultNetwork.ToLowerInvariant())"
    $Config.vmOptions.network = $script:TestNetworkMap[$defaultMapKey]
    foreach ($networkUse in @($networkUses | Where-Object { $_.VM -and $_.VM.network })) {
        $mapKey = "$($domainName.ToLowerInvariant())|$($networkUse.Source.ToLowerInvariant())"
        $networkUse.VM.network = $script:TestNetworkMap[$mapKey]
    }

    if ($Config.domainDefaults -and $Config.domainDefaults.Network) {
        $domainDefaultsNetwork = "$($Config.domainDefaults.Network)"
        $mapKey = "$($domainName.ToLowerInvariant())|$($domainDefaultsNetwork.ToLowerInvariant())"
        if ($script:TestNetworkMap.ContainsKey($mapKey)) {
            $Config.domainDefaults.Network = $script:TestNetworkMap[$mapKey]
        }
    }
}

function Invoke-TestGitPull {
    param(
        [string]$Context
    )

    # Pull failures are non-fatal: the operator can still retry with the current tree.
    try {
        Write-Host "git pull ($Context)..." -ForegroundColor Cyan
        $pullOutput = & git -C $PSScriptRoot pull --rebase --autostash 2>&1
        $pullExit = $LASTEXITCODE
        $pullOutput | ForEach-Object { Write-Host "  $_" }
        if ($pullExit -ne 0) {
            Write-Host "  git pull returned $pullExit; continuing with the current tree." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  git pull failed: $($_.Exception.Message); continuing with the current tree." -ForegroundColor Yellow
    }
}

function Invoke-MixedRevisionGitRefresh {
    param([string]$Context)

    $mutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) {
            throw 'Another MemLabs test cycle owns the host mutation lock; refusing to update the shared checkout.'
        }

        Invoke-TestGitPull -Context $Context
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $revisionOutput = @(& git -C $repoRoot rev-parse HEAD 2>$null)
        $revision = if ($revisionOutput.Count -eq 1) { $revisionOutput[0].Trim() } else { '' }
        if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
            throw "Could not pin develop after git pull ($Context)."
        }
        return $revision
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Invoke-VMNoteCompatibilityPreflight {
    param([string] $PinnedMainRevision)

    $testPath = Join-Path $PSScriptRoot 'tools\Test-VMNoteMainToDevelopCompatibility.ps1'
    if (-not (Test-Path -LiteralPath $testPath)) {
        Write-Host "VM-note compatibility test not found: $testPath" -ForegroundColor Red
        return $false
    }

    $engines = @(
        [pscustomobject]@{ Name = 'PowerShell 7'; Path = (Join-Path $PSHOME 'pwsh.exe'); Arguments = @('-NoLogo', '-NoProfile', '-NonInteractive') }
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Path = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass') }
    )

    Write-Host '===== main-to-develop VM-note compatibility preflight =====' -ForegroundColor Magenta
    foreach ($engine in $engines) {
        if (-not (Test-Path -LiteralPath $engine.Path)) {
            Write-Host "FAIL: $($engine.Name) executable not found at $($engine.Path)" -ForegroundColor Red
            return $false
        }

        Write-Host "Running under $($engine.Name)..." -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        & $engine.Path @($engine.Arguments) -File $testPath -MainRevision $PinnedMainRevision | Out-Host
        $exitCode = [int]$LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Host "FAIL: VM-note compatibility preflight returned $exitCode under $($engine.Name)." -ForegroundColor Red
            return $false
        }
    }

    Write-Host 'PASS: VM-note compatibility preflight passed under both PowerShell engines.' -ForegroundColor Green
    return $true
}

function Invoke-MainToDevelopExpansionCycle {
    param(
        [string] $PinnedMainRevision,
        [string] $PinnedDevelopRevision,
        [string] $TestPrefix,
        [string[]] $TestPrefixes,
        [string] $StateRoot,
        [switch] $RunAll,
        [switch] $PlanOnly,
        [switch] $ResetState,
        [switch] $RequireCleanSource
    )

    $runnerPath = Join-Path $PSScriptRoot 'tools\Invoke-MainToDevelopExpansionTest.ps1'
    if (-not (Test-Path -LiteralPath $runnerPath)) {
        Write-Host "Cross-revision expansion runner not found: $runnerPath" -ForegroundColor Red
        return 2
    }

    $currentDevelopRevision = $PinnedDevelopRevision
    $forwardResetState = $ResetState.IsPresent
    do {
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerPath,
            '-RepositoryRoot', (Split-Path -Parent $PSScriptRoot),
            '-MainRevision', $PinnedMainRevision,
            '-DevelopRevision', $currentDevelopRevision
        )
        if ($RunAll.IsPresent) {
            $arguments += '-All'
        }
        elseif ($TestPrefixes.Count -gt 1) {
            $arguments += @('-TestsCsv', ($TestPrefixes -join ','))
        }
        elseif ($TestPrefixes.Count -eq 1) {
            $arguments += @('-Test', $TestPrefixes[0])
        }
        else {
            $arguments += @('-Test', $TestPrefix)
        }
        $arguments += '-PauseAtFamilyBoundary'
        if ($PlanOnly.IsPresent) { $arguments += '-PlanOnly' }
        if ($forwardResetState) { $arguments += '-ResetState' }
        if ($RequireCleanSource.IsPresent) { $arguments += '-RequireCleanSource' }
        if ($StateRoot) { $arguments += @('-StateRoot', $StateRoot) }

        $global:LASTEXITCODE = 0
        & (Join-Path $PSHOME 'pwsh.exe') @arguments | Out-Host
        $exitCode = [int]$LASTEXITCODE
        $forwardResetState = $false
        if ($exitCode -ne 56) { return $exitCode }

        try {
            $currentDevelopRevision = Invoke-MixedRevisionGitRefresh -Context 'between mixed-revision families'
        }
        catch {
            Write-Host "Could not refresh develop at the family boundary: $($_.Exception.Message)" -ForegroundColor Red
            return 2
        }
        Write-Host "Restarting mixed-revision runner at develop $currentDevelopRevision." -ForegroundColor Yellow
    } while ($true)
}

function Invoke-NewLab {
    # Run one deployment and hand back ONLY its exit code. Two things here are load-bearing:
    #  1. '| Out-Host' -- New-Lab.ps1 leaks objects onto the success stream. Un-piped they
    #     join Run-Test's own output, so the caller's "$result = Run-Test" gets an ARRAY and
    #     "-not $result" evaluates FALSE on failure: a failed build silently rolled on.
    #  2. Zeroing $LASTEXITCODE first -- New-Lab.ps1 only calls exit when it FAILS, so on
    #     success $LASTEXITCODE is whatever the last native command left (e.g. a preceding
    #     git pull whose non-zero exit we deliberately tolerate).
    #  3. -KeepFailedVMs -- without it New-Lab deletes every Phase 1 VM on failure, which
    #     flatly contradicts the "left intact for investigation" message the harness prints
    #     next and makes the offered Retry-after-repair impossible.
    param(
        [string]$ConfigFile
    )

    $script:LastNewLabResumeCommand = $null
    $global:NewLabResumeCommand = $null
    $global:LASTEXITCODE = 0
    & ./New-Lab.ps1 -Configuration $ConfigFile -NoSnapshot -KeepFailedVMs -ClearErrorHistoryOnExit -RequireCleanSource:$RequireCleanSource | Out-Host
    $code = [int]$LASTEXITCODE
    $script:LastNewLabResumeCommand = $global:NewLabResumeCommand

    # 55 = New-Lab rebuilt DSC.zip and needs a restart to pick it up.
    if ($code -eq 55) {
        $global:NewLabResumeCommand = $null
        $global:LASTEXITCODE = 0
        & ./New-Lab.ps1 -Configuration $ConfigFile -NoSnapshot -KeepFailedVMs -ClearErrorHistoryOnExit -RequireCleanSource:$RequireCleanSource | Out-Host
        $code = [int]$LASTEXITCODE
        $script:LastNewLabResumeCommand = $global:NewLabResumeCommand
    }

    # New-Lab runs INSIDE this process, so its job workers are children of the
    # harness and survive into the next test. Each is a pwsh.exe holding ~300MB
    # once it has dot-sourced Common.ps1, so an -All run accumulates them until
    # Phase 1 of some later test fails its memory pre-flight. Sweep between tests
    # and report anything that would not die, so the leaking job gets named.
    try {
        foreach ($job in @(Get-Job -ErrorAction SilentlyContinue)) {
            if ($job.State -eq 'Running') { try { $job.StopJobAsync() } catch { } }
        }
        $stragglers = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID AND Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match '-s\s+-NoLogo' })
        foreach ($proc in $stragglers) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
        foreach ($job in @(Get-Job -ErrorAction SilentlyContinue)) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        if ($stragglers.Count -gt 0) {
            Write-Host "  Swept $($stragglers.Count) leftover job worker process(es) after $(Split-Path $ConfigFile -Leaf)." -ForegroundColor DarkYellow
        }
        $null = Write-PowerShellJobLeakDiag -Context "Start-Test after $(Split-Path $ConfigFile -Leaf)"
    }
    catch { }

    return $code
}

function Get-TestFailureAction {
    # A failed build must never roll straight on to the next config. The lab is left
    # intact so it can be repaired in another window; the operator decides what happens next.
    param(
        [string]$ConfigFile,
        [string]$DomainName,
        [int]$ExitCode,
        [string]$ResumeCommand
    )

    Write-Host
    Write-Host "  BUILD FAILED (exit $ExitCode). The lab has been left intact for investigation." -ForegroundColor Red
    Write-Host "  Config : $ConfigFile" -ForegroundColor DarkGray
    Write-Host "  Domain : $DomainName" -ForegroundColor DarkGray
    if ($ResumeCommand) {
        Write-Host "  Resume : $ResumeCommand" -ForegroundColor DarkGray
        Write-Host "  Repair or resume it from another window, then choose Retry." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  No -StartPhase command was produced; the failure occurred before a resumable phase was identified." -ForegroundColor DarkGray
        Write-Host "  Correct the validation or startup issue above, then choose Retry." -ForegroundColor DarkGray
    }
    Write-Host

    if (-not [Environment]::UserInteractive) {
        Write-Host "  Non-interactive host; aborting the test run." -ForegroundColor Yellow
        return 'Abort'
    }

    if ($Automated.IsPresent) { return 'Abort' }
    while ($true) {
        try {
            $answer = "$(Read-Host '  [R]etry this config, [S]kip it and continue, [A]bort all tests (default A)')".Trim()
        }
        catch {
            # No console to read from (redirected/closed stdin) -- don't spin the prompt.
            Write-Host "  Could not read a response ($($_.Exception.Message)); aborting the test run." -ForegroundColor Yellow
            return 'Abort'
        }
        if (-not $answer) { return 'Abort' }
        switch ($answer.Substring(0, 1).ToUpperInvariant()) {
            'R' { return 'Retry' }
            'S' { return 'Skip' }
            'A' { return 'Abort' }
            default { Write-Host "  Please enter R, S or A." -ForegroundColor Yellow }
        }
    }
}

function Run-Test {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
        Justification = 'Local test-runner helper; not an exported cmdlet.')]
    param(
        [string]$Test
    )
    Write-Host "Starting all tests for $Test"
    $Test = $Test.ToLowerInvariant()
    $Tests = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name } | Where-Object { $_.Name.ToLowerInvariant().StartsWith($Test) }
    $script:TestNetworkMap = @{}

    # Run the entire prefix group twice before the domain is torn down: pass 1 deploys
    # every matching config in order, then pass 2 starts over at the first config and
    # re-runs the whole cycle (add/repair against the existing VMs) to prove a re-deploy
    # of the full sequence works. A failure in either pass fails the whole group
    # (returns $false), leaving the domain(s) intact for investigation.
    $groupFailed = $false
    $totalPasses = 2
    for ($pass = 1; $pass -le $totalPasses; $pass++) {
        $passLabel = if ($pass -eq 1) { "deploy" } else { "re-deploy" }
        Write-Host "===== $Test pass $pass of $totalPasses ($passLabel) =====" -ForegroundColor Magenta

        foreach ($testjson in $Tests) {
            # Always pull the latest code before each test so every run picks up the
            # newest New-Lab.ps1 / Common.ps1 / DSC / phase scripts without restarting
            # the runner. --rebase --autostash keeps any local edits and never creates a
            # merge commit; a pull failure is non-fatal (continue with the current tree).
            Invoke-TestGitPull -Context "before $(Split-Path $testjson -Leaf)"
            $outputFile = Split-Path $testjson -leaf
            $ModifiedtestFile = (Join-Path "c:\temp" $outputFile)
            $config = Get-Content $testjson -Force | ConvertFrom-Json
            if ($cmVersion -and $config.cmOptions.version) {
                if ($config.cmOptions.version -ne $cmVersion) {
                    $config.cmOptions.version = $cmVersion
                    write-host "updating cmVersion to $cmVersion"
                } 

                if ($DoNotInstallCM -and $config.cmOptions.Install)  {
                    $config.cmOptions.Install = $false
                }
            }
        
            if ($dynamicMemory) {
                foreach ($vm in $config.virtualMachines) {
                    $dynamicMinRam = if ($vm.sqlVersion) { "4GB" } else { "1GB" }
                    write-host "updating dynamicMinRam to $dynamicMinRam on $($vm.VmName)"
                    $vm | Add-Member -MemberType NoteProperty -Name "dynamicMinRam" -Value $dynamicMinRam -Force
                }       
            }
            if ($serverVersion) {
                foreach ($vm in $config.virtualMachines) {
                    if ($vm.operatingSystem -like "*server*") {
                        $vm.operatingSystem = $serverVersion
                    }
                }    
            }
            Set-FeatureOverrides -Config $config -ConfigName $outputFile
            Resolve-TestConfigNetworks -Config $config -ConfigName $outputFile
            $domainName = $config.vmOptions.domainName
            $global:removedomains += $domainName
            $global:removedomains = @($global:removedomains | Select-Object -Unique)

            $config | ConvertTo-Json -Depth 5 | Out-File $ModifiedtestFile -Force
            Write-Host "Starting test ($passLabel) for $testjson.  Added $domainName to the cleanup list: $($global:removedomains -join ', ')"

            $exitCode = Invoke-NewLab -ConfigFile $ModifiedtestFile
            Write-Host "$exitCode was returned from $testjson ($passLabel)"

            $action = 'Continue'
            while ($exitCode -ne 0) {
                Write-Host "$testjson Failed ($passLabel)"
                Write-Host "Failed to create lab for $testjson copied to $ModifiedtestFile"
                $action = Get-TestFailureAction -ConfigFile $ModifiedtestFile -DomainName $domainName -ExitCode $exitCode -ResumeCommand $script:LastNewLabResumeCommand
                if ($action -ne 'Retry') { break }
                Write-Host "Retrying $testjson ($passLabel)..." -ForegroundColor Cyan
                Invoke-TestGitPull -Context "before retrying $(Split-Path $testjson -Leaf)"
                $exitCode = Invoke-NewLab -ConfigFile $ModifiedtestFile
                Write-Host "$exitCode was returned from $testjson (retry, $passLabel)"
            }

            if ($exitCode -eq 0) {
                Write-Host "$testjson Completed Successfully ($passLabel)"
                $global:history += "$testjson Completed Successfully ($passLabel)"
                continue
            }

            # Still failed. Never let a failure be reported as a pass -- even when the
            # operator elects to keep going, the group stays failed so the caller leaves
            # every domain in place instead of tearing it down.
            $groupFailed = $true
            $global:history += "$testjson Failed ($passLabel)"
            if ($action -eq 'Skip') {
                Write-Host "Skipping $testjson and continuing ($passLabel). The group is still marked failed." -ForegroundColor Yellow
                continue
            }
            Write-Host "Aborting the test run. $domainName is left intact." -ForegroundColor Red
            return $false
        }
    }
    
    [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory("./Remove-lab.ps1 -DomainName $domainName")
    return (-not $groupFailed)
}

function Invoke-RecordedTestFamily {
    param(
        [Parameter(Mandatory = $true)][string] $Family,
        [string] $SuiteName = ''
    )

    $repositoryRoot = Split-Path -Parent $script:StartTestVmbuildRoot
    $metadata = Get-MemLabsFamilyMetadata -VmbuildRoot $script:StartTestVmbuildRoot -Family $Family
    $runId = [guid]::NewGuid().ToString('N')
    $startedUtc = [DateTime]::UtcNow
    $startCommit = Get-MemLabsCurrentCommit -RepositoryRoot $repositoryRoot
    Write-MemLabsTestHistoryEvent -Event ([pscustomobject]@{
            EventType = 'RunStarted'; RunId = $runId; CandidateKey = "Standard|$Family"
            Mode = 'Standard'; Family = $Family; Suite = $SuiteName
            StartedUtc = $startedUtc.ToString('o'); Commit = $startCommit
            Domains = @($metadata.Domains); CoverageTags = @($metadata.CoverageTags)
            RequiredMemoryGB = $metadata.EstimatedRequiredGB
        })
    $success = $false
    $failureText = ''
    try {
        $success = (@(Run-Test -Test $Family) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true
        if (-not $success) { $failureText = "Test family '$Family' returned failure." }
        return $success
    }
    catch {
        $failureText = $_.Exception.Message
        throw
    }
    finally {
        $completedUtc = [DateTime]::UtcNow
        Write-MemLabsTestHistoryEvent -Event ([pscustomobject]@{
                EventType = 'RunCompleted'; RunId = $runId; CandidateKey = "Standard|$Family"
                Mode = 'Standard'; Family = $Family; Suite = $SuiteName
                StartedUtc = $startedUtc.ToString('o'); CompletedUtc = $completedUtc.ToString('o')
                DurationSeconds = [Math]::Round(($completedUtc - $startedUtc).TotalSeconds, 1)
                Commit = Get-MemLabsCurrentCommit -RepositoryRoot $repositoryRoot
                StartCommit = $startCommit; Success = $success; ExitCode = $(if ($success) { 0 } else { 1 })
                Error = $failureText; Domains = @($metadata.Domains)
                CoverageTags = @($metadata.CoverageTags); NeedsRerun = -not $success
            })
    }
}

$script:TestMutationMutex = $null
$script:TestMutationMutexHeld = $false
if (-not $runCrossRevision -and -not $VMNoteCompatibilityOnly.IsPresent) {
    try {
        $script:TestMutationMutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
        try { $script:TestMutationMutexHeld = $script:TestMutationMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $script:TestMutationMutexHeld = $true }
        if (-not $script:TestMutationMutexHeld) {
            Write-Host 'Another MemLabs test cycle owns the host mutation lock. Stop it or wait for it to finish.' -ForegroundColor Red
            exit 2
        }
    }
    catch {
        Write-Host "Could not acquire the host mutation lock: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
}

if (-not $runCrossRevision) {
    Invoke-TestGitPull -Context 'before VM-note compatibility preflight'
}
else {
    if ($cmVersion -or $dynamicMemory.IsPresent -or $DoNotInstallCM.IsPresent -or $serverVersion -or
        $EnableBLM.IsPresent -or $EnableProxy.IsPresent -or $TwoTierPKI.IsPresent -or $Office.IsPresent -or $TheWorks.IsPresent) {
        Write-Host 'Feature and platform overrides are not supported in a pinned main-to-develop cycle; use the committed fixtures unchanged.' -ForegroundColor Red
        exit 2
    }

    $startTestRepoRoot = Split-Path -Parent $PSScriptRoot
    $branchOutput = @(& git -C $startTestRepoRoot branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or $branchOutput.Count -gt 1) {
        Write-Host 'Could not determine the current Git branch.' -ForegroundColor Red
        exit 2
    }
    $currentBranch = if ($branchOutput.Count -eq 1) { $branchOutput[0].Trim() } else { '' }
    if (-not $CrossRevisionPlanOnly.IsPresent -and $currentBranch -ne 'develop') {
        Write-Host "A live main-to-develop cycle must run from the develop branch; current branch is '$currentBranch'." -ForegroundColor Red
        exit 2
    }
    if ($DevelopRevision) {
        $resolvedDevelop = @(& git -C $startTestRepoRoot rev-parse "$DevelopRevision^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $resolvedDevelop.Count -ne 1 -or $resolvedDevelop[0] -notmatch '^[0-9a-f]{40}$') {
            Write-Host "Could not resolve pinned develop revision '$DevelopRevision'." -ForegroundColor Red
            exit 2
        }
        $developRevision = $resolvedDevelop[0].Trim()
        Write-Host "Using explicitly pinned develop revision $developRevision." -ForegroundColor DarkGray
    }
    elseif (-not $CrossRevisionPlanOnly.IsPresent) {
        try {
            $developRevision = Invoke-MixedRevisionGitRefresh -Context 'before mixed-revision cycle'
        }
        catch {
            Write-Host "Could not refresh develop before the mixed-revision cycle: $($_.Exception.Message)" -ForegroundColor Red
            exit 2
        }
    }
    else {
        Write-Host 'Mixed-revision plan-only mode uses the current committed HEAD without pulling.' -ForegroundColor DarkGray
    }
}
if ($SkipVMNoteCompatibility.IsPresent) {
    Write-Host 'WARNING: main-to-develop VM-note compatibility preflight skipped by request.' -ForegroundColor Yellow
}
elseif (-not (Invoke-VMNoteCompatibilityPreflight -PinnedMainRevision $MainRevision)) {
    Write-Host 'Start-Test stopped before lab mutation because the VM-note compatibility preflight failed.' -ForegroundColor Red
    exit 1
}

if ($VMNoteCompatibilityOnly.IsPresent) {
    exit 0
}

if (($CrossRevisionPlanOnly.IsPresent -or $ResetCrossRevisionState.IsPresent) -and -not $runCrossRevision) {
    Write-Host '-CrossRevisionPlanOnly and -ResetCrossRevisionState require -MainToDevelopExpansion or -Suite Upgrade.' -ForegroundColor Red
    exit 2
}

if ($runCrossRevision) {
    if ($CrossRevisionPlanOnly.IsPresent -and -not $developRevision) {
        $developOutput = @(& git -C $startTestRepoRoot rev-parse HEAD 2>$null)
        $developRevision = if ($developOutput.Count -eq 1) { $developOutput[0].Trim() } else { '' }
        if ($LASTEXITCODE -ne 0 -or $developRevision -notmatch '^[0-9a-f]{40}$') {
            Write-Host 'Could not pin the current develop commit.' -ForegroundColor Red
            exit 2
        }
    }
    $crossRevisionFamilies = if ($resolvedTestSuite -and -not $resolvedTestSuite.IncludeAll) {
        @($resolvedTestSuite.Families)
    }
    else {
        @()
    }
    $crossRevisionRunAll = ($resolvedTestSuite -and $resolvedTestSuite.IncludeAll) -or
        (-not $resolvedTestSuite -and $All.IsPresent)
    $crossRevisionExit = Invoke-MainToDevelopExpansionCycle `
        -PinnedMainRevision $MainRevision `
        -PinnedDevelopRevision $developRevision `
        -TestPrefix $Test `
        -TestPrefixes $crossRevisionFamilies `
        -RunAll:$crossRevisionRunAll `
        -StateRoot $CrossRevisionStateRoot `
        -PlanOnly:$CrossRevisionPlanOnly `
        -ResetState:$ResetCrossRevisionState `
        -RequireCleanSource:$RequireCleanSource
    exit $crossRevisionExit
}

# Validate Common.ps1 has UTF-8 BOM before dot-sourcing (PS5.1 needs BOM for non-ASCII chars)
$commonPath = Join-Path $PSScriptRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. PS5.1 will fail to parse non-ASCII characters." -ForegroundColor Red
    Write-Host "Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Yellow
    exit 1
}

. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

try {
    $global:history = @()
    $global:removedomains = @()
    $script:StartTestFailed = $false
    if ($test) {
        # Coerce down to the single boolean: anything Run-Test's callees leak onto the
        # success stream would otherwise make this an array (and every -not test useless).
        $result = (@(Invoke-RecordedTestFamily -Family $Test) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true
        if (-not $result) {
            $script:StartTestFailed = $true
            Write-Host "Test '$Test' FAILED. Labs left intact: $($global:removedomains -join ', ')" -ForegroundColor Red
        }
        elseif ($CleanupOnSuccess.IsPresent) {
            foreach ($domain in @($global:removedomains | Select-Object -Unique)) {
                Write-Host "CleanupOnSuccess: removing $domain" -ForegroundColor DarkGray
                try {
                    & ./Remove-lab.ps1 -DomainName $domain
                    $remaining = @(Get-List -Type VM -DomainName $domain -SmartUpdate)
                    if ($remaining.Count -gt 0) {
                        throw "Cleanup left VM(s): $($remaining.vmName -join ', ')."
                    }
                }
                catch {
                    $script:StartTestFailed = $true
                    Write-Host "CleanupOnSuccess failed for '$domain': $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            $global:removedomains = @()
        }
    }

    if ($all -or $Suite) {
        $Tests = @($resolvedTestSuite.Families)
        Write-Host "Running '$($resolvedTestSuite.Name)' suite: $($Tests -join ', ')" -ForegroundColor Cyan

        foreach ($Test in $Tests) {
            if (Get-Content "c:\temp\CompletedTests.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -eq $Test }) {
                write-host "$Test already ran skipping"
                continue
            }
            $result = (@(Invoke-RecordedTestFamily -Family $Test -SuiteName $resolvedTestSuite.Name) |
                    Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true
            Write-Host "$Test returned $result"
            if (-not $result) {
                $script:StartTestFailed = $true
                Write-Host "Stopping: '$Test' failed. Labs left intact for repair: $($global:removedomains -join ', ')" -ForegroundColor Red
                break
            }
            if ($global:removedomains.Count -gt 0) {
                foreach ($domain in $global:removedomains) {
                    write-host "calling ./Remove-lab.ps1 -DomainName $domain"
                    & ./Remove-lab.ps1 -DomainName $domain
                    $global:history += "$domain Removed"
                }
                $global:removedomains = @()
            }else {
                write-host "global:removedomains was empty"
            }
            $Test | Out-File "c:\temp\CompletedTests.txt" -Force -Append
        }
    }
}
finally {
    Write-Host
    Write-Host "History of tests ran"
    Write-Host "----------------------"
    foreach ($historyitem in $global:history) {
        if ($historyitem -like "*Failed*") {
            Write-RedX $historyitem 
        }
        else {
            Write-GreenCheck $historyitem
        }
    }
    Write-host "Delete C:\temp\CompletedTests.txt to re-run all tests"
    if ($script:TestMutationMutexHeld) {
        try { $script:TestMutationMutex.ReleaseMutex() } catch { }
    }
    if ($script:TestMutationMutex) { $script:TestMutationMutex.Dispose() }
}
if ($script:StartTestFailed) { exit 1 }
