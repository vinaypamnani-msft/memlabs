function ConvertTo-MemLabsMemoryGB {
    param($Value)

    if ($null -eq $Value) { return 0.0 }
    $text = "$Value".Trim()
    if ($text -notmatch '^(?<Number>\d+(?:\.\d+)?)\s*(?<Unit>KB|MB|GB|TB)?$') { return 0.0 }
    $number = [double]$Matches.Number
    switch ("$($Matches.Unit)".ToUpperInvariant()) {
        'KB' { return $number / 1MB }
        'MB' { return $number / 1024 }
        'TB' { return $number * 1024 }
        default { return $number }
    }
}

function Get-MemLabsTestHistoryPath {
    if ($env:MEMLABS_TEST_HISTORY_PATH) { return [IO.Path]::GetFullPath($env:MEMLABS_TEST_HISTORY_PATH) }
    return Join-Path $env:ProgramData 'MemLabs\TestHistory.jsonl'
}

function Get-MemLabsCurrentCommit {
    param([Parameter(Mandatory = $true)][string] $RepositoryRoot)

    $commit = @(& git -C $RepositoryRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or $commit[0] -notmatch '^[0-9a-f]{40}$') {
        return ''
    }
    return $commit[0].Trim()
}

function Write-MemLabsTestHistoryEvent {
    param(
        [Parameter(Mandatory = $true)][object] $Event,
        [string] $Path = (Get-MemLabsTestHistoryPath)
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    if (-not $Event.PSObject.Properties['SchemaVersion']) {
        $Event | Add-Member -NotePropertyName SchemaVersion -NotePropertyValue 1 -Force
    }
    if (-not $Event.PSObject.Properties['RecordedUtc']) {
        $Event | Add-Member -NotePropertyName RecordedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    }
    $line = ($Event | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop) + [Environment]::NewLine
    $mutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestHistoryLock')
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw "Timed out acquiring the MemLabs test-history lock for '$fullPath'." }
        [IO.File]::AppendAllText($fullPath, $line, (New-Object Text.UTF8Encoding($false)))
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Read-MemLabsTestHistory {
    param([string] $Path = (Get-MemLabsTestHistoryPath))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $records = @()
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($Path))) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records += $line | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Test history '$Path' contains invalid JSON on line $lineNumber. $($_.Exception.Message)" }
    }
    return @($records)
}

