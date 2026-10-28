#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'common\Common.NewMenu.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-KeyStroke'
        }, $true))
if ($definitions.Count -ne 1) { throw 'Expected one Get-KeyStroke definition.' }
$returns = @($definitions[0].Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ReturnStatementAst] -and
            $node.Extent.Text.Contains('[System.Management.Automation.Host.KeyInfo]::new(')
        }, $true))
if ($returns.Count -ne 1) { throw 'Expected one native console KeyInfo conversion.' }
$convertKey = [scriptblock]::Create("param(`$ke)`n" + $returns[0].Extent.Text)

function Assert-KeyConversion {
    param(
        [uint32]$NativeFlags,
        [int]$ExpectedFlags,
        [int]$VirtualKeyCode = 65,
        [char]$Character = 'A'
    )
    $record = [pscustomobject]@{
        wVirtualKeyCode = [uint16]$VirtualKeyCode
        UnicodeChar = $Character
        dwControlKeyState = $NativeFlags
    }
    $key = & $convertKey -ke $record
    if ($key -isnot [System.Management.Automation.Host.KeyInfo] -or
        [int]$key.ControlKeyState -ne $ExpectedFlags -or
        $key.VirtualKeyCode -ne $VirtualKeyCode -or $key.Character -ne $Character -or
        -not $key.KeyDown) {
        throw "Native flags $NativeFlags changed the key payload or supported modifier flags."
    }
}

Assert-KeyConversion -NativeFlags 1040 -ExpectedFlags 16
foreach ($flags in 0..0x01ff) {
    Assert-KeyConversion -NativeFlags $flags -ExpectedFlags $flags
    Assert-KeyConversion -NativeFlags ($flags -bor 0x0400) -ExpectedFlags $flags
}
Assert-KeyConversion -NativeFlags ([uint32]::MaxValue) -ExpectedFlags 0x01ff
Assert-KeyConversion -NativeFlags 0x0400 -ExpectedFlags 0 -VirtualKeyCode 38 -Character ([char]0)
Assert-KeyConversion -NativeFlags 0x0500 -ExpectedFlags 0x0100 -VirtualKeyCode 13 -Character ([char]13)

Write-Host 'PASS -- console key conversion ignores unsupported flags and preserves every supported modifier combination.'
