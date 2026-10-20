<#
.SYNOPSIS
    Verifies expansion maintenance coverage receipts and fail-closed runner gates.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'Common.MaintenanceQualification.ps1')
function Assert-Qualification {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-QualificationThrows {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Qualification ($message -like $Pattern) "Expected '$Pattern', got '$message'."
}
function Import-QualificationRunnerFunction {
    param([string]$Name, [string]$ScriptName = 'Invoke-MainToDevelopExpansionTest.ps1')
    $path = Join-Path $PSScriptRoot $ScriptName
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    $found = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($found.Count -ne 1) { throw "Expected one runner definition $Name." }
    $scriptRoot = (Split-Path $path -Parent).Replace("'", "''")
    return [scriptblock]::Create($found[0].Extent.Text.Replace('$PSScriptRoot', "'$scriptRoot'"))
}
foreach ($name in @('Initialize-CrossRevisionMaintenanceState', 'Get-CrossRevisionMaintenanceTargets',
        'Invoke-CrossRevisionMaintenanceGate', 'Invoke-CrossRevisionRecoveryGate', 'Resume-CrossRevisionMaintenanceGate',
        'Assert-CrossRevisionMaintenanceFamilyGate')) {
    . (Import-QualificationRunnerFunction $name)
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-qualification-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $tempRoot -ItemType Directory
$mainCommit = 'b' * 40
$developCommit = 'a' * 40
$digest = 'C' * 64
$target = [pscustomobject]@{ Name = 'LAB-PRI'; Id = '11111111-1111-1111-1111-111111111111'; Domain = 'lab.test' }
function New-TestQualificationReceipt {
    param([string]$Mode = 'Recovery', [object[]]$Targets = @($target), [bool]$HasCm = $true, [string]$Revision = $developCommit)
    [pscustomobject]@{
        SchemaVersion = 1; Mode = $Mode; Status = 'Passed'; MainRevision = $mainCommit; DevelopRevision = $Revision
        Source = [pscustomobject]@{
            Digest = $digest; Commit = $Revision; Dirty = $false
            Files = [pscustomobject]@{ 'DSC\DSC.zip' = ('D' * 64); 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1' = ('E' * 64) }
        }
        Targets = @($Targets | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Domain = $_.Domain } })
        HasCmTarget = $HasCm; RunId = ('f' * 32)
        Cases = @(Get-MaintenanceQualificationCases $Mode | ForEach-Object { [pscustomobject]@{ Name = $_; Status = 'Passed'; Reason = '' } })
    }
}
try {
    $receiptName = "lab_maintenance_baseline_$developCommit.qualification.log"
    $longPrefix = Join-Path $tempRoot 'path-budget'
    $paddingLength = 227 - $longPrefix.Length - $receiptName.Length - 2
    Assert-Qualification ($paddingLength -gt 0 -and $paddingLength -lt 248) 'TEMP prefix cannot accommodate the qualification path-budget fixture.'
    $script:QualificationReceiptDirectory = Join-Path $longPrefix ('p' * $paddingLength)
    $longReceiptPath = Join-Path $script:QualificationReceiptDirectory $receiptName
    Assert-Qualification ($longReceiptPath.Length -eq 227 -and
        "$longReceiptPath.$('0' * 32).tmp".Length -eq 264) 'The receipt fixture does not reproduce the reported path-length boundary.'
    $script:QualificationTemporaryPaths = [Collections.Generic.List[string]]::new()
    $script:QualificationMoveFailure = $false
    function Set-Content {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)]$Value, [string]$LiteralPath, [string]$Encoding)
        process {
            Assert-Qualification ($LiteralPath.Length -lt 260) "Atomic qualification temporary path is $($LiteralPath.Length) characters; legacy Windows requires fewer than 260."
            Assert-Qualification ((Split-Path $LiteralPath -Parent) -eq $script:QualificationReceiptDirectory -and
                $LiteralPath -ne $longReceiptPath) 'The receipt was not staged separately in its destination directory.'
            $script:QualificationTemporaryPaths.Add($LiteralPath)
            Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding -ErrorAction Stop
        }
    }
    function Move-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($script:QualificationMoveFailure) { throw 'Synthetic atomic receipt move failure.' }
        Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
    }
    try {
        $longReceipt = New-TestQualificationReceipt
        Write-MaintenanceQualificationReceipt $longReceiptPath $longReceipt
        $null = Assert-MaintenanceQualificationReceipt -Path $longReceiptPath -Mode Recovery -MainRevision $mainCommit `
            -DevelopRevision $developCommit -SourceDigest $digest -Targets @($target) -RequireCmCoverage
        $longReceipt.RunId = 'e' * 32
        Write-MaintenanceQualificationReceipt $longReceiptPath $longReceipt
        Assert-Qualification ((Get-Content -LiteralPath $longReceiptPath -Raw | ConvertFrom-Json).RunId -eq ('e' * 32)) 'Atomic replacement did not update the long-path receipt.'
        $beforeFailure = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $longReceiptPath -Algorithm SHA256).Hash
        $script:QualificationMoveFailure = $true
        $longReceipt.RunId = '0' * 32
        Assert-QualificationThrows { Write-MaintenanceQualificationReceipt $longReceiptPath $longReceipt } '*Synthetic atomic receipt move failure*'
        Assert-Qualification ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $longReceiptPath -Algorithm SHA256).Hash -eq $beforeFailure) 'A failed atomic replacement changed the previous receipt.'
        Assert-Qualification ($script:QualificationTemporaryPaths.Count -eq 3 -and
            @($script:QualificationTemporaryPaths | Select-Object -Unique).Count -eq 3) 'Receipt writes reused a staging path.'
        $remaining = @(Get-ChildItem -LiteralPath $script:QualificationReceiptDirectory -File -Force)
        Assert-Qualification ($remaining.Count -eq 1 -and $remaining[0].FullName -eq $longReceiptPath) 'Receipt staging files survived success or failure cleanup.'
    }
    finally {
        Remove-Item -LiteralPath Function:\Set-Content -Force
        Remove-Item -LiteralPath Function:\Move-Item -Force
    }

    $path = Join-Path $tempRoot 'receipt.json'
    $receipt = New-TestQualificationReceipt
    Write-MaintenanceQualificationReceipt $path $receipt
    $arguments = @{
        Path = $path; Mode = 'Recovery'; MainRevision = $mainCommit; DevelopRevision = $developCommit
        SourceDigest = $digest; Targets = @($target); RequireCmCoverage = $true
    }
    $null = Assert-MaintenanceQualificationReceipt @arguments
    foreach ($mutation in @(
            @{ Name = 'failed'; Change = { param($r) $r.Status = 'Failed' }; Error = '*did not pass*' },
            @{ Name = 'dirty'; Change = { param($r) $r.Source.Dirty = $true }; Error = '*clean pinned source*' },
            @{ Name = 'stale'; Change = { param($r) $r.DevelopRevision = ('0' * 40) }; Error = '*another contract*' },
            @{ Name = 'target'; Change = { param($r) $r.Targets[0].Id = [guid]::NewGuid().ToString() }; Error = '*target identity differs*' },
            @{ Name = 'missing'; Change = { param($r) $r.Cases = @($r.Cases | Select-Object -Skip 1) }; Error = '*missing or duplicate*' },
            @{ Name = 'duplicate'; Change = { param($r) $r.Cases[-1].Name = $r.Cases[0].Name }; Error = '*missing or duplicate*' },
            @{ Name = 'skip'; Change = { param($r) $r.Cases[0].Status = 'NotApplicable'; $r.Cases[0].Reason = 'not run' }; Error = '*improperly skipped*' },
            @{ Name = 'coverageflag'; Change = { param($r) $r.HasCmTarget = 'true' }; Error = '*invalid CM coverage flag*' },
            @{ Name = 'modulehash'; Change = { param($r) $r.Source.Files.'DSC\DSC.zip' = '' }; Error = '*omits the shipped*' }
        )) {
        $receipt = New-TestQualificationReceipt
        & $mutation.Change $receipt
        Write-MaintenanceQualificationReceipt $path $receipt
        Assert-QualificationThrows { Assert-MaintenanceQualificationReceipt @arguments } $mutation.Error
    }
    $receipt = New-TestQualificationReceipt -HasCm $false
    foreach ($case in $receipt.Cases) { $case.Status = 'NotApplicable'; $case.Reason = 'No eligible CM target.' }
    Write-MaintenanceQualificationReceipt $path $receipt
    $noCmArguments = @{}; foreach ($key in $arguments.Keys) { $noCmArguments[$key] = $arguments[$key] }
    $noCmArguments.RequireCmCoverage = $false
    $null = Assert-MaintenanceQualificationReceipt @noCmArguments
    Assert-QualificationThrows { Assert-MaintenanceQualificationReceipt @arguments } '*did not exercise a CM target*'
    $receipt = New-TestQualificationReceipt
    Write-MaintenanceQualificationReceipt $path $receipt
    $reference = New-MaintenanceQualificationReference $path $receipt
    $null = Assert-MaintenanceQualificationReference $reference -RequireCmCoverage
    $checksum = $reference.Sha256
    $reference.Sha256 = ''
    Assert-QualificationThrows { Assert-MaintenanceQualificationReference $reference } '*no valid receipt checksum*'
    $reference.Sha256 = $checksum
    Add-Content -LiteralPath $path -Value ' '
    Assert-QualificationThrows { Assert-MaintenanceQualificationReference $reference } '*checksum changed*'

    $readinessCases = @('Test-WindowsClientSetupReadiness-PS7', 'Test-WindowsClientSetupReadiness-PS51')
    $consoleCases = @('Test-VmConsoleScreenshot-PS7', 'Test-VmConsoleScreenshot-PS51')
    foreach ($name in @($readinessCases + $consoleCases + 'Test-CimProxyTempPath' + 'Test-SetupDiagnosticDefaults')) {
        Assert-Qualification ((Get-MaintenanceQualificationCases Preflight) -contains $name) "Preflight does not require $name."
        $receipt = New-TestQualificationReceipt -Mode Preflight -Targets @() -HasCm $false
        $receipt.Cases = @($receipt.Cases | Where-Object Name -ne $name)
        Write-MaintenanceQualificationReceipt $path $receipt
        Assert-QualificationThrows {
            Assert-MaintenanceQualificationReceipt -Path $path -Mode Preflight -MainRevision $mainCommit `
                -DevelopRevision $developCommit -SourceDigest $digest
        } '*missing or duplicate*'
    }
    $source = Get-MaintenanceQualificationSource -VmbuildRoot $RootPath
    foreach ($relative in @('Common.ps1', 'common\Common.ScriptBlocks.ps1', 'DSC\phases\WindowsSetupReadiness.ps1',
            'DSC\phases\Phase2DomainMember.ps1', 'DSC\phases\Phase2WorkgroupMember.ps1',
            'tools\Test-WindowsClientSetupReadiness.ps1', 'tools\Test-CimProxyTempPath.ps1',
            'tools\Clear-CimProxyTempFolders.ps1', 'tools\Test-SetupDiagnosticDefaults.ps1',
            'tools\Get-WindowsVmSetupDiagnostics.ps1', 'tools\Common.VmConsoleScreenshot.ps1',
            'tools\Test-VmConsoleScreenshot.ps1')) {
        Assert-Qualification ($source.Files.Contains($relative) -and $source.Files[$relative] -match '^[A-Fa-f0-9]{64}$') `
            "Pinned source digest does not cover regression input $relative."
    }
    & {
        $script:TrackingQueries = 0
        function git {
            $global:LASTEXITCODE = 0
            if ($args -contains 'rev-parse') { return $source.Commit }
            if ($args -contains 'status') { return }
            if ($args -contains 'ls-files') {
                $script:TrackingQueries++
                Assert-Qualification ($args -notcontains '--error-unmatch') 'Untracked candidate files must not become a native stderr failure on Windows PowerShell 5.1.'
                foreach ($relative in @($source.Files.Keys | Select-Object -Skip 1)) { "vmbuild\$relative" }
                return
            }
            throw "Unexpected source-inspection git command: $args"
        }
        $untrackedSource = Get-MaintenanceQualificationSource -VmbuildRoot $RootPath
        Assert-Qualification ($script:TrackingQueries -eq 1 -and $untrackedSource.Dirty -and $untrackedSource.Digest -eq $source.Digest -and
            $untrackedSource.Files.Count -eq $source.Files.Count) 'A missing tracked source file was accepted as clean or lost its source fingerprint.'
    }
    & {
        $root = Join-Path $tempRoot 'preflight'
        $null = New-Item -Path (Join-Path $root 'common') -ItemType Directory -Force
        @'
function Get-MemLabsDscArtifactState {
    param($DscRoot)
    [pscustomobject]@{ Current = $script:PreflightScenario -ne 'StaleArtifact'; Reason = 'Synthetic DSC state'; Root = $DscRoot }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'common\Common.Prereqs.ps1') -Encoding UTF8
        foreach ($name in @('Add-MQCase', 'Invoke-MQPreflight')) {
            . (Import-QualificationRunnerFunction -Name $name -ScriptName 'Invoke-MaintenanceQualification.ps1')
        }
        $ReceiptPath = Join-Path $root 'receipt.json'
        function Join-Path {
            param([string]$Path, [string]$ChildPath)
            if ($ChildPath -eq 'System32\WindowsPowerShell\v1.0\powershell.exe') { return 'Invoke-QualificationEngine51' }
            Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
        }
        function Test-Path {
            param([string]$LiteralPath, [string]$PathType)
            if ($LiteralPath -eq 'Invoke-QualificationEngine51') { return $script:PreflightScenario -ne 'MissingPS51' }
            Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        function Get-Command {
            param($Name, $CommandType, $ErrorAction)
            Assert-Qualification ($Name -eq 'pwsh.exe' -and $CommandType -eq 'Application') 'Preflight did not resolve the PowerShell 7 application.'
            if ($script:PreflightScenario -eq 'MissingPS7') { throw 'Synthetic missing PowerShell 7.' }
            [pscustomobject]@{ Source = 'Invoke-QualificationEngine7' }
        }
        function Invoke-QualificationEngine7 {
            param([string]$File)
            Assert-Qualification (Test-Path -LiteralPath $File -PathType Leaf) "Preflight selected a missing script: $File"
            $scriptName = Split-Path $File -Leaf
            $script:PreflightCalls.Add([pscustomobject]@{ Engine = 'PS7'; Script = $scriptName })
            $global:LASTEXITCODE = if ($script:PreflightScenario -eq 'FailPS7' -or
                ($script:PreflightScenario -eq 'FailConsolePS7' -and $scriptName -eq 'Test-VmConsoleScreenshot.ps1')) { 37 } else { 0 }
        }
        function Invoke-QualificationEngine51 {
            param([string]$File)
            Assert-Qualification (Test-Path -LiteralPath $File -PathType Leaf) "Preflight selected a missing script: $File"
            $scriptName = Split-Path $File -Leaf
            $script:PreflightCalls.Add([pscustomobject]@{ Engine = 'PS51'; Script = $scriptName })
            $global:LASTEXITCODE = if ($script:PreflightScenario -eq 'FailPS51' -or
                ($script:PreflightScenario -eq 'FailConsolePS51' -and $scriptName -eq 'Test-VmConsoleScreenshot.ps1')) { 37 } else { 0 }
        }
        foreach ($scenario in @('Passed', 'FailPS7', 'FailPS51', 'FailConsolePS7', 'FailConsolePS51', 'MissingPS7', 'MissingPS51', 'StaleArtifact')) {
            $script:PreflightScenario = $scenario
            $script:PreflightCalls = [Collections.Generic.List[object]]::new()
            $script:MQReceipt = New-TestQualificationReceipt -Mode Preflight -Targets @() -HasCm $false
            $script:MQReceipt.Status = 'Running'
            $script:MQReceipt.Cases = @()
            if ($scenario -eq 'Passed') {
                Invoke-MQPreflight
                $readinessCalls = @($script:PreflightCalls | Where-Object Script -eq 'Test-WindowsClientSetupReadiness.ps1')
                Assert-Qualification ($readinessCalls.Count -eq 2 -and
                    ($readinessCalls.Engine -join ',') -eq 'PS7,PS51') 'Readiness preflight did not run the same script under both engines.'
                $consoleCalls = @($script:PreflightCalls | Where-Object Script -eq 'Test-VmConsoleScreenshot.ps1')
                Assert-Qualification ($consoleCalls.Count -eq 2 -and
                    ($consoleCalls.Engine -join ',') -eq 'PS7,PS51') 'Console preflight did not run the same script under both engines.'
                Assert-Qualification ($script:PreflightCalls.Count -eq (Get-MaintenanceQualificationCases Preflight).Count - 1) `
                    'Preflight skipped or duplicated a regression invocation.'
                foreach ($entry in @(
                        @{ Name = $readinessCases[0]; Engine = 'Invoke-QualificationEngine7'; Script = 'Test-WindowsClientSetupReadiness.ps1' },
                        @{ Name = $readinessCases[1]; Engine = 'Invoke-QualificationEngine51'; Script = 'Test-WindowsClientSetupReadiness.ps1' },
                        @{ Name = $consoleCases[0]; Engine = 'Invoke-QualificationEngine7'; Script = 'Test-VmConsoleScreenshot.ps1' },
                        @{ Name = $consoleCases[1]; Engine = 'Invoke-QualificationEngine51'; Script = 'Test-VmConsoleScreenshot.ps1' }
                    )) {
                    $case = @($script:MQReceipt.Cases | Where-Object Name -eq $entry.Name)
                    Assert-Qualification ($case.Count -eq 1 -and $case[0].Status -eq 'Passed' -and
                        $case[0].Data.Engine -eq $entry.Engine -and $case[0].Data.ExitCode -eq 0 -and
                        $case[0].Data.Script -eq $entry.Script) 'Preflight receipt lost per-engine readiness or console evidence.'
                }
                $script:MQReceipt.Status = 'Passed'
                Write-MaintenanceQualificationReceipt $ReceiptPath $script:MQReceipt
                $null = Assert-MaintenanceQualificationReceipt -Path $ReceiptPath -Mode Preflight -MainRevision $mainCommit `
                    -DevelopRevision $developCommit -SourceDigest $digest
            }
            else {
                $pattern = switch ($scenario) {
                    'FailPS7' { '*Test-WindowsClientSetupReadiness-PS7 (exit 37)*' }
                    'FailPS51' { '*Test-WindowsClientSetupReadiness-PS51 (exit 37)*' }
                    'FailConsolePS7' { '*Test-VmConsoleScreenshot-PS7 (exit 37)*' }
                    'FailConsolePS51' { '*Test-VmConsoleScreenshot-PS51 (exit 37)*' }
                    'MissingPS7' { '*Synthetic missing PowerShell 7*' }
                    'MissingPS51' { '*Windows PowerShell 5.1 is required*' }
                    'StaleArtifact' { '*Candidate DSC artifact is stale*' }
                }
                Assert-QualificationThrows { Invoke-MQPreflight } $pattern
                $passedReadiness = @($script:MQReceipt.Cases | Where-Object { $_.Name -in $readinessCases })
                $passedConsole = @($script:MQReceipt.Cases | Where-Object { $_.Name -in $consoleCases })
                $expectedPassed = if ($scenario -eq 'FailPS51') { 1 } elseif ($scenario -in @('FailConsolePS7', 'FailConsolePS51')) { 2 } else { 0 }
                $expectedConsolePassed = if ($scenario -eq 'FailConsolePS51') { 1 } else { 0 }
                $expectedCalls = switch ($scenario) {
                    'FailPS7' { 1 }
                    'FailPS51' { 2 }
                    'FailConsolePS7' { 3 }
                    'FailConsolePS51' { 4 }
                    default { 0 }
                }
                Assert-Qualification ($passedReadiness.Count -eq $expectedPassed -and $passedConsole.Count -eq $expectedConsolePassed -and
                    $script:PreflightCalls.Count -eq $expectedCalls -and $script:MQReceipt.Status -eq 'Running') `
                    "$scenario continued after a failed/missing engine or recorded unearned readiness/console coverage."
            }
        }
    }

    Assert-Qualification (Test-MaintenanceQualificationCmScope ([pscustomobject]@{ virtualMachines = @([pscustomobject]@{ role = 'CAS' }) })) 'CAS recovery target was not recognized.'
    Assert-Qualification (-not (Test-MaintenanceQualificationCmScope ([pscustomobject]@{ virtualMachines = @([pscustomobject]@{ role = 'Primary'; parentSiteCode = 'CAS' }) }))) 'A child Primary was misclassified as a Full Administrator qualification target.'
    $old = [ordered]@{ CompletedSteps = @('lab|main|A'); CurrentStep = $null }
    Initialize-CrossRevisionMaintenanceState $old
    Assert-Qualification ($old.MaintenanceContractVersion -eq 1) 'A safe unexpanded baseline did not migrate.'
    foreach ($step in @('lab|develop|1|B.json', 'lab|cleanup|lab.test', 'lab|complete')) {
        $old = [ordered]@{ CompletedSteps = @('lab|main|A', $step); CurrentStep = $null }
        Assert-QualificationThrows { Initialize-CrossRevisionMaintenanceState $old } '*predates mandatory maintenance coverage*'
    }

    $RepositoryRoot = Join-Path $tempRoot 'repository'
    $StateRoot = Join-Path $tempRoot 'state'
    $null = New-Item -Path (Join-Path $RepositoryRoot 'vmbuild\logs') -ItemType Directory -Force
    $script:MaintenanceCandidateSource = [pscustomobject]@{ Digest = $digest }
    $script:State = [ordered]@{ CompletedSteps = @(); CurrentStep = $null; MaintenanceReceipts = @{}; MaintenanceFamilyGates = @{} }
    $script:ChildCalls = 0
    $script:ReadiedTargets = 0
    $script:BadChildReceipt = $false
    $script:MockRole = 'Primary'
    function Save-State {}
    function Start-Step { param($Step) $script:State.CurrentStep = $Step }
    function Complete-Step { param($Step) $script:State.CompletedSteps += $Step; $script:State.CurrentStep = $null }
    function Wait-CrossRevisionRetainedVmReady {
        param($Target, $AdminCachePath)
        Assert-Qualification ($Target.Name -eq 'LAB-PRI' -and $Target.Id -eq '11111111-1111-1111-1111-111111111111') 'Maintenance readiness selected a VM outside the validated target scope.'
        $script:ReadiedTargets++
    }
    function Get-VM {
        param($Name, $ErrorAction)
        [void]$ErrorAction
        [pscustomobject]@{
            Name = $Name; Id = $target.Id; State = 'Running'
            Notes = (@{ domain = 'lab.test'; role = $script:MockRole; parentSiteCode = '' } | ConvertTo-Json -Compress)
        }
    }
    function Invoke-ChildScript {
        param($WorktreePath, $ScriptName, $Parameters, $Label)
        [void]$WorktreePath; [void]$Label
        Assert-Qualification ($ScriptName -eq 'tools\Invoke-MaintenanceQualification.ps1' -and $Parameters.RequireCleanSource) 'The gate did not invoke the pinned clean-source qualifier.'
        $script:ChildCalls++
        $targets = Get-Content -LiteralPath $Parameters.TargetsPath -Raw | ConvertFrom-Json
        Assert-Qualification ($script:ReadiedTargets -eq @($targets).Count) 'Maintenance invoked the child before preparing every scoped target.'
        $script:ReadiedTargets = 0
        $receipt = New-TestQualificationReceipt -Mode $Parameters.Mode -Targets @($targets) -HasCm ($script:MockRole -eq 'Primary')
        if ($Parameters.Mode -eq 'Recovery' -and $script:MockRole -ne 'Primary') {
            foreach ($case in $receipt.Cases) { $case.Status = 'NotApplicable'; $case.Reason = 'No CM target.' }
        }
        if ($script:BadChildReceipt) { $receipt.Cases = @() }
        Write-MaintenanceQualificationReceipt $Parameters.ReceiptPath $receipt
        return 0
    }
    $key = "lab|maintenance|baseline|$developCommit"
    $null = Invoke-CrossRevisionMaintenanceGate -Key $key -Mode Baseline -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned' -AdminCachePath 'C:\cache\admin.txt'
    $null = Invoke-CrossRevisionMaintenanceGate -Key $key -Mode Baseline -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned'
    Assert-Qualification ($script:ChildCalls -eq 1 -and $script:State.CompletedSteps -contains $key) 'A validated baseline gate was rerun or not checkpointed.'
    $script:BadChildReceipt = $true
    $badKey = "lab|maintenance|post|1|B.json|$developCommit"
    Assert-QualificationThrows {
        Invoke-CrossRevisionMaintenanceGate -Key $badKey -Mode Postconditions -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned'
    } '*missing or duplicate*'
    Assert-Qualification ($script:State.CompletedSteps -notcontains $badKey -and -not $script:State.MaintenanceReceipts.Contains($badKey)) 'A zero exit code bypassed an incomplete coverage receipt.'
    Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } '*no maintenance completion gate*'
    $script:BadChildReceipt = $false
    $beforeCalls = $script:ChildCalls
    $recoveryKey = Invoke-CrossRevisionRecoveryGate -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned'
    $null = Invoke-CrossRevisionRecoveryGate -Family 'next' -Identity @($target) -WorktreePath 'C:\pinned'
    Assert-Qualification ($script:ChildCalls -eq $beforeCalls + 1 -and $recoveryKey -like '__revision__|maintenance|recovery|*') 'The CM fault matrix did not run exactly once per candidate.'
    $script:MockRole = 'DC'
    $naKey = Invoke-CrossRevisionRecoveryGate -Family 'nocm' -Identity @($target) -WorktreePath 'C:\pinned'
    Assert-Qualification ($naKey -like 'nocm|maintenance|recovery-na|*' -and -not $script:State.MaintenanceReceipts[$naKey].HasCmTarget) 'NOCM incorrectly qualified CM recovery coverage.'
    $script:MockRole = 'Primary'

    $preflightKey = "__revision__|maintenance|preflight|$developCommit"
    $postKeys = @("lab|maintenance|post|1|B.json|$developCommit", "lab|maintenance|post|2|B.json|$developCommit", "lab|maintenance|final|$developCommit")
    foreach ($entry in @(@{ Key = $preflightKey; Mode = 'Preflight' }) + @($postKeys | ForEach-Object { @{ Key = $_; Mode = 'Postconditions' } })) {
        $file = Join-Path $tempRoot "$($entry.Key -replace '[^A-Za-z0-9_.-]', '_').json"
        $receipt = New-TestQualificationReceipt -Mode $entry.Mode
        Write-MaintenanceQualificationReceipt $file $receipt
        $script:State.MaintenanceReceipts[$entry.Key] = New-MaintenanceQualificationReference $file $receipt
    }
    $script:State.MaintenanceFamilyGates['lab'] = [ordered]@{
        DevelopRevision = $developCommit; SourceDigest = $digest; FollowOns = @('B.json'); HasCmTarget = $true
        PreflightKey = $preflightKey; BaselineKey = $key; RecoveryKey = $recoveryKey; PostconditionKeys = $postKeys
    }
    Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab'
    $script:State.MaintenanceFamilyGates.lab.PostconditionKeys = @($postKeys | Select-Object -Skip 1)
    Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } '*incomplete maintenance gate*'
    $script:State.MaintenanceFamilyGates.lab.PostconditionKeys = $postKeys
    $goodPreflight = $script:State.MaintenanceReceipts[$preflightKey]
    $script:State.MaintenanceReceipts[$preflightKey] = $script:State.MaintenanceReceipts[$key]
    Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } '*wrong-mode*'
    $script:State.MaintenanceReceipts[$preflightKey] = $goodPreflight

    & {
        $RepositoryRoot = Join-Path $tempRoot 'contract-history'
        $contractPath = Join-Path $RepositoryRoot 'vmbuild\tools\Common.MaintenanceQualification.ps1'
        $null = New-Item -Path (Split-Path $contractPath -Parent) -ItemType Directory -Force
        & git -C $RepositoryRoot init -q
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the historical contract fixture.' }
        function New-TestCaseContractCommit {
            param([string]$Source)
            [IO.File]::WriteAllText($contractPath, $Source)
            & git -C $RepositoryRoot -c core.autocrlf=false add -- 'vmbuild\tools\Common.MaintenanceQualification.ps1'
            if ($LASTEXITCODE -ne 0) { throw 'Could not stage the historical contract fixture.' }
            & git -C $RepositoryRoot -c user.name=MemLabsTest -c user.email=memlabs-test@example.invalid `
                -c commit.gpgsign=false -c "core.hooksPath=$RepositoryRoot\no-hooks" commit -q `
                -m 'Qualification contract fixture' -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the historical contract fixture.' }
            $revision = @(& git -C $RepositoryRoot rev-parse HEAD)
            if ($LASTEXITCODE -ne 0 -or $revision.Count -ne 1) { throw 'Could not resolve the historical contract fixture.' }
            return "$($revision[0])"
        }
        $legacyCases = @('Test-ConsoleUpgradeRouting', 'Test-MaintenanceFixRobustness', 'Test-Odbc18VersionEnforcement',
            'Test-MsiBusyRetryAndPassiveDependency', 'Test-VMMaintenanceNoteDiagnostics', 'Test-Phase11OsdContentState',
            'Test-MaintenanceQualification', 'Test-MainToDevelopExpansionRunner', 'dsc-artifact')
        $otherModes = foreach ($mode in @('Baseline', 'Postconditions', 'Recovery')) {
            $names = @(Get-MaintenanceQualificationCases $mode | ForEach-Object { "'$_'" }) -join ', '
            "'$mode' { return @($names) }"
        }
        $template = @'
throw 'Historical qualifier source must never execute.'
function Get-MaintenanceQualificationCases {
    param([string]$Mode)
    switch ($Mode) {
        'Preflight' { return @(__PREFLIGHT__) }
        __OTHER_MODES__
    }
}
'@
        $template = $template.Replace('__OTHER_MODES__', ($otherModes -join "`n"))
        $legacySource = $template.Replace('__PREFLIGHT__', (($legacyCases | ForEach-Object { "'$_'" }) -join ', '))
        $legacyRevision = New-TestCaseContractCommit $legacySource
        $currentSource = $template.Replace('__PREFLIGHT__', ((Get-MaintenanceQualificationCases Preflight | ForEach-Object { "'$_'" }) -join ', '))
        $developCommit = New-TestCaseContractCommit $currentSource
        [IO.File]::WriteAllText($contractPath, 'throw "The mutable checkout is not a pinned contract."')
        foreach ($mode in @('Preflight', 'Baseline', 'Postconditions', 'Recovery')) {
            $expectedCases = if ($mode -eq 'Preflight') { $legacyCases } else { @(Get-MaintenanceQualificationCases $mode) }
            $pinnedCases = @(Get-PinnedMaintenanceQualificationCases -RepositoryRoot $RepositoryRoot -Revision $legacyRevision -Mode $mode)
            Assert-Qualification (($pinnedCases -join ',') -ceq ($expectedCases -join ',')) "Historical $mode cases were taken from the current or mutable checkout."
        }
        $currentCases = @(Get-PinnedMaintenanceQualificationCases -RepositoryRoot $RepositoryRoot -Revision $developCommit -Mode Preflight)
        Assert-Qualification (($currentCases -join ',') -ceq ((Get-MaintenanceQualificationCases Preflight) -join ',')) 'The current pinned case contract lost required regressions.'
        Assert-QualificationThrows {
            Get-PinnedMaintenanceQualificationCases -RepositoryRoot $RepositoryRoot -Revision ('0' * 40) -Mode Preflight
        } '*Could not read pinned maintenance case contract*'

        $historicalPreflightKey = "__revision__|maintenance|preflight|$legacyRevision"
        $historicalBaselineKey = "lab|maintenance|baseline|$legacyRevision"
        $historicalRecoveryKey = "__revision__|maintenance|recovery|$legacyRevision"
        $historicalPostKeys = @("lab|maintenance|post|1|B.json|$legacyRevision", "lab|maintenance|post|2|B.json|$legacyRevision",
            "lab|maintenance|final|$legacyRevision")
        $previousState = $script:State
        try {
            $script:State = [ordered]@{ MaintenanceReceipts = @{}; MaintenanceFamilyGates = @{} }
            $script:State.MaintenanceFamilyGates.lab = [ordered]@{
                DevelopRevision = $legacyRevision; SourceDigest = $digest; FollowOns = @('B.json'); HasCmTarget = $true
                PreflightKey = $historicalPreflightKey; BaselineKey = $historicalBaselineKey
                RecoveryKey = $historicalRecoveryKey; PostconditionKeys = $historicalPostKeys
            }
            foreach ($entry in @(
                    @{ Key = $historicalPreflightKey; Mode = 'Preflight' },
                    @{ Key = $historicalBaselineKey; Mode = 'Baseline' },
                    @{ Key = $historicalRecoveryKey; Mode = 'Recovery' }
                ) + @($historicalPostKeys | ForEach-Object { @{ Key = $_; Mode = 'Postconditions' } })) {
                $file = Join-Path $tempRoot "$($entry.Key -replace '[^A-Za-z0-9_.-]', '_').json"
                $receipt = New-TestQualificationReceipt -Mode $entry.Mode -Revision $legacyRevision
                if ($entry.Mode -eq 'Preflight') {
                    $receipt.Targets = @()
                    $receipt.Cases = @($legacyCases | ForEach-Object { [pscustomobject]@{ Name = $_; Status = 'Passed'; Reason = '' } })
                    $historicalPreflight = $receipt
                    $historicalPreflightPath = $file
                }
                Write-MaintenanceQualificationReceipt $file $receipt
                $script:State.MaintenanceReceipts[$entry.Key] = New-MaintenanceQualificationReference $file $receipt
            }
            Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab'
            Add-Content -LiteralPath $historicalPreflightPath -Value ' '
            Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } '*checksum changed*'
            foreach ($mutation in @(
                    @{ Change = { param($r) $r.Cases = @($r.Cases | Select-Object -Skip 1) }; Error = "*candidate $legacyRevision*expected=9; actual=8; missing=[[]Test-ConsoleUpgradeRouting[]]*" },
                    @{ Change = { param($r) $r.Cases[-1].Name = $r.Cases[0].Name }; Error = '*duplicate=[[]Test-ConsoleUpgradeRouting[]]*' },
                    @{ Change = { param($r) $r.Cases[0].Name = 'Unrecognized-Case' }; Error = '*unexpected=[[]Unrecognized-Case[]]*' },
                    @{ Change = { param($r) $r.Cases[0].Status = 'Failed' }; Error = "*case 'Test-ConsoleUpgradeRouting' did not pass*" },
                    @{ Change = { param($r) $r.Source.Dirty = $true }; Error = '*clean pinned source*' }
                )) {
                $receipt = $historicalPreflight | ConvertTo-Json -Depth 12 | ConvertFrom-Json
                & $mutation.Change $receipt
                Write-MaintenanceQualificationReceipt $historicalPreflightPath $receipt
                $script:State.MaintenanceReceipts[$historicalPreflightKey] = New-MaintenanceQualificationReference $historicalPreflightPath $receipt
                Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } $mutation.Error
            }
            Write-MaintenanceQualificationReceipt $historicalPreflightPath $historicalPreflight
            $script:State.MaintenanceReceipts[$historicalPreflightKey] = New-MaintenanceQualificationReference $historicalPreflightPath $historicalPreflight
            Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab'
            $savedRepository = $RepositoryRoot
            $RepositoryRoot = ''
            Assert-QualificationThrows { Assert-CrossRevisionMaintenanceFamilyGate -Family 'lab' } '*requires its Git repository*'
            $RepositoryRoot = $savedRepository
        }
        finally { $script:State = $previousState }

        $currentPath = Join-Path $tempRoot 'current-preflight.json'
        $receipt = New-TestQualificationReceipt -Mode Preflight -Revision $developCommit -Targets @()
        $receipt.Cases = $historicalPreflight.Cases
        Write-MaintenanceQualificationReceipt $currentPath $receipt
        $reference = New-MaintenanceQualificationReference $currentPath $receipt
        foreach ($parameters in @(@{}, @{ RepositoryRoot = $RepositoryRoot })) {
            Assert-QualificationThrows { Assert-MaintenanceQualificationReference $reference @parameters } `
                "*candidate $developCommit*missing=[[]Test-WindowsClientSetupReadiness-PS7*"
        }
        $receipt = New-TestQualificationReceipt -Mode Preflight -Revision $developCommit -Targets @()
        Write-MaintenanceQualificationReceipt $currentPath $receipt
        $reference = New-MaintenanceQualificationReference $currentPath $receipt
        $null = Assert-MaintenanceQualificationReference $reference -RepositoryRoot $RepositoryRoot
        $dynamicRevision = New-TestCaseContractCommit ($template.Replace('__PREFLIGHT__', '(Write-Output ''forged-case'')'))
        Assert-QualificationThrows {
            Get-PinnedMaintenanceQualificationCases -RepositoryRoot $RepositoryRoot -Revision $dynamicRevision -Mode Preflight
        } '*not a literal Preflight case list*'
        $duplicateRevision = New-TestCaseContractCommit ($template.Replace('__PREFLIGHT__', "'duplicate', 'duplicate'"))
        Assert-QualificationThrows {
            Get-PinnedMaintenanceQualificationCases -RepositoryRoot $RepositoryRoot -Revision $duplicateRevision -Mode Preflight
        } '*invalid or duplicate Preflight cases*'
    }

    $pendingKey = "lab|maintenance|recovery|$developCommit"
    $script:State.CurrentStep = $pendingKey
    $beforeCalls = $script:ChildCalls
    Resume-CrossRevisionMaintenanceGate -WorktreePath 'C:\pinned' -AdminCachePath 'C:\cache\admin.txt'
    Assert-Qualification ($script:ChildCalls -eq $beforeCalls + 1 -and -not $script:State.CurrentStep) 'An interrupted matrix was not resumed with its original scoped identity before deployment.'
    $refreshKey = "lab|maintenance|post|2|refresh.json|$developCommit"
    $null = Invoke-CrossRevisionMaintenanceGate -Key $refreshKey -Mode Postconditions -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned'
    $script:BadChildReceipt = $true
    Assert-QualificationThrows {
        Invoke-CrossRevisionMaintenanceGate -Key $refreshKey -Mode Postconditions -Family 'lab' -Identity @($target) -WorktreePath 'C:\pinned' -AlwaysRun
    } '*missing or duplicate*'
    Assert-Qualification (-not $script:State.MaintenanceReceipts.Contains($refreshKey)) 'A failed refreshed postcondition retained a stale successful receipt reference.'
    $script:BadChildReceipt = $false
    Resume-CrossRevisionMaintenanceGate -WorktreePath 'C:\pinned'
    Assert-Qualification ($script:State.MaintenanceReceipts.Contains($refreshKey) -and -not $script:State.CurrentStep) 'An interrupted refreshed readiness check cannot resume after its receipt is replaced.'

    $runner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-MainToDevelopExpansionTest.ps1') -Raw
    Assert-Qualification ($runner -match '(?s)Assert-CrossRevisionMaintenanceFamilyGate -Family \$family\s+foreach \(\$domain in \$familyPlan.Domains\)') 'Cleanup is not guarded by maintenance qualification.'
    Assert-Qualification ($runner -match 'Mode Postconditions' -and $runner -match 'Mode Recovery' -and $runner -match 'Mode Preflight') 'A required runner qualification stage is missing.'
    $qualifier = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-MaintenanceQualification.ps1') -Raw
    $start = $qualifier.IndexOf("'SeedLegacy' {", [StringComparison]::Ordinal)
    $end = $qualifier.IndexOf("'LoseCurrent' {", $start, [StringComparison]::Ordinal)
    $seed = $qualifier.Substring($start, $end - $start)
    Assert-Qualification ([regex]::Matches($seed, 'foreach\s*\(\$code in \$related\)').Count -eq 1 -and
        $seed.Contains('$codes += "$code"')) 'The one-shot MSI RelatedProducts enumerator is reused instead of retaining product codes during its first traversal.'
}
finally {
    $global:LASTEXITCODE = $previousExitCode
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS -- Pinned historical/current case contracts, dual-engine preflight, receipt/source/identity integrity, N/A coverage, resume migration and cleanup gates.'
