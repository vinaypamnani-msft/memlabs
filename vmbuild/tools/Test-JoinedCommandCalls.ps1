<#
.SYNOPSIS
    Flag two command calls welded onto one line, where the second is silently eaten as arguments
    to the first.

.DESCRIPTION
    An edit that drops a newline between two calls to the same helper produces this:

        Q "SELECT * FROM PkgStatus_G ..." 'PkgStatus_G' $keep $PkgId        Q "SELECT * FROM PkgServers_G ..." 'PkgServers_G' $keep $PkgId

    PowerShell parses that as ONE call. If the target is declared with param() and no
    [CmdletBinding()], the extra arguments -- including the second command's name -- are collected
    into $args and discarded. No error, no output, nothing. The second query simply never runs.

    This is invisible to every existing gate: it is syntactically valid PowerShell, so the parser
    is happy, PSScriptAnalyzer is happy, and the 5.1 parse check is happy. It cost a live
    experiment window on 2026-08-14 by deleting the PkgServers_G query from Get-DrsLogs.ps1 while
    the surrounding snapshot kept reporting success, which then read as "the row is absent".

    Detected shape: a bare word appearing as an ARGUMENT to a command, where that bare word is the
    name of a function defined in the same file, and it is followed by another argument. Passing a
    local function's own name as a bare positional argument, with more arguments after it, has no
    legitimate use. A trailing bare word (Write-Host Q) and a switch that follows (Get-Help Q -Full)
    are both excluded, so ordinary code stays silent.

.EXAMPLE
    .\Test-JoinedCommandCalls.ps1
.EXAMPLE
    .\Test-JoinedCommandCalls.ps1 -SelfTest
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
function Q {
    param($q, $title, $keep, $p)
    Write-Host "$title $q"
}
$keep = 'x'
$PkgId = 'CS100003'
Q "SELECT * FROM PkgStatus_G" 'PkgStatus_G' $keep $PkgId        Q "SELECT * FROM PkgServers_G" 'PkgServers_G' $keep $PkgId
Q "SELECT * FROM PkgServers_L" 'PkgServers_L' $keep $PkgId
Write-Host Q
Get-Help Q -Full
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("joinedcall-fixture-{0}.ps1" -f [guid]::NewGuid())
    Set-Content -LiteralPath $tmp -Value $fixture -Encoding UTF8
    $sources = @(Get-Item -LiteralPath $tmp)
}
elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
    $sources = @(Get-Item -LiteralPath $Path)
}
else {
    $sources = @(Get-ChildItem -LiteralPath $Path -Include *.ps1, *.psm1 -Recurse -File)
}

# A gate that silently scans nothing passes for the wrong reason.
if ($sources.Count -eq 0) {
    Write-Host "ERROR: Test-JoinedCommandCalls scanned 0 files under '$Path'." -ForegroundColor Red
    exit 1
}

$findings = @()
foreach ($src in $sources) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($src.FullName, [ref]$tokens, [ref]$errors)
    if ($null -eq $ast) { continue }

    $funcNames = @{}
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $funcNames[$fn.Name] = $true
    }
    if ($funcNames.Count -eq 0) { continue }

    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $el = $cmd.CommandElements
        if ($el.Count -lt 3) { continue }
        # The outer command must itself be a function from this file. A welded call is
        # '<localfunc> args <localfunc> args'; requiring that kills the case where a native tool
        # takes a verb that merely collides with a function name, e.g. 'netsh winhttp set proxy'.
        if ($el[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        if (-not $funcNames.ContainsKey($el[0].Value)) { continue }
        for ($i = 1; $i -lt $el.Count - 1; $i++) {
            $cur = $el[$i]
            if ($cur -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if ($cur.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::BareWord) { continue }
            if (-not $funcNames.ContainsKey($cur.Value)) { continue }
            # A switch after it means the bare word was a real argument (Get-Help Q -Full), not a
            # second call that lost its newline.
            if ($el[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $findings += [pscustomobject]@{
                Source = $src.FullName
                Line   = $cur.Extent.StartLineNumber
                Outer  = $el[0].Extent.Text
                Name   = $cur.Value
                Text   = ($cmd.Extent.Text -replace '\s+', ' ')
            }
            break
        }
    }
}

if ($SelfTest.IsPresent) {
    Remove-Item -LiteralPath $sources[0].FullName -Force -ErrorAction SilentlyContinue
    if ($findings.Count -eq 1 -and $findings[0].Name -eq 'Q') {
        Write-Host "SELFTEST OK - fired once on the welded call, silent on 'Write-Host Q' and 'Get-Help Q -Full'."
        exit 0
    }
    Write-Host "SELFTEST FAILED - expected exactly 1 finding for 'Q', got $($findings.Count)." -ForegroundColor Red
    $findings | ForEach-Object { Write-Host "  $($_.Line): $($_.Text)" -ForegroundColor DarkGray }
    exit 1
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no local function name is passed as a bare argument mid-call. Scanned $($sources.Count) file(s)." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: two commands appear to be welded onto one line (a dropped newline):" -ForegroundColor Red
foreach ($f in $findings) {
    Write-Host ""
    Write-Host ("  {0}:{1}" -f $f.Source, $f.Line) -ForegroundColor Red
    Write-Host ("      {0}" -f $f.Text) -ForegroundColor DarkGray
    Write-Host ("      '{0}' is a function in this file, passed as an argument to '{1}'." -f $f.Name, $f.Outer) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "PowerShell parses this as ONE call. Under param() without [CmdletBinding()] the extra" -ForegroundColor Yellow
Write-Host "arguments land in `$args and are discarded -- the second call never runs, and nothing is" -ForegroundColor Yellow
Write-Host "reported. Put each call on its own line." -ForegroundColor Yellow
exit 1
