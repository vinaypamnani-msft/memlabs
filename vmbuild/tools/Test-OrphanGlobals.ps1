<#
.SYNOPSIS
    Flag variables that are READ but never ASSIGNED when the name looks like a
    typo of one that IS assigned.

.DESCRIPTION
    Reading an unassigned variable is silent in PowerShell without Set-StrictMode,
    so a misspelling degrades quietly instead of failing. Start-Test.ps1 read
    $global:removeddomains (double d) where every other reference was
    $global:removedomains; the join produced an empty string and a log line ended
    mid-sentence as "Adding pushlab.sandwich.lab to".

    PSScriptAnalyzer cannot catch this. PSUseDeclaredVarsMoreThanAssignments
    flags the opposite case (assigned, never read), and $global: scope opts out
    of that rule entirely.

    All $global:/$script: reads are checked. Unqualified/local reads are checked
    when they occur inside an expandable string, where an undefined name silently
    removes user-visible text. "Never assigned" alone is far too noisy -- it hits
    automatic variables, deliberately console-settable debug toggles, and values
    supplied by dot-sourced caller scope. So the report is narrowed to the signal
    that actually means "typo": the unassigned name is within a small edit distance
    of a name that IS assigned. A genuine external toggle resembles nothing and
    stays silent.
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
    [int]$MinLength = 5,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
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

function Get-BareVariableName {
    param([System.Management.Automation.Language.VariableExpressionAst]$Variable)

    $userPath = $Variable.VariablePath.UserPath
    if ($userPath -match '^(env|variable|function|alias|using|workflow):' -or $userPath -match '^[A-Za-z]:') {
        return $null
    }
    return ($userPath -replace '^(global|script|local|private):', '')
}

$assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$readHits = @{}

$sources = @()
if ($SelfTest.IsPresent) {
    $fixture = @'
$global:removedomains = @()
$Description = 'network'
"Cleanup list: $($global:removeddomains -join ', ')"
"Remove $Description?"
'@
    $tokens = $null
    $parseErrors = $null
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$tokens, [ref]$parseErrors)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    $files = @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(logs|azureFiles)\\' })
    foreach ($file in $files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        $sources += [pscustomobject]@{ Name = $file.FullName; Ast = $ast }
    }
}

foreach ($source in $sources) {
    $ast = $source.Ast

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
        $elems = $node.CommandElements
        for ($i = 1; $i -lt $elems.Count - 1; $i++) {
            $element = $elems[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -notin @('ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'PipelineVariable')) { continue }
            $valueElement = $elems[$i + 1]
            if ($valueElement -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $null = $assigned.Add(($valueElement.Value -replace '^\+', '' -replace '^(global|script|local|private):', ''))
            }
        }
        if ($node.GetCommandName() -in @('Set-Variable', 'New-Variable')) {
            for ($i = 1; $i -lt $elems.Count; $i++) {
                if ($elems[$i] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $null = $assigned.Add(($elems[$i].Value -replace '^(global|script|local|private):', ''))
                    break
                }
            }
        }
    }

    $interpolatedOffsets = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($expandableString in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        foreach ($nestedExpression in $expandableString.NestedExpressions) {
            if ($nestedExpression -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $null = $interpolatedOffsets.Add($nestedExpression.Extent.StartOffset)
            }
            foreach ($variable in $nestedExpression.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $null = $interpolatedOffsets.Add($variable.Extent.StartOffset)
            }
        }
    }

    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $p = $v.VariablePath
        if (-not ($p.IsGlobal -or $p.IsScript) -and -not $interpolatedOffsets.Contains($v.Extent.StartOffset)) { continue }
        $bare = Get-BareVariableName -Variable $v
        if (-not $bare) { continue }
        if (-not $readHits.ContainsKey($bare)) { $readHits[$bare] = @() }
        $readHits[$bare] += "$($source.Name):$($v.Extent.StartLineNumber)"
    }
}

$assignedList = @($assigned)
$findings = @()
# Hashtable keys named Keys or Count shadow the adapted properties; PSBase
# guarantees that the collector cannot hide its own contents.
foreach ($name in ($readHits.PSBase.Keys | Sort-Object)) {
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
    Write-Host "Scanned $($sources.Count) source(s); $($readHits.PSBase.Count) scoped/interpolated name(s) read, $($assigned.Count) assigned."
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no scoped/interpolated variable is read under a name that looks like a typo." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: variable read but never assigned, and the name closely matches one that is:" -ForegroundColor Red
foreach ($f in $findings) {
    Write-Host ""
    Write-Host ("  `$$($f.Name)  ->  closest assigned name: `$$($f.LooksLike)  (edit distance $($f.Distance))") -ForegroundColor Red
    foreach ($r in ($f.References | Select-Object -First 5)) { Write-Host "      $r" -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host "Reading an unassigned variable is silent -- it yields `$null and can erase interpolated text." -ForegroundColor Yellow
exit 1
