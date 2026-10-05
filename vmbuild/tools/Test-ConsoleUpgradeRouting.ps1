<#
.SYNOPSIS
    Guards console-upgrade routing, failure semantics, and Phase 11 validation.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$failures = 0

function Assert-ConsoleUpgrade {
    param([bool] $Condition, [string] $Description)
    if ($Condition) { Write-Host "PASS  $Description" }
    else { Write-Host "FAIL  $Description"; $script:failures++ }
}

function Import-ConsoleUpgradeFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name function in $Path, found $($definition.Count)" }
    return $definition[0].Extent.Text
}

$fixPath = Join-Path $RootPath 'Fixes\Fix-Upgrade-Console.ps1'
$upgradePath = Join-Path $RootPath 'DSC\phases\Upgrade-Console.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$phaseJobsPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$paths = @($fixPath, $upgradePath, $validationPath, $phaseJobsPath)

foreach ($path in $paths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    $realErrors = @($errors | Where-Object { $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    Assert-ConsoleUpgrade ($realErrors.Count -eq 0) "$path parses"
}

$fixText = Get-Content -LiteralPath $fixPath -Raw
$upgradeText = Get-Content -LiteralPath $upgradePath -Raw
$validationText = Get-Content -LiteralPath $validationPath -Raw
$phaseJobsText = Get-Content -LiteralPath $phaseJobsPath -Raw

Assert-ConsoleUpgrade ($fixText -match 'NeededOnFreshDeploy\s*=\s*\$true' -and $fixText -match 'AppliesToExisting\s*=\s*\$true') 'console fix is reachable from Phase 10 and fresh-deploy maintenance'
Assert-ConsoleUpgrade ($fixText -match 'FixVersion\s*=\s*"261002\.1"') 'console fix version forces deployment of the hierarchy-release repair'
Assert-ConsoleUpgrade ($fixText -match 'returned no result' -and $fixText -match "Properties\['Success'\]") 'maintenance wrapper requires an explicit result'
Assert-ConsoleUpgrade ($fixText -match 'ToBase64String.+ReadAllBytes' -and
    $fixText -match 'WriteAllBytes\(\$script.+FromBase64String') 'maintenance carries the current console script into Phase 10-only reruns'
Assert-ConsoleUpgrade ($upgradeText -match 'Get-ConsoleVersionState' -and $upgradeText -match 'ConsoleRelease\s*=') 'upgrader compares the installed console release'
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Get-ConsoleSetupFailureDetail')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Invoke-ConsoleSetupProcess')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Uninstall-Console')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Install-Console')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Invoke-ConsoleUpgrade')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Get-ConsoleVersionState')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $upgradePath -Name 'Resolve-ExpectedConsoleRelease')))
. ([scriptblock]::Create((Import-ConsoleUpgradeFunction -Path $validationPath -Name 'Resolve-EffectiveHierarchyCmRelease')))
$numericVM = [pscustomobject]@{}
$symbolicVM = [pscustomobject]@{ thisParams = [pscustomobject]@{ cmDownloadVersion = [pscustomobject]@{ baselineVersion = '2603' } } }
$offlineVM = [pscustomobject]@{ thisParams = [pscustomobject]@{ cmDownloadVersion = [pscustomobject]@{ baselineVersion = '2509' } } }
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = '2509' }) -VM $numericVM) -eq '2509') 'numeric console release passes through unchanged'
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = 'current-branch' }) -VM $symbolicVM) -eq '2603') 'current-branch resolves through deployed media metadata'
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = 'tech-preview' }) -VM $symbolicVM) -eq '2603') 'tech-preview resolves through deployed media metadata'
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = '2603'; OfflineSCP = $true }) -VM $offlineVM) -eq '2509') 'OfflineSCP pins console expectation to deployed baseline media'
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = '2509'; OfflineSCP = $true }) -VM $numericVM) -eq '2509') 'OfflineSCP with no per-VM media metadata preserves a concrete baseline target'
$childOfflineVM = [pscustomobject]@{ parentSiteCode = 'CAS' }
$offlineHierarchy = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{
            vmName   = 'CAS1'
            role      = 'CAS'
            siteCode  = 'CAS'
            cmOptions = [pscustomobject]@{ Version = '2603'; OfflineSCP = $true }
            thisParams = [pscustomobject]@{
                cmDownloadVersion = [pscustomobject]@{ baselineVersion = '2509' }
            }
        }
    )
}
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = '2603'; OfflineSCP = $true }) -VM $childOfflineVM -DeployConfig $offlineHierarchy) -eq '2509') 'OfflineSCP child Primary inherits deployed baseline metadata from its CAS'
$mainEraParent = [pscustomobject]@{
    vmName   = 'CAS1'
    role      = 'CAS'
    siteCode  = 'CS1'
    cmOptions = [pscustomobject]@{ Version = '2309'; OfflineSCP = $false }
    thisParams = [pscustomobject]@{
        cmDownloadVersion = [pscustomobject]@{
            baselineVersion = '2303'
            versions = @('2303', '2309')
        }
    }
}
$developChild = [pscustomobject]@{
    siteCode = 'PS2'
    parentSiteCode = 'CS1'
    cmOptions = [pscustomobject]@{ Version = '2509'; OfflineSCP = $false }
    thisParams = [pscustomobject]@{
        cmDownloadVersion = [pscustomobject]@{
            baselineVersion = '2303'
            versions = @('2303', '2309')
        }
    }
}
$mixedHierarchy = [pscustomobject]@{
    cmOptions = $developChild.cmOptions
    virtualMachines = @($developChild, $mainEraParent)
}
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions $developChild.cmOptions -VM $developChild -DeployConfig $mixedHierarchy) -eq '2309') `
    'child Primary console inherits the existing parent hierarchy release'
function Resolve-CmVersionAlias { param([string]$Version) return $Version }
function Get-CMBaselineVersion { param([string]$CMVersion) [pscustomobject]@{ baselineVersion = '2303' } }
$validationRelease = Resolve-EffectiveHierarchyCmRelease -CurrentItem $developChild -DeployConfig $mixedHierarchy
Assert-ConsoleUpgrade ($validationRelease.Version -eq '2309' -and $validationRelease.InheritedFromParent) `
    'Phase 11 uses the same parent hierarchy release as console maintenance'
