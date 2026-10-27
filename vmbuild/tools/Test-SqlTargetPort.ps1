# Fails when a SQL connection target is built from lab config without carrying sqlPort.
#
#     pwsh -NoProfile -File vmbuild\tools\Test-SqlTargetPort.ps1 [-Root <path>]
#
# A DEFAULT SQL instance on a non-default port has no instance name to hang the port on, so
# omitting the port silently aims the connection at 1433 -- and ChangeSqlInstancePort moves
# IPAll\TcpPort, so nothing is listening there. CT3-CS1SQL (MSSQLSERVER on 5422) failed an
# 83-minute Phase 8 that way, and the resulting connect error was reported as "the parent site
# has NO targeting row". 13 of 62 lab configs use a non-1433 port.
#
# The shape with zero legitimate uses: a scope that reads sqlInstanceName / remoteSQLVM /
# AlwaysOnListenerName to build a server target, and never mentions a port at all. Building
# from config is what makes the port knowable; a target arriving as a parameter is its
# caller's problem and is not flagged here.
#
# Guest phase scripts should call Get-VmSqlConnectionTarget (DSC\phases\ScriptFunctions.ps1)
# rather than open-coding this a fourth time.

[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path $PSScriptRoot -Parent) '' }
if (-not (Test-Path $Root)) { throw "root not found: $Root" }

$files = @(Get-ChildItem -Path $Root -Recurse -Include '*.ps1', '*.psm1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\temp\\' })
if ($files.Count -eq 0) { Write-Host 'FAIL: scanned 0 files.' -ForegroundColor Red; exit 1 }

# Reads config to decide WHICH server to talk to.
$configPattern = '(?i)\.sqlInstanceName|\.remoteSQLVM|\.AlwaysOnListenerName'
# Must read the port FROM CONFIG, or be handed one. Merely naming a $sqlPort local does not
# count: the original bug set `$sqlPort = $null` and then filled it only from SQLAOPort, so a
# non-AlwaysOn server never got one. SQLAOPort alone is therefore NOT an acceptable source.
$portPattern = '(?i)\.sqlPort\b|\$Port\b|-Port\b|listenerPort|\bTcpPort\b'
# Actually hands the result to SQL.
$sinkPattern = "(?i)Data Source=|-ServerInstance|Server=\`$|SqlConnection|Get-VmSqlConnectionTarget|Get-SqlConnString"
# The builder that caused the outage contained no connection string at all -- it returned
# "server\instance" for someone else to connect with. That shape is a target too, but only
# when BOTH tells are present: comparing an instance against MSSQLSERVER (the "do I append
# an instance?" decision) AND actually concatenating it after a backslash. A tooltip that
# prints " ($instance)" has the first and not the second.
$formatPattern = "(?i)(-ne|-eq)\s+'MSSQLSERVER'"
$backslashJoin = '\\\$'
# A local connection reaches SQL over Shared Memory, which has no port -- exempt, but only
# while the scope builds nothing remote (no FQDN/domain-qualified target) alongside it.
$localPattern = "(?i)['`"]localhost|['`"]\(local\)"
$remotePattern = '(?i)\$\w*fqdn|\.\$domain|\.\$DomainFullName|\.\$DomainFqdn'

$findings = New-Object System.Collections.Generic.List[object]
$scanned = 0

foreach ($file in $files) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    if (-not [regex]::IsMatch($raw, $configPattern)) { continue }
    $scanned++

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    # DSC configurations do not parse without their modules present; scan those textually.
    if ($errors -and $errors.Count -gt 0 -and @($errors | Where-Object { $_.Message -notmatch 'Could not find the module' }).Count -gt 0) { continue }

    $scopes = New-Object System.Collections.Generic.List[object]
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $scopes.Add([pscustomobject]@{ Name = "function $($fn.Name)"; Ast = $fn })
    }
    foreach ($asn in $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Right.Extent.Text.TrimStart().StartsWith('{') }, $true)) {
        $scopes.Add([pscustomobject]@{ Name = "scriptblock $($asn.Left.Extent.Text)"; Ast = $asn })
    }
    if ($scopes.Count -eq 0) { continue }

    foreach ($scope in $scopes) {
        $text = $scope.Ast.Extent.Text
        if (-not [regex]::IsMatch($text, $configPattern)) { continue }
        $isTarget = [regex]::IsMatch($text, $sinkPattern) -or
            ([regex]::IsMatch($text, $formatPattern) -and [regex]::IsMatch($text, $backslashJoin))
        if (-not $isTarget) { continue }
        if ([regex]::IsMatch($text, $portPattern)) { continue }
        if ([regex]::IsMatch($text, $localPattern) -and -not [regex]::IsMatch($text, $remotePattern)) { continue }
        # An enclosing scope that already handles the port covers this one.
        $outer = $scopes | Where-Object {
            $_ -ne $scope -and
            $_.Ast.Extent.StartLineNumber -le $scope.Ast.Extent.StartLineNumber -and
            $_.Ast.Extent.EndLineNumber -ge $scope.Ast.Extent.EndLineNumber -and
            [regex]::IsMatch($_.Ast.Extent.Text, $portPattern)
        }
        if ($outer) { continue }

        $findings.Add([pscustomobject]@{
                File  = $file.FullName.Replace("$Root", '').TrimStart('\')
                Line  = $scope.Ast.Extent.StartLineNumber
                Scope = $scope.Name
            })
    }
}

if ($scanned -eq 0) {
    Write-Host 'FAIL: no file references SQL config at all -- the gate is not looking at anything.' -ForegroundColor Red
    exit 1
}

if ($findings.Count -gt 0) {
    Write-Host "FAIL - $($findings.Count) SQL target(s) built from config with no port (scanned $scanned file(s)):" -ForegroundColor Red
    foreach ($f in $findings | Sort-Object File, Line) {
        Write-Host ("  {0}:{1}  [{2}]" -f $f.File, $f.Line, $f.Scope) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  A default instance on a non-default port has nowhere else to carry the port.' -ForegroundColor Yellow
    Write-Host '  Guest phase scripts: call Get-VmSqlConnectionTarget from ScriptFunctions.ps1.' -ForegroundColor Yellow
    exit 1
}

if (-not $Quiet) {
    Write-Host "Scanned $scanned file(s) that build SQL targets from config."
    Write-Host 'OK - every SQL target built from config accounts for a port.'
}
exit 0
