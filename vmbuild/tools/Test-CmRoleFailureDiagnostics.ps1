<#
.SYNOPSIS
    Exercises automatic MP/RP failure capture without Hyper-V or guest configuration changes.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Read by the imported failure-capture functions.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Get-TestAst {
    param([string] $Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "$Path parse errors: $($parseErrors -join '; ')" }
    return $ast
}
function Get-TestFunction {
    param($Ast, [string] $Name)
    $nodes = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    Assert-True ($nodes.Count -eq 1) "Expected one $Name definition."
    [scriptblock]::Create($nodes[0].Extent.Text)
}
$commonAst = Get-TestAst (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1')
$validationAst = Get-TestAst (Join-Path $RootPath 'common\Common.Validation.Functional.ps1')
$mpPath = Join-Path $RootPath 'tools\Get-ManagementPointDiagnostics.ps1'
$mpAst = Get-TestAst $mpPath
$setupDefinition = $commonAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-CMSetupLogsFromVm'
    }, $true)
$prerequisiteGuards = @($setupDefinition.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$Mode') -and
            $node.Clauses[0].Item1.Extent.Text.Contains('$Phase') -and
            $node.Clauses[0].Item2.Extent.Text.Contains('$prereq = [ordered]@{')
        }, $true))
Assert-True ($prerequisiteGuards.Count -eq 1) 'Expected one prerequisite snapshot guard.'
$prerequisiteGuard = [scriptblock]::Create("param(`$Mode, `$Phase) $($prerequisiteGuards[0].Clauses[0].Item1.Extent.Text)")
Assert-True ((& $prerequisiteGuard Failure 3) -and (& $prerequisiteGuard Failure 8) -and
    -not (& $prerequisiteGuard Success 3) -and -not (& $prerequisiteGuard Failure 7)) 'CBS/DISM failure evidence is not scoped to the feature/setup failure phases.'
