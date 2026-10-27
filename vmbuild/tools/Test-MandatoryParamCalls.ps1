<#
.SYNOPSIS
Find calls to repo functions that omit a Mandatory parameter.

.DESCRIPTION
A missing Mandatory parameter makes PowerShell PROMPT for it. Inside a background
job there is no interactive host, so the prompt never returns: the job sits at
state=Blocked and whatever is waiting on it waits forever. -ErrorAction
SilentlyContinue does not help, because a prompt is not an error.

One bare `Get-VM2` in a diagnostic cost two builds 5h11m and 10h24m.

Deliberately conservative -- it only reports a call when ALL of these hold, so a
hit is nearly always real:
  * the target is a function defined in this repo (cmdlets are not checked)
  * the function has at least one Mandatory parameter
  * the call binds NONE of them by name
  * the call passes NO positional arguments
  * the call does not splat
  * the call is not receiving pipeline input into a ValueFromPipeline parameter

.EXAMPLE
    .\Test-MandatoryParamCalls.ps1
    .\Test-MandatoryParamCalls.ps1 -Path vmbuild\common\Common.HyperV.ps1
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

# Common parameters that take no value. Everything else named consumes the next
# element, which is how `-ErrorAction SilentlyContinue` avoids being miscounted as a
# positional argument.
$commonSwitch = @('Verbose', 'Debug', 'WhatIf', 'Confirm')

$funcs = @{}
$defs = @{}
$asts = @{}

foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if (-not $ast) { continue }
    $asts[$f.FullName] = $ast

    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $paramBlock = $fn.Body.ParamBlock
        if (-not $paramBlock) { continue }
        $mandatory = New-Object System.Collections.Generic.List[string]
        $switches = New-Object System.Collections.Generic.List[string]
        $pipelineBound = New-Object System.Collections.Generic.List[string]
        foreach ($p in $paramBlock.Parameters) {
            $pname = $p.Name.VariablePath.UserPath
            $isSwitch = ("$($p.StaticType)" -match 'SwitchParameter')
            if ($isSwitch) { [void]$switches.Add($pname) }
            foreach ($attr in $p.Attributes) {
                if ("$($attr.TypeName)" -notmatch '^Parameter$') { continue }
                foreach ($na in $attr.NamedArguments) {
                    $argName = "$($na.ArgumentName)"
                    $argText = "$($na.Argument)"
                    if ($argName -eq 'Mandatory' -and ($na.ExpressionOmitted -or $argText -match '\$true')) {
                        if (-not $mandatory.Contains($pname)) { [void]$mandatory.Add($pname) }
                    }
                    if ($argName -match '^ValueFromPipeline' -and ($na.ExpressionOmitted -or $argText -match '\$true')) {
                        if (-not $pipelineBound.Contains($pname)) { [void]$pipelineBound.Add($pname) }
                    }
                }
            }
        }
        if (-not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = New-Object System.Collections.Generic.List[object] }
        $defs[$fn.Name].Add([pscustomobject]@{ Mandatory = $mandatory; Switches = $switches; Pipeline = $pipelineBound })
    }
}

# A name can be defined more than once (Write-Log exists in both Common.ps1 and
# Invoke-Maintenance.ps1). Letting the last definition win misreads every call:
# switches the winner does not declare swallow the next element as their value, so a
# positional argument looks absent. Union the switches, and require a parameter only
# where EVERY definition marks it Mandatory.
foreach ($kv in $defs.GetEnumerator()) {
    # .ToArray(), not @(): on PS 7.6.4 / .NET 10, `@($x)` throws "Argument types do not
    # match" when $x is a List[object]. A List[string] is unaffected.
    $all = $kv.Value.ToArray()

    $mand = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($all[0].Mandatory)) {
        $name = "$candidate"
        $inEvery = $true
        foreach ($d in $all) {
            $has = $false
            foreach ($m in @($d.Mandatory)) { if ("$m" -eq $name) { $has = $true; break } }
            if (-not $has) { $inEvery = $false; break }
        }
        if ($inEvery -and -not $mand.Contains($name)) { [void]$mand.Add($name) }
    }
    if ($mand.Count -eq 0) { continue }

    $sw = New-Object System.Collections.Generic.List[string]
    $pl = New-Object System.Collections.Generic.List[string]
    foreach ($d in $all) {
        foreach ($s in @($d.Switches)) { if ("$s" -and -not $sw.Contains("$s")) { [void]$sw.Add("$s") } }
        foreach ($v in @($d.Pipeline)) { if ("$v" -and -not $pl.Contains("$v")) { [void]$pl.Add("$v") } }
    }

    $funcs[$kv.Key] = [pscustomobject]@{
        Name      = "$($kv.Key)"
        Mandatory = $mand.ToArray()
        Switches  = $sw.ToArray()
        Pipeline  = $pl.ToArray()
    }
}

$violations = New-Object System.Collections.Generic.List[object]

foreach ($kv in $asts.GetEnumerator()) {
    $file = $kv.Key
    foreach ($cmd in $kv.Value.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $nameAst = $cmd.CommandElements[0]
        if ($nameAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $target = $funcs["$($nameAst.Value)"]
        if (-not $target) { continue }

        # Pipeline input can satisfy a ValueFromPipeline mandatory parameter.
        if ($target.Pipeline.Count -gt 0 -and
            $cmd.Parent -is [System.Management.Automation.Language.PipelineAst] -and
            $cmd.Parent.PipelineElements.Count -gt 1 -and
            $cmd.Parent.PipelineElements[0] -ne $cmd) { continue }

        $named = New-Object System.Collections.Generic.List[string]
        $positional = 0
        $splatted = $false
        $i = 1
        while ($i -lt $cmd.CommandElements.Count) {
            $el = $cmd.CommandElements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                $pn = "$($el.ParameterName)"
                [void]$named.Add($pn)
                $takesValue = -not ($target.Switches -contains $pn) -and ($commonSwitch -notcontains $pn)
                if ($null -eq $el.Argument -and $takesValue -and ($i + 1) -lt $cmd.CommandElements.Count) { $i++ }
            }
            elseif ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted) {
                $splatted = $true
            }
            else { $positional++ }
            $i++
        }
        if ($splatted -or $positional -gt 0) { continue }

        $boundMandatory = @($target.Mandatory | Where-Object { $named -contains $_ })
        if ($boundMandatory.Count -gt 0) { continue }

        $violations.Add([pscustomobject]@{
                File      = $file.Replace($repoRoot, '').TrimStart('\')
                Line      = $cmd.Extent.StartLineNumber
                Function  = $target.Name
                Missing   = ($target.Mandatory -join ', ')
                Statement = ("$($cmd.Extent.Text)" -replace '\s+', ' ')
            })
    }
}

if (-not $Quiet) {
    "Scanned $($files.Count) file(s); $($funcs.Count) repo function(s) have Mandatory parameters."
}

if ($violations.Count -eq 0) {
    if (-not $Quiet) { "OK - no call omits a Mandatory parameter." }
    exit 0
}

""
"ERROR: $($violations.Count) call(s) omit a Mandatory parameter. In a background job this PROMPTS and hangs forever (state=Blocked):"
""
foreach ($v in $violations) {
    "  {0}:{1}" -f $v.File, $v.Line
    "      {0}  (missing: -{1})" -f $v.Statement, ($v.Missing -replace ', ', ' / -')
}
""
exit 1
