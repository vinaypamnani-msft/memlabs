<#
.SYNOPSIS
    Guards client-push site resolution for add-to-existing deployments.
#>
[CmdletBinding()]
param([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$genConfigPath = Join-Path $RootPath 'common\Common.GenConfig.ps1'
$guestFunctionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$script:Failures = 0

function Assert-ClientPush {
    param([bool] $Condition, [string] $Description)

    if ($Condition) { Write-Host "PASS  $Description" }
    else { Write-Host "FAIL  $Description"; $script:Failures++ }
}

function Import-ClientPushFunction {
    param(
        [string] $Name,
        [string] $Path = $configPath
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-ClientPushFunction -Name 'Get-EligiblePushSites')
. (Import-ClientPushFunction -Name 'Test-PushClientRequested')
. (Import-ClientPushFunction -Name 'Resolve-PushClientSite')
. (Import-ClientPushFunction -Name 'Update-VMFromHyperV')

function Get-VMDeployedNetwork { throw 'inventory snapshot should prevent a deployed-network lookup' }
function Get-ExistingSiteServer { throw 'inventory snapshot should prevent a second site lookup' }
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Warning) }

$config = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{
        domainName = 'cstest1.com'
        network    = '192.168.11.0'
    }
    virtualMachines = @(
        [pscustomobject]@{
            vmName  = 'CT1-PS2SITE'
            role    = 'Primary'
            siteCode = 'PS2'
            network = '192.168.11.0'
        }
        [pscustomobject]@{
            vmName  = 'CT1-PS1SITE'
            role    = 'Primary'
            siteCode = 'PS1'
            hidden  = $true
        }
    )
}
$inventory = @(
    [pscustomobject]@{
        vmName = 'CT1-PS2SITE'; role = 'Primary'; siteCode = 'PS2'
        network = '192.168.99.0'; pushClient = $false
    }
    [pscustomobject]@{
        vmName = 'CT1-PS1SITE'; role = 'Primary'; siteCode = 'PS1'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-W10Client1'; role = 'DomainMember'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-W11Client2'; role = 'DomainMember'
        network = '192.168.10.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-DPMP1'; role = 'SiteSystem'
        network = '192.168.11.0'; pushClient = $true
    }
    [pscustomobject]@{
        vmName = 'CT1-RemoteClient'; role = 'DomainMember'
        network = '172.16.1.0'; pushClient = 'PS1'
    }
    [pscustomobject]@{
        vmName = 'CT1-LegacyCAS'; role = 'CAS'; siteCode = 'LC1'
        network = '192.168.20.0'
    }
)

$eligible = @(Get-EligiblePushSites -Config $config -Domain 'cstest1.com' -Inventory $inventory)
Assert-ClientPush ($eligible.Count -eq 2) 'eligible sites merge new config and deployed inventory'
Assert-ClientPush (@($eligible | Where-Object { $_.SiteCode -eq 'PS1' -and $_.Network -eq '192.168.10.0' }).Count -eq 1) `
    'existing PS1 Primary retains ownership of its deployed subnet'
Assert-ClientPush (@($eligible | Where-Object { $_.SiteCode -eq 'PS2' -and $_.Network -eq '192.168.11.0' }).Count -eq 1) `
    'new PS2 config entry wins over a stale inventory duplicate'

