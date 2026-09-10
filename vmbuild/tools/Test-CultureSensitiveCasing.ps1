<#
.SYNOPSIS
    Flag parameterless string casing, which depends on the current culture.

.DESCRIPTION
    Machine keys and identifiers must use ToLowerInvariant or ToUpperInvariant.
    Equality predicates should normally use -ieq or -ine. Human-language text
    must pass an explicit culture to the casing method.

    The AST finds executable calls. A token-aware text fallback also checks
    generated code and partial ASTs while ignoring comments.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

if (-not $Path) { $Path = Split-Path $PSScriptRoot -Parent }

$sources = @()
if ($SelfTest.IsPresent) {
    $lowerMethod = 'To' + 'Lower'
    $upperMethod = 'To' + 'Upper'
    $lowercaseMethod = 'to' + 'lower'
    $uppercaseMethod = 'TO' + 'UPPER'
    $mixedCaseMethod = 'tO' + 'LoWeR'
    $fixture = @"
`$badLower = 'ACTIVE'.$lowerMethod()
`$badUpper = 'active'.$upperMethod()
`$safeLower = 'ACTIVE'.ToLowerInvariant()
`$safeUpper = 'active'.ToUpperInvariant()
`$generatedCode = "'ACTIVE'.$lowerMethod()"
# 'ACTIVE'.$upperMethod()
`$display = 'TITLE'.ToLower([Globalization.CultureInfo]::CurrentCulture)
`$generatedLowercase = "'ACTIVE'.$lowercaseMethod()"
`$generatedUppercase = "'active'.$uppercaseMethod()"
`$generatedMixedCase = "'ACTIVE'.$mixedCaseMethod()"
"@
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$tokens, [ref]$parseErrors)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Text = $fixture; Ast = $ast; Tokens = @($tokens) })
}
else {
    $target = Get-Item -LiteralPath $Path -ErrorAction Stop
    $files = if ($target.PSIsContainer) {
        $root = $target.FullName.TrimEnd('\')
        @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1, *.psd1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Substring($root.Length).TrimStart('\') -notmatch '^(logs|logs2|azureFiles|temp)\\' })
    }
    else {
        @($target)
    }

    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $file.FullName, [ref]$tokens, [ref]$parseErrors)
        $sources += [pscustomobject]@{ Name = $file.FullName; Text = $text; Ast = $ast; Tokens = @($tokens) }
    }
}

if ($sources.Count -eq 0) {
    Write-Host "ERROR: no PowerShell source found under '$Path' -- NOTHING WAS SCANNED." -ForegroundColor Red
    exit 1
}

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($source in $sources) {
    $astCallExtents = [System.Collections.Generic.List[object]]::new()
    foreach ($call in $source.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Member.Value -in @('ToLower', 'ToUpper') -and
                $node.Arguments.Count -eq 0
            }, $true)) {
        $astCallExtents.Add([pscustomobject]@{ Start = $call.Extent.StartOffset; End = $call.Extent.EndOffset })
        $findings.Add([pscustomobject]@{
                Source = $source.Name
                Line   = $call.Extent.StartLineNumber
                Text   = ($call.Extent.Text -split "`n")[0].Trim()
                Origin = 'AST'
            })
    }

        foreach ($match in [regex]::Matches($source.Text, '\.(?:ToLower|ToUpper)\s*\(\s*\)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        $coveredByAst = @($astCallExtents | Where-Object {
            $_.Start -le $match.Index -and $_.End -ge ($match.Index + $match.Length)
            }).Count -gt 0
        if ($coveredByAst) { continue }
        $comment = @($source.Tokens | Where-Object {
                $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and
                $_.Extent.StartOffset -le $match.Index -and $_.Extent.EndOffset -ge ($match.Index + $match.Length)
            })
        if ($comment.Count -gt 0) { continue }
        $line = 1 + ([regex]::Matches($source.Text.Substring(0, $match.Index), "`n")).Count
        $lineText = ($source.Text -split "`r?`n")[$line - 1].Trim()
        $findings.Add([pscustomobject]@{ Source = $source.Name; Line = $line; Text = $lineText; Origin = 'Text' })
    }
}

if (-not $Quiet) {
    Write-Host "Scanned $($sources.Count) source(s) for culture-sensitive parameterless casing."
}

if ($SelfTest.IsPresent) {
    $expected = @('1:AST', '2:AST', '5:Text', '8:Text', '9:Text', '10:Text')
    $actual = @($findings | ForEach-Object { "$($_.Line):$($_.Origin)" } | Sort-Object -Unique)
    $missed = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ })
    if ($missed.Count -or $extra.Count) {
        Write-Host "SELF-TEST FAILED. missed=[$($missed -join ', ')] unexpected=[$($extra -join ', ')]" -ForegroundColor Red
        exit 1
    }
    Write-Host 'SELF-TEST PASSED - caught two executable and four generated-code calls in canonical/lower/upper/mixed case; safe forms were ignored.' -ForegroundColor Green
    exit 0
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host 'OK - all string casing is culture-explicit.' }
    exit 0
}

Write-Host ''
Write-Host 'ERROR: culture-sensitive parameterless string casing:' -ForegroundColor Red
foreach ($finding in ($findings | Sort-Object Source, Line -Unique)) {
    Write-Host ("  {0}:{1}" -f $finding.Source, $finding.Line) -ForegroundColor Yellow
    Write-Host ("      {0}" -f $finding.Text) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Use -ieq/-ine for equality, invariant casing for machine data, or pass an explicit culture for human text.' -ForegroundColor Red
exit 1