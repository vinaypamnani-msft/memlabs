<#
.SYNOPSIS
    Find swallowed failures that leave a variable unset and then let a decision be
    made on it. Reports ranked candidates for review -- this is an audit, not a gate.

.DESCRIPTION
    An empty catch is not automatically a defect. `try { Remove-Item $tmp } catch { }`
    is fine: nothing downstream depends on it. The dangerous shape is different:

        try { $probe = Get-Something } catch { }
        if ($probe.Count -gt 0) { ... }        # decides on $null, silently

    When the try throws, $probe is never assigned, the catch says nothing, and the
    `if` runs anyway on an unset value. Nothing in the log, no failed exit code, and
    a confident-looking answer derived from a measurement that never happened.

    Compact-Disks.ps1 shipped exactly this: the zero-fill pass caught every
    IOException as "disk full - expected", wrote ZERO bytes, and logged a line
    indistinguishable from success. Common.Validation.Functional.ps1 is the file to
    care about most -- a validator that cannot tell "checked and clean" from
    "could not check" reports a broken build as healthy.

    Ranking:
      HIGH   variable is not pre-initialised, and is later read in a CONDITION
             (if/while/until, comparison, -and/-or). A decision on an unset value.
      MEDIUM variable is not pre-initialised, and is later read somewhere else
             (usually interpolated into a log line). Misreports, does not misroute.
      LOW    variable IS pre-initialised before the try, so the swallow falls back
             to a known value. Usually deliberate. Hidden unless -All.

.PARAMETER Path
    File or directory to scan. Defaults to the vmbuild tree.

.PARAMETER MinimumSeverity
    HIGH (default) or MEDIUM. LOW requires -All.

.PARAMETER All
    Include LOW findings.

.PARAMETER SelfTest
    Run against a built-in fixture with one planted defect per severity and exit
    non-zero if the ranking is wrong. Validates the instrument.

.NOTES
    Known limits, reported rather than hidden:
      * Scope is the nearest enclosing function, else the file. A variable shared
        across functions via script scope may be misjudged as un-initialised.
      * Only plain `$var = ...` assignments are tracked. Property assignments
        (`$obj.Prop = ...`) are ignored -- the object still exists, only the
        property is unset, which is a weaker signal.
      * Assignments made inside a nested scriptblock in the try are attributed to
        the enclosing scope, which can under-report.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path = (Split-Path $PSScriptRoot -Parent),

    [Parameter(Mandatory = $false)]
    [ValidateSet('HIGH', 'MEDIUM')]
    [string]$MinimumSeverity = 'HIGH',

    [Parameter(Mandatory = $false)]
    [switch]$All,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

$autoVars = @('_', 'psitem', 'null', 'true', 'false', 'args', 'input', 'this',
    'pscmdlet', 'psboundparameters', 'matches', 'lastexitcode', 'error',
    'foreach', 'switch', 'ofs', 'pwd', 'host', 'psscriptroot', 'pscommandpath')

$decisionOps = @('Ieq', 'Ine', 'Ige', 'Igt', 'Ile', 'Ilt', 'Ceq', 'Cne', 'Cge', 'Cgt', 'Cle', 'Clt',
    'Imatch', 'Inotmatch', 'Cmatch', 'Cnotmatch', 'Ilike', 'Inotlike', 'Clike', 'Cnotlike',
    'Icontains', 'Inotcontains', 'Ccontains', 'Cnotcontains', 'Iin', 'Inotin', 'Cin', 'Cnotin',
    'Is', 'IsNot', 'And', 'Or', 'Xor')

function Get-Ancestors {
    param($Node)
    $out = @()
    $cur = $Node.Parent
    while ($cur) { $out += $cur; $cur = $cur.Parent }
    return $out
}

function Get-EnclosingScope {
    param($Node, $Root)
    foreach ($a in (Get-Ancestors -Node $Node)) {
        if ($a -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $a }
    }
    return $Root
}

