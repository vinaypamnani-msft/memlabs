<#
.SYNOPSIS
    Verifies that Windows 11 SiteSystems are DP-only.

.DESCRIPTION
    Exercises the production OS picker, VM creation, role-property shaper, and
    configuration validator. Also checks that config and VM-note rehydration do
    not add server-only role properties back to a Windows 11 SiteSystem.

    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $color = 'Green'
    $status = 'PASS'
    if (-not $passed) { $color = 'Red'; $status = 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What) -ForegroundColor $color
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Import-TestFunction {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Path has $(@($errors).Count) parse error(s)"
    }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $Name definition in $Path, found $($definition.Count)"
    }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Assert-PropertiesAbsent {
    param ([object] $VirtualMachine, [string[]] $Names, [string] $What)

    $present = @($Names | Where-Object { $VirtualMachine.PSObject.Properties.Name -contains $_ })
    Assert-Equal '' ($present -join ',') $What
}

function Assert-PropertiesPresent {
    param ([object] $VirtualMachine, [string[]] $Names, [string] $What)

    $missing = @($Names | Where-Object { $VirtualMachine.PSObject.Properties.Name -notcontains $_ })
    Assert-Equal '' ($missing -join ',') $What
}

$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
$menusPath = Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1'
$addVmPath = Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1'
$vmListPath = Join-Path $RootPath 'common\Common.GenConfig.VMList.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.ps1'
$phase2Path = Join-Path $RootPath 'DSC\phases\Phase2DomainMember.ps1'
$phase3Path = Join-Path $RootPath 'DSC\phases\Phase3.ps1'
$scriptFunctionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$installDpPath = Join-Path $RootPath 'DSC\phases\InstallDPMPClient.ps1'

. (Import-TestFunction -Path $configPath -Name 'Test-SiteSystemClientOperatingSystem')
. (Import-TestFunction -Path $menusPath -Name 'Get-SupportedOperatingSystemsForRole')
. (Import-TestFunction -Path $menusPath -Name 'Set-SiteSystemPropertiesForOperatingSystem')
. (Import-TestFunction -Path $addVmPath -Name 'Add-NewVMForRole')
. (Import-TestFunction -Path $validationPath -Name 'Test-ValidRoleSiteSystem')
. (Import-TestFunction -Path $scriptFunctionsPath -Name 'Test-ClientDpProvisioningTarget')
. (Import-TestFunction -Path $scriptFunctionsPath -Name 'Confirm-DpInstallationAdminAccess')
. (Import-TestFunction -Path $scriptFunctionsPath -Name 'Get-ClientDpProvisioningState')
. (Import-TestFunction -Path $scriptFunctionsPath -Name 'Wait-ClientDpProvisioningReady')

function Write-Log { param() }
function Write-Host2 { param() }
function Test-VmIsLinux { return $false }
function get-RoleForSitecode { return 'Primary' }
function Get-List2 { param([object] $DeployConfig); return @($DeployConfig.virtualMachines) }
function Get-ExistingSiteServer { return $null }
function Write-DscStatus { param($Status, [switch]$Warning); $script:LastDscStatus = $Status }
function Remove-MPReplicaLocalSql {
    param ([object] $VirtualMachine)
    $script:ReplicaCleanupCalled++
}
function Add-ValidationMessage {
    param (
        [string] $Message,
        [object] $ReturnObject,
        [switch] $Failure,
        [switch] $Warning
    )
    $ReturnObject.Messages.Add($Message)
    if ($Failure) { $ReturnObject.Failures++ }
}
function Invoke-Command {
    param (
        [string] $ComputerName,
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList,
        [string] $ErrorAction
    )
    $script:LastInvokeArgumentList = $ArgumentList
    return $script:RemoteInvokeResult
}
function Write-ClientDpProvisioningDiagnostics {
    param ([string] $ServerFQDN)
    $script:DiagnosticCalls++
}

