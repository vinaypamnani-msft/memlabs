<#
.SYNOPSIS
    Verifies expansion maintenance coverage receipts and fail-closed runner gates.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
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
    param([string]$Name)
    $path = Join-Path $PSScriptRoot 'Invoke-MainToDevelopExpansionTest.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    $found = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($found.Count -ne 1) { throw "Expected one runner definition $Name." }
    return [scriptblock]::Create($found[0].Extent.Text)
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
    param([string]$Mode = 'Recovery', [object[]]$Targets = @($target), [bool]$HasCm = $true)
    [pscustomobject]@{
        SchemaVersion = 1; Mode = $Mode; Status = 'Passed'; MainRevision = $mainCommit; DevelopRevision = $developCommit
        Source = [pscustomobject]@{
            Digest = $digest; Commit = $developCommit; Dirty = $false
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
    $script:BadChildReceipt = $false
    $script:MockRole = 'Primary'
    function Save-State {}
    function Start-Step { param($Step) $script:State.CurrentStep = $Step }
    function Complete-Step { param($Step) $script:State.CompletedSteps += $Step; $script:State.CurrentStep = $null }
    function Get-VM {
        param($Name, $ErrorAction)
        [void]$ErrorAction
        [pscustomobject]@{
            Name = $Name; Id = $target.Id
            Notes = (@{ domain = 'lab.test'; role = $script:MockRole; parentSiteCode = '' } | ConvertTo-Json -Compress)
        }
    }
    function Invoke-ChildScript {
        param($WorktreePath, $ScriptName, $Parameters, $Label)
        [void]$WorktreePath; [void]$Label
        Assert-Qualification ($ScriptName -eq 'tools\Invoke-MaintenanceQualification.ps1' -and $Parameters.RequireCleanSource) 'The gate did not invoke the pinned clean-source qualifier.'
        $script:ChildCalls++
        $targets = Get-Content -LiteralPath $Parameters.TargetsPath -Raw | ConvertFrom-Json
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
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS -- Pinned maintenance receipts, identity/source validation, N/A coverage, resume migration and cleanup gates.'