function Get-AssignedVariableName {
    param($Left)
    $target = $Left
    while ($target -is [System.Management.Automation.Language.ConvertExpressionAst] -or
        $target -is [System.Management.Automation.Language.AttributedExpressionAst]) {
        $target = $target.Child
    }
    if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return $target.VariablePath.UserPath
    }
    return $null
}

function Test-IsWriteTarget {
    param($Read)
    $p = $Read.Parent
    while ($p -is [System.Management.Automation.Language.ConvertExpressionAst] -or
        $p -is [System.Management.Automation.Language.AttributedExpressionAst]) {
        $p = $p.Parent
    }
    if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        return ($p.Left.Extent.StartOffset -le $Read.Extent.StartOffset -and
            $p.Left.Extent.EndOffset -ge $Read.Extent.EndOffset)
    }
    # `foreach ($x in ...)` assigns $x; it is not a read of the stale value.
    if ($p -is [System.Management.Automation.Language.ForEachStatementAst]) {
        return ($p.Variable.Extent.StartOffset -eq $Read.Extent.StartOffset)
    }
    return $false
}

function Test-IsDecisionContext {
    param($Read)
    foreach ($a in (Get-Ancestors -Node $Read)) {
        if ($a -is [System.Management.Automation.Language.BinaryExpressionAst]) {
            if ($decisionOps -contains $a.Operator.ToString()) { return $true }
        }
        if ($a -is [System.Management.Automation.Language.UnaryExpressionAst]) {
            if ($a.TokenKind.ToString() -eq 'Not') { return $true }
        }
        if ($a -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $a.Clauses) {
                if ($Read.Extent.StartOffset -ge $clause.Item1.Extent.StartOffset -and
                    $Read.Extent.EndOffset -le $clause.Item1.Extent.EndOffset) { return $true }
            }
        }
        foreach ($loopType in @('WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst')) {
            if ($a.GetType().Name -eq $loopType -and $a.Condition) {
                if ($Read.Extent.StartOffset -ge $a.Condition.Extent.StartOffset -and
                    $Read.Extent.EndOffset -le $a.Condition.Extent.EndOffset) { return $true }
            }
        }
    }
    return $false
}

function Test-IsLoopShadowed {
    # Inside `foreach ($x in ...)` every read of $x is the loop's value, not the stale one.
    param($Read, [string]$Name)
    foreach ($a in (Get-Ancestors -Node $Read)) {
        if ($a -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $a.Variable.VariablePath.UserPath -eq $Name) { return $true }
    }
    return $false
}

function Test-IsUnconditionalConstant {
    # `try { $k = 'literal'; ... }` always assigns before anything can throw.
    param($Assignment, $Try)
    if ($Try.Body.Statements.Count -eq 0) { return $false }
    $first = $Try.Body.Statements[0]
    if ($Assignment.Extent.StartOffset -lt $first.Extent.StartOffset -or
        $Assignment.Extent.EndOffset -gt $first.Extent.EndOffset) { return $false }
    $r = $Assignment.Right
    $expr = $null
    if ($r -is [System.Management.Automation.Language.PipelineAst]) {
        if ($r.PipelineElements.Count -ne 1) { return $false }
        $e = $r.PipelineElements[0]
        if ($e -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $false }
        $expr = $e.Expression
    }
    elseif ($r -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $expr = $r.Expression
    }
    else { return $false }
    return ($expr -is [System.Management.Automation.Language.ConstantExpressionAst])
}

