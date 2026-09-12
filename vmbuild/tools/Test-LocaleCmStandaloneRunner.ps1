#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Failures = [Collections.Generic.List[string]]::new()
$script:AssertionCount = 0

function Assert-True {
    param([bool] $Condition, [string] $What)
    $script:AssertionCount++
    if ($Condition) {
        [Console]::WriteLine("PASS  $What")
    }
    else {
        $script:Failures.Add($What)
        [Console]::WriteLine("FAIL  $What")
    }
}

function Assert-ThrowsLike {
    param([scriptblock] $Action, [string] $Pattern, [string] $What)
    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert-True -Condition ($message -like $Pattern) -What $What
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)." }
    $functionAst = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functionAst.Count -ne 1) { throw "Expected one $Name function, found $($functionAst.Count)." }
    return [scriptblock]::Create($functionAst[0].Extent.Text)
}

$runnerPath = Join-Path $PSScriptRoot 'Invoke-LocaleCmStandaloneTest.ps1'
$configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\tests\Locale-CM-Standalone.json'
$additionsConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\tests\Locale-CM-Standalone-Additions.json'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-standalone-locale-' + [guid]::NewGuid().ToString('N'))
$outputRoot = Join-Path $fixtureRoot 'output'
$capturePath = Join-Path $fixtureRoot 'capture.json'
$stubPath = Join-Path $fixtureRoot 'Invoke-MemLabsMonitoredDeployment.ps1'
$global:MemLabsStandaloneHostProductType = 1
$global:MemLabsStandaloneExistingVmNames = @()
$global:MemLabsStandaloneCounterAvailableMB = 30720
$global:MemLabsStandaloneCounterFailure = $false
$global:MemLabsStandaloneFallbackAvailableKB = 26624 * 1024
$global:MemLabsStandaloneNow = [datetime]'2026-09-12T00:00:00Z'
$global:MemLabsStandaloneCounterSamplesMB = @()
$global:MemLabsStandaloneCounterSampleIndex = 0
$global:MemLabsStandaloneProbeDelaySeconds = 0

function global:Get-CimInstance {
    param([string] $ClassName)
    if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ TotalPhysicalMemory = 64GB } }
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ ProductType = $global:MemLabsStandaloneHostProductType; FreePhysicalMemory = $global:MemLabsStandaloneFallbackAvailableKB } }
    throw "Unexpected Get-CimInstance class '$ClassName'."
}

function global:Get-Command {
    param([string] $Name)
    if ($Name -eq 'Get-VM') { return [pscustomobject]@{ Name = 'Get-VM' } }
    throw "Unexpected Get-Command name '$Name'."
}

function global:Get-PSDrive {
    param([string] $Name, [string] $PSProvider)
    return [pscustomobject]@{ Name = $Name; Free = 700GB }
}

function global:Get-Counter {
    param([string] $Counter)
    if ($global:MemLabsStandaloneCounterFailure) { throw 'fixture counter failure' }
    $value = $global:MemLabsStandaloneCounterAvailableMB
    if ($global:MemLabsStandaloneCounterSamplesMB.Count -gt 0) {
        $sampleIndex = [math]::Min($global:MemLabsStandaloneCounterSampleIndex, $global:MemLabsStandaloneCounterSamplesMB.Count - 1)
        $value = $global:MemLabsStandaloneCounterSamplesMB[$sampleIndex]
        $global:MemLabsStandaloneCounterSampleIndex++
    }
    return [pscustomobject]@{ CounterSamples = @([pscustomobject]@{ CookedValue = $value }) }
}

function global:Get-Date { return $global:MemLabsStandaloneNow }
function global:Start-Sleep { param([int] $Seconds) $global:MemLabsStandaloneNow = $global:MemLabsStandaloneNow.AddSeconds($Seconds) }
function global:Start-ThreadJob {
    param([scriptblock] $ScriptBlock)
    $value = & $ScriptBlock
    return [pscustomobject]@{ Value = $value; DelaySeconds = $global:MemLabsStandaloneProbeDelaySeconds }
}
function global:Wait-Job {
    param($Job, [int] $Timeout)
    if ($Job.DelaySeconds -gt $Timeout) {
        $global:MemLabsStandaloneNow = $global:MemLabsStandaloneNow.AddSeconds($Timeout)
        return $null
    }
    $global:MemLabsStandaloneNow = $global:MemLabsStandaloneNow.AddSeconds($Job.DelaySeconds)
    return $Job
}
function global:Receive-Job { param($Job) return $Job.Value }
function global:Stop-Job { param($Job) }
function global:Remove-Job { param($Job, [switch] $Force) }

