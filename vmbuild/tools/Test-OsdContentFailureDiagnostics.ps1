<#
.SYNOPSIS
    Exercises automatic OSD failure capture, rolled logs and PXE evidence offline.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production functions and conditions read fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestDefinition {
    param([string]$Name, [switch]$Collector)
    if ($Collector) {
        $definitions = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq "`$$Name"
                }, $true))
        Assert-True ($definitions.Count -eq 1) "Expected one $Name collector."
        return & ([scriptblock]::Create("$($definitions[0].Extent.Text)`n`$$Name"))
    }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($definitions.Count -eq 1) "Expected one $Name function."
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Get-TestDefinition 'Invoke-Phase11LocalSystemProbe')
. (Get-TestDefinition 'Save-Phase11OsdContentFailureLogs')
& {
    $Phase11SmsSiteLogCollector = { 'site' }
    $Phase11DpContentLogCollector = { 'dp' }
    $state = [pscustomobject]@{
        Calls = [System.Collections.Generic.List[object]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        Existing = @(); DiscoveryFails = $false
    }
    function Save-Phase11GuestLogs {
        param($VMName, $DomainName, $RoleLabel, $Collector, $TimeoutSeconds)
        $kind = $Collector.ToString().Trim()
        if ($RoleLabel -eq 'OSD-DP') {
            Assert-True ($kind.Contains('Invoke-Phase11LocalSystemProbe -ScriptBlock')) 'Protected DP failure evidence is not collected as SYSTEM.'
            $kind = "'dp'"
        }
        $state.Calls.Add([pscustomobject]@{ VM = $VMName; Kind = $kind; Domain = $DomainName })
    }
    function Add-Phase11Output { param($Message) }
    function Write-Log {
        param($Message, [switch]$Warning, [switch]$LogOnly)
        if ($Warning) { $state.Warnings.Add($Message) }
    }
    function Get-List {
        param($Type, $DomainName)
        if ($state.DiscoveryFails) { throw 'synthetic discovery failure' }
        return $state.Existing
    }
    $primary = [pscustomobject]@{ vmName = 'PRIMARY1'; role = 'Primary'; siteCode = 'PRI'; parentSiteCode = 'HUB' }
    $cas = [pscustomobject]@{ vmName = 'CAS1'; role = 'CAS'; siteCode = 'HUB' }
    $dp = [pscustomobject]@{ vmName = 'NEWDP'; role = 'SiteSystem'; siteCode = 'PRI' }
    $foreign = [pscustomobject]@{ vmName = 'FOREIGN'; role = 'Primary'; siteCode = 'PRI'; domain = 'other.test' }
    $config = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'memlabs.test' }
        virtualMachines = @($primary, $cas, $dp, $foreign)
    }
    Save-Phase11OsdContentFailureLogs -VMName NEWDP -CurrentItem $dp -DeployConfig $config `
        -DistributionPointNames @('NEWDP.memlabs.test', 'newdp')
    $sites = @($state.Calls | Where-Object { $_.Kind -eq "'site'" } | Sort-Object VM)
    $dps = @($state.Calls | Where-Object { $_.Kind -eq "'dp'" })
    Assert-True (($sites.VM -join ',') -eq 'CAS1,PRIMARY1') 'A DP failure did not collect both its feeding site and parent content source.'
    Assert-True ($dps.Count -eq 1 -and $dps[0].VM -ieq 'NEWDP') 'FQDN/short-name aliases were not deduplicated.'
    Assert-True (@($state.Calls | Where-Object { $_.VM -eq 'FOREIGN' }).Count -eq 0) 'Diagnostic discovery crossed a domain boundary.'
    $state.Calls.Clear()
    $source = [pscustomobject]@{ vmName = 'SOURCE1'; role = 'Primary'; siteCode = 'SRC'; parentSiteCode = 'HUB' }
    $foreignSource = [pscustomobject]@{ vmName = 'FOREIGNSOURCE'; role = 'Primary'; siteCode = 'SRC'; parentSiteCode = 'BAD'; domain = 'other.test' }
    $unrelatedCas = [pscustomobject]@{ vmName = 'UNRELATEDCAS'; role = 'CAS'; siteCode = 'BAD' }
    $state.Existing = @($source, $foreignSource, $unrelatedCas)
    Save-Phase11OsdContentFailureLogs -VMName NEWDP -CurrentItem $dp -DeployConfig $config `
        -DistributionPointNames @('NEWDP') -SourceSiteCodes @('SRC', 'src', 'PRI', 'bad-source')
    Assert-True (@($state.Calls | Where-Object { $_.Kind -eq "'site'" }).Count -eq 3 -and
        @($state.Calls | Where-Object { $_.VM -eq 'SOURCE1' }).Count -eq 1) 'The actual content source Primary was not captured from inventory.'
    Assert-True (@($state.Calls | Where-Object { $_.VM -in 'FOREIGNSOURCE', 'UNRELATEDCAS' }).Count -eq 0 -and
        ($state.Warnings -join ' ') -match 'invalid content source site') 'Source discovery crossed a domain boundary or hid invalid source metadata.'
    $state.Calls.Clear()
    $config.virtualMachines = @($dp)
    $state.Existing = @($primary, $cas)
    Save-Phase11OsdContentFailureLogs -VMName NEWDP -CurrentItem $dp -DeployConfig $config -DistributionPointNames @('NEWDP')
    Assert-True (@($state.Calls | Where-Object { $_.Kind -eq "'site'" }).Count -eq 2) 'A partial expansion config lost existing site-server evidence.'
    $state.Calls.Clear()
    $state.DiscoveryFails = $true
    Save-Phase11OsdContentFailureLogs -VMName NEWDP -CurrentItem $dp -DeployConfig $config -DistributionPointNames @('NEWDP')
    Assert-True (($state.Warnings -join ' ') -match 'synthetic discovery failure' -and
        @($state.Calls | Where-Object { $_.Kind -eq "'dp'" }).Count -eq 1) 'A failed site lookup hid its error or prevented DP evidence.'
}

