<#
.SYNOPSIS
    Flag a bare word used as a command when the next token is '=' -- the signature
    of a dropped '$' on an assignment.

.DESCRIPTION
    ScriptWorkFlow.ps1 carried this for four years:

        $propName = propName = "PSReadyToUse" + $psvm.VmName

    The second 'propName' has no '$', so PowerShell parses it in command mode and
    raises CommandNotFoundException at runtime. That stayed invisible because a
    command-not-found is only a STATEMENT-terminating error: the script continued,
    $propName was $null, and the key it was supposed to build was silently dropped.
    When a top-level 'trap { ... break }' was later added to that script the exact
    same line became a fatal exit, and a CAS hierarchy hung for 80 minutes with no
    error anywhere.

    Neither the parser nor PSScriptAnalyzer sees anything wrong: the syntax is
    legal and the command name cannot be resolved until run time. Resolving every
    bare command name against the local session is far too noisy -- the DSC phase
    scripts call ~100 cmdlets that only exist inside a VM (ConfigurationManager,
    ActiveDirectory, WebAdministration, FailoverClusters, SqlServer, UpdateServices).

    So this checks the one shape that has no legitimate form: a command whose
    FIRST argument is a bare '=' (or '+=' / '-=' / '*=' / '/='). No real cmdlet or
    executable is invoked that way, so a hit is always a dropped sigil.
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

$assignmentOperators = @('=', '+=', '-=', '*=', '/=', '%=')

$sources = @()
if ($SelfTest.IsPresent) {
    $fixture = @'
$psvm = [pscustomobject]@{ VmName = 'PS1' }
$propName = propName = "PSReadyToUse" + $psvm.VmName
counter += 1
Get-ChildItem = $here
$ok = "PSReadyToUse" + $psvm.VmName
Write-Host "=" -NoNewline
& $someCommand '=' 'x'
'@
    $parseErrors = $null
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$parseErrors)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    $files = @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(logs|azureFiles|temp)\\' })
    foreach ($file in $files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { continue }
        $sources += [pscustomobject]@{ Name = $file.FullName; Ast = $ast }
    }
}

$findings = @()
foreach ($source in $sources) {
    foreach ($node in $source.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        # An & / . invocation names the command through a variable, so a following
        # '=' is a real argument rather than a dropped sigil.
        if ($node.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown) { continue }
        $elements = $node.CommandElements
        if ($elements.Count -lt 2) { continue }
        $name = $node.GetCommandName()
        if (-not $name) { continue }
        $next = $elements[1]
        if ($next -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        # A quoted '=' is a deliberate argument; only a bare operator token counts.
        if ($next.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord) { continue }
        if ($assignmentOperators -notcontains $next.Value) { continue }

        $findings += [pscustomobject]@{
            Source = $source.Name
            Line   = $node.Extent.StartLineNumber
            Name   = $name
            Text   = ($node.Extent.Text -split "`n")[0].Trim()
        }
    }
}

if (-not $Quiet) {
    Write-Host "Scanned $($sources.Count) source(s) for bare-word assignments."
}

if ($SelfTest.IsPresent) {
    $expected = @('propName', 'counter', 'Get-ChildItem')
    $got = @($findings | ForEach-Object { $_.Name })
    $missed = @($expected | Where-Object { $got -notcontains $_ })
    $extra = @($got | Where-Object { $expected -notcontains $_ })
    if ($missed.Count -or $extra.Count) {
        Write-Host "SELF-TEST FAILED. missed=[$($missed -join ', ')] unexpected=[$($extra -join ', ')]" -ForegroundColor Red
        exit 1
    }
    Write-Host "SELF-TEST PASSED - caught $($got -join ', ') and left the legitimate lines alone." -ForegroundColor Green
    exit 0
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no bare word is used as a command with '=' as its first argument." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: bare word used as a command, followed by an assignment operator (missing '`$'):" -ForegroundColor Red
foreach ($f in $findings) {
    Write-Host ""
    Write-Host ("  {0}:{1}" -f $f.Source, $f.Line) -ForegroundColor Red
    Write-Host ("      {0}" -f $f.Text) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "PowerShell parses '$($findings[0].Name) = ...' as a COMMAND call, not an assignment." -ForegroundColor Yellow
Write-Host "It throws CommandNotFoundException at run time -- silently under default" -ForegroundColor Yellow
Write-Host "preferences, fatally under a top-level trap. Add the missing '`$'." -ForegroundColor Yellow
exit 1
