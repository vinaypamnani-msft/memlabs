<#
.SYNOPSIS
    Verifies domain-aware site lookup and null deployConfig fail-closed behavior.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'The production configuration generator reads the fixture context dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'common\Common.Config.ps1'
$genConfigPath = Join-Path $root 'common\Common.GenConfig.ps1'
$newLabPath = Join-Path $root 'New-Lab.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

$script:Inventory = @()
function Get-List {
    param([string] $Type, [string] $Domain, [string] $DomainName, [bool] $SmartUpdate)
    $wantedDomain = if ($Domain) { $Domain } else { $DomainName }
    @($script:Inventory | Where-Object { -not $wantedDomain -or $_.domain -ieq $wantedDomain })
}

. (Import-TestFunction -Path $configPath -Name 'Get-SiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-PrimarySiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-PassiveSiteServerForSiteCode')
. (Import-TestFunction -Path $configPath -Name 'Get-ActiveSiteServerForSiteCode')

$deployConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'client.test' }
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'CLIENT-PRI'; role = 'Primary'; siteCode = 'PRI'
        },
        [pscustomobject]@{
            vmName = 'SITE-PRI'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'CAS'
            domain = 'site.test'; hidden = $true
        },
        [pscustomobject]@{
            vmName = 'SITE-CAS'; role = 'CAS'; siteCode = 'CAS'; domain = 'site.test'; hidden = $true
        },
        [pscustomobject]@{
            vmName = 'SITE-PRI-P'; role = 'PassiveSite'; siteCode = 'PRI'; domain = 'site.test'; hidden = $true
        }
    )
}
$script:Inventory = @($deployConfig.virtualMachines)