$calls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Save-Phase11OsdContentFailureLogs'
        }, $true))
Assert-True ($calls.Count -eq 2) 'Both DP-local and site-wide OSD failure paths must capture distribution evidence.'
$callOwners = @(
    foreach ($call in $calls) {
        for ($parent = $call.Parent; $parent; $parent = $parent.Parent) {
            if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) {
                $parent.Name
                break
            }
        }
    }
)
Assert-True ('Test-SiteSystemFunctionality' -in $callOwners -and
    'Test-CMSiteWideFunctionality' -in $callOwners) 'OSD failure capture is wired to the wrong validation functions.'
Assert-True ($ast.Extent.Text.Contains('-SourceSiteCodes $osdSourceSiteCodes') -and
    $ast.Extent.Text.Contains('$result.ScriptBlockOutput.OsdContentSourceSiteCodes')) 'Measured content source sites are not passed from the validator to failure capture.'
$guards = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$osdFailureLines.Count')
        }, $true))
Assert-True ($guards.Count -eq 1) 'Expected one site-wide OSD capture decision.'
$captureCondition = [scriptblock]::Create($guards[0].Clauses[0].Item1.Extent.Text)
& {
    $prePopulate = $true
    $hasOsdClient = $true
    $result = @{ ScriptBlockFailed = $false }
    $osdFailureLines = @('FAIL: Boot image PRI00008 is still pending after 300s')
    Assert-True ([bool](& $captureCondition)) 'InstallRetrying boot-image failures do not trigger capture.'
    $osdFailureLines = @()
    Assert-True (-not (& $captureCondition)) 'Healthy OSD validation triggers unnecessary capture.'
    $result = $null
    Assert-True ([bool](& $captureCondition)) 'An unreachable site-wide validation job lost its OSD evidence.'
    $prePopulate = $false
    Assert-True (-not (& $captureCondition)) 'Non-prepopulated sites trigger OSD capture.'
}

