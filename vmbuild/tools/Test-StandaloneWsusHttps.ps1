#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', '', Justification = 'The fixture executes an extracted DSC method body using its production $this variable.')]
[CmdletBinding()]
param([switch]$CompileDsc)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($CompileDsc) {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'DSC compilation must run under Windows PowerShell 5.1.' }
    if (-not (Test-Path -LiteralPath 'C:\temp' -PathType Container)) { throw 'Compile prerequisite C:\temp is absent; the test will not create it.' }
    $build = Join-Path $env:TEMP ('memlabs-wsus-mof-' + [guid]::NewGuid().ToString('N'))
    $moduleRoot = Join-Path $build 'Modules'
    $null = New-Item -ItemType Directory -Path $moduleRoot -Force
    $links = @()
    $savedModulePath = $env:PSModulePath
    try {
        foreach ($name in @('ComputerManagementDsc', 'UpdateServicesDsc')) {
            $module = Get-Module -ListAvailable -Name $name | Sort-Object Version -Descending | Select-Object -First 1
            if (-not $module) { throw "Compile prerequisite $name is absent." }
            $link = Join-Path $moduleRoot $name
            $null = New-Item -ItemType Junction -Path $link -Target $module.ModuleBase
            $links += $link
        }
        $link = Join-Path $moduleRoot 'TemplateHelpDSC'
        $null = New-Item -ItemType Junction -Path $link -Target (Join-Path $root 'DSC\TemplateHelpDSC')
        $links += $link
        $env:PSModulePath = "$moduleRoot;$PSHOME\Modules"
        function Set-ExecutionPolicy {
            param($ExecutionPolicy, [switch]$Force)
            if ($ExecutionPolicy -ne 'Bypass') { throw 'Unexpected execution-policy request during compilation.' }
        }
        . (Join-Path $root 'DSC\phases\Phase6.ps1')
        . (Join-Path $root 'DSC\phases\Phase7.ps1')
        $password = [Security.SecureString]::new()
        $password.AppendChar('x')
        $credential = [pscredential]::new('LAB\fixture', $password)
        $cases = @(
            @{ Name = 'http'; Role = 'WSUS'; Https = $false; CmHttps = $true; Sql = $false },
            @{ Name = 'https-wid'; Role = 'WSUS'; Https = $true; CmHttps = $false; Sql = $false },
            @{ Name = 'https-sql'; Role = 'WSUS'; Https = $true; CmHttps = $false; Sql = $true },
            @{ Name = 'cm-unchanged'; Role = 'Primary'; Https = $false; CmHttps = $true; Sql = $false }
        )
        foreach ($case in $cases) {
            $vm = [pscustomobject]@{
                vmName = 'WSUS1'; role = $case.Role; wsusUseHTTPS = $case.Https
                wsusContentDir = 'E:\WSUS'; installSUP = ($case.Role -ne 'WSUS')
                cmOptions = [pscustomobject]@{ UsePKI = $case.CmHttps }
                siteCode = 'PRI'
            }
            $vms = @($vm)
            if ($case.Sql) {
                $vm | Add-Member -NotePropertyName wsusDataBaseServer -NotePropertyValue 'SQL1'
                $vms += [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember'; sqlInstanceName = 'MSSQLSERVER'; sqlPort = 1433 }
            }
            $config = [pscustomobject]@{
                parameters = @{ domainName = 'lab.test' }
                vmOptions = @{ domainName = 'lab.test'; adminName = 'fixture' }
                virtualMachines = $vms
            }
            $path = Join-Path $build ($case.Name + '.json')
            $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
            $cd = @{ AllNodes = @(@{ NodeName = 'WSUS1'; Role = 'WSUS'; PSDscAllowDomainUser = $true; PSDscAllowPlainTextPassword = $true }) }
            $six = Join-Path $build ($case.Name + '-6')
            $seven = Join-Path $build ($case.Name + '-7')
            Phase6 -DeployConfigPath $path -Admincreds $credential -ConfigurationData $cd -OutputPath $six | Out-Null
            Phase7 -DeployConfigPath $path -Admincreds $credential -ConfigurationData $cd -OutputPath $seven | Out-Null
            $mof6 = Get-Content -LiteralPath (Join-Path $six 'WSUS1.mof') -Raw
            $mof7 = Get-Content -LiteralPath (Join-Path $seven 'WSUS1.mof') -Raw
            $wanted = if ($case.Https) { 'True' } else { 'False' }
            if ($mof6 -notmatch "StandaloneHTTPS = $wanted;" -or $mof7 -notmatch "UseSsl = $wanted;") {
                throw "$($case.Name): standalone transport did not reach both compiled resource instances."
            }
            $usesTls = $case.Https -or ($case.Role -ne 'WSUS' -and $case.CmHttps)
            if ($usesTls -and $mof6 -notmatch 'HTTPSUrl = "WSUS1.lab.test";') { throw "$($case.Name): compiled FQDN is missing." }
            if ($case.Sql -and $mof6 -notmatch 'SqlServer = "SQL1";') { throw 'Standalone explicit SQL placement did not reach ConfigureWSUS.' }
        }
        Write-Host 'PASS -- source-isolated Phase 6/7 compilation: 4 transport/database cases, 8 MOFs; none applied.'
    }
    finally {
        $env:PSModulePath = $savedModulePath
        foreach ($junction in $links) { [IO.Directory]::Delete($junction) }
        Remove-Item -LiteralPath $build -Recurse -Force
    }
    return
}
function Read-TestAst {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path parse errors: $($errors -join '; ')" }
    return $ast
}
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $ast = Read-TestAst $Path
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name in $Path." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = ''
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($caught -match $Pattern) "Expected failure '$Pattern', got '$caught'."
}
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Failure, [switch]$Warning) }
function Write-Status { param($Status) }
$script:Inventory = @()
function Get-List { param($Type, $DomainName) $script:Inventory }
$script:Errors = @()
function Add-ErrorMessage { param($Message, $Property, [switch]$Persist) $script:Errors += $Message }
function Add-ValidationMessage { param($Message, $ReturnObject, [switch]$Failure) $script:Errors += $Message }

