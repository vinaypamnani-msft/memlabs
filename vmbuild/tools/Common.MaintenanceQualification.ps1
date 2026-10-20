function Get-MaintenanceQualificationCases {
    param([ValidateSet('Preflight', 'Baseline', 'Postconditions', 'Recovery')][string]$Mode)
    switch ($Mode) {
        'Preflight' {
            return @('Test-WindowsClientSetupReadiness-PS7', 'Test-WindowsClientSetupReadiness-PS51',
                'Test-VmConsoleScreenshot-PS7', 'Test-VmConsoleScreenshot-PS51',
                'Test-CimProxyTempPath', 'Test-SetupDiagnosticDefaults',
                'Test-ConsoleUpgradeRouting', 'Test-MaintenanceFixRobustness', 'Test-Odbc18VersionEnforcement',
                'Test-MsiBusyRetryAndPassiveDependency', 'Test-VMMaintenanceNoteDiagnostics', 'Test-Phase11OsdContentState',
                'Test-MaintenanceQualification', 'Test-MainToDevelopExpansionRunner', 'dsc-artifact')
        }
        'Baseline' { return @('existing-maintenance', 'independent-readiness', 'maintenance-idempotence', 'identity-preserved') }
        'Postconditions' { return @('independent-readiness', 'identity-preserved') }
        'Recovery' {
            return @('legacy-msi-source-cache-loss', 'current-msi-registration-cache-loss', 'legacy-console-config',
                'newer-console-preserved', 'administrator-assignment', 'retry-and-evidence', 'unverifiable-package-rejected', 'packaged-dsc-recovery')
        }
    }
}

function Test-MaintenanceQualificationCmScope {
    param([object]$Config)
    return @($Config.virtualMachines | Where-Object {
            $_.role -eq 'CAS' -or ($_.role -eq 'Primary' -and -not $_.parentSiteCode)
        }).Count -gt 0
}

