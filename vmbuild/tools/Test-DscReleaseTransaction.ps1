<#
.SYNOPSIS
    Verifies recovery of interrupted and committed DSC artifact transactions.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$builderPath = Join-Path $RootPath 'DSC\createGuestDscZip.ps1'
$script:Failures = 0

function Write-TestResult {
    param([bool] $Passed, [string] $What, [string] $Detail = '')

    if (-not $Passed) { $script:Failures++ }
    Write-Host ("{0}  {1}" -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($Passed) { 'Green' } else { 'Red' })
    if (-not $Passed -and $Detail) { Write-Host "      $Detail" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What)

    Write-TestResult -Passed ("$Expected" -eq "$Actual") -What $What -Detail "expected=[$Expected] actual=[$Actual]"
}

function Assert-True {
    param([bool] $Condition, [string] $What, [string] $Detail = '')

    Write-TestResult -Passed $Condition -What $What -Detail $Detail
}

function Assert-ThrowsLike {
    param([scriptblock] $Action, [string] $Pattern, [string] $What)

    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    Write-TestResult -Passed ([bool]($message -like $Pattern)) -What $What `
        -Detail "expected pattern=[$Pattern] actual=[$message]"
}

function Assert-FileText {
    param([string] $Path, [string] $Expected, [string] $What)

    $actual = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::ReadAllText($Path)
    }
    else {
        '<missing>'
    }
    Assert-Equal -Expected $Expected -Actual $actual -What $What
}

function Assert-PathsAbsent {
    param([string[]] $Path, [string] $What)

    $remaining = @($Path | Where-Object { Test-Path -LiteralPath $_ })
    Assert-True -Condition ($remaining.Count -eq 0) -What $What `
        -Detail "still present=[$($remaining -join ', ')]"
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Set-TestFile {
    param([string] $Path, [string] $Text)

    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::UTF8)
}

function Write-TransactionMarker {
    param([string] $Path, [System.Collections.IDictionary] $Transaction)

    [IO.File]::WriteAllText($Path, ($Transaction | ConvertTo-Json), [Text.Encoding]::UTF8)
}

