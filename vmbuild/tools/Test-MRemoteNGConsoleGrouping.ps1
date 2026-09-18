<#
.SYNOPSIS
    Verifies console-only VMs survive mRemoteNG additive-group pruning.
#>
#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) {
    $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$script:Failures = [Collections.Generic.List[string]]::new()
$script:AssertionCount = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)

    $script:AssertionCount++
    if ("$Expected" -ne "$Actual") {
        $script:Failures.Add("$Name -- expected '$Expected', got '$Actual'")
        [Console]::WriteLine("  FAIL: $Name")
    }
    else {
        [Console]::WriteLine("  PASS: $Name")
    }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $functionAst = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Function '$Name' not found in $Path" }
    return [scriptblock]::Create($functionAst.Extent.Text)
}

$script:TestVmList = @(
    [pscustomobject]@{
        vmName = 'PS1-W11OOBE01'; Role = 'AADClient'; Domain = 'contoso.com'
        vmId = '11111111-1111-1111-1111-111111111111'; LastKnownIP = '10.0.0.50'
    }
    [pscustomobject]@{
        vmName = 'PS1-DC1'; Role = 'DC'; Domain = 'contoso.com'
        vmId = '22222222-2222-2222-2222-222222222222'; AdminName = 'labadmin'
    }
    [pscustomobject]@{
        vmName = 'PS1-LINUX1'; Role = 'LinuxClient'; Domain = 'contoso.com'
        vmId = '33333333-3333-3333-3333-333333333333'; LastKnownIP = '10.0.0.60'
        enableRDP = $true; joinDomain = $false
    }
)

function Get-List {
    param([string] $Type, [string] $Domain, [switch] $SmartUpdate)

    if ($Type -eq 'UniqueDomain') { return @('contoso.com') }
    if ($Type -ne 'VM') { throw "Unexpected list type '$Type'." }
    if ($Domain) { return @($script:TestVmList | Where-Object { $_.Domain -eq $Domain }) }
    return @($script:TestVmList)
}

function Write-Log {
    param(
        $Message,
        [switch] $Activity,
        [switch] $LogOnly,
        [switch] $Success,
        [switch] $Verbose,
        [switch] $Warning
    )
}

function Write-MRNGDiag { param($Message) }
function Write-RedX { param($Message) }
function Write-GreenCheck { param($Message, $ForegroundColor) }
function Restore-TerminalFocus {}
function Invoke-VMNetworkBulkWarmup {}
function Install-MRemoteNG {}
function Set-MRemoteNGExternalApps {}
function Get-MRemoteNGPassword { return '' }
function Get-MRNGFileFingerprint { param($Path); return $null }
function Format-MRNGFingerprint { param($Fingerprint); return '' }
function Repair-MRemoteNGPasswords { param($Doc, [Alias('FreshEncryptedPassword')] $EncryptedValue); return $false }

function Get-Process {
    [CmdletBinding()]
    param([string] $Name)
    return $null
}

function Remove-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $Path,
        [string] $LiteralPath,
        [switch] $Force
    )
}

function Start-Sleep {
    [CmdletBinding()]
    param([int] $Seconds, [int] $Milliseconds)
}

function Get-RDCSettings {
    return [pscustomobject]@{
        DefaultGrouping = $true
        AllVMsGroup = $true
        RoleGroups = $false
        OSGroups = $false
        SubnetGroups = $false
        SiteCodeGroups = $false
        ShowUser = $false
    }
}

function Get-RDCGroupingFolders {
    param($vm, $settings, $vmListFull, $siteHierarchy, $clientPushSiteMap)

    $folders = @()
    if ($settings.AllVMsGroup) { $folders += , @('All VMs') }
    return , $folders
}

function Test-VmIsLinux { param($Vm); return $Vm.Role -eq 'LinuxClient' }
function Get-RDCManCmVersionForVM { param($VM, $Config, $DomainDefaults); return $null }
function Format-MRemoteNGTooltip { param($Vm, $CmVersion, $VmListFull, $ResolvedIp); return '' }

