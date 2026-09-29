#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'DSC\phases\InstallAndUpdateSCCM.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s): $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $sourcePath -Name 'Test-DrsForceSendProbeDue')

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

$now = [datetime]'2026-09-29T12:00:00'
$common = @{
    Now                  = $now
    ThresholdMinutes     = 3
    Attempts             = 0
    MaxAttempts          = 2
    LastSend             = $null
    SendCooldownMinutes  = 5
    LastProbe            = $null
    ProbeCooldownMinutes = 2
}

Assert-Equal $false (Test-DrsForceSendProbeDue @common -StuckMinutes 2) 'probe waits for the idle-stuck threshold'
Assert-Equal $true (Test-DrsForceSendProbeDue @common -StuckMinutes 3) 'first self-active probe is due at the threshold'

$afterSkippedProbe = $common.Clone()
$afterSkippedProbe.LastProbe = $now
$afterSkippedProbe.Now = $now.AddSeconds(30)
Assert-Equal $false (Test-DrsForceSendProbeDue @afterSkippedProbe -StuckMinutes 4) 'skipped probe is not repeated every 30-second loop'
$afterSkippedProbe.Now = $now.AddMinutes(2)
Assert-Equal $true (Test-DrsForceSendProbeDue @afterSkippedProbe -StuckMinutes 5) 'skipped probe becomes eligible after two minutes'

$afterRealSend = $common.Clone()
$afterRealSend.Attempts = 1
$afterRealSend.LastSend = $now
$afterRealSend.LastProbe = $now
$afterRealSend.Now = $now.AddMinutes(2)
Assert-Equal $false (Test-DrsForceSendProbeDue @afterRealSend -StuckMinutes 5) 'real send keeps the five-minute send cooldown'
$afterRealSend.Now = $now.AddMinutes(5)
Assert-Equal $true (Test-DrsForceSendProbeDue @afterRealSend -StuckMinutes 8) 'second real send is eligible after five minutes'

$maxed = $common.Clone()
$maxed.Attempts = 2
Assert-Equal $false (Test-DrsForceSendProbeDue @maxed -StuckMinutes 30) 'maximum real send attempts remains enforced'

$source = [IO.File]::ReadAllText($sourcePath)
Assert-Equal $true ($source -match '\$forceSendProbeCooldownMin = 2') 'production probe cooldown is two minutes'
Assert-Equal $true ($source -match '\$forceSendLastProbe\[\$PSVM\.VmName\] = \$now') 'production records every SQL self-active probe'
Assert-Equal $false ($source.Contains('DRS force-send skipped:')) 'old every-loop skipped message is removed'
Assert-Equal $false ($source -match '\$forceSendLastAttempt\[\$PSVM\.VmName\] = \$lastFs') 'skipped probes no longer roll back cooldown state'
Assert-Equal $true ($source -match 'elseif \(\$fsResult\.Skipped\)[\s\S]+?else \{[\s\S]+?\$forceSendCount\[\$PSVM\.VmName\] = \$attemptsSoFar \+ 1') 'only a real send consumes an attempt'
Assert-Equal $true ($source -match '\$r\.Groups -eq 0[\s\S]+?\$r\.SkipReason = ''NoGlobalGroups''') 'zero-group query consumes no real send attempt'
$resetIndex = $source.IndexOf('if ($linkInFailedState -or $linkIsProgressing -or $replicationStatus.GlobalInitPercentage -lt 100)')
$percentageGateIndex = $source.IndexOf('if ($replicationStatus.GlobalInitPercentage -ge 100)')
Assert-Equal $true ($resetIndex -ge 0 -and $resetIndex -lt $percentageGateIndex) 'idle continuity resets before the 100-percent gate'

if ($script:Failures -gt 0) {
    throw "$script:Failures DRS force-send cooldown test(s) failed."
}

Write-Host 'ALL DRS FORCE-SEND COOLDOWN TESTS PASSED'
