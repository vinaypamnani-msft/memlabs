<#
.SYNOPSIS
    Verifies VM-note property updates preserve Boolean and numeric types.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$commonPath = Join-Path $RootPath 'Common.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$commonPath has parse errors: $($errors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Update-VMNoteProperty'
        }, $true))
if ($definitions.Count -ne 1) {
    throw "Expected one Update-VMNoteProperty definition, found $($definitions.Count)."
}
. ([scriptblock]::Create($definitions[0].Extent.Text))

$script:Note = [pscustomobject]@{ vmName = 'TYPE-VM' }
function Get-VMNote { param([string] $VMName) return $script:Note }
function Set-VMNote {
    param([string] $VmName, [object] $VmNote)
    $script:Note = $VmNote
}
function Assert-TypeAndValue {
    param($ExpectedType, $ExpectedValue, $ActualValue, [string] $Message)
    if ($ActualValue.GetType() -ne $ExpectedType -or "$ActualValue" -ne "$ExpectedValue") {
        throw "$Message`nExpected: $($ExpectedType.FullName) [$ExpectedValue]`nActual:   $($ActualValue.GetType().FullName) [$ActualValue]"
    }
}

Update-VMNoteProperty -VmName TYPE-VM -PropertyName useDatabaseReplica -PropertyValue $false
Assert-TypeAndValue -ExpectedType ([bool]) -ExpectedValue $false `
    -ActualValue $script:Note.useDatabaseReplica `
    -Message 'Boolean false was coerced to a non-Boolean VM-note value.'

Update-VMNoteProperty -VmName TYPE-VM -PropertyName InstallSUP -PropertyValue $true
Assert-TypeAndValue -ExpectedType ([bool]) -ExpectedValue $true `
    -ActualValue $script:Note.InstallSUP `
    -Message 'Boolean true was coerced to a non-Boolean VM-note value.'

Update-VMNoteProperty -VmName TYPE-VM -PropertyName virtualProcs -PropertyValue 6
Assert-TypeAndValue -ExpectedType ([int]) -ExpectedValue 6 `
    -ActualValue $script:Note.virtualProcs `
    -Message 'Integer VM-note value was coerced to a string.'

Update-VMNoteProperty -VmName TYPE-VM -PropertyName siteCode -PropertyValue '001'
Assert-TypeAndValue -ExpectedType ([string]) -ExpectedValue '001' `
    -ActualValue $script:Note.siteCode `
    -Message 'String VM-note value did not preserve its text/type.'

Write-Host 'PASS -- Update-VMNoteProperty preserves native scalar types.'
