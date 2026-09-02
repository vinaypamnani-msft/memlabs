<#
.SYNOPSIS
Find calls that pass a parameter the target repo function does not declare.

.DESCRIPTION
A SIMPLE function -- one with a param() block but no [CmdletBinding()] and no
[Parameter()] attributes -- does not reject unknown named parameters. PowerShell
collects them into $args and carries on, so the call looks correct, runs clean,
and does nothing.

`Write-DscStatus "..." -Warning` did exactly that at 91 call sites across 7 DSC
phase scripts. Write-DscStatus never had a -Warning parameter; every one of those
warnings was written to the guest log as Informational, including the boot-image
publication failure that left PXE unbootable. An advanced function would have
thrown on the first call.

Deliberately conservative -- it only reports a call when ALL of these hold:
  * the target is a function defined in this repo (cmdlets are not checked)
  * EVERY definition of that name is a simple function (an advanced one throws
    at runtime, which is loud, so it is not a silent-failure risk)
  * every definition has a param() block
  * no definition references $args (some simple functions harvest extras on purpose)
  * the parameter name does not match a declared parameter, case-insensitively,
    including PowerShell's unambiguous-prefix binding

.EXAMPLE
    .\Test-UndeclaredParamCalls.ps1
    .\Test-UndeclaredParamCalls.ps1 -Path vmbuild\DSC\phases\perfloading.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $Path) {
    $files = @(Get-ChildItem -Path (Join-Path $repoRoot 'vmbuild') -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(temp|logs|azureFiles)\\' })
}
else {
    $files = @($Path | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
}

$defs = @{}
$asts = @{}

foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if (-not $ast) { continue }
    $asts[$f.FullName] = $ast

    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $paramBlock = $fn.Body.ParamBlock
        $names = New-Object System.Collections.Generic.List[string]
        $isAdvanced = $false

        if ($paramBlock) {
            foreach ($attr in $paramBlock.Attributes) {
                if ("$($attr.TypeName)" -match '^CmdletBinding$') { $isAdvanced = $true }
            }
            foreach ($p in $paramBlock.Parameters) {
                [void]$names.Add($p.Name.VariablePath.UserPath)
                foreach ($attr in $p.Attributes) {
                    if ("$($attr.TypeName)" -match '^Parameter$') { $isAdvanced = $true }
                }
            }
        }

        # A body that reads $args is harvesting extras deliberately. FindAll is scoped
        # to this function, so a nested function's own $args does not mask the parent.
        $usesArgs = @($fn.Body.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.VariablePath.UserPath -eq 'args'
                }, $true)).Count -gt 0

        if (-not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = New-Object System.Collections.Generic.List[object] }
        $defs[$fn.Name].Add([pscustomobject]@{
                Names      = $names
                HasParam   = [bool]$paramBlock
                IsAdvanced = $isAdvanced
                UsesArgs   = $usesArgs
            })
    }
}

# A name can be defined more than once. Only judge a call when EVERY definition is a
# silent-swallow candidate, and accept a parameter that ANY definition declares.
$funcs = @{}
foreach ($kv in $defs.GetEnumerator()) {
    $all = $kv.Value.ToArray()
    $eligible = $true
    foreach ($d in $all) {
        if ($d.IsAdvanced -or -not $d.HasParam -or $d.UsesArgs) { $eligible = $false; break }
    }
    if (-not $eligible) { continue }

    # A repo function that shadows a real command (in-guest stubs redefine Get-ItemProperty,
    # Test-Path, New-Item, Get-Volume ...) only wins inside the scope that defines it. Every
    # other call site binds the genuine command, which validates its own parameters, so
    # judging those call sites against the stub's param block is pure noise -- 135 of 152
    # first-run hits. No CommandType filter: Get-Volume is a module FUNCTION, not a cmdlet,
    # and filtering on Cmdlet,Alias let it through. This script runs -NoProfile, so anything
    # Get-Command resolves is a system/module command, never a repo function.
    if (Get-Command -Name "$($kv.Key)" -ErrorAction SilentlyContinue) { continue }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($d in $all) {
        foreach ($n in @($d.Names)) { if ("$n" -and -not $names.Contains("$n")) { [void]$names.Add("$n") } }
    }
    if ($names.Count -eq 0) { continue }
    $funcs[$kv.Key] = $names.ToArray()
}

$violations = New-Object System.Collections.Generic.List[object]

foreach ($kv in $asts.GetEnumerator()) {
    $file = $kv.Key
    foreach ($cmd in $kv.Value.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $nameAst = $cmd.CommandElements[0]
        if ($nameAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $declared = $funcs["$($nameAst.Value)"]
        if (-not $declared) { continue }

        foreach ($el in $cmd.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $pn = "$($el.ParameterName)"
            if (-not $pn) { continue }
            # PowerShell binds an unambiguous prefix, so -Mach is a valid -MachineName.
            $matchesDeclared = @($declared | Where-Object { $_ -like "$pn*" })
            if ($matchesDeclared.Count -ge 1) { continue }

            $violations.Add([pscustomobject]@{
                    File      = $file.Replace($repoRoot, '').TrimStart('\')
                    Line      = $el.Extent.StartLineNumber
                    Function  = "$($nameAst.Value)"
                    Parameter = "-$pn"
                    Declared  = ($declared -join ', ')
                    Statement = ("$($cmd.Extent.Text)" -replace '\s+', ' ')
                })
        }
    }
}

if (-not $Quiet) {
    "Scanned $($files.Count) file(s); $($funcs.Count) repo function(s) are simple functions that silently swallow unknown parameters."
}

if ($violations.Count -eq 0) {
    if (-not $Quiet) { "OK - no call passes a parameter its target function does not declare." }
    exit 0
}

foreach ($v in $violations | Sort-Object File, Line) {
    $stmt = $v.Statement
    if ($stmt.Length -gt 150) { $stmt = $stmt.Substring(0, 150) + '...' }
    "ERROR: {0}:{1}  {2} {3} is not declared (declared: {4})" -f $v.File, $v.Line, $v.Function, $v.Parameter, $v.Declared
    "       $stmt"
}
""
"$($violations.Count) call(s) pass a parameter the target function does not declare. PowerShell puts it in `$args and ignores it."
exit 1
