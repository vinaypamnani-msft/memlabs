<#
.SYNOPSIS
Fail on Write-Log -OutputStream (and friends) called at statement level inside a FUNCTION,
where the emitted object silently joins that function's return value.

.DESCRIPTION
-OutputStream calls Write-Output. Inside a JOB SCRIPTBLOCK that is the point: the object
becomes job output and Wait-Phase scores it ($OutputObject.LogLevel 3=Failed, 2=Warning).
Inside a FUNCTION whose caller assigns the result, `$ok = Some-Function` gets
@(logObject, $false) -- and a multi-element array is TRUTHY, so the failure is scored as a
pass. Six confirmed instances before this gate existed; see the commit history for
Install-Tools (723507fd), Run-Test (beb5673d), Start-Phase (480ed275) and Wait-Phase.

Job scriptblocks are `$global:XJob = { ... }` assignments, not function definitions, so
scoping the scan to FunctionDefinitionAst excludes them by construction. Nested
scriptblocks (Start-Job/Invoke-Command bodies) are skipped for the same reason.

Exit 1 on any un-allowlisted hit, or if 0 files were scanned -- a gate that passes on an
empty set is worse than no gate.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$ShowAllowed
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }

# Commands that write to the success stream when handed -OutputStream.
$emitters = @('Write-Log', 'Write-HostMemoryPressureDiag')

# BY DESIGN: helpers that exist only to forward lines into job output. Every caller must
# be a bare statement inside a job scriptblock -- never `$x = ...`. Keyed "Function:Line-ish"
# by function name, because line numbers move.
$allowed = @(
    'Write-MemDiagLine'                      # nested emitter of Write-HostMemoryPressureDiag
    'Write-HostMemoryPressureDiag'           # -OutputStream switch is its documented job mode
    'Write-DhcpDiagLine'                     # nested emitter of Write-DhcpLeaseFailureDiag
    'Write-DhcpLeaseFailureDiag'             # called bare from the VM_Config job scriptblock
    'Save-CMSetupLogsFromVm'                 # called bare from the VM_Config job scriptblock
    'Save-CMClientPackagePrestageLogsFromVm' # called bare from the VM_Config job scriptblock
)

$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
$files = @(Get-ChildItem -Path $rootFull -Recurse -Include '*.ps1', '*.psm1' -File |
        Where-Object { $_.FullName.Substring($rootFull.Length) -notmatch '\\(logs|temp|\.git)\\' })

if ($files.Count -eq 0) {
    Write-Host "Test-OutputStreamInFunction: scanned 0 files under '$Root' -- the gate proved nothing." -ForegroundColor Red
    exit 1
}

$hits = [System.Collections.Generic.List[object]]::new()
$allowedHits = 0

foreach ($file in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    # DSC configuration files need the DSC resources loaded to parse; they use
    # Write-DscStatus, never Write-Log -OutputStream.
    if ($errors -and $errors.Count -gt 0) { continue }

    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        foreach ($cmd in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $cmd.GetCommandName()
            if (-not $name -or $emitters -notcontains $name) { continue }

            $hasOutputStream = $false
            foreach ($el in $cmd.CommandElements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -like 'OutputStream*') { $hasOutputStream = $true; break }
            }
            if (-not $hasOutputStream) { continue }

            # Inside a nested scriptblock? That runs in another runspace / another scope
            # and does not join THIS function's output.
            $inNestedBlock = $false
            $p = $cmd.Parent
            while ($p -and $p -ne $fn) {
                if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $inNestedBlock = $true; break }
                $p = $p.Parent
            }
            if ($inNestedBlock) { continue }

            # Consumed (assigned, $null =, piped onward, used as an argument)? Then it never
            # reaches the function's own success stream.
            $pipeline = $cmd
            while ($pipeline -and $pipeline -isnot [System.Management.Automation.Language.PipelineAst]) { $pipeline = $pipeline.Parent }
            if ($pipeline) {
                if ($pipeline.PipelineElements.Count -gt 1) { continue }
                $parent = $pipeline.Parent
                if ($parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and
                    $parent -isnot [System.Management.Automation.Language.NamedBlockAst]) { continue }
            }

            if ($allowed -contains $fn.Name) { $allowedHits++; if (-not $ShowAllowed) { continue } }

            $text = ($cmd.Extent.Text -replace '\s+', ' ')
            $hits.Add([pscustomobject]@{
                    File     = $file.FullName
                    Line     = $cmd.Extent.StartLineNumber
                    Function = $fn.Name
                    Allowed  = ($allowed -contains $fn.Name)
                    Text     = $text.Substring(0, [Math]::Min(110, $text.Length))
                })
        }
    }
}

$real = @($hits | Where-Object { -not $_.Allowed })

if ($real.Count -eq 0) {
    Write-Host "Test-OutputStreamInFunction: PASS ($($files.Count) files, $allowedHits by-design emitter(s) allowed)." -ForegroundColor Green
    if ($ShowAllowed) { $hits | Sort-Object File, Line | ForEach-Object { "  ALLOWED {0}:{1} {2}" -f (Split-Path $_.File -Leaf), $_.Line, $_.Function } }
    exit 0
}

Write-Host "Test-OutputStreamInFunction: FAIL -- $($real.Count) -OutputStream call(s) land in a function's return value:" -ForegroundColor Red
$real | Sort-Object File, Line | ForEach-Object {
    Write-Host ("  {0}:{1}  {2}" -f (Split-Path $_.File -Leaf), $_.Line, $_.Function) -ForegroundColor Red
    Write-Host ("      {0}" -f $_.Text) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Log with plain -Failure/-Warning, or buffer the line and emit it from the job scriptblock." -ForegroundColor Yellow
exit 1
