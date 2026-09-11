#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.DownloadCache.ps1'
$tokens = $null
$parseErrors = $null
$sourceAst = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) { throw "$sourcePath has $(@($parseErrors).Count) parse error(s)." }

$sourceFunctions = @{}
foreach ($functionName in 'Write-VmMediaHostDiag', 'Mount-IsoOnVm', 'Confirm-IsoVisibleInGuest', 'Reset-AllDvdDrivesOnVm') {
    $functionAst = @($sourceAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true))
    if ($functionAst.Count -ne 1) { throw "Expected one $functionName function, found $($functionAst.Count)." }
    $sourceFunctions[$functionName] = $functionAst[0]
    . ([scriptblock]::Create($functionAst[0].Extent.Text))
}

$script:Failures = 0
function Assert-SqlMediaEqual {
    param($Expected, $Actual, [string]$What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

$hostDiagnosticWrites = @($sourceFunctions['Write-VmMediaHostDiag'].FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Log'
        }, $true))
$hostDiagnosticsWithoutLogOnly = @($hostDiagnosticWrites | Where-Object {
        -not ($_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LogOnly' })
    })
Assert-SqlMediaEqual 6 $hostDiagnosticWrites.Count 'All host diagnostic write paths are covered'
Assert-SqlMediaEqual 0 $hostDiagnosticsWithoutLogOnly.Count 'Every host diagnostic write is log-only'

$guestDiagnosticWrites = @($sourceFunctions['Confirm-IsoVisibleInGuest'].FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Write-Log' -and
            $node.Extent.Text -match 'REBOOTED mid-probe|media state UNKNOWN|media NOT visible in guest|media guest diag'
        }, $true))
$guestDiagnosticsWithoutLogOnly = @($guestDiagnosticWrites | Where-Object {
        -not ($_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LogOnly' })
    })
Assert-SqlMediaEqual 5 $guestDiagnosticWrites.Count 'All detailed guest diagnostic write paths are covered'
Assert-SqlMediaEqual 0 $guestDiagnosticsWithoutLogOnly.Count 'Every detailed guest diagnostic write is log-only'

$phasePath = Join-Path $RootPath 'common\Common.Phases.ps1'
$phaseTokens = $null
$phaseParseErrors = $null
$phaseAst = [Management.Automation.Language.Parser]::ParseFile($phasePath, [ref]$phaseTokens, [ref]$phaseParseErrors)
if (@($phaseParseErrors).Count -ne 0) { throw "$phasePath has $(@($phaseParseErrors).Count) parse error(s)." }
$mountPhaseAst = @($phaseAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Mount-SqlIsoForPhase'
        }, $true))
if ($mountPhaseAst.Count -ne 1) { throw "Expected one Mount-SqlIsoForPhase function, found $($mountPhaseAst.Count)." }
$phaseWrites = @($mountPhaseAst[0].FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Log'
        }, $true))
