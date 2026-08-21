<#
.SYNOPSIS
    Flag `@($var).Count` on a variable that may be $null -- PowerShell reports 1,
    so a measurement of nothing is reported as a measurement of one.

.DESCRIPTION
    @($null).Count is 1, not 0. The array subexpression wraps the null itself, so a
    query that returned nothing counts as one phantom element:

        $kids = @($cdp.Children)                # unbound container -> $null -> Count 1
        "found $($kids.Count) child container(s)"    # prints 1, found none

    That shipped in a probe which reported "1 child container(s)" and then
    "0 CA entr(ies)" from the same enumeration -- arithmetically impossible, and the
    only reason the lie was caught.

    The risky form is a BARE variable inside the wrapper. `@(<command or pipeline>)`
    is safe: a command that emits nothing produces an empty array, not $null. So
    `@(Get-ChildItem ...).Count` is fine and is not reported; `@($files).Count` is not.

    Fix by filtering the nulls out, or by testing for null before counting:

        @($x | Where-Object { $null -ne $_ }).Count
        if ($null -eq $x) { 0 } else { @($x).Count }

.PARAMETER Path
    File or directory to scan. Defaults to the vmbuild tree.

.PARAMETER Quiet
    Suppress the "Scanned N source(s)" banner.

.PARAMETER SelfTest
    Run against a built-in fixture with known answers and exit non-zero if the
    detector misses a planted defect or invents one. Validates the instrument.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path = (Split-Path $PSScriptRoot -Parent),

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

$sources = @()
if ($SelfTest.IsPresent) {
    $fixture = @'
$kids = $cdp.Children
$a = @($kids).Count
$b = @($obj.Items).Count
$c = @($x[0]).Count
$safe1 = @(Get-ChildItem C:\).Count
$safe2 = @($list | Where-Object { $null -ne $_ }).Count
$safe3 = @().Count
$safe4 = @(1, 2, 3).Count
$notCount = @($kids).Length
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
    $nodes = $source.Ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $args[0].Member.Value -eq 'Count' -and
            $args[0].Expression -is [System.Management.Automation.Language.ArrayExpressionAst]
        }, $true)

    foreach ($node in $nodes) {
        $sub = $node.Expression.SubExpression
        # @() and @(1,2,3) cannot be null; only a lone variable read can be.
        if ($sub.Statements.Count -ne 1) { continue }
        $stmt = $sub.Statements[0]
        if ($stmt -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
        if ($stmt.PipelineElements.Count -ne 1) { continue }
        $element = $stmt.PipelineElements[0]
        if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }

        # A bare variable, or a member/index path rooted at one. Anything else
        # (command, pipeline, literal array) already yields a real array.
        $expr = $element.Expression
        $root = $expr
        while ($root -is [System.Management.Automation.Language.MemberExpressionAst] -or
            $root -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $root = if ($root -is [System.Management.Automation.Language.IndexExpressionAst]) { $root.Target } else { $root.Expression }
        }
        if ($root -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

        $findings += [pscustomobject]@{
            Source = $source.Name
            Line   = $node.Extent.StartLineNumber
            Text   = ($node.Extent.Text -split "`n")[0].Trim()
        }
    }
}

if (-not $Quiet) {
    Write-Host "Scanned $($sources.Count) source(s) for phantom-element array counts."
}

if ($SelfTest.IsPresent) {
    $expectedLines = @(2, 3, 4)
    $gotLines = @($findings | ForEach-Object { $_.Line } | Sort-Object)
    $missed = @($expectedLines | Where-Object { $gotLines -notcontains $_ })
    $extra = @($gotLines | Where-Object { $expectedLines -notcontains $_ })
    if ($missed.Count -or $extra.Count) {
        Write-Host "SELF-TEST FAILED. missed lines=[$($missed -join ', ')] unexpected lines=[$($extra -join ', ')]" -ForegroundColor Red
        exit 1
    }
    Write-Host "SELF-TEST PASSED - caught the 3 planted @(`$var).Count defects and left the 5 safe forms alone." -ForegroundColor Green
    exit 0
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no @(`$var).Count that could report a phantom element." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: @(`$var).Count on a variable that may be `$null -- reports 1, not 0:" -ForegroundColor Red
foreach ($f in $findings) {
    Write-Host ""
    Write-Host ("  {0}:{1}" -f $f.Source, $f.Line) -ForegroundColor Red
    Write-Host ("      {0}" -f $f.Text) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "@(`$null).Count is 1. A query that found nothing then reports one result." -ForegroundColor Yellow
Write-Host "Filter first:  @(`$x | Where-Object { `$null -ne `$_ }).Count" -ForegroundColor Yellow
Write-Host "or test first: if (`$null -eq `$x) { 0 } else { @(`$x).Count }" -ForegroundColor Yellow
exit 1
