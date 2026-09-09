<#
.SYNOPSIS
    Verifies Phase 11 CA validation is independent of localized certutil text.
#>
[CmdletBinding()]
param ([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
function Assert-True {
    param ([bool] $Condition, [string] $What)
    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

$source = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.Validation.Functional.ps1') -Raw
Assert-True ($source -notmatch "-match 'CA name:'") 'CA validation does not parse localized certutil labels'
Assert-True ($source -match "CertSvc\\Configuration' -Name Active") 'CA validation reads the active CA configuration'
Assert-True ($source -match 'CACertHash') 'CA validation resolves the configured CA certificate thumbprint'
Assert-True ($source -match 'Get-ADObject -Identity "CN=NTAuthCertificates') 'CA validation reads NTAuthCertificates through AD objects'
Assert-True ($source -match 'cACertificate') 'CA validation decodes typed NTAuth certificate bytes'
Assert-True ($source -match '\$ntAuthThumbprints -contains \$localCaCert\.Thumbprint') 'CA validation compares local and NTAuth certificate thumbprints'

if ($script:Failures) { throw "$script:Failures typed CA validation test(s) failed" }
Write-Host 'ALL TYPED CA VALIDATION TESTS PASSED' -ForegroundColor Green