$global:Common = [pscustomobject]@{
    Supported = [pscustomobject]@{
        OperatingSystems = @('Server 2025', 'Server 2022', 'Windows 11 25H2', 'Windows 10 22H2')
    }
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
Write-Host ''

$siteSystemOperatingSystems = @(Get-SupportedOperatingSystemsForRole -Role 'SiteSystem')
Assert-Equal 'Server 2025,Server 2022,Windows 11 25H2' ($siteSystemOperatingSystems -join ',') 'SiteSystem picker offers Server and Windows 11'

$serverRoleProperties = @('installMP', 'installSUP', 'installRP', 'installSMSProv')
$dependentProperties = @('useDatabaseReplica', 'replicaSqlServerVM', 'replicaDbName', 'wsusContentDir', 'wsusDataBaseServer', 'InstallPatchMyPC', 'PatchMyPCFileServer')
$script:ReplicaCleanupCalled = 0
$roundTrip = [pscustomobject]@{
    Role                = 'SiteSystem'
    operatingSystem     = 'Windows 11 25H2'
    installDP           = $true
    enablePullDP        = $true
    pullDPSourceDP      = 'SOURCE'
    installMP           = $true
    installSUP          = $true
    installRP           = $true
    installSMSProv      = $true
    useDatabaseReplica  = $true
    replicaSqlServerVM  = 'SQL1'
    replicaDbName       = 'CM_ABC'
    replicaSqlAutoAdded = $true
    wsusContentDir      = 'F:\WSUS'
    wsusDataBaseServer  = 'WID'
    InstallPatchMyPC    = $true
    PatchMyPCFileServer = 'FS1'
}
Set-SiteSystemPropertiesForOperatingSystem -VirtualMachine $roundTrip
Assert-PropertiesAbsent $roundTrip ($serverRoleProperties + $dependentProperties) 'Windows 11 removes server-only role properties and dependents'
Assert-Equal $true $roundTrip.installDP 'Windows 11 retains the DP role'
Assert-Equal $true $roundTrip.enablePullDP 'Windows 11 retains pull-DP configuration'
Assert-Equal 'SOURCE' $roundTrip.pullDPSourceDP 'Windows 11 retains the pull-DP source'
Assert-Equal 1 $script:ReplicaCleanupCalled 'Windows 11 invokes local replica cleanup before removing MP properties'

$roundTrip.operatingSystem = 'Server 2022'
Set-SiteSystemPropertiesForOperatingSystem -VirtualMachine $roundTrip
Assert-PropertiesPresent $roundTrip $serverRoleProperties 'switching back to Server restores SiteSystem role toggles'
Assert-Equal 'False,False,False,False' (($serverRoleProperties | ForEach-Object { $roundTrip.$_ }) -join ',') 'restored Server role toggles default off'

$generatedConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ domainName = 'example.test' }
    domainDefaults  = [pscustomobject]@{
        IncludeSSMSOnNONSQL       = $false
        PushCMClientToSiteSystems = $false
        UseProxyForCM             = $false
        UseDynamicMemory          = $false
    }
    cmOptions       = [pscustomobject]@{ EnableBLM = $false }
    virtualMachines = @([pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'ABC'; installDP = $false })
}
Add-NewVMForRole -Role 'SiteSystem' -Domain 'example.test' -ConfigToModify $generatedConfig `
    -Name 'W11DP' -SiteCode 'ABC' -OperatingSystem 'Windows 11 25H2' -Network '10.0.0.0' -Quiet:$true -Test:$true
Add-NewVMForRole -Role 'SiteSystem' -Domain 'example.test' -ConfigToModify $generatedConfig `
    -Name 'SRVDPMP' -SiteCode 'ABC' -OperatingSystem 'Server 2022' -Network '10.0.0.0' -Quiet:$true -Test:$true
$generatedClient = $generatedConfig.virtualMachines | Where-Object { $_.vmName -eq 'W11DP' } | Select-Object -First 1
$generatedServer = $generatedConfig.virtualMachines | Where-Object { $_.vmName -eq 'SRVDPMP' } | Select-Object -First 1
Assert-Equal $true $generatedClient.installDP 'new Windows 11 SiteSystem is a DP'
Assert-PropertiesAbsent $generatedClient $serverRoleProperties 'new Windows 11 SiteSystem is DP-only'
Assert-Equal $true $generatedServer.installMP 'new Server SiteSystem retains its MP default'
Assert-PropertiesPresent $generatedServer $serverRoleProperties 'new Server SiteSystem retains all role toggles'

$global:ConfigObject = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ DomainName = 'example.test' }
    virtualMachines = @([pscustomobject]@{ role = 'Primary'; vmName = 'PS1'; siteCode = 'ABC' })
}
$badClient = [pscustomobject]@{
    role = 'SiteSystem'; vmName = 'BAD'; siteCode = 'ABC'; operatingSystem = 'Windows 11 25H2'
    installDP = $true; installMP = $true
}
$badResult = [pscustomobject]@{ Failures = 0; Messages = New-Object System.Collections.Generic.List[string] }
Test-ValidRoleSiteSystem -VM $badClient -ReturnObject $badResult
Assert-Equal 1 $badResult.Failures 'validator rejects a Windows 11 SiteSystem with an MP'
Assert-Equal $true ($badResult.Messages[0] -like '*only the Distribution Point role*') 'validation message explains the DP-only rule'

