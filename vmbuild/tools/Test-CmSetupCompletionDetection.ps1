#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$sourcePath = Join-Path $RootPath 'vmbuild\DSC\phases\InstallAndUpdateSCCM.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "$sourcePath has $($errors.Count) parse error(s)." }
$functionAsts = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in 'Get-CmSetupFailureLine', 'Get-CmSetupCompletionFailureReason' }, $true))
if ($functionAsts.Count -ne 2) { throw "Expected two setup completion functions, found $($functionAsts.Count)." }
foreach ($functionName in 'Get-CmSetupFailureLine', 'Get-CmSetupCompletionFailureReason') {
    $functionAst = @($functionAsts | Where-Object Name -eq $functionName)
    if ($functionAst.Count -ne 1) { throw "Expected one $functionName function, found $($functionAst.Count)." }
    . ([scriptblock]::Create($functionAst[0].Extent.Text))
}

$script:Failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

Assert-Equal 'setup.exe exited with code 7' (Get-CmSetupFailureLine -Lines @() -ExitCode 7) 'nonzero setup exit code is fatal without log text'
Assert-Equal 'Setup failed to configure SQL Service Broker. Possible Cause: Each Configuration Manager site must have its own SQL Server instance.' `
    (Get-CmSetupFailureLine -ExitCode 0 -Lines @('~Setup failed to configure SQL Service Broker. Possible Cause: Each Configuration Manager site must have its own SQL Server instance.  $$<Configuration Manager Setup><09-11-2026 08:55:59.872+240>')) `
    'real SQL Service Broker terminal failure is fatal'
Assert-Equal 'Setup has encountered fatal errors during database initialization.' `
    (Get-CmSetupFailureLine -ExitCode 0 -Lines @('~Setup has encountered fatal errors during database initialization.  $$<Configuration Manager Setup><09-11-2026 03:06:52.311+240>')) `
    'database initialization fatal remains detected'
Assert-Equal 'Failed Configuration Manager Server Setup.' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('Failed Configuration Manager Server Setup. $$<Configuration Manager Setup>')) 'failed setup banner is fatal'
Assert-Equal 'Configuration Manager Setup cannot be completed.' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('Configuration Manager Setup cannot be completed. $$<Configuration Manager Setup>')) 'cannot-be-completed message is fatal'
$administrativeRightsResult = Get-CmSetupFailureLine -ExitCode 0 -Lines @('Computer account doesn''t have administrative rights. $$<Configuration Manager Setup>')
Assert-Equal "Computer account doesn't have administrative rights." $administrativeRightsResult 'administrative-rights failure is fatal'
Assert-Equal 'Setup failed to configure SQL Service Broker.' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('Setup failed to configure SQL Service Broker. $$<Configuration Manager Setup>')) 'unprefixed setup-failed form is fatal'
Assert-Equal 'Setup failed to configure SQL Service Broker.' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('~Setup failed to configure SQL Service Broker. $$<Configuration Manager Setup>')) 'ConfigMgr-prefixed setup-failed form is fatal'
Assert-Equal 'Setup failed to configure SQL Service Broker.' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('~Setup failed to configure SQL Service Broker. $$<Configuration Manager Setup>', '~~===================== Completed Configuration Manager Server Setup =====================')) 'fatal before completion banner remains fatal'
Assert-Equal '' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('Diagnostic replayed prior text: ~Setup failed to configure SQL Service Broker.')) 'embedded prior setup-failure text is not treated as the terminal line'
Assert-Equal '' (Get-CmSetupFailureLine -ExitCode 0 -Lines @('ERROR: Failed to connect to ROOT\SMS.', '~~===================== Completed Configuration Manager Server Setup =====================')) 'startup ROOT SMS probe and completion banner are not treated as terminal failure'
Assert-Equal "setup.exe returned without installing the requested Configuration Manager console module at ''" `
    (Get-CmSetupCompletionFailureReason -LogLines @() -ExitCode 0 -ConfigurationManagerModule '' -ConfigurationManagerModuleExists $false) `
    'missing console module blocks completion'
Assert-Equal "setup.exe returned without installing the requested Configuration Manager console module at 'E:\ConfigMgr\AdminConsole\bin\ConfigurationManager.psd1'" `
    (Get-CmSetupCompletionFailureReason -LogLines @() -ExitCode 0 -ConfigurationManagerModule 'E:\ConfigMgr\AdminConsole\bin\ConfigurationManager.psd1' -ConfigurationManagerModuleExists $false) `
    'missing measured console path blocks completion'
Assert-Equal '' `
    (Get-CmSetupCompletionFailureReason -LogLines @('~~===================== Completed Configuration Manager Server Setup =====================') -ExitCode 0 -ConfigurationManagerModule 'E:\ConfigMgr\AdminConsole\bin\ConfigurationManager.psd1' -ConfigurationManagerModuleExists $true) `
    'clean exit with installed console permits completion'
Assert-Equal 'Setup failed to configure SQL Service Broker.' `
    (Get-CmSetupCompletionFailureReason -LogLines @('~Setup failed to configure SQL Service Broker. $$<Configuration Manager Setup>') -ExitCode 0 -ConfigurationManagerModule 'E:\ConfigMgr\AdminConsole\bin\ConfigurationManager.psd1' -ConfigurationManagerModuleExists $true) `
    'terminal setup failure overrides an installed console'

$source = Get-Content -LiteralPath $sourcePath -Raw
Assert-Equal $true ($source -match '(?s)function Start-CmSetupProcessWithBreadcrumb.+?return Start-Process.+?-Wait -PassThru -ErrorAction Stop' -and $source -match '(?s)\$setupProcess\s*=\s*Start-CmSetupProcessWithBreadcrumb.+?catch \{.+?return\s+\}\s*\$setupExitCode\s*=\s*\$setupProcess\.ExitCode') 'initial setup launch is breadcrumb-gated and immediately preserves its process exit code'
Assert-Equal 1 @([regex]::Matches($source, '(?s)\$setupProcess\s*=\s*Start-Process -Filepath \(\$CMInstallationFile\).+?-Wait -PassThru\s+\$setupExitCode\s*=\s*\$setupProcess\.ExitCode')).Count 'prerequisite retry immediately preserves its process exit code'
Assert-Equal $true ($source -match 'Get-CmSetupCompletionFailureReason.+?-ExitCode \$setupExitCode') 'final setup exit code flows into the completion decision'
Assert-Equal $true ($source -match '(?s)\$completionFailureReason\s*=\s*Get-CmSetupCompletionFailureReason.+?if \(\$completionFailureReason\) \{.+?Write-DscStatus.+?-Failure\s+return\s+\}.+?InstallSCCM\.Status = ''Completed''') 'executed completion decision and failure return precede the Completed status write'

if ($script:Failures -gt 0) { throw "$script:Failures ConfigMgr setup completion detection test(s) failed." }
Write-Host 'ALL CONFIGMGR SETUP COMPLETION DETECTION TESTS PASSED'