$configPath = Join-Path $root 'common\Common.Config.ps1'
foreach ($name in @('Get-LabWsusUrl', 'Test-PushClientRequested', 'Get-UserConfiguration',
    'Resolve-ConfigVmReference', 'Test-SiteSystemClientOperatingSystem',
    'Resolve-ConfigCmVersionAliases', 'Move-CmOptionsToTopLevelSiteServer')) {
    . (Import-TestFunction $configPath $name)
}
. (Import-TestFunction (Join-Path $root 'common\Common.GenConfig.Validation.ps1') 'Get-AdditionalValidations')
. (Import-TestFunction (Join-Path $root 'common\Common.GenConfig.ConfigFiles.ps1') 'Write-ConfigJsonFile')
foreach ($name in @('Test-ValidStandaloneWsusHttps', 'Resolve-DomainVmReference')) {
    . (Import-TestFunction (Join-Path $root 'common\Common.Validation.ps1') $name)
}
. (Import-TestFunction (Join-Path $root 'Common.ps1') 'Test-VmIsLinux')

$wsus = [pscustomobject]@{ vmName = 'WSUS1'; role = 'WSUS'; wsusUseHTTPS = $true }
$global:Config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'lab.test'; prefix = ''; domainNetBiosName = 'LAB' }
    pkiOptions = [pscustomobject]@{ EnablePKI = $false; IssuingCAVM = ''; UseOfflineRoot = $false; OfflineRootCAVM = '' }
    virtualMachines = @([pscustomobject]@{ vmName = 'DC1'; role = 'DC'; operatingSystem = 'Server 2022' }, $wsus)
}
Get-AdditionalValidations -property $wsus -name wsusUseHTTPS -CurrentValue $false
Assert-True ($global:Config.pkiOptions.EnablePKI -and $global:Config.pkiOptions.IssuingCAVM -eq 'DC1') 'HTTPS opt-in did not enable independent CA infrastructure.'
Assert-True (-not $global:Config.PSObject.Properties['cmOptions']) 'Standalone HTTPS created ConfigMgr options.'
Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
Assert-True ($script:Errors.Count -eq 0) "Valid standalone config failed: $($script:Errors)"
foreach ($cmMode in @($false, $true)) {
    $global:Config | Add-Member -NotePropertyName cmOptions -NotePropertyValue ([pscustomobject]@{ UsePKI = $cmMode; Version = '2309' }) -Force
    foreach ($wsusMode in @($false, $true)) {
        $wsus.wsusUseHTTPS = $wsusMode
        $before = $global:Config.cmOptions | ConvertTo-Json -Compress
        Get-AdditionalValidations -property $wsus -name wsusUseHTTPS -CurrentValue (-not $wsusMode)
        Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
        $url = Get-LabWsusUrl -DeployConfig $global:Config -CurrentItem $wsus
        $expected = if ($wsusMode) { 'https://WSUS1.lab.test:8531' } else { 'http://WSUS1.lab.test:8530' }
        Assert-True ($url.WsusUrl -eq $expected) 'Standalone URL inherited ConfigMgr transport.'
        Assert-True (($global:Config.cmOptions | ConvertTo-Json -Compress) -ceq $before) 'WSUS HTTPS changed ConfigMgr options.'
    }
}
$script:Errors = @()
$wsus.wsusUseHTTPS = 'false'
Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
Assert-True (($script:Errors -join ' ') -match 'Boolean') 'A string flag was silently coerced.'
$wsus.wsusUseHTTPS = $true
$script:Inventory = @([pscustomobject]@{ vmName = 'WSUS1'; role = 'WSUS' })
$script:Errors = @()
Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
Assert-True (($script:Errors -join ' ') -match 'deployed') 'Existing HTTP WSUS conversion was accepted.'
$script:Inventory[0] | Add-Member -NotePropertyName wsusUseHTTPS -NotePropertyValue $true
$script:Errors = @()
Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
Assert-True ($script:Errors.Count -eq 0) 'A feature-deployed HTTPS WSUS could not be revalidated.'
$script:Inventory = @()
$global:Config.pkiOptions.EnablePKI = $false
$script:Errors = @()
Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
Assert-True (($script:Errors -join ' ') -match 'EnablePKI') 'Missing PKI dependency was accepted.'
$global:Config.pkiOptions.EnablePKI = $true
$newCa = $global:Config.virtualMachines[0]
foreach ($inConfig in @($false, $true)) {
    $script:Inventory = @([pscustomobject]@{ vmName = 'DC1'; role = 'DC'; operatingSystem = 'Server 2022'; InstallCA = $false })
    $newCa | Add-Member -NotePropertyName InstallCA -NotePropertyValue $true -Force
    if (-not $inConfig) { $global:Config.virtualMachines = @($wsus) }
    $script:Errors = @()
    Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
    Assert-True (($script:Errors -join ' ') -match 'IssuingCA') 'A desired CA flag or absent UI marker hid an existing non-CA.'
    $script:Inventory[0].InstallCA = $true
    $script:Errors = @()
    Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
    Assert-True ($script:Errors.Count -eq 0) 'Authoritative existing CA inventory was rejected.'
    $global:Config.virtualMachines = @($newCa, $wsus)
}
$script:Inventory = @()