$goodClient = [pscustomobject]@{
    role = 'SiteSystem'; vmName = 'GOOD'; siteCode = 'ABC'; operatingSystem = 'Windows 11 25H2'
    installDP = $true
}
$goodResult = [pscustomobject]@{ Failures = 0; Messages = New-Object System.Collections.Generic.List[string] }
Test-ValidRoleSiteSystem -VM $goodClient -ReturnObject $goodResult
Assert-Equal 0 $goodResult.Failures 'validator accepts a DP-only Windows 11 SiteSystem'

$configLines = @(Get-Content -LiteralPath $configPath)
foreach ($guard in @(
        '$isClientOsSiteSystem = Test-SiteSystemClientOperatingSystem -VirtualMachine $vm',
        '$isClientOsSiteSystem = Test-SiteSystemClientOperatingSystem -VirtualMachine $vmObject')) {
    $guardCount = @($configLines | Where-Object { $_.Trim() -ceq $guard }).Count
    Assert-Equal 1 $guardCount "reload normalization contains guard: $guard"
}
$vmListText = Get-Content -LiteralPath $vmListPath -Raw
Assert-Equal 1 ([regex]::Matches($vmListText, 'Set-SiteSystemPropertiesForOperatingSystem -VirtualMachine \$property').Count) 'OS editor invokes the SiteSystem shaper once'

$clientDpConfig = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'W11DP'; role = 'SiteSystem'; operatingSystem = 'Windows 11 25H2'; installDP = $true },
        [pscustomobject]@{ vmName = 'SRVDP'; role = 'SiteSystem'; operatingSystem = 'Server 2022'; installDP = $true }
    )
}
Assert-Equal $true (Test-ClientDpProvisioningTarget -ServerFQDN 'W11DP.example.test' -DeployConfig $clientDpConfig) 'Phase 8 identifies a Windows 11 DP target'
Assert-Equal $false (Test-ClientDpProvisioningTarget -ServerFQDN 'SRVDP.example.test' -DeployConfig $clientDpConfig) 'Phase 8 leaves Server DP timing unchanged'

$primaryDpConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainNetBiosName = 'EXAMPLE' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'ABC' },
        [pscustomobject]@{
            vmName = 'W11DP'; role = 'SiteSystem'; siteCode = 'ABC'; operatingSystem = 'Windows 11 25H2'
            thisParams = [pscustomobject]@{ SiteServer = 'PS1' }
        }
    )
}
$script:RemoteInvokeResult = [pscustomobject]@{ Success = $true; Detail = 'present EXAMPLE\PS1$'; Missing = '' }
$script:LastInvokeArgumentList = $null
Assert-Equal $true (Confirm-DpInstallationAdminAccess -ServerFQDN 'W11DP.example.test' -ServerSiteCode 'ABC' -DeployConfig $primaryDpConfig) 'DP preflight accepts verified primary site-server admin membership'
Assert-Equal 'EXAMPLE\PS1$' (@($script:LastInvokeArgumentList[0]) -join ',') 'primary-owned DP requires the primary site-server computer account'

$secondaryDpConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainNetBiosName = 'EXAMPLE' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PS1'; role = 'Primary'; siteCode = 'PRI' },
        [pscustomobject]@{ vmName = 'SEC1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI' },
        [pscustomobject]@{ vmName = 'W11SEC'; role = 'SiteSystem'; siteCode = 'SEC'; operatingSystem = 'Windows 11 25H2' }
    )
}
$script:RemoteInvokeResult = [pscustomobject]@{ Success = $true; Detail = 'present required accounts'; Missing = '' }
$script:LastInvokeArgumentList = $null
Assert-Equal $true (Confirm-DpInstallationAdminAccess -ServerFQDN 'W11SEC.example.test' -ServerSiteCode 'SEC' -DeployConfig $secondaryDpConfig) 'secondary DP preflight accepts verified installation principals'
Assert-Equal 'EXAMPLE\SEC1$,EXAMPLE\PS1$' (@($script:LastInvokeArgumentList[0]) -join ',') 'secondary-owned DP includes the parent primary computer account'
$script:RemoteInvokeResult = [pscustomobject]@{ Success = $false; Detail = 'ERROR EXAMPLE\PS1$'; Missing = 'EXAMPLE\PS1$' }
Assert-Equal $false (Confirm-DpInstallationAdminAccess -ServerFQDN 'W11DP.example.test' -ServerSiteCode 'ABC' -DeployConfig $primaryDpConfig) 'DP preflight blocks installation when primary admin membership is unverified'

