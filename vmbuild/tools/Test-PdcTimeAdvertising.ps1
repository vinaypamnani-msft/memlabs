<#
.SYNOPSIS
    Verifies forest-root PDC time-server advertisement and Phase 11 recovery.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected"; Write-Host "      actual:   $Actual" }
}

function Get-TestNestedScriptBlock {
    param ([string] $Path, [string] $FunctionName, [string] $VariableName)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName }, $true))
    $assignment = @($function[0].FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $VariableName }, $true))
    if ($function.Count -ne 1 -or $assignment.Count -ne 1) { throw "Could not uniquely locate $VariableName in $FunctionName" }
    return $assignment[0].Right.Expression.ScriptBlock.GetScriptBlock()
}

function Get-DscScriptResourceBlock {
    param ([string] $Path, [string] $ResourceName, [string] $PropertyName)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ -and $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    if ($parseErrors.Count -ne 0) { throw "$Path has parse errors: $($parseErrors.Message -join '; ')" }
    $resource = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.DynamicKeywordStatementAst] -and
                $node.Extent.Text -match "^\s*Script\s+$ResourceName\s*\{"
            }, $true))
    if ($resource.Count -ne 1) { throw "Expected one Script $ResourceName resource, found $($resource.Count)" }
    $hashtable = @($resource[0].FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true))[0]
    $pair = @($hashtable.KeyValuePairs | Where-Object { $_.Item1.Value -eq $PropertyName })
    if ($pair.Count -ne 1) { throw "Expected one $PropertyName property in Script $ResourceName, found $($pair.Count)" }
    $expression = @($pair[0].Item2.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true))
    if ($expression.Count -ne 1) { throw "Expected one scriptblock for $PropertyName, found $($expression.Count)" }
    $scriptText = $expression[0].ScriptBlock.Extent.Text.Trim()
    return [scriptblock]::Create($scriptText.Substring(1, $scriptText.Length - 2))
}

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @()
$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:ServiceStatus = 'Running'
$script:W32tmExitCode = 0
$script:W32tmErrorText = $null
$script:W32tmCount = 0
$script:RestartCount = 0
$script:SetCount = 0

function Get-ADDomain {
    $pdcEmulator = $script:PdcName
    if ($script:PdcSequence.Count -gt 0) {
        $pdcEmulator = $script:PdcSequence[0]
        if ($script:PdcSequence.Count -eq 1) { $script:PdcSequence = @() }
        else { $script:PdcSequence = @($script:PdcSequence[1..($script:PdcSequence.Count - 1)]) }
    }
    [pscustomobject]@{ PDCEmulator = $pdcEmulator }
}
function Get-ItemPropertyValue {
    param($LiteralPath, $Name, $ErrorAction)
    if ($Name -eq 'AnnounceFlags') { return $script:AnnounceFlags }
    return $script:NtpServerEnabled
}
function Get-Service { param($Name, $ErrorAction); [pscustomobject]@{ Status = $script:ServiceStatus } }
function Set-ItemProperty {
    param($LiteralPath, $Name, $Type, $Value, $ErrorAction)
    $script:SetCount++
    $script:NtpServerEnabled = $Value
}
function Restart-Service {
    param($Name, [switch]$Force, $ErrorAction)
    $script:RestartCount++
    $script:AnnounceFlags = 5
    $script:ServiceStatus = 'Running'
}
function Start-Sleep { param($Seconds) }
function w32tm.exe {
    $script:W32tmCount++
    if ($script:W32tmErrorText) { Write-Error $script:W32tmErrorText }
    $global:LASTEXITCODE = $script:W32tmExitCode
}

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$phase2Path = Join-Path $RootPath 'DSC\phases\Phase2DC.ps1'
$probe = Get-TestNestedScriptBlock -Path $validationPath -FunctionName 'Test-DCFunctionality' -VariableName '$ensurePdcTimeAdvertising'
$phase2Get = Get-DscScriptResourceBlock -Path $phase2Path -ResourceName ConfigurePdcTimeServer -PropertyName GetScript
$phase2Test = Get-DscScriptResourceBlock -Path $phase2Path -ResourceName ConfigurePdcTimeServer -PropertyName TestScript
$phase2Set = Get-DscScriptResourceBlock -Path $phase2Path -ResourceName ConfigurePdcTimeServer -PropertyName SetScript
$phase2Text = Get-Content -LiteralPath $phase2Path -Raw

Write-Host "engine : $($PSVersionTable.PSVersion)"
Assert-Equal $true ($phase2Text -match 'Script ConfigurePdcTimeServer' -and $phase2Text -match '/config /reliable:yes /update' -and $phase2Text -match 'NtpServer.*Enabled') 'Phase 2 configures the forest-root PDC time server'

$env:COMPUTERNAME = 'DC1'
$phase2State = @(& $phase2Get)
Assert-Equal 1 $phase2State.Count 'Phase 2 GetScript returns exactly one state object'
Assert-Equal @('Result') @($phase2State[0].Keys) 'Phase 2 GetScript returns the DSC Script resource schema'
Assert-Equal $true ($phase2State[0].Result -match 'PdcEmulator=DC1\.memlabs\.test; AnnounceFlags=10; NtpServerEnabled=0') 'Phase 2 GetScript reports diagnostic state'
Assert-Equal $false (& $phase2Test) 'Phase 2 detects unreliable time advertisement on the PDC'
$phase2SetOutput = @(& $phase2Set)
Assert-Equal 0 $phase2SetOutput.Count 'Phase 2 SetScript emits no success-stream output'
Assert-Equal $true (& $phase2Test) 'Phase 2 verifies repaired PDC time advertisement'

