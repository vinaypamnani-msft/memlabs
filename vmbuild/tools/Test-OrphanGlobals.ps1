<#
.SYNOPSIS
    Flag $global:/$script: variables that are READ but never ASSIGNED, when the
    name looks like a typo of one that IS assigned.

.DESCRIPTION
    Reading an unassigned variable is silent in PowerShell without Set-StrictMode,
    so a misspelling degrades quietly instead of failing. Start-Test.ps1 read
    $global:removeddomains (double d) where every other reference was
    $global:removedomains; the join produced an empty string and a log line ended
    mid-sentence as "Adding pushlab.sandwich.lab to".

    PSScriptAnalyzer cannot catch this. PSUseDeclaredVarsMoreThanAssignments
    flags the opposite case (assigned, never read), and $global: scope opts out
    of that rule entirely.

    "Never assigned" alone is far too noisy -- it hits automatic variables,
    deliberately console-settable debug toggles, and the very common pattern of
    assigning unqualified at script level then reading with an explicit $script:
    prefix. So the report is narrowed to the signal that actually means "typo":
    the unassigned name is within a small edit distance of a name that IS
    assigned. A genuine external toggle resembles nothing and stays silent.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) ''),

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    # Max edit distance from an assigned name for a miss to count as a typo.
    [Parameter(Mandatory = $false)]
    [int]$MaxDistance = 2,

    # Short names collide by chance; only consider names at least this long.
    [Parameter(Mandatory = $false)]
    [int]$MinLength = 5
)

# Automatic variables are provided by the engine and never assigned by us.
$automatic = @(
    'Error', 'args', 'input', 'PSItem', '_', 'this', 'true', 'false', 'null',
    'PSVersionTable', 'PSScriptRoot', 'PSCommandPath', 'MyInvocation', 'Host',
    'PID', 'PWD', 'HOME', 'LASTEXITCODE', 'matches', 'foreach', 'switch',
    'StackTrace', 'ExecutionContext', 'PSBoundParameters', 'PSCmdlet',
    'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'ProgressPreference',
    'ErrorActionPreference', 'WarningPreference', 'VerbosePreference',
    'DebugPreference', 'InformationPreference', 'ConfirmPreference',
    'PSDefaultParameterValues', 'PSNativeCommandUseErrorActionPreference'
)

function Get-EditDistance {
    param([string]$A, [string]$B)
    $la = $A.Length; $lb = $B.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    # Only two rows are ever needed.
    $prev = New-Object 'int[]' ($lb + 1)
    $cur = New-Object 'int[]' ($lb + 1)
    for ($j = 0; $j -le $lb; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $la; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $lb; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $cur[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $cur[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$lb]
}

$assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$readHits = @{}

$files = @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(logs|azureFiles)\\' })

foreach ($file in $files) {
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { continue }

    # Any assignment establishes the name. Scope is deliberately ignored: a
    # script-level "$out = ..." is what later "$script:out" reads, and treating
    # those as different names is the single biggest source of false positives.
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        foreach ($v in $node.Left.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            # Extra parens are load-bearing: inside a method call the comma in
            # "-replace 'a', ''" binds as an ARGUMENT separator, so Add() gets two.
            $null = $assigned.Add(($v.VariablePath.UserPath -replace '^(global|script|local|private):', ''))
        }
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $null = $assigned.Add(($node.Variable.VariablePath.UserPath -replace '^(global|script|local|private):', ''))
    }
    # $x++ / $x-- establish nothing new but do imply the name exists.
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.UnaryExpressionAst] }, $true)) {
        foreach ($v in $node.Child.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $null = $assigned.Add(($v.VariablePath.UserPath -replace '^(global|script|local|private):', ''))
        }
    }
    # param() blocks and Set-Variable -Name 'x'
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        $null = $assigned.Add(($node.Name.VariablePath.UserPath -replace '^(global|script|local|private):', ''))
    }
    foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cmd = $node.GetCommandName()
        if ($cmd -in @('Set-Variable', 'New-Variable')) {
            $elems = $node.CommandElements
            for ($i = 1; $i -lt $elems.Count; $i++) {
                if ($elems[$i] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $null = $assigned.Add(($elems[$i].Value -replace '^(global|script|local|private):', ''))
                    break
                }
            }
        }
    }

    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $p = $v.VariablePath
        if (-not ($p.IsGlobal -or $p.IsScript)) { continue }
        $bare = $p.UserPath -replace '^(global|script|local|private):', ''
        if (-not $readHits.ContainsKey($bare)) { $readHits[$bare] = @() }
        $readHits[$bare] += "$($file.FullName):$($v.Extent.StartLineNumber)"
    }
}

$assignedList = @($assigned)
$findings = @()
foreach ($name in ($readHits.Keys | Sort-Object)) {
    if ($assigned.Contains($name)) { continue }
    if ($automatic -contains $name) { continue }
    if ($name.Length -lt $MinLength) { continue }

    $best = $null
    $bestDist = [int]::MaxValue
    foreach ($cand in $assignedList) {
        if ([Math]::Abs($cand.Length - $name.Length) -gt $MaxDistance) { continue }
        $d = Get-EditDistance -A $name -B $cand
        if ($d -lt $bestDist) { $bestDist = $d; $best = $cand }
    }
    if ($best -and $bestDist -ge 1 -and $bestDist -le $MaxDistance) {
        $findings += [pscustomobject]@{
            Name       = $name
            LooksLike  = $best
            Distance   = $bestDist
            References = $readHits[$name]
        }
    }
}

if (-not $Quiet) {
    Write-Host "Scanned $($files.Count) file(s); $($readHits.Keys.Count) global/script name(s) read, $($assigned.Count) assigned."
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no global/script variable is read under a name that looks like a typo." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: global/script variable read but never assigned, and the name closely matches one that is:" -ForegroundColor Red
foreach ($f in $findings) {
    Write-Host ""
    Write-Host ("  `$$($f.Name)  ->  did you mean `$$($f.LooksLike)?  (edit distance $($f.Distance))") -ForegroundColor Red
    foreach ($r in ($f.References | Select-Object -First 5)) { Write-Host "      $r" -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host "Reading an unassigned variable is silent -- it yields `$null, so strings render empty." -ForegroundColor Yellow
exit 1
