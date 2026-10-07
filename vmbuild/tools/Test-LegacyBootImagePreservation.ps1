<#
.SYNOPSIS
    Verifies healthy main-era boot images are preserved without false warnings.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsLegacyBootImageHealth'
        }, $true))
if ($definition.Count -ne 1) {
    throw "Expected one Get-MemLabsLegacyBootImageHealth definition, found $($definition.Count)."
}
. ([scriptblock]::Create($definition[0].Extent.Text))

$script:BootImages = @(
    [pscustomobject]@{ PackageID = 'PRI00002'; Name = 'Boot image (x64)' }
)
$script:BootWmi = [pscustomobject]@{
    PackageID = 'PRI00002'
    ImagePath = '\\PRI1\SMS_PRI\osd\boot\x64\boot.wim'
    PkgSourcePath = ''
}
$script:ExistingPaths = @('FileSystem::\\PRI1\SMS_PRI\osd\boot\x64\boot.wim')

function Get-CMBootImage { return @($script:BootImages) }
function Get-WmiObject {
    param(
        [string] $Namespace,
        [string] $Class,
        [string] $Filter,
        [string] $ErrorAction
    )
    return $script:BootWmi
}
function Test-Path {
    param([string] $LiteralPath)
    return $LiteralPath -in $script:ExistingPaths
}

$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-One'; BootImageID = 'PRI00002' },
    [pscustomobject]@{ Name = 'MEMLABS-Two'; BootImageID = 'PRI00002' }
)
$healthy = Get-MemLabsLegacyBootImageHealth -TaskSequences $taskSequences `
    -OwningSiteCode PRI
if (-not $healthy.Healthy -or ($healthy.PackageIds -join ',') -ne 'PRI00002' -or
    $healthy.Problems.Count -ne 0) {
    throw 'A healthy referenced main-era boot image was not accepted for preservation.'
}

$script:BootImages = @()
$missing = Get-MemLabsLegacyBootImageHealth -TaskSequences $taskSequences `
    -OwningSiteCode PRI
if ($missing.Healthy -or ($missing.Problems -join ' ') -notmatch 'object.+missing') {
    throw 'A missing referenced boot image did not retain a real warning condition.'
}

$source = Get-Content -LiteralPath $sourcePath -Raw
if ($source -notmatch
    '(?s)if \(\$legacyHealth\.Healthy\).+?intentionally retain healthy main-era boot image.+?else.+?preservation health failed.+?-Warning') {
    throw 'Legacy boot image preservation is not informational for healthy images and warning-only for measured failures.'
}

Write-Host 'PASS -- healthy main-era boot images are preserved without producing a false Phase 8 warning.'
