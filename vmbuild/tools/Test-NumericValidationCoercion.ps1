<#
.SYNOPSIS
    Rejects numeric validation implemented with PowerShell's coercing -as operator.

.DESCRIPTION
    An empty string converted with `-as [int]` becomes integer zero. Combining
    that with `-is [int]` therefore accepts blank input as a valid number. This
    scanner uses the PowerShell AST to catch parenthesized and unparenthesized
    forms without flagging comments or strings.
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [switch] $Quiet,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if ($SelfTest) {
    $fixturePath = Join-Path $env:TEMP ('numeric-coercion-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($fixturePath, 'if (($value -as [int]) -is [int]) { $accepted = $true }', [Text.Encoding]::ASCII)
    $Path = @($fixturePath)
}
$defaultScope = -not $Path

$numericTypes = 'byte|sbyte|short|ushort|int|int16|uint16|int32|uint|uint32|long|ulong|int64|uint64|single|float|double|decimal'
$issues = New-Object System.Collections.Generic.List[object]
try {
    $files = @()
    if ($defaultScope) {
        # Do not recursively enumerate large synchronized log/artifact trees
        # merely to discard them afterward. The gate judges repository source,
        # so ask Git for the exact tracked PowerShell corpus.
        $tracked = @(& git -C $repoRoot ls-files -- 'vmbuild/*.ps1' 'vmbuild/*.psm1' 'vmbuild/*.psd1' 'vmbuild/**/*.ps1' 'vmbuild/**/*.psm1' 'vmbuild/**/*.psd1')
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while enumerating PowerShell sources' }
        $files = @($tracked | ForEach-Object { Get-Item -LiteralPath (Join-Path $repoRoot $_) -ErrorAction SilentlyContinue } |
                Where-Object { $_ -and $_.FullName -notmatch '\\(logs|logs2|azureFiles|temp)\\' })
    }
    else {
        foreach ($candidate in $Path) {
            $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            if ($item.PSIsContainer) {
                $files += Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Include *.ps1,*.psm1,*.psd1 -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\(logs|logs2|azureFiles|temp)\\' }
            }
            else {
                $files += $item
            }
        }
    }

    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        if ($file.FullName -eq $PSCommandPath) { continue }
        $errors = $null; $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($node in $ast.FindAll({
                    param($candidate)
                    $candidate -is [Management.Automation.Language.BinaryExpressionAst] -and
                    "$($candidate.Operator)" -eq 'Is' -and
                    $candidate.Left.Extent.Text -match "(?i)-as\s*\[\s*($numericTypes)\s*\]"
                }, $true)) {
            $issues.Add([pscustomobject]@{
                    Path = $file.FullName
                    Line = $node.Extent.StartLineNumber
                    Text = $node.Extent.Text.Trim()
                })
        }
    }

    if ($SelfTest) {
        if ($issues.Count -eq 1) { exit 0 }
        Write-Host "Self-test failed: expected one issue, found $($issues.Count)." -ForegroundColor Red
        exit 1
    }

    if ($issues.Count -gt 0) {
        if (-not $Quiet) {
            Write-Host 'ERROR: Numeric validation via -as/-is accepts blank strings as zero.' -ForegroundColor Red
            foreach ($issue in $issues) {
                Write-Host "  $($issue.Path):$($issue.Line): $($issue.Text)" -ForegroundColor Yellow
            }
            Write-Host 'Use lexical validation or TryParse before converting.' -ForegroundColor Red
        }
        exit 1
    }

    if (-not $Quiet) { Write-Host 'Numeric validation coercion check passed.' }
}
finally {
    if ($SelfTest -and $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue }
}
