<#
.SYNOPSIS
    Patches LanguageDsc 1.0.0.0 null registry handling inside DSC.zip.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ArchivePath
)

function Get-NormalizedArchivePath {
    param ([string] $Path)

    $segments = [Collections.Generic.List[string]]::new()
    foreach ($segment in ($Path.Replace('\', '/') -split '/')) {
        if (-not $segment -or $segment -eq '.') { continue }
        if ($segment -eq '..') {
            if ($segments.Count -eq 0) { return $null }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }
        $segments.Add($segment)
    }
    return $segments -join '/'
}

$ErrorActionPreference = 'Stop'
$archiveFullPath = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$temporaryArchive = Join-Path (Split-Path $archiveFullPath -Parent) ('.{0}.{1}.tmp' -f (Split-Path $archiveFullPath -Leaf), [guid]::NewGuid().ToString('N'))
$backupArchive = "$temporaryArchive.backup"
try {
    Copy-Item -LiteralPath $archiveFullPath -Destination $temporaryArchive -ErrorAction Stop
    $zip = [IO.Compression.ZipFile]::Open($temporaryArchive, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entries = @($zip.Entries | Where-Object { $null -ne $_ -and (Get-NormalizedArchivePath -Path $_.FullName) -eq 'LanguageDsc/DSCResources/MSFT_Language/MSFT_Language.psm1' })
        if ($entries.Count -ne 1) { throw "Expected exactly one LanguageDsc MSFT_Language resource in $archiveFullPath, found $($entries.Count)." }
        $entry = $entries[0]

        $reader = [IO.StreamReader]::new($entry.Open(), [Text.Encoding]::UTF8, $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }

        $continueLine = '        $LanguageCodeObj = $LanguageProperties | Get-Member -MemberType NoteProperty | Where-Object {$_.Name -Match $RegEx} -ErrorAction Continue'
        $stopLine = '        $LanguageCodeObj = $LanguageProperties | Get-Member -MemberType NoteProperty | Where-Object {$_.Name -Match $RegEx} -ErrorAction Stop'
        $nameLine = '        $LanguageCode = $LanguageCodeObj.Name'
        $replacementLine = '        $LanguageCode = if ($null -ne $LanguageProperties) { @($LanguageProperties.PSObject.Properties.Name | Where-Object { $_ -Match $RegEx }) } else { @() }'
        $typoLine = 'if ($nulll -ne $LanguageCode)'
        $fixedLine = 'if ($null -ne $LanguageCode)'
        $registryReadLines = @(
            '        $LanguageProperties = Get-ItemProperty -Path "HKCU:\Control Panel\International\User Profile\$Language\" -ErrorAction Continue'
            '        $LanguageProperties = Get-ItemProperty "HKCU:\Control Panel\International\User Profile\$Language\" -ErrorAction Stop'
            '        $LanguageProperties = Get-ItemProperty "registry::hkey_Users\S-1-5-18\Control Panel\International\User Profile\$Language\" -ErrorAction Stop'
            '        $LanguageProperties = Get-ItemProperty "registry::hkey_Users\.DEFAULT\Control Panel\International\User Profile\$Language\" -ErrorAction Stop'
        )
        $patchedRegistryReadLines = @($registryReadLines | ForEach-Object { $_.Replace('-ErrorAction Continue', '-ErrorAction SilentlyContinue').Replace('-ErrorAction Stop', '-ErrorAction SilentlyContinue') })

        $unsafeCount = [regex]::Matches($text, [regex]::Escape($continueLine)).Count +
            [regex]::Matches($text, [regex]::Escape($stopLine)).Count
        $replacementCount = [regex]::Matches($text, [regex]::Escape($replacementLine)).Count
        $nameLineCount = [regex]::Matches($text, [regex]::Escape($nameLine)).Count
        $typoCount = [regex]::Matches($text, [regex]::Escape($typoLine)).Count
        $fixedCount = [regex]::Matches($text, [regex]::Escape($fixedLine)).Count

        if ($unsafeCount -eq 0) {
            if ($replacementCount -ne 4 -or $nameLineCount -ne 0 -or $typoCount -ne 0 -or $fixedCount -ne 4) {
                throw "LanguageDsc patched-state validation failed: replacements=$replacementCount obsoleteNames=$nameLineCount nullTypos=$typoCount fixedNulls=$fixedCount."
            }
            foreach ($registryReadLine in $registryReadLines) {
                if ([regex]::Matches($text, [regex]::Escape($registryReadLine)).Count -ne 0) { throw "Unpatched LanguageDsc registry read remains: $registryReadLine" }
            }
            foreach ($patchedRegistryReadLine in $patchedRegistryReadLines) {
                $lineCount = [regex]::Matches($text, [regex]::Escape($patchedRegistryReadLine)).Count
                if ($lineCount -ne 1) { throw "Expected one patched LanguageDsc registry read '$patchedRegistryReadLine', found $lineCount." }
            }
            Write-Host 'LanguageDsc archive is already patched.'
            return
        }

        if ($unsafeCount -ne 4 -or $replacementCount -ne 0 -or $nameLineCount -ne 4 -or $typoCount -ne 1 -or $fixedCount -ne 3) {
            throw "LanguageDsc source validation failed: unsafeBlocks=$unsafeCount replacements=$replacementCount obsoleteNames=$nameLineCount nullTypos=$typoCount fixedNulls=$fixedCount."
        }
        foreach ($registryReadLine in $registryReadLines) {
            $lineCount = [regex]::Matches($text, [regex]::Escape($registryReadLine)).Count
            if ($lineCount -ne 1) { throw "Expected one LanguageDsc registry read '$registryReadLine', found $lineCount." }
        }
        foreach ($patchedRegistryReadLine in $patchedRegistryReadLines) {
            if ([regex]::Matches($text, [regex]::Escape($patchedRegistryReadLine)).Count -ne 0) { throw "LanguageDsc registry read is already partially patched: $patchedRegistryReadLine" }
        }

        $text = $text.Replace($continueLine, $replacementLine).Replace($stopLine, $replacementLine)
        $text = $text.Replace($nameLine + "`r`n", '').Replace($nameLine + "`n", '')
        for ($index = 0; $index -lt $registryReadLines.Count; $index++) {
            $text = $text.Replace($registryReadLines[$index], $patchedRegistryReadLines[$index])
        }
        $text = $text.Replace($typoLine, $fixedLine)

        if ([regex]::Matches($text, [regex]::Escape($replacementLine)).Count -ne 4 -or
            [regex]::Matches($text, [regex]::Escape($nameLine)).Count -ne 0 -or
            [regex]::Matches($text, [regex]::Escape($typoLine)).Count -ne 0 -or
            [regex]::Matches($text, [regex]::Escape($fixedLine)).Count -ne 4) {
            throw 'LanguageDsc patched-state validation failed after replacement.'
        }

        $entryName = $entry.FullName
        $entry.Delete()
        $newEntry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $writer = [IO.StreamWriter]::new($newEntry.Open(), [Text.UTF8Encoding]::new($true))
        try { $writer.Write($text) } finally { $writer.Dispose() }
    }
    finally {
        $zip.Dispose()
    }

    [IO.File]::Replace($temporaryArchive, $archiveFullPath, $backupArchive)
    Remove-Item -LiteralPath $backupArchive -Force -ErrorAction Stop
    Write-Host "Patched LanguageDsc null registry handling in $archiveFullPath"
}
finally {
    if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backupArchive) { Remove-Item -LiteralPath $backupArchive -Force -ErrorAction SilentlyContinue }
}