$parentSiteRoleDecoy = [pscustomobject]@{
    vmName = 'CAS-SUP1'; role = 'SiteSystem'; siteCode = 'CS1'
}
$foreignParentDecoy = [pscustomobject]@{
    vmName = 'FOREIGN-CAS'; role = 'CAS'; siteCode = 'CS1'; domain = 'foreign.test'
}
$developChild | Add-Member -MemberType NoteProperty -Name domain -Value 'upgrade.test' -Force
$mainEraParent | Add-Member -MemberType NoteProperty -Name domain -Value 'upgrade.test' -Force
$mixedHierarchy | Add-Member -MemberType NoteProperty -Name vmOptions `
    -Value ([pscustomobject]@{ domainName = 'upgrade.test' }) -Force
$mixedHierarchy.virtualMachines += @($parentSiteRoleDecoy, $foreignParentDecoy)
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions $developChild.cmOptions -VM $developChild `
            -DeployConfig $mixedHierarchy) -eq '2309') `
    'Console release routing confused a parent-site role host or foreign CAS with the owning CAS.'
$decoyValidationRelease = Resolve-EffectiveHierarchyCmRelease -CurrentItem $developChild -DeployConfig $mixedHierarchy
Assert-ConsoleUpgrade ($decoyValidationRelease.Version -eq '2309' -and $decoyValidationRelease.InheritedFromParent) `
    'Phase 11 release routing confused a parent-site role host or foreign CAS with the owning CAS.'
$mainEraParent.cmOptions.OfflineSCP = $true
Assert-ConsoleUpgrade ((Resolve-ExpectedConsoleRelease -CmOptions $developChild.cmOptions -VM $developChild -DeployConfig $mixedHierarchy) -eq '2303') `
    'child Primary inherits an offline parent hierarchy baseline'
$offlineValidationRelease = Resolve-EffectiveHierarchyCmRelease -CurrentItem $developChild -DeployConfig $mixedHierarchy
Assert-ConsoleUpgrade ($offlineValidationRelease.Version -eq '2303' -and $offlineValidationRelease.OfflineSCP) `
    'Phase 11 inherits the offline parent hierarchy baseline'