function Get-TestFileHash {
    param([string] $Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Reset-TestDirectory {
    param([string] $Path)

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $Path -Force
}

. (Import-TestFunction -Path $builderPath -Name 'Restore-MemLabsReleaseTransaction')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-dsc-transaction-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $testRoot 'DSC.zip'
$archiveBackup = Join-Path $testRoot 'DSC.zip.bak'
$version = Join-Path $testRoot 'version.json'
$versionBackup = Join-Path $testRoot 'version.json.bak'
$receipt = Join-Path $testRoot 'DSC.build.json'
$receiptBackup = Join-Path $testRoot 'DSC.build.json.bak'
$marker = Join-Path $testRoot 'transaction.json'

try {
    Write-Host 'Pending transaction with an existing artifact set'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'new archive'
    Set-TestFile $archiveBackup 'old archive'
    Set-TestFile $version 'new version'
    Set-TestFile $versionBackup 'old version'
    Set-TestFile $receipt 'new receipt'
    Set-TestFile $receiptBackup 'old receipt'
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Pending'
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
            ReceiptTarget = $receipt; ReceiptBackup = $receiptBackup; ReceiptExisted = $true
        })

    Restore-MemLabsReleaseTransaction -MarkerPath $marker
    Assert-FileText $archive 'old archive' 'pending recovery restores the prior archive'
    Assert-FileText $version 'old version' 'pending recovery restores the matching prior version'
    Assert-FileText $receipt 'old receipt' 'pending recovery restores the matching prior receipt'
    Assert-PathsAbsent @($marker, $archiveBackup, $versionBackup, $receiptBackup) 'pending recovery removes marker and backups'

    Write-Host ''
    Write-Host 'Pending transaction with no prior artifact set'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'first archive'
    Set-TestFile $version 'first version'
    Set-TestFile $receipt 'first receipt'
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Pending'
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $false
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $false
            ReceiptTarget = $receipt; ReceiptBackup = $receiptBackup; ReceiptExisted = $false
        })

    Restore-MemLabsReleaseTransaction -MarkerPath $marker
    Assert-PathsAbsent @($archive, $version, $receipt) 'pending recovery removes new targets when no prior artifact set existed'
    Assert-PathsAbsent @($marker) 'pending recovery removes the completed marker'

    Write-Host ''
    Write-Host 'Committed transaction with matching target hashes'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'committed archive'
    Set-TestFile $archiveBackup 'old archive'
    Set-TestFile $version 'committed version'
    Set-TestFile $versionBackup 'old version'
    Set-TestFile $receipt 'committed receipt'
    Set-TestFile $receiptBackup 'old receipt'
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Committed'
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            ArchiveSha256 = Get-TestFileHash $archive
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
            VersionSha256 = Get-TestFileHash $version
            ReceiptTarget = $receipt; ReceiptBackup = $receiptBackup; ReceiptExisted = $true
            ReceiptSha256 = Get-TestFileHash $receipt
        })

    Restore-MemLabsReleaseTransaction -MarkerPath $marker
    Assert-FileText $archive 'committed archive' 'matching committed archive remains promoted'
    Assert-FileText $version 'committed version' 'matching committed version remains promoted'
    Assert-FileText $receipt 'committed receipt' 'matching committed receipt remains promoted'
    Assert-PathsAbsent @($marker, $archiveBackup, $versionBackup, $receiptBackup) 'matching committed recovery removes marker and backups'

    Write-Host ''
    Write-Host 'Committed transaction with a target hash mismatch'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'expected committed archive'
    $expectedArchiveHash = Get-TestFileHash $archive
    Set-TestFile $archive 'tampered committed archive'
    Set-TestFile $archiveBackup 'old archive'
    Set-TestFile $version 'committed version'
    Set-TestFile $versionBackup 'old version'
    Set-TestFile $receipt 'committed receipt'
    Set-TestFile $receiptBackup 'old receipt'
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Committed'
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            ArchiveSha256 = $expectedArchiveHash
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
            VersionSha256 = Get-TestFileHash $version
            ReceiptTarget = $receipt; ReceiptBackup = $receiptBackup; ReceiptExisted = $true
            ReceiptSha256 = Get-TestFileHash $receipt
        })

    Restore-MemLabsReleaseTransaction -MarkerPath $marker
    Assert-FileText $archive 'old archive' 'hash mismatch rolls the archive back'
    Assert-FileText $version 'old version' 'hash mismatch rolls the version back'
    Assert-FileText $receipt 'old receipt' 'hash mismatch rolls the receipt back'
    Assert-PathsAbsent @($marker, $archiveBackup, $versionBackup, $receiptBackup) 'hash-mismatch rollback removes marker and backups'

    Write-Host ''
    Write-Host 'Missing backup diagnostics'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'new archive'
    Set-TestFile $archiveBackup 'old archive'
    Set-TestFile $version 'new version'
    Set-TestFile $versionBackup 'old version'
    Set-TestFile $receipt 'new receipt'
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Pending'
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
            ReceiptTarget = $receipt; ReceiptBackup = $receiptBackup; ReceiptExisted = $true
        })

    Assert-ThrowsLike { Restore-MemLabsReleaseTransaction -MarkerPath $marker } `
        '*Cannot restore the prior DSC build receipt*backup*missing*' `
        'missing receipt backup produces an actionable error'
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'failed recovery retains its transaction marker'

    Write-Host ''
    Write-Host 'Incomplete marker diagnostics'
    Reset-TestDirectory -Path $testRoot
    Write-TransactionMarker $marker ([ordered]@{
            State = 'Pending'
            ArchiveTarget = ''; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
        })

    Assert-ThrowsLike { Restore-MemLabsReleaseTransaction -MarkerPath $marker } `
        '*transaction marker*is incomplete*' `
        'incomplete marker produces an actionable error'
    Assert-True (Test-Path -LiteralPath $marker -PathType Leaf) 'incomplete marker remains available for diagnosis'

    Write-Host ''
    Write-Host 'Legacy two-artifact marker compatibility'
    Reset-TestDirectory -Path $testRoot
    Set-TestFile $archive 'new archive'
    Set-TestFile $archiveBackup 'old archive'
    Set-TestFile $version 'new version'
    Set-TestFile $versionBackup 'old version'
    Write-TransactionMarker $marker ([ordered]@{
            ArchiveTarget = $archive; ArchiveBackup = $archiveBackup; ArchiveExisted = $true
            VersionTarget = $version; VersionBackup = $versionBackup; VersionExisted = $true
        })

    Restore-MemLabsReleaseTransaction -MarkerPath $marker
    Assert-FileText $archive 'old archive' 'legacy recovery restores the prior archive'
    Assert-FileText $version 'old version' 'legacy recovery restores the matching prior version'
    Assert-PathsAbsent @($marker, $archiveBackup, $versionBackup) 'legacy recovery removes marker and backups'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'PASS: DSC release transaction recovery passed all rollback, commit, compatibility, and diagnostic checks.' -ForegroundColor Green
exit 0