$script:RemoteInvokeResult = [pscustomobject]@{ Ready = $true; Summary = 'provider=True share=True iisApp=True W3SVC=True' }
$state = Get-ClientDpProvisioningState -ServerFQDN 'W11DP.example.test'
Assert-Equal $true $state.Ready 'readiness probe returns the remote usable state'
Assert-Equal $true (Wait-ClientDpProvisioningReady -ServerFQDN 'W11DP.example.test' -TimeoutSeconds 1 -PollSeconds 1) 'readiness wait exits immediately for a usable DP'
$script:DiagnosticCalls = 0
Assert-Equal $false (Wait-ClientDpProvisioningReady -ServerFQDN 'W11DP.example.test' -TimeoutSeconds 0 -PollSeconds 1) 'readiness timeout fails instead of accepting role registration'
Assert-Equal 1 $script:DiagnosticCalls 'readiness timeout captures client-DP diagnostics'

$phase2Text = Get-Content -LiteralPath $phase2Path -Raw
foreach ($requiredPhase2Text in @(
        "Service ClientDpRemoteRegistry",
        'ValueName = "LocalAccountTokenFilterPolicy"',
        "LocalPort = '135'",
        "LocalPort = '49152-65535'",
        "LocalPort = 'RPC'",
        "LocalPort = '445'")) {
    Assert-Equal $true $phase2Text.Contains($requiredPhase2Text) "Phase 2 contains $requiredPhase2Text"
}

$expectedFeatures = @(
    'IIS-WebServerRole', 'IIS-WebServer', 'IIS-CommonHttpFeatures', 'IIS-StaticContent',
    'IIS-DefaultDocument', 'IIS-DirectoryBrowsing', 'IIS-HttpErrors', 'IIS-HttpRedirect',
    'IIS-WebServerManagementTools', 'IIS-IIS6ManagementCompatibility', 'IIS-Metabase',
    'IIS-WindowsAuthentication', 'IIS-WMICompatibility', 'IIS-ISAPIExtensions',
    'IIS-ManagementScriptingTools', 'MSRDC-Infrastructure', 'IIS-ManagementService'
)
$phase3Text = Get-Content -LiteralPath $phase3Path -Raw
$featureBlock = [regex]::Match($phase3Text, '(?s)Script ClientDpWindowsFeatures \{(?<body>.*?)\n\s*Service ClientDpWAS').Groups['body'].Value
$actualFeatures = @([regex]::Matches($featureBlock, "'(?<name>(?:IIS-[^']+|MSRDC-Infrastructure))'") |
        ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)
Assert-Equal (($expectedFeatures | Sort-Object) -join ',') ($actualFeatures -join ',') 'Phase 3 stages the exact DistMgr Windows 11 DP feature set'
Assert-Equal $true $phase3Text.Contains("`$featureDependency = '[Service]ClientDpW3SVC'") 'Phase 3 starts WAS and W3SVC before continuing'

$scriptFunctionsText = Get-Content -LiteralPath $scriptFunctionsPath -Raw
foreach ($diagnosticMarker in @('SMSDPProvider DLL:', 'LocalAccountTokenFilterPolicy=', 'Local Administrators:', 'Optional features:', 'WMI event ', 'smsdpprov.log:', 'distmgr.log:', '5046770')) {
    Assert-Equal $true $scriptFunctionsText.Contains($diagnosticMarker) "timeout diagnostics contain $diagnosticMarker"
}
foreach ($preflightMarker in @("Set-Service -Name 'RemoteRegistry' -StartupType Automatic", "Start-Service -Name 'RemoteRegistry'", "New-ItemProperty -Path `$policyPath -Name 'LocalAccountTokenFilterPolicy'")) {
    Assert-Equal $true $scriptFunctionsText.Contains($preflightMarker) "Phase 8 preflight reasserts $preflightMarker"
}
$installDpText = Get-Content -LiteralPath $installDpPath -Raw
Assert-Equal 4 ([regex]::Matches($installDpText, '(?:Install-DP|Install-PullDP).*?-DeployConfig \$deployConfig').Count) 'every DP installer call passes configuration to the readiness gate'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All SiteSystem client-OS checks passed.' -ForegroundColor Green