$mainEraParent.cmOptions.OfflineSCP = $false
function Get-CMBaselineVersion { throw 'synthetic baseline catalog failure' }
$offlineWithoutMetadata = [pscustomobject]@{
    cmOptions = [pscustomobject]@{ Version = '2603'; OfflineSCP = $true }
    thisParams = [pscustomobject]@{ cmDownloadVersion = [pscustomobject]@{} }
}
$offlineWithoutMetadataConfig = [pscustomobject]@{
    cmOptions = $offlineWithoutMetadata.cmOptions
    virtualMachines = @($offlineWithoutMetadata)
}
$offlineFallback = Resolve-EffectiveHierarchyCmRelease -CurrentItem $offlineWithoutMetadata -DeployConfig $offlineWithoutMetadataConfig
Assert-ConsoleUpgrade ($offlineFallback.Version -eq '2603' -and
    $offlineFallback.BaselineResolutionError -eq 'synthetic baseline catalog failure') `
    'Phase 11 preserves actionable OfflineSCP baseline catalog errors while falling back'
$missingParentFailed = $false
try {
    $null = Resolve-ExpectedConsoleRelease -CmOptions $developChild.cmOptions -VM $developChild `
        -DeployConfig ([pscustomobject]@{ virtualMachines = @($developChild) })
}
catch { $missingParentFailed = $_.Exception.Message -match 'expected exactly one parent CAS' }
Assert-ConsoleUpgrade $missingParentFailed 'missing parent hierarchy metadata fails explicitly'
Remove-Item Function:\Resolve-CmVersionAlias -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CMBaselineVersion -ErrorAction SilentlyContinue
$unresolvedFailed = $false
try { $null = Resolve-ExpectedConsoleRelease -CmOptions ([pscustomobject]@{ Version = 'tech-preview' }) -VM $numericVM }
catch { $unresolvedFailed = $_.Exception.Message -match 'could not resolve symbolic' }
Assert-ConsoleUpgrade $unresolvedFailed 'unresolved symbolic console release fails explicitly'
Assert-ConsoleUpgrade ($upgradeText -match 'RequiredExtensionSiteVersion' -and $upgradeText -match 'RequiredExtensionVersion') 'upgrader compares the site-required extension version'
Assert-ConsoleUpgrade ($upgradeText -match 'expected release.+ReleaseMatches' -and $upgradeText -match 'ExtensionMatches') 'upgrade failure names release and extension comparisons independently'
Assert-ConsoleUpgrade ($upgradeText -match 'MaximumAttempts = 2' -and $upgradeText -match 'for \(\$attempt = 1; \$attempt -le \$MaximumAttempts; \$attempt\+\+\)') 'upgrader makes at most two install attempts'
Assert-ConsoleUpgrade ($upgradeText -match "Tools\\ConsoleSetup" -and $upgradeText -notmatch "Join-Path \$CMInstallDir 'bin\\I386\\Consolesetup\.exe'") 'upgrader uses the site-maintained console payload instead of baseline media'
Assert-ConsoleUpgrade ($upgradeText -match 'AdminConsole\.msi' -and $upgradeText -match 'ConfigMgr\.AC_Extension\.i386\.cab' -and $upgradeText -match 'ConfigMgr\.AC_Extension\.amd64\.cab') 'upgrader requires the complete console payload'
Assert-ConsoleUpgrade (@([regex]::Matches($upgradeText, 'Start-Process -FilePath \$ConsoleUIExe')).Count -eq 1 -and $upgradeText -match '-PassThru -ErrorAction Stop') 'console setup captures the launched process object'
Assert-ConsoleUpgrade ($upgradeText -match 'Wait-Process -Timeout 900' -and $upgradeText -notmatch '\$LASTEXITCODE') 'upgrader also preserves the proven residual ConsoleSetup wait without racing LASTEXITCODE'
Assert-ConsoleUpgrade ($upgradeText -match 'LangPackDir=\$LangPackDir' -and $upgradeText -cmatch 'DEFAULTSITESERVERNAME=\$LocalSiteServer' -and $upgradeText -cmatch 'TargetDir=\$UIInstallDir' -and $upgradeText -cnotmatch 'TARGETDIR=') 'upgrader preserves the product-emitted command-line property contract'
Assert-ConsoleUpgrade ($upgradeText -match 'C:\\ConfigMgrAdminUISetup\.log' -and $upgradeText -match 'C:\\ConfigMgrAdminUISetupVerbose\.log') 'console process failures include product setup-log evidence'
Assert-ConsoleUpgrade ($upgradeText -match 'Stop-Process -Id \$ownedProcess\.Id' -and $upgradeText -match '\$preExistingIds') 'timed-out attempts stop only ConsoleSetup processes owned by that attempt'
Assert-ConsoleUpgrade ($upgradeText -match 'Console upgrade did not converge' -and $upgradeText -match 'throw "Upgrade-Console: CM install directory' -and $upgradeText -match 'site-maintained console source.+is incomplete') 'missing prerequisites and retry exhaustion are terminating failures'
Assert-ConsoleUpgrade ($validationText -match 'ConfigMgr admin console is release' -and $validationText -match 'ConfigMgr admin console extension is' -and $validationText -match '\$results\.Passed = \$false') 'Phase 11 fails stale console release and extension versions'
Assert-ConsoleUpgrade ($validationText -match 'OfflineSCP pins the effective ConfigMgr release to deployed baseline' -and
    $validationText -match 'Get-CMBaselineVersion -CMVersion \$configuredVersion') 'Phase 11 derives missing OfflineSCP metadata from the baseline catalog'
