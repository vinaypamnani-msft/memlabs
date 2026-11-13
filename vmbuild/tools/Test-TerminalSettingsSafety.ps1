<#
.SYNOPSIS
    Verifies Terminal appearance updates preserve live settings on failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Colors.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Common.Colors.ps1 has parse errors: $($errors -join '; ')" }
$definition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-BackgroundImage'
        }, $true))
if ($definition.Count -ne 1) { throw 'Expected one Set-BackgroundImage definition.' }
. ([scriptblock]::Create($definition[0].Extent.Text))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS  $Message"
}

function Get-FileFingerprint {
    param([string]$Path)
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

function Invoke-TestAppearance {
    $script:LastWarnings = @()
    Set-BackgroundImage -file $image -alignment right -opacityPercent 49 -stretchMode uniform `
        -WarningVariable script:LastWarnings
}

function Assert-NoStagingFiles {
    Assert-True (@(Get-ChildItem -LiteralPath $settingsDirectory -Filter '*.tmp').Count -eq 0) `
        'Failed/successful update leaves no staging files'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-terminal-$([guid]::NewGuid().ToString('N'))"
$savedLocalAppData = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = $testRoot
    $settingsDirectory = Join-Path $testRoot 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    $null = New-Item -Path $settingsDirectory -ItemType Directory -Force
    $settingsPath = Join-Path $settingsDirectory 'settings.json'
    $image = Join-Path $testRoot 'fixture.png'
    [IO.File]::WriteAllBytes($image, @(0))
    $original = '{"defaultProfile":"fixture","custom":{"keep":true},"profiles":{"list":[{"guid":"fixture","name":"Keep me"}]},"themes":[{"name":"UserTheme"}]}'
    $fixture = $original | ConvertFrom-Json
    $padding = ('x' * 16384) + [char]0x00E9
    $fixture.custom | Add-Member NoteProperty padding $padding
    $original = $fixture | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($settingsPath, $original)
    $fingerprint = Get-FileFingerprint $settingsPath
    Set-BackgroundImage -file $image -alignment right -opacityPercent 49 -stretchMode uniform -InJob $true
    Set-BackgroundImage -file (Join-Path $testRoot 'missing.png') -alignment right -opacityPercent 49 -stretchMode uniform
    Assert-True ((Get-FileFingerprint $settingsPath) -ceq $fingerprint -and
        -not (Test-Path -LiteralPath "$settingsPath.memlabs.lock")) `
        'Background jobs and missing images still skip Terminal updates entirely'
    Invoke-TestAppearance
    $updated = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-True ($script:LastWarnings.Count -eq 0 -and $updated.custom.keep -and
        $updated.defaultProfile -eq 'fixture' -and $updated.profiles.list[0].name -eq 'Keep me' -and
        $updated.profiles.defaults.backgroundImageOpacity -eq 0.49 -and
        $updated.theme -eq 'MemLabsActiveTab' -and @($updated.themes).Count -eq 2 -and
        $updated.custom.padding -ceq $padding -and (Get-Item -LiteralPath $settingsPath).Length -gt 16384) `
        'Successful update preserves profiles, user properties and themes while applying appearance'
    Assert-True ((Get-FileFingerprint "$settingsPath.memlabs.bak") -ceq $fingerprint) `
        'Atomic replacement keeps a byte-exact backup of the previous settings'
    $fingerprint = Get-FileFingerprint $settingsPath
    Invoke-TestAppearance
    Assert-True ($script:LastWarnings.Count -eq 0 -and
        (Get-FileFingerprint "$settingsPath.memlabs.bak") -ceq $fingerprint) `
        'Repeated appearance updates safely replace the last-good backup'
    Assert-NoStagingFiles

    foreach ($opacity in @(1, 101)) {
        Set-BackgroundImage -file $image -alignment right -opacityPercent $opacity -stretchMode uniform
        $updated = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $expectedOpacity = if ($opacity -lt 5) { 0.05 } else { 1 }
        Assert-True ($updated.profiles.defaults.backgroundImageOpacity -eq $expectedOpacity) `
            'Appearance update preserves the existing 5-to-100 percent opacity clamp'
    }

    foreach ($invalid in @('{"themes":[{"name":"MemLabsActiveTab",', 'null', '[]', '[{"profiles":{}}]', '{"profiles":null}')) {
        [IO.File]::WriteAllText($settingsPath, $invalid)
        $fingerprint = Get-FileFingerprint $settingsPath
        Invoke-TestAppearance
        Assert-True ($script:LastWarnings.Count -eq 1 -and
            (Get-FileFingerprint $settingsPath) -ceq $fingerprint) `
            'Truncated or structurally invalid settings are preserved with a visible warning'
    }
    [IO.File]::WriteAllText($settingsPath, '{}')
    Invoke-TestAppearance
    $updated = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-True ($script:LastWarnings.Count -eq 0 -and $updated.profiles.defaults.historySize -eq 32768) `
        'Valid minimal Terminal settings gain profile defaults without failure'

    [IO.File]::WriteAllText($settingsPath, $original)
    $fingerprint = Get-FileFingerprint $settingsPath
    $backupFingerprint = Get-FileFingerprint "$settingsPath.memlabs.bak"
    $handle = [IO.File]::Open("$settingsPath.memlabs.lock", [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Invoke-TestAppearance }
    finally { $handle.Dispose() }
    Assert-True ($script:LastWarnings.Count -eq 1 -and
        (Get-FileFingerprint $settingsPath) -ceq $fingerprint) `
        'A competing MemLabs writer cannot modify the live settings'

    $handle = [IO.File]::Open($settingsPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Invoke-TestAppearance }
    finally { $handle.Dispose() }
    Assert-True ($script:LastWarnings.Count -eq 1 -and
        (Get-FileFingerprint $settingsPath) -ceq $fingerprint -and
        (Get-FileFingerprint "$settingsPath.memlabs.bak") -ceq $backupFingerprint) `
        'Failed filesystem replacement preserves both live settings and the last-good backup'
    Assert-NoStagingFiles

    & {
        function ConvertTo-Json {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth)
            process {
                $InputObject | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth $Depth | Out-Null
                throw 'fixture: serialization failed'
            }
        }
        Invoke-TestAppearance
    }
    Assert-True ($script:LastWarnings.Count -eq 1 -and
        (Get-FileFingerprint $settingsPath) -ceq $fingerprint) `
        'Serialization failure cannot truncate the live settings'

    & {
        function ConvertTo-Json {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth)
            process {
                $InputObject | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth $Depth | Out-Null
                '{"incomplete":'
            }
        }
        Invoke-TestAppearance
    }
    Assert-True ($script:LastWarnings.Count -eq 1 -and
        (Get-FileFingerprint $settingsPath) -ceq $fingerprint) `
        'Malformed staged JSON is rejected before replacement'
    Assert-NoStagingFiles

    & {
        function ConvertTo-Json {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [int]$Depth)
            process {
                [IO.File]::WriteAllText($settingsPath, '{"externalEdit":true}')
                $InputObject | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth $Depth
            }
        }
        Invoke-TestAppearance
    }
    $updated = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-True ($script:LastWarnings.Count -eq 1 -and $updated.externalEdit -and
        (Get-FileFingerprint "$settingsPath.memlabs.bak") -ceq $backupFingerprint) `
        'An intervening external edit is preserved rather than overwritten'
    Assert-NoStagingFiles
    Write-Host 'PASS: Terminal settings safety regressions.'
}
finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