function Get-RDCManDisplayName {
    param($vm, $settings, $cmVersion, $siteHierarchy, $clientPushSiteMap)

    switch ($vm.Role) {
        'AADClient' { return "$($vm.vmName) [AAD]" }
        'DC' { return "$($vm.vmName) [DC]" }
        default { return $vm.vmName }
    }
}

function Get-VMNetworkAdapter {
    [CmdletBinding()]
    param([string] $VMName)

    return [pscustomobject]@{ IPAddresses = @('10.0.0.60') }
}

$sourcePath = Join-Path $RootPath 'vmbuild\common\Common.mRemoteNG.ps1'
$productionFunctions = @(
    'Get-MRemoteNGDeterministicGuid'
    'New-MRemoteNGXmlDocument'
    'Get-MRemoteNGGroupForVM'
    'New-MRemoteNGContainerNode'
    'New-MRemoteNGConnectionNode'
    'Get-MRemoteNGContainerForDomain'
    'Get-MRemoteNGNestedContainer'
    'Add-MRemoteNGConnectionToContainer'
    'Set-MRemoteNGNodeOrder'
    'Remove-MissingConnectionsFromMRemoteNG'
    'Remove-MissingDomainsFromMRemoteNG'
    'New-MRemoteNGFileFromHyperV'
)
foreach ($functionName in $productionFunctions) {
    . (Import-TestFunction -Path $sourcePath -Name $functionName)
}

[xml] $document = @'
<Connections>
  <Node Name="contoso.com" Type="Container">
    <Node Name="All VMs" Type="Container">
            <Node Name="PS1-W11OOBE01 [AAD] [Console]" Type="Connection" Hostname="LABHOST" Protocol="RDP" Port="2179" VmId="11111111-1111-1111-1111-111111111111" UseVmId="true" UseEnhancedMode="false" />
      <Node Name="PS1-DC1 [DC]" Type="Connection" Hostname="PS1-DC1" />
      <Node Name="REMOVED [Server]" Type="Connection" Hostname="REMOVED" />
      <Node Name="[console] PS1-MISSING01 [AAD]" Type="Connection" Hostname="LABHOST" VmId="22222222-2222-2222-2222-222222222222" UseVmId="true" />
    </Node>
  </Node>
</Connections>
'@

$domainContainer = $document.SelectSingleNode('/Connections/Node[@Name="contoso.com"]')
$changed = Remove-MissingConnectionsFromMRemoteNG -Container $domainContainer
$allVms = $domainContainer.SelectSingleNode('Node[@Name="All VMs"]')

Assert-Equal $true $changed 'prune reports removal of stale connections'
Assert-Equal 1 @($domainContainer.SelectNodes('Node[@Name="All VMs"]')).Count 'nonempty All VMs container survives recursive pruning'
$consoleNode = $allVms.SelectSingleNode('Node[@Name="PS1-W11OOBE01 [AAD] [Console]"]')
Assert-Equal 1 @($consoleNode).Count 'valid console-only VM remains discoverable with a sortable suffix'
Assert-Equal 'true' $consoleNode.GetAttribute('UseVmId') 'surviving entry retains Hyper-V console binding'
Assert-Equal '2179' $consoleNode.GetAttribute('Port') 'console-only entry targets the VMMS RDP endpoint'
Assert-Equal 'false' $consoleNode.GetAttribute('UseEnhancedMode') 'console-only entry uses guest-independent standard mode'
Assert-Equal 1 @($allVms.SelectNodes('Node[@Name="PS1-DC1 [DC]"]')).Count 'ordinary RDP VM remains in All VMs'
Assert-Equal 0 @($allVms.SelectNodes('Node[@Name="REMOVED [Server]"]')).Count 'stale ordinary entry is removed'
Assert-Equal 0 @($allVms.SelectNodes('Node[@Name="[console] PS1-MISSING01 [AAD]"]')).Count 'stale console entry is removed'

$generatedPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-mrng-console-$PID-$([guid]::NewGuid()).xml"
try {
    New-MRemoteNGFileFromHyperV -MRemoteNGFile $generatedPath -NoActivity
    [xml] $generated = Get-Content -LiteralPath $generatedPath -Raw

    $generatedDomain = $generated.SelectSingleNode('/Connections/Node[@Name="contoso.com"]')
    $generatedAllVms = $generatedDomain.SelectSingleNode('Node[@Name="All VMs"]')
    $generatedConsole = $generatedAllVms.SelectSingleNode('Node[@Name="PS1-W11OOBE01 [AAD] [Console]"]')
    Assert-Equal 1 @($generatedConsole).Count 'generator appends Console after sortable VM metadata in All VMs'
    Assert-Equal '2179' $generatedConsole.GetAttribute('Port') 'generated All VMs console targets the VMMS RDP endpoint'
    Assert-Equal 'false' $generatedConsole.GetAttribute('UseEnhancedMode') 'generated All VMs console uses standard mode'

    $vmIdNodes = @($generated.SelectNodes('//Node[@Type="Connection" and @UseVmId="true"]'))
    $standardVmIdNodes = @($generated.SelectNodes('//Node[@Type="Connection" and @UseVmId="true" and @Port="2179" and @UseEnhancedMode="false"]'))
    Assert-Equal 5 $vmIdNodes.Count 'generator emits every expected default, additive, and dedicated VM-ID connection'
    Assert-Equal $vmIdNodes.Count $standardVmIdNodes.Count 'every generated VM-ID connection uses VMMS port 2179 in standard mode'

    $defaultConsole = $generatedDomain.SelectSingleNode('Node[@Name="Clients"]/Node[@Name="PS1-W11OOBE01 [AAD] [Console]"]')
    Assert-Equal '2179' $defaultConsole.GetAttribute('Port') 'default console copy also targets VMMS port 2179'
    Assert-Equal 'false' $defaultConsole.GetAttribute('UseEnhancedMode') 'default console copy also uses standard mode'

    $hyperVContainer = $generatedDomain.SelectSingleNode('Node[@Name="Hyper-V Console"]')
    Assert-Equal 3 @($hyperVContainer.SelectNodes('Node[@UseVmId="true" and @Port="2179" and @UseEnhancedMode="false"]')).Count 'dedicated Hyper-V folder emits a standard console for every VM'

    $ordinaryRdp = $generatedDomain.SelectSingleNode('Node[@Name="DomainServers"]/Node[@Name="PS1-DC1 [DC]"]')
    Assert-Equal '3389' $ordinaryRdp.GetAttribute('Port') 'ordinary Windows RDP remains on port 3389'
    Assert-Equal '' $ordinaryRdp.GetAttribute('UseVmId') 'ordinary Windows RDP does not acquire a VM-ID binding'

    $linuxSsh = $generatedDomain.SelectSingleNode('Node[@Name="Linux"]/Node[@Name="SSH"]/Node[@Name="PS1-LINUX1 [Linux SSH]"]')
    Assert-Equal 'SSH2' $linuxSsh.GetAttribute('Protocol') 'ordinary Linux SSH remains SSH2'
    Assert-Equal '22' $linuxSsh.GetAttribute('Port') 'ordinary Linux SSH remains on port 22'

    $linuxRdp = $generatedDomain.SelectSingleNode('Node[@Name="Linux"]/Node[@Name="PS1-LINUX1 [Linux RDP]"]')
    Assert-Equal '3389' $linuxRdp.GetAttribute('Port') 'ordinary Linux RDP remains on port 3389'
    Assert-Equal '' $linuxRdp.GetAttribute('UseVmId') 'ordinary Linux RDP does not acquire a VM-ID binding'
}
finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $generatedPath -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { [Console]::WriteLine("    $_") }
    [Console]::WriteLine("$($script:Failures.Count) of $script:AssertionCount check(s) failed.")
    exit 1
}

[Console]::WriteLine("All $script:AssertionCount mRemoteNG console grouping checks passed.")