Assert-ConsoleUpgrade ($validationText -match 'Child site inherits ConfigMgr release.+from parent site') 'Phase 11 reports inherited parent hierarchy release'
Assert-ConsoleUpgrade ($validationText -match 'BaselineResolutionError' -and
    $validationText -match 'Could not derive the OfflineSCP baseline from the ConfigMgr catalog') 'Phase 11 reports baseline catalog resolution failures'
Assert-ConsoleUpgrade ($phaseJobsText -match 'Start-VMMaintenance reported failure.+preceding per-fix result') 'Phase 10 reports explicit maintenance failure instead of claiming no data'

$fixesToPerform = @()
. $fixPath
$upgradeFix = @($fixesToPerform | Where-Object { $_.FixName -eq 'Fix-Upgrade-Console' }) | Select-Object -Last 1
$payloadBytes = if ($upgradeFix -and $upgradeFix.ArgumentList.Count -eq 1) {
    [Convert]::FromBase64String("$($upgradeFix.ArgumentList[0])")
}
else {
    @()
}
$sourceBytes = [IO.File]::ReadAllBytes($upgradePath)
Assert-ConsoleUpgrade ($payloadBytes.Count -eq $sourceBytes.Count -and
    [Convert]::ToBase64String($payloadBytes) -eq [Convert]::ToBase64String($sourceBytes)) 'maintenance payload exactly matches the current Upgrade-Console.ps1 bytes'

$script:ConsoleSetupState = [pscustomobject]@{
    AdminConsoleVersion      = ' 5.2509.1036.1200 '
    RequiredExtensionVersion = ' 5.0.9141.1002 '
}
function Get-ItemProperty {
    param($Path, $ErrorAction)
    $script:ConsoleSetupState
}
function Get-WmiObject {
    param($Namespace, $Query, $ErrorAction)
    [pscustomobject]@{ FileVersion = ' 5.0.9141.1002 ' }
}
$currentState = Get-ConsoleVersionState -SiteCode 'SPC' -ExpectedRelease '2509'
Assert-ConsoleUpgrade ($currentState.Current -and $currentState.ReleaseMatches -and $currentState.ExtensionMatches) 'console state normalizes provider and registry version strings before comparison'
Remove-Item Function:\Get-ItemProperty -ErrorAction SilentlyContinue
Remove-Item Function:\Get-WmiObject -ErrorAction SilentlyContinue

$script:ProcessExitCodes = New-Object System.Collections.Generic.Queue[object]
$script:ProcessCalls = New-Object System.Collections.Generic.List[object]
$script:WaitCalls = New-Object System.Collections.Generic.List[object]
$script:ResidualProcesses = @()
$script:PreExistingProcesses = @()
$script:ProcessInventories = New-Object System.Collections.Queue
$script:WaitFailureOnCall = 0
$script:StopCalls = New-Object System.Collections.Generic.List[int]
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$PassThru, $ErrorAction)
    $processId = 100 + $script:ProcessCalls.Count
    $script:ProcessCalls.Add([pscustomobject]@{
            Id              = $processId
            FilePath        = $FilePath
            ArgumentList    = $ArgumentList
            WorkingDirectory = $WorkingDirectory
            PassThru        = $PassThru.IsPresent
            ErrorAction     = "$ErrorAction"
        })
    [pscustomobject]@{ Id = $processId; ExitCode = $script:ProcessExitCodes.Dequeue() }
}
function Get-Process {
    param($Name, $ErrorAction)
    if ($script:ProcessInventories.Count -gt 0) { return $script:ProcessInventories.Dequeue() }
    return $script:ResidualProcesses
}
function Wait-Process {
    param([Parameter(ValueFromPipeline)]$InputObject, [int]$Timeout)
    process {
        $script:WaitCalls.Add([pscustomobject]@{ Process = $InputObject; Timeout = $Timeout })
        if ($script:WaitFailureOnCall -gt 0 -and $script:WaitCalls.Count -eq $script:WaitFailureOnCall) {
            throw 'synthetic wait timeout'
        }
    }
}
function Stop-Process { param([int]$Id, [switch]$Force, $ErrorAction) $script:StopCalls.Add($Id) }
function Write-DscStatus { param($Status, [switch]$NoStatus) }