$caCases = @(
    foreach ($role in @('DC', 'BDC', 'DomainMember', 'CAS', 'Primary', 'Secondary', 'PassiveSite', 'SiteSystem', 'WSUS', 'FileServer', 'SQLAO')) {
        @{ Role = $role; OS = 'Server 2022'; Family = 'Windows'; Expected = $true }
    }
    foreach ($role in @('OtherDC', 'StandaloneRootCA', 'WorkgroupMember', 'AADClient', 'InternetClient', 'Proxy', 'LinuxServer', 'LinuxClient', 'DHCPRelay', 'OSDClient', 'Unknown')) {
        @{ Role = $role; OS = 'Server 2022'; Family = 'Windows'; Expected = $false }
    }
    foreach ($os in @($null, 'Windows 11 Latest', 'Ubuntu Server 24.04 LTS', 'Debian 12', 'Linux Server 2025')) {
        @{ Role = 'DomainMember'; OS = $os; Family = ''; Expected = $false }
    }
    @{ Role = 'DomainMember'; OS = 'Server 2022'; Family = 'Linux'; Expected = $false }
    @{ Role = 'DomainMember'; OS = 'Server 2022'; DeployedOS = 'Ubuntu Server 24.04 LTS'; Expected = $false }
    @{ Role = 'DomainMember'; OS = 'Server 2022'; Domain = 'other.test'; Expected = $false }
    @{ Role = 'DomainMember'; OS = $null; DeployedOS = 'Server 2022'; Expected = $true }
    @{ Role = 'DomainMember'; OS = 'Windows Server 2025'; Expected = $true }
    @{ Role = 'OSDClient'; OS = $null; Expected = $false }
    @{ Role = 'DHCPRelay'; OS = 'Ubuntu Server 24.04 LTS'; Family = 'Linux'; Expected = $false }
)
foreach ($placement in @('New', 'ExistingInConfig', 'ExistingOutsideConfig')) {
    foreach ($case in $caCases) {
        $candidate = [pscustomobject]@{
            vmName = 'DC1'; role = $case.Role; operatingSystem = $case.OS
            deployedOS = $case.DeployedOS; osFamily = $case.Family; domain = $case.Domain; InstallCA = $true
        }
        $global:Config.virtualMachines = @($candidate, $wsus)
        $script:Inventory = @()
        if ($placement -ne 'New') { $script:Inventory = @($candidate) }
        if ($placement -eq 'ExistingOutsideConfig') { $global:Config.virtualMachines = @($wsus) }
        $script:Errors = @()
        Test-ValidStandaloneWsusHttps -ConfigObject $global:Config -ReturnObject @{}
        Assert-True (($script:Errors.Count -eq 0) -eq $case.Expected) "CA eligibility was wrong for $placement / $($case.Role) / $($case.OS) / $($case.Family)."
    }
}
$global:Config.virtualMachines = @($newCa, $wsus)
$script:Inventory = @()

