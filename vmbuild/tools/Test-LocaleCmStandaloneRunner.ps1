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

$runnerPath = Join-Path $PSScriptRoot 'Invoke-LocaleCmStandaloneTest.ps1'
$configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\tests\Locale-CM-Standalone.json'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-standalone-locale-' + [guid]::NewGuid().ToString('N'))
$outputRoot = Join-Path $fixtureRoot 'output'
$capturePath = Join-Path $fixtureRoot 'capture.json'
$stubPath = Join-Path $fixtureRoot 'Invoke-MemLabsMonitoredDeployment.ps1'
$global:MemLabsStandaloneHostProductType = 1
$global:MemLabsStandaloneExistingVmNames = @()

function global:Get-CimInstance {
    param([string] $ClassName)
    if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ TotalPhysicalMemory = 64GB } }
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ ProductType = $global:MemLabsStandaloneHostProductType } }
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
} | ConvertTo-Json | Set-Content -LiteralPath $env:MEMLABS_STANDALONE_CAPTURE -Encoding UTF8
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $stubPath -Encoding UTF8
    $env:MEMLABS_STANDALONE_CAPTURE = $capturePath

    & $runnerPath -LocaleSet 3 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null
    $freshCapture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $generatedConfig = Get-Content -LiteralPath $freshCapture.Configuration -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ($freshCapture.ExpectedCompletedPhase -eq 11 -and $freshCapture.StartPhase -eq 0 -and $freshCapture.KeepFailedVMs) -What 'fresh run forwards monitored Phase 11 completion and VM retention'
    Assert-True -Condition ($freshCapture.PollSeconds -eq 60 -and $freshCapture.NoProgressMinutes -eq 45 -and $freshCapture.MaxHours -eq 18) -What 'fresh run forwards monitor timing parameters'
    Assert-True -Condition ($freshCapture.Configuration -eq (Join-Path $outputRoot 'Locale-CM-Standalone-Set3.json')) -What 'fresh run forwards the isolated generated configuration path'
    Assert-True -Condition ($generatedConfig.vmOptions.basePath -eq 'C:\VirtualMachines' -and $generatedConfig.vmOptions.prefix -eq 'LS3-' -and $generatedConfig.vmOptions.domainName -eq 'standalone3.lab' -and $generatedConfig.vmOptions.network -eq '10.221.223.0') -What 'serialized set 3 contains the expected storage and identity'
    Assert-True -Condition ((@($generatedConfig.virtualMachines | ForEach-Object locale) -join ',') -eq 'fi-FI,fr-CA,he-IL,hr-HR,hu-HU,it-IT,ja-JP,ko-KR') -What 'serialized set 3 contains all eight locale assignments'

    $forbiddenProperties = @('OtherNode', 'AlwaysOnName', 'ClusterName', 'ClusterIPAddress', 'AGIPAddress', 'fileServerVM', 'AlwaysOnGroupName', 'AlwaysOnListenerName', 'SqlServiceAccount', 'SqlAgentAccount')
    $generatedAoProperties = @(foreach ($vm in $generatedConfig.virtualMachines) {
            foreach ($property in $forbiddenProperties) {
                if ($vm.PSObject.Properties.Name -contains $property) { "$($vm.vmName).$property" }
            }
        })
    Assert-True -Condition (@($generatedConfig.virtualMachines | Where-Object role -eq 'SQLAO').Count -eq 0 -and $generatedAoProperties.Count -eq 0) -What 'serialized configuration contains no SQLAO role or topology property'

    $global:MemLabsStandaloneExistingVmNames = @($generatedConfig.virtualMachines | ForEach-Object { "LS3-$($_.vmName)" })
    & $runnerPath -LocaleSet 3 -StartPhase 8 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null
    $resumeCapture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition ($resumeCapture.StartPhase -eq 8 -and $resumeCapture.ExpectedCompletedPhase -eq 11) -What 'resume run forwards start phase 8 and expected completion phase 11'

    $global:MemLabsStandaloneExistingVmNames = @('LS3-DC1')
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*Fresh test refused because target VM(s) already exist*' -What 'fresh run rejects an existing target VM'
    $global:MemLabsStandaloneExistingVmNames = @('LS3-DC1')
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -StartPhase 8 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*Resume from Phase 8 refused because target VM(s) are missing*' -What 'resume rejects missing target VMs'

    $global:MemLabsStandaloneExistingVmNames = @()
    $global:MemLabsStandaloneHostProductType = 3
    Assert-ThrowsLike -Action { & $runnerPath -LocaleSet 3 -OutputDirectory $outputRoot -DeploymentRunner $stubPath | Out-Null } -Pattern '*C: VM storage is supported only when the Hyper-V host runs Windows Client*' -What 'non-plan run rejects C drive storage on Windows Server'
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
    Assert-ThrowsLike -Action { & $runnerPath -Configuration $memoryPath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern '*requires exactly 40 GB configured VM memory*' -What 'plan rejects aggregate memory drift'

    $osConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    ($osConfig.virtualMachines | Where-Object vmName -eq 'CL1').operatingSystem = 'Server 2022'
    $osPath = Join-Path $fixtureRoot 'client-os.json'
    $osConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $osPath -Encoding UTF8
    Assert-ThrowsLike -Action { & $runnerPath -Configuration $osPath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern "*VM 'CL1' must be one visible DomainMember running Windows 11*" -What 'plan rejects client operating-system drift'

    $roleConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    ($roleConfig.virtualMachines | Where-Object vmName -eq 'FS1').role = 'DomainMember'
    $rolePath = Join-Path $fixtureRoot 'role.json'
    $roleConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $rolePath -Encoding UTF8
    Assert-ThrowsLike -Action { & $runnerPath -Configuration $rolePath -LocaleSet 1 -PlanOnly | Out-Null } -Pattern "*VM 'FS1' must be one visible FileServer running Server 2022*" -What 'plan rejects role drift'
}
finally {
    Remove-Item Env:\MEMLABS_STANDALONE_CAPTURE -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-CimInstance, Function:\Get-Command, Function:\Get-PSDrive, Function:\Get-VM -ErrorAction SilentlyContinue
    Remove-Variable MemLabsStandaloneHostProductType, MemLabsStandaloneExistingVmNames -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    [Console]::WriteLine("FAIL: Test-LocaleCmStandaloneRunner ($($script:Failures.Count) failure(s), $script:AssertionCount assertions)")
    $script:Failures | ForEach-Object { [Console]::WriteLine("  $_") }
    exit 1
}

[Console]::WriteLine("PASS: Test-LocaleCmStandaloneRunner ($script:AssertionCount assertions)")
exit 0