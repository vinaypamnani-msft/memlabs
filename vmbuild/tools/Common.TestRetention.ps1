function Get-MemLabsTestRetentionPath {
    if ($env:MEMLABS_TEST_RETENTION_PATH) { return [IO.Path]::GetFullPath($env:MEMLABS_TEST_RETENTION_PATH) }
    return Join-Path $env:ProgramData 'MemLabs\RetainedTestLabs.json'
}

function Read-MemLabsTestRetentions {
    param([string] $Path = (Get-MemLabsTestRetentionPath))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @($content)
    }
    catch {
        throw "Could not read retained-test registry '$Path'. $($_.Exception.Message)"
    }
}

function Write-MemLabsTestRetentions {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Retentions,
        [string] $Path = (Get-MemLabsTestRetentionPath)
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    }
    $tempPath = "$fullPath.$PID.tmp"
    try {
        $items = @($Retentions)
        $json = if ($items.Count -eq 0) { '[]' } else { $items | ConvertTo-Json -Depth 8 }
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-MemLabsRetentionConflict {
    param(
        [Parameter(Mandatory = $true)][object] $Retention,
        [Parameter(Mandatory = $true)][object] $Candidate
    )

    if (@($Retention.Domains | Where-Object { $_ -in @($Candidate.Domains) }).Count -gt 0) { return $true }
    if (@($Retention.VmNames | Where-Object { $_ -in @($Candidate.VmNames) }).Count -gt 0) { return $true }
    return $false
}

function Get-MemLabsExpiredRetentions {
    param(
        [Parameter(Mandatory = $true)][object[]] $Retentions,
        [DateTime] $NowUtc = [DateTime]::UtcNow
    )

    @($Retentions | Where-Object {
            $_.ExpiresUtc -and ([DateTime]"$($_.ExpiresUtc)").ToUniversalTime() -le $NowUtc
        })
}

function Get-MemLabsFreeStorageGB {
    param(
        [string[]] $BasePaths,
        [Parameter(Mandatory = $true)][string] $FallbackPath
    )

    $paths = @($BasePaths | Where-Object { $_ })
    if ($paths.Count -eq 0) { $paths = @($FallbackPath) }
    $freeValues = @()
    foreach ($path in $paths) {
        $fullPath = [IO.Path]::GetFullPath($path)
        $root = [IO.Path]::GetPathRoot($fullPath)
        if (-not $root) { continue }
        $drive = [IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) { continue }
        $freeValues += [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    }
    if ($freeValues.Count -eq 0) { throw "Could not determine free storage for: $($paths -join ', ')." }
    return [double](($freeValues | Measure-Object -Minimum).Minimum)
}

function Test-MemLabsCanRetainFailure {
    param(
        [Parameter(Mandatory = $true)][double] $FreeStorageGB,
        [double] $MinimumFreeStorageGB = 250,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $CurrentRetentions,
        [int] $MaximumRetentions = 2
    )

    [pscustomobject]@{
        CanRetain = $FreeStorageGB -ge $MinimumFreeStorageGB -and $MaximumRetentions -gt 0
        FreeStorageGB = $FreeStorageGB
        MinimumFreeStorageGB = $MinimumFreeStorageGB
        RequiresEviction = @($CurrentRetentions).Count -ge $MaximumRetentions
    }
}