$w10 = $inventory | Where-Object vmName -eq 'CT1-W10Client1'
$w11 = $inventory | Where-Object vmName -eq 'CT1-W11Client2'
$oldDp = $inventory | Where-Object vmName -eq 'CT1-DPMP1'
$remoteClient = $inventory | Where-Object vmName -eq 'CT1-RemoteClient'
$legacySiteServer = $inventory | Where-Object vmName -eq 'CT1-LegacyCAS'
Assert-ClientPush ((Resolve-PushClientSite -VM $w10 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 10 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $w11 -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'main-era Windows 11 client remains assigned to PS1'
Assert-ClientPush ((Resolve-PushClientSite -VM $oldDp -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS2') `
    'existing site system on the new PS2 subnet resolves to PS2'
Assert-ClientPush ((Resolve-PushClientSite -VM $remoteClient -Config $config -Domain 'cstest1.com' -EligibleSites $eligible) -eq 'PS1') `
    'explicit PS1 client on a standalone subnet retains PS1 for boundary generation'
Assert-ClientPush (-not (Test-PushClientRequested -VM $legacySiteServer)) `
    'legacy site server with missing pushClient is opted out'
Assert-ClientPush (-not (Resolve-PushClientSite -VM $legacySiteServer -Config $config -Domain 'cstest1.com' -EligibleSites $eligible)) `
    'missing pushClient never auto-resolves to a site'
Assert-ClientPush (Test-PushClientRequested -VM $w10) 'boolean true explicitly requests client push'
Assert-ClientPush (Test-PushClientRequested -VM $remoteClient) 'site-code string explicitly requests client push'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = $false }))) `
    'boolean false opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = $null }))) `
    'null pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = '' }))) `
    'empty pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = '   ' }))) `
    'whitespace pushClient opts out'
Assert-ClientPush (-not (Test-PushClientRequested -VM ([pscustomobject]@{ pushClient = 1 }))) `
    'non-Boolean non-string pushClient opts out'

$global:vm_List = @()
$legacyVm = [pscustomobject]@{ State = 'Running' }
$legacyProjection = [pscustomobject]@{ Memory = 4GB }
$legacyNote = [pscustomobject]@{ vmName = 'CT1-OLD-CS1'; role = 'CAS' }
Update-VMFromHyperV -vm $legacyVm -vmObject $legacyProjection -vmNoteObject $legacyNote
Assert-ClientPush (($legacyProjection.PSObject.Properties.Name -contains 'pushClient') -and
    $legacyProjection.pushClient -eq $false) 'exact-main site-system note materializes missing pushClient as false'

$explicitProjection = [pscustomobject]@{ Memory = 4GB }
$explicitNote = [pscustomobject]@{ vmName = 'CT1-OLD-CLIENT'; role = 'DomainMember'; pushClient = 'PS1' }
Update-VMFromHyperV -vm $legacyVm -vmObject $explicitProjection -vmNoteObject $explicitNote
Assert-ClientPush ($explicitProjection.pushClient -eq 'PS1') 'exact-main note preserves explicit target site code'

$numericProjection = [pscustomobject]@{ Memory = 4GB; network = '10.12.3.0' }
$numericNote = [pscustomobject]@{
    vmName = 'CT1-NUMERIC-PRIMARY'; role = 'Primary'; siteCode = '123'; pushClient = '123'
}
Update-VMFromHyperV -vm $legacyVm -vmObject $numericProjection -vmNoteObject $numericNote
Assert-ClientPush (($numericProjection.pushClient -is [string]) -and $numericProjection.pushClient -eq '123') `
    'exact-main note preserves numeric target site code as a string'
Assert-ClientPush (($numericProjection.siteCode -is [string]) -and $numericProjection.siteCode -eq '123') `
    'exact-main note preserves numeric siteCode as a string'

$leadingZeroProjection = [pscustomobject]@{ Memory = 4GB; network = '10.0.1.0' }
$leadingZeroNote = [pscustomobject]@{
    vmName = 'CT1-ZERO-SECONDARY'; role = 'Secondary'; siteCode = '001'
    parentSiteCode = '123'; pushClient = '001'
}
Update-VMFromHyperV -vm $legacyVm -vmObject $leadingZeroProjection -vmNoteObject $leadingZeroNote
Assert-ClientPush (($leadingZeroProjection.pushClient -is [string]) -and $leadingZeroProjection.pushClient -eq '001') `
    'exact-main note preserves leading-zero target site code'
Assert-ClientPush (($leadingZeroProjection.siteCode -is [string]) -and $leadingZeroProjection.siteCode -eq '001') `
    'exact-main note preserves leading-zero siteCode'
Assert-ClientPush (($leadingZeroProjection.parentSiteCode -is [string]) -and $leadingZeroProjection.parentSiteCode -eq '123') `
    'exact-main note preserves numeric parentSiteCode as a string'

$numericConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'numeric.test'; network = '10.12.3.0' }
    virtualMachines = @()
}
$numericEligible = @(Get-EligiblePushSites -Config $numericConfig -Domain 'numeric.test' -Inventory @(
        $numericProjection, $leadingZeroProjection
    ))
Assert-ClientPush (@($numericEligible | Where-Object SiteCode -eq '123').Count -eq 1 `
    -and @($numericEligible | Where-Object SiteCode -eq '001').Count -eq 1) `
    'hydrated numeric site inventory remains eligible without type errors'
Assert-ClientPush ((Resolve-PushClientSite -VM $numericProjection -Config $config -Domain 'cstest1.com' -EligibleSites $numericEligible) -eq '123') `
    'numeric target site code remains explicitly selected'
Assert-ClientPush ((Resolve-PushClientSite -VM $leadingZeroProjection -Config $numericConfig -Domain 'numeric.test' -EligibleSites $numericEligible) -eq '001') `
    'leading-zero target site code remains explicitly selected'

$hostCases = @(
    [pscustomobject]@{ pushClient = $true },
    [pscustomobject]@{ pushClient = $false },
    [pscustomobject]@{ pushClient = 'PS1' },
    [pscustomobject]@{ pushClient = '' },
    [pscustomobject]@{}
)
$hostResults = @($hostCases | ForEach-Object { Test-PushClientRequested -VM $_ })
. (Import-ClientPushFunction -Name 'Test-PushClientRequested' -Path $guestFunctionsPath)
$guestResults = @($hostCases | ForEach-Object { Test-PushClientRequested -VM $_ })
Assert-ClientPush (($hostResults -join ',') -eq ($guestResults -join ',')) `
    'guest and host pushClient predicates have identical behavior'

$genConfigText = [IO.File]::ReadAllText($genConfigPath)
Assert-ClientPush ($genConfigText -match '\$pushInventory\s*=\s*@\(get-list2 -DeployConfig \$deployConfig\)') `
    'generator resolves one shared client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$pushInventory') `
    'eligible sites use the same inventory snapshot as client candidates'
Assert-ClientPush ($genConfigText -match '\$ClientNames\s*=\s*\$pushInventory') `
    'client candidates use the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match '\$_.role -in \$pushableRoles -and \(Test-PushClientRequested -VM \$_\)') `
    'client candidates require explicit pushClient opt-in'
Assert-ClientPush ($genConfigText -match '\$siteInventory\s*=\s*if \(\$thisVM\.Role -eq "Primary".+\$pushInventory') `
    'Primary boundary generation reuses the client-push inventory snapshot'
Assert-ClientPush ($genConfigText -match 'Get-EligiblePushSites -Config \$deployConfig -Domain \$DomainName -Inventory \$siteInventory') `
    'boundary site resolution uses the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match 'foreach \(\$vm in \$siteInventory \| Where-Object \{ \$_.role -in \$bgPushableRoles') `
    'boundary client candidates use the shared inventory snapshot'
Assert-ClientPush ($genConfigText -match '\$_.role -in \$bgPushableRoles -and \(Test-PushClientRequested -VM \$_\)') `
    'boundary candidates require explicit pushClient opt-in'

. (Import-ClientPushFunction -Name 'Disable-MemLabsAutomaticClientPush' -Path $guestFunctionsPath)
$script:AutomaticPush = @{ PS1 = $true; PS2 = $true }
$script:PolicyCalls = 0
$script:PolicyFailure = $false
$script:PolicyFailures = @()
$script:PushAccounts = @('existing-account')
function Set-CMClientPushInstallation {
    [CmdletBinding()]
    param([string]$SiteCode, [bool]$EnableAutomaticClientPushInstallation, [string[]]$AddAccount)

    $script:PolicyCalls++
    if (-not $PSBoundParameters.ContainsKey('EnableAutomaticClientPushInstallation') -or
        $EnableAutomaticClientPushInstallation -or -not $PSBoundParameters.ContainsKey('ErrorAction') -or
        "$($PSBoundParameters.ErrorAction)" -ne 'Stop' -or
        $PSBoundParameters.ContainsKey('AddAccount')) {
        throw 'Client-push policy must disable automatic push without changing accounts and must fail on cmdlet errors.'
    }
    if ($script:PolicyFailure) { throw 'fixture provider rejected policy change' }
    $script:AutomaticPush[$SiteCode] = $false
}
function Write-StatusLogEntry {
    param([Parameter(ValueFromPipeline)]$Message)
    process {}
}
function Write-DscStatus {
    param($Status, [switch]$Failure, [switch]$Warning, [switch]$NoStatus)
    if ($Failure) { $script:PolicyFailures += "$Status" }
    if (-not $NoStatus) {
        $script:LastPushStatus = if ($Failure) { "JOBFAILURE: $Status" } else { "$Status" }
    }
}
$policyResult = @(Disable-MemLabsAutomaticClientPush -SiteCode PS1)
Assert-ClientPush ($policyResult.Count -eq 1 -and $policyResult[0] -is [bool] -and $policyResult[0]) `
    'automatic-push policy returns one successful Boolean result'
Assert-ClientPush (-not $script:AutomaticPush.PS1 -and $script:AutomaticPush.PS2 -and
    ($script:PushAccounts -join ',') -eq 'existing-account') `
    'policy disables only the selected site and preserves existing push credentials'
Assert-ClientPush (Disable-MemLabsAutomaticClientPush -SiteCode PS1) 'policy is reapplied on redeploy with an existing account'
$script:AutomaticPush.PS1 = $true
$script:PolicyFailure = $true
Assert-ClientPush (-not (Disable-MemLabsAutomaticClientPush -SiteCode PS1)) 'failed policy update fails closed'
Assert-ClientPush ($script:AutomaticPush.PS1 -and $script:PolicyFailures.Count -eq 1 -and
    $script:PolicyFailures[0] -match 'fixture provider rejected policy change') `
    'policy failure retains provider diagnostics and is reported as a deployment failure'
$script:PolicyFailure = $false

foreach ($policyConsumer in @(
        @{ Path = 'DSC\phases\ScriptWorkFlow.ps1'; Count = 2; Site = '$SiteCode' },
        @{ Path = 'DSC\phases\InstallBoundaryGroups.ps1'; Count = 1; Site = '$SiteCode' },
        @{ Path = 'DSC\phases\PushClients.ps1'; Count = 1; Site = '$SiteCode' },
        @{ Path = 'DSC\phases\InstallMultiDomainPKI.ps1'; Count = 1; Site = '$Externaldomainsitecode' }
    )) {
    $tokens = $null; $errors = $null
    $consumerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RootPath $policyConsumer.Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$($policyConsumer.Path) has parse errors: $($errors -join '; ')" }
    if ($policyConsumer.Path -eq 'DSC\phases\ScriptWorkFlow.ps1') { $workflowAst = $consumerAst }
    $guards = @($consumerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -match '^-not \(Disable-MemLabsAutomaticClientPush '
            }, $true))
    Assert-ClientPush ($guards.Count -eq $policyConsumer.Count) "$($policyConsumer.Path) guards automatic-push policy"
    foreach ($guard in $guards) {
        Assert-ClientPush ($guard.Clauses[0].Item1.Extent.Text -like "*-SiteCode $($policyConsumer.Site)*" -and
            $guard.Clauses[0].Item2.Statements.Count -eq 1 -and
            $guard.Clauses[0].Item2.Statements[0] -is [Management.Automation.Language.ReturnStatementAst]) `
            "$($policyConsumer.Path) stops before discovery/push if its owned site's policy cannot be enforced"
        $gate = [scriptblock]::Create($guard.Extent.Text + "`n`$script:GuardPassed++")
        $SiteCode = 'PS1'; $script:Externaldomainsitecode = 'PS2'
        $script:PolicyFailure = $true; $script:GuardPassed = 0
        & $gate
        Assert-ClientPush ($script:GuardPassed -eq 0) "$($policyConsumer.Path) does not execute dependent work after policy failure"
        $script:PolicyFailure = $false
        & $gate
        Assert-ClientPush ($script:GuardPassed -eq 1) "$($policyConsumer.Path) advances after policy success"
        $nextAction = $consumerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Set-CMDiscoveryMethod', 'New-CMActiveDirectoryForest', 'Install-CMClient') -and
                $node.Extent.StartOffset -gt $guard.Extent.EndOffset
            }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        Assert-ClientPush ($null -ne $nextAction) "$($policyConsumer.Path) enforces policy before discovery or individual push"
    }
    foreach ($command in @($consumerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Set-CMClientPushInstallation'
            }, $true))) {
        Assert-ClientPush ($command.Extent.Text -notmatch '-EnableAutomaticClientPushInstallation\s+\$true') `
            "$($policyConsumer.Path) never re-enables automatic push while configuring accounts"
    }
    if ($policyConsumer.Path -eq 'DSC\phases\InstallBoundaryGroups.ps1') {
        $casGuards = @($consumerAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.IfStatementAst] -and
                        $node.Clauses[0].Item1.Extent.Text -eq "`$ThisVM.role -ne 'CAS'" -and
                        $node.Extent.Text -match 'Disable-MemLabsAutomaticClientPush'
                }, $true))
        Assert-ClientPush ($casGuards.Count -eq 1) 'boundary setup does not configure automatic push on a CAS'
        if ($casGuards.Count -eq 1) {
            $script:ThisVM = [pscustomobject]@{ role = 'CAS' }; $SiteCode = 'CAS'
            $before = $script:PolicyCalls
            & ([scriptblock]::Create($casGuards[0].Extent.Text))
            Assert-ClientPush ($script:PolicyCalls -eq $before) 'CAS boundary setup executes no client-push policy mutation'
        }
    }
}