$resetProgressWrite = @($phaseWrites | Where-Object { $_.Extent.Text -like '*clean DVD reset + recheck*' })
$recoveryOutcomeWrites = @($phaseWrites | Where-Object { $_.Extent.Text -match 'SQL media recovered|SQL media is still not visible after a clean DVD device rebuild' })
$incompleteOutcomeWrites = @($phaseWrites | Where-Object { $_.Extent.Text -like '*did not restore the complete optical topology*' })
Assert-SqlMediaEqual 1 $resetProgressWrite.Count 'The detailed reset-progress message is present'
Assert-SqlMediaEqual 1 @($resetProgressWrite[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LogOnly' }).Count 'The reset-progress message is log-only'
Assert-SqlMediaEqual 2 $recoveryOutcomeWrites.Count 'Success and persistent-failure console outcomes are present'
Assert-SqlMediaEqual 2 @($recoveryOutcomeWrites | Where-Object {
        $_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Warning' }
    }).Count 'Recovery outcomes retain warning severity'
Assert-SqlMediaEqual 0 @($recoveryOutcomeWrites | Where-Object {
        $_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LogOnly' }
    }).Count 'Recovery outcomes remain visible on the console'
Assert-SqlMediaEqual 2 $incompleteOutcomeWrites.Count 'Visible and missing-media incomplete-topology outcomes are present'
Assert-SqlMediaEqual 2 @($incompleteOutcomeWrites | Where-Object {
        $_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Failure' }
    }).Count 'Incomplete-topology outcomes retain failure severity'
Assert-SqlMediaEqual 0 @($incompleteOutcomeWrites | Where-Object {
        $_.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LogOnly' }
    }).Count 'Incomplete-topology outcomes remain visible on the console'

$script:LogEntries = [Collections.Generic.List[object]]::new()
function Write-Log {
    param(
        [Parameter(Position = 0)]$Message,
        [switch]$Warning,
        [switch]$Failure,
        [switch]$LogOnly
    )
    $script:LogEntries.Add([pscustomobject]@{
            Message = "$Message"
            Warning = [bool]$Warning
            Failure = [bool]$Failure
            LogOnly = [bool]$LogOnly
        })
}

$script:DvdDrives = @()
$script:SetCalls = 0
$script:AddCalls = 0
$script:RemoveCalls = 0
$script:RefreshCalls = 0
$script:AddFailurePath = ''
$script:RemoveFailureLocation = -1
$script:GetDvdCalls = 0
$script:InjectOnGetCall = -1
$script:GetDvdFailureCall = -1
$script:FinalTopologyInjection = ''
$script:InjectedIsoPath = ''
function Get-VMDvdDrive {
    param([string]$VMName, $ErrorAction)
    $script:GetDvdCalls++
    if ($script:GetDvdCalls -eq $script:GetDvdFailureCall) { throw 'modeled DVD inventory failure' }
    $result = @($script:DvdDrives)
    if ($script:GetDvdCalls -eq $script:InjectOnGetCall) {
        if ($script:FinalTopologyInjection -eq 'unexpected') {
            $result += [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 20; ControllerType = 'SCSI'; Path = $script:InjectedIsoPath }
        }
        elseif ($script:FinalTopologyInjection -eq 'empty') {
            $result += [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 20; ControllerType = 'SCSI'; Path = $null }
        }
        elseif ($script:FinalTopologyInjection -eq 'duplicate') {
            $result += [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 20; ControllerType = 'SCSI'; Path = $result[0].Path }
        }
    }
    return $result
}
function Set-VMDvdDrive {
    param([string]$VMName, [int]$ControllerNumber, [int]$ControllerLocation, [string]$Path, $ErrorAction)
    $script:SetCalls++
    $drive = $script:DvdDrives | Where-Object { $_.ControllerNumber -eq $ControllerNumber -and $_.ControllerLocation -eq $ControllerLocation } | Select-Object -First 1
    if ($drive) { $drive.Path = $Path }
}
function Add-VMDvdDrive {
    param([string]$VMName, [string]$Path, $ErrorAction)
    $script:AddCalls++
    if ($Path -eq $script:AddFailurePath) { throw "modeled add failure for $Path" }
    $script:DvdDrives += [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = (8 + $script:AddCalls); ControllerType = 'SCSI'; Path = $Path }
}
function Remove-VMDvdDrive {
    param([string]$VMName, [int]$ControllerNumber, [int]$ControllerLocation, $ErrorAction)
    $script:RemoveCalls++
    if ($ControllerLocation -eq $script:RemoveFailureLocation) { throw "modeled removal failure at $ControllerNumber`:$ControllerLocation" }
    $script:DvdDrives = @($script:DvdDrives | Where-Object {
            $_.ControllerNumber -ne $ControllerNumber -or $_.ControllerLocation -ne $ControllerLocation
        })
}
function Test-VmMediaChangeReadiness {
    param([string]$VmName, [int]$TimeoutSeconds)
    return [pscustomobject]@{ Ok = $true; Running = $true; State = 'Running'; Generation = $script:VmGeneration; HotPlugOk = ($script:VmGeneration -ne 1); Uptime = [timespan]::FromMinutes(5); Heartbeat = 'enabled=True status=OK'; Actions = @(); Reason = '' }
}
function Invoke-VmSessionRefreshAfterMediaChange {
    param([string]$VmName)
    $script:RefreshCalls++
}
function Start-Sleep { param([int]$Seconds) }

$isoPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-sql-media-$([guid]::NewGuid().ToString('N')).iso"
$siblingIsoPath = Join-Path ([IO.Path]::GetTempPath()) "memlabs-sql-media-sibling-$([guid]::NewGuid().ToString('N')).iso"
try {
    [IO.File]::WriteAllText($isoPath, 'test')
    [IO.File]::WriteAllText($siblingIsoPath, 'sibling')
    $script:VmGeneration = 2

    $script:DvdDrives = @(
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $isoPath }
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 3; ControllerType = 'SCSI'; Path = $siblingIsoPath }
    )
    $represented = Mount-IsoOnVm -VmName 'SQL1' -IsoPath $isoPath -Context SQL -Phase 4 -RepresentIfAttached
    Assert-SqlMediaEqual $true $represented 'An attached SQL ISO is re-presented successfully'
    Assert-SqlMediaEqual 2 $script:RemoveCalls 'Re-presentation removes every existing DVD drive'
    Assert-SqlMediaEqual 2 $script:AddCalls 'Re-presentation restores every captured ISO'
    Assert-SqlMediaEqual 0 $script:SetCalls 'Re-presentation does not use the racy same-drive media toggle'
    Assert-SqlMediaEqual 2 $script:DvdDrives.Count 'Re-presentation restores the exact DVD count'
    Assert-SqlMediaEqual $true ($script:DvdDrives.Path -contains $isoPath) 'Re-presentation restores the required SQL ISO'
    Assert-SqlMediaEqual $true ($script:DvdDrives.Path -contains $siblingIsoPath) 'Re-presentation preserves a co-mounted ISO'

    $script:VmGeneration = 1
    $script:DvdDrives = @([pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'IDE'; Path = $isoPath })
    $script:RemoveCalls = 0
    $script:AddCalls = 0
    $script:SetCalls = 0
    $gen1Represented = Mount-IsoOnVm -VmName 'SQL1GEN1' -IsoPath $isoPath -Context SQL -Phase 4 -RepresentIfAttached
    Assert-SqlMediaEqual $true $gen1Represented 'Running Gen1 re-presents an attached SQL ISO successfully'
    Assert-SqlMediaEqual 0 $script:RemoveCalls 'Running Gen1 does not remove its IDE DVD drive'
    Assert-SqlMediaEqual 0 $script:AddCalls 'Running Gen1 does not attempt an unsupported DVD hot-add'
    Assert-SqlMediaEqual 2 $script:SetCalls 'Running Gen1 uses same-drive eject and remount'
    Assert-SqlMediaEqual $isoPath $script:DvdDrives[0].Path 'Running Gen1 restores the SQL ISO on its original drive'
    $script:VmGeneration = 2

    $script:DvdDrives = @([pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $isoPath })
    $script:RemoveCalls = 0
    $script:AddCalls = 0
    $script:SetCalls = 0
    $script:RemoveFailureLocation = 1
    $failedRepresentation = Mount-IsoOnVm -VmName 'SQL1' -IsoPath $isoPath -Context SQL -Phase 4 -RepresentIfAttached
    Assert-SqlMediaEqual $false $failedRepresentation 'A failed DVD removal propagates rebuild failure'
    Assert-SqlMediaEqual 1 $script:RemoveCalls 'A failed re-presentation attempts the existing drive removal once'
    Assert-SqlMediaEqual 0 $script:AddCalls 'A failed removal does not duplicate an ISO that remains attached'
    Assert-SqlMediaEqual 0 $script:SetCalls 'A failed rebuild does not fall through to the racy media toggle'
    $script:RemoveFailureLocation = -1

    $script:DvdDrives = @([pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $null })
    $script:RemoveCalls = 0
    $script:AddCalls = 0
    $script:SetCalls = 0
    $mounted = Mount-IsoOnVm -VmName 'SQL2' -IsoPath $isoPath -Context SQL -Phase 4 -RepresentIfAttached
    Assert-SqlMediaEqual $true $mounted 'A newly attached SQL ISO still uses the ordinary mount path'
    Assert-SqlMediaEqual 0 $script:RemoveCalls 'An empty drive does not trigger a topology rebuild'
    Assert-SqlMediaEqual 1 $script:SetCalls 'An empty drive receives the SQL ISO once'

    $script:DvdDrives = @(
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $isoPath }
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 3; ControllerType = 'SCSI'; Path = $siblingIsoPath }
    )
    $script:RemoveCalls = 0
    $script:AddCalls = 0
    $script:AddFailurePath = $siblingIsoPath
    $partialRestore = Reset-AllDvdDrivesOnVm -VmName 'SQL3' -RequiredIsoPath $isoPath -Context SQL -Phase 4
    Assert-SqlMediaEqual $false $partialRestore 'A failed sibling ISO re-add fails the topology rebuild'
    Assert-SqlMediaEqual 2 $script:RemoveCalls 'The sibling failure scenario removes the original topology'
    Assert-SqlMediaEqual 2 $script:AddCalls 'The sibling failure scenario attempts every captured ISO'
    Assert-SqlMediaEqual $true ($script:DvdDrives.Path -contains $isoPath) 'The required SQL ISO is restored before reporting partial failure'
    Assert-SqlMediaEqual $false ($script:DvdDrives.Path -contains $siblingIsoPath) 'The modeled missing sibling remains observable in final topology'
    Assert-SqlMediaEqual $true ([bool]($script:LogEntries | Where-Object { $_.Message -like '*DVD reset verification failed*' })) 'Partial restoration records verification evidence'
    $script:AddFailurePath = ''

    $script:DvdDrives = @(
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $isoPath }
        [pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 3; ControllerType = 'SCSI'; Path = $siblingIsoPath }
    )
    $script:GetDvdCalls = 0
    $script:GetDvdFailureCall = 2
    $script:AddCalls = 0
    $postRemovalQueryFailure = Reset-AllDvdDrivesOnVm -VmName 'SQL3' -RequiredIsoPath $isoPath -Context SQL -Phase 4
    Assert-SqlMediaEqual $false $postRemovalQueryFailure 'Post-removal DVD inventory failure reports rebuild failure'
    Assert-SqlMediaEqual 2 $script:AddCalls 'Post-removal inventory failure attempts to restore every successfully removed ISO'
    Assert-SqlMediaEqual $true ($script:DvdDrives.Path -contains $isoPath) 'Post-removal inventory failure restores the required SQL ISO'
    Assert-SqlMediaEqual $true ($script:DvdDrives.Path -contains $siblingIsoPath) 'Post-removal inventory failure restores the sibling ISO'
    $script:GetDvdFailureCall = -1

    $script:InjectedIsoPath = $siblingIsoPath
    foreach ($injection in 'unexpected', 'empty', 'duplicate') {
        $script:DvdDrives = @([pscustomobject]@{ ControllerNumber = 0; ControllerLocation = 1; ControllerType = 'SCSI'; Path = $isoPath })
        $script:GetDvdCalls = 0
        $script:InjectOnGetCall = 3
        $script:FinalTopologyInjection = $injection
        $script:LogEntries.Clear()
        $injectedResult = Reset-AllDvdDrivesOnVm -VmName 'SQL3' -RequiredIsoPath $isoPath -Context SQL -Phase 4
        Assert-SqlMediaEqual $false $injectedResult "$injection final topology fails rebuild verification"
        Assert-SqlMediaEqual $true ([bool]($script:LogEntries | Where-Object { $_.Message -like '*DVD reset verification failed*' })) "$injection final topology records verification evidence"
    }
    $script:InjectOnGetCall = -1
    $script:FinalTopologyInjection = ''

    function Get-VM2 {
        param([string]$Name, [switch]$Fallback)
        return [pscustomobject]@{ State = 'Running'; Status = 'Operating normally'; Generation = 2; Uptime = [timespan]::FromMinutes(5) }
    }
    function Get-VMIntegrationService {
        param([Parameter(ValueFromPipeline)]$InputObject, $ErrorAction)
        process { [pscustomobject]@{ Name = 'Heartbeat'; PrimaryStatusDescription = 'OK'; Enabled = $true } }
    }

    $script:LogEntries.Clear()
    Write-VmMediaHostDiag -VmName 'SQL2' -IsoPath $isoPath -Context SQL -Phase 4
    $hostDiagnostics = @($script:LogEntries | Where-Object { $_.Message -like '*[SQL media host diag]*' })
    Assert-SqlMediaEqual $true ($hostDiagnostics.Count -ge 3) 'Host diagnostics emitted measured VM, DVD, and ISO evidence'
    Assert-SqlMediaEqual 0 @($hostDiagnostics | Where-Object { -not $_.LogOnly }).Count 'Host diagnostics are log-only'
    Assert-SqlMediaEqual $hostDiagnostics.Count @($hostDiagnostics | Where-Object Warning).Count 'Host diagnostics retain warning severity in the log'

    . ([scriptblock]::Create($mountPhaseAst[0].Extent.Text))
    $script:PhaseIsoPath = $isoPath
    $script:PhaseProbeCall = 0
    $script:PhaseRecheckVisible = $true
    $script:PhaseResetResult = $true
    function Get-SqlVMNamesNeedingReplication {
        param([object]$deployConfig)
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        return , $set
    }
    function Get-SqlIsoPathForVm { param([object]$VirtualMachine) return $script:PhaseIsoPath }
    function Mount-IsoOnVm {
        param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase, [switch]$RepresentIfAttached)
        return $true
    }
    function Confirm-IsoVisibleInGuest {
        param([string]$VmName, [string]$VmDomainName, [string]$MarkerRelativePath, [string]$Context, [int]$Phase, [int]$TimeoutSeconds, [hashtable]$Diagnostics)
        $script:PhaseProbeCall++
        if ($script:PhaseProbeCall -eq 1) {
            $Diagnostics['Answered'] = 1
            $Diagnostics['Attempts'] = 1
            $Diagnostics['Reason'] = 'marker-absent'
            return $false
        }
        if ($script:PhaseRecheckVisible) {
            $Diagnostics['Root'] = 'S:'
            return $true
        }
        $Diagnostics['Reason'] = 'marker-absent'
        return $false
    }
    function Reset-AllDvdDrivesOnVm {
        param([string]$VmName, [string]$RequiredIsoPath, [string]$Context, [int]$Phase)
        return $script:PhaseResetResult
    }
    function Write-VmMediaHostDiag { param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase) }

    $phaseConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'test.lab' }
        virtualMachines = @([pscustomobject]@{ vmName = 'SQL4'; sqlVersion = '2022'; hidden = $false; Domain = 'test.lab' })
    }
    foreach ($phaseCase in @(
            [pscustomobject]@{ Name = 'complete visible'; Reset = $true; Visible = $true; Pattern = '*SQL media recovered at S:*'; Failure = $false }
            [pscustomobject]@{ Name = 'complete missing'; Reset = $true; Visible = $false; Pattern = '*SQL media is still not visible after a clean DVD device rebuild*'; Failure = $false }
            [pscustomobject]@{ Name = 'partial visible'; Reset = $false; Visible = $true; Pattern = '*SQL media is visible at S:*, but the DVD rebuild did not restore*'; Failure = $true }
            [pscustomobject]@{ Name = 'partial missing'; Reset = $false; Visible = $false; Pattern = '*SQL media is still not visible and the DVD rebuild did not restore*'; Failure = $true }
        )) {
        $script:PhaseProbeCall = 0
        $script:PhaseResetResult = $phaseCase.Reset
        $script:PhaseRecheckVisible = $phaseCase.Visible
        $script:LogEntries.Clear()
        $phaseMountResult = Mount-SqlIsoForPhase -deployConfig $phaseConfig
        $consoleEntries = @($script:LogEntries | Where-Object { -not $_.LogOnly })
        Assert-SqlMediaEqual 1 $consoleEntries.Count "$($phaseCase.Name) emits one concise console outcome"
        Assert-SqlMediaEqual $true ($consoleEntries[0].Message -like $phaseCase.Pattern) "$($phaseCase.Name) emits the expected outcome"
        Assert-SqlMediaEqual $phaseCase.Failure $consoleEntries[0].Failure "$($phaseCase.Name) uses the expected failure severity"
        Assert-SqlMediaEqual (-not $phaseCase.Failure) $phaseMountResult "$($phaseCase.Name) returns the aggregate Phase 4 mount verdict"
    }

    $phaseSource = Get-Content -LiteralPath $phasePath -Raw
    Assert-SqlMediaEqual $true ($phaseSource -match '(?s)if \(\$Phase -eq 4\) \{\s*if \(-not \(Mount-SqlIsoForPhase.+?return \$false\s*\}') 'Start-Phase aborts before worker dispatch when SQL media preparation fails'
}
finally {
    Remove-Item -LiteralPath $isoPath, $siblingIsoPath -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) { throw "$script:Failures SQL media mount recovery assertion(s) failed." }
Write-Host 'PASS  SQL media mount recovery regression suite'