$script:ProcessExitCodes.Enqueue(0)
$script:ProcessExitCodes.Enqueue(3010)
$script:ProcessCalls.Clear()
$script:ResidualProcesses = @([pscustomobject]@{ Id = 201 })
$script:PreExistingProcesses = @()
$script:ProcessInventories.Clear()
$script:ProcessInventories.Enqueue($script:PreExistingProcesses)
$script:ProcessInventories.Enqueue($script:ResidualProcesses)
$script:ProcessInventories.Enqueue($script:PreExistingProcesses)
$script:ProcessInventories.Enqueue($script:ResidualProcesses)
$script:WaitFailureOnCall = 0
$script:WaitCalls.Clear()
$script:StopCalls.Clear()
Uninstall-Console -ConsoleUIExe 'E:\ConfigMgr\Tools\ConsoleSetup\ConsoleSetup.exe'
Install-Console -ConsoleUIExe 'E:\ConfigMgr\Tools\ConsoleSetup\ConsoleSetup.exe' -LangPackDir 'E:\ConfigMgr\Tools\ConsoleSetup' -UIInstallDir 'E:\ConfigMgr\AdminConsole' -LocalSiteServer 'site.example.test'
Assert-ConsoleUpgrade ($script:ProcessCalls.Count -eq 2) 'console upgrade launches one uninstall and one install process'
Assert-ConsoleUpgrade (@($script:ProcessCalls | Where-Object { -not $_.PassThru -or $_.ErrorAction -ne 'Stop' }).Count -eq 0) 'every console process returns a process object with terminating launch failures'
Assert-ConsoleUpgrade ($script:ProcessCalls[0].ArgumentList -eq '/uninstall /q') 'console uninstall uses the documented silent arguments'
Assert-ConsoleUpgrade ($script:ProcessCalls[1].ArgumentList -clike '/q *LangPackDir=E:\ConfigMgr\Tools\ConsoleSetup*TargetDir=E:\ConfigMgr\AdminConsole*DEFAULTSITESERVERNAME=site.example.test*') 'console install preserves language, target, and default-site arguments'
Assert-ConsoleUpgrade (@($script:ProcessCalls | Where-Object WorkingDirectory -ne 'E:\ConfigMgr\Tools\ConsoleSetup').Count -eq 0) 'console processes run beside the site-maintained payload'
Assert-ConsoleUpgrade ($script:WaitCalls.Count -eq 4 -and @($script:WaitCalls | Where-Object { $_.Timeout -lt 1 -or $_.Timeout -gt 900 }).Count -eq 0) 'launched and detached ConsoleSetup processes share a bounded wait budget'

foreach ($failureCase in @(
        [pscustomobject]@{ Name = 'missing exit code'; ExitCode = $null; Pattern = '*returned no process exit code*' }
        [pscustomobject]@{ Name = 'nonzero exit code'; ExitCode = 1603; Pattern = '*failed with exit 1603*' }
    )) {
    $script:ProcessExitCodes.Clear()
    $script:ProcessExitCodes.Enqueue($failureCase.ExitCode)
    $script:PreExistingProcesses = @()
    $script:ResidualProcesses = @()
    $script:ProcessInventories.Clear()
    $script:ProcessInventories.Enqueue($script:PreExistingProcesses)
    $script:ProcessInventories.Enqueue($script:ResidualProcesses)
    $script:WaitFailureOnCall = 0
    $caught = $null
    $script:ResidualProcesses = @()
    try { Invoke-ConsoleSetupProcess -ConsoleUIExe 'E:\ConfigMgr\Tools\ConsoleSetup\ConsoleSetup.exe' -Arguments '/uninstall /q' -Operation 'uninstall' }
    catch { $caught = $_ }
    Assert-ConsoleUpgrade ([bool]$caught -and $caught.Exception.Message -like $failureCase.Pattern) "$($failureCase.Name) is a terminating console-upgrade failure"
}

