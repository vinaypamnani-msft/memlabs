<#
.SYNOPSIS
    Verifies stale BDC cleanup and terminal promotion failure semantics.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-True {
    param ([bool] $Condition, [string] $What)

    if (-not $Condition) { $script:Failures++ }
    $status = if ($Condition) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors | Where-Object { $null -ne $_ }).Count -ne 0) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Write-Log {
    param([string] $Message, [switch] $Failure, [switch] $OutputStream)
    if ($OutputStream) { Write-Output ([pscustomobject]@{ LogLevel = 3; Text = $Message }) }
}

$phases = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Phases.ps1') -Raw
$common = Get-Content -LiteralPath (Join-Path $RootPath 'Common.ps1') -Raw
$module = Get-Content -LiteralPath (Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1') -Raw

Assert-True ($phases -match "if \(\`$item\.role -eq 'BDC'\)") 'Phase 1 has BDC-specific stale-object cleanup'
Assert-True ($phases -match 'Remove-StaleAdComputer.+-ComputerName \$item\.vmName.+BDC rebuild') 'BDC cleanup removes the replacement VM controller object'
Assert-True ($phases -match "\`$adOutcome.+-notin @\('Removed', 'NotPresent'\).+\`$blockingAdObjects\.Add\(\`$item\.vmName\)") 'unknown or failed BDC cleanup blocks the rebuild'
Assert-True ($phases -match 'Remove-StaleAdDomainControllerMetadata.+-ComputerName \$item\.vmName.+BDC rebuild') 'BDC cleanup removes the replacement server and NTDS Settings subtree'
Assert-True ($phases -match "\`$metadataOutcome.+-notin @\('Removed', 'NotPresent'\).+Sites/Services metadata") 'unknown or failed server-metadata cleanup blocks the rebuild'
Assert-True ($common.Contains('$escapedName = $name.Replace(''\'', ''\5c'').Replace(''*'', ''\2a'').Replace(''('', ''\28'').Replace('')'', ''\29'').Replace([string][char]0, ''\00'')')) 'server-metadata lookup escapes LDAP filter metacharacters without unavailable framework types'
Assert-True ($common -notmatch 'DirectoryServices\.Protocols\.Utilities') 'server-metadata cleanup avoids the unavailable LDAP Utilities type'
. (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.Phases.ps1') -Name 'Assert-StaleAdCleanupSucceeded')
$cleanupFailure = $null
$cleanupOutput = @(& {
        try { Assert-StaleAdCleanupSucceeded -BlockingAdObjects @('STALE-BDC') -DCName 'DC1' -Phase 1 }
        catch { $script:cleanupFailure = $_ }
    })
Assert-True ([bool]$cleanupFailure) 'failed stale-object cleanup throws before VM dispatch'
Assert-True ($cleanupFailure.Exception.Message -like '*WILL block the rebuild*' -and $cleanupFailure.Exception.Message -like '*STALE-BDC*') 'cleanup failure names the blocking object'
Assert-True ($cleanupOutput.Count -eq 0) 'cleanup failure emits no success-stream value before throwing'
Assert-StaleAdCleanupSucceeded -BlockingAdObjects @() -DCName 'DC1' -Phase 1
Assert-True $true 'empty stale-object cleanup result continues'

Assert-True ($module -match '\$promotionErrors = \[System\.Collections\.Generic\.List\[string\]\]::new\(\)') 'promotion captures error records before invoking ADDSDeployment'
Assert-True ($module -match '\$promotionErrors\.Add\(\$_\.Exception\.Message\)') 'promotion records ADDSDeployment error messages'
Assert-True ($module -match '-ErrorVariable promotionCommandErrors') 'promotion captures non-terminating ADDSDeployment errors before scrubbing the error stream'
Assert-True ($module -match '(?s)if \(-not \$promotionVerified\) \{.*?throw "Domain controller promotion') 'missing SysVol is a terminal promotion failure'
$failureIndex = $module.IndexOf('throw "Domain controller promotion')
$rebootIndex = $module.IndexOf('Write-Verbose "PromoteDomainController: Requesting reboot to complete promotion"')
Assert-True ($failureIndex -ge 0 -and $rebootIndex -gt $failureIndex) 'failed promotion throws before requesting reboot'

function Test-NonTerminatingPromotionFailure {
    [CmdletBinding()]
    param()
    Write-Error 'The specified account already exists.'
}
$capturedPromotionErrors = @()
$null = Test-NonTerminatingPromotionFailure -ErrorAction SilentlyContinue -ErrorVariable capturedPromotionErrors 2>&1
Assert-True ($capturedPromotionErrors.Count -eq 1 -and $capturedPromotionErrors[0].Exception.Message -like '*specified account already exists*') 'ErrorVariable preserves a silenced non-terminating promotion error'

if ($script:Failures -ne 0) { throw "$script:Failures BDC promotion recovery test(s) failed" }

Write-Host 'ALL BDC PROMOTION RECOVERY TESTS PASSED' -ForegroundColor Green