$script:PdcName = 'OTHERDC.memlabs.test'
$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:W32tmCount = 0
$script:RestartCount = 0
$script:SetCount = 0
Assert-Equal $true (& $phase2Test) 'Phase 2 treats a non-PDC as not applicable'
$phase2SetOutput = @(& $phase2Set)
Assert-Equal 0 $phase2SetOutput.Count 'Phase 2 non-PDC SetScript returns no output'
Assert-Equal $true ($script:W32tmCount -eq 0 -and $script:SetCount -eq 0 -and $script:RestartCount -eq 0) 'Phase 2 does not alter a former PDC'

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @('DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$null = & $phase2Set
Assert-Equal $true ($script:W32tmCount -eq 1 -and $script:SetCount -eq 0 -and $script:RestartCount -eq 0) 'Phase 2 stops when ownership changes after w32tm configuration'

$script:PdcSequence = @('DC1.memlabs.test', 'DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$null = & $phase2Set
Assert-Equal $true ($script:W32tmCount -eq 1 -and $script:SetCount -eq 1 -and $script:RestartCount -eq 0) 'Phase 2 stops when ownership changes after enabling the NTP server provider'

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @()
$script:W32tmExitCode = 5
$script:W32tmErrorText = 'simulated native stderr'
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$phase2Failure = $null
$phase2FailureOutput = @()
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Stop'
    try { $phase2FailureOutput = @(& $phase2Set) } catch { $phase2Failure = $_.Exception.Message }
}
finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
Assert-Equal $true ($phase2Failure -match 'exit 5') 'Phase 2 reports the w32tm exit code under stop preference and stderr'
Assert-Equal 0 $phase2FailureOutput.Count 'Phase 2 suppresses w32tm failure-stream output'
Assert-Equal $true ($script:W32tmCount -eq 1 -and $script:SetCount -eq 0 -and $script:RestartCount -eq 0) 'Phase 2 stops mutation after w32tm failure'

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @()
$script:W32tmExitCode = 0
$script:W32tmErrorText = $null
$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $true
Assert-Equal $true ($result.Passed -and $result.Changed) 'configured BDC is repaired when it owns the PDC role'
Assert-Equal $true ($script:W32tmCount -eq 1 -and $script:SetCount -eq 1 -and $script:RestartCount -eq 1) 'PDC repair runs on the configured BDC'

$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $false
Assert-Equal $true $result.Passed 'unreliable PDC time configuration is repaired'
Assert-Equal $true $result.Changed 'repair reports a changed state'
Assert-Equal 5 $script:AnnounceFlags 'repair sets always-time-server and always-reliable flags'
Assert-Equal 1 $script:NtpServerEnabled 'repair enables the NTP server provider'
Assert-Equal 1 $script:RestartCount 'repair restarts W32Time once'

$script:RestartCount = 0
$script:SetCount = 0
$result = & $probe $false
Assert-Equal $true ($result.Passed -and -not $result.Changed) 'healthy PDC state is idempotent'
Assert-Equal 0 $script:RestartCount 'healthy PDC state does not restart W32Time'
Assert-Equal 0 $script:SetCount 'healthy PDC state does not rewrite the registry'

$script:PdcName = 'OTHERDC.memlabs.test'
$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $true
Assert-Equal $true ($result.Passed -and -not $result.Changed) 'configured BDC is left unchanged when it does not own the PDC role'
Assert-Equal $true ($script:W32tmCount -eq 0 -and $script:SetCount -eq 0 -and $script:RestartCount -eq 0) 'non-PDC BDC performs no time-server mutation'

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @('DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $false
Assert-Equal $true ($result.Passed -and -not $result.Changed -and $script:W32tmCount -eq 0) 'Phase 11 stops before w32tm when PDC ownership changes'

$script:PdcSequence = @('DC1.memlabs.test', 'DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $false
Assert-Equal $true (-not $result.Passed -and $script:W32tmCount -eq 1 -and $script:SetCount -eq 0 -and $script:RestartCount -eq 0) 'Phase 11 stops after w32tm when PDC ownership changes'

$script:PdcSequence = @('DC1.memlabs.test', 'DC1.memlabs.test', 'DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $false
Assert-Equal $true (-not $result.Passed -and $script:W32tmCount -eq 1 -and $script:SetCount -eq 1 -and $script:RestartCount -eq 0) 'Phase 11 stops after the registry mutation when PDC ownership changes'

$script:PdcSequence = @('DC1.memlabs.test', 'DC1.memlabs.test', 'DC1.memlabs.test', 'DC1.memlabs.test', 'OTHERDC.memlabs.test')
$script:W32tmCount = 0
$script:SetCount = 0
$script:RestartCount = 0
$result = & $probe $false
Assert-Equal $true (-not $result.Passed -and $script:W32tmCount -eq 1 -and $script:SetCount -eq 1 -and $script:RestartCount -eq 1) 'Phase 11 does not report success after ownership changes following restart'

$script:PdcName = 'DC1.memlabs.test'
$script:PdcSequence = @()
$script:AnnounceFlags = 10
$script:NtpServerEnabled = 0
$script:W32tmExitCode = 5
$script:W32tmErrorText = 'simulated native stderr'
$result = & $probe $false
Assert-Equal $false $result.Passed 'w32tm failure is reported'
Assert-Equal $true ($result.Message -match 'exit 5') 'w32tm failure retains its exit code'

if ($script:Failures -gt 0) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All PDC time-advertising checks passed.'