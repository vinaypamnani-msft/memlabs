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

    Pre-initialisation is NOT treated as a fallback when the try and the read are in
    the same loop AND nothing re-seeds the variable inside that loop before the try.
    There the prior value is last iteration's answer, not a default, so a failed refresh
    republishes stale data as current. That is how the real defect in
    InstallAndUpdateSCCM.ps1 hid: a swallowed Get-CMSiteUpdate left $updatepack frozen,
    and the stuck-state timer read "State unchanged" from a state it had not read.
    A `$x = $null` immediately before the try re-seeds every pass and is safe; that shape
    is common in this repo and an earlier version of the rule wrongly flagged 104 of them.

    Which catches count as swallowing (shape, reported per finding):
      empty         no statements at all.
      silent        has a body, but no report and no throw/return/continue/break.
      verbose-only  reports only through Write-Verbose / Write-Debug, both off by
                    default on this repo's dispatch paths, so the message is discarded.
    A catch that throws or diverts control flow is not analysed: the read below it is
    not reached on the failure path.

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
    Reporting calls are DERIVED per source, not guessed. Most of this repo reports from
    inside a catch through short local helpers -- _Log, _R, _Add, _Progress, W -- that
    append to a collection and match no Write-* rule. A tally of every command appearing
    in a non-empty catch body put those five in the top ten, so a hardcoded list would
    have mislabelled 166 reporting catches as silent.

    Known limits, reported rather than hidden:
      * Scope is the nearest enclosing function, else the file. A variable shared
        across functions via script scope may be misjudged as un-initialised.
      * Only plain `$var = ...` assignments are tracked. Property assignments
        (`$obj.Prop = ...`) are ignored -- the object still exists, only the
        property is unset, which is a weaker signal.
      * Assignments made inside a nested scriptblock in the try are ignored: the try
        throwing says nothing about whether a deferred -Action block ran.
      * ForEach-Object is a pipeline, not a LoopStatementAst, so the stale-in-loop
        rule does not apply inside one.
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

$quietCmds = @('write-verbose', 'write-debug')
$reportCmds = @('out-file', 'out-host', 'add-content', 'set-content', 'add-uilog',
    'add-result', 'add-validationmessage')

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

function Get-AssignmentRhsExpression {
    param($Assignment)
    $r = $Assignment.Right
    if ($r -is [System.Management.Automation.Language.PipelineAst]) {
        if ($r.PipelineElements.Count -ne 1) { return $null }
        $e = $r.PipelineElements[0]
        if ($e -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
        return $e.Expression
    }
    if ($r -is [System.Management.Automation.Language.CommandExpressionAst]) { return $r.Expression }
    return $null
}

function Test-AssignsLiteral {
    # $true / $false / $null parse as VariableExpressionAst, not ConstantExpressionAst.
    param($Assignment)
    $expr = Get-AssignmentRhsExpression -Assignment $Assignment
    if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $true }
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return ($autoVars -contains $expr.VariablePath.UserPath.ToLowerInvariant())
    }
    return $false
}

function Test-IsUnconditionalConstant {
    # `try { $k = 'literal'; ... }` always assigns before anything can throw. Must BE the
    # first statement, not merely sit inside it -- an assignment nested in a leading `if`
    # is conditional.
    param($Assignment, $Try)
    if ($Try.Body.Statements.Count -eq 0) { return $false }
    $first = $Try.Body.Statements[0]
    if ($Assignment.Extent.StartOffset -ne $first.Extent.StartOffset -or
        $Assignment.Extent.EndOffset -ne $first.Extent.EndOffset) { return $false }
    return (Test-AssignsLiteral -Assignment $Assignment)
}

function Get-LocalReporterNames {
    # `function _Log($m) { $report.Add($m) }` is how most of this repo reports from a
    # catch. Small one-liners only -- a large function that happens to log somewhere
    # inside it is not a reporting call.
    param($Root)
    $names = @{}
    foreach ($fn in $Root.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $body = $fn.Body.EndBlock
        if (-not $body -or $body.Statements.Count -gt 4) { continue }
        $writes = @($fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $_ -match '^[Ww]rite-' })
        $adds = @($fn.Body.FindAll({
                    $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    "$($args[0].Member)" -eq 'Add'
                }, $true))
        if ($writes.Count -or $adds.Count) { $names[$fn.Name.ToLowerInvariant()] = $true }
    }
    return $names
}

