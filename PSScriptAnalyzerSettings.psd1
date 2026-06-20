# PSScriptAnalyzerSettings.psd1
#
# Curated PSScriptAnalyzer ruleset for MemLabs, intended for MANUAL / CI / pre-commit scans:
#
#     Invoke-ScriptAnalyzer -Path <file> -Settings .\PSScriptAnalyzerSettings.psd1
#
# IMPORTANT: This is deliberately NOT wired into the VS Code editor
# (powershell.scriptAnalysis.settingsPath is intentionally left unset). The editor's built-in
# analysis already surfaces a small curated subset (~the rules below). Pointing it at
# PSScriptAnalyzer's *full* default ruleset (IncludeDefaultRules = $true) explodes the Problems
# panel -- e.g. 230 findings on Common.ps1 alone (PSAvoidGlobalVars x76,
# PSAvoidUsingEmptyCatchBlock x62, ...) -- which is the opposite of reducing commit noise.
#
# Strategy ("Both"):
#   - This file = the repo-WIDE correctness rule list used for scripted scans.
#   - Per-LOCATION false positives are suppressed inline at the function/param block with
#       [Diagnostics.CodeAnalysis.SuppressMessageAttribute('<RuleName>', '', Justification = '...')]
#
# NOTE: DSC "Could not find the module '...'" / "Undefined DSC resource '...'" diagnostics come
#       from the PowerShell extension's DSC compilation, NOT PSScriptAnalyzer, so they cannot be
#       silenced here or via SuppressMessageAttribute. They only clear when the referenced DSC
#       modules are resolvable on $env:PSModulePath.

@{
    # Only run the high-signal correctness rules (the ones that have actually mattered here).
    # Add to this list deliberately; avoid IncludeDefaultRules = $true (see header).
    IncludeRules = @(
        'PSUseDeclaredVarsMoreThanAssignments'   # assigned but never used
        'PSPossibleIncorrectComparisonWithNull'  # $null should be on the left of -eq/-ne
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSAvoidAssignmentToAutomaticVariable'   # e.g. assigning to $args / $input
        'PSUseApprovedVerbs'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
