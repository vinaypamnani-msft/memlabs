<#
.SYNOPSIS
    Verifies every $using: variable inside a job-dispatched scriptblock exists in the
    scope that dispatches it.

.DESCRIPTION
    Start-Job / Start-ThreadJob resolve EVERY using-variable in the whole scriptblock
    tree -- nested scriptblock literals included -- against the DISPATCHING scope, at
    dispatch time. Not against the scriptblock's defining scope, and not lazily when
    the inner block later runs.

    So a variable that is only assigned inside $global:VM_Config, but referenced as
    $using: by one of the nested phase scriptblocks, throws at job creation:

        The value of the using variable '$using:X' cannot be retrieved because it
        has not been set in the local session.

    The whole phase then fails before a single job starts. Neither the parser nor
    PSScriptAnalyzer sees it: the scriptblock is syntactically valid, and the
    dispatching function is in a different file.

    Caught 28c2795a (mofFolderName defined in VM_Config instead of Start-PhaseJobs).

.EXAMPLE
    Test-UsingVarsInDispatchScope.ps1
    Test-UsingVarsInDispatchScope.ps1 -ScriptBlocksFile a.ps1 -DispatchFile b.ps1
#>
[CmdletBinding()]
param(
    [string]$ScriptBlocksFile,
    [string]$DispatchFile,
    # Ancestor scopes. $using: lookup walks the dispatching function's CALLER chain,
    # so script-level params/vars of the entry point are legitimately in scope
    # (e.g. $enableVerbose, $Migrate, $RoleConfigTimeoutMinutes from New-Lab.ps1).
    [string[]]$AncestorScopeFile
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $ScriptBlocksFile) { $ScriptBlocksFile = Join-Path $repoRoot 'vmbuild\common\Common.ScriptBlocks.ps1' }
if (-not $DispatchFile) { $DispatchFile = Join-Path $repoRoot 'vmbuild\common\Common.Phases.ps1' }
if (-not $AncestorScopeFile) { $AncestorScopeFile = @(Join-Path $repoRoot 'vmbuild\New-Lab.ps1') }

# Automatic or module-scope variables that are always present in any scope.
$ambient = @(
    'Common', 'PSScriptRoot', 'PSCommandPath', 'PWD', 'HOME', 'PID', 'true', 'false', 'null'
)

