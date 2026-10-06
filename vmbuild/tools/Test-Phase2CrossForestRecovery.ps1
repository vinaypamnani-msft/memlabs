<#
.SYNOPSIS
    Verifies the Phase 2 cross-forest recovery paths found by CSTest8B.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$otherDcPath = Join-Path $root 'DSC\phases\Phase2OtherDC.ps1'
$dcPath = Join-Path $root 'DSC\phases\Phase2DC.ps1'
$modulePath = Join-Path $root 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$scriptBlocksPath = Join-Path $root 'common\Common.ScriptBlocks.ps1'

$otherDc = Get-Content -LiteralPath $otherDcPath -Raw
$dc = Get-Content -LiteralPath $dcPath -Raw
$module = Get-Content -LiteralPath $modulePath -Raw
$scriptBlocks = Get-Content -LiteralPath $scriptBlocksPath -Raw

$forwarderStart = $otherDc.IndexOf("DnsServerConditionalForwarder 'Forwarder1' {", [StringComparison]::Ordinal)
$forwarderEnd = $otherDc.IndexOf('$nextDepend = "[DnsServerConditionalForwarder]Forwarder1"', $forwarderStart, [StringComparison]::Ordinal)
if ($forwarderStart -lt 0 -or $forwarderEnd -le $forwarderStart) {
    throw 'Could not isolate the OtherDC conditional-forwarder resource.'
}
$forwarder = $otherDc.Substring($forwarderStart, $forwarderEnd - $forwarderStart)
if ($forwarder -match 'PsDscRunAsCredential') {
    throw 'OtherDC conditional-forwarder setup still runs under the new forest credential instead of LocalSystem.'
}

$delegateStart = $module.IndexOf('class DelegateControl {', [StringComparison]::Ordinal)
$delegateEnd = $module.IndexOf('[DscResource()]' + [Environment]::NewLine + 'class AddNtfsPermissions', $delegateStart, [StringComparison]::Ordinal)
if ($delegateStart -lt 0 -or $delegateEnd -le $delegateStart) {
    throw 'Could not isolate the DelegateControl DSC resource.'
}
$delegate = $module.Substring($delegateStart, $delegateEnd - $delegateStart)
foreach ($required in @(
        '[System.Management.Automation.PSCredential] $RemoteCreds',
        '[string] $RemoteServer',
        'ResolveIdentitySid',
        'DirectorySearcher',
        'GrantSidOnSystemManagement',
        'HasSidPermission',
        'SidCachePath',
        'ReadSidCache',
        'SaveSidCache',
        'Granted and verified FULL CONTROL')) {
    if (-not $delegate.Contains($required)) {
        throw "DelegateControl is missing cross-forest SID behavior: $required"
    }
}
$delegateSetStart = $delegate.IndexOf('[void] Set()', [StringComparison]::Ordinal)
$delegateSetEnd = $delegate.IndexOf('[bool] Test()', $delegateSetStart, [StringComparison]::Ordinal)
if ($delegateSetStart -lt 0 -or $delegateSetEnd -le $delegateSetStart) {
    throw 'Could not isolate DelegateControl.Set().'
}
$delegateSet = $delegate.Substring($delegateSetStart, $delegateSetEnd - $delegateSetStart)
$sidCall = '$sidGrantError = $this.GrantSidOnSystemManagement($arg1, $sidText)'
if ($delegateSet.IndexOf($sidCall, [StringComparison]::Ordinal) -lt 0 -or
    $delegateSet.IndexOf($sidCall, [StringComparison]::Ordinal) -gt
    $delegateSet.IndexOf('$cmd = "dsacls.exe"', [StringComparison]::Ordinal)) {
    throw 'DelegateControl does not attempt the SID grant before dsacls name resolution.'
}
if ($delegateSet.IndexOf('$sidText = $this.ResolveIdentitySid($identity)', [StringComparison]::Ordinal) -gt
    $delegateSet.IndexOf('$sidText = $this.ReadSidCache()', [StringComparison]::Ordinal)) {
    throw 'DelegateControl.Set() trusts the cached SID before an authoritative live lookup.'
}
$delegateTest = $delegate.Substring($delegateSetEnd)
if ($delegateTest.IndexOf('$sidText = $this.ResolveIdentitySid(', [StringComparison]::Ordinal) -lt 0 -or
    $delegateTest.IndexOf('$sidText = $this.ResolveIdentitySid(', [StringComparison]::Ordinal) -gt
    $delegateTest.IndexOf('$sidText = $this.ReadSidCache()', [StringComparison]::Ordinal)) {
    throw 'DelegateControl.Test() trusts the cached SID before an authoritative live lookup.'
}
if ($delegate -notmatch '\$searcher\.Filter = "\(&\(objectClass=group\)\(sAMAccountName=\$escapedLeaf\)\)"') {
    throw 'Foreign SID lookup is not restricted to an exact group sAMAccountName.'
}
if ($dc -notmatch 'DelegateControl "AddremoteIISGroup"[\s\S]{0,350}RemoteCreds\s*=\s*\$groupCreds') {
    throw 'Phase2DC does not pass explicit remote credentials to foreign-group delegation.'
}
if ($dc -notmatch 'DelegateControl "AddremoteIISGroup"[\s\S]{0,450}RemoteServer\s*=\s*\$ThisVM\.ThisParams\.RootCADC') {
    throw 'Phase2DC does not pin foreign-group LDAP lookup to the remote forest DC.'
}

