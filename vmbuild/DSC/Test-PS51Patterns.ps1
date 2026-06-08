# Test-PS51Patterns.ps1
# Pre-commit check for PS 5.1 runtime anti-patterns in staged files.
# Called from .git/hooks/pre-commit for files that run inside VMs.

$Files = git diff --cached --name-only --diff-filter=ACM |
    Where-Object { $_ -match '(vmbuild/DSC/|Common\.ScriptBlocks\.ps1|TemplateHelpDSC)' }

if (-not $Files) { exit 0 }

$issues = @()

foreach ($f in $Files) {
    # Get added/modified lines from staged diff
    $diffLines = git diff --cached -U0 -- $f |
        Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' }

    if (-not $diffLines) { continue }

    foreach ($line in $diffLines) {
        # Pattern 1: ::new($var) without @() wrapper
        # Matches: ::new($items) but not ::new() or ::new($a, $b) or ::new([string[]]@($items))
        if ($line -match '::new\(\$[^,)]+\)' -and $line -notmatch '@\(') {
            $issues += "  $f  ::new(`$var) without @() -- PS 5.1 cannot match collection constructor overloads."
            $issues += "    $($line.TrimStart('+').Trim())"
            $issues += "    Fix: [string[]]@(`$var) or [type[]]@(`$var)"
            $issues += ""
        }

        # Pattern 2: .Values or .Keys passed to cmdlet parameter without @()
        if ($line -match '\.(Values|Keys)\b' -and $line -notmatch '@\(' -and $line -match '-[A-Za-z]') {
            $issues += "  $f  `$hash.Values/Keys without @() -- PS 5.1 cannot bind ValueCollection/KeyCollection."
            $issues += "    $($line.TrimStart('+').Trim())"
            $issues += "    Fix: @(`$hash.Values)"
            $issues += ""
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: PS 5.1 runtime anti-patterns found in files that execute inside VMs." -ForegroundColor Red
    Write-Host "These patterns pass parsing but fail at runtime under PowerShell 5.1." -ForegroundColor Red
    Write-Host ""
    $issues | ForEach-Object { Write-Host $_ }
    Write-Host "Test with: powershell.exe -NoProfile -Command { <pattern> }"
    Write-Host "To bypass (if false positive): git commit --no-verify"
    exit 1
}

exit 0