function Get-FileAst {
    param([string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Parse errors in ${Path}: $(($errors | Select-Object -First 1).Message)" }
    return $ast
}

# [SuppressMessage(...)] $x = ... and [int]$x = ... wrap the target, so a plain
# cast to VariableExpressionAst silently misses the assignment.
function Get-AssignedName {
    param($Left)
    $node = $Left
    while ($node -is [System.Management.Automation.Language.AttributedExpressionAst]) { $node = $node.Child }
    $v = $node -as [System.Management.Automation.Language.VariableExpressionAst]
    if ($v) { return ($v.VariablePath.UserPath -replace '^(global|script|local|private):', '') }
    return $null
}

function Add-ScopeNames {
    param($Ast, [System.Collections.Generic.HashSet[string]]$Set)
    foreach ($p in @($Ast.ParamBlock.Parameters)) { if ($p) { [void]$Set.Add($p.Name.VariablePath.UserPath) } }
    foreach ($a in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $n = Get-AssignedName -Left $a.Left
        if ($n) { [void]$Set.Add($n) }
    }
    foreach ($fe in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        [void]$Set.Add($fe.Variable.VariablePath.UserPath)
    }
}

$ancestorNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
foreach ($f in $AncestorScopeFile) {
    if (Test-Path -LiteralPath $f) { Add-ScopeNames -Ast (Get-FileAst -Path $f) -Set $ancestorNames }
}

$sbAst = Get-FileAst -Path $ScriptBlocksFile
$dispatchAst = Get-FileAst -Path $DispatchFile

# 1. $global:NAME = { ... }
$globalBlocks = @{}
foreach ($a in $sbAst.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $lhs = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
    if (-not $lhs -or $lhs.VariablePath.UserPath -notmatch '^global:') { continue }
    $rhs = $a.Right.Find({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $false)
    if ($rhs) { $globalBlocks[$lhs.VariablePath.UserPath] = $rhs.ScriptBlock }
}
# 2. Start-Job/Start-ThreadJob -ScriptBlock $global:NAME, and the function around it
$pairs = New-Object System.Collections.Generic.List[object]
foreach ($c in $dispatchAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    if ($c.GetCommandName() -notin @('Start-Job', 'Start-ThreadJob')) { continue }
    for ($i = 0; $i -lt $c.CommandElements.Count - 1; $i++) {
        $p = $c.CommandElements[$i] -as [System.Management.Automation.Language.CommandParameterAst]
        if (-not $p -or $p.ParameterName -ne 'ScriptBlock') { continue }
        $arg = $c.CommandElements[$i + 1] -as [System.Management.Automation.Language.VariableExpressionAst]
        if (-not $arg) { continue }
        $name = $arg.VariablePath.UserPath
        if (-not $globalBlocks.ContainsKey($name)) { continue }

        $fn = $null; $node = $c
        while ($node) {
            if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $node; break }
            $node = $node.Parent
        }
        $pairs.Add([pscustomobject]@{ Block = $name; Function = $(if ($fn) { $fn.Name } else { '<top level>' }); Fn = $fn; Line = $c.Extent.StartLineNumber })
    }
}

if ($pairs.Count -eq 0) { Write-Host 'No job-dispatched global scriptblocks found -- nothing to check.'; exit 0 }

$problems = 0
foreach ($pair in ($pairs | Sort-Object Block, Line -Unique)) {
    $block = $globalBlocks[$pair.Block]

    $usingNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $block.FindAll({ $args[0] -is [System.Management.Automation.Language.UsingExpressionAst] }, $true)) {
        $v = $u.SubExpression -as [System.Management.Automation.Language.VariableExpressionAst]
        $n = if ($v) { $v.VariablePath.UserPath } else { ($u.SubExpression.Extent.Text -replace '^\$', '') }
        [void]$usingNames.Add(((($n -replace '^using:', '') -split '\.')[0]))
    }

    $available = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $ambient) { [void]$available.Add($x) }
    foreach ($x in $ancestorNames) { [void]$available.Add($x) }
    if ($pair.Fn) { Add-ScopeNames -Ast $pair.Fn.Body -Set $available }

    $missing = @($usingNames | Where-Object { -not $available.Contains($_) } | Sort-Object)
    '{0,-22} dispatched by {1,-18} (line {2}): {3} using-var(s), {4} missing' -f `
        ('$' + $pair.Block), $pair.Function, $pair.Line, $usingNames.Count, $missing.Count
    foreach ($m in $missing) {
        '    MISSING(dispatch)  $using:{0} is not set in {1} -- job creation will throw.' -f $m, $pair.Function
        $problems++
    }

    # Second resolution. A nested scriptblock is later handed to Invoke-VmCommand,
    # which resolves its $using: AGAIN -- that time against the outer block's own
    # scope. So the outer block must re-expose each name as a local. Satisfying
    # only the dispatch scope above still throws, just later and per-VM.
    $ownScriptBlocks = @($block) + @($block.FindAll({ $args[0] -is [System.Management.Automation.Language.NamedBlockAst] }, $false))
    $outerLocals = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $ambient) { [void]$outerLocals.Add($x) }
    foreach ($a in $block.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $encl = $a.Parent
        while ($encl -and $encl -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $encl = $encl.Parent }
        if ($encl -notin $ownScriptBlocks) { continue }
        $n = Get-AssignedName -Left $a.Left
        if ($n) { [void]$outerLocals.Add($n) }
    }

    $nestedMissing = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($nested in $block.FindAll({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
        foreach ($u in $nested.ScriptBlock.FindAll({ $args[0] -is [System.Management.Automation.Language.UsingExpressionAst] }, $true)) {
            $v = $u.SubExpression -as [System.Management.Automation.Language.VariableExpressionAst]
            $n = if ($v) { $v.VariablePath.UserPath } else { ($u.SubExpression.Extent.Text -replace '^\$', '') }
            $n = ((($n -replace '^using:', '') -split '\.')[0])
            if (-not $outerLocals.Contains($n)) { [void]$nestedMissing.Add($n) }
        }
    }
    foreach ($m in ($nestedMissing | Sort-Object)) {
        '    MISSING(nested)    $using:{0} is used by a nested scriptblock but is not a local of ${1}.' -f $m, $pair.Block
        $problems++
    }
}

Write-Host ''
if ($problems -gt 0) {
    Write-Host "FAIL: $problems using-variable(s) are not available in the dispatching scope." -ForegroundColor Red
    Write-Host 'Assign them in the dispatching function (before the Start-Job call), not inside the scriptblock.'
    exit 1
}
Write-Host 'OK - every $using: variable is available in its dispatching scope.' -ForegroundColor Green
exit 0