function Get-MaintenanceQualificationSource {
    param([Parameter(Mandatory)][string]$VmbuildRoot)

    $repository = Split-Path $VmbuildRoot -Parent
    $commit = @(& git -C $repository rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or "$($commit[0])" -notmatch '^[0-9a-f]{40}$') {
        throw 'Could not identify the maintenance qualification candidate commit.'
    }
    $changes = @(& git -C $repository status --porcelain --untracked-files=no 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not determine candidate source cleanliness.' }
    $files = [ordered]@{}
    foreach ($relative in @(
            'Common.ps1', 'common\Common.ScriptBlocks.ps1', 'DSC\phases\WindowsSetupReadiness.ps1',
            'DSC\phases\Phase2DomainMember.ps1', 'DSC\phases\Phase2WorkgroupMember.ps1',
            'tools\Test-WindowsClientSetupReadiness.ps1', 'tools\Test-CimProxyTempPath.ps1',
            'tools\Clear-CimProxyTempFolders.ps1', 'tools\Test-SetupDiagnosticDefaults.ps1',
            'tools\Get-WindowsVmSetupDiagnostics.ps1', 'tools\Common.VmConsoleScreenshot.ps1',
            'tools\Test-VmConsoleScreenshot.ps1',
            'common\Common.Maintenance.ps1', 'common\Common.Validation.Functional.ps1',
            'Fixes\Fix-ODBC18.ps1', 'Fixes\Fix-Upgrade-Console.ps1', 'Fixes\Fix-CMFullAdmin.ps1',
            'DSC\phases\Upgrade-Console.ps1', 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1',
            'DSC\DSC.zip', 'DSC\DSC.build.json', 'version.json',
            'Start-Test.ps1', 'tools\Invoke-MainToDevelopExpansionTest.ps1',
            'tools\Common.MaintenanceQualification.ps1', 'tools\Invoke-MaintenanceQualification.ps1',
            'tools\Test-ConsoleUpgradeRouting.ps1', 'tools\Test-MaintenanceFixRobustness.ps1',
            'tools\Test-Odbc18VersionEnforcement.ps1', 'tools\Test-MsiBusyRetryAndPassiveDependency.ps1',
            'tools\Test-VMMaintenanceNoteDiagnostics.ps1', 'tools\Test-Phase11OsdContentState.ps1',
            'tools\Test-MaintenanceQualification.ps1', 'tools\Test-MainToDevelopExpansionRunner.ps1'
        )) {
        $path = Join-Path $VmbuildRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Candidate qualification source is missing: $path" }
        $files[$relative] = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $canonical = @($files.Keys | Sort-Object | ForEach-Object { "$_=$($files[$_])" }) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-', '') }
    finally { $sha.Dispose() }
    $tracked = @(& git -C $repository ls-files -- @($files.Keys | ForEach-Object { "vmbuild\$_" }) 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate tracked candidate qualification files.' }
    $allTracked = $tracked.Count -eq $files.Count
    [pscustomobject]@{ Commit = "$($commit[0])"; Dirty = $changes.Count -gt 0 -or -not $allTracked; Digest = $digest; Files = $files }
}

function Write-MaintenanceQualificationReceipt {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Receipt)
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
    }
    # Do not extend a valid receipt path past Windows PowerShell's path limit.
    $temporary = Join-Path $directory ".$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Receipt | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } }
}

function Assert-MaintenanceQualificationReceipt {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$MainRevision,
        [Parameter(Mandatory)][string]$DevelopRevision,
        [Parameter(Mandatory)][string]$SourceDigest,
        [object[]]$Targets = @(),
        [string]$ExpectedSha256,
        [switch]$RequireCmCoverage
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Maintenance qualification receipt is missing: $Path" }
    if ((Get-Item -LiteralPath $Path).Length -gt 4MB) { throw 'Maintenance qualification receipt exceeds 4 MB.' }
    if ($ExpectedSha256 -and (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedSha256) {
        throw "Maintenance qualification receipt checksum changed: $Path"
    }
    $receipt = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($receipt.SchemaVersion -ne 1 -or $receipt.Mode -cne $Mode -or
        $receipt.MainRevision -cne $MainRevision -or $receipt.DevelopRevision -cne $DevelopRevision -or
        $receipt.Source.Digest -cne $SourceDigest -or $receipt.Source.Commit -cne $DevelopRevision) {
        throw "Maintenance qualification receipt belongs to another contract, mode, or candidate: $Path"
    }
    if ($receipt.Status -cne 'Passed' -or $receipt.Source.Dirty -isnot [bool] -or $receipt.Source.Dirty) {
        throw "Maintenance qualification did not pass with clean pinned source: $Path"
    }
    if ($receipt.HasCmTarget -isnot [bool]) { throw "Maintenance receipt has an invalid CM coverage flag: $Path" }
    foreach ($name in @('DSC\DSC.zip', 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1')) {
        $property = $receipt.Source.Files.PSObject.Properties[$name]
        if (-not $property -or "$($property.Value)" -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Maintenance receipt omits the shipped source/module hash '$name': $Path"
        }
    }
    $expected = @($Targets | ForEach-Object { "$($_.Name)|$($_.Id)".ToLowerInvariant() } | Sort-Object)
    $actual = @($receipt.Targets | ForEach-Object { "$($_.Name)|$($_.Id)".ToLowerInvariant() } | Sort-Object)
    if ($Mode -ne 'Preflight' -and -not $expected.Count) { throw "Live maintenance receipt has no scoped target: $Path" }
    if (($expected -join "`n") -cne ($actual -join "`n")) { throw "Maintenance qualification target identity differs: $Path" }
    $required = @(Get-MaintenanceQualificationCases -Mode $Mode)
    $results = @($receipt.Cases)
    if ($results.Count -ne $required.Count -or @($results.Name | Select-Object -Unique).Count -ne $required.Count) {
        throw "Maintenance qualification has missing or duplicate cases: $Path"
    }
    foreach ($name in $required) {
        $case = @($results | Where-Object Name -ceq $name)
        if ($case.Count -ne 1 -or $case[0].Status -notin @('Passed', 'NotApplicable')) {
            throw "Maintenance qualification case '$name' did not pass: $Path"
        }
        if ($case[0].Status -eq 'NotApplicable' -and
            ($Mode -ne 'Recovery' -or $receipt.HasCmTarget -isnot [bool] -or $receipt.HasCmTarget -or -not $case[0].Reason)) {
            throw "Maintenance qualification improperly skipped case '$name': $Path"
        }
    }
    if ($RequireCmCoverage -and (-not $receipt.HasCmTarget -or @($results | Where-Object Status -ne 'Passed').Count)) {
        throw "Maintenance recovery matrix did not exercise a CM target: $Path"
    }
    if ($Mode -eq 'Recovery' -and -not $receipt.HasCmTarget -and @($results | Where-Object Status -ne 'NotApplicable').Count) {
        throw "Maintenance recovery receipt claims passed CM cases without a CM target: $Path"
    }
    return $receipt
}

function New-MaintenanceQualificationReference {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Receipt)
    [ordered]@{
        Path = [IO.Path]::GetFullPath($Path)
        Sha256 = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Mode = $Receipt.Mode
        MainRevision = $Receipt.MainRevision
        DevelopRevision = $Receipt.DevelopRevision
        SourceDigest = $Receipt.Source.Digest
        Targets = @($Receipt.Targets | Select-Object Name, Id)
        HasCmTarget = [bool]$Receipt.HasCmTarget
    }
}

function Assert-MaintenanceQualificationReference {
    param([Parameter(Mandatory)]$Reference, [switch]$RequireCmCoverage)
    if ("$($Reference.Sha256)" -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Maintenance qualification reference has no valid receipt checksum.'
    }
    return Assert-MaintenanceQualificationReceipt -Path $Reference.Path -Mode $Reference.Mode `
        -MainRevision $Reference.MainRevision -DevelopRevision $Reference.DevelopRevision `
        -SourceDigest $Reference.SourceDigest -Targets @($Reference.Targets) -ExpectedSha256 $Reference.Sha256 `
        -RequireCmCoverage:$RequireCmCoverage
}
