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
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$pathWasProvided = -not [string]::IsNullOrWhiteSpace($Path)
$vmbuildRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $vmbuildRoot
if (-not $pathWasProvided) {
    $Path = $vmbuildRoot
}

$assignmentOperators = @('=', '+=', '-=', '*=', '/=', '%=')
$nonBlockingParserErrorIds = @(
    'ModuleNotFoundDuringParse'
    'MultipleModuleEntriesFoundDuringParse'
    'InvalidInstanceProperty'
    'ResourceNotDefined'
)
$script:ParserDiagnostics = New-Object System.Collections.Generic.List[object]

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
configuration TestConfig {
    Node localhost {
        FakeResource Example {
            Name = 'legitimate DSC property'
        }
        FakeResource NextLine
        {
            Ensure = 'Present'
        }
        FakeResource NestedScript {
            ScriptProperty = {
                droppedInsideDscScript = 1
            }
        }
    }
}
'@
    $parseErrors = $null
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$parseErrors)
    $blockingParseErrors = @($parseErrors | Where-Object { $_.ErrorId -notin $nonBlockingParserErrorIds })
    if ($blockingParseErrors.Count -gt 0) {
        throw "Bareword self-test fixture has parse errors: $($blockingParseErrors -join '; ')"
    }
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    if (-not $pathWasProvided) {
        $repositoryPaths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- `
                'vmbuild/*.ps1' 'vmbuild/*.psm1' 'vmbuild/**/*.ps1' 'vmbuild/**/*.psm1')
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed with exit code $LASTEXITCODE while enumerating PowerShell sources."
        }
        $files = @($repositoryPaths |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $repoRoot $_) -ErrorAction SilentlyContinue } |
                Where-Object {
                    $_ -and
                    $_.FullName -notmatch '\\(logs|azureFiles|temp)\\' -and
                    $_.FullName -notmatch '\\baseimagestaging\\filesToInject\\tools\\'
                })
    }
    else {
        $scanItem = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $scanItem) { throw "Scan path not found: '$Path'." }

        if ($scanItem.PSIsContainer) {
            $files = @(Get-ChildItem -LiteralPath $scanItem.FullName -Recurse -File -ErrorAction Stop |
                    Where-Object { $_.Extension -in '.ps1', '.psm1' })
        }
        elseif ($scanItem.Extension -in '.ps1', '.psm1') {
            $files = @($scanItem)
        }
        else {
            throw "Scan path is not a PowerShell script or module: '$Path'."
        }
    }
    if ($files.Count -eq 0) { throw "No PowerShell scripts or modules were found under '$Path'." }

    foreach ($file in $files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        $blockingParseErrors = @($parseErrors | Where-Object { $_.ErrorId -notin $nonBlockingParserErrorIds })
        if ($blockingParseErrors.Count -gt 0) {
            $details = @($blockingParseErrors | ForEach-Object {
                    "line $($_.Extent.StartLineNumber): $($_.Message)"
                }) -join '; '
            throw "Cannot scan '$($file.FullName)' because it has PowerShell parse errors: $details"
        }
        foreach ($parseDiagnostic in @($parseErrors | Where-Object { $_.ErrorId -in $nonBlockingParserErrorIds })) {
            $script:ParserDiagnostics.Add([pscustomobject]@{
                    Path = $file.FullName
                    Line = $parseDiagnostic.Extent.StartLineNumber
                    ErrorId = $parseDiagnostic.ErrorId
                    Message = $parseDiagnostic.Message
                })
        }
        $sources += [pscustomobject]@{ Name = $file.FullName; Ast = $ast }
    }
}

function Write-ParserDiagnosticSummary {
    if ($script:ParserDiagnostics.Count -eq 0) { return }

    $counts = @($script:ParserDiagnostics |
            Group-Object ErrorId |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" })
    Write-Host "NOTE: Scanned partial ASTs after $($script:ParserDiagnostics.Count) environment-dependent DSC parser diagnostic(s): $($counts -join ', ')." -ForegroundColor Yellow
    foreach ($diagnostic in $script:ParserDiagnostics) {
        Write-Verbose "$($diagnostic.Path):$($diagnostic.Line) [$($diagnostic.ErrorId)] $($diagnostic.Message)"
    }
}

function Test-IsDscResourceProperty {
    param (
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $pipeline = $Command.Parent
    $namedBlock = if ($pipeline) { $pipeline.Parent } else { $null }
    $resourceBody = if ($namedBlock) { $namedBlock.Parent } else { $null }
    $bodyExpression = if ($resourceBody) { $resourceBody.Parent } else { $null }

    if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or
        $namedBlock -isnot [System.Management.Automation.Language.NamedBlockAst] -or
        $resourceBody -isnot [System.Management.Automation.Language.ScriptBlockAst] -or
        $bodyExpression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        return $false
    }

    $resourceCommand = $null
    if ($bodyExpression.Parent -is [System.Management.Automation.Language.CommandAst]) {
        $candidateCommand = $bodyExpression.Parent
        $secondElementIsAssignment = $candidateCommand.CommandElements.Count -gt 2 -and
            $candidateCommand.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $assignmentOperators -contains $candidateCommand.CommandElements[1].Value
        if ($candidateCommand.CommandElements.Count -in 2, 3 -and
            -not $secondElementIsAssignment -and
            [object]::ReferenceEquals($candidateCommand.CommandElements[-1], $bodyExpression)) {
            $resourceCommand = $candidateCommand
        }
    }
    elseif ($bodyExpression.Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $bodyExpression.Parent.Parent -is [System.Management.Automation.Language.PipelineAst]) {
        $bodyPipeline = $bodyExpression.Parent.Parent
        $statementContainer = $bodyPipeline.Parent
        $statements = @($statementContainer.Statements)
        $bodyIndex = -1
        for ($index = 0; $index -lt $statements.Count; $index++) {
            if ([object]::ReferenceEquals($statements[$index], $bodyPipeline)) {
                $bodyIndex = $index
                break
            }
        }
        if ($bodyIndex -gt 0) {
            $declarationPipeline = $statements[$bodyIndex - 1]
            if ($declarationPipeline -is [System.Management.Automation.Language.PipelineAst] -and
                $declarationPipeline.PipelineElements.Count -eq 1 -and
                $declarationPipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst]) {
                $candidateCommand = $declarationPipeline.PipelineElements[0]
                $secondElementIsAssignment = $candidateCommand.CommandElements.Count -gt 1 -and
                    $candidateCommand.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $assignmentOperators -contains $candidateCommand.CommandElements[1].Value
                if ($candidateCommand.CommandElements.Count -in 1, 2 -and -not $secondElementIsAssignment) {
                    $resourceCommand = $candidateCommand
                }
            }
        }
    }
    if (-not $resourceCommand) { return $false }

    $ancestor = $resourceCommand.Parent
    while ($ancestor) {
        if ($ancestor -is [System.Management.Automation.Language.ConfigurationDefinitionAst]) {
            return $true
        }
        $ancestor = $ancestor.Parent
    }
    return $false
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
        if (Test-IsDscResourceProperty -Command $node) { continue }

        $findings += [pscustomobject]@{
            Source = $source.Name
            Line   = $node.Extent.StartLineNumber
            Name   = $name
            Text   = ($node.Extent.Text -split "`n")[0].Trim()
        }
    }
}

if (-not $Quiet) {
    Write-ParserDiagnosticSummary
    Write-Host "Scanned $($sources.Count) source(s) for bare-word assignments."
}

if ($SelfTest.IsPresent) {
    $expected = @('propName', 'counter', 'Get-ChildItem', 'droppedInsideDscScript')
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
