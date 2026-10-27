<#
.SYNOPSIS
    Verifies that cross-forest Phase 11 validation uses authoritative PKI signals.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$sidAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$identitySidOf'
        }, $true))
if ($sidAssignments.Count -ne 1) {
    throw "Expected one forest-trust identity SID helper; found $($sidAssignments.Count)."
}
$identitySidOf = Invoke-Expression $sidAssignments[0].Right.Extent.Text

$fakeIdentity = [pscustomobject]@{ Name = 'CONTOSO\Domain Computers' }
$fakeIdentity | Add-Member -MemberType ScriptMethod -Name ToString -Value { return $this.Name } -Force
$fakeIdentity | Add-Member -MemberType ScriptMethod -Name Translate -Value {
    param($targetType)
    [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-515' }
} -Force

$translated = & $identitySidOf $fakeIdentity
if ($translated -ne 'S-1-5-21-1-2-3-515') {
    throw "Resolved ACE identity was not translated to SID: '$translated'."
}
$rawSid = & $identitySidOf 'S-1-5-21-4-5-6-515'
if ($rawSid -ne 'S-1-5-21-4-5-6-515') {
    throw "Raw SID identity was not preserved: '$rawSid'."
}

$certificateListAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$certificatesOf'
        }, $true))
$certificateAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$containsExpectedCertificate'
        }, $true))
if ($certificateListAssignments.Count -ne 1 -or $certificateAssignments.Count -ne 1) {
    throw "Expected one certificate decoder and matcher; found decoders=$($certificateListAssignments.Count), matchers=$($certificateAssignments.Count)."
}
$certificatesOf = Invoke-Expression $certificateListAssignments[0].Right.Extent.Text
$containsExpectedCertificate = Invoke-Expression $certificateAssignments[0].Right.Extent.Text
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=cstest8-Test-CA',
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $remoteCert = $request.CreateSelfSigned((Get-Date).AddMinutes(-1), (Get-Date).AddDays(1))
    $remoteBytes = $remoteCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $decodedCertificates = @(& $certificatesOf $remoteBytes)
    if ($decodedCertificates.Count -ne 1 -or
        $decodedCertificates[0] -isnot [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
        throw "Remote-certificate decoder returned a nested/non-certificate shape: count=$($decodedCertificates.Count), type=$($decodedCertificates[0].GetType().FullName)."
    }
    if (-not (& $containsExpectedCertificate $remoteBytes @($remoteCert.Thumbprint.ToUpperInvariant()))) {
        throw 'Remote-certificate matcher rejected the target CA.'
    }

    $otherRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=unrelated-Test-CA',
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $otherCert = $otherRequest.CreateSelfSigned((Get-Date).AddMinutes(-1), (Get-Date).AddDays(1))
    $otherBytes = $otherCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    if (& $containsExpectedCertificate $otherBytes @($remoteCert.Thumbprint.ToUpperInvariant())) {
        throw 'Remote-certificate matcher accepted an unrelated NTAuth certificate.'
    }
}
finally {
    $rsa.Dispose()
}

$sourceText = Get-Content -LiteralPath $sourcePath -Raw
foreach ($required in @(
        '$enterpriseRootCached = @($remoteRootThumbprints | Where-Object { $compactRootStore.Contains($_) }).Count -gt 0',
        '$enterpriseNtauthCached = @($remoteIssuingThumbprints | Where-Object { $compactNtauthStore.Contains($_) }).Count -gt 0',
        '$ntAuthPublishedInAd = & $containsExpectedCertificate $ntRaw $remoteIssuingThumbprints',
        '$publicationVerdict ''RootCA''',
        '$publicationVerdict ''NTAuthCertificates''')) {
    if (-not $sourceText.Contains($required)) {
        throw "Forest-trust validation is missing authoritative/cache distinction: $required"
    }
}
if ($sourceText -match "WARN: Remote CA '\$remoteDnsShort-\*' NOT found in enterprise Root store") {
    throw 'A lagging enterprise Root cache is still reported as authoritative publication failure.'
}
if ($sourceText -match 'WARN: Remote CA NOT found in enterprise NTAuth store') {
    throw 'A lagging enterprise NTAuth cache is still reported as authoritative publication failure.'
}
if ($sourceText -notmatch '-ArgumentList @\(\$domain, \$remoteForest, \$remoteDcFqdn, \$externalSiteCode, \$remoteNetbios, \$remoteCaConfig, \$remoteIssuingHint\)') {
    throw 'Forest-trust validation does not forward the issuing-CA hint to the guest.'
}
if ($sourceText.Contains('return , $certificates.ToArray()') -or
    $sourceText.Contains('return , @($granted | Select-Object -Unique)')) {
    throw 'Forest-trust validation still returns nested certificate/ACL arrays.'
}
if ($sourceText -notmatch '(?s)\$pkiCertFailure.+?if \(\$pkiCertFailure\).+?elseif \(\$mpUnavailable\).+?elseif \(\$noDpLocations\)') {
    throw 'ccmsetup diagnosis does not prioritize PKI rejection over secondary location symptoms.'
}

$verdictAssignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$publicationVerdict'
        }, $true))
if ($verdictAssignments.Count -ne 1) {
    throw "Expected one authoritative publication verdict helper; found $($verdictAssignments.Count)."
}
$publicationVerdict = Invoke-Expression $verdictAssignments[0].Right.Extent.Text
if ((& $publicationVerdict 'RootCA' $false $true) -notmatch '^WARN:.*stale') {
    throw 'A stale positive cache overrides authoritative AD absence.'
}
if ((& $publicationVerdict 'RootCA' $true $false) -notmatch '^INFO:.*authoritatively published') {
    throw 'Authoritative AD publication with cache lag is not informational.'
}
if ((& $publicationVerdict 'RootCA' $null $true) -notmatch '^INFO:.*authoritative AD.*could not be measured') {
    throw 'Cache-only evidence is not clearly marked as authoritative-state unknown.'
}

$rootVerdictIndex = $sourceText.IndexOf('$publicationVerdict ''RootCA''', [StringComparison]::Ordinal)
$clientGateIndex = $sourceText.IndexOf('# --- C3: Can a computer in THIS domain', [StringComparison]::Ordinal)
if ($rootVerdictIndex -lt 0 -or $clientGateIndex -lt 0 -or $rootVerdictIndex -gt $clientGateIndex) {
    throw 'Root/NTAuth trust verdicts are incorrectly gated on external client management.'
}

Write-Host 'PASS -- forest-trust validation translates ACE identities and treats AD publication as authoritative.'