$pkiAst = Read-TestAst (Join-Path $root 'common\Common.PKI.ps1')
$pkiDefinition = $pkiAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-PKICertificateTemplates'
}, $true)
Set-Item -Path function:Install-PKICertificateTemplates -Value $pkiDefinition.Body.GetScriptBlock()
function Flush-LogBuffer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'The fixture must match the existing production command name.')]
    [CmdletBinding()]
    param([switch]$All)
}
$script:TemplateCalls = @(); $script:PublishOk = $true
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName)
    $script:TemplateCalls += ,$ArgumentList
    [pscustomobject]@{ ScriptBlockOutput = [pscustomobject]@{ Success = $script:PublishOk } }
}
function Test-PKIStepResult { param($Result, $StepName, $LogPrefix, $LogSource) $Result.ScriptBlockOutput.Success }
$global:Config.PSObject.Properties.Remove('cmOptions')
Assert-True (Install-PKICertificateTemplates -CAVMName DC1 -DomainName lab.test -DeployConfig $global:Config -LogPrefix fixture -StandaloneWsusOnly) 'Existing CA web-template preparation failed.'
$arguments = $script:TemplateCalls[-1]
Assert-True ($arguments[1] -eq 'ConfigMgrWebServerCertificate' -and $arguments[2] -eq 'WSUS1' -and -not $arguments[3] -and $arguments[4]) 'Standalone preparation touched CM grants/templates or lost its consumer/template source.'
$script:PublishOk = $false
Assert-True (-not (Install-PKICertificateTemplates -CAVMName DC1 -DomainName lab.test -DeployConfig $global:Config -LogPrefix fixture -StandaloneWsusOnly)) 'Template publication failure was ignored.'
$script:PublishOk = $true
$wsus.wsusUseHTTPS = $false
$calls = $script:TemplateCalls.Count
Assert-True (Install-PKICertificateTemplates -CAVMName DC1 -DomainName lab.test -DeployConfig $global:Config -LogPrefix fixture -StandaloneWsusOnly) 'No-consumer preparation failed.'
Assert-True ($script:TemplateCalls.Count -eq $calls) 'No-consumer preparation contacted a CA.'
$wsus.wsusUseHTTPS = $true

$scratch = Join-Path $env:TEMP ("memlabs-wsus-https-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    $savedPath = Join-Path $scratch 'config.json'
    $global:Config.PSObject.Properties.Remove('cmOptions')
    foreach ($mode in @($false, $true)) {
        $wsus.wsusUseHTTPS = $mode
        Write-ConfigJsonFile -Config $global:Config -Path $savedPath
        $loaded = Get-UserConfiguration -Configuration $savedPath
        Assert-True $loaded.Loaded "Saved configuration did not reload: $($loaded.Message)"
        Assert-True ($loaded.Config.virtualMachines[1].wsusUseHTTPS -is [bool] -and $loaded.Config.virtualMachines[1].wsusUseHTTPS -eq $mode) 'WSUS HTTPS did not round-trip as a Boolean.'
        Assert-True (-not $loaded.Config.cmOptions) 'Loading standalone configuration introduced ConfigMgr.'
    }
    $wsus.PSObject.Properties.Remove('wsusUseHTTPS')
    Write-ConfigJsonFile -Config $global:Config -Path $savedPath
    $loaded = Get-UserConfiguration -Configuration $savedPath
    Assert-True ($loaded.Loaded -and $loaded.Config.virtualMachines[1].wsusUseHTTPS -ceq $false) 'Legacy standalone WSUS did not default to HTTP.'
}
finally {
    Remove-Item -LiteralPath (Join-Path $scratch 'config.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Force
}

. (Join-Path $root 'DSC\TemplateHelpDSC\WsusHttps.ps1')
$templateBytes = [byte[]]@(0x30,0x0d,0x06,0x05,0x2b,0x06,0x01,0x04,0x01,0x02,0x01,0x01,0x02,0x01,0x00)
function New-FixtureCertificate {
    param([string]$Thumbprint = 'AABB', [string]$DnsName = 'WSUS1.lab.test')
    $sanBuilder = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $sanBuilder.AddDnsName($DnsName)
    [pscustomobject]@{
        Thumbprint = $Thumbprint; HasPrivateKey = $true
        NotBefore = (Get-Date).AddDays(-1); NotAfter = (Get-Date).AddDays(90)
        Issuer = 'CN=Lab CA'; Subject = 'CN=WSUS1.lab.test'
        DnsNameList = @([pscustomobject]@{ Unicode = 'WSUS1.lab.test' })
        EnhancedKeyUsageList = @([pscustomobject]@{ ObjectId = '1.3.6.1.5.5.7.3.1' })
        Extensions = @($sanBuilder.Build(), [pscustomobject]@{ Oid = [pscustomobject]@{ Value = '1.3.6.1.4.1.311.21.7' }; RawData = $templateBytes })
    }
}
$cert = New-FixtureCertificate
$script:FixtureCertificate = $cert
Assert-True (Test-MemLabsWsusCertificateIdentity $cert 'WSUS1.lab.test' '1.3.6.1.4.1') 'Typed certificate template/SAN/EKU matching rejected the expected identity.'
foreach ($property in @('HasPrivateKey', 'NotAfter', 'NotBefore', 'SAN', 'EnhancedKeyUsageList')) {
    $bad = New-FixtureCertificate
    switch ($property) {
        HasPrivateKey { $bad.HasPrivateKey = $false }
        NotAfter { $bad.NotAfter = (Get-Date).AddDays(-1) }
        NotBefore { $bad.NotBefore = (Get-Date).AddDays(1) }
        SAN { $bad = New-FixtureCertificate -DnsName 'WSUS1.lab.test.attacker.test' }
        EnhancedKeyUsageList { $bad.EnhancedKeyUsageList = @([pscustomobject]@{ ObjectId = '1.3.6.1.5.5.7.3.2' }) }
    }
    Assert-True (-not (Test-MemLabsWsusCertificateIdentity $bad 'WSUS1.lab.test' '1.3.6.1.4.1')) "Invalid $property certificate was accepted."
}
Assert-True (-not (Test-MemLabsWsusCertificateIdentity $cert 'WSUS1.lab.test' '1.2.3.4')) 'A different template was accepted.'
Assert-Throws { Assert-MemLabsWsusCertificateChain -Certificate ([Security.Cryptography.X509Certificates.X509Certificate2]::new()) } '.'

$rsa = [Security.Cryptography.RSACng]::new(2048)
$issuer = $null
try {
    $issuerRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Fixture CA', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $issuerRequest.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
    $issuer = $issuerRequest.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-2), [DateTimeOffset]::Now.AddDays(365))
    foreach ($case in @('missing', 'email', 'wrong', 'correct', 'wildcard', 'suffix')) {
        $subject = if ($case -eq 'correct') { 'CN=Different name' } else { 'CN=WSUS1.lab.test' }
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $eku = [Security.Cryptography.OidCollection]::new()
        $null = $eku.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509Extension]::new('1.3.6.1.4.1.311.21.7', $templateBytes, $false))
        $sanBuilder = [Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        switch ($case) {
            email { $sanBuilder.AddEmailAddress('WSUS1.lab.test@example.test') }
            wrong { $sanBuilder.AddDnsName('other.lab.test') }
            correct { $sanBuilder.AddDnsName('WSUS1.lab.test') }
            wildcard { $sanBuilder.AddDnsName('*.lab.test') }
            suffix { $sanBuilder.AddDnsName('WSUS1.lab.test.attacker.test') }
        }
        if ($case -ne 'missing') { $request.CertificateExtensions.Add($sanBuilder.Build()) }
        $public = $request.Create($issuer, [DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(90), [byte[]]@(1,2,3))
        $signed = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($public, $rsa)
        try {
            Assert-True ((Test-MemLabsWsusCertificateIdentity $signed 'WSUS1.lab.test' '1.3.6.1.4.1') -eq ($case -eq 'correct')) "Real certificate SAN case '$case' was misclassified."
        }
        finally { $signed.Dispose(); $public.Dispose() }
    }
}
finally { if ($issuer) { $issuer.Dispose() }; $rsa.Dispose() }