Assert-Equal 'SITE-PRI' (Get-SiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware site lookup selected a same-code site in the client forest.'
Assert-Equal 'SITE-PRI' (Get-PrimarySiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware Primary lookup selected the wrong forest.'
Assert-Equal 'SITE-PRI-P' (Get-PassiveSiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware Passive lookup dropped a hidden remote support VM.'
Assert-Equal 'SITE-PRI' (Get-ActiveSiteServerForSiteCode -DeployConfig $deployConfig -SiteCode PRI `
        -DomainName site.test -Type Name) `
    'Domain-aware active-site lookup selected the wrong forest.'

$genConfigText = Get-Content -LiteralPath $genConfigPath -Raw
if ($genConfigText -notmatch '\$DomainName\s*=\s*if \(\$thisVM\.domain\)') {
    throw 'ConvertTo-DeployConfigEx does not derive the owning domain per VM.'
}
if ($genConfigText -notmatch '(?s)"SiteSystem".+?Get-SiteServerForSiteCode.+?-DomainName \$DomainName.+?Get-PassiveSiteServerForSiteCode.+?-DomainName \$DomainName') {
    throw 'SiteSystem generation does not propagate its owning domain to site lookups.'
}
$genTokens = $null
$genErrors = $null
$genAst = [Management.Automation.Language.Parser]::ParseFile(
    $genConfigPath, [ref]$genTokens, [ref]$genErrors)
if ($genErrors.Count) { throw "Common.GenConfig.ps1 has parse errors: $($genErrors -join '; ')" }
$siteLookupNames = @(
    'Get-SiteServerForSiteCode',
    'Get-PrimarySiteServerForSiteCode',
    'Get-PassiveSiteServerForSiteCode',
    'Get-ActiveSiteServerForSiteCode',
    'Get-SqlServerForSiteCode'
)
$unscopedSiteLookups = @($genAst.FindAll({
            param($node)
            if ($node -isnot [Management.Automation.Language.CommandAst] -or
                $node.GetCommandName() -notin $siteLookupNames) {
                return $false
            }
            return @($node.CommandElements | Where-Object {
                    $_ -is [Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'DomainName'
                }).Count -eq 0
        }, $true))
if ($unscopedSiteLookups.Count -gt 0) {
    throw "GenConfig still has unscoped site lookup(s): $(@($unscopedSiteLookups.Extent.Text) -join ' | ')"
}

& {
    . (Import-TestFunction -Path $genConfigPath -Name 'ConvertTo-DeployConfigEx')
    foreach ($name in @('Add-VMToAccountLists', 'get-RoleForSitecode')) {
        . (Import-TestFunction -Path $configPath -Name $name)
    }
    . (Import-TestFunction -Path (Join-Path $root 'common\Common.Phases.ps1') -Name 'Test-MemLabsIncludeHiddenVmForPhase')
    $routingFixture = @{ Config=$null; Logs=[Collections.Generic.List[string]]::new() }
    function Get-List {
        param($Type,$Domain,$DomainName,$SmartUpdate)
        $wanted = if ($Domain) { $Domain } else { $DomainName }
        @($routingFixture.Config.virtualMachines | Where-Object { -not $wanted -or -not $_.domain -or $_.domain -ieq $wanted })
    }
    function Get-List2 { param($DeployConfig) $DeployConfig.virtualMachines }
    function Get-VMFromList2 { param($DeployConfig,$VmName) $DeployConfig.virtualMachines | Where-Object vmName -eq $VmName }
    function Get-CMBaselineVersion { param($CMVersion) [pscustomobject]@{ baselineVersion='2509'; versions=@('2509') } }
    function Get-EligiblePushSites { param($Config,$Domain,$Inventory) }
    function Test-PushClientRequested { param($VM) $false }
    function Resolve-DeployUrlCatalog { param($AzureFileList) [pscustomobject]@{ Urls=[pscustomobject]@{}; Metadata=[pscustomobject]@{} } }
    function Write-Log { param($Message,[switch]$Warning,[switch]$LogOnly) $routingFixture.Logs.Add("$Message") }
    $Common=[pscustomobject]@{ AzureFileList=[pscustomobject]@{ Tools=@() } }
    $savedRoutingConfig=[pscustomobject]@{
        vmOptions=[pscustomobject]@{ domainName='lab.test'; domainNetBiosName='LAB'; network='192.0.2.0'; prefix='LAB-'; adminName='admin' }
        cmOptions=[pscustomobject]@{ Version='2509'; Install=$true }
        virtualMachines=@(
            [pscustomobject]@{ vmName='LAB-CAS'; role='CAS'; siteCode='CAS'; hidden=$false },
            [pscustomobject]@{ vmName='LAB-PRI'; role='Primary'; siteCode='PRI'; parentSiteCode='CAS'; hidden=$false },
            [pscustomobject]@{ vmName='LAB-PRI2'; role='Primary'; siteCode='PR2'; parentSiteCode='CAS'; hidden=$false },
            [pscustomobject]@{ vmName='LAB-SEC'; role='Secondary'; siteCode='SEC'; parentSiteCode='PRI'; hidden=$false }
        )
    } | ConvertTo-Json -Depth 5
    $expectedRouting=$null
    foreach ($marker in @('FreshVisible','InstalledNoRestore','RestoredPrePhase8','phase11Validate','UnmarkedSupport')) {
        $routingFixture.Config=$savedRoutingConfig | ConvertFrom-Json
        $isExisting=$marker -ne 'FreshVisible'
        foreach ($vm in $routingFixture.Config.virtualMachines) {
            $vm.hidden=$isExisting
            if ($marker -in @('InstalledNoRestore','RestoredPrePhase8')) {
                $vm | Add-Member NoteProperty pkiReconfigure $true
                $lastPhase = if ($marker -eq 'InstalledNoRestore') { 11 } else { 7 }
                $vm | Add-Member NoteProperty lastPhaseComplete $lastPhase
            }
            elseif ($marker -eq 'phase11Validate') { $vm | Add-Member NoteProperty phase11Validate $true }
        }
        $generated = ConvertTo-DeployConfigEx -deployConfig $routingFixture.Config
        $routing=@($generated.virtualMachines | Sort-Object vmName | Select-Object vmName,siteCode,parentSiteCode,
            @{Name='SiteServer';Expression={$_.thisParams.SiteServer}},
            @{Name='ParentSiteServer';Expression={$_.thisParams.ParentSiteServer}}) | ConvertTo-Json -Depth 3 -Compress
        if ($null -eq $expectedRouting) { $expectedRouting=$routing }
        else {
            Assert-Equal $expectedRouting $routing "$marker changed required setup routes for the same saved topology."
        }
        $primary = $generated.virtualMachines | Where-Object vmName -eq 'LAB-PRI'
        $secondary = $generated.virtualMachines | Where-Object vmName -eq 'LAB-SEC'
        Assert-Equal 'LAB-CAS' $primary.thisParams.ParentSiteServer "$marker hidden Primary lost required hierarchy setup routing."
        Assert-Equal 'LAB-CAS' ($generated.virtualMachines | Where-Object vmName -eq 'LAB-PRI2').thisParams.ParentSiteServer `
            "$marker second hidden Primary lost its independent CAS setup route."
        Assert-Equal 'LAB-PRI' $primary.thisParams.SiteServer "$marker hidden Primary lost its local site-owner metadata."
        Assert-Equal 'LAB-PRI' $secondary.thisParams.ParentSiteServer "$marker hidden Secondary lost its Primary receipt owner."
        Assert-Equal 'LAB-SEC' $secondary.thisParams.SiteServer "$marker hidden Secondary lost its own site-owner metadata."
        foreach ($vm in $generated.virtualMachines) {
            Assert-Equal $isExisting $vm.hidden 'Hierarchy routing changed rebuild protection.'
            foreach ($phase in @(1,10)) {
                Assert-Equal (-not $isExisting) (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase $phase) 'Hierarchy metadata changed existing-VM rebuild/mutation phase protection.'
            }
        }
    }
    $routingFixture.Config.virtualMachines = @($routingFixture.Config.virtualMachines | Where-Object vmName -ne 'LAB-CAS')
    $caught=$null
    try { $null = ConvertTo-DeployConfigEx -deployConfig $routingFixture.Config } catch { $caught=$_ }
    if (-not $caught -or $caught.Exception.Message -notmatch 'LAB-PRI.*parent.*CAS.*lab\.test') {
        throw 'Missing hierarchy parent did not fail configuration generation with its child/site/domain context.'
    }
}

$newLabText = Get-Content -LiteralPath $newLabPath -Raw
$nullGuard = $newLabText.IndexOf('Configuration validation did not produce a deployConfig', [StringComparison]::Ordinal)
$deployUse = $newLabText.IndexOf('foreach ($vm in $deployConfig.virtualMachines)', [StringComparison]::Ordinal)
if ($nullGuard -lt 0 -or $deployUse -lt 0 -or $nullGuard -gt $deployUse) {
    throw 'New-Lab can consume a null deployConfig after validation.'
}
if ($newLabText -notmatch 'Continue anyway\? \(y/N\).+?-Default "n"') {
    throw 'Validation bypass still defaults to continuing after timeout.'
}

Write-Host 'PASS -- cross-forest site lookup is domain-aware and null validation results fail closed.'
