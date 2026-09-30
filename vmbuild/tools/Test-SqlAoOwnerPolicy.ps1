#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-OwnerPolicy {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

$phase5Path = Join-Path $RootPath 'DSC\phases\Phase5.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($phase5Path, [ref]$tokens, [ref]$errors)
$parseErrors = @($errors | Where-Object {
        $_.ErrorId -notin 'ModuleNotFoundDuringParse', 'MultipleModuleEntriesFoundDuringParse'
    })
Assert-OwnerPolicy ($parseErrors.Count -eq 0) 'Phase 5 parses'

$source = Get-Content -LiteralPath $phase5Path -Raw
$codeTokens = @($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment } |
        ForEach-Object { $_.Text }) -join ' '
Assert-OwnerPolicy (-not ($source -match 'ClusterSetOwnerNodes\s+ClusterSetOwnerNodes')) 'Phase 5 does not invoke universal cluster owner mutation'
Assert-OwnerPolicy (-not ($source -match 'EnsureAgPossibleOwners')) 'Phase 5 does not converge SQL-managed AG owner lists'
Assert-OwnerPolicy (-not ($codeTokens -match 'Set-ClusterOwnerNode')) 'Phase 5 never calls Set-ClusterOwnerNode'
Assert-OwnerPolicy ([regex]::Matches($source, "FailoverMode\s*=\s*'Manual'").Count -ge 2) 'Phase 5 retains ConfigMgr-required MANUAL replica mode'

$alwaysOnHealthResources = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.DynamicKeywordStatementAst] -and
            $node.Extent.Text -match '^\s*Script\s+EnsureAlwaysOnHealth\s*\{'
        }, $true))
Assert-OwnerPolicy ($alwaysOnHealthResources.Count -eq 2) 'Phase 5 converges AlwaysOn_health on both SQLAO nodes'
foreach ($resource in $alwaysOnHealthResources) {
    $resourceSource = $resource.Extent.Text
    Assert-OwnerPolicy ($resourceSource -match 'sys\.server_event_sessions' -and
        $resourceSource -match 'configured\.startup_state\s*=\s*1' -and
        $resourceSource -match 'sys\.dm_xe_sessions') 'AlwaysOn_health TestScript requires configured startup and running state'
    Assert-OwnerPolicy ($resourceSource -match 'WITH \(STARTUP_STATE = ON\)' -and
        $resourceSource -match 'STATE = START') 'AlwaysOn_health SetScript enables startup and starts the session'
    Assert-OwnerPolicy ($resourceSource -match 'THROW 51000') 'AlwaysOn_health convergence fails explicitly when the built-in session is absent'
    Assert-OwnerPolicy ($resourceSource -match 'DependsOn\s*=\s*\$nextDepend') 'AlwaysOn_health convergence follows HADR enablement'
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO owner-policy assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO owner-policy tests passed.'