$rootCertStart = $module.IndexOf('class InstallRootCertificate {', [StringComparison]::Ordinal)
$rootCertEnd = $module.IndexOf('[DscResource()]' + [Environment]::NewLine + 'class AddCertificateTemplate', $rootCertStart, [StringComparison]::Ordinal)
if ($rootCertStart -lt 0 -or $rootCertEnd -le $rootCertStart) {
    throw 'Could not isolate the InstallRootCertificate DSC resource.'
}
$rootCert = $module.Substring($rootCertStart, $rootCertEnd - $rootCertStart)
foreach ($required in @(
        '[System.Management.Automation.PSCredential]$RemoteCreds',
        'OpenRemoteEntry',
        'retrying the credentialed AD read',
        'no cached certificate was available after credentialed AD retries')) {
    if (-not $rootCert.Contains($required)) {
        throw "InstallRootCertificate is missing credentialed AD recovery behavior: $required"
    }
}
if ($rootCert -match 'certutil\.exe\s+-config\s+\$caConfig\s+-ca\.cert') {
    throw 'InstallRootCertificate still invokes the known-broken Server 2022 certutil -ca.cert fallback.'
}
if ($dc -notmatch 'InstallRootCertificate InstallRootCertificate[\s\S]{0,350}RemoteCreds\s*=\s*\$groupCreds') {
    throw 'Phase2DC does not pass explicit remote credentials to root-certificate retrieval.'
}
if ($otherDc -notmatch '(?s)RunPkiSync FinalizeCrossForestPki\s*\{.+?SourceForest\s*=\s*\$ThisVM\.Domain.+?TargetForest\s*=\s*\$DomainName.+?DependsOn\s*=\s*\$waitOnDependency') {
    throw 'Phase2OtherDC does not re-publish finalized certificate-template ACLs after the foreign grants converge.'
}
if ($otherDc.IndexOf('RunPkiSync FinalizeCrossForestPki', [StringComparison]::Ordinal) -lt
    $otherDc.IndexOf('AddCertificateTemplate ConfigMgrClientCertificate', [StringComparison]::Ordinal)) {
    throw 'Final cross-forest PKI sync runs before the client-template ACL grant.'
}

$phaseStartStop = [regex]::Match(
    $scriptBlocks,
    '(?m)^\s*\$result = Invoke-VmCommand .*ArgumentList @\(\$hostRunStartUtc\).*DisplayName "Stop Any Running DSC''s".*$')
if (-not $phaseStartStop.Success -or $phaseStartStop.Value -notmatch '-SuppressLog') {
    throw 'The handled phase-start DSC stop probe can still emit a structured low-level ERROR before recovery.'
}

# Run DSC semantic parsing/resource-property binding against an isolated module
# path containing the workspace TemplateHelpDSC, not the globally installed copy.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-phase2-compile-$([guid]::NewGuid().ToString('N'))"
try {
    $moduleRoot = Join-Path $tempRoot 'Modules'
    $null = New-Item -ItemType Directory -Path $moduleRoot -Force
    $moduleTargets = @{ TemplateHelpDSC = (Join-Path $root 'DSC\TemplateHelpDSC') }
    foreach ($moduleName in @('NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc', 'GroupPolicyDsc')) {
        $module = Get-Module -ListAvailable $moduleName | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { throw "Required DSC module '$moduleName' is not installed." }
        $moduleTargets[$moduleName] = $module.ModuleBase
    }
    foreach ($entry in $moduleTargets.GetEnumerator()) {
        $null = New-Item -ItemType Junction -Path (Join-Path $moduleRoot $entry.Key) -Target $entry.Value
    }

    $isolatedModulePath = "$moduleRoot;C:\Windows\System32\WindowsPowerShell\v1.0\Modules"
    foreach ($configPath in @($dcPath, $otherDcPath)) {
        $escapedModulePath = $isolatedModulePath.Replace("'", "''")
        $escapedConfigPath = $configPath.Replace("'", "''")
        $compileOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -Command @"
`$env:PSModulePath = '$escapedModulePath'
`$tokens = `$null
`$errors = `$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$escapedConfigPath', [ref]`$tokens, [ref]`$errors)
`$errors | ForEach-Object { Write-Output `$_ }
if (`$errors.Count) { exit 1 }
"@ 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "$(Split-Path $configPath -Leaf) failed isolated DSC compilation: $($compileOutput -join ' | ')"
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- cross-forest Phase 2 uses local DNS context, SID delegation, credentialed CA reads, and classified DSC-stop recovery.'
