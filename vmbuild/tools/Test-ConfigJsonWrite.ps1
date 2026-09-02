<#
.SYNOPSIS
    Prove Write-ConfigJsonFile cannot destroy an existing config when the write fails.

.DESCRIPTION
    Save-Config used to write with `$config | ConvertTo-Json | Out-File $path`, which
    truncates the destination the instant it opens it. Anything that interrupts the
    write -- crash, full disk, the file being held open -- replaced a valid config with
    a half-written one, and the damage only surfaced later as a confusing load failure.

    Write-ConfigJsonFile writes to a sibling temp file, reads it back through
    ConvertFrom-Json to prove it parses, then File.Replace's it into place.

    The claim that matters is the negative one: when the replace CANNOT happen, the
    original must still be there afterwards. That is not inferred here. The test holds the
    destination open with FileShare.ReadWrite so File.Replace fails while a plain truncating
    write would still get in, then asserts the call threw, the original file is byte-identical,
    and no .tmp/.bak was orphaned.

    The function is lifted out of the shipped file with the AST, so this always exercises
    the code that actually ships rather than a copy that can drift.

    Preferences are deliberately left at their defaults. Set-StrictMode or
    $ErrorActionPreference = 'Stop' would run the function under rules production never
    applies, and could fail it for something that works in the real tool.

.PARAMETER RootPath
    The vmbuild folder. Defaults to the parent of this script, so it works from any clone.

.PARAMETER SourceFile
    Path of the file defining Write-ConfigJsonFile, relative to RootPath.

.PARAMETER FunctionName
    Function to extract and exercise.

.EXAMPLE
    .\Test-ConfigJsonWrite.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-ConfigJsonWrite.ps1
    Run it under Windows PowerShell 5.1 as well; genconfig loads under both engines.
#>
[CmdletBinding()]
param (
    [string]$RootPath,
    [string]$SourceFile = 'common\Common.GenConfig.ConfigFiles.ps1',
    [string]$FunctionName = 'Write-ConfigJsonFile'
)

# $PSScriptRoot is empty inside a param() default under Windows PowerShell 5.1.
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string]$What)

    $ok = ("$Expected" -eq "$Actual")
    if (-not $ok) { $script:Failures++ }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $color
    if (-not $ok) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$definition = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
        }, $true))
if ($definition.Count -ne 1) {
    Write-Host "SETUP FAIL: expected 1 definition of $FunctionName in $SourceFile, found $($definition.Count)" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($definition[0].Extent.Text))

Write-Host "engine   : $($PSVersionTable.PSVersion)"
Write-Host "source   : $sourcePath"
Write-Host "function : $FunctionName"
Write-Host ''

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('configjson-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir
$target = Join-Path $workDir 'config.json'

function Get-OrphanCount {
    @(Get-ChildItem -LiteralPath $workDir -Force | Where-Object { $_.FullName -ne $target }).Count
}

function New-SampleConfig {
    param ([string]$DomainName, [int]$Serial)
    [pscustomobject]@{
        vmOptions       = [pscustomobject]@{ domainName = $DomainName }
        serial          = $Serial
        virtualMachines = @([pscustomobject]@{ vmName = 'SAMPLE'; role = 'DC' })
    }
}

try {
    $first = New-SampleConfig -DomainName 'first.example' -Serial 1
    & $FunctionName -Config $first -Path $target
    Assert-Equal $true (Test-Path -LiteralPath $target) 'creates the file when none exists'
    Assert-Equal 'first.example' (Get-Content -LiteralPath $target -Raw | ConvertFrom-Json).vmOptions.domainName 'content round-trips through ConvertFrom-Json'
    Assert-Equal 0 (Get-OrphanCount) 'no temp or backup file left after create'

    $second = New-SampleConfig -DomainName 'second.example' -Serial 2
    & $FunctionName -Config $second -Path $target
    Assert-Equal 'second.example' (Get-Content -LiteralPath $target -Raw | ConvertFrom-Json).vmOptions.domainName 'overwrite replaces the previous content'
    Assert-Equal 0 (Get-OrphanCount) 'no temp or backup file left after overwrite'

    # The reason the function exists: a write that cannot complete must not consume the original.
    $contentBefore = Get-Content -LiteralPath $target -Raw
    $threw = $false
    # Share must permit writes. FileShare.None blocks the open itself, so a naive truncating
    # implementation fails identically to this one and the assertions below prove nothing.
    $lock = [System.IO.File]::Open($target, 'Open', 'Read', 'ReadWrite')
    try {
        & $FunctionName -Config (New-SampleConfig -DomainName 'third.example' -Serial 3) -Path $target
    }
    catch { $threw = $true }
    finally { $lock.Dispose() }

    Assert-Equal $true $threw 'a blocked write throws instead of reporting success'
    Assert-Equal $contentBefore (Get-Content -LiteralPath $target -Raw) 'the existing config survives a blocked write'
    Assert-Equal 0 (Get-OrphanCount) 'no temp or backup file left after a blocked write'

    $missingThrew = $false
    try { & $FunctionName -Config $first -Path (Join-Path $workDir 'no-such-dir\config.json') } catch { $missingThrew = $true }
    Assert-Equal $true $missingThrew 'a missing target directory is refused up front'
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0
