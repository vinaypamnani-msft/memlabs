<#
.SYNOPSIS
    Lint DSC phase files for backtick-escaped $true/$false inside { } script blocks.
.DESCRIPTION
    DSC Script resources accept TestScript/GetScript as { } script blocks or
    SetScript as [string]"..." strings.  Backtick escaping (`$true, `$false) is
    required inside double-quoted strings to prevent variable expansion, but is
    WRONG inside { } blocks — it turns $false into a bareword that PowerShell
    tries to invoke as a command, silently crashing DSC's consistency check.

    This script scans DSC phase .ps1 files and flags any `$true or `$false
    that appear inside TestScript or GetScript { } blocks.
.EXAMPLE
    .\Test-DscScriptBlocks.ps1
    .\Test-DscScriptBlocks.ps1 -Path C:\memlabs\vmbuild\DSC\phases
#>
param(
    [string] $Path = (Join-Path $PSScriptRoot "phases")
)

$exitCode = 0
$files = Get-ChildItem -Path $Path -Filter "*.ps1" -Recurse

foreach ($file in $files) {
    $lines = Get-Content $file.FullName
    $inScriptBlock = $false
    $blockProperty = ""
    $braceDepth = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Detect start of TestScript = { or GetScript = {
        if ($line -match '^\s*(TestScript|GetScript)\s*=\s*\{') {
            $inScriptBlock = $true
            $blockProperty = $Matches[1]
            # Count opening braces on this line (minus the one matched in the property assignment)
            $braceDepth = ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count -
                          ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            # Check this line too
            if ($line -match '`\$(true|false)') {
                $val = $Matches[1]
                Write-Warning ("{0}:{1}: backtick-escaped `${2} in {3} script block" -f $file.Name, ($i + 1), $val, $blockProperty)
                $exitCode = 1
            }
            if ($braceDepth -le 0) { $inScriptBlock = $false }
            continue
        }

        if ($inScriptBlock) {
            $braceDepth += ($line.ToCharArray() | Where-Object { $_ -eq '{' }).Count -
                           ($line.ToCharArray() | Where-Object { $_ -eq '}' }).Count

            if ($line -match '`\$(true|false)') {
                $val = $Matches[1]
                Write-Warning ("{0}:{1}: backtick-escaped `${2} in {3} script block" -f $file.Name, ($i + 1), $val, $blockProperty)
                $exitCode = 1
            }

            if ($braceDepth -le 0) { $inScriptBlock = $false }
        }
    }
}

if ($exitCode -eq 0) {
    Write-Host "DSC script block lint: all clean." -ForegroundColor Green
}
else {
    Write-Host "DSC script block lint: issues found (see warnings above)." -ForegroundColor Red
}

exit $exitCode
