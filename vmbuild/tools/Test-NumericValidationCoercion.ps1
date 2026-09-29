<#
.SYNOPSIS
    Rejects numeric validation implemented with PowerShell's coercing -as operator.

.DESCRIPTION
    An empty string converted with `-as [int]` becomes integer zero. Testing that
    converted value with `-is` or `-isnot` can therefore accept blank input as a
    valid number. This scanner uses the PowerShell AST to catch parenthesized and
    unparenthesized forms without flagging comments, strings, standalone
    conversions, or TryParse validation.
#>
[CmdletBinding()]
param(
    [string[]] $Path,
    [switch] $Quiet,
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$fixtureRoot = $null
$numericTypes = 'byte|sbyte|short|ushort|int|int16|uint16|int32|uint|uint32|long|ulong|int64|uint64|single|float|double|decimal|bigint|System\.(?:Byte|SByte|Int16|UInt16|Int32|UInt32|Int64|UInt64|Single|Double|Decimal)|System\.Numerics\.BigInteger'
$nonBlockingParserErrorIds = @(
    'ModuleNotFoundDuringParse'
    'MultipleModuleEntriesFoundDuringParse'
    'InvalidInstanceProperty'
    'ResourceNotDefined'
)
$script:ParserDiagnostics = New-Object System.Collections.Generic.List[object]

function Get-ScanFiles {
    param([string[]] $RequestedPath)

    $files = @()
    if (-not $RequestedPath) {
        $tracked = @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- `
                'vmbuild/*.ps1' 'vmbuild/*.psm1' 'vmbuild/*.psd1' `
                'vmbuild/**/*.ps1' 'vmbuild/**/*.psm1' 'vmbuild/**/*.psd1')
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed with exit code $LASTEXITCODE while enumerating PowerShell sources."
        }
        $files = @($tracked |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $repoRoot $_) -ErrorAction SilentlyContinue } |
                Where-Object { $_ -and $_.FullName -notmatch '\\(logs|logs2|azureFiles|temp)\\' })
    }
    else {
        foreach ($candidate in $RequestedPath) {
            $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            if (-not $item) { throw "Scan path not found: '$candidate'." }

            if ($item.PSIsContainer) {
                $files += @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction Stop |
                        Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
            }
            elseif ($item.Extension -in '.ps1', '.psm1', '.psd1') {
                $files += $item
            }
            else {
                throw "Scan path is not a PowerShell source file: '$candidate'."
            }
        }
    }

    $resolved = @($files | Sort-Object FullName -Unique)
    if ($resolved.Count -eq 0) { throw 'No PowerShell source files were found in the requested scan scope.' }
    return $resolved
}

function Find-NumericValidationCoercion {
    param([IO.FileInfo[]] $File)

    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($sourceFile in $File) {
        if ($sourceFile.FullName -eq $PSCommandPath) { continue }

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName, [ref]$tokens, [ref]$parseErrors)
        $blockingParseErrors = @($parseErrors | Where-Object { $_.ErrorId -notin $nonBlockingParserErrorIds })
        if ($blockingParseErrors.Count -gt 0) {
            $details = @($blockingParseErrors | ForEach-Object {
                    "line $($_.Extent.StartLineNumber): $($_.Message)"
                }) -join '; '
            throw "Cannot scan '$($sourceFile.FullName)' because it has PowerShell parse errors: $details"
        }
        foreach ($parseDiagnostic in @($parseErrors | Where-Object { $_.ErrorId -in $nonBlockingParserErrorIds })) {
            $script:ParserDiagnostics.Add([pscustomobject]@{
                    Path = $sourceFile.FullName
                    Line = $parseDiagnostic.Extent.StartLineNumber
                    ErrorId = $parseDiagnostic.ErrorId
                    Message = $parseDiagnostic.Message
                })
        }

        foreach ($node in $ast.FindAll({
                    param($candidate)
                    $candidate -is [Management.Automation.Language.BinaryExpressionAst] -and
                    "$($candidate.Operator)" -match '^Is(Not)?$' -and
                    $candidate.Left.Extent.Text -match "(?i)-as\s*\[\s*($numericTypes)\s*\]"
                }, $true)) {
            $issues.Add([pscustomobject]@{
                    Path = $sourceFile.FullName
                    Line = $node.Extent.StartLineNumber
                    Operator = "$($node.Operator)"
                    Text = $node.Extent.Text.Trim()
                })
        }
    }
    return $issues
}

