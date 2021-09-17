# Dot source common
. $PSScriptRoot\Common.ps1

# Validate token exists
if ($Common.FatalError) {
    Write-Host
    Write-Host "Get-AvailableFiles: Critical Failure! $($Common.FatalError)" -ForegroundColor Red
    Write-Host
    return
}

Write-Host
Write-Host "=== Available Operating Systems versions ===" -ForegroundColor Cyan
Write-Host

$Common.AzureFileList.OS.id | Where-Object {$_ -ne "vmbuildadmin" }

Write-Host
Write-Host "=== Available SQL Server versions ===" -ForegroundColor Cyan
Write-Host

$Common.AzureFileList.ISO.id

Write-Host
Write-Host "Use one of these values in the json config file(s) for specifying OS and SQL Versions." -ForegroundColor Green
Write-Host