$siteCollector = Get-TestDefinition 'Phase11SmsSiteLogCollector' -Collector
& {
    $state = [pscustomobject]@{
        ProviderFails = $false; ManyRows = $false; InventoryFails = ''; ManyImages = $false
    }
    $contents = @{
        'C:\Site\Logs\distmgr.log' = 'current distribution retry'
        'C:\Site\Logs\distmgr.lo_' = 'original distribution failure'
        'C:\Site\Logs\PkgXferMgr.log' = 'current transfer failure'
        'C:\Site\Logs\PkgXferMgr.lo_' = 'original transfer failure'
        'C:\Site\Logs\SMSProv.log' = 'provider rebuild evidence'
        'C:\staging\DSC\InstallCMLog.log' = 'Phase 8 publication and coverage evidence'
        'C:\staging\DSC\DSC_Log.log' = 'DSC evidence'
        'C:\staging\DSC\DSC_Status.txt' = 'DSC status'
    }
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        if ($Name -eq 'Site Code') { return [pscustomobject]@{ 'Site Code' = 'PRI' } }
        return [pscustomobject]@{ 'Installation Directory' = 'C:\Site' }
    }
    function Test-Path { param($Path) return $Path -eq 'C:\Site' }
    function Get-Item {
        param($LiteralPath, $ErrorAction)
        if (-not $contents.ContainsKey($LiteralPath)) { throw "missing fixture $LiteralPath" }
        [pscustomobject]@{ Length = 123; LastWriteTimeUtc = [datetime]'2026-10-30T12:05:00Z' }
    }
    function Get-Content {
        param($LiteralPath, $Tail, $ErrorAction)
        Assert-True ($Tail -eq 4000) 'A diagnostic log read lost its 4000-line bound.'
        return $contents[$LiteralPath]
    }
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        if ($ClassName -eq 'Win32_Service') { return }
        Assert-True ($OperationTimeoutSec -eq 10) 'A provider diagnostic query has no bounded operation timeout.'
        if ($ClassName -eq $state.InventoryFails) { throw 'fixture package inventory failed' }
        if ($ClassName -eq 'SMS_BootImagePackage') {
            return [pscustomobject]@{ PackageID = 'PRI00008'; SourceSite = 'PRI'; SourceVersion = 4; StoredPkgVersion = 4; PkgFlags = 1024 }
        }
        if ($ClassName -eq 'SMS_ImagePackage') {
            if ($state.ManyImages) {
                1..21 | ForEach-Object {
                    [pscustomobject]@{ PackageID = ('SRC{0:X5}' -f $_); SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = 1 }
                }
                return
            }
            return [pscustomobject]@{ PackageID = 'SRC00007'; SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = 1 }
        }
        if ($ClassName -eq 'SMS_OperatingSystemInstallPackage') {
            return [pscustomobject]@{ PackageID = 'SRC00004'; SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = 0 }
        }
        Assert-True ($Filter -match "PackageID='SRC00004'") 'A provider diagnostic query omitted measured OS upgrade content.'
        if (-not $state.ManyImages -and $state.InventoryFails -ne 'SMS_ImagePackage') {
            Assert-True ($Filter -match "PackageID='SRC00007'") 'A provider diagnostic query omitted measured OS image content.'
        }
        if ($state.ProviderFails -and $ClassName -eq 'SMS_DistributionDPStatus') { throw 'synthetic provider failure' }
        if ($state.ManyRows) {
            1..251 | ForEach-Object { [pscustomobject]@{ State = 2; SourceVersion = 4 } }
            return
        }
        foreach ($packageMatch in [regex]::Matches($Filter, "PackageID='([^']+)'")) {
            [pscustomobject]@{
                PackageID = $packageMatch.Groups[1].Value; State = 2; SourceVersion = 4
                ServerNALPath = '\\NEWDP.memlabs.test\'
            }
        }
    }
    function Get-WinEvent { param($FilterHashtable, $ErrorAction) }
    $out = & $siteCollector
    foreach ($name in @('distmgr.log', 'distmgr.lo_', 'PkgXferMgr.log', 'PkgXferMgr.lo_', 'SMSProv.log', 'InstallCMLog.log', 'DSC_Log.log', 'DSC_Status.txt')) {
        Assert-True ($out.ContainsKey($name)) "Site capture lost $name."
    }
    Assert-True ($out['_collector-diag.txt'] -match 'modifiedUtc=.*tailLines=4000' -and
        $out['_collector-diag.txt'] -match 'missing fixture') 'The log inventory lost freshness metadata or missing-file errors.'
    $snapshot = $out['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True ($snapshot.SiteCode -eq 'PRI' -and $snapshot.BootImages[0].SourceVersion -eq 4 -and
        $snapshot.Classes.SMS_PackageStatusDistPointsSummarizer[0].State -eq 2) 'The snapshot lost the package/DP version and retry state.'
    Assert-True ($snapshot.OSImages[0].PackageID -eq 'SRC00007' -and
        $snapshot.OSUpgradePackages[0].StoredPkgVersion -eq 0 -and
        $snapshot.SourceSiteCodes -contains 'SRC' -and
        $snapshot.Classes.SMS_PackageStatusDistPointsSummarizer.Count -eq 3) 'The snapshot lost OS content versions, their source Primary, or their per-DP status.'
    $state.ProviderFails = $true
    $out = & $siteCollector
    $snapshot = $out['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True (($snapshot.Errors -join ' ') -match 'synthetic provider failure' -and
        $out.ContainsKey('distmgr.lo_')) 'A failed provider probe hid its error or discarded already collected logs.'
    $state.ProviderFails = $false
    $state.InventoryFails = 'SMS_BootImagePackage'
    $snapshot = (& $siteCollector)['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True ($snapshot.BootImages.Count -eq 0 -and $snapshot.OSImages.Count -eq 1 -and
        $snapshot.OSUpgradePackages.Count -eq 1 -and
        ($snapshot.Errors -join ' ') -match 'fixture package inventory failed') 'A failed boot-image query discarded the independent OS inventories.'
    $state.InventoryFails = 'SMS_ImagePackage'
    $snapshot = (& $siteCollector)['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True ($snapshot.OSImages.Count -eq 0 -and $snapshot.BootImages.Count -eq 1 -and
        $snapshot.OSUpgradePackages.Count -eq 1) 'A failed OS image query discarded the remaining inventories.'
    $state.InventoryFails = ''
    $state.ManyImages = $true
    $snapshot = (& $siteCollector)['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True ($snapshot.OSImages.Count -eq 20 -and
        ($snapshot.Errors -join ' ') -match 'SMS_ImagePackage inventory truncated to 20') 'OS image inventory truncation is unbounded or silent.'
    $state.ManyImages = $false
    $state.ManyRows = $true
    $out = & $siteCollector
    $snapshot = $out['OsdDistributionState.json'] | ConvertFrom-Json
    Assert-True ($snapshot.Classes.SMS_DistributionPoint.Count -eq 250 -and
        ($snapshot.Errors -join ' ') -match 'truncated to 250') 'Provider snapshot truncation is unbounded or silent.'
}

