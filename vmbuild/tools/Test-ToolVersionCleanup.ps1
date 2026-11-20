<#
.SYNOPSIS
    Exercises managed tool replacement and verified legacy 7-Zip cleanup without a VM.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'Common.ps1'), [ref]$null, [ref]$null)
$copyTool = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ToolToVM'
    }, $true)
$assignment = $copyTool.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$expandToolsBundles'
    }, $true)
if (-not $assignment) { throw 'The shared guest tools expander was not found.' }
$argument = $assignment.Right.Find({
        param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-tool-versions-' + [guid]::NewGuid().ToString('N'))
$guestRoot = Join-Path $tempRoot 'guest'
$toolsRoot = Join-Path $guestRoot 'tools'
$sourcesRoot = Join-Path $tempRoot 'sources'
$null = New-Item -ItemType Directory -Path $toolsRoot, $sourcesRoot, (Join-Path $guestRoot 'Apps') -Force
$escapedGuestRoot = $guestRoot.Replace("'", "''") + '\'
$expandTools = [scriptblock]::Create($argument.ScriptBlock.GetScriptBlock().ToString().Replace("'C:\'", "'$escapedGuestRoot'"))
$script:Checks = 0

function Assert-ToolState {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Checks++
    Write-Host "PASS -- $Message"
}

function New-TestBundle {
    param([string]$ToolName, [string]$RelativePath, [string]$SourcePath, [string]$ExpectedHash)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $path = Join-Path $tempRoot ([guid]::NewGuid().ToString('N') + '.zip')
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry($RelativePath.Replace([char]92, [char]47))
        $input = [IO.File]::OpenRead($SourcePath)
        $output = $entry.Open()
        try { $input.CopyTo($output) }
        finally { $output.Dispose(); $input.Dispose() }
    }
    finally { $archive.Dispose() }
    if (-not $ExpectedHash) { $ExpectedHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash }
    [pscustomobject]@{
        Path = $path
        Json = ConvertTo-Json -InputObject @([pscustomobject]@{
                ToolName = $ToolName; RelativePath = $RelativePath; Sha256 = $ExpectedHash
            }) -Compress
    }
}

function New-TestMsi {
    param([string]$Path, [string]$Version, [string]$UpgradeCode = '{23170F69-40C1-2701-0000-000004000000}', [string]$Template = 'x64;1033', [string]$Manufacturer = 'Igor Pavlov', [string]$ProductName)
    $installer = $null
    $database = $null
    $summary = $null
    try {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 3))
        $queries = @('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)')
        if (-not $ProductName) { $ProductName = "7-Zip $Version (x64 edition)" }
        $properties = @{
            ProductName = $ProductName; Manufacturer = $Manufacturer
            ProductVersion = $Version; UpgradeCode = $UpgradeCode
        }
        foreach ($name in $properties.Keys) {
            $queries += 'INSERT INTO `Property` (`Property`, `Value`) VALUES (''{0}'', ''{1}'')' -f $name, $properties[$name]
        }
        foreach ($query in $queries) {
            $view = $null
            try {
                $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($query))
                $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            }
            finally { if ($view) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) } }
        }
        $summary = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(20))
        $null = $summary.GetType().InvokeMember('Property', 'SetProperty', $null, $summary, @(7, $Template))
        $null = $summary.GetType().InvokeMember('Property', 'SetProperty', $null, $summary, @(9, [guid]::NewGuid().ToString('B')))
        $null = $summary.GetType().InvokeMember('Persist', 'InvokeMethod', $null, $summary, $null)
        $null = $database.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $database, $null)
    }
    finally {
        if ($summary) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
        if ($database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        if ($installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    }
}

try {
    $source = Join-Path $sourcesRoot 'widget.exe'
    Set-Content -LiteralPath $source -Value 'widget-version-one' -Encoding ASCII
    $first = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v1.exe' -SourcePath $source
    $result = & $expandTools -BundlePath $first.Path -ToolFilesJson $first.Json
    Assert-ToolState ($result.Ok -and (Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v1.exe'))) 'The first managed version is recorded after extraction.'
    $untrackedPath = Join-Path $toolsRoot 'widget-personal-v0.exe'
    $appSource = Join-Path $guestRoot 'Apps\keep.msi'
    Set-Content -LiteralPath $untrackedPath -Value 'user-owned' -Encoding ASCII
    Set-Content -LiteralPath $appSource -Value 'application-source' -Encoding ASCII
    Set-Content -LiteralPath $source -Value 'widget-version-two' -Encoding ASCII
    $second = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v2.exe' -SourcePath $source
    $result = & $expandTools -BundlePath $second.Path -ToolFilesJson $second.Json
    Assert-ToolState ($result.Ok -and -not (Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v1.exe')) -and $result.RemovedToolFiles.Count -eq 1) 'A verified replacement removes the unchanged previous managed file.'
    Assert-ToolState ((Test-Path -LiteralPath $untrackedPath) -and (Test-Path -LiteralPath $appSource)) 'Untracked tools and ConfigMgr application sources are preserved.'
    Set-Content -LiteralPath (Join-Path $toolsRoot 'widget-v2.exe') -Value 'user-modified-tool' -Encoding ASCII
    Set-Content -LiteralPath $source -Value 'widget-version-three' -Encoding ASCII
    $third = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v3.exe' -SourcePath $source
    $result = & $expandTools -BundlePath $third.Path -ToolFilesJson $third.Json
    Assert-ToolState ((Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v2.exe')) -and $result.CleanupWarnings.Count -eq 1) 'A locally modified former tool is preserved with a warning.'
    $shared = New-TestBundle -ToolName OtherTool -RelativePath 'tools\widget-v3.exe' -SourcePath $source
    $sharedRecords = ConvertFrom-Json -InputObject $shared.Json
    $sharedRecords[0].RelativePath = 'tools\.\widget-v3.exe'.Replace([char]92, [char]47)
    $shared.Json = ConvertTo-Json -InputObject @($sharedRecords) -Compress
    $null = & $expandTools -BundlePath $shared.Path -ToolFilesJson $shared.Json
    Set-Content -LiteralPath $source -Value 'widget-version-four' -Encoding ASCII
    $fourth = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v4.exe' -SourcePath $source
    $null = & $expandTools -BundlePath $fourth.Path -ToolFilesJson $fourth.Json
    Assert-ToolState (Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v3.exe')) 'A canonical path still owned through dot/separator aliases is not deleted.'
    $empty = New-TestBundle -ToolName Widget -RelativePath 'tools\empty-manifest.txt' -SourcePath $source
    $result = & $expandTools -BundlePath $empty.Path -ToolFilesJson '[]'
    Assert-ToolState ($result.Ok -and (Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v4.exe'))) 'A bundle with no managed tool entries does not prune previously tracked tools.'

    $ledgerPath = Join-Path $toolsRoot '.memlabs-tool-versions.json'
    $ledgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
    $bad = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v5.exe' -SourcePath $source -ExpectedHash ('0' * 64)
    $failed = $false
    try { $null = & $expandTools -BundlePath $bad.Path -ToolFilesJson $bad.Json } catch { $failed = $true }
    Assert-ToolState ($failed -and (Test-Path -LiteralPath (Join-Path $toolsRoot 'widget-v4.exe')) -and
        (Test-Path -LiteralPath $bad.Path) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerPath)) -eq [Convert]::ToBase64String($ledgerBytes)) `
        'An unverified replacement preserves the previous tool, ledger, and retry archive.'

    $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    $ledger.Files[0].RelativePath = 'tools\..\Apps\keep.msi'
    $ledger | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ledgerPath -Encoding UTF8
    $escape = New-TestBundle -ToolName Widget -RelativePath 'tools\widget-v6.exe' -SourcePath $source
    $failed = $false
    try { $null = & $expandTools -BundlePath $escape.Path -ToolFilesJson $escape.Json } catch { $failed = $true }
    Assert-ToolState ($failed -and (Get-Content -LiteralPath $appSource -Raw).Trim() -eq 'application-source') 'A ledger path outside tools is rejected before deleting application content.'
    [IO.File]::WriteAllBytes($ledgerPath, $ledgerBytes)

    $oldMsi = Join-Path $toolsRoot '7z2301-x64.msi'
    New-TestMsi -Path $oldMsi -Version '23.1.0'
    $legacyApp = Join-Path $guestRoot 'Apps\legacy-7z.msi'
    $null = New-Item -ItemType HardLink -Path $legacyApp -Value $oldMsi
    $legacyHash = (Get-FileHash -LiteralPath $legacyApp -Algorithm SHA256).Hash
    New-TestMsi -Path (Join-Path $toolsRoot '7z2200-x64.msi') -Version '22.0.0' -UpgradeCode '{11111111-2222-3333-4444-555555555555}'
    New-TestMsi -Path (Join-Path $toolsRoot '7z2400-x64.msi') -Version '24.0.0' -Template 'Intel;1033'
    New-TestMsi -Path (Join-Path $toolsRoot '7z3000-x64.msi') -Version '30.0.0'
    New-TestMsi -Path (Join-Path $toolsRoot '7z2100-x64.msi') -Version '21.0.0' -Manufacturer 'Other vendor'
    New-TestMsi -Path (Join-Path $toolsRoot '7z2000-x64.msi') -Version '20.0.0' -ProductName 'Other application'
    New-TestMsi -Path (Join-Path $toolsRoot '7z2502-x64.msi') -Version '25.1.0'
    Set-Content -LiteralPath (Join-Path $toolsRoot '7z9999-x64.msi') -Value 'not-an-msi' -Encoding ASCII
    $newMsi = Join-Path $sourcesRoot '7z2501-x64.msi'
    New-TestMsi -Path $newMsi -Version '25.1.0'
    $zip = New-TestBundle -ToolName '7-Zip 64-bit' -RelativePath 'tools\7z2501-x64.msi' -SourcePath $newMsi
    $result = & $expandTools -BundlePath $zip.Path -ToolFilesJson $zip.Json
    Assert-ToolState (-not (Test-Path -LiteralPath $oldMsi) -and $result.RemovedToolFiles.Count -eq 1) 'An older legacy 7-Zip MSI is removed only after matching product family, upgrade code, and platform.'
    Assert-ToolState ((Test-Path -LiteralPath (Join-Path $toolsRoot '7z2200-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z2400-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z3000-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z2100-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z2000-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z2502-x64.msi')) -and
        (Test-Path -LiteralPath (Join-Path $toolsRoot '7z9999-x64.msi')) -and $result.CleanupWarnings.Count -gt 0) `
        'Other product families, architectures, newer versions, and invalid MSI files are preserved.'
    Assert-ToolState ((Get-FileHash -LiteralPath $legacyApp -Algorithm SHA256).Hash -eq $legacyHash) 'Removing an old tool name does not delete its surviving application-source hardlink.'

    New-TestMsi -Path (Join-Path $toolsRoot '7z2501-x64.msi') -Version '25.1.0'
    New-TestMsi -Path $newMsi -Version '26.0.0'
    $zip = New-TestBundle -ToolName '7-Zip 64-bit' -RelativePath 'tools\7z2600-x64.msi' -SourcePath $newMsi
    $result = & $expandTools -BundlePath $zip.Path -ToolFilesJson $zip.Json
    Assert-ToolState ((Test-Path -LiteralPath (Join-Path $toolsRoot '7z2501-x64.msi')) -and $result.CleanupWarnings.Count -gt 0) `
        'Legacy migration cannot delete a former managed MSI that was locally modified.'
    foreach ($version in '27.0.0', '28.0.0') {
        New-TestMsi -Path $newMsi -Version $version
        $fileName = '7z' + $version.Replace('.', '') + '-x64.msi'
        $zip = New-TestBundle -ToolName '7-Zip 64-bit' -RelativePath (Join-Path 'tools' $fileName) -SourcePath $newMsi
        $null = & $expandTools -BundlePath $zip.Path -ToolFilesJson $zip.Json
        Assert-ToolState (Test-Path -LiteralPath (Join-Path $toolsRoot '7z2501-x64.msi')) `
            "A locally modified former MSI remains protected after another injection ($version)."
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Checks tool-version cleanup checks on PowerShell $($PSVersionTable.PSVersion)."