function Get-MemLabsFamilyMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $VmbuildRoot,
        [Parameter(Mandatory = $true)][string] $Family,
        [switch] $IncludeMutations
    )

    $testsPath = Join-Path $VmbuildRoot 'config\tests'
    $files = @(Get-ChildItem -LiteralPath $testsPath -Filter "$Family-*.json" -File)
    if ($IncludeMutations.IsPresent) {
        $files += @(Get-ChildItem -LiteralPath (Join-Path $testsPath 'mutations') `
                -Filter "$Family-*.json" -File -ErrorAction SilentlyContinue)
    }
    $files = @($files | Sort-Object Name)
    if ($files.Count -eq 0) { throw "No test configs were found for family '$Family'." }

    $vmMap = @{}
    $domains = @()
    $basePaths = @()
    $tags = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) {
        $config = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $prefix = "$($config.vmOptions.prefix)"
        $domain = "$($config.vmOptions.domainName)"
        if ($domain) { $domains += $domain }
        if ($config.vmOptions.basePath) { $basePaths += "$($config.vmOptions.basePath)" }
        $isMutation = $config.PSObject.Properties['existingVmMutationVersion']
        foreach ($vm in @($config.virtualMachines)) {
            $requestedName = "$($vm.vmName)"
            $fullName = if ($prefix -and -not $requestedName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                "$prefix$requestedName"
            }
            else { $requestedName }
            if (-not $fullName) { continue }
            $role = "$($vm.role)"
            $memory = if ($isMutation -and $vm.changes -and $vm.changes.PSObject.Properties['memory']) {
                ConvertTo-MemLabsMemoryGB $vm.changes.memory
            }
            else {
                ConvertTo-MemLabsMemoryGB $vm.memory
            }
            if (-not $vmMap.ContainsKey($fullName)) {
                $vmMap[$fullName] = [pscustomobject]@{ VmName = $fullName; Role = $role; MemoryGB = $memory }
            }
            elseif ($memory -gt 0) {
                $vmMap[$fullName].MemoryGB = $memory
            }
            if ($role) { $null = $tags.Add("Role:$role") }
            foreach ($entry in @(
                    @{ Name = 'DP'; Keys = @('installDP', 'InstallDP') },
                    @{ Name = 'MP'; Keys = @('installMP', 'InstallMP') },
                    @{ Name = 'SUP'; Keys = @('installSUP', 'InstallSUP') },
                    @{ Name = 'RP'; Keys = @('installRP', 'InstallRP') },
                    @{ Name = 'PullDP'; Keys = @('enablePullDP') },
                    @{ Name = 'PKI'; Keys = @('InstallCA') },
                    @{ Name = 'Proxy'; Keys = @('useProxy') },
                    @{ Name = 'ReplicaMP'; Keys = @('useDatabaseReplica') },
                    @{ Name = 'PatchMyPC'; Keys = @('InstallPatchMyPC') },
                    @{ Name = 'Office'; Keys = @('installOffice') },
                    @{ Name = 'BLM'; Keys = @('BitLocker') }
                )) {
                foreach ($key in $entry.Keys) {
                    $value = if ($isMutation -and $vm.changes -and $vm.changes.PSObject.Properties[$key]) {
                        $vm.changes.$key
                    }
                    else { $vm.$key }
                    if ($value -eq $true -or ($entry.Name -eq 'Office' -and $value)) {
                        $null = $tags.Add($entry.Name)
                        break
                    }
                }
            }
            if ($vm.remoteSQLVM) { $null = $tags.Add('RemoteSQL') }
            if ($vm.sqlVersion) { $null = $tags.Add('SQL') }
            if ($vm.role -eq 'SQLAO') { $null = $tags.Add('SQLAO') }
            if ($vm.network -and "$($vm.network)" -ne "$($config.vmOptions.network)") { $null = $tags.Add('MultiSubnet') }
        }
        $cmOptions = $config.cmOptions
        if ($cmOptions.UsePKI -eq $true -or $config.pkiOptions.EnablePKI -eq $true) { $null = $tags.Add('PKI') }
        if ($config.pkiOptions.UseOfflineRoot -eq $true) { $null = $tags.Add('OfflineRoot') }
        if ($cmOptions.OfflineSUP -eq $true) { $null = $tags.Add('OfflineSUP') }
        if ($cmOptions.PrePopulateObjects -eq $true) { $null = $tags.Add('PrePopulate') }
        if ($cmOptions.EnableBLM -eq $true) { $null = $tags.Add('BLM') }
        if (@($config.virtualMachines | Where-Object { $_.ForestTrust -and $_.ForestTrust -ne 'NONE' }).Count -gt 0) {
            $null = $tags.Add('MultiDomain')
        }
    }
    $peakMemory = [Math]::Round((@($vmMap.Values | Measure-Object -Property MemoryGB -Sum).Sum), 1)
    [pscustomobject]@{
        Family                = $Family
        ConfigNames           = @($files.Name)
        Domains               = @($domains | Where-Object { $_ } | Select-Object -Unique)
        BasePaths             = @($basePaths | Where-Object { $_ } | Select-Object -Unique)
        VmNames               = @($vmMap.Keys | Sort-Object)
        VmCount               = $vmMap.Count
        EstimatedPeakMemoryGB = $peakMemory
        EstimatedRequiredGB   = [Math]::Round($peakMemory + 8, 1)
        CoverageTags          = @($tags | Sort-Object)
    }
}

function Get-MemLabsTestCandidates {
    param([Parameter(Mandatory = $true)][string] $VmbuildRoot)

    . (Join-Path $VmbuildRoot 'tools\Common.TestSuites.ps1')
    $ordinary = @(Get-MemLabsOrdinaryTestFamilies -VmbuildRoot $VmbuildRoot)
    $upgrade = Resolve-MemLabsTestSuite -VmbuildRoot $VmbuildRoot -Name 'Upgrade'
    $stress = Resolve-MemLabsTestSuite -VmbuildRoot $VmbuildRoot -Name 'Stress'
    $suiteNames = @('Core', 'Specialized', 'Stress')
    $suiteMembership = @{}
    foreach ($suiteName in $suiteNames) {
        $suite = Resolve-MemLabsTestSuite -VmbuildRoot $VmbuildRoot -Name $suiteName
        foreach ($family in $suite.Families) {
            if (-not $suiteMembership.ContainsKey($family)) { $suiteMembership[$family] = @() }
            $suiteMembership[$family] += $suiteName
        }
    }
    $standardMetadata = @{}
    $candidates = @()
    foreach ($family in $ordinary) {
        if (-not $standardMetadata.ContainsKey($family)) {
            $standardMetadata[$family] = Get-MemLabsFamilyMetadata -VmbuildRoot $VmbuildRoot -Family $family
        }
        $m = $standardMetadata[$family]
        $candidates += [pscustomobject]@{
            CandidateKey = "Standard|$family"; Mode = 'Standard'; Family = $family
            Suites = @($suiteMembership[$family]); IsStress = $family -in $stress.Families
            Metadata = $m
        }
    }
    foreach ($family in $upgrade.Families) {
        $upgradeMetadata = Get-MemLabsFamilyMetadata -VmbuildRoot $VmbuildRoot -Family $family -IncludeMutations
        $candidates += [pscustomobject]@{
            CandidateKey = "CrossRevision|$family"; Mode = 'CrossRevision'; Family = $family
            Suites = @('Upgrade'); IsStress = $false; Metadata = $upgradeMetadata
        }
    }
    return @($candidates)
}

function Get-MemLabsAvailableMemoryGB {
    try {
        $mb = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue
        if ($mb -gt 0) { return [Math]::Round($mb / 1024, 1) }
    }
    catch {}
    try {
        $kb = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory
        if ($kb -gt 0) { return [Math]::Round($kb / 1MB, 1) }
    }
    catch {}
    throw 'Could not determine available host memory.'
}

function Get-MemLabsRiskTagsForPaths {
    param([string[]] $Paths)

    $tags = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Paths)) {
        $p = "$path"
        if ($p -match 'PKI|Certificate|EnableHTTPS') { $null = $tags.Add('PKI') }
        if ($p -match 'perfloading|Boundary|DistributionPoint|\\bDP\\b|BootImage|OSD') {
            foreach ($tag in @('DP', 'OSD', 'MultiSubnet')) { $null = $tags.Add($tag) }
        }
        if ($p -match 'Phase7|InstallRoles|WSUS|SUP|Reporting|PBIRS') {
            foreach ($tag in @('SUP', 'RP')) { $null = $tags.Add($tag) }
        }
        if ($p -match 'SQLAO|Phase4|Sql|Replica') {
            foreach ($tag in @('SQL', 'SQLAO', 'ReplicaMP', 'RemoteSQL')) { $null = $tags.Add($tag) }
        }
        if ($p -match 'Linux|Proxy') {
            foreach ($tag in @('Role:LinuxServer', 'Role:LinuxClient', 'Role:Proxy', 'Proxy')) { $null = $tags.Add($tag) }
        }
        if ($p -match 'GenConfig|Common\.Config|Validation|MainToDevelop|CrossRevision') {
            foreach ($tag in @('ExistingVM', 'Upgrade')) { $null = $tags.Add($tag) }
        }
        if ($p -match 'HyperV|ScriptBlocks|Phase0|Phase1|New-VirtualMachine') { $null = $tags.Add('VMCreation') }
    }
    return @($tags | Sort-Object)
}

function Get-MemLabsBuildStatsEvidence {
    param([Parameter(Mandatory = $true)][string] $VmbuildRoot)

    $files = @()
    foreach ($root in @((Join-Path $VmbuildRoot 'logs'), (Join-Path $VmbuildRoot 'logs2'))) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -match '[\\/]stats$' })
        }
    }
    $evidence = @()
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        try { $stats = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if (-not $stats.Configuration) { continue }
        $family = ("$($stats.Configuration)" -split '-')[0]
        $mode = if ($file.FullName -match '[\\/]CrossRevision[\\/]' -or "$($stats.Branch)" -like 'memlabs-cross-*') {
            'CrossRevision'
        }
        else { 'Standard' }
        $completedUtc = try { ([DateTime]"$($stats.Timestamp)").ToUniversalTime() } catch { $file.LastWriteTimeUtc }
        $evidence += [pscustomobject]@{
            CandidateKey = "$mode|$family"; Family = $family; Mode = $mode
            Success = [bool]$stats.Success; Commit = "$($stats.Source.Commit)"
            CompletedUtc = $completedUtc; DurationSeconds = [double]$stats.TotalSeconds
            EvidenceType = 'BuildStats'; SourcePath = $file.FullName
        }
    }
    return @($evidence)
}

function Get-MemLabsHistoryEvidence {
    param([string] $Path = (Get-MemLabsTestHistoryPath))

    $records = @(Read-MemLabsTestHistory -Path $Path)
    $completedRunIds = @($records | Where-Object { $_.EventType -eq 'RunCompleted' } |
            ForEach-Object { "$($_.RunId)" } | Where-Object { $_ } | Select-Object -Unique)
    @(
        $records |
            Where-Object { $_.EventType -eq 'RunCompleted' } |
            ForEach-Object {
                [pscustomobject]@{
                    CandidateKey = "$($_.CandidateKey)"; Family = "$($_.Family)"; Mode = "$($_.Mode)"
                    Success = [bool]$_.Success; Commit = "$($_.Commit)"
                    CompletedUtc = [DateTime]"$($_.CompletedUtc)"
                    DurationSeconds = [double]$_.DurationSeconds
                    EvidenceType = 'History'; SourcePath = $Path
                    NeedsRerun = [bool]$_.NeedsRerun
                }
            }
        $records |
            Where-Object {
                $_.EventType -eq 'RunStarted' -and $_.RunId -and
                "$($_.RunId)" -notin $completedRunIds
            } |
            ForEach-Object {
                [pscustomobject]@{
                    CandidateKey = "$($_.CandidateKey)"; Family = "$($_.Family)"; Mode = "$($_.Mode)"
                    Success = $false; Commit = "$($_.Commit)"
                    CompletedUtc = [DateTime]"$($_.RecordedUtc)"
                    DurationSeconds = 0
                    EvidenceType = 'Interrupted'; SourcePath = $Path
                    NeedsRerun = $true
                }
            }
    )
}

function Get-MemLabsChangedPathsSince {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [string] $Commit
    )

    if (-not $Commit -or $Commit -notmatch '^[0-9a-f]{40}$') { return @() }
    $null = & git -C $RepositoryRoot cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @(& git -C $RepositoryRoot diff --name-only "$Commit..HEAD" 2>$null | Where-Object { $_ })
}

function Select-MemLabsNextTest {
    param(
        [Parameter(Mandatory = $true)][string] $VmbuildRoot,
        [string] $HistoryPath = (Get-MemLabsTestHistoryPath),
        [double] $AvailableMemoryGB = -1
    )

    $repositoryRoot = Split-Path -Parent $VmbuildRoot
    $currentCommit = Get-MemLabsCurrentCommit -RepositoryRoot $repositoryRoot
    if ($AvailableMemoryGB -lt 0) { $AvailableMemoryGB = Get-MemLabsAvailableMemoryGB }
    $candidates = @(Get-MemLabsTestCandidates -VmbuildRoot $VmbuildRoot)
    $evidence = @(
        Get-MemLabsHistoryEvidence -Path $HistoryPath
        Get-MemLabsBuildStatsEvidence -VmbuildRoot $VmbuildRoot
    )
    $workingPaths = @(
        & git -C $repositoryRoot diff --name-only 2>$null
        & git -C $repositoryRoot diff --cached --name-only 2>$null
        & git -C $repositoryRoot ls-files --others --exclude-standard -- 'vmbuild' 2>$null
    ) | Where-Object { $_ } | Select-Object -Unique
    $diffCache = @{}
    $now = [DateTime]::UtcNow
    $scored = @()
    foreach ($candidate in $candidates) {
        $candidateEvidence = @($evidence | Where-Object { $_.CandidateKey -ieq $candidate.CandidateKey } |
                Sort-Object CompletedUtc -Descending)
        $latest = $candidateEvidence | Select-Object -First 1
        $latestSuccess = $candidateEvidence | Where-Object { $_.Success } | Select-Object -First 1
        $score = 0.0
        $reasons = @()
        if (-not $latestSuccess) {
            $score += 1000
            $reasons += 'never passed'
        }
        else {
            $ageHours = [Math]::Max(0, ($now - $latestSuccess.CompletedUtc).TotalHours)
            $ageScore = [Math]::Min(400, $ageHours / 3)
            $score += $ageScore
            $reasons += "age=$([Math]::Round($ageHours, 1))h"
            if ($latestSuccess.Commit -and $latestSuccess.Commit -ne $currentCommit) {
                $commitCount = @(& git -C $repositoryRoot rev-list --count "$($latestSuccess.Commit)..HEAD" 2>$null)
                if ($LASTEXITCODE -eq 0 -and $commitCount.Count -eq 1) {
                    $distance = [int]$commitCount[0]
                    $score += [Math]::Min(500, 25 * $distance)
                    $reasons += "commits=$distance"
                }
                else {
                    $score += 300
                    $reasons += 'commit ancestry unknown'
                }
            }
        }
        if ($latest -and -not $latest.Success) {
            $score += 1000
            $reasons += 'latest run failed'
        }
        $latestRerunRequest = $candidateEvidence | Where-Object { $_.NeedsRerun } | Select-Object -First 1
        if ($latestRerunRequest -and
            (-not $latestSuccess -or $latestRerunRequest.CompletedUtc -ge $latestSuccess.CompletedUtc)) {
            $score += 1200
            $reasons += 'rerun requested'
        }
        $changedPaths = @()
        if ($latestSuccess -and $latestSuccess.Commit) {
            if (-not $diffCache.ContainsKey($latestSuccess.Commit)) {
                $diffCache[$latestSuccess.Commit] = @(Get-MemLabsChangedPathsSince -RepositoryRoot $repositoryRoot -Commit $latestSuccess.Commit)
            }
            $changedPaths = @($diffCache[$latestSuccess.Commit])
        }
        $changedPaths = @($changedPaths + $workingPaths | Select-Object -Unique)
        $riskTags = @(Get-MemLabsRiskTagsForPaths -Paths $changedPaths)
        $overlap = @($candidate.Metadata.CoverageTags | Where-Object { $_ -in $riskTags })
        if ($overlap.Count -gt 0) {
            $score += 200 * $overlap.Count
            $reasons += "risk=$($overlap -join '+')"
        }
        if ($candidate.Mode -eq 'CrossRevision' -and
            (@($riskTags | Where-Object { $_ -in @('Upgrade', 'ExistingVM') }).Count -gt 0)) {
            $score += 250
            $reasons += 'upgrade-path change'
        }
        $durations = @($candidateEvidence | Where-Object { $_.DurationSeconds -gt 0 } | Select-Object -ExpandProperty DurationSeconds)
        $estimatedMinutes = if ($durations.Count -gt 0) {
            [Math]::Round((($durations | Measure-Object -Average).Average) / 60, 1)
        }
        else {
            [Math]::Round([Math]::Max(10, $candidate.Metadata.VmCount * 8 + $candidate.Metadata.ConfigNames.Count * 10), 1)
        }
        $score -= [Math]::Min(300, $estimatedMinutes)
        if ($candidate.IsStress) {
            $score -= 250
            $reasons += 'stress deferred'
        }
        $fitsHost = $candidate.Metadata.EstimatedRequiredGB -le $AvailableMemoryGB
        if (-not $fitsHost) {
            $reasons += "needs $($candidate.Metadata.EstimatedRequiredGB)GB; available ${AvailableMemoryGB}GB"
        }
        $scored += [pscustomobject]@{
            CandidateKey = $candidate.CandidateKey
            Mode = $candidate.Mode
            Family = $candidate.Family
            Suites = @($candidate.Suites)
            Score = [Math]::Round($score, 1)
            FitsHost = $fitsHost
            AvailableMemoryGB = $AvailableMemoryGB
            RequiredMemoryGB = $candidate.Metadata.EstimatedRequiredGB
            EstimatedMinutes = $estimatedMinutes
            Domains = @($candidate.Metadata.Domains)
            BasePaths = @($candidate.Metadata.BasePaths)
            VmNames = @($candidate.Metadata.VmNames)
            CoverageTags = @($candidate.Metadata.CoverageTags)
            Reasons = @($reasons)
            CurrentCommit = $currentCommit
        }
    }
    return @($scored | Sort-Object @{ Expression = 'FitsHost'; Descending = $true }, @{ Expression = 'Score'; Descending = $true }, CandidateKey)
}