$script:ProcessExitCodes.Clear()
$script:ProcessExitCodes.Enqueue(0)
$script:ProcessCalls.Clear()
$script:WaitCalls.Clear()
$script:StopCalls.Clear()
$script:PreExistingProcesses = @([pscustomobject]@{ Id = 900 })
$script:ResidualProcesses = @([pscustomobject]@{ Id = 900 }, [pscustomobject]@{ Id = 301 })
$script:ProcessInventories.Clear()
$script:ProcessInventories.Enqueue($script:PreExistingProcesses)
$script:ProcessInventories.Enqueue($script:ResidualProcesses)
$script:ProcessInventories.Enqueue($script:ResidualProcesses)
$script:WaitFailureOnCall = 2
$caught = $null
try { Invoke-ConsoleSetupProcess -ConsoleUIExe 'E:\ConfigMgr\Tools\ConsoleSetup\ConsoleSetup.exe' -Arguments '/uninstall /q' -Operation 'uninstall' }
catch { $caught = $_ }
Assert-ConsoleUpgrade ([bool]$caught -and $caught.Exception.Message -like '*did not finish within 900 seconds*synthetic wait timeout*') 'detached-process timeout is a terminating failure with its cause'
Assert-ConsoleUpgrade (($script:StopCalls | Sort-Object) -join ',' -eq '100,301') 'timeout stops the launched and detached attempt-owned processes'
Assert-ConsoleUpgrade ($script:StopCalls -notcontains 900) 'timeout never stops a pre-existing ConsoleSetup process'

$script:UpgradeSleeps = @()
function Get-ConsoleVersionState {
    [pscustomobject]@{ Current = $true; AdminConsoleVersion = '5.2503.1000.1000'; ConsoleRelease = '2503'; RequiredExtensionVersion = '5.0.9135.1001'; RequiredExtensionSiteVersion = '5.0.9135.1001' }
}
function Start-Sleep { param([int]$Seconds) $script:UpgradeSleeps += $Seconds }
$script:ProcessExitCodes.Clear()
$script:ProcessExitCodes.Enqueue(0)
$script:ProcessExitCodes.Enqueue(1603)
$script:ProcessExitCodes.Enqueue(0)
$script:ProcessCalls.Clear()
$script:WaitCalls.Clear()
$script:StopCalls.Clear()
$script:PreExistingProcesses = @()
$script:ResidualProcesses = @()
$script:ProcessInventories.Clear()
for ($inventoryIndex = 0; $inventoryIndex -lt 6; $inventoryIndex++) {
    $script:ProcessInventories.Enqueue(@())
}
$script:WaitFailureOnCall = 0
$retryState = Invoke-ConsoleUpgrade -ConsoleUIExe 'E:\ConfigMgr\Tools\ConsoleSetup\ConsoleSetup.exe' -LangPackDir 'E:\ConfigMgr\Tools\ConsoleSetup' -UIInstallDir 'E:\ConfigMgr\AdminConsole' -LocalSiteServer 'site.example.test' -SiteCode 'PS1' -ExpectedRelease '2503' -RetrySeconds 7
Assert-ConsoleUpgrade ($retryState.Current -and $script:ProcessCalls.Count -eq 3) 'failed first install retries through the real process runner'
Assert-ConsoleUpgrade (@($script:ProcessCalls | Where-Object ArgumentList -eq '/uninstall /q').Count -eq 1) 'successful uninstall is not repeated after an install failure'
Assert-ConsoleUpgrade (@($script:ProcessCalls | Where-Object ArgumentList -ne '/uninstall /q').Count -eq 2) 'failed installation is retried exactly once'
Assert-ConsoleUpgrade (@($script:UpgradeSleeps | Where-Object { $_ -eq 7 }).Count -eq 1) 'process-failure retry uses the configured delay once'

if ($failures -gt 0) { throw "$failures console-upgrade regression assertion(s) failed" }
Write-Host 'PASS  console-upgrade routing and validation regression suite'