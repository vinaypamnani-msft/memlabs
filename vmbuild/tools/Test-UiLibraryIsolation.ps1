# Guards the -InJob library gate in Common.ps1.
#
# Common.ps1 skips the config-wizard / menu / RDP-client libraries when loaded inside a
# job. If job-reachable code ever calls a function those files define, the job dies on a
# CommandNotFoundException -- which PowerShell reports quietly under default preferences,
# inside a background job, where nobody is reading. This computes what a job can actually
# execute and fails the commit if any of it lives behind the gate.
#
# Detects static call edges only. A dynamic dispatch (& $name) into a gated function is
# invisible here, so keep the gated set to host-only UI code.
[CmdletBinding()]
param(
    [string]$Repo = (Join-Path (Split-Path -Parent $PSScriptRoot) ''),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$commonPs1 = Join-Path $Repo 'Common.ps1'
$commonDir = Join-Path $Repo 'common'
if (-not (Test-Path -LiteralPath $commonPs1)) { Write-Host "[Test-UiLibraryIsolation] cannot find $commonPs1" -ForegroundColor Red; exit 2 }

function Get-FileAst {
    param([string]$Path)
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) { Write-Host "[Test-UiLibraryIsolation] parse errors in $Path" -ForegroundColor Red; exit 2 }
    $ast
}

# 1. Which files does Common.ps1 load only when NOT in a job?
$rootAst = Get-FileAst $commonPs1
# Ordinal-ignore-case: the dot-source text says Common.menu.ps1 while the file on disk is
# Common.Menu.ps1, and a case-sensitive set silently treats that file as ungated.
$gated = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
foreach ($ifAst in $rootAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
    foreach ($clause in $ifAst.Clauses) {
        if ($clause.Item1.Extent.Text -notmatch '-not\s+\$InJob') { continue }
        foreach ($cmd in $clause.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $txt = $cmd.Extent.Text
            if ($txt -match '([\w.]+\.ps1)') { [void]$gated.Add($Matches[1]) }
        }
    }
}

if ($gated.Count -eq 0) {
    Write-Host '[Test-UiLibraryIsolation] no gated libraries found - nothing to check.'
    exit 0
}

# 2. Function definitions and their call edges across the host codebase.
$files = @(Get-ChildItem -LiteralPath $commonDir -Filter '*.ps1' -File)
$files += Get-Item -LiteralPath $commonPs1

$defs = @{}
$calls = @{}
$entry = New-Object System.Collections.Generic.HashSet[string]

foreach ($f in $files) {
    $ast = Get-FileAst $f.FullName
    $isGated = $gated.Contains($f.Name)

    $fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($fn in $fnAsts) {
        $defs[$fn.Name] = $f.Name
        $calls[$fn.Name] = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    # Load-time code runs in a job too -- but not for a file the job never loads.
    if ($isGated) { continue }
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if (-not $name) { continue }
        $inFn = $false
        foreach ($fn in $fnAsts) {
            if ($cmd.Extent.StartOffset -ge $fn.Extent.StartOffset -and $cmd.Extent.EndOffset -le $fn.Extent.EndOffset) { $inFn = $true; break }
        }
        if (-not $inFn) { [void]$entry.Add($name) }
    }

    # Every scriptblock that bootstraps Common.ps1 -InJob is a job entry point.
    if ($f.Name -eq 'Common.ScriptBlocks.ps1') {
        foreach ($sb in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
            if ($sb.Extent.Text -notmatch 'Common\.ps1\s+-InJob') { continue }
            foreach ($c in $sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $n2 = $c.GetCommandName()
                if ($n2) { [void]$entry.Add($n2) }
            }
        }
    }
}

if ($SelfTest) {
    # Prove the detector fires: seed a call to a function that lives behind the gate.
    $victim = $defs.GetEnumerator() | Where-Object { $gated.Contains($_.Value) } | Select-Object -First 1
    if (-not $victim) { Write-Host '[Test-UiLibraryIsolation] SELFTEST: no gated function to seed' -ForegroundColor Red; exit 2 }
    [void]$entry.Add($victim.Key)
    Write-Host ("[Test-UiLibraryIsolation] SELFTEST: seeded a call to {0} ({1})" -f $victim.Key, $victim.Value) -ForegroundColor Yellow
}

# 3. Transitive closure of what a job can execute.
$seen = @{}
$queue = New-Object System.Collections.Queue
foreach ($n in $entry) { $queue.Enqueue($n) }
while ($queue.Count -gt 0) {
    $n = $queue.Dequeue()
    if ($seen.ContainsKey($n)) { continue }
    $seen[$n] = $true
    if ($calls.ContainsKey($n)) {
        foreach ($c in $calls[$n]) { if (-not $seen.ContainsKey($c)) { $queue.Enqueue($c) } }
    }
}

# Callers that already guard with Get-Command before invoking, so absence is handled.
$allowed = @('Get-LiveWindowSize', 'Initialize-MenuConsoleInterop')

$violations = @()
foreach ($name in $seen.Keys) {
    if (-not $defs.ContainsKey($name)) { continue }
    if (-not $gated.Contains($defs[$name])) { continue }
    if ($allowed -contains $name) { continue }
    $violations += [pscustomobject]@{ Function = $name; File = $defs[$name] }
}

if ($violations.Count -gt 0) {
    Write-Host ''
    Write-Host '[Test-UiLibraryIsolation] FAILED - job-reachable code calls a host-only function:' -ForegroundColor Red
    foreach ($v in ($violations | Sort-Object File, Function)) {
        Write-Host ("    {0,-40} defined in {1}" -f $v.Function, $v.File) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  A job does not load that file, so this is a CommandNotFoundException at run time.' -ForegroundColor Red
    Write-Host '  Fix: move the function into a non-gated file, or stop calling it from job-reachable code.' -ForegroundColor Red
    exit 1
}

Write-Host ("[Test-UiLibraryIsolation] OK - {0} gated file(s), {1} job-reachable function(s), no leaks." -f $gated.Count, $seen.Count)
exit 0
