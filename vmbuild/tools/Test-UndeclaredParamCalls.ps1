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
    [switch]$Quiet,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$nonBlockingParserErrorIds = @(
    'ModuleNotFoundDuringParse'
    'MultipleModuleEntriesFoundDuringParse'
    'InvalidInstanceProperty'
    'ResourceNotDefined'
)
$script:ParserDiagnostics = New-Object System.Collections.Generic.List[object]

if ($SelfTest) {
    if ($Path) { throw '-SelfTest cannot be combined with -Path.' }

    $fixtureRoot = Join-Path $env:TEMP ('undeclared-param-' + [guid]::NewGuid().ToString('N'))
    $fixtureTools = Join-Path $fixtureRoot 'tools'
    try {
        $null = New-Item -ItemType Directory -Path $fixtureTools -Force
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Production.ps1'), @'
Invoke-External -RealParameter value
function Invoke-Local { param($AllowedParameter) }
Invoke-Local -Allowed value
Invoke-Local -Bogus value
function Invoke-ArgsConsumer { param($Known); $null = $args }
Invoke-ArgsConsumer -Anything value
'@, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $fixtureTools 'Test-Mock.ps1'), @'
function Invoke-External { param($MockParameter) }
'@, [Text.Encoding]::ASCII)

        $engine = if ($PSVersionTable.PSEdition -eq 'Core') {
            Join-Path $PSHOME 'pwsh.exe'
        }
        else {
            Join-Path $PSHOME 'powershell.exe'
        }
        $engineArguments = @('-NoLogo', '-NoProfile', '-NonInteractive')
        if ($PSVersionTable.PSEdition -ne 'Core') {
            $engineArguments += @('-ExecutionPolicy', 'Bypass')
        }
        $engineArguments += @('-File', $PSCommandPath, '-Path', $fixtureRoot)
        $output = @(& $engine @engineArguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
        $text = $output -join [Environment]::NewLine
        if ($exitCode -ne 1 -or
            $text -notlike '*Invoke-Local -Bogus is not declared*' -or
            $text -like '*Invoke-External -RealParameter is not declared*' -or
            $text -like '*Invoke-Local -Allowed is not declared*' -or
            $text -like '*Invoke-ArgsConsumer -Anything is not declared*') {
            $output | Write-Host
            Write-Host "SELF-TEST FAILED: expected one Invoke-Local -Bogus violation, child exit=$exitCode." -ForegroundColor Red
            exit 1
        }
        if (-not $Quiet) {
            Write-Host 'SELF-TEST PASSED: test-local mocks, valid prefixes, and $args consumers were ignored; the real violation was reported.' -ForegroundColor Green
        }
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ScanFiles {
    param([string[]]$RequestedPath)

    $resolved = @()
    if (-not $RequestedPath) {
        $repositoryPaths = @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- `
                'vmbuild/*.ps1' 'vmbuild/**/*.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed with exit code $LASTEXITCODE while enumerating PowerShell sources."
        }
        $resolved = @($repositoryPaths |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $repoRoot $_) -ErrorAction SilentlyContinue } |
                Where-Object {
                    $_ -and
                    $_.FullName -notmatch '\\(temp|logs|azureFiles)\\' -and
                    $_.FullName -notmatch '\\baseimagestaging\\filesToInject\\tools\\'
                })
    }
    else {
        foreach ($candidate in $RequestedPath) {
            $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            if (-not $item) { throw "Scan path not found: '$candidate'." }
            if ($item.PSIsContainer) {
                $resolved += @(Get-ChildItem -LiteralPath $item.FullName -Filter *.ps1 -File -Recurse -ErrorAction Stop)
            }
            elseif ($item.Extension -eq '.ps1') {
                $resolved += $item
            }
            else {
                throw "Scan path is not a PowerShell script: '$candidate'."
            }
        }
    }

    $files = @($resolved | Sort-Object FullName -Unique)
    if ($files.Count -eq 0) { throw 'No PowerShell scripts were found in the requested scan scope.' }
    return $files
}

$files = @(Get-ScanFiles -RequestedPath $Path)

$defs = @{}
$asts = @{}

foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $blockingParseErrors = @($errors | Where-Object { $_.ErrorId -notin $nonBlockingParserErrorIds })
    if ($blockingParseErrors.Count -gt 0) {
        $details = @($blockingParseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber): $($_.Message)"
            }) -join '; '
        throw "Cannot scan '$($f.FullName)' because it has PowerShell parse errors: $details"
    }
    foreach ($parseDiagnostic in @($errors | Where-Object { $_.ErrorId -in $nonBlockingParserErrorIds })) {
        $script:ParserDiagnostics.Add([pscustomobject]@{
                Path = $f.FullName
                Line = $parseDiagnostic.Extent.StartLineNumber
                ErrorId = $parseDiagnostic.ErrorId
                Message = $parseDiagnostic.Message
            })
    }
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
            Source     = $f.FullName
            Names      = $names
            HasParam   = [bool]$paramBlock
            IsAdvanced = $isAdvanced
            UsesArgs   = $usesArgs
            })
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

# A name can be defined more than once. Only judge a call when EVERY definition is a
# silent-swallow candidate, and accept a parameter that ANY definition declares.
$funcs = @{}
foreach ($kv in $defs.GetEnumerator()) {
    # Test fixture functions are local to the test script that defines them. Treating
    # their mock signatures as repo-wide contracts misclassifies real module cmdlets
    # on hosts where those modules are not installed.
    $all = @($kv.Value.ToArray() | Where-Object { $_.Source -notmatch '\\tools\\Test-[^\\]+\.ps1$' })
    if ($all.Count -eq 0) { continue }
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
    Write-ParserDiagnosticSummary
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