$failureDiagnostic = Get-TestDefinition 'getOsdContentFailureDiagnostic' -Collector
& {
    $results = @{ OsdContentWaitTargets = @() }
    $ns = 'root\SMS\site_PRI'
    $dpNameOf = { param($Path) "$Path".Trim('\') }
    $getOsdContentTargetRows = { param($PackageId, $RequiredDp) @() }
    $logs = @{
        'C:\Site\Logs\PkgXferMgr.log' = 'Sending legacy content SRC00007.1 -- current transfer timestamp'
        'C:\Site\Logs\despool.lo_' = 'Stored Package SRC00007 -- original arrival timestamp'
        'E:\SMS_DP$\sms\logs\smsdpprov.log' = 'Unrelated old startup failed; 0x80070002'
    }
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        if ($Name -eq 'ContentLibraryPath') { return [pscustomobject]@{ ContentLibraryPath = 'E:\CLib' } }
        [pscustomobject]@{ 'Installation Directory' = 'C:\Site' }
    }
    function Test-Path {
        param($Path, $LiteralPath, $ErrorAction)
        $name = $LiteralPath
        if (-not $name) { $name = $Path }
        $logs.ContainsKey($name)
    }
    function Get-Content {
        param($LiteralPath, $Tail, $ErrorAction)
        Assert-True ($Tail -in 3000, 5000) 'A per-package failure diagnostic lost its log-read bound.'
        $logs[$LiteralPath]
    }
    function Get-WmiObject { param($Namespace, $Class, $Filter, $ErrorAction) @() }
    function New-PSSessionOption { param($OpenTimeout, $OperationTimeout) [pscustomobject]@{} }
    function Invoke-Command {
        param($ComputerName, $SessionOption, $ErrorAction, [object[]]$ArgumentList, $ScriptBlock)
        & $ScriptBlock @ArgumentList
    }
    $package = [pscustomobject]@{ PackageID = 'SRC00007'; SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = 1 }
    $detail = & $failureDiagnostic $package 'NEWDP.fixture.test' 'ContentValidating'
    Assert-True ($detail -match 'PkgXferMgr.log package tail:.*current transfer timestamp' -and
        $detail -match 'despool.lo_ package tail:.*original arrival timestamp') 'Failure diagnostics lost the active transfer or rolled arrival evidence.'
    Assert-True ($detail -notmatch 'Unrelated old startup failed' -and
        $detail -match 'unrelated startup errors are not evidence') 'Old uncorrelated DP startup errors masqueraded as this package''s failure.'
}

$dpCollector = Get-TestDefinition 'Phase11DpContentLogCollector' -Collector
& {
    $state = [pscustomobject]@{ ReadFails = $false }
    $contents = @{
        'C:\AlternateDP\sms\logs\smsdpprov.log' = 'current DP failure'
        'C:\AlternateDP\sms\logs\smsdpprov.lo_' = 'original DP failure'
        'C:\AlternateDP\sms\logs\SMSPXE.log' = 'current PXE evidence'
        'C:\SMS_DP$\sms\logs\smsdpprov.log' = 'stale October 28 DP log'
        'C:\CLib\DataLib\PRI00008.4\boot.PRI00008.wim.INI' = '[File] Hash=fixture'
    }
    $directories = @(
        'C:\AlternateDP\sms\logs', 'C:\SMS_DP$\sms\logs', 'C:\CLib', 'C:\CLib\PkgLib',
        'C:\AlternateDP\sms\bin', 'C:\AlternatePxe', 'C:\AlternatePxe\SMSBoot'
    )
    function Get-SmbShare {
        param($Name, $ErrorAction)
        if ($Name -eq 'SMS_DP$') { [pscustomobject]@{ Path = 'C:\AlternateDP' } }
    }
    function Get-SmbShareAccess {
        param($Name, $ErrorAction)
        [pscustomobject]@{ AccountName = 'BUILTIN\Administrators'; AccessControlType = 'Allow'; AccessRight = 'Full' }
    }
    function Get-LocalGroup {
        param($SID, $ErrorAction)
        [pscustomobject]@{ Name = 'Administrators' }
    }
    function Get-LocalGroupMember {
        param($Group, $ErrorAction)
        [pscustomobject]@{ Name = 'MEMLABS\SITESERVER$'; SID = 'S-1-5-21-10-20-30-1001' }
    }
    function Test-Path {
        param($LiteralPath, $ErrorAction)
        return $LiteralPath -in $directories
    }
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        if ($Name -eq 'RootFolder') { throw 'WDS not installed' }
        [pscustomobject]@{ ContentLibraryPath = 'C:\CLib'; SccmPXE = 1 }
    }
    function Get-Item {
        param($LiteralPath, [switch]$Force, $ErrorAction)
        if ($contents.ContainsKey($LiteralPath) -or $LiteralPath -in $directories) {
            return [pscustomobject]@{
                FullName = $LiteralPath; Length = 456
                LastWriteTimeUtc = [datetime]'2026-10-30T12:05:00Z'
                Attributes = 'Directory'; LinkType = ''; Target = ''
            }
        }
        throw "missing fixture $LiteralPath"
    }
    function Get-Content {
        param($LiteralPath, $Tail, $TotalCount, $ErrorAction)
        if ($LiteralPath -like '*.INI') { Assert-True ($TotalCount -eq 40) 'A DataLib metadata read is unbounded.' }
        else { Assert-True ($Tail -eq 4000) 'A DP log read is unbounded.' }
        if ($state.ReadFails -and $LiteralPath -eq 'C:\AlternateDP\sms\logs\smsdpprov.log') { throw 'synthetic DP log access denied' }
        return $contents[$LiteralPath]
    }
    function Get-ChildItem {
        param($LiteralPath, $Filter, [switch]$Directory, [switch]$Recurse, [switch]$File, [switch]$Force, $ErrorAction)
        switch ($LiteralPath) {
            'C:\CLib\PkgLib' { [pscustomobject]@{ BaseName = 'PRI00008' }; break }
            'C:\CLib\DataLib' {
                [pscustomobject]@{ Name = 'PRI00008.4'; FullName = 'C:\CLib\DataLib\PRI00008.4' }
                break
            }
            'C:\CLib\DataLib\PRI00008.4' {
                [pscustomobject]@{ Name = 'boot.PRI00008.wim.INI'; FullName = 'C:\CLib\DataLib\PRI00008.4\boot.PRI00008.wim.INI'; PSIsContainer = $false }
                break
            }
            'C:\AlternatePxe\SMSBoot' {
                [pscustomobject]@{ FullName = 'C:\AlternatePxe\SMSBoot\PRI00008\x64\wdsmgfw.efi'; Length = 1024; LastWriteTimeUtc = [datetime]'2026-10-30T12:05:00Z' }
                break
            }
            'C:\AlternateDP\sms\logs' { [pscustomobject]@{ LastWriteTime = [datetime]'2026-10-30T08:05:00' }; break }
            default { throw "unexpected fixture directory $LiteralPath" }
        }
    }
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        [pscustomobject]@{ Name = 'SccmPxe'; State = 'Running'; ProcessId = 123; PathName = '"C:\AlternatePxe\sccmpxe.exe" -service' }
    }
    function Get-Acl { param($LiteralPath, $ErrorAction) [pscustomobject]@{ Sddl = 'fixture-sddl' } }
    function Import-Module { param($Name, $ErrorAction) }
    function Get-Website { param($Name, $ErrorAction) [pscustomobject]@{ State = 'Started' } }
    $out = & $dpCollector
    Assert-True ($out['smsdpprov.log'] -eq 'current DP failure' -and
        $out['smsdpprov.lo_'] -eq 'original DP failure' -and
        $out['C-smsdpprov.log'] -eq 'stale October 28 DP log') 'The share-authoritative, rolled, and stale-root DP logs were not kept separately.'
    Assert-True ($out['_dp-collector-diag.txt'] -match 'modifiedUtc=.*tailLines=4000') 'DP log freshness is not recorded.'
    Assert-True ($out['DpPxePayload.txt'] -match [regex]::Escape('C:\AlternatePxe\SMSBoot\PRI00008\x64\wdsmgfw.efi') -and
        $out['DpPxePayload.txt'] -match 'bytes=1024' -and
        $out['DpPxePayload.txt'] -match 'fixture-sddl' -and
        $out['DpPxePayload.txt'] -match "DataLib 'PRI00008.4': files=1 folders=0" -and
        $out['DpPxePayload.txt'] -match 'missing fixture') 'PXE capture does not explain service roots, actual boot files, ACLs, package shape, and absent paths.'
    $state.ReadFails = $true
    $out = & $dpCollector
    Assert-True ($out['_dp-collector-diag.txt'] -match 'synthetic DP log access denied' -and
        $out.ContainsKey('smsdpprov.lo_') -and $out.ContainsKey('DpPxePayload.txt')) 'An unreadable active log hid its error or prevented independent evidence.'
}

Write-Host 'PASS -- OSD failures retain feeding-site, provider, workflow, current/rolled DP logs, and timestamped PXE payload evidence.'