$workDir = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-RoleDiagnostics-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $workDir
try {
    & {
        . (Get-TestFunction $mpAst 'Invoke-ManagementPointDiagnosticNative')
        $text = Invoke-ManagementPointDiagnosticNative -FilePath $env:ComSpec -Arguments @('/d', '/c', 'echo success&echo stderr 1>&2&exit /b 0')
        Assert-True ($text -match 'success' -and $text -match 'stderr') 'Native stderr disrupted a successful diagnostic.'
        $caught = $null
        try { Invoke-ManagementPointDiagnosticNative -FilePath $env:ComSpec -Arguments @('/d', '/c', 'echo failure 1>&2&exit /b 7') }
        catch { $caught = $_ }
        Assert-True ($caught -and $caught.Exception.Message -match 'exited 7.*failure') 'Native stderr bypassed exit-code reporting.'
    }

    $windows = Join-Path $workDir 'Windows'
    $configDir = Join-Path $windows 'System32\inetsrv\config'
    $null = New-Item -ItemType Directory -Path $configDir -Force
    '<configuration><system.applicationHost><sites><site name="Default Web Site" id="1"><application path="/" applicationPool="DefaultAppPool"><virtualDirectory path="/SMS_MP" physicalPath="E:\SMS_CCM\SMS_MP" userName="fixture-user" password="DO-NOT-EXPORT" /></application></site><site name="SMSWEB" id="2"><application path="/SMS_MP" applicationPool="MPPool"><virtualDirectory path="/" physicalPath="E:\SMS_CCM\SMS_MP" /></application></site></sites></system.applicationHost></configuration>' |
        Set-Content -LiteralPath (Join-Path $configDir 'applicationHost.config') -Encoding UTF8
    if (-not (Get-PSDrive -Name E -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -Name E -PSProvider FileSystem -Root $workDir -Scope Script
    }
    $savedWindows = $env:windir
    try {
        $env:windir = $windows
        & {
            $localState = [pscustomobject]@{ ModuleFailure = $false; LogFailure = $false; FullReads = 0; TailReads = 0 }
            function Import-Module {
                param($Name, $ErrorAction)
                if ($localState.ModuleFailure) { throw 'synthetic IIS module failure' }
            }
            function Test-Path {
                param([string]$LiteralPath, [string]$PathType, $ErrorAction)
                if ($LiteralPath -like 'HKLM:\*') { return $true }
                return $LiteralPath -in @('E:\SMS\Logs', 'E:\SMS_CCM\SMS_MP', 'E:\Unreadable\Logs')
            }
            function Get-ItemProperty {
                param([string]$LiteralPath, $ErrorAction)
                if ($LiteralPath -like '*\Setup') { return [pscustomobject]@{ 'Installation Directory' = 'E:\Unreadable' } }
                [pscustomobject]@{ LogDirectory = 'E:\SMS\Logs' }
            }
            function Get-Service {
                param($ErrorAction)
                [pscustomobject]@{ Name = 'W3SVC'; Status = 'Running' }
            }
            function Get-WebApplication { param($Site, $ErrorAction) }
            function Get-WebVirtualDirectory {
                param($Site, $ErrorAction)
                [pscustomobject]@{ Path = '/SMS_MP'; PhysicalPath = 'E:\SMS_CCM\SMS_MP' }
            }
            function Get-WebBinding { param($ErrorAction) }
            function Get-ChildItem {
                param([string]$LiteralPath, [string]$Path, [switch]$File, $ErrorAction)
                if ($Path -eq 'C:\staging\InstallFeatureStatus*.txt') {
                    return [pscustomobject]@{ FullName = 'C:\staging\InstallFeatureStatusFixture8.txt'; LastWriteTimeUtc = [datetime]::UtcNow }
                }
                switch ($LiteralPath) {
                    'IIS:\AppPools' { [pscustomobject]@{ Name = 'MPPool'; State = 'Started' }; break }
                    'Cert:\LocalMachine\My' {
                        [pscustomobject]@{ EnhancedKeyUsageList = @([pscustomobject]@{ ObjectId = '1.3.6.1.5.5.7.3.1' }) }
                        break
                    }
                    'E:\SMS\Logs' {
                        [pscustomobject]@{ Name = 'mpMSI.log'; FullName = 'E:\SMS\Logs\mpMSI.log'; Length = 8MB; LastWriteTimeUtc = [datetime]::UtcNow }
                        [pscustomobject]@{ Name = 'MPSetup.log'; FullName = 'E:\SMS\Logs\MPSetup.log'; Length = (8MB + 1); LastWriteTimeUtc = [datetime]::UtcNow }
                        break
                    }
                    'E:\Unreadable\Logs' { throw 'synthetic directory failure' }
                    default { throw "Unexpected directory: $LiteralPath" }
                }
            }
            function Get-Content {
                param([string]$LiteralPath, [switch]$Raw, [int]$Tail, [int]$TotalCount, $ErrorAction)
                switch ($LiteralPath) {
                    'C:\staging\InstallFeatureStatusFixture8.txt' { return @('BITS,BITS-IIS-Ext', 'MemLabsFeatureStateVerified=1') }
                    'E:\SMS\Logs\mpMSI.log' {
                        if ($localState.LogFailure) { throw 'synthetic log failure' }
                        Assert-True ($Raw -and -not $PSBoundParameters.ContainsKey('Tail')) 'The 8 MiB boundary was not retained in full.'
                        $localState.FullReads++
                        return 'MSI: Error 25051. Return value 3.'
                    }
                    'E:\SMS\Logs\MPSetup.log' {
                        Assert-True ($Tail -eq 6000 -and -not $Raw) 'Oversized logs lost the 6000-line bound.'
                        $localState.TailReads++
                        return @('setup', 'exit 1603')
                    }
                    default { return Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop }
                }
            }
            $payload = @(& $mpPath -SiteCode NOM -AsJson)
            Assert-True ($payload.Count -eq 1 -and $payload[0] -is [string]) 'MP collector did not return one JSON document.'
            $document = $payload[0] | ConvertFrom-Json
            $provider = $document.Probes | Where-Object Name -eq 'IisProviderEndpoint'
            $configuration = $document.Probes | Where-Object Name -eq 'IisConfigurationFile'
            Assert-True ($provider.Success -and -not $provider.Data[0].Exists -and $configuration.Success) 'Provider and independent IIS evidence were not retained separately.'
            Assert-True (@($configuration.Data[0].Sites.Applications.VirtualDirectories | Where-Object IsSmsMp).Count -eq 2) 'Virtual-directory/application or custom-site endpoint mapping changed.'
            Assert-True ($payload[0] -notmatch 'DO-NOT-EXPORT|fixture-user') 'IIS configuration credentials were exported.'
            Assert-True ($localState.FullReads -eq 1 -and $localState.TailReads -eq 1 -and $document.Logs.Count -eq 2) 'Non-C: logs or exact capture bounds were lost.'
            Assert-True (($document.CollectionErrors -join '; ') -match 'synthetic directory failure') 'An inaccessible directory was hidden or suppressed other available logs.'
            $certificate = $document.Probes | Where-Object Name -eq 'PublicCertificateMetadata'
            Assert-True ($certificate.Data[0].EnhancedKeyUsageOids[0] -eq '1.3.6.1.5.5.7.3.1') 'Single-EKU metadata lost its array shape.'
            $receipt = $document.Probes | Where-Object Name -eq 'FeatureReceipts'
            Assert-True $receipt.Data[0].Verified 'Verified feature receipt evidence is missing.'
            $localState.ModuleFailure = $true
            $localState.LogFailure = $true
            $document = (& $mpPath -AsJson) | ConvertFrom-Json
            Assert-True (($document.CollectionErrors -join '; ') -match 'synthetic IIS module failure' -and ($document.CollectionErrors -join '; ') -match 'synthetic log failure') 'MP probe failures were swallowed.'
            $document = (& $mpPath -SiteServerOnly -AsJson) | ConvertFrom-Json
            Assert-True (@($document.Probes | Where-Object Name -like 'Iis*').Count -eq 0) 'Owning-site log collection incorrectly requires an MP.'
        }
    }
    finally { $env:windir = $savedWindows }

    & {
        $definition = Get-TestFunction $commonAst 'Save-CMRoleFailureDiagnostics'
        $definitionText = $definition.ToString().Replace('(Split-Path -Parent $PSScriptRoot)', "'$($RootPath.Replace("'", "''"))'")
        . ([scriptblock]::Create($definitionText))
        $Common = [pscustomobject]@{ LogPath = (Join-Path $workDir 'VMBuild.log') }
        $transportFixture = [pscustomobject]@{
            Mode = 'Success'; Calls = [Collections.Generic.List[object]]::new()
            Payloads = @{}; Messages = [Collections.Generic.List[string]]::new()
        }
        $primary = [pscustomobject]@{ vmName = 'PRI'; role = 'Primary'; siteCode = 'NOM'; remoteSQLVM = 'SQL'; installRP = $false }
        $mp = [pscustomobject]@{ vmName = 'MP'; role = 'SiteSystem'; siteCode = 'NOM'; installMP = $true }
        $sql = [pscustomobject]@{ vmName = 'SQL'; role = 'DomainMember'; installRP = $true }
        $secondary = [pscustomobject]@{ vmName = 'SEC'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'NOM' }
        $other = [pscustomobject]@{ vmName = 'OTHER'; role = 'Primary'; siteCode = 'ALT'; installMP = $true; installRP = $true }
        $config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'example.test' }; virtualMachines = @($primary, $mp, $sql, $secondary, $other) }
        function Write-Log { param($Text, [switch]$Warning, [switch]$OutputStream, [switch]$LogOnly); $transportFixture.Messages.Add("$Text") }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, [switch]$AsJob, $TimeoutSeconds,
                $SessionMaxRetries, [switch]$SuppressLog, [switch]$RequireDomainIdentity, [switch]$FailOnRemoteError, $DisplayName)
            Assert-True ($AsJob -and $SessionMaxRetries -eq 1 -and $RequireDomainIdentity -and $FailOnRemoteError -and $VmDomainName -eq 'example.test') 'Automatic capture lost its bounded, domain-authenticated transport.'
            $transportFixture.Calls.Add([pscustomobject]@{ VmName = $VmName; DisplayName = $DisplayName; Arguments = $ArgumentList; ScriptBlock = $ScriptBlock })
            if ($DisplayName -eq 'Remove staged role diagnostic') {
                Assert-True ($TimeoutSeconds -eq 30 -and $ArgumentList[0] -match '^C:\\Windows\\Temp\\MemLabs-RoleDiagnostics-[a-f0-9]{32}\.json$') 'Cleanup did not target only the generated artifact.'
                if ($transportFixture.Mode -eq 'CleanupFailure' -and $VmName -eq 'MP') { throw 'synthetic cleanup failure' }
                return [pscustomobject]@{ CommandResult = $true; ScriptBlockFailed = $false }
            }
            $role = ($DisplayName -split ' ')[1]
            $expectedTimeout = if ($role -eq 'RP') { 600 } else { 180 }
            Assert-True ($TimeoutSeconds -eq $expectedTimeout -and $ArgumentList[1].AsJson) 'Role capture lost its documented budget or JSON mode.'
            if ($transportFixture.Mode -eq 'TransportFailure' -and $VmName -eq 'MP') {
                return [pscustomobject]@{ CommandResult = $false; ScriptBlockFailed = $true; TimedOut = $true; ErrorDetails = @('synthetic timeout') }
            }
            $document = [ordered]@{
                ComputerName = $VmName; CollectedAt = [datetime]::UtcNow.ToString('o')
                CollectionErrors = @(); Logs = @(); SiteCode = $ArgumentList[1].SiteCode
            }
            if ($role -eq 'RP') { $document.Endpoints = @() } else { $document.Probes = @() }
            if ($transportFixture.Mode -eq 'ProbeFailure' -and $VmName -eq 'MP') { $document.CollectionErrors = @('synthetic probe failure') }
            if ($transportFixture.Mode -eq 'IdentityMismatch' -and $VmName -eq 'MP') { $document.ComputerName = 'WRONG' }
            $json = $document | ConvertTo-Json -Depth 5
            if ($transportFixture.Mode -eq 'InvalidJson' -and $VmName -eq 'MP') { $json = '{invalid' }
            $transportFixture.Payloads[$ArgumentList[2]] = $json
            $path = if ($transportFixture.Mode -eq 'InvalidManifest' -and $VmName -eq 'MP') { 'C:\unexpected.json' } else { $ArgumentList[2] }
            [pscustomobject]@{
                CommandResult = $true; ScriptBlockFailed = $false
                ScriptBlockOutput = [pscustomobject]@{ Path = $path; Bytes = [Text.Encoding]::UTF8.GetByteCount($json) }
            }
        }
        function Copy-ItemFromVmBounded {
            param($Path, $Destination, $VMName, $VMDomainName, $TimeoutSeconds)
            Assert-True ($TimeoutSeconds -eq 180 -and $VMDomainName -eq 'example.test') 'Role file transfer lost its bound or domain.'
            if ($transportFixture.Mode -eq 'CopyFailure' -and $VMName -eq 'MP') { return $false }
            [IO.File]::WriteAllText($Destination, $transportFixture.Payloads[$Path], [Text.UTF8Encoding]::new($false))
            return $true
        }
        Save-CMRoleFailureDiagnostics -VmName PRI -DomainName example.test -Phase 8 -DeployConfig $config
        $calls = @($transportFixture.Calls | Where-Object DisplayName -like 'Capture *')
        Assert-True ($calls.Count -eq 5 -and 'OTHER' -notin $calls.VmName) "Phase 8 target capture is incorrect (calls=$($calls.Count)): $($transportFixture.Messages -join ' | ')"
        $rpCall = $calls | Where-Object DisplayName -eq 'Capture RP role diagnostics'
        Assert-True ($rpCall.VmName -eq 'SQL' -and $rpCall.Arguments[1].SiteCode -eq 'NOM') 'Remote SQL-hosted RP ownership was guessed incorrectly.'
        $siteCalls = @($calls | Where-Object DisplayName -eq 'Capture SiteServer role diagnostics')
        Assert-True ($siteCalls.Count -eq 2 -and @($siteCalls | Where-Object { -not $_.Arguments[1].SiteServerOnly }).Count -eq 0) 'Owning-site logs incorrectly require local MPs.'
        $stage = $calls[0].ScriptBlock
        $stagePath = Join-Path $workDir 'stage.json'
        $source = 'param([switch]$AsJson) if (-not $AsJson) { throw "JSON mode required" }; ''{"ComputerName":"fixture","Body":"'' + (''x'' * 65536) + ''"}'''
        $manifest = @(& $stage $source @{ AsJson = $true } $stagePath)
        Assert-True ($manifest.Count -eq 1 -and $manifest[0].Bytes -gt 65536 -and ($manifest | ConvertTo-Json).Length -lt 1024) 'Large guest diagnostic bodies crossed the PSDirect return stream.'

        foreach ($mode in @('Success', 'TransportFailure', 'CopyFailure', 'InvalidManifest', 'InvalidJson', 'IdentityMismatch', 'ProbeFailure', 'CleanupFailure')) {
            $transportFixture.Mode = $mode
            $transportFixture.Calls.Clear()
            Save-CMRoleFailureDiagnostics -VmName MP -DomainName example.test -Phase 11 -DeployConfig $config -Roles MP
            $statusFile = Get-ChildItem -LiteralPath $workDir -Filter 'MP-Phase11-*-RoleDiagnostics.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $status = Get-Content -LiteralPath $statusFile.FullName -Raw | ConvertFrom-Json
            $expected = if ($mode -eq 'Success') { 'Completed' } else { 'Partial' }
            Assert-True ($status.CaptureStatus -eq $expected -and $status.Targets.Count -eq 2) "$mode did not persist accurate automatic capture status."
            Assert-True (@($status.Targets | Where-Object { $_.Role -eq 'SiteServer' -and $_.CaptureStatus -eq 'Completed' }).Count -eq 1) "$mode prevented independent owning-site evidence."
            if ($mode -eq 'CleanupFailure') {
                $captured = $status.Targets | Where-Object Role -eq 'MP'
                Assert-True ($captured.CaptureStatus -eq 'CompletedWithErrors' -and $captured.CleanupError -match 'synthetic cleanup failure' -and (Test-Path -LiteralPath $captured.HostPath)) 'Cleanup failure discarded successful evidence.'
            }
        }
        $transportFixture.Mode = 'Success'
        $transportFixture.Calls.Clear()
        Save-CMRoleFailureDiagnostics -VmName SQL -DomainName example.test -Phase 7 -DeployConfig $config
        Assert-True (@($transportFixture.Calls | Where-Object DisplayName -eq 'Capture RP role diagnostics').Count -eq 1 -and @($transportFixture.Calls | Where-Object DisplayName -eq 'Capture MP role diagnostics').Count -eq 0) 'Phase 7 capture requests MP checks before role provisioning.'
    }

    & {
        . (Get-TestFunction $validationAst 'Test-SiteSystemFunctionality')
        . (Get-TestFunction $validationAst 'Test-ReportingFunctionality')
        . (Get-TestFunction $commonAst 'Save-CMSetupLogsFromVm')
        $Common = [pscustomobject]@{ LogPath = (Join-Path $workDir 'VMBuild.log') }
        $hooks = [pscustomobject]@{ Passed = $true; Throw = $false; Captures = [Collections.Generic.List[object]]::new() }
        $item = [pscustomobject]@{ vmName = 'MP'; role = 'SiteSystem'; siteCode = 'NOM'; installMP = $true }
        $config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'example.test' }; virtualMachines = @($item) }
        function Write-Progress2 { param($PercentComplete, $Activity, $Status) }
        function Write-Log { param($Text, [switch]$Warning, [switch]$OutputStream, [switch]$LogOnly) }
        function Format-TestResult { param($VMName, $RoleLabel, $Result); return $hooks.Passed }
        function Save-CMRoleFailureDiagnostics {
            param($VmName, $DomainName, $Phase, $DeployConfig, $Roles)
            $hooks.Captures.Add([pscustomobject]@{ VmName = $VmName; Phase = $Phase; Roles = $Roles })
        }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$SuppressLog, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries)
            if ($hooks.Throw) { throw 'synthetic validation transport failure' }
            if ($DisplayName -eq 'Capture ConfigMgr provider state') {
                return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = '{"ProbeStatus":"Completed"}' }
            }
            $output = [pscustomobject]@{ SetupExists = $false; WrapperExists = $false; DscLogExists = $false; AdkArtifacts = @(); CmArtifacts = @(); UpdateDiagnostics = '{"CaptureStatus":"Completed"}' }
            [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output }
        }
        Assert-True (Test-SiteSystemFunctionality -VMName MP -CurrentItem $item -DeployConfig $config) 'Healthy MP validation changed its result.'
        Assert-True ($hooks.Captures.Count -eq 0) 'Healthy MP validation ran failure diagnostics.'
        $hooks.Passed = $false
        Assert-True (-not (Test-SiteSystemFunctionality -VMName MP -CurrentItem $item -DeployConfig $config)) 'Failed MP validation was converted to success.'
        Assert-True ($hooks.Captures.Count -eq 1 -and $hooks.Captures[0].Roles -eq 'MP') 'Failed MP validation did not automatically capture evidence.'
        $hooks.Throw = $true
        foreach ($role in @('MP', 'RP')) {
            $caught = $null
            $count = $hooks.Captures.Count
            try {
                if ($role -eq 'MP') { Test-SiteSystemFunctionality -VMName MP -CurrentItem $item -DeployConfig $config }
                else { Test-ReportingFunctionality -VMName MP -Domain example.test -CurrentItem $item -DeployConfig $config }
            }
            catch { $caught = $_ }
            Assert-True ($caught -and $caught.Exception.Message -match 'synthetic validation transport failure' -and $hooks.Captures.Count -eq ($count + 1)) "$role transport exceptions bypassed capture or were replaced."
        }
        $hooks.Throw = $false
        foreach ($case in @(@{ Phase = 7; Mode = 'Failure'; Capture = $true }, @{ Phase = 8; Mode = 'Failure'; Capture = $true },
                @{ Phase = 8; Mode = 'Success'; Capture = $false }, @{ Phase = 3; Mode = 'Failure'; Capture = $false })) {
            $count = $hooks.Captures.Count
            Save-CMSetupLogsFromVm -VmName MP -DomainName example.test -Phase $case.Phase -Mode $case.Mode -DeployConfig $config
            $expectedCount = if ($case.Capture) { $count + 1 } else { $count }
            Assert-True ($hooks.Captures.Count -eq $expectedCount) "Main failure hook is incorrect for Phase $($case.Phase), $($case.Mode)."
        }
    }
    Write-Host "PASS -- automatic MP/RP failure capture, independent owning-site logs, bounded file staging, truthful partial status, and unchanged validation outcomes (PowerShell $($PSVersionTable.PSVersion))."
}
finally { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
