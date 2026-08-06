#Start-Test.ps1
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

    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'TestName')]
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
    [switch]$dynamicMemory,

    [Parameter(Mandatory = $false, HelpMessage = "Override Install CM", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Install CM", ParameterSetName = 'TestName')]
    [switch]$DoNotInstallCM,

    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'TestName')]
    [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false -InJob:$true
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
    [switch]$EnableBLM,

    [Parameter(Mandatory = $false, HelpMessage = "Add a Proxy server and route Windows clients through it", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Add a Proxy server and route Windows clients through it", ParameterSetName = 'TestName')]
    [switch]$EnableProxy,

    [Parameter(Mandatory = $false, HelpMessage = "Two-tier PKI: issuing CA on the DC + offline standalone root CA", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Two-tier PKI: issuing CA on the DC + offline standalone root CA", ParameterSetName = 'TestName')]
    [switch]$TwoTierPKI,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy Microsoft 365 Apps (Office) to Windows clients", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Deploy Microsoft 365 Apps (Office) to Windows clients", ParameterSetName = 'TestName')]
    [switch]$Office,

    [Parameter(Mandatory = $false, HelpMessage = "Enable BLM + Proxy + Two-tier PKI + Office together", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Enable BLM + Proxy + Two-tier PKI + Office together", ParameterSetName = 'TestName')]
    [switch]$TheWorks
)


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

function Invoke-NewLab {
    # Run one deployment and hand back ONLY its exit code. Two things here are load-bearing:
    #  1. '| Out-Host' -- New-Lab.ps1 leaks objects onto the success stream. Un-piped they
    #     join Run-Test's own output, so the caller's "$result = Run-Test" gets an ARRAY and
    #     "-not $result" evaluates FALSE on failure: a failed build silently rolled on.
    #  2. Zeroing $LASTEXITCODE first -- New-Lab.ps1 only calls exit when it FAILS, so on
    #     success $LASTEXITCODE is whatever the last native command left (e.g. the git pull
    #     above, whose non-zero exit we deliberately tolerate).
    #  3. -KeepFailedVMs -- without it New-Lab deletes every Phase 1 VM on failure, which
    #     flatly contradicts the "left intact for investigation" message the harness prints
    #     next and makes the offered Retry-after-repair impossible.
    param(
        [string]$ConfigFile
    )

    $global:LASTEXITCODE = 0
    & ./New-Lab.ps1 -Configuration $ConfigFile -NoSnapshot -KeepFailedVMs | Out-Host
    $code = [int]$LASTEXITCODE

    # 55 = New-Lab rebuilt DSC.zip and needs a restart to pick it up.
    if ($code -eq 55) {
        $global:LASTEXITCODE = 0
        & ./New-Lab.ps1 -Configuration $ConfigFile -NoSnapshot -KeepFailedVMs | Out-Host
        $code = [int]$LASTEXITCODE
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
        [int]$ExitCode
    )

    Write-Host
    Write-Host "  BUILD FAILED (exit $ExitCode). The lab has been left intact for investigation." -ForegroundColor Red
    Write-Host "  Config : $ConfigFile" -ForegroundColor DarkGray
    Write-Host "  Domain : $DomainName" -ForegroundColor DarkGray
    Write-Host "  Repair it from another window (New-Lab printed a '-startPhase' resume command above), then choose Retry." -ForegroundColor DarkGray
    Write-Host

    if (-not [Environment]::UserInteractive) {
        Write-Host "  Non-interactive host; aborting the test run." -ForegroundColor Yellow
        return 'Abort'
    }

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
            try {
                Write-Host "git pull (before $(Split-Path $testjson -Leaf))..." -ForegroundColor Cyan
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
            $domainName = $config.vmOptions.domainName
            $global:removedomains += $domainName
            $global:removedomains = @($global:removedomains | Select-Object -Unique)

            $config | ConvertTo-Json -Depth 5 | Out-File $ModifiedtestFile -Force
            Write-Host "Starting test ($passLabel) for $testjson.  Adding $domainName to $($global:removeddomains -join ',')"

            $exitCode = Invoke-NewLab -ConfigFile $ModifiedtestFile
            Write-Host "$exitCode was returned from $testjson ($passLabel)"

            $action = 'Continue'
            while ($exitCode -ne 0) {
                Write-Host "$testjson Failed ($passLabel)"
                Write-Host "Failed to create lab for $testjson copied to $ModifiedtestFile"
                $action = Get-TestFailureAction -ConfigFile $ModifiedtestFile -DomainName $domainName -ExitCode $exitCode
                if ($action -ne 'Retry') { break }
                Write-Host "Retrying $testjson ($passLabel)..." -ForegroundColor Cyan
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
    if ($test) {
        # Coerce down to the single boolean: anything Run-Test's callees leak onto the
        # success stream would otherwise make this an array (and every -not test useless).
        $result = (@(Run-Test -Test $Test) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true
        if (-not $result) {
            Write-Host "Test '$Test' FAILED. Labs left intact: $($global:removedomains -join ', ')" -ForegroundColor Red
        }
    }

    if ($all) {
        $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name }
        $Tests = @()
        foreach ($name in $ConfigPaths.Name) {
     
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

        foreach ($Test in $Tests) {
            if (Get-Content "c:\temp\CompletedTests.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -eq $Test }) {
                write-host "$Test already ran skipping"
                continue
            }
            $result = (@(Run-Test -Test $($Test + "-")) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) -eq $true
            Write-Host "$Test returned $result"
            if (-not $result) {
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
}