$externalSelection = $consumerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$externalClients'
}, $true)
$externalBlocks = @($consumerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$externalClients.Count -gt 0'
        }, $true))
Assert-ClientPush ($externalBlocks.Count -eq 1 -and $null -ne $externalSelection) 'external push fixture executes the real per-VM selection and delivery block'
$externalCompletion = @($consumerAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$Configuration.InstallClient.Status'
    })
Assert-ClientPush ($externalCompletion.Count -eq 1) 'external push fixture uses the actual completed-state assignment'
$externalDelivery = [scriptblock]::Create($externalSelection.Extent.Text + "`n" +
    $externalBlocks[0].Extent.Text + "`n" + $externalCompletion[0].Extent.Text)
$tokens = $null; $errors = $null
$primaryAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'DSC\phases\PushClients.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "PushClients.ps1 has parse errors: $($errors -join '; ')" }
$primaryLoops = @($primaryAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
                $node.Variable.Extent.Text -eq '$client' -and $node.Condition.Extent.Text -eq '$ClientNameList'
        }, $true))
Assert-ClientPush ($primaryLoops.Count -eq 1) 'primary push fixture executes the real individual target loop'
$primaryTry = $primaryLoops[0].Parent.Parent
Assert-ClientPush ($primaryTry -is [Management.Automation.Language.TryStatementAst]) 'primary push retains its bounded retry handler'
$primaryBudget = @($primaryTry.Body.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -in @('$discoveryBudgetMinutes', '$discoveryDeadline', '$lastDiscoveryRun')
    })
