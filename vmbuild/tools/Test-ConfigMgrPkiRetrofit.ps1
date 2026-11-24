#requires -Version 5.1
[CmdletBinding()]
param([switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1 -or $errors.Count) { throw "Cannot import $Name from $Path`: $($errors -join '; ')" }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw
    }
    throw "Expected an exception matching '$Pattern'."
}
function Write-Log { param($Message, [switch]$Failure, [switch]$Verbose, [switch]$Warning, [switch]$LogOnly) }
function Write-DscStatus { param($Message, [switch]$Failure) }

if (-not $GuestOnly) {
    $configPath = Join-Path $root 'common\Common.Config.ps1'
    foreach ($name in @('Get-ExistingConfigMgrPkiConversionTargets', 'Sync-ExistingHierarchyOptionsToDeployConfig',
            'New-DeployConfig', 'Add-ExistingVMToDeployConfig', 'ConvertFrom-MemLabsVmNoteScalar',
            'Resolve-ConfigVmReference', 'Resolve-VmCmOptions', 'Set-VmCmOptionsResolved')) {
        . (Import-TestFunction $configPath $name)
    }
    foreach ($name in @('Get-Phase2ConfigurationData', 'Get-Phase4ConfigurationData', 'Get-Phase6ConfigurationData', 'Get-Phase8ConfigurationData',
            'Test-MemLabsIncludeHiddenVmForPhase')) {
        . (Import-TestFunction (Join-Path $root 'common\Common.Phases.ps1') $name)
    }
    $script:Common = [pscustomobject]@{ InJob = $false }
    $script:Inventory = @(
        [pscustomobject]@{ vmName = 'LAB-DC'; role = 'DC'; domain = 'lab.test'; state = 'Running' },
        [pscustomobject]@{
            vmName = 'LAB-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
            cmOptions = [pscustomobject]@{ UsePKI = $false; Install = $false; Version = '2609' }
        },
        [pscustomobject]@{
            vmName = 'LAB-MPDP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
            installMP = $true; installDP = $true
        },
        [pscustomobject]@{
            vmName = 'LAB-SUP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'lab.test'; state = 'Running'; installSUP = $true
        },
        [pscustomobject]@{
            vmName = 'LAB-SEC'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-CLIENT'; role = 'DomainMember'; pushClient = 'SEC'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'LAB-LEGACY'; role = 'DomainMember'; pushClient = 'True'; domain = 'lab.test'; state = 'Running'
        },
        [pscustomobject]@{
            vmName = 'FOREIGN-PRI'; role = 'Primary'; siteCode = 'PRI'; domain = 'foreign.test'; state = 'Running'
        }
    )
    function Get-List {
        param($Type, $DomainName, [switch]$FailOnError)
        if ($DomainName) { $script:FailClosedInventory = [bool]$FailOnError }
        @($script:Inventory | Where-Object { -not $DomainName -or $_.domain -eq $DomainName })
    }
    function Get-VMNote {
        param($VMName)
        $script:Inventory | Where-Object vmName -eq $VMName | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
    function Start-VM2 { param($Name) throw "Fixture must not start $Name." }
    function Get-ExistingForDomain { param($DomainName, $Role) if ($Role -eq 'DC') { 'LAB-DC' } }
    function Get-MemlabsDataRoot { Join-Path $env:TEMP '__memlabs_pki_fixture_no_data__' }
    function Write-Exception { param($ExceptionInfo, $AdditionalInfo) throw $ExceptionInfo }
    function Get-CmOptionsFromSiteServerBackup { param($VmName, $DomainName) throw 'Unexpected backup recovery.' }
    function Test-PushClientRequested { param($VM) $false }
    function New-FixtureConfig {
        [pscustomobject]@{
            vmOptions = [pscustomobject]@{ domainName = 'lab.test'; prefix = 'LAB-' }
            cmOptions = [pscustomobject]@{ UsePKI = $true; Install = $true; Version = '9999' }
            pkiOptions = [pscustomobject]@{ EnablePKI = $true; IssuingCAVM = 'CA'; UseOfflineRoot = $false }
            virtualMachines = @([pscustomobject]@{ vmName = 'CA'; role = 'DomainMember'; InstallCA = $true })
        }
    }

    $converted = New-DeployConfig -configObject (New-FixtureConfig)
    Assert-True $script:FailClosedInventory 'PKI retrofit must use fail-closed domain inventory.'
    $targets = @($converted.virtualMachines | Where-Object pkiReconfigure)
    Assert-True (($targets.vmName | Sort-Object) -join ',' -eq 'LAB-CLIENT,LAB-LEGACY,LAB-MPDP,LAB-PRI,LAB-SEC,LAB-SUP') `
        'CA-only UsePKI enablement did not include exactly the existing hierarchy and its client.'
    foreach ($vm in $targets) {
        Assert-True ($vm.hidden -and $vm.phase11Validate) "$($vm.vmName) lost rebuild protection or independent validation."
        Assert-True (-not (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 1) -and
            -not (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 10) -and
            (Test-MemLabsIncludeHiddenVmForPhase -Vm $vm -Phase 11)) 'Retrofit changed hidden VM phase safety.'
    }
    $primary = $converted.virtualMachines | Where-Object vmName -eq 'LAB-PRI'
    Assert-True ($primary.cmOptions.UsePKI -and -not $primary.cmOptions.Install -and $primary.cmOptions.Version -eq '2609') `
        'PKI intent was overwritten, or conversion changed unrelated hierarchy options.'
    Assert-True (-not $script:Inventory[1].cmOptions.UsePKI) 'Planning mutated the deployed hierarchy inventory.'
    Assert-True ((Get-Phase4ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-MPDP') 'Hidden role host missed certificate enrollment.'
    Assert-True ((Get-Phase6ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-SUP') 'Hidden SUP missed WSUS TLS configuration.'
    Assert-True ((Get-Phase8ConfigurationData $converted).AllNodes.NodeName -contains 'LAB-PRI') 'Install=false suppressed the PKI conversion workflow.'
    $dcText = [IO.File]::ReadAllText((Join-Path $root 'DSC\phases\Phase2DC.ps1'))
    $start = $dcText.IndexOf('    $sitecount = 0')
    $end = $dcText.IndexOf('    # Domain creds', $start)
    Assert-True ($start -ge 0 -and $end -gt $start) 'Could not locate production DC group membership selection.'
    $deployConfig = $converted
    $waitOnDomainJoin = [Collections.ArrayList]@()
    $members = @(& ([scriptblock]::Create($dcText.Substring($start, $end - $start) + "`n`$iisgroupMembers")))
    Assert-True ($members -contains 'LAB-MPDP$' -and $members -contains 'LAB-SUP$') 'Existing role hosts missed IIS certificate enrollment permissions.'

    $caOnly = New-FixtureConfig
    $caOnly.cmOptions.UsePKI = $false
    Assert-True (@((New-DeployConfig $caOnly).virtualMachines | Where-Object pkiReconfigure).Count -eq 0) `
        'CA infrastructure without ConfigMgr UsePKI requested a hierarchy conversion.'
    $existingCa = New-FixtureConfig
    $existingCa.virtualMachines = @()
    $existingCa.pkiOptions.IssuingCAVM = 'DC'
    $existingCaDeploy = New-DeployConfig $existingCa
    Assert-True (@($existingCaDeploy.virtualMachines | Where-Object {
                $_.vmName -eq 'LAB-DC' -and $_.hidden -and $_.InstallCA
            }).Count -eq 1) 'Existing selected CA was not included without rebuilding it.'
    Assert-True (@(Get-Phase2ConfigurationData $existingCaDeploy).Count -gt 0) 'All-hidden conversion skipped the DC permissions/policy phase.'

    $script:Inventory += [pscustomobject]@{
        vmName = 'LAB-OTHER'; role = 'Primary'; siteCode = 'OTH'; domain = 'lab.test'; state = 'Running'
        cmOptions = [pscustomobject]@{ UsePKI = $false; Install = $false; Version = '2609' }
    }
    Assert-Throws { New-DeployConfig (New-FixtureConfig) } '*multiple hierarchies*'
    $scoped = New-FixtureConfig
    $scoped.virtualMachines += [pscustomobject]@{
        vmName = 'PRI'; role = 'Primary'; siteCode = 'PRI'; cmOptions = [pscustomobject]@{ UsePKI = $true }
    }
    $scopedDeploy = New-DeployConfig $scoped
    Assert-True ($scopedDeploy.virtualMachines.vmName -notcontains 'LAB-OTHER' -and
        $scopedDeploy.virtualMachines.vmName -notcontains 'FOREIGN-PRI') 'PKI conversion escaped the selected hierarchy/domain.'
    $child = New-FixtureConfig
    $child.virtualMachines += [pscustomobject]@{
        vmName = 'CHILD'; role = 'Primary'; siteCode = 'NEW'; parentSiteCode = 'PRI'
        cmOptions = [pscustomobject]@{ UsePKI = $true }
    }
    $childDeploy = New-DeployConfig $child
    Assert-True (@($childDeploy.virtualMachines | Where-Object pkiReconfigure).Count -eq 0) 'A child-site default silently converted its existing hierarchy.'
    & {
        foreach ($name in @('Install-PKI', 'Test-PKIStepResult')) {
            . (Import-TestFunction (Join-Path $root 'common\Common.PKI.ps1') $name)
        }
        $script:CaSteps = [Collections.Generic.List[string]]::new()
        function Test-Path { [CmdletBinding()]param($LiteralPath) if ($script:CaMode -eq 'Permission') { throw 'fixture denied' }; $script:CaMode -ne 'Unconfigured' }
        function Get-ItemProperty { [CmdletBinding()]param($LiteralPath) [pscustomobject]@{ Active = 'FixtureCA' } }
        function Get-Service {
            [CmdletBinding()]param()
            $status = if ($script:CaMode -eq 'Stopped') { 'Stopped' } else { 'Running' }
            [pscustomobject]@{ Name = 'CertSvc'; Status = $status }
        }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $DisplayName, $ScriptBlock)
            if ($script:CaMode -eq 'Missing') { return }
            $state = & $ScriptBlock
            if ($script:CaMode -eq 'Malformed') { $state.Ready = 'true' }
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $state }
        }
        function Install-PKICertificateTemplates { param($CAVMName, $DomainName, $DeployConfig, $LogPrefix) $script:CaSteps.Add('Templates'); $true }
        function Install-SingleTierPKI { param($DeployConfig) $script:CaSteps.Add('SingleTier'); $true }
        function Install-TwoTierPKI { param($DeployConfig) throw 'An operational existing CA must not start its offline root.' }
        function Initialize-PKIMemberCertificates { param($DeployConfig) $script:CaSteps.Add('Members'); $true }
        $caConfig = [pscustomobject]@{
            vmOptions = @{ domainName = 'lab.test' }
            virtualMachines = @([pscustomobject]@{ vmName = 'CA'; hidden = $true; InstallCA = $true; UseOfflineRoot = $true })
        }
        $script:CaMode = 'Ready'
        Assert-True ((Install-PKI $caConfig) -and ($script:CaSteps -join ',') -eq 'Templates,Members') `
            'Existing healthy issuing CA did not reuse templates without reinstalling/waking its offline root.'
        foreach ($failure in @('Stopped', 'Permission', 'Missing', 'Malformed')) {
            $script:CaSteps.Clear()
            $script:CaMode = $failure
            Assert-True (-not (Install-PKI $caConfig) -and $script:CaSteps.Count -eq 0) "$failure CA inspection incorrectly continued conversion."
        }
        $script:CaSteps.Clear()
        $script:CaMode = 'Unconfigured'
        $caConfig.virtualMachines[0].UseOfflineRoot = $false
        Assert-True ((Install-PKI $caConfig) -and ($script:CaSteps -join ',') -eq 'SingleTier,Members') `
            'An existing VM selected as a new CA skipped actual CA provisioning.'
    }
    Write-Host 'PASS -- existing-hierarchy PKI targeting, intent preservation, permissions, enrollment phases, and rebuild protection.'
}

$functionsPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
foreach ($name in @('Get-MemLabsConfigMgrRoleHttpsState', 'Invoke-MemLabsConfigMgrPkiConversion')) {
    . (Import-TestFunction $functionsPath $name)
}
$script:Calls = [Collections.Generic.List[string]]::new()
$script:Mode = 'Ready'
$script:RoleModes = @{}
$script:SiteMode = 0
function Get-SMSProvider { param($SiteCode) [pscustomobject]@{ FQDN = 'SITE.lab.test' } }
function Set-CMSiteProvider { param($SiteCode, $ProviderFQDN) $script:Mode -ne 'ProviderFailure' }
function Set-Location { [CmdletBinding()]param($Path) }
function Get-CMManagementPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) if ($script:Mode -eq 'ImplicitRoles') { [pscustomobject]@{ Found = $true } } }
function Get-CMDistributionPoint { [CmdletBinding()]param($SiteSystemServerName, $SiteCode) if ($script:Mode -eq 'ImplicitRoles') { [pscustomobject]@{ Found = $true } } }
function Test-Path { param($LiteralPath, $PathType) $script:Mode -ne 'MissingPfx' }
function Get-Content { [CmdletBinding()]param($LiteralPath) 'fixture-password-not-a-credential' }
function Test-MPHttpsBinding { param($MPFQDN) $script:Mode -ne 'MissingBinding' }
function Invoke-DotSource {
    param($Script, $Arguments, [switch]$Rethrow)
    Assert-True ($Rethrow -and $Script -like '*EnableHTTPS.ps1') 'Conversion did not preserve HTTPS failure propagation.'
    $script:Calls.Add('EnableHTTPS')
}
function Set-CMSite {
    [CmdletBinding()]param($SiteCode, $UsePkiClientCertificate, $ClientComputerCommunicationType)
    Assert-True ($UsePkiClientCertificate -and $ClientComputerCommunicationType -eq 'HttpsOnly') 'Site did not request HTTPS-only mode.'
    $script:SiteMode = 1
}
function Set-CMManagementPoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, [bool]$EnableSsl)
    Assert-True $EnableSsl 'MP conversion did not request SSL.'
    if ($script:Mode -eq 'SetFailure') { throw 'fixture MP update failure' }
    $script:Calls.Add("MP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.MP = 63
}
function Set-CMDistributionPoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, $ClientCommunicationType, $CertificatePath,
        [securestring]$CertificatePassword, [switch]$Force)
    Assert-True ($ClientCommunicationType -eq 'Https' -and $CertificatePath -like '*DistributionPointCertificate.pfx' -and
        $null -ne $CertificatePassword -and $Force) 'DP conversion omitted HTTPS or its PKI identity certificate.'
    $script:Calls.Add("DP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.DP = 63
}
function Set-CMSoftwareUpdatePoint {
    [CmdletBinding()]param($SiteSystemServerName, $SiteCode, [bool]$EnableSsl, $HttpPort, $HttpsPort)
    Assert-True ($EnableSsl -and $HttpPort -eq 8530 -and $HttpsPort -eq 8531) 'SUP conversion omitted WSUS TLS settings.'
    $script:Calls.Add("SUP:$SiteSystemServerName/$SiteCode")
    $script:RoleModes.SUP = 1
}
function Get-WmiObject {
    [CmdletBinding()]param($Namespace, $Class, $Filter)
    if ($script:Mode -eq 'SecondaryScope') {
        Assert-True ($Namespace -eq 'root\SMS\site_PRI' -and $Filter -like "*SiteCode='SEC'*") `
            'Secondary role readback used a nonexistent local secondary provider namespace.'
    }
    if ($script:Mode -eq 'MissingRow') { return }
    $role = if ($Filter -like '*Management Point*') { 'MP' } elseif ($Filter -like '*Distribution Point*') { 'DP' } else { 'SUP' }
    $value = $script:RoleModes[$role]
    if ($script:Mode -eq 'NoConvergence') { $value = 0 }
    $name = if ($role -eq 'SUP') { 'SSLWSUS' } else { 'SslState' }
    $row = [pscustomobject]@{
        NALPath = '\\ROLE.lab.test\'
        Props = @([pscustomobject]@{ PropertyName = $name; Value = $value },
            [pscustomobject]@{ PropertyName = 'WSUSIISSSLPort'; Value = 8531 })
    }
    $row | Add-Member -MemberType ScriptMethod -Name Get -Value {}
    if ($script:Mode -eq 'MissingProperty') { $row.Props = @() }
    if ($script:Mode -eq 'InvalidProperty') { $row.Props[0].Value = 'invalid' }
    $row
    if ($script:Mode -eq 'DuplicateRow') { $row }
    if ($script:Mode -eq 'ImplicitRoles') {
        $implicit = $row.PSObject.Copy()
        $implicit.NALPath = '\\SITE.lab.test\'
        $implicit
    }
}
function Wait-CMRoleRegistered {
    param($RoleName, $ServerFQDN, $TimeoutSeconds, $PollSeconds, $Probe)
    & $Probe
}
function Get-CMSite {
    [CmdletBinding()]param($SiteCode)
    if ($script:Mode -eq 'SiteNoConvergence') { [pscustomobject]@{ Mode = 0 } }
    elseif ($script:Mode -ne 'MissingSite') { [pscustomobject]@{ Mode = $script:SiteMode } }
}
function Get-CMSiteComponent {
    [CmdletBinding()]param($SiteCode, $ComponentName)
    [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'IISSSLState'; Value = 63 }) }
}
$site = [pscustomobject]@{
    vmName = 'SITE'; role = 'Primary'; siteCode = 'PRI'; pkiReconfigure = $true
    cmOptions = [pscustomobject]@{ UsePKI = $true }
}
$roleVm = [pscustomobject]@{
    vmName = 'ROLE'; role = 'SiteSystem'; siteCode = 'PRI'; pkiReconfigure = $true
    installMP = $true; installDP = $true; installSUP = $true
}
$guestConfig = [pscustomobject]@{
    vmOptions = @{ domainName = 'lab.test' }
    virtualMachines = @($site, $roleVm,
        [pscustomobject]@{ vmName = 'OTHER'; role = 'SiteSystem'; siteCode = 'OTH'; pkiReconfigure = $true; installMP = $true },
        [pscustomobject]@{ vmName = 'FOREIGN'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'other.test'; pkiReconfigure = $true; installDP = $true })
}
Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
Assert-True (($script:Calls -join ',') -eq 'EnableHTTPS,MP:ROLE.lab.test/PRI,DP:ROLE.lab.test/PRI,SUP:ROLE.lab.test/PRI') `
    'Existing role conversion omitted a role or updated an unrelated hierarchy/domain.'
foreach ($failure in @('ProviderFailure', 'MissingPfx', 'MissingBinding', 'SetFailure', 'NoConvergence', 'MissingRow', 'SiteNoConvergence', 'MissingSite')) {
    $script:Mode = $failure
    Assert-Throws {
        Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
    } '*'
}
foreach ($failure in @('MissingRow', 'DuplicateRow', 'MissingProperty', 'InvalidProperty', 'NoConvergence')) {
    $script:Mode = $failure
    Assert-True (-not (Get-MemLabsConfigMgrRoleHttpsState -ServerFQDN 'ROLE.lab.test' -SiteCode 'PRI' -Role MP).Ready) `
        "$failure incorrectly verified a role as HTTPS."
}
$script:Mode = 'ImplicitRoles'
$script:Calls.Clear()
Invoke-MemLabsConfigMgrPkiConversion -DeployConfig $guestConfig -CurrentVM $site -ConfigFilePath 'fixture.json' -LogPath 'C:\fixture'
Assert-True ($script:Calls.Contains('MP:SITE.lab.test/PRI') -and $script:Calls.Contains('DP:SITE.lab.test/PRI')) `
    'Existing default co-located MP/DP roles were missed because InstallMP/DP flags were absent.'
$script:Mode = 'SecondaryScope'
Assert-True (Get-MemLabsConfigMgrRoleHttpsState -ServerFQDN 'ROLE.lab.test' -SiteCode SEC -Role MP -ProviderSiteCode PRI).Ready `
    'Secondary-site HTTPS readback did not use its managing provider.'
$tokens = $null; $errors = $null
$workflowAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'DSC\phases\ScriptWorkFlow.ps1'), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'ScriptWorkflow has parser errors.'
$refresh = @($workflowAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$requiresTlsRefresh'
        }, $true))