$sources = @()
if ($SelfTest.IsPresent) {
    $fixture = @'
function Test-High {
    try { $probe = Get-Thing } catch { }
    if ($probe.Count -gt 0) { 'yes' }
}
function Test-Medium {
    try { $label = Get-Label } catch { }
    Write-Host "label is $label"
}
function Test-Low {
    $state = 'unknown'
    try { $state = Get-State } catch { }
    if ($state -eq 'ok') { 'fine' }
}
function Test-Benign {
    try { $tmp = Remove-Thing } catch { }
}
function Test-Reassigned {
    try { $r = Get-A } catch { }
    try { $r = Get-B } catch { }
    if ($r) { 'x' }
}
function Test-ConstFirst {
    try { $k = 'literal'; Get-Risky } catch { }
    if ($k) { 'x' }
}
function Test-LoopVar {
    try { $q = Get-Q } catch { }
    foreach ($q in 1..3) { $q.Name }
}
'@
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$null)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    $target = Get-Item -LiteralPath $Path -ErrorAction Stop
    $files = if ($target.PSIsContainer) {
        @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(logs|azureFiles|temp)\\' })
    }
    else {
        @($target)
    }
    foreach ($file in $files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { continue }
        $sources += [pscustomobject]@{ Name = $file.FullName; Ast = $ast }
    }
}

$findings = @()
foreach ($source in $sources) {
    $root = $source.Ast
    $catches = $root.FindAll({ $args[0] -is [System.Management.Automation.Language.CatchClauseAst] }, $true)

    foreach ($catch in $catches) {
        if ($catch.Body.Statements.Count -ne 0) { continue }
        $try = $catch.Parent
        if ($try -isnot [System.Management.Automation.Language.TryStatementAst]) { continue }

        $scope = Get-EnclosingScope -Node $try -Root $root
        $scopeAst = if ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope.Body } else { $scope }

        $paramNames = @()
        if ($scopeAst.ParamBlock) {
            $paramNames = @($scopeAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }

        $assigned = @{}
        foreach ($a in $try.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $name = Get-AssignedVariableName -Left $a.Left
            if (-not $name) { continue }
            if ($autoVars -contains $name.ToLowerInvariant()) { continue }
            if (Test-IsUnconditionalConstant -Assignment $a -Try $try) { continue }
            $assigned[$name] = $true
        }
        if ($assigned.Count -eq 0) { continue }

        $scopeAssignments = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
        $scopeForeach = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))
        $scopeReads = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))

        foreach ($name in $assigned.Keys) {
            $preInit = $paramNames -contains $name
            if (-not $preInit) {
                foreach ($a in $scopeAssignments) {
                    if ($a.Extent.EndOffset -gt $try.Extent.StartOffset) { continue }
                    if ((Get-AssignedVariableName -Left $a.Left) -eq $name) { $preInit = $true; break }
                }
            }
            if (-not $preInit) {
                foreach ($fe in $scopeForeach) {
                    if ($fe.Variable.VariablePath.UserPath -eq $name -and
                        $fe.Extent.StartOffset -lt $try.Extent.StartOffset) { $preInit = $true; break }
                }
            }

            # A read only sees the stale value if nothing reassigned the variable first.
            $nextAssign = [int]::MaxValue
            foreach ($a in $scopeAssignments) {
                if ($a.Extent.StartOffset -lt $try.Extent.EndOffset) { continue }
                if ((Get-AssignedVariableName -Left $a.Left) -ne $name) { continue }
                if ($a.Extent.StartOffset -lt $nextAssign) { $nextAssign = $a.Extent.StartOffset }
            }

            $read = $null
            $decision = $false
            foreach ($r in $scopeReads) {
                if ($r.Extent.StartOffset -lt $try.Extent.EndOffset) { continue }
                if ($r.Extent.StartOffset -ge $nextAssign) { continue }
                if ($r.VariablePath.UserPath -ne $name) { continue }
                if (Test-IsWriteTarget -Read $r) { continue }
                if (Test-IsLoopShadowed -Read $r -Name $name) { continue }
                if (-not $read) { $read = $r }
                if (Test-IsDecisionContext -Read $r) { $read = $r; $decision = $true; break }
            }
            if (-not $read) { continue }

            $severity = if ($preInit) { 'LOW' } elseif ($decision) { 'HIGH' } else { 'MEDIUM' }
            $tryFirst = if ($try.Body.Statements.Count -gt 0) { ($try.Body.Statements[0].Extent.Text -split "`n")[0].Trim() } else { '' }

            $findings += [pscustomobject]@{
                Severity = $severity
                Source   = $source.Name
                Line     = $try.Extent.StartLineNumber
                Variable = '$' + $name
                Try      = if ($tryFirst.Length -gt 90) { $tryFirst.Substring(0, 90) + '...' } else { $tryFirst }
                ReadLine = $read.Extent.StartLineNumber
                ReadText = ($read.Parent.Extent.Text -split "`n")[0].Trim()
            }
        }
    }
}

