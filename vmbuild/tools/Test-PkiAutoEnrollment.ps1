#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
. (Import-TestFunction (Join-Path $root 'common\Common.ScriptBlocks.ps1') 'Invoke-MemLabsClientCertificateReadiness')
foreach ($name in @('Initialize-PKIMemberCertificates', 'Install-PKI')) {
    . (Import-TestFunction (Join-Path $root 'common\Common.PKI.ps1') $name)
}
function Get-MemLabsClientCertificateReadinessBlock { { throw 'Fixture must not execute guest commands locally.' } }
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Messages = [Collections.Generic.List[string]]::new()
$script:Failures = [Collections.Generic.List[string]]::new()
$script:Mode = 'Ready'
$script:CaReady = $true; $script:SingleCalls = 0; $script:TwoCalls = 0
function Write-Log {
    param($Message, [switch]$Failure, [switch]$LogOnly)
    $script:Messages.Add("$Message")
    if ($Failure) { $script:Failures.Add("$Message") }
}
function Install-SingleTierPKI { param($DeployConfig) $script:SingleCalls++; $script:CaReady }
function Install-TwoTierPKI { param($DeployConfig) $script:TwoCalls++; $script:CaReady }
function Invoke-VmCommand {
    param($VmName, $VmDomainName, [switch]$AsJob, $TimeoutSeconds,
        [switch]$SuppressLog, $DisplayName, $ScriptBlock)
    Assert-True ($VmDomainName -eq 'lab.test' -and $AsJob -and $TimeoutSeconds -eq 120) `
        'Autoenrollment changed its domain or bounded guest-probe contract.'
    $script:Calls.Add("$VmName")
    if ($script:Mode -eq 'Transport' -and $VmName -eq 'OPT-OUT') { throw 'fixture transport failure' }
    if ($script:Mode -eq 'Missing' -and $VmName -eq 'OPT-OUT') { return $null }
    $ready = -not ($script:Mode -eq 'Unready' -and $VmName -eq 'OPT-OUT')
    $state = [pscustomobject]@{
        Ready = $ready; CertFound = $ready; ChainOk = $ready
        ChainStatus = 'fixture'; Thumbprint = 'fixture'
        Diagnostics = @('AEPolicy at probe start=7')
    }
    if ($script:Mode -eq 'StringReady' -and $VmName -eq 'OPT-OUT') { $state.Ready = 'true' }
    if ($script:Mode -eq 'Inconsistent' -and $VmName -eq 'OPT-OUT') { $state.ChainOk = $false }
    $output = $state
    if ($script:Mode -eq 'Multiple' -and $VmName -eq 'OPT-OUT') { $output = @($state, $state) }
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output }
}
function Reset-Fixture {
    $script:Calls.Clear(); $script:Messages.Clear(); $script:Failures.Clear()
    $script:Mode = 'Ready'; $script:CaReady = $true
    $script:SingleCalls = 0; $script:TwoCalls = 0
}
$ca = [pscustomobject]@{ vmName = 'CA'; role = 'DC'; InstallCA = $true; UseOfflineRoot = $false }
$config = [pscustomobject]@{
    vmOptions = @{ domainName = 'lab.test' }
    virtualMachines = @(
        $ca,
        [pscustomobject]@{ vmName = 'OPT-IN'; role = 'DomainMember'; pushClient = $true },
        [pscustomobject]@{ vmName = 'OPT-OUT'; role = 'DomainMember'; pushClient = $false },
        [pscustomobject]@{ vmName = 'SITE'; role = 'SiteSystem'; domain = 'lab.test'; pushClient = $false },
        [pscustomobject]@{ vmName = 'SQL'; role = 'SQLAO'; pushClient = $false },
        [pscustomobject]@{ vmName = 'OLD'; role = 'DomainMember'; hidden = $true; pushClient = $true },
        [pscustomobject]@{ vmName = 'WORKGROUP'; role = 'WorkgroupMember' },
        [pscustomobject]@{ vmName = 'ROOT'; role = 'StandaloneRootCA' },
        [pscustomobject]@{ vmName = 'BDC'; role = 'BDC' }
    )
}
foreach ($offlineRoot in @($false, $true)) {
    Reset-Fixture
    $ca.UseOfflineRoot = $offlineRoot
    $output = @(Install-PKI -DeployConfig $config)
    Assert-True ($output.Count -eq 1 -and $output[0] -is [bool] -and $output[0]) `
        'Completed PKI deployment did not return one successful Boolean.'
    Assert-True (($script:Calls -join ',') -eq 'OPT-IN,OPT-OUT,SITE,SQL') `
        'Post-CA autoenrollment missed an opted-out member or included a hidden/workgroup/DC/offline-root VM.'
    Assert-True ($script:SingleCalls -eq [int](-not $offlineRoot) -and $script:TwoCalls -eq [int]$offlineRoot) `
        'Autoenrollment changed single-tier/two-tier dispatch.'
}
Reset-Fixture
$script:CaReady = $false
Assert-True (-not (Install-PKI -DeployConfig $config) -and $script:Calls.Count -eq 0) `
    'Member autoenrollment ran before CA/template provisioning succeeded.'
foreach ($failureMode in @('Unready', 'Transport', 'Missing', 'StringReady', 'Inconsistent', 'Multiple')) {
    Reset-Fixture
    $script:Mode = $failureMode
    $output = @(Install-PKI -DeployConfig $config)
    Assert-True ($output.Count -eq 1 -and $output[0] -is [bool] -and -not $output[0] -and
        ($script:Calls -join ',') -eq 'OPT-IN,OPT-OUT,SITE,SQL') `
        "$failureMode enrollment failure was ignored or prevented independent member checks."
    Assert-True ($script:Failures.Count -gt 0 -and ($script:Failures -join ' ') -match 'OPT-OUT') `
        "$failureMode enrollment failure lost its target and explicit failure diagnostics."
    if ($failureMode -eq 'Unready') {
        Assert-True (($script:Messages -join ' ') -match 'AEPolicy at probe start=7') `
            'Autoenrollment policy evidence was not surfaced on failure.'
    }
}
Reset-Fixture
$noMembers = [pscustomobject]@{ vmOptions = $config.vmOptions; virtualMachines = @($ca) }
Assert-True ((Install-PKI -DeployConfig $noMembers) -and $script:Calls.Count -eq 0) `
    'A CA-only deployment attempted member enrollment.'

$dcPath = Join-Path $root 'DSC\phases\Phase2DC.ps1'
$dcText = [IO.File]::ReadAllText($dcPath)
Assert-True ($dcText -match 'ValueName\s*=\s*"AEPolicy"[\s\S]{0,100}Value\s*=\s*"7"') `
    'Domain-wide computer autoenrollment policy is no longer enabled.'
$tokens = $null; $errors = $null
$launcherAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'New-Lab.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "New-Lab.ps1 has parse errors: $($errors -join '; ')" }
$postPhaseThree = @($launcherAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$i -eq 3' -and $node.Extent.Text -match 'Install-PKI'
        }, $true))
Assert-True ($postPhaseThree.Count -eq 1) 'PKI must run after Phase 3 domain join/policy readiness.'
Write-Host 'PASS -- CA provisioning is followed by verified autoenrollment for new Windows members, independent of client push.'
