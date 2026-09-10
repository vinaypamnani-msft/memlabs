[CmdletBinding()]
param (
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = (& git rev-parse --show-toplevel).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) { throw 'Could not resolve repository root.' }
}

function Invoke-GitBinary {
    param ([string[]] $Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [System.IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'git.exe did not start.' }
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode      = $process.ExitCode
            Bytes         = $memory.ToArray()
            StandardError = $standardError
        }
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function ConvertFrom-GitNameStatus {
    param ([byte[]] $Bytes)

    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    $tokens = @($text.Split([char] 0, [System.StringSplitOptions]::RemoveEmptyEntries))
    $changes = @()
    $index = 0
    while ($index -lt $tokens.Count) {
        $status = $tokens[$index]
        $index++
        if ($status -match '^[RC]') {
            if (($index + 1) -ge $tokens.Count) { throw "Incomplete Git rename/copy record for status '$status'." }
            $sourcePath = $tokens[$index]
            $destinationPath = $tokens[$index + 1]
            $index += 2
        }
        else {
            if ($index -ge $tokens.Count) { throw "Incomplete Git change record for status '$status'." }
            $sourcePath = $null
            $destinationPath = $tokens[$index]
            $index++
        }
        $changes += [pscustomobject]@{ Status = $status; SourcePath = $sourcePath; DestinationPath = $destinationPath }
    }
    return $changes
}

function Get-StagedChanges {
    $result = Invoke-GitBinary -Arguments @('diff', '--cached', '--find-renames', '--name-status', '-z', '--')
    if ($result.ExitCode -ne 0) { throw "Could not enumerate staged changes: $($result.StandardError)" }
    return @(ConvertFrom-GitNameStatus -Bytes $result.Bytes)
}

function Get-StagedBytes {
    param ([string] $Path)
    $result = Invoke-GitBinary -Arguments @('cat-file', 'blob', ":$Path")
    if ($result.ExitCode -ne 0) { throw "Could not read staged blob '$Path': $($result.StandardError)" }
    return $result.Bytes
}

$changes = @(Get-StagedChanges)
$paths = @($changes | Where-Object { $_.Status -notmatch '^D' } | ForEach-Object { $_.DestinationPath })
$failures = [System.Collections.Generic.List[string]]::new()
$powerShellCount = 0

foreach ($change in $changes) {
    if ($change.Status -match '^D') { continue }
    $touchesSensitivePath = @($change.SourcePath, $change.DestinationPath | Where-Object { $_ }) |
        Where-Object { $_.Replace('\', '/').StartsWith('vmbuild/azureFiles/', [System.StringComparison]::OrdinalIgnoreCase) }
    if ($touchesSensitivePath) {
        $failures.Add("$($change.DestinationPath): files under vmbuild/azureFiles must never be added, modified, or renamed")
    }
}

foreach ($path in $paths) {
    if ([System.IO.Path]::GetExtension($path) -notin @('.ps1', '.psm1', '.psd1')) { continue }
    $powerShellCount++
    $bytes = @(Get-StagedBytes -Path $path)
    $hasBom = $bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom -and @($bytes | Where-Object { $_ -gt 0x7F }).Count -gt 0) {
        $failures.Add("${path}: BOM-less PowerShell files must contain ASCII only")
        continue
    }

    $offset = if ($hasBom) { 3 } else { 0 }
    $content = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Count - $offset)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, $path, [ref] $tokens, [ref] $parseErrors)
    foreach ($parseError in @($parseErrors | Where-Object { $_.ErrorId -ne 'ModuleNotFoundDuringParse' })) {
        $failures.Add("${path}:$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }

    foreach ($assignment in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)) {
        foreach ($variable in $assignment.Left.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)) {
            $automaticName = $variable.VariablePath.UserPath -replace '^(global|script|local|private):', ''
            if ($automaticName -in @('IsLinux', 'IsWindows', 'IsMacOS')) {
                $failures.Add("${path}:$($variable.Extent.StartLineNumber): assignment to PS7 read-only automatic variable `$$($variable.VariablePath.UserPath)")
            }
        }
    }

    $casingExtents = [System.Collections.Generic.List[object]]::new()
    foreach ($call in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.Member.Value -in @('ToLower', 'ToUpper') -and
                $node.Arguments.Count -eq 0
            }, $true)) {
        $casingExtents.Add([pscustomobject]@{ Start = $call.Extent.StartOffset; End = $call.Extent.EndOffset })
        $failures.Add("${path}:$($call.Extent.StartLineNumber): culture-sensitive parameterless $($call.Member.Value) call")
    }

        foreach ($match in [regex]::Matches($content, '\.(?:ToLower|ToUpper)\s*\(\s*\)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
        $coveredByAst = @($casingExtents | Where-Object {
            $_.Start -le $match.Index -and $_.End -ge ($match.Index + $match.Length)
            }).Count -gt 0
        if ($coveredByAst) { continue }
        $comment = @($tokens | Where-Object {
                $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and
                $_.Extent.StartOffset -le $match.Index -and $_.Extent.EndOffset -ge ($match.Index + $match.Length)
            })
        if ($comment.Count -gt 0) { continue }
        $line = 1 + ([regex]::Matches($content.Substring(0, $match.Index), "`n")).Count
        $failures.Add("${path}:${line}: culture-sensitive parameterless casing in generated or partially parsed code")
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'ERROR: staged-file safety check failed:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Fast staged checks: PASS ($($paths.Count) changed path(s), $powerShellCount PowerShell file(s))."