function Get-MemLabsWsusTemplateOid { '1.3.6.1.4.1' }
$script:Certs = @($cert)
function Get-ChildItem {
    param($Path)
    if ($Path -ne 'Cert:\LocalMachine\My') { throw "Unexpected certificate path $Path." }
    $script:Certs
}
Assert-True ((Get-MemLabsWsusHttpsCertificate -Fqdn 'WSUS1.lab.test').Thumbprint -eq 'AABB') 'Existing eligible certificate was not reused.'
$newer = New-FixtureCertificate 'CCDD'
$newer.NotAfter = (Get-Date).AddDays(180)
$script:Certs = @($newer, $cert)
Assert-True ((Get-MemLabsWsusHttpsCertificate -Fqdn 'WSUS1.lab.test').Thumbprint -eq 'CCDD') 'Renewed certificate selection depended on store order.'
$script:Certs = @($cert, $newer)
Assert-True ((Get-MemLabsWsusHttpsCertificate -Fqdn 'WSUS1.lab.test').Thumbprint -eq 'CCDD') 'Renewed certificate selection changed with store order.'

function Import-Module { param($Name) }
$script:ChainBad = $false
function Assert-MemLabsWsusCertificateChain {
    param($Certificate)
    if ($script:ChainBad) { throw 'Fixture revocation failure.' }
}
$script:Certs = @($cert)
$script:Flags = @{}
$required = @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')
foreach ($path in @('') + $required + @('Content','Inventory','ReportingWebService','SelfUpdate')) {
    $location = if ($path) { "WSUS Administration/$path" } else { 'WSUS Administration' }
    $script:Flags[$location] = if ($path -in $required) { 8 } else { 0 }
}
$script:Binding = [pscustomobject]@{ certificateHash = 'AABB'; certificateStoreName = 'My' }
$script:BindMode = 'Normal'
$script:Binding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value {
    param($Thumbprint, $Store)
    if ($script:BindMode -eq 'Throw') { throw 'Fixture binding error.' }
    if ($script:BindMode -eq 'NonTerminating') { Write-Error 'Fixture binding error.'; return }
    if ($script:BindMode -eq 'NoOp') { return }
    $this.certificateHash = $Thumbprint; $this.certificateStoreName = $Store
}
$originalBinding = $script:Binding
$script:HasHttp = $true; $script:UsingSsl = 1; $script:ApiCalls = 0; $script:LocalReady = $true
function Get-WebBinding {
    param($Name, $Protocol, $Port)
    if ($Name -ne 'WSUS Administration' -or $Port -notin 8530,8531) { throw 'A non-WSUS binding was accessed.' }
    if ($Protocol -eq 'https') {
        if ($script:Binding) { return $script:Binding }
        return
    }
    if ($script:HasHttp) { return [pscustomobject]@{} }
}
function Get-WebConfigurationProperty { param($PSPath, $Location, $Filter, $Name) [pscustomobject]@{ Value = $script:Flags[$Location] } }
function Get-ItemProperty { param($LiteralPath) [pscustomobject]@{ UsingSSL = $script:UsingSsl } }
function Get-WsusServer {
    param($Name, $PortNumber, [switch]$UseSsl)
    if ($Name) {
        if ($Name -ne 'WSUS1.lab.test' -or $PortNumber -ne 8531 -or -not $UseSsl) { throw 'WSUS API used an insecure or incorrect endpoint.' }
        $script:ApiCalls++
    }
    elseif (-not $script:LocalReady) { return }
    [pscustomobject]@{ Version = 'fixture' }
}
Assert-True (Get-MemLabsWsusHttpsState -Fqdn 'WSUS1.lab.test').Passed 'Valid WSUS HTTPS state failed.'
foreach ($key in @($script:Flags.Keys)) { $script:Flags[$key] = if ($script:Flags[$key] -eq 8) { 'Ssl' } else { 'None' } }
Assert-True (Get-MemLabsWsusHttpsState -Fqdn 'WSUS1.lab.test').Passed 'IIS string-valued SSL flags were rejected.'
foreach ($key in @($script:Flags.Keys)) { $script:Flags[$key] = if ($script:Flags[$key] -eq 'Ssl') { 8 } else { 0 } }
foreach ($fault in @('Binding', 'Http', 'Flags', 'Mode', 'Revocation')) {
    switch ($fault) {
        Binding { $script:Binding.certificateHash = 'DEAD' }
        Http { $script:HasHttp = $false }
        Flags { $script:Flags['WSUS Administration/Content'] = 8 }
        Mode { $script:UsingSsl = 0 }
        Revocation { $script:ChainBad = $true }
    }
    $state = Get-MemLabsWsusHttpsState -Fqdn 'WSUS1.lab.test'
    Assert-True (-not $state.Passed -and ($state.Details -join ' ') -match 'FAIL') "$fault drift passed HTTPS validation."
    $script:Binding.certificateHash = 'AABB'; $script:HasHttp = $true; $script:UsingSsl = 1
    $script:Flags['WSUS Administration/Content'] = 0; $script:ChainBad = $false
}
$nativeInvoker = ${function:Invoke-MemLabsWsusUtil}
$script:UtilArguments = @()
$script:UtilFails = $false; $script:BadUrl = $false
function Invoke-MemLabsWsusUtil {
    param($Arguments)
    $script:UtilArguments += ,$Arguments
    if ($script:UtilFails) { throw 'Fixture configuressl exit 7.' }
    if ($Arguments[0] -eq 'postinstall') { $script:LocalReady = $true; return 'postinstall completed' }
    if ($script:BadUrl) { return 'https://other.lab.test:8531' }
    'https://WSUS1.lab.test:8531'
}
$script:Enrolled = @()
$script:EnrollmentPending = $false
function klist.exe { $global:LASTEXITCODE = 0; 'fixture machine ticket cache' }
function Get-Certificate {
    param($Template, $SubjectName, $DnsName, $CertStoreLocation)
    $script:Enrolled += ,@($Template, $SubjectName, $DnsName, $CertStoreLocation)
    if ($script:EnrollmentPending) { return [pscustomobject]@{ Certificate = $null; Status = 'Pending' } }
    $script:Certs = @($script:FixtureCertificate)
    [pscustomobject]@{ Certificate = $script:FixtureCertificate; Status = 'Issued' }
}
function Set-WebConfigurationProperty {
    param($PSPath, $Location, $Filter, $Name, $Value)
    if (-not $script:Flags.ContainsKey($Location)) { throw "Non-WSUS SSL mutation $Location." }
    $script:Flags[$Location] = if ($Value -eq 'Ssl') { 8 } else { 0 }
}
function New-WebBinding {
    param($Name, $IPAddress, $Port, $Protocol)
    if ($Name -ne 'WSUS Administration' -or $Port -notin 8530,8531) { throw 'Non-WSUS binding mutation.' }
    if ($Protocol -eq 'https') { $script:Binding = $originalBinding }
    else { $script:HasHttp = $true }
}
$script:Binding.certificateHash = 'DEAD'
$script:Flags['WSUS Administration/ClientWebService'] = 0
Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test'
Assert-True ((Get-MemLabsWsusHttpsState -Fqdn 'WSUS1.lab.test').Passed) 'TLS repair did not converge.'
Assert-True ($script:UtilArguments.Count -eq 1 -and ($script:UtilArguments[0] -join ',') -eq 'configuressl,WSUS1.lab.test') 'TLS repair ran postinstall or used the wrong name.'
$script:UtilFails = $true
Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'exit 7'
$script:UtilFails = $false
$script:BadUrl = $true
Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'expected HTTPS URL'
$script:BadUrl = $false
$script:UsingSsl = 0
Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'SSL mode'
$script:UsingSsl = 1
$script:Binding = @($originalBinding, $originalBinding)
$calls = $script:UtilArguments.Count
Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'Ambiguous'
Assert-True ($calls -eq $script:UtilArguments.Count) 'Ambiguous bindings reached configuressl.'
$script:Binding = $originalBinding
foreach ($failure in @('Throw', 'NonTerminating', 'NoOp')) {
    $script:BindMode = $failure
    $script:Binding.certificateHash = 'OLD'
    $flagsBefore = $script:Flags | ConvertTo-Json -Compress
    $calls = $script:UtilArguments.Count
    Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'binding'
    Assert-True (($script:Flags | ConvertTo-Json -Compress) -ceq $flagsBefore -and $script:UtilArguments.Count -eq $calls) 'Failed binding continued into SSL/native mutations.'
    Assert-True ($script:Binding.certificateHash -eq 'OLD' -and $script:Certs.Count -eq 1) 'Failed binding deleted certificates or lost the prior binding.'
}
$script:BindMode = 'Normal'
$script:Binding = $null; $script:HasHttp = $false
Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test'
Assert-True ($script:Binding.certificateHash -eq 'AABB' -and $script:HasHttp) 'Missing HTTPS/HTTP bindings were not reconciled.'
$script:Certs = @(); $script:EnrollmentPending = $true
$calls = $script:UtilArguments.Count
Assert-Throws { Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test' } 'Pending'
Assert-True ($calls -eq $script:UtilArguments.Count) 'Unissued enrollment reached TLS mutation.'
$script:EnrollmentPending = $false
Enable-MemLabsWsusHttps -Fqdn 'WSUS1.lab.test'
Assert-True (($script:Enrolled[-1] -join ',') -eq 'ConfigMgrWebServerCertificate,CN=WSUS1.lab.test,WSUS1.lab.test,Cert:\LocalMachine\My') 'Enrollment used the wrong template, subject/SAN, or store.'

# Execute the production DSC Set body without installing or registering a resource.
$moduleAst = Read-TestAst (Join-Path $root 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1')
$resource = $moduleAst.Find({ param($node) $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'ConfigureWSUS' }, $true)
$setBody = ($resource.Members | Where-Object Name -eq Set).Body
$set = [scriptblock]::Create($setBody.Extent.Text.Trim().Substring(1, $setBody.Extent.Text.Trim().Length - 2))
$this = [pscustomobject]@{ StandaloneHTTPS = $true; HTTPSUrl = 'WSUS1.lab.test'; ContentPath = 'fixture-wsus'; SqlServer = '' }
$this | Add-Member -MemberType ScriptMethod -Name HardenWsusPool -Value {}
$this | Add-Member -MemberType ScriptMethod -Name EnsureIisMetabaseHealthy -Value { $true }
$script:WidGrants = 0
$this | Add-Member -MemberType ScriptMethod -Name GrantWidSysadmin -Value { $script:WidGrants++ }
$script:UtilArguments = @()
& $set
Assert-True ($script:UtilArguments.Count -eq 1 -and $script:UtilArguments[0][0] -eq 'configuressl') 'TLS-only DSC resume repeated WSUS postinstall.'
function New-Item {
    param($Path, $ItemType, [switch]$Force)
    if ($Path -ne 'fixture-wsus') { throw "Unexpected directory creation: $Path" }
}
foreach ($sql in @('', 'SQL1\UPDATES,1435')) {
    $this.SqlServer = $sql
    $script:LocalReady = $false; $script:UtilArguments = @(); $script:WidGrants = 0
    & $set
    Assert-True ($script:UtilArguments.Count -eq 2 -and $script:UtilArguments[0][0] -eq 'postinstall' -and $script:UtilArguments[1][0] -eq 'configuressl') 'Fresh WSUS did not run postinstall before HTTPS configuration.'
    Assert-True (($script:UtilArguments[0] -contains 'CONTENT_DIR=fixture-wsus') -and ($script:WidGrants -eq [int](-not $sql))) 'Postinstall content path or WID-only grant was incorrect.'
    if ($sql) { Assert-True ($script:UtilArguments[0] -contains "SQL_INSTANCE_NAME=$sql") 'Postinstall lost the explicit SQL instance/port.' }
}
$script:LocalReady = $false; $script:UtilFails = $true; $script:UtilArguments = @()
Assert-Throws { & $set } 'exit 7'
Assert-True ($script:UtilArguments.Count -eq 1) 'Failed postinstall advanced to HTTPS configuration.'
$script:UtilFails = $false; $script:LocalReady = $true

$nativeScratch = [IO.Path]::Combine($env:TEMP, 'memlabs-wsus-native-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($nativeScratch)
$script:NativeTool = [IO.Path]::Combine($nativeScratch, 'wsus-fixture.cmd')
function Join-Path {
    param($Path, $ChildPath)
    if ($ChildPath -eq 'Update Services\Tools\WsusUtil.exe') { return $script:NativeTool }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}
try {
    [IO.File]::WriteAllText($script:NativeTool, "@echo off`r`necho fixture stderr 1>&2`r`nexit /b 0`r`n")
    $null = & $nativeInvoker -Arguments @('configuressl', 'WSUS1.lab.test')
    [IO.File]::WriteAllText($script:NativeTool, "@echo off`r`necho fixture stderr 1>&2`r`nexit /b 7`r`n")
    Assert-Throws { & $nativeInvoker -Arguments @('configuressl', 'WSUS1.lab.test') } 'exit 7.*fixture stderr'
}
finally {
    [IO.File]::Delete($script:NativeTool)
    [IO.Directory]::Delete($nativeScratch)
}

. (Import-TestFunction (Microsoft.PowerShell.Management\Join-Path $root 'common\Common.Validation.Functional.ps1') 'Test-WSUSFunctionality')
$observerDir = [IO.Path]::Combine($env:TEMP, 'memlabs-wsus-observer-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($observerDir)
$observerPath = [IO.Path]::Combine($observerDir, 'WsusHttps.ps1')
[IO.File]::WriteAllText($observerPath, @'
function Get-MemLabsWsusHttpsState {
    param($Fqdn)
    $global:MemLabsWsusFixtureObserverCalls++
    [pscustomobject]@{ Passed = -not $global:MemLabsWsusFixtureObserverFails; Details = @("fixture TLS for $Fqdn") }
}
'@)
$global:MemLabsWsusFixtureObserverCalls = 0
$global:MemLabsWsusFixtureObserverFails = $false
function Get-Module { param($Name, [switch]$ListAvailable) [pscustomobject]@{ Version = [version]'1.0'; ModuleBase = $observerDir } }
function Get-Service { param($Name) [pscustomobject]@{ Status = 'Running' } }
function Get-WebAppPoolState { param($Name) [pscustomobject]@{ Value = 'Started' } }
function Get-NetTCPConnection { param($State, $LocalPort) foreach ($port in $LocalPort) { [pscustomobject]@{ LocalPort = $port } } }
$script:ObservedArguments = @(); $script:ObservedDetails = @()
function Invoke-VmCommand {
    param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds)
    $script:ObservedArguments = $ArgumentList
    [pscustomobject]@{ ScriptBlockOutput = (& $ScriptBlock @ArgumentList) }
}
function Format-TestResult {
    param($VMName, $RoleLabel, $Result)
    $script:ObservedDetails = $Result.ScriptBlockOutput.Details
    return $Result.ScriptBlockOutput.Passed
}
try {
    $beforeFlags = $script:Flags | ConvertTo-Json -Compress
    foreach ($fails in @($false, $true)) {
        $global:MemLabsWsusFixtureObserverFails = $fails
        $result = Test-WSUSFunctionality -VMName WSUS1 -Domain lab.test -UseHTTPS
        Assert-True ($result -eq (-not $fails)) 'Phase 11 lost the TLS observation result.'
        Assert-True ($script:ObservedArguments[0] -is [bool] -and $script:ObservedArguments[0] -and $script:ObservedArguments[1] -eq 'WSUS1.lab.test') 'Phase 11 changed the typed HTTPS flag or FQDN.'
        Assert-True (($script:ObservedDetails -join ' ') -match 'Intended-client.*not tested') 'Server-only validation claimed client coverage.'
    }
    Assert-True (($script:Flags | ConvertTo-Json -Compress) -ceq $beforeFlags) 'Phase 11 mutated TLS settings.'
    Assert-True ($global:MemLabsWsusFixtureObserverCalls -eq 2) 'Phase 11 skipped or duplicated TLS observations.'
}
finally {
    [IO.File]::Delete($observerPath)
    [IO.Directory]::Delete($observerDir)
}
Write-Host "PASS -- standalone WSUS HTTPS ($script:Assertions assertions); no VM, certificate-store, IIS, AD, or ConfigMgr mutations."
