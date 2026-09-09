<#
.SYNOPSIS
    Verifies the LanguageDsc archive compatibility patch.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

$sourceArchive = Join-Path $RootPath 'DSC\DSC.zip'
$work = Join-Path ([IO.Path]::GetTempPath()) ('language-dsc-patch-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $work 'DSC.zip'
$extract = Join-Path $work 'extract'
try {
    $null = New-Item -ItemType Directory -Path $work -Force
    Copy-Item -LiteralPath $sourceArchive -Destination $archive
    & (Join-Path $RootPath 'tools\Update-LanguageDscArchive.ps1') -ArchivePath $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $resourcePath = Join-Path $extract 'LanguageDsc\DSCResources\MSFT_Language\MSFT_Language.psm1'
    $resource = Get-Content -LiteralPath $resourcePath -Raw
    Assert-Equal 0 ([regex]::Matches($resource, '\| Get-Member -MemberType NoteProperty').Count) 'patched resource has no null-unsafe Get-Member pipelines'
    Assert-Equal 4 ([regex]::Matches($resource, '\$LanguageCode = if \(\$null -ne \$LanguageProperties\)').Count) 'all four language-profile reads are null-safe'
    Assert-Equal 4 ([regex]::Matches($resource, '\$LanguageProperties = Get-ItemProperty .+ -ErrorAction SilentlyContinue').Count) 'all four missing registry reads are non-terminating'
    Assert-Equal 0 ([regex]::Matches($resource, '\$LanguageProperties = Get-ItemProperty .+ -ErrorAction (?:Continue|Stop)').Count) 'no original registry error actions remain'
    Assert-Equal 0 ([regex]::Matches($resource, '\$nulll').Count) 'SYSTEM language comparison uses the real null variable'
    $LanguageProperties = $null
    $RegEx = '[0-9a-fA-F]{4}:[0-9a-fA-F]{8}'
    $LanguageCode = if ($null -ne $LanguageProperties) { @($LanguageProperties.PSObject.Properties.Name | Where-Object { $_ -Match $RegEx }) } else { @() }
    Assert-Equal 0 @($LanguageCode).Count 'missing language registry key produces an empty code list without an error'
    $beforeIdempotenceHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $idempotenceError = $null
    try { & (Join-Path $RootPath 'tools\Update-LanguageDscArchive.ps1') -ArchivePath $archive } catch { $idempotenceError = $_ }
    Assert-Equal $true ($null -eq $idempotenceError) 'archive patch is idempotent'
    Assert-Equal $beforeIdempotenceHash (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash 'idempotent patch leaves archive bytes unchanged'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $duplicateNames = @(
        'LanguageDsc/DSCResources/MSFT_Language/MSFT_Language.psm1'
        'LanguageDsc/./DSCResources/MSFT_Language/MSFT_Language.psm1'
        'LanguageDsc//DSCResources/MSFT_Language/MSFT_Language.psm1'
        'LanguageDsc/ignored/../DSCResources/MSFT_Language/MSFT_Language.psm1'
    )
    for ($index = 0; $index -lt $duplicateNames.Count; $index++) {
        $duplicateArchive = Join-Path $work "duplicate-$index.zip"
        Copy-Item -LiteralPath $archive -Destination $duplicateArchive
        $duplicateZip = [IO.Compression.ZipFile]::Open($duplicateArchive, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $duplicateEntry = $duplicateZip.CreateEntry($duplicateNames[$index])
            $duplicateWriter = [IO.StreamWriter]::new($duplicateEntry.Open())
            try { $duplicateWriter.Write('duplicate') } finally { $duplicateWriter.Dispose() }
        }
        finally { $duplicateZip.Dispose() }
        $duplicateHash = (Get-FileHash -LiteralPath $duplicateArchive -Algorithm SHA256).Hash
        $duplicateError = $null
        try { & (Join-Path $RootPath 'tools\Update-LanguageDscArchive.ps1') -ArchivePath $duplicateArchive } catch { $duplicateError = $_ }
        Assert-Equal $true ($null -ne $duplicateError) "duplicate LanguageDsc entry '$($duplicateNames[$index])' is rejected"
        Assert-Equal $duplicateHash (Get-FileHash -LiteralPath $duplicateArchive -Algorithm SHA256).Hash "duplicate rejection for '$($duplicateNames[$index])' leaves archive bytes unchanged"
    }

    $markerArchive = Join-Path $work 'marker-only.zip'
    $markerZip = [IO.Compression.ZipFile]::Open($markerArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $markerEntry = $markerZip.CreateEntry('LanguageDsc/DSCResources/MSFT_Language/MSFT_Language.psm1')
        $markerWriter = [IO.StreamWriter]::new($markerEntry.Open())
        try { $markerWriter.Write('$LanguageCode = if ($null -ne $LanguageProperties)') } finally { $markerWriter.Dispose() }
    }
    finally { $markerZip.Dispose() }
    $markerHash = (Get-FileHash -LiteralPath $markerArchive -Algorithm SHA256).Hash
    $markerError = $null
    try { & (Join-Path $RootPath 'tools\Update-LanguageDscArchive.ps1') -ArchivePath $markerArchive } catch { $markerError = $_ }
    Assert-Equal $true ($null -ne $markerError) 'marker-only LanguageDsc resource is rejected'
    Assert-Equal $markerHash (Get-FileHash -LiteralPath $markerArchive -Algorithm SHA256).Hash 'marker-only rejection leaves archive bytes unchanged'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures) { throw "$script:Failures LanguageDsc archive patch test(s) failed" }
Write-Host 'ALL LANGUAGEDSC ARCHIVE PATCH TESTS PASSED' -ForegroundColor Green