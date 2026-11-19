<#
.SYNOPSIS
    Verifies guarded tool-injection recovery and replacement of running LogMachine.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$sourcePath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw

$initial = [regex]::Match(
    $source,
    '(?s)if \(-not \$injectedOk\)\s*\{\s*Write-Log "([^"]*Initial tool injection[^"]*)"([^\r\n]*)'
)
if (-not $initial.Success) {
    throw 'Phase 2 is missing the initial tool-injection recovery diagnostic.'
}
if ($initial.Groups[2].Value -match '-Warning|-Failure|-OutputStream') {
    throw 'Initial tool-injection failure is classified before guarded recovery finishes.'
}
if ($source -notmatch '(?s)if \(-not \$injectedOk\)\s*\{.+?Wait-ForVM.+?Install-Tools.+?Tool injection recovered successfully after guarded guest recovery\." -OutputStream') {
    throw 'Phase 2 does not report successful guarded tool-injection recovery.'
}
if ($source -notmatch '(?s)Tool injection still failing after guarded guest recovery\." -Warning -OutputStream.+?Tool injection FAILED.+?-Failure -OutputStream') {
    throw 'Terminal tool-injection failure is not surfaced after recovery is exhausted.'
}

Write-Host 'PASS -- Phase 2 classifies tool injection only after guarded recovery completes.'

function Assert-ToolReplacement {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'Common.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Common.ps1 has parse errors: $($parseErrors -join '; ')" }
$copyTool = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ToolToVM'
    }, $true)
$expandAssignment = $copyTool.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'expandToolsBundles'
    }, $true)