$bounce = @($workflowAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -eq '$requiresTlsRefresh -and -not (Test-Path $mpBounceFlag)'
        }, $true))
Assert-True ($refresh.Count -eq 1 -and $bounce.Count -eq 1) 'Could not locate production MP TLS refresh control flow.'
$bounceBlock = [scriptblock]::Create($refresh[0].Extent.Text + "`n" + $bounce[0].Extent.Text)
$script:BounceCalls = [Collections.Generic.List[string]]::new()
$script:BounceMode = 'Ready'
function Test-Path { param($Path) $false }
function iisreset.exe {
    param($Argument)
    $script:BounceCalls.Add('IIS')
    $global:LASTEXITCODE = 0
    if ($script:BounceMode -eq 'IisFailure') { $global:LASTEXITCODE = 5 }
}
function Restart-Service { [CmdletBinding()]param($Name, [switch]$Force) $script:BounceCalls.Add('CcmExec') }
function Restart-Computer {
    [CmdletBinding()]param($ComputerName, [switch]$Force)
    if ($script:BounceMode -eq 'RestartFailure') { throw 'fixture restart failure' }
    $script:BounceCalls.Add("Restart:$ComputerName")
}
function Start-Sleep { param($Seconds) }
function Get-Service { [CmdletBinding()]param($ComputerName, $Name) [pscustomobject]@{ Status = 'Running' } }
function Set-Content {
    [CmdletBinding()]param($Path, $Value, [switch]$Force, $Encoding)
    if ($script:BounceMode -eq 'StampFailure') { throw 'fixture flag write failure' }
    $script:BounceCalls.Add('Stamp')
}
$local = $site.PSObject.Copy()
$local | Add-Member -MemberType NoteProperty -Name installMP -Value $true
$ThisVM = $local
$deployConfig = [pscustomobject]@{ virtualMachines = @($local, $roleVm) }
$DomainFullName = 'lab.test'
$mpBounceFlag = 'C:\fixture\mp.flag'
$needCertPulse = $false
& $bounceBlock
Assert-True (($script:BounceCalls -join ',') -eq 'IIS,CcmExec,Restart:ROLE,Stamp') `
    'PKI retrofit skipped local/remote MP TLS refresh when no new client push was required.'
foreach ($failure in @('IisFailure', 'RestartFailure', 'StampFailure')) {
    $script:BounceCalls.Clear()
    $script:BounceMode = $failure
    Assert-Throws { & $bounceBlock } '*'
    Assert-True (-not $script:BounceCalls.Contains('Stamp')) "$failure incorrectly recorded a successful TLS refresh."
}
$script:BounceCalls.Clear()
$ThisVM.pkiReconfigure = $false
& $bounceBlock
Assert-True ($script:BounceCalls.Count -eq 0) 'An ordinary already-installed client triggered a new MP TLS restart.'
Write-Host 'PASS -- existing MP/DP/SUP HTTPS updates, independent site-control readback, scoped targets, and failure propagation.'
Write-Host 'PASS -- existing MP TLS refresh is required without client push and cannot silently ignore restart or receipt failures.'