$primaryCompletion = @($primaryAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$Configuration.InstallClient.Status'
    })
Assert-ClientPush ($primaryBudget.Count -eq 3 -and $primaryCompletion.Count -eq 1) `
    'primary push fixture uses the actual discovery budget and completed-state assignment'
$primaryDelivery = [scriptblock]::Create("try {`n" + ($primaryBudget.Extent.Text -join "`n") + "`n" +
    $primaryLoops[0].Extent.Text + "`n}`n" + ($primaryTry.CatchClauses.Extent.Text -join "`n") +
    "`n" + $primaryCompletion[0].Extent.Text)

$script:deployConfig = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'OPT-IN'; Role = 'DomainMember'; pushClient = $true; ThisParams = @{ vmNetwork = '192.0.2.0' } },
        [pscustomobject]@{ vmName = 'OPT-OUT'; Role = 'DomainMember'; pushClient = $false; ThisParams = @{ vmNetwork = '192.0.2.0' } },
        [pscustomobject]@{ vmName = 'SITE-OPT-IN'; Role = 'DomainMember'; pushClient = 'PS1'; ThisParams = @{ vmNetwork = '192.0.2.0' } }
    )
}
$script:networks = @('192.0.2.0'); $script:Externaldomainsitecode = 'PS1'
function Reset-PushFixture {
    $script:Clock = [datetime]'2026-11-05T12:00:00'
    $script:Discovered = @('OPT-IN', 'OPT-OUT', 'SITE-OPT-IN')
    $script:QueryFailure = $false; $script:InstallFailure = $false; $script:SmbAvailable = $true
    $script:SetupRunning = $false
    $script:DeliveryCalls = [System.Collections.Generic.List[string]]::new()
    $script:PolicyFailures = @()
    $script:Configuration = @{ InstallClient = @{ Status = 'Running' } }
    $script:ClientNameList = @('OPT-IN', 'SITE-OPT-IN')
    $script:installedmachinelist = @(); $script:machinelist = $script:Discovered
    $script:clientIndex = 0; $script:CollectionName = 'All Systems'; $script:SiteCode = 'PS1'
    $script:pushAttempt = 2; $script:pushMaxAttempts = 2
}
function Get-CMDevice {
    [CmdletBinding()]
    param($CollectionName, $Name)
    if ($script:QueryFailure) { throw 'fixture device query failed' }
    if ($Name) { [pscustomobject]@{ Name = $Name; IsClient = $false } }
    else { $script:Discovered | ForEach-Object { [pscustomobject]@{ Name = $_; IsClient = $false } } }
}
function Install-CMClient {
    [CmdletBinding()]
    param($DeviceName, $SiteCode, [bool]$AlwaysInstallClient)
    if (-not $PSBoundParameters.ContainsKey('ErrorAction') -or "$($PSBoundParameters.ErrorAction)" -ne 'Stop') {
        throw 'Client-push requests must promote cmdlet failures into their retry/error handlers.'
    }
    $script:DeliveryCalls.Add("$DeviceName")
    if ($script:InstallFailure) { throw 'fixture client push rejected' }
}
function Invoke-CMForestDiscovery { [CmdletBinding()]param($SiteCode) }
function Invoke-CMSystemDiscovery { [CmdletBinding()]param() }
function Invoke-CMDeviceCollectionUpdate { [CmdletBinding()]param($Name) }
function Start-Sleep { param($Seconds) $script:Clock = $script:Clock.AddSeconds($Seconds) }
function Get-Date { $script:Clock }
function Test-TcpPortFast { param($ComputerName, $Port) $script:SmbAvailable }
function Test-RemoteCMClientInstalled { param($ComputerName) $false }
function Invoke-Command {
    [CmdletBinding()]
    param($ComputerName, $ScriptBlock)
    if ($script:SetupRunning) { [pscustomobject]@{ Id = 1234 } }
}
foreach ($delivery in @($externalDelivery, $primaryDelivery)) {
    Reset-PushFixture
    & $delivery
    Assert-ClientPush (($script:DeliveryCalls -join ',') -eq 'OPT-IN,SITE-OPT-IN' -and
        $script:Configuration.InstallClient.Status -eq 'Completed' -and $script:PolicyFailures.Count -eq 0) `
        'individual pushes reach only explicitly requested targets and preserve asynchronous installation'
}
Reset-PushFixture
$script:QueryFailure = $true
& $externalDelivery
Assert-ClientPush ($script:DeliveryCalls.Count -eq 0 -and $script:PolicyFailures.Count -gt 0 -and
    $script:Configuration.InstallClient.Status -ne 'Completed') 'unreadable external discovery cannot report completed push or rely on automatic push'
Assert-ClientPush (($script:Clock - [datetime]'2026-11-05T12:00:00').TotalSeconds -eq 900) `
    'external discovery retains one shared 900-second budget'
foreach ($delivery in @($externalDelivery, $primaryDelivery)) {
    Reset-PushFixture
    $script:Discovered = @(); $script:machinelist = @()
    & $delivery
    Assert-ClientPush ($script:DeliveryCalls.Count -eq 0 -and $script:PolicyFailures.Count -gt 0 -and
        $script:Configuration.InstallClient.Status -ne 'Completed') 'undiscovered requested clients fail without false completion'
    $expectedSeconds = if ($delivery -eq $externalDelivery) { 900 } else { 1200 }
    Assert-ClientPush (($script:Clock - [datetime]'2026-11-05T12:00:00').TotalSeconds -eq $expectedSeconds) `
        'discovery failure occurs at the real shared budget rather than a per-target or unbounded wait'
    Reset-PushFixture
    $script:InstallFailure = $true
    & $delivery
    Assert-ClientPush ($script:PolicyFailures.Count -gt 0 -and
        ($script:PolicyFailures -join ' ') -match 'fixture client push rejected' -and
        $script:Configuration.InstallClient.Status -ne 'Completed') 'rejected individual push preserves error evidence and does not complete the stage'
}
Reset-PushFixture
$script:SmbAvailable = $false
& $primaryDelivery
Assert-ClientPush ($script:DeliveryCalls.Count -eq 0 -and $script:PolicyFailures.Count -gt 0 -and
    $script:Configuration.InstallClient.Status -ne 'Completed') 'unreachable SMB target cannot silently complete an individual push'
Reset-PushFixture
$script:SetupRunning = $true
& $primaryDelivery
Assert-ClientPush ($script:DeliveryCalls.Count -eq 0 -and
    $script:Configuration.InstallClient.Status -eq 'Completed') 'in-flight ccmsetup is preserved without a competing push'

$ownerTry = @($workflowAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
                $node.CatchClauses.Extent.Text -match 'PushClients.ps1 failed'
        }, $true))
Assert-ClientPush ($ownerTry.Count -eq 1) 'workflow has one owner for client-push failure'
$owner = [scriptblock]::Create($ownerTry[0].Extent.Text + "`n`$script:OwnerCompleted = `$true")
function Set-Location { param($Path) }
function Invoke-DotSource {
    param($Script, $Arguments)
    if ($script:OwnerFailure) {
        Write-DscStatus 'fixture critical push failure' -Failure
        throw 'fixture critical push failure'
    }
}
$script:LogPath = $RootPath
foreach ($fatal in @($false, $true)) {
    Reset-PushFixture
    $script:OwnerFailure = $fatal; $script:OwnerCompleted = $false
    $caught = $false
    try { & $owner } catch { $caught = $true }
    Assert-ClientPush ($caught -eq $fatal -and $script:OwnerCompleted -eq (-not $fatal)) `
        'workflow preserves nonfatal completion but propagates critical push failure to its receipt-writing trap'
    if ($fatal) {
        Assert-ClientPush ($script:LastPushStatus -like 'JOBFAILURE:*') 'workflow does not overwrite the reachable push failure with a warning'
    }
}

foreach ($consumerPath in @(
        'common\Common.Config.ps1',
        'common\Common.GenConfig.ps1',
        'common\Common.Phases.ps1',
        'common\Common.Validation.Functional.ps1',
        'DSC\phases\InstallBoundaryGroups.ps1',
        'DSC\phases\InstallMultiDomainPKI.ps1',
        'DSC\phases\perfloading.ps1'
    )) {
    $consumerText = [IO.File]::ReadAllText((Join-Path $RootPath $consumerPath))
    Assert-ClientPush ($consumerText -notmatch 'pushClient\s*-ne\s*\$false') `
        "$consumerPath has no fail-open pushClient comparison"
}

if ($script:Failures -gt 0) {
    throw "$script:Failures client-push site-resolution assertion(s) failed."
}

Write-Host 'PASS: client-push site resolution preserves existing subnet ownership.'