if ($SelfTest.IsPresent) {
    $expected = @{ 'probe' = 'HIGH'; 'label' = 'MEDIUM'; 'state' = 'LOW' }
    $problems = @()
    foreach ($k in $expected.Keys) {
        $hit = @($findings | Where-Object { $_.Variable -eq ('$' + $k) })
        if ($hit.Count -ne 1) { $problems += "`$$k`: expected 1 finding, got $($hit.Count)"; continue }
        if ($hit[0].Severity -ne $expected[$k]) { $problems += "`$$k`: expected $($expected[$k]), got $($hit[0].Severity)" }
    }
    $benign = @($findings | Where-Object { $_.Variable -eq '$tmp' })
    if ($benign.Count -ne 0) { $problems += "`$tmp is never read afterwards but was reported" }
    $konst = @($findings | Where-Object { $_.Variable -eq '$k' })
    if ($konst.Count -ne 0) { $problems += "`$k is assigned a constant first and cannot be unset, but was reported" }
    $reass = @($findings | Where-Object { $_.Variable -eq '$r' })
    if ($reass.Count -ne 1) { $problems += "`$r: expected 1 finding (the second try only), got $($reass.Count)" }
    $loop = @($findings | Where-Object { $_.Variable -eq '$q' })
    if ($loop.Count -ne 0) { $problems += "`$q is a foreach loop variable (a write), but was reported as a stale read" }

    if ($problems.Count) {
        Write-Host "SELF-TEST FAILED:" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "SELF-TEST PASSED - ranked HIGH/MEDIUM/LOW correctly and ignored the never-read variable." -ForegroundColor Green
    exit 0
}

$order = @{ 'HIGH' = 0; 'MEDIUM' = 1; 'LOW' = 2 }
$wanted = if ($All.IsPresent) { @('HIGH', 'MEDIUM', 'LOW') }
elseif ($MinimumSeverity -eq 'MEDIUM') { @('HIGH', 'MEDIUM') }
else { @('HIGH') }

$shown = @($findings | Where-Object { $wanted -contains $_.Severity } |
        Sort-Object @{ e = { $order[$_.Severity] } }, Source, Line)

Write-Host ""
Write-Host "Scanned $($sources.Count) source(s)." -ForegroundColor Cyan
Write-Host ("  HIGH   {0,5}   unset value reaches a condition" -f @($findings | Where-Object Severity -eq 'HIGH').Count)
Write-Host ("  MEDIUM {0,5}   unset value reaches a log line or other read" -f @($findings | Where-Object Severity -eq 'MEDIUM').Count)
Write-Host ("  LOW    {0,5}   pre-initialised, swallow falls back to a known value" -f @($findings | Where-Object Severity -eq 'LOW').Count)
Write-Host ""

foreach ($f in $shown) {
    $colour = if ($f.Severity -eq 'HIGH') { 'Red' } elseif ($f.Severity -eq 'MEDIUM') { 'Yellow' } else { 'DarkGray' }
    Write-Host ("[{0}] {1}:{2}  {3}" -f $f.Severity, $f.Source, $f.Line, $f.Variable) -ForegroundColor $colour
    Write-Host ("        try   {0}" -f $f.Try) -ForegroundColor DarkGray
    Write-Host ("        L{0}   {1}" -f $f.ReadLine, $f.ReadText) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Showing $($shown.Count) of $($findings.Count) finding(s). These are CANDIDATES, not confirmed" -ForegroundColor Cyan
Write-Host "defects -- each one needs the call site read. Fix by recording the failure in the" -ForegroundColor Cyan
Write-Host "catch, or by giving the variable an explicit value that means 'not measured'." -ForegroundColor Cyan
exit 0
