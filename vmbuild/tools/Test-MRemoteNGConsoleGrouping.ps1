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

function Get-List {
    param([string] $Type)

    if ($Type -ne 'VM') { throw "Unexpected list type '$Type'." }
    return @(
        [pscustomobject]@{ vmName = 'PS1-W11OOBE01' }
        [pscustomobject]@{ vmName = 'PS1-DC1' }
    )
}

function Write-Log {
    param($Message, [switch] $LogOnly, [switch] $Verbose)
}

$sourcePath = Join-Path $RootPath 'vmbuild\common\Common.mRemoteNG.ps1'
. (Import-TestFunction -Path $sourcePath -Name 'Remove-MissingConnectionsFromMRemoteNG')

[xml] $document = @'
<Connections>
  <Node Name="contoso.com" Type="Container">
    <Node Name="All VMs" Type="Container">
      <Node Name="[console] PS1-W11OOBE01 [AAD]" Type="Connection" Hostname="LABHOST" VmId="11111111-1111-1111-1111-111111111111" UseVmId="true" />
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
Assert-Equal 1 @($allVms.SelectNodes('Node[@Name="[console] PS1-W11OOBE01 [AAD]"]')).Count 'valid console-only VM remains discoverable in All VMs'
Assert-Equal 'true' $allVms.SelectSingleNode('Node[@Name="[console] PS1-W11OOBE01 [AAD]"]').GetAttribute('UseVmId') 'surviving entry retains Hyper-V console binding'
Assert-Equal 1 @($allVms.SelectNodes('Node[@Name="PS1-DC1 [DC]"]')).Count 'ordinary RDP VM remains in All VMs'
Assert-Equal 0 @($allVms.SelectNodes('Node[@Name="REMOVED [Server]"]')).Count 'stale ordinary entry is removed'
Assert-Equal 0 @($allVms.SelectNodes('Node[@Name="[console] PS1-MISSING01 [AAD]"]')).Count 'stale console entry is removed'

if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { [Console]::WriteLine("    $_") }
    [Console]::WriteLine("$($script:Failures.Count) of $script:AssertionCount check(s) failed.")
    exit 1
}

[Console]::WriteLine("All $script:AssertionCount mRemoteNG console grouping checks passed.")