function Get-CatchShape {
    # Returns empty / silent / verbose-only, or $null when the catch is not a swallow.
    param($Catch, $Reporters)
    if ($Catch.Body.Statements.Count -eq 0) { return 'empty' }

    # A throw or a control-flow exit means the read below the try is never reached on
    # the failure path, so there is no stale value to decide on.
    $exits = @($Catch.Body.FindAll({
                $args[0] -is [System.Management.Automation.Language.ThrowStatementAst] -or
                $args[0] -is [System.Management.Automation.Language.ReturnStatementAst] -or
                $args[0] -is [System.Management.Automation.Language.ContinueStatementAst] -or
                $args[0] -is [System.Management.Automation.Language.BreakStatementAst] -or
                $args[0] -is [System.Management.Automation.Language.ExitStatementAst]
            }, $true))
    if ($exits.Count) { return $null }

    $names = @($Catch.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $loud = @($names | Where-Object {
            ($_ -match '^write-' -and $quietCmds -notcontains $_) -or
            $reportCmds -contains $_ -or $Reporters.ContainsKey($_)
        })
    if ($loud.Count) { return $null }

    # `catch { $results.Details.Add("FAIL: ...") }` is how the validation engine reports.
    # It is a method call, not a command, so no Write-* rule sees it.
    $adds = @($Catch.Body.FindAll({
                $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                "$($args[0].Member)" -eq 'Add'
            }, $true))
    if ($adds.Count) { return $null }

    if (@($names | Where-Object { $quietCmds -contains $_ }).Count) { return 'verbose-only' }
    return 'silent'
}

function Get-EnclosingLoop {
    param($Node)
    foreach ($a in (Get-Ancestors -Node $Node)) {
        if ($a -is [System.Management.Automation.Language.LoopStatementAst]) { return $a }
        if ($a -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $null }
    }
    return $null
}

function Test-IsUnconditionalInTry {
    # A value the try assigns only under an `if` is already expected to be absent
    # sometimes, so carrying the previous one is the design, not a failed refresh.
    # `while (-not $tcpUp) { try { if ($sock.Connected) { $tcpUp = $true } } catch {} }`
    # is a retry latch; `try { $pack = Get-Pack }` in a poll loop is a snapshot.
    param($Assignment, $Try)
    foreach ($a in (Get-Ancestors -Node $Assignment)) {
        if ($a -is [System.Management.Automation.Language.TryStatementAst]) { break }
        if ($a -is [System.Management.Automation.Language.IfStatementAst] -or
            $a -is [System.Management.Automation.Language.SwitchStatementAst] -or
            $a -is [System.Management.Automation.Language.LoopStatementAst]) { return $false }
    }
    return $true
}

function Test-IsInNestedScriptBlock {
    # `try { Register-EngineEvent -Action { $t = $null } } catch {}` -- the assignment runs
    # at engine exit, not in the try's flow, so the try throwing says nothing about it.
    # Must stop at THIS try: stopping at the first try found lands on an inner one and
    # wrongly reports the assignment as belonging to the outer try as well.
    param($Assignment, $Try)
    foreach ($a in (Get-Ancestors -Node $Assignment)) {
        if ($a -eq $Try) { return $false }
        if ($a -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }
    }
    return $false
}

function Get-EnclosingScriptBlock {
    # The scriptblock a try lives in, if any. Code outside it runs at a different time,
    # so it cannot observe what the swallowed failure left behind.
    param($Node, $ScopeAst)
    foreach ($a in (Get-Ancestors -Node $Node)) {
        if ($a -eq $ScopeAst) { break }
        if ($a -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
        if ($a -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $a }
    }
    return $null
}

function Test-ReadGuardsLoopExit {
    # `foreach ($k in $keys) { try { $v = Get-Thing $k } catch {}; if ($v) { break } }`
    # -- a good value ends the loop, so no later iteration can observe a stale one. This
    # "try each candidate until one works" shape accounted for 10 of 18 HIGH findings.
    # The guard must be a BARE truthiness test of this variable: with `if ($v -eq 'ok')`
    # a different successful value is still carried forward, which is the defect.
    param($Read, $Loop)
    foreach ($a in (Get-Ancestors -Node $Read)) {
        if ($a.Extent.StartOffset -lt $Loop.Extent.StartOffset) { break }
        if ($a -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }

        $bare = $false
        foreach ($clause in $a.Clauses) {
            if ($Read.Extent.StartOffset -lt $clause.Item1.Extent.StartOffset -or
                $Read.Extent.EndOffset -gt $clause.Item1.Extent.EndOffset) { continue }
            $expr = $null
            $cond = $clause.Item1
            if ($cond -is [System.Management.Automation.Language.PipelineAst] -and
                $cond.PipelineElements.Count -eq 1 -and
                $cond.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $expr = $cond.PipelineElements[0].Expression
            }
            if ($expr -is [System.Management.Automation.Language.UnaryExpressionAst] -and
                "$($expr.TokenKind)" -eq 'Not') { $expr = $expr.Child }
            if ($expr -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $expr.Extent.StartOffset -eq $Read.Extent.StartOffset) { $bare = $true }
        }
        if (-not $bare) { continue }

        foreach ($exit in $a.FindAll({
                    $args[0] -is [System.Management.Automation.Language.BreakStatementAst] -or
                    $args[0] -is [System.Management.Automation.Language.ReturnStatementAst]
                }, $true)) {
            if ($exit -is [System.Management.Automation.Language.ReturnStatementAst]) { return $true }
            # a break belonging to an inner loop does not end this one
            if ((Get-EnclosingLoop -Node $exit) -eq $Loop) { return $true }
        }
    }
    return $false
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
function Test-SilentBody {
    try { $s = Get-S } catch { Start-Sleep -Seconds 1 }
    if ($s) { 'x' }
}
function Test-ReportingBody {
    try { $rep = Get-R } catch { Write-Host "failed: $_" }
    if ($rep) { 'x' }
}
function Test-LocalReporter {
    function _Log($m) { $log.Add($m) }
    try { $lr = Get-L } catch { _Log "failed" }
    if ($lr) { 'x' }
}
function Test-CatchAssigns {
    try { $ca = Get-C } catch { $ca = $null }
    if ($ca) { 'x' }
}
function Test-CatchReturns {
    try { $cr = Get-C } catch { return }
    if ($cr) { 'x' }
}
function Test-LoopStale {
    $ls = 'seed'
    while ($true) {
        try { $ls = Get-Fresh } catch { Start-Sleep -Seconds 1 }
        if ($ls -eq 'ok') { break }
    }
}
function Test-LoopReseeded {
    $rs = 'seed'
    while ($true) {
        $rs = $null
        try { $rs = Get-Fresh } catch { Start-Sleep -Seconds 1 }
        if ($rs -eq 'ok') { break }
    }
}
function Test-LoopLatch {
    $lt = $false
    while (-not $lt) {
        try { if (Get-Ready) { $lt = $true } } catch { Start-Sleep -Seconds 1 }
        if (-not $lt) { Start-Sleep -Seconds 1 }
    }
}
function Test-LoopStaleAbove {
    $sa = 'seed'
    while ($sa -ne 'ok') {
        Start-Sleep -Seconds 1
        try { $sa = Get-Fresh } catch { Start-Sleep -Seconds 1 }
    }
}
function Test-LoopFlag {
    $fl = $false
    $n = 0
    while ($n -lt 3) {
        $n++
        try { Get-Thing | Out-Null; $fl = $true } catch { Start-Sleep -Seconds 1 }
        if ($fl -eq $true) { Start-Sleep -Seconds 1 }
    }
}
function Test-LoopBreaksOnSuccess {
    $bs = $null
    foreach ($k in 1..2) {
        try { $bs = Get-Thing $k } catch { Start-Sleep -Seconds 1 }
        if ($bs) { break }
    }
}
function Test-CatchAdds {
    $sink = New-Object System.Collections.Generic.List[string]
    try { $cad = Get-C } catch { $sink.Add("failed: $_") }
    if ($cad) { 'x' }
}
function Test-DeferredScriptBlock {
    try { Register-Thing -Action { $dsb = 'set at exit' } } catch { }
    if ($dsb) { 'x' }
}
function Test-ReadOutsideScriptBlock {
    Register-Thing -Action { try { $ros = Get-Thing } catch { } }
    if ($ros) { 'x' }
}
'@
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$null)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    $target = Get-Item -LiteralPath $Path -ErrorAction Stop
    $files = if ($target.PSIsContainer) {
        # Anchored to the scan root: an unanchored '\temp\' also matches the user's
        # AppData\Local\Temp, silently excluding a baseline extracted there to test this.
        $root = $target.FullName.TrimEnd('\')
        @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Substring($root.Length).TrimStart('\') -notmatch '^(logs|logs2|azureFiles|temp)\\' })
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
    $reporters = Get-LocalReporterNames -Root $root

    foreach ($catch in $catches) {
        $shape = Get-CatchShape -Catch $catch -Reporters $reporters
        if (-not $shape) { continue }
        $try = $catch.Parent
        if ($try -isnot [System.Management.Automation.Language.TryStatementAst]) { continue }

        $scope = Get-EnclosingScope -Node $try -Root $root
        $scopeAst = if ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope.Body } else { $scope }

        $paramNames = @()
        if ($scopeAst.ParamBlock) {
            $paramNames = @($scopeAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }

        $assigned = @{}
        $refreshed = @{}
        foreach ($a in $try.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $name = Get-AssignedVariableName -Left $a.Left
            if (-not $name) { continue }
            if ($autoVars -contains $name.ToLowerInvariant()) { continue }
            if (Test-IsUnconditionalConstant -Assignment $a -Try $try) { continue }
            if (Test-IsInNestedScriptBlock -Assignment $a -Try $try) { continue }
            $assigned[$name] = $true
            if (-not $refreshed.ContainsKey($name)) { $refreshed[$name] = $false }
            # `$ok = $true` is a success flag: carrying the old value means "still not
            # succeeded", which is correct. Only a value read back from somewhere goes stale.
            if ((Test-IsUnconditionalInTry -Assignment $a -Try $try) -and
                -not (Test-AssignsLiteral -Assignment $a)) { $refreshed[$name] = $true }
        }
        # `catch { $x = $null }` sets the variable, so the read below is not a stale one.
        foreach ($a in $catch.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $name = Get-AssignedVariableName -Left $a.Left
            if ($name) { $assigned.Remove($name) }
        }
        if ($assigned.Count -eq 0) { continue }

        $scopeAssignments = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
        $scopeForeach = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))
        $scopeReads = @($scopeAst.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
        $sbScope = Get-EnclosingScriptBlock -Node $try -ScopeAst $scopeAst

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

            # A read ABOVE the try still sees the stale value from iteration 2 onwards, so
            # for a stale candidate the window is the whole loop, not just after the try.
            $loop = Get-EnclosingLoop -Node $try
            $loopStale = $false
            if ($loop -and $refreshed[$name]) {
                $loopStale = $true
                foreach ($a in $scopeAssignments) {
                    if ($a.Extent.EndOffset -gt $try.Extent.StartOffset) { continue }
                    if ($a.Extent.StartOffset -lt $loop.Extent.StartOffset) { continue }
                    if ((Get-AssignedVariableName -Left $a.Left) -ne $name) { continue }
                    $loopStale = $false
                    break
                }
                if ($loopStale -and $loop -is [System.Management.Automation.Language.ForEachStatementAst] -and
                    $loop.Variable.VariablePath.UserPath -eq $name) { $loopStale = $false }
            }
            $windowStart = if ($loopStale) { $loop.Extent.StartOffset } else { $try.Extent.EndOffset }

            $read = $null
            $decision = $false
            foreach ($r in $scopeReads) {
                if ($r.Extent.StartOffset -lt $windowStart) { continue }
                if ($r.Extent.StartOffset -ge $nextAssign) { continue }
                if ($r.VariablePath.UserPath -ne $name) { continue }
                if ($sbScope -and ($r.Extent.StartOffset -lt $sbScope.Extent.StartOffset -or
                        $r.Extent.EndOffset -gt $sbScope.Extent.EndOffset)) { continue }
                if ($r.Extent.StartOffset -ge $try.Extent.StartOffset -and
                    $r.Extent.EndOffset -le $try.Extent.EndOffset) { continue }
                if (Test-IsWriteTarget -Read $r) { continue }
                if (Test-IsLoopShadowed -Read $r -Name $name) { continue }
                if (-not $read) { $read = $r }
                if (Test-IsDecisionContext -Read $r) { $read = $r; $decision = $true; break }
            }
            if (-not $read) { continue }

            $stale = [bool]($loopStale -and
                $read.Extent.StartOffset -ge $loop.Extent.StartOffset -and
                $read.Extent.EndOffset -le $loop.Extent.EndOffset)
            if ($stale -and (Test-ReadGuardsLoopExit -Read $read -Loop $loop)) { $stale = $false }

            $severity = if ($preInit -and -not $stale) { 'LOW' } elseif ($decision) { 'HIGH' } else { 'MEDIUM' }
            $tryFirst = if ($try.Body.Statements.Count -gt 0) { ($try.Body.Statements[0].Extent.Text -split "`n")[0].Trim() } else { '' }

            $findings += [pscustomobject]@{
                Severity = $severity
                Shape    = $shape
                Stale    = $stale
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

    $silent = @($findings | Where-Object { $_.Variable -eq '$s' })
    if ($silent.Count -ne 1) { $problems += "`$s`: catch has a body but reports nothing -- expected 1 finding, got $($silent.Count)" }
    elseif ($silent[0].Severity -ne 'HIGH' -or $silent[0].Shape -ne 'silent') {
        $problems += "`$s`: expected HIGH/silent, got $($silent[0].Severity)/$($silent[0].Shape)"
    }
    foreach ($pair in @(@('rep', 'the catch calls Write-Host'), @('lr', 'the catch calls a local _Log reporter'),
            @('ca', 'the catch assigns the variable itself'), @('cr', 'the catch returns'),
            @('cad', 'the catch reports via .Add()'),
            @('dsb', 'the assignment is in a deferred scriptblock, not the try flow'),
            @('ros', 'the read is outside the scriptblock the try lives in'))) {
        $hit = @($findings | Where-Object { $_.Variable -eq ('$' + $pair[0]) })
        if ($hit.Count -ne 0) { $problems += "`$$($pair[0]) was reported, but $($pair[1])" }
    }
    $stale = @($findings | Where-Object { $_.Variable -eq '$ls' })
    if ($stale.Count -ne 1) { $problems += "`$ls`: stale-in-loop -- expected 1 finding, got $($stale.Count)" }
    elseif ($stale[0].Severity -ne 'HIGH' -or -not $stale[0].Stale) {
        $problems += "`$ls`: pre-initialised but refreshed inside a loop -- expected HIGH/stale, got $($stale[0].Severity)/stale=$($stale[0].Stale)"
    }
    $reseed = @($findings | Where-Object { $_.Variable -eq '$rs' })
    if ($reseed.Count -ne 1) { $problems += "`$rs`: re-seeded in loop -- expected 1 finding, got $($reseed.Count)" }
    elseif ($reseed[0].Severity -ne 'LOW' -or $reseed[0].Stale) {
        $problems += "`$rs`: re-seeded to a known value inside the loop -- expected LOW/not stale, got $($reseed[0].Severity)/stale=$($reseed[0].Stale)"
    }
    $latch = @($findings | Where-Object { $_.Variable -eq '$lt' })
    if ($latch.Count -ne 1) { $problems += "`$lt`: retry latch -- expected 1 finding, got $($latch.Count)" }
    elseif ($latch[0].Severity -ne 'LOW' -or $latch[0].Stale) {
        $problems += "`$lt`: assigned only under an if, so the loop is the retry -- expected LOW/not stale, got $($latch[0].Severity)/stale=$($latch[0].Stale)"
    }
    $above = @($findings | Where-Object { $_.Variable -eq '$sa' })
    if ($above.Count -ne 1) { $problems += "`$sa`: only read is the loop condition ABOVE the try -- expected 1 finding, got $($above.Count)" }
    elseif ($above[0].Severity -ne 'HIGH' -or -not $above[0].Stale) {
        $problems += "`$sa`: stale read above the try -- expected HIGH/stale, got $($above[0].Severity)/stale=$($above[0].Stale)"
    }
    $flag = @($findings | Where-Object { $_.Variable -eq '$fl' })
    if ($flag.Count -ne 1) { $problems += "`$fl`: success flag -- expected 1 finding, got $($flag.Count)" }
    elseif ($flag[0].Severity -ne 'LOW' -or $flag[0].Stale) {
        $problems += "`$fl`: assigned a literal, so the old value means 'not yet' -- expected LOW/not stale, got $($flag[0].Severity)/stale=$($flag[0].Stale)"
    }
    $brk = @($findings | Where-Object { $_.Variable -eq '$bs' })
    if ($brk.Count -ne 1) { $problems += "`$bs`: loop breaks on success -- expected 1 finding, got $($brk.Count)" }
    elseif ($brk[0].Severity -ne 'LOW' -or $brk[0].Stale) {
        $problems += "`$bs`: a good value breaks the loop, so no iteration sees a stale one -- expected LOW/not stale, got $($brk[0].Severity)/stale=$($brk[0].Stale)"
    }

    if ($problems.Count) {
        Write-Host "SELF-TEST FAILED:" -ForegroundColor Red
        $problems | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "SELF-TEST PASSED - ranked HIGH/MEDIUM/LOW correctly, spotted the silent non-empty catch and the stale-in-loop refresh, and ignored the reporting catches." -ForegroundColor Green
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
Write-Host ("  HIGH   {0,5}   unset or stale value reaches a condition" -f @($findings | Where-Object Severity -eq 'HIGH').Count)
Write-Host ("  MEDIUM {0,5}   unset or stale value reaches a log line or other read" -f @($findings | Where-Object Severity -eq 'MEDIUM').Count)
Write-Host ("  LOW    {0,5}   pre-initialised outside a loop, swallow falls back to a known value" -f @($findings | Where-Object Severity -eq 'LOW').Count)
Write-Host ""
Write-Host ("  by catch shape:  empty {0}   silent {1}   verbose-only {2}" -f
    @($findings | Where-Object Shape -eq 'empty').Count,
    @($findings | Where-Object Shape -eq 'silent').Count,
    @($findings | Where-Object Shape -eq 'verbose-only').Count) -ForegroundColor DarkCyan
Write-Host ("  stale-in-loop:   {0}" -f @($findings | Where-Object Stale).Count) -ForegroundColor DarkCyan
Write-Host ""

foreach ($f in $shown) {
    $colour = if ($f.Severity -eq 'HIGH') { 'Red' } elseif ($f.Severity -eq 'MEDIUM') { 'Yellow' } else { 'DarkGray' }
    $tag = if ($f.Stale) { "$($f.Shape) catch, STALE IN LOOP" } else { "$($f.Shape) catch" }
    Write-Host ("[{0}] {1}:{2}  {3}  ({4})" -f $f.Severity, $f.Source, $f.Line, $f.Variable, $tag) -ForegroundColor $colour
    Write-Host ("        try   {0}" -f $f.Try) -ForegroundColor DarkGray
    Write-Host ("        L{0}   {1}" -f $f.ReadLine, $f.ReadText) -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Showing $($shown.Count) of $($findings.Count) finding(s). These are CANDIDATES, not confirmed" -ForegroundColor Cyan
Write-Host "defects -- each one needs the call site read. Fix by recording the failure in the" -ForegroundColor Cyan
Write-Host "catch, or by giving the variable an explicit value that means 'not measured'." -ForegroundColor Cyan
exit 0
