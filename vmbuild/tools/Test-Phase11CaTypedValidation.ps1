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

$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$source = Get-Content -LiteralPath $validationPath -Raw
Assert-True ($source -notmatch "-match 'CA name:'") 'CA validation does not parse localized certutil labels'
Assert-True ($source -match "CertSvc\\Configuration' -Name Active") 'CA validation reads the active CA configuration'
Assert-True ($source -match 'CACertHash') 'CA validation resolves the configured CA certificate thumbprint'
Assert-True ($source -match 'X509RevocationMode\]::Online' -and $source -match '\.ChainStatus') 'CA revocation uses typed X509Chain status'
Assert-True ($source -notmatch 'revocation check passed') 'CA revocation does not parse localized certutil success prose'
Assert-True ($source -match 'Get-ItemPropertyValue.+CRLDeltaPeriodUnits') 'delta CRL configuration comes from CertSvc registry'
Assert-True ($source -match 'Get-ADObject -Identity "CN=NTAuthCertificates') 'CA validation reads NTAuthCertificates through AD objects'
Assert-True ($source -match 'cACertificate') 'CA validation decodes typed NTAuth certificate bytes'
Assert-True ($source -match '\$ntAuthThumbprints -contains \$localCaCert\.Thumbprint') 'CA validation compares local and NTAuth certificate thumbprints'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'functional validation source parses'
$caFunction = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-CAFunctionality'
        }, $true))
$caScriptAssignment = if ($caFunction.Count -eq 1) {
    @($caFunction[0].FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$scriptBlock'
            }, $true))
}
else { @() }
Assert-True ($caScriptAssignment.Count -eq 1) 'CA guest scriptblock is extractable'
if ($caScriptAssignment.Count -eq 1) {
    $caScriptAst = $caScriptAssignment[0].Right.Expression.ScriptBlock
    foreach ($functionName in @('Select-ActiveCaCertificate', 'Get-ActiveCaBaseCrlFreshness')) {
        $definition = @($caScriptAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
                }, $true))
        Assert-True ($definition.Count -eq 1) "$functionName has one definition"
        if ($definition.Count -eq 1) { . ([scriptblock]::Create($definition[0].Extent.Text)) }
    }

    $now = Get-Date
    $certificates = @(
        [pscustomobject]@{ Thumbprint = 'AAAA'; NotAfter = $now.AddDays(10); Name = 'old' }
        [pscustomobject]@{ Thumbprint = 'BBBB'; NotAfter = $now.AddDays(20); Name = 'renewed' }
        [pscustomobject]@{ Thumbprint = 'CCCC'; NotAfter = $now.AddDays(30); Name = 'unconfigured' }
    )
    $scalarSelection = @(Select-ActiveCaCertificate -CertificateHashes ' AA AA ' -Certificates $certificates)
    Assert-True ($scalarSelection.Count -eq 1 -and $scalarSelection[0].Name -eq 'old') 'scalar CACertHash resolves one matching certificate'
    $renewedSelection = @(Select-ActiveCaCertificate -CertificateHashes @(' AA AA ', 'bb bb') -Certificates $certificates)
    Assert-True ($renewedSelection.Count -eq 1 -and $renewedSelection[0].Name -eq 'renewed') 'REG_MULTI_SZ CACertHash selects the newest matching renewed certificate'

    $fixture = 'MIIBfTBnAgEBMA0GCSqGSIb3DQEBCwUAMCQxIjAgBgNVBAMMGU1lbUxhYnMgVHlwZWQgQ1JMIFRlc3QgQ0EXDTI2MDkxMDE1MzQzNFoXDTM2MDkwNzE1MzQzNFqgDzANMAsGA1UdFAQEAgIQADANBgkqhkiG9w0BAQsFAAOCAQEAlXafB6pZ7A0oxHl73Nu0yWXbjGwtqyc4agEdlwEuIPgRYpemSwN0EIhgQd55ubGxsoqdXUUqo4RCdYCwn2rKDPuwDkXjC95ab0WpJE9BstPmwthBrF9FC3SJfe4kR3xb/gvBYvdbTWqolUaa76PeIpHDBcSYaCsjuN0Ozc/SKqcIJhQcJmdMrQ4LHA8u8gbgnOqPInR5/Wjb5Sbrx/5t+wOrenzZEy6qJ00gJa9VA0HfVQr5r+yRV+Bu5G813fcuGwdrzicPPc1MVoclRaRGU+MLYCbqZ2mlA2jdjCYcDrUQXpa/+xVyHvWo7RZuvdTZK7EpMvhHjp6A3EgIt2j+dw=='
    $fixtureRoot = Join-Path $env:TEMP ('memlabs-crl-fixture-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -Path $fixtureRoot -ItemType Directory
        $fixturePath = Join-Path $fixtureRoot 'typed-base.crl'
        [IO.File]::WriteAllBytes($fixturePath, [Convert]::FromBase64String($fixture))
        $freshness = @(Get-ActiveCaBaseCrlFreshness -Directory $fixtureRoot -Issuer 'CN=MemLabs Typed CRL Test CA')
        Assert-True ($freshness.Count -eq 1 -and $freshness[0].Measured) 'typed DER base CRL fixture is measured'
        Assert-True ($freshness[0].Path -eq $fixturePath -and $freshness[0].NextUpdate -gt $now) 'typed DER base CRL returns path and future NextUpdate'
        $wrongIssuer = @(Get-ActiveCaBaseCrlFreshness -Directory $fixtureRoot -Issuer 'CN=Other CA')
        Assert-True ($wrongIssuer.Count -eq 1 -and -not $wrongIssuer[0].Measured -and $wrongIssuer[0].Error) 'unmatched CRL issuer reports one explicit unmeasured result'
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'broken.crl'), 'not a CRL')
        $malformedOnlyRoot = Join-Path $fixtureRoot 'malformed'
        $null = New-Item -Path $malformedOnlyRoot -ItemType Directory
        Copy-Item (Join-Path $fixtureRoot 'broken.crl') $malformedOnlyRoot
        $malformed = @(Get-ActiveCaBaseCrlFreshness -Directory $malformedOnlyRoot -Issuer 'CN=MemLabs Typed CRL Test CA')
        Assert-True ($malformed.Count -eq 1 -and -not $malformed[0].Measured -and $malformed[0].Error) 'malformed CRL reports one explicit unmeasured result'
    }
    finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures) { throw "$script:Failures typed CA validation test(s) failed" }
Write-Host 'ALL TYPED CA VALIDATION TESTS PASSED' -ForegroundColor Green