function Write-ParserDiagnosticSummary {
    if ($script:ParserDiagnostics.Count -eq 0) { return }

    $counts = @($script:ParserDiagnostics |
            Group-Object ErrorId |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" })
    Write-Host "NOTE: Scanned partial ASTs after $($script:ParserDiagnostics.Count) environment-dependent DSC parser diagnostic(s): $($counts -join ', ')." -ForegroundColor Yellow
    foreach ($diagnostic in $script:ParserDiagnostics) {
        Write-Verbose "$($diagnostic.Path):$($diagnostic.Line) [$($diagnostic.ErrorId)] $($diagnostic.Message)"
    }
}

function Write-SelfTestFixture {
    param([string] $Name, [string] $Content)

    [IO.File]::WriteAllText((Join-Path $fixtureRoot $Name), $Content, [Text.Encoding]::ASCII)
}

$exitCode = 0
try {
    if ($SelfTest) {
        if ($Path) { throw '-SelfTest cannot be combined with -Path.' }

        $fixtureRoot = Join-Path $env:TEMP ('numeric-coercion-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixtureRoot -Force
        Write-SelfTestFixture 'parenthesized.ps1' 'if (($value -as [int]) -is [int]) { $accepted = $true }'
        Write-SelfTestFixture 'unparenthesized.ps1' 'if ($value -as [System.UInt32] -is [uint]) { $accepted = $true }'
        Write-SelfTestFixture 'isnot.ps1' 'if (($value -as [double]) -isnot [double]) { $rejected = $true }'
        Write-SelfTestFixture 'safe.ps1' @'
# if (($value -as [int]) -is [int]) { }
$example = '(($value -as [int]) -is [int])'
$converted = $value -as [int]
$parsed = 0
if ([int]::TryParse([string]$value, [ref]$parsed)) { $accepted = $true }
if ($value -is [int]) { $alreadyTyped = $true }
'@
        $Path = @($fixtureRoot)
    }

    $files = @(Get-ScanFiles -RequestedPath $Path)
    $issues = @(Find-NumericValidationCoercion -File $files)
    if (-not $SelfTest -and -not $Quiet) { Write-ParserDiagnosticSummary }

    if ($SelfTest) {
        $expected = @('isnot.ps1', 'parenthesized.ps1', 'unparenthesized.ps1') | Sort-Object
        $actual = @($issues | ForEach-Object { Split-Path -Leaf $_.Path } | Sort-Object)
        $missing = @($expected | Where-Object { $_ -notin $actual })
        $unexpected = @($actual | Where-Object { $_ -notin $expected })

        if ($actual.Count -ne $expected.Count -or $missing.Count -gt 0 -or $unexpected.Count -gt 0) {
            Write-Host 'ERROR: Numeric validation coercion self-test failed.' -ForegroundColor Red
            Write-Host "  Expected fixtures : $($expected -join ', ')" -ForegroundColor Yellow
            Write-Host "  Detected fixtures : $($actual -join ', ')" -ForegroundColor Yellow
            if ($missing.Count -gt 0) { Write-Host "  Missing detections : $($missing -join ', ')" -ForegroundColor Red }
            if ($unexpected.Count -gt 0) { Write-Host "  False positives    : $($unexpected -join ', ')" -ForegroundColor Red }
            $exitCode = 1
        }
        elseif (-not $Quiet) {
            Write-Host "Numeric validation coercion self-test passed: detected $($actual.Count) unsafe fixtures and ignored the safe fixture."
        }
    }
    elseif ($issues.Count -gt 0) {
        if (-not $Quiet) {
            Write-Host 'ERROR: Numeric validation via -as with -is/-isnot can accept blank strings as zero.' -ForegroundColor Red
            foreach ($issue in $issues) {
                Write-Host "  $($issue.Path):$($issue.Line): $($issue.Text)" -ForegroundColor Yellow
            }
            Write-Host 'Use lexical validation or TryParse before converting.' -ForegroundColor Red
        }
        $exitCode = 1
    }
    elseif (-not $Quiet) {
        Write-Host "Numeric validation coercion check passed across $($files.Count) PowerShell source file(s)."
    }
}
finally {
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