Assert-ToolReplacement ($null -ne $expandAssignment) 'Tool delivery is missing its shared guest bundle expander.'
$expandNode = $expandAssignment.Find({
        param($node) $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
Assert-ToolReplacement (@([regex]::Matches($copyTool.Extent.Text, '-ScriptBlock \$expandToolsBundles\b')).Count -eq 2) `
    'ISO and direct-copy delivery must both use the tested guest bundle expander.'

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-tool-replacement-' + [guid]::NewGuid().ToString('N'))
$guestRoot = Join-Path $tempRoot 'guest'
$isoRoot = Join-Path $tempRoot 'iso'
$null = New-Item -ItemType Directory -Path $guestRoot, $isoRoot -Force
$escapedGuestRoot = $guestRoot.Replace("'", "''") + '\'
$guestText = $expandNode.ScriptBlock.GetScriptBlock().ToString().Replace("'C:\'", "'$escapedGuestRoot'")
$expandBundles = [scriptblock]::Create($guestText)
$ownedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$script:ToolsIsoDrive = 'MLToolsIso' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$stopMocked = $false

function New-TestToolBundle {
    param([string]$Path, [switch]$LogMachine)
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entryName = if ($LogMachine) { 'tools/LogMachine/LogMachine.exe' } else { 'tools/other.txt' }
        $writer = [IO.StreamWriter]::new($archive.CreateEntry($entryName).Open())
        try { $writer.Write('replacement tool bytes') }
        finally { $writer.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Start-TestLogMachine {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $Path -Force
    $process = Start-Process -FilePath $Path -ArgumentList @('-n', '120', '127.0.0.1') -WindowStyle Hidden -PassThru
    $ownedProcesses.Add($process)
    if ($process.WaitForExit(200)) { throw "LogMachine test fixture exited during setup: $($process.ExitCode)" }
    return $process
}

function Get-Volume {
    [CmdletBinding()]
    param([string]$FileSystemLabel)
    if ($FileSystemLabel -ne 'MemLabsToolsTest') { throw "Unexpected test volume: $FileSystemLabel" }
    [pscustomobject]@{ DriveLetter = $script:ToolsIsoDrive }
}

try {
    $targetPath = Join-Path $guestRoot 'tools\LogMachine\LogMachine.exe'
    $otherPath = Join-Path $tempRoot 'unrelated\LogMachine.exe'
    $targetProcess = Start-TestLogMachine -Path $targetPath
    $otherProcess = Start-TestLogMachine -Path $otherPath

    $unrelatedBundle = Join-Path $tempRoot 'other.zip'
    New-TestToolBundle -Path $unrelatedBundle
    $result = @(& $expandBundles -BundlePath $unrelatedBundle)
    Assert-ToolReplacement ($result.Count -eq 1 -and $result[0].Ok) 'An unrelated bundle did not expand cleanly.'
    Assert-ToolReplacement (-not $targetProcess.HasExited -and -not $otherProcess.HasExited) `
        'A bundle without LogMachine must not stop either running viewer.'
    Assert-ToolReplacement (Test-Path -LiteralPath (Join-Path $guestRoot 'tools\other.txt')) 'The unrelated tool was not extracted.'

    $locked = $false
    try {
        $stream = [IO.File]::Open($targetPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
    }
    catch [IO.IOException] { $locked = $true }
    catch [UnauthorizedAccessException] { $locked = $true }
    Assert-ToolReplacement $locked 'The running executable fixture did not reproduce a write lock.'

    $directBundle = Join-Path $tempRoot 'direct.zip'
    New-TestToolBundle -Path $directBundle -LogMachine
    $result = @(& $expandBundles -BundlePath $directBundle)
    Assert-ToolReplacement ($result.Count -eq 1 -and $result[0].Ok) 'Direct delivery did not return one successful result.'
    Assert-ToolReplacement ($targetProcess.HasExited -and -not $otherProcess.HasExited) 'Direct delivery stopped the wrong process or left its target running.'
    Assert-ToolReplacement (@($result[0].StoppedLogMachineProcessIds).Count -eq 1 -and $result[0].StoppedLogMachineProcessIds[0] -eq $targetProcess.Id) `
        'Direct delivery did not identify exactly the destination process it stopped.'
    Assert-ToolReplacement ([IO.File]::ReadAllText($targetPath) -eq 'replacement tool bytes') 'Direct delivery did not replace the locked executable.'
    Assert-ToolReplacement (-not (Test-Path -LiteralPath $directBundle)) 'Direct delivery left its successfully expanded temporary archive behind.'
    Write-Host 'PASS -- Direct delivery replaces a locked LogMachine and leaves other locations untouched.'

    $targetProcess = Start-TestLogMachine -Path $targetPath
    $isoBundle = Join-Path $isoRoot 'tools.zip'
    New-TestToolBundle -Path $isoBundle -LogMachine
    [IO.File]::WriteAllText((Join-Path $isoRoot 'Tools.Bundle.md5'), 'expected-hash')
    [IO.File]::WriteAllText((Join-Path $isoRoot 'Tools.Bundles.txt'), 'tools.zip')
    $null = New-PSDrive -Name $script:ToolsIsoDrive -PSProvider FileSystem -Root $isoRoot
    $result = & $expandBundles -ExpectedHash 'wrong-hash' -VolumeLabel 'MemLabsToolsTest'
    Assert-ToolReplacement (-not $result.Ok -and -not $targetProcess.HasExited) 'Invalid ISO media stopped LogMachine before validation.'
    $result = @(& $expandBundles -ExpectedHash 'expected-hash' -VolumeLabel 'MemLabsToolsTest')
    Assert-ToolReplacement ($result.Count -eq 1 -and $result[0].Ok -and $targetProcess.HasExited) 'ISO delivery did not replace its running LogMachine.'
    Assert-ToolReplacement (-not $otherProcess.HasExited -and (Test-Path -LiteralPath $isoBundle)) 'ISO delivery touched another viewer or tried to delete its source archive.'
    Assert-ToolReplacement ([IO.File]::ReadAllText($targetPath) -eq 'replacement tool bytes') 'ISO delivery did not extract the replacement executable.'
    Write-Host 'PASS -- ISO delivery validates its media before stopping and replacing LogMachine.'

    $targetProcess = Start-TestLogMachine -Path $targetPath
    $failedBundle = Join-Path $tempRoot 'failed.zip'
    New-TestToolBundle -Path $failedBundle -LogMachine
    function Stop-Process {
        [CmdletBinding()]
        param([int]$Id, [switch]$Force)
        throw "Simulated access denied stopping PID $Id."
    }
    $stopMocked = $true
    $stopFailed = $false
    try { $null = & $expandBundles -BundlePath $failedBundle }
    catch { $stopFailed = $_.Exception.Message -like '*Simulated access denied*' }
    Assert-ToolReplacement ($stopFailed -and -not $targetProcess.HasExited) 'A failed stop was hidden or treated as successful extraction.'
    Assert-ToolReplacement (Test-Path -LiteralPath $failedBundle) 'Failed replacement discarded the archive needed for retry.'
    Write-Host 'PASS -- A failed LogMachine stop remains an explicit failure, not a successful update.'
}
finally {
    if ($stopMocked) { Remove-Item -LiteralPath Function:\Stop-Process -ErrorAction Stop }
    foreach ($process in $ownedProcesses) {
        try {
            if (-not $process.HasExited) {
                Microsoft.PowerShell.Management\Stop-Process -Id $process.Id -Force -ErrorAction Stop
                if (-not $process.WaitForExit(10000)) { throw "Test process $($process.Id) did not exit during cleanup." }
            }
        }
        finally { $process.Dispose() }
    }
    if (Get-PSDrive -Name $script:ToolsIsoDrive -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $script:ToolsIsoDrive -ErrorAction Stop
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
