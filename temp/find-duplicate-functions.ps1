<#
Find duplicate function definitions and say which ones actually collide.

Not every duplicate is a bug: DSC phase scripts, tools and Fixes run standalone (in
the guest, or in a fresh process) and legitimately carry their own copy of helpers
like Write-Log. A duplicate only MATTERS when both definitions are dot-sourced into
the same session -- then the last one silently wins.
#>
[CmdletBinding()]
param([switch]$IncludeNested)

$repo = 'C:\memlabs'
$vmbuild = Join-Path $repo 'vmbuild'

# --- 1. which files land in the launcher session (transitive from Common.ps1) ----
$sessionFiles = New-Object System.Collections.Generic.List[string]
$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue((Join-Path $vmbuild 'Common.ps1'))
while ($queue.Count -gt 0) {
    $f = $queue.Dequeue()
    if (-not (Test-Path $f)) { continue }
    $full = (Resolve-Path $f).Path
    if ($sessionFiles.Contains($full)) { continue }
    [void]$sessionFiles.Add($full)
    foreach ($line in (Get-Content $full)) {
        if ($line -match '^\s*\.\s+\$PSScriptRoot\\(.+?\.ps1)') {
            $queue.Enqueue((Join-Path $vmbuild $matches[1]))
        }
    }
}

# New-Lab / genconfig dot-source Common.ps1 plus their own helpers; treat the whole
# common\ folder as one session, which is how it is actually loaded.
foreach ($f in (Get-ChildItem (Join-Path $vmbuild 'common') -Filter *.ps1 -File)) {
    if (-not $sessionFiles.Contains($f.FullName)) { [void]$sessionFiles.Add($f.FullName) }
}

"launcher-session files: $($sessionFiles.Count)"

# --- 2. every function definition in the repo ------------------------------------
$all = New-Object System.Collections.Generic.List[psobject]
$files = @(Get-ChildItem $vmbuild -Filter *.ps1 -File -Recurse |
        Where-Object { $_.FullName -notmatch '\\(temp|logs|azureFiles)\\' })

foreach ($f in $files) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    if (-not $ast) { continue }
    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        # A function declared inside another function/scriptblock is scoped to it.
        $nested = $false
        $p = $fn.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
            $p = $p.Parent
        }
        if ($nested -and -not $IncludeNested) { continue }
        # A definition inside an `if` is a guarded fallback (PS-version stub,
        # `if (-not (Get-Command X))`). Those coexist by design, so they are not
        # collisions -- only unconditional definitions can silently overwrite.
        $conditional = $false
        $q = $fn.Parent
        while ($q) {
            if ($q -is [System.Management.Automation.Language.IfStatementAst]) { $conditional = $true; break }
            $q = $q.Parent
        }
        $all.Add([pscustomobject]@{
                Name        = "$($fn.Name)"
                File        = $f.FullName
                Rel         = $f.FullName.Replace($repo, '').TrimStart('\')
                Line        = $fn.Extent.StartLineNumber
                InSession   = $sessionFiles.Contains($f.FullName)
                Conditional = $conditional
                Params      = if ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters.Count } else { 0 }
                Lines       = ($fn.Extent.EndLineNumber - $fn.Extent.StartLineNumber + 1)
            })
    }
}
"top-level function definitions: $($all.Count)"
""

$groups = $all.ToArray() | Group-Object Name | Where-Object { $_.Count -gt 1 }

$collide = New-Object System.Collections.Generic.List[psobject]
$sameFile = New-Object System.Collections.Generic.List[psobject]
$benign = New-Object System.Collections.Generic.List[psobject]

foreach ($g in $groups) {
    $defs = $g.Group
    $inSession = @($defs | Where-Object { $_.InSession -and -not $_.Conditional })
    $byFile = $defs | Group-Object File | Where-Object { $_.Count -gt 1 }
    if ($byFile) { $sameFile.Add([pscustomobject]@{ Name = $g.Name; Defs = $defs }) }
    elseif ($inSession.Count -gt 1) { $collide.Add([pscustomobject]@{ Name = $g.Name; Defs = $defs; N = $inSession.Count }) }
    else { $benign.Add([pscustomobject]@{ Name = $g.Name; Defs = $defs }) }
}

"=== A. SAME FILE twice (always a bug) : $($sameFile.Count) ==="
foreach ($d in $sameFile) {
    "  {0}" -f $d.Name
    foreach ($x in $d.Defs) { "      {0}:{1}  ({2} params, {3} lines)" -f $x.Rel, $x.Line, $x.Params, $x.Lines }
}
""
"=== B. COLLIDE in the launcher session (last one silently wins) : $($collide.Count) ==="
foreach ($d in ($collide | Sort-Object Name)) {
    "  {0}" -f $d.Name
    foreach ($x in $d.Defs) { "      {0}{1}:{2}  ({3} params, {4} lines)" -f $(if ($x.InSession) { '* ' } else { '  ' }), $x.Rel, $x.Line, $x.Params, $x.Lines }
}
""
"=== C. separate load scopes (standalone copies -- usually fine) : $($benign.Count) ==="
foreach ($d in ($benign | Sort-Object Name)) {
    "  {0,-42} {1}" -f $d.Name, (($d.Defs | ForEach-Object { "$($_.Rel):$($_.Line)" }) -join '  |  ')
}