function global:Get-VM {
    param([string[]] $Name)
    foreach ($vmName in $Name) {
        if ($vmName -in $global:MemLabsStandaloneExistingVmNames) { [pscustomobject]@{ Name = $vmName } }
    }
}

try {
    $null = New-Item -Path $fixtureRoot -ItemType Directory -Force
    @'
param(
    [string] $Configuration,
    [int] $StartPhase = 0,
    [int] $NoProgressMinutes,
    [int] $PollSeconds,
    [int] $MaxHours,
    [int] $ExpectedCompletedPhase,
    [switch] $KeepFailedVMs
)
[ordered]@{
    Configuration = $Configuration
    StartPhase = $StartPhase
    NoProgressMinutes = $NoProgressMinutes
    PollSeconds = $PollSeconds
    MaxHours = $MaxHours
    ExpectedCompletedPhase = $ExpectedCompletedPhase
    KeepFailedVMs = $KeepFailedVMs.IsPresent
} | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:MEMLABS_STANDALONE_CAPTURE -Encoding UTF8
'@ | Set-Content -LiteralPath $stubPath -Encoding UTF8
    $env:MEMLABS_STANDALONE_CAPTURE = $capturePath

    . (Import-TestFunction -Path $runnerPath -Name 'Wait-LocaleStageCapacity')
    $global:MemLabsStandaloneCounterAvailableMB = 23552
    Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes 2
    Assert-True -Condition ($global:MemLabsStandaloneNow -eq [datetime]'2026-09-12T00:01:00Z') -What 'stage handoff requires three sustained samples at the exact authoritative threshold'
    $global:MemLabsStandaloneCounterFailure = $true
    $global:MemLabsStandaloneFallbackAvailableKB = 24GB / 1KB
    $global:MemLabsStandaloneNow = [datetime]'2026-09-12T00:00:00Z'
    Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes 2
    Assert-True -Condition ($global:MemLabsStandaloneNow -eq [datetime]'2026-09-12T00:01:00Z') -What 'stage handoff requires three sustained CIM fallback samples'
    $global:MemLabsStandaloneFallbackAvailableKB = 22GB / 1KB
    $global:MemLabsStandaloneNow = [datetime]'2026-09-12T00:00:00Z'
    Assert-ThrowsLike -Action { Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes 1 } -Pattern '*raw available memory remained below 23 GB for 1 minute*' -What 'stage handoff times out when fallback memory remains insufficient'
    $global:MemLabsStandaloneCounterFailure = $false
    $global:MemLabsStandaloneNow = [datetime]'2026-09-12T00:00:00Z'
    $global:MemLabsStandaloneCounterSamplesMB = @(23552, 23551.5, 23552, 23552, 23552)
    $global:MemLabsStandaloneCounterSampleIndex = 0
    Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes 3
    Assert-True -Condition ($global:MemLabsStandaloneCounterSampleIndex -eq 5) -What 'stage handoff rejects an unrounded sub-threshold sample and resets the qualifying streak'
    $global:MemLabsStandaloneCounterSamplesMB = @()
    $global:MemLabsStandaloneCounterSampleIndex = 0
    $global:MemLabsStandaloneCounterAvailableMB = 30720
    $global:MemLabsStandaloneProbeDelaySeconds = 30
    $global:MemLabsStandaloneNow = [datetime]'2026-09-12T00:00:00Z'
    Assert-ThrowsLike -Action { Wait-LocaleStageCapacity -RequiredAvailableGB 23 -TimeoutMinutes 1 } -Pattern '*raw available memory remained below 23 GB for 1 minute*' -What 'stage handoff bounds stalled probes to the wall-clock timeout'
    Assert-True -Condition ($global:MemLabsStandaloneNow -eq [datetime]'2026-09-12T00:01:00Z') -What 'stalled memory probes cannot overrun the handoff deadline'
    $global:MemLabsStandaloneProbeDelaySeconds = 0

    $global:LASTEXITCODE = 37
    & $runnerPath -LocaleSet 3 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null
    $freshCaptures = @(Get-Content -LiteralPath $capturePath | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    Assert-True -Condition ($freshCaptures.Count -eq 2 -and @($freshCaptures | Where-Object { $_.ExpectedCompletedPhase -eq 11 -and $_.StartPhase -eq 0 -and $_.KeepFailedVMs }).Count -eq 2) -What 'default run forwards both fresh stages through monitored Phase 11 completion'
    Assert-True -Condition (@($freshCaptures | Where-Object { $_.PollSeconds -eq 60 -and $_.NoProgressMinutes -eq 45 -and $_.MaxHours -eq 18 }).Count -eq 2) -What 'both fresh stages forward monitor timing parameters'
    $expectedCorePath = Join-Path $outputRoot 'Locale-CM-Standalone-Core-Set3.json'
    $expectedAdditionsPath = Join-Path $outputRoot 'Locale-CM-Standalone-Additions-Set3.json'
    Assert-True -Condition (($freshCaptures.Configuration -join ',') -eq "$expectedCorePath,$expectedAdditionsPath") -What 'default run forwards core then additions generated configuration paths'
    $generatedCore = Get-Content -LiteralPath $expectedCorePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $generatedAdditions = Get-Content -LiteralPath $expectedAdditionsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $generatedVms = @($generatedCore.virtualMachines) + @($generatedAdditions.virtualMachines)
    Assert-True -Condition ($generatedCore.vmOptions.basePath -eq 'C:\VirtualMachines' -and $generatedAdditions.vmOptions.basePath -eq 'C:\VirtualMachines' -and $generatedCore.vmOptions.prefix -eq 'LS3-' -and $generatedCore.vmOptions.domainName -eq 'standalone3.lab' -and $generatedCore.vmOptions.network -eq '10.221.223.0') -What 'serialized set 3 stages contain matching storage and identity'
    Assert-True -Condition ((@($generatedVms | ForEach-Object locale) -join ',') -eq 'fi-FI,hr-HR,it-IT,fr-CA,he-IL,hu-HU,ja-JP,ko-KR') -What 'serialized set 3 stages contain all eight locale assignments'
    Assert-True -Condition (((@($generatedCore.virtualMachines | ForEach-Object { $_.memory / 1 }) | Measure-Object -Sum).Sum -eq 22GB) -and ((@($generatedAdditions.virtualMachines | ForEach-Object { $_.memory / 1 }) | Measure-Object -Sum).Sum -eq 15GB)) -What 'serialized stages preserve 22 GB and 15 GB deployment budgets'
    Assert-True -Condition ((@($generatedAdditions.virtualMachines | ForEach-Object { "$($_.vmName)=$($_.memory)/$($_.dynamicMinRam)" }) -join ',') -eq 'BDC1=3GB/1GB,FS1=3GB/1GB,SRV1=2GB/1GB,DPMP1=3GB/1GB,CL1=4GB/1GB') -What 'serialized additions preserve the reviewed per-role memory profile'

    $forbiddenProperties = @('OtherNode', 'AlwaysOnName', 'ClusterName', 'ClusterIPAddress', 'AGIPAddress', 'fileServerVM', 'AlwaysOnGroupName', 'AlwaysOnListenerName', 'SqlServiceAccount', 'SqlAgentAccount')
    $generatedAoProperties = @(foreach ($vm in $generatedVms) {
            foreach ($property in $forbiddenProperties) {
                if ($vm.PSObject.Properties.Name -contains $property) { "$($vm.vmName).$property" }
            }
        })
    Assert-True -Condition (@($generatedVms | Where-Object role -eq 'SQLAO').Count -eq 0 -and $generatedAoProperties.Count -eq 0) -What 'serialized stages contain no SQLAO role or topology property'

    $global:MemLabsStandaloneExistingVmNames = @($generatedCore.virtualMachines | ForEach-Object { "LS3-$($_.vmName)" })
    Remove-Item -LiteralPath $capturePath -Force
    & $runnerPath -LocaleSet 3 -Stage Core -StartPhase 8 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null
    $coreResumeCapture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ($coreResumeCapture.StartPhase -eq 8 -and $coreResumeCapture.ExpectedCompletedPhase -eq 11 -and $coreResumeCapture.Configuration -eq $expectedCorePath) -What 'core resume forwards start phase 8 and expected completion phase 11'

    $global:MemLabsStandaloneExistingVmNames = @($generatedVms | ForEach-Object { "LS3-$($_.vmName)" })
    Remove-Item -LiteralPath $capturePath -Force
    $additionsResumeStart = $global:MemLabsStandaloneNow
    & $runnerPath -LocaleSet 3 -Stage Additions -StartPhase 8 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null
    $additionsResumeCapture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ($additionsResumeCapture.StartPhase -eq 8 -and $additionsResumeCapture.ExpectedCompletedPhase -eq 11 -and $additionsResumeCapture.Configuration -eq $expectedAdditionsPath) -What 'additions resume forwards start phase 8 and expected completion phase 11'
    Assert-True -Condition ($global:MemLabsStandaloneNow -eq $additionsResumeStart.AddMinutes(1)) -What 'explicit additions resume also requires three sustained capacity samples'

    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -StartPhase 8 -PlanOnly | Out-Null } -Pattern '*Select -Stage Core or -Stage Additions*' -What 'all-stage resume requires an explicit stage'

    $global:MemLabsStandaloneExistingVmNames = @('LS3-DC1')
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*Fresh All stage refused because target VM(s) already exist*' -What 'fresh all-stage run rejects an existing target VM'
    $global:MemLabsStandaloneExistingVmNames = @('LS3-DC1')
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -Stage Core -StartPhase 8 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*Core stage resume from Phase 8 refused because target VM(s) are missing*' -What 'core resume rejects missing core VMs'

    $global:MemLabsStandaloneExistingVmNames = @()
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -Stage Additions -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*Additions stage requires completed core VM(s)*' -What 'additions stage rejects a missing core'

    $global:MemLabsStandaloneExistingVmNames = @()
    $global:MemLabsStandaloneHostProductType = 3
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -Stage Core -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*C: VM storage is supported only when the Hyper-V host runs Windows Client*' -What 'non-plan run rejects C drive storage on Windows Server'
    $global:MemLabsStandaloneHostProductType = 1

    foreach ($property in $forbiddenProperties) {
        $mutatedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $sqlVm = $mutatedConfig.virtualMachines | Where-Object vmName -eq 'SQL1'
        $sqlVm | Add-Member -MemberType NoteProperty -Name $property -Value 'fixture-value'
        $mutationPath = Join-Path $fixtureRoot "ao-$property.json"
        $mutatedConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $mutationPath -Encoding UTF8
        Assert-ThrowsLike -Action { & $runnerPath -Configuration $mutationPath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern "*SQL1.$property*" -What "plan rejects SQLAO property $property"
    }

    $memoryConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    ($memoryConfig.virtualMachines | Where-Object vmName -eq 'SQL1').memory = '9GB'
    $memoryPath = Join-Path $fixtureRoot 'memory.json'
    $memoryConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $memoryPath -Encoding UTF8
    Assert-ThrowsLike -Action { & $runnerPath -Configuration $memoryPath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern '*Core locale stage requires exactly 22 GB configured VM memory*' -What 'plan rejects core memory drift'

    $osConfig = Get-Content -LiteralPath $additionsConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    ($osConfig.virtualMachines | Where-Object vmName -eq 'CL1').operatingSystem = 'Server 2022'
    $osPath = Join-Path $fixtureRoot 'client-os.json'
    $osConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $osPath -Encoding UTF8
    Assert-ThrowsLike -Action { & $runnerPath -AdditionsConfiguration $osPath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern "*Additions locale stage VM 'CL1' must be one visible DomainMember running Windows 11*" -What 'plan rejects client operating-system drift'

    $roleConfig = Get-Content -LiteralPath $additionsConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    ($roleConfig.virtualMachines | Where-Object vmName -eq 'FS1').role = 'DomainMember'
    $rolePath = Join-Path $fixtureRoot 'role.json'
    $roleConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $rolePath -Encoding UTF8
    Assert-ThrowsLike -Action { & $runnerPath -AdditionsConfiguration $rolePath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern "*Additions locale stage VM 'FS1' must be one visible FileServer running Server 2022*" -What 'plan rejects role drift'
}
finally {
    Remove-Item Env:\MEMLABS_STANDALONE_CAPTURE -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-CimInstance, Function:\Get-Command, Function:\Get-PSDrive, Function:\Get-Counter, Function:\Get-Date, Function:\Start-Sleep, Function:\Start-ThreadJob, Function:\Wait-Job, Function:\Receive-Job, Function:\Stop-Job, Function:\Remove-Job, Function:\Get-VM -ErrorAction SilentlyContinue
    Remove-Variable MemLabsStandaloneHostProductType, MemLabsStandaloneExistingVmNames, MemLabsStandaloneCounterAvailableMB, MemLabsStandaloneCounterFailure, MemLabsStandaloneFallbackAvailableKB, MemLabsStandaloneNow, MemLabsStandaloneCounterSamplesMB, MemLabsStandaloneCounterSampleIndex, MemLabsStandaloneProbeDelaySeconds -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    [Console]::WriteLine("FAIL: Test-LocaleCmStandaloneRunner ($($script:Failures.Count) failure(s), $script:AssertionCount assertions)")
    $script:Failures | ForEach-Object { [Console]::WriteLine("  $_") }
    exit 1
}

[Console]::WriteLine("PASS: Test-LocaleCmStandaloneRunner ($script:AssertionCount assertions)")
exit 0