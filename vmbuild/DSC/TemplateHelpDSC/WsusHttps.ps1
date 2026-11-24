function Get-MemLabsWsusTemplateOid {
    $searcher = New-Object DirectoryServices.DirectorySearcher
    try {
        $configDN = ([ADSI]'LDAP://RootDSE').configurationNamingContext
        $searcher.SearchRoot = [ADSI]"LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$configDN"
        $searcher.Filter = '(cn=ConfigMgrWebServerCertificate)'
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds(15)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds(15)
        $null = $searcher.PropertiesToLoad.Add('msPKI-Cert-Template-OID')
        $template = $searcher.FindOne()
        $oid = if ($template) { [string]$template.Properties['mspki-cert-template-oid'][0] } else { '' }
        if (-not $oid) { throw 'ConfigMgrWebServerCertificate was not found in AD.' }
        return $oid
    }
    finally { $searcher.Dispose() }
}

function Test-MemLabsWsusCertificateIdentity {
    param([object]$Certificate, [string]$Fqdn, [string]$TemplateOid)

    if (-not $Certificate.HasPrivateKey -or $Certificate.NotBefore -gt (Get-Date) -or
        $Certificate.NotAfter -le (Get-Date) -or $Certificate.Issuer -eq $Certificate.Subject -or
        $Certificate.EnhancedKeyUsageList.ObjectId -notcontains '1.3.6.1.5.5.7.3.1') { return $false }
    $san = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if (-not $san) { return $false }
    $names = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
    try {
        $names.InitializeDecode(1, [Convert]::ToBase64String($san.RawData))
        $dnsNames = @($names.AlternativeNames | Where-Object { $_.Type -eq 3 } | ForEach-Object { $_.strValue })
        if ($dnsNames -notcontains $Fqdn) { return $false }
    }
    finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($names) }
    $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' } | Select-Object -First 1
    if (-not $extension) { return $false }
    $decoder = New-Object -ComObject X509Enrollment.CX509ExtensionTemplate
    try {
        $decoder.InitializeDecode(1, [Convert]::ToBase64String($extension.RawData))
        return $decoder.TemplateOid.Value -eq $TemplateOid
    }
    finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($decoder) }
}

function Get-MemLabsWsusHttpsCertificate {
    param([Parameter(Mandatory)][string]$Fqdn)

    $templateOid = Get-MemLabsWsusTemplateOid
    $candidates = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object {
        Test-MemLabsWsusCertificateIdentity -Certificate $_ -Fqdn $Fqdn -TemplateOid $templateOid
    } | Sort-Object -Property @{ Expression = { $_.NotAfter }; Descending = $true },
        @{ Expression = { $_.NotBefore }; Descending = $true }, Thumbprint)
    if ($candidates.Count -gt 0) { return $candidates[0] }
    Write-Verbose "No eligible WSUS Server Authentication certificate for $Fqdn in LocalMachine\My."
}

function Assert-MemLabsWsusCertificateChain {
    param([Parameter(Mandatory)][object]$Certificate)

    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(15)
        $null = $chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        if (-not $chain.Build($Certificate)) {
            $why = @($chain.ChainStatus | ForEach-Object { "$($_.Status): $($_.StatusInformation.Trim())" }) -join '; '
            throw "WSUS certificate chain/revocation verification failed: $why"
        }
    }
    finally { $chain.Dispose() }
}

function Invoke-MemLabsWsusUtil {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $tool = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "WSUS utility not found: $tool" }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $tool @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) { throw "WsusUtil $($Arguments[0]) failed (exit $exitCode): $($output -join ' ')" }
    return ($output -join "`n")
}

function Get-MemLabsWsusHttpsState {
    param([Parameter(Mandatory)][string]$Fqdn)

    $details = [Collections.Generic.List[string]]::new()
    $passed = $false
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $cert = Get-MemLabsWsusHttpsCertificate -Fqdn $Fqdn
        if (-not $cert) { throw "No eligible WSUS certificate for $Fqdn." }
        Assert-MemLabsWsusCertificateChain -Certificate $cert
        $bindings = @(Get-WebBinding -Name 'WSUS Administration' -Protocol https -Port 8531 -ErrorAction Stop)
        if ($bindings.Count -ne 1) { throw 'Expected one WSUS HTTPS binding on port 8531.' }
        $hash = $bindings[0].certificateHash
        if ($hash -is [byte[]]) { $hash = [BitConverter]::ToString($hash).Replace('-', '') }
        if ([string]$hash -ne $cert.Thumbprint -or $bindings[0].certificateStoreName -ine 'My') {
            throw 'WSUS:8531 does not bind the selected certificate in LocalMachine\My.'
        }
        if (@(Get-WebBinding -Name 'WSUS Administration' -Protocol http -Port 8530 -ErrorAction Stop).Count -eq 0) {
            throw 'WSUS requires its HTTP binding on port 8530.'
        }
        $required = @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')
        foreach ($path in @('') + $required + @('Content', 'Inventory', 'ReportingWebService', 'SelfUpdate')) {
            $location = if ($path) { "WSUS Administration/$path" } else { 'WSUS Administration' }
            $flags = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $location `
                -Filter 'system.webServer/security/access' -Name sslFlags -ErrorAction Stop
            $expected = if ($path -in $required) { 8 } else { 0 }
            $expectedName = if ($path -in $required) { 'Ssl' } else { 'None' }
            if ([string]$flags.Value -notin @("$expected", $expectedName)) {
                throw "Incorrect SSL/client-certificate settings on '$location' (expected sslFlags=$expected, actual=$($flags.Value))."
            }
        }
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction Stop
        if ($setup.UsingSSL -ne 1) { throw 'WSUS application SSL mode is not enabled; configuressl is required.' }
        $server = Get-WsusServer -Name $Fqdn -PortNumber 8531 -UseSsl -ErrorAction Stop
        if (-not $server) { throw 'WSUS HTTPS API returned no server.' }
        $details.Add("OK: https://${Fqdn}:8531 API, certificate $($cert.Thumbprint), chain/revocation, and WSUS SSL settings verified; HTTP content on 8530 retained.")
        if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
            $details.Add("WARN: WSUS certificate expires $($cert.NotAfter.ToString('u')); renew and explicitly rebind before expiry.")
        }
        $passed = $true
    }
    catch { $details.Add("FAIL: WSUS HTTPS: $($_.Exception.Message)") }
    [pscustomobject]@{ Passed = $passed; Details = $details.ToArray() }
}

function Enable-MemLabsWsusHttps {
    param([Parameter(Mandatory)][string]$Fqdn)

    Import-Module WebAdministration -ErrorAction Stop
    $cert = Get-MemLabsWsusHttpsCertificate -Fqdn $Fqdn
    if (-not $cert) {
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $ticketOutput = @(& klist.exe -li 0x3e7 purge 2>&1)
            $ticketExit = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedPreference }
        if ($ticketExit -ne 0) { throw "WSUS enrollment machine-ticket refresh failed (exit $ticketExit): $($ticketOutput -join ' ')" }
        $enrollment = Get-Certificate -Template ConfigMgrWebServerCertificate -SubjectName "CN=$Fqdn" `
            -DnsName $Fqdn -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
        if (-not $enrollment.Certificate) { throw "WSUS certificate enrollment for $Fqdn did not issue a certificate (status $($enrollment.Status))." }
        $cert = Get-MemLabsWsusHttpsCertificate -Fqdn $Fqdn
        if (-not $cert) { throw "WSUS enrollment did not produce an eligible certificate for $Fqdn." }
    }
    Assert-MemLabsWsusCertificateChain -Certificate $cert
    $bindings = @(Get-WebBinding -Name 'WSUS Administration' -Protocol https -Port 8531 -ErrorAction Stop)
    if ($bindings.Count -gt 1) { throw 'Ambiguous WSUS HTTPS bindings on port 8531; no binding was changed.' }
    if ($bindings.Count -eq 0) {
        New-WebBinding -Name 'WSUS Administration' -IPAddress '*' -Port 8531 -Protocol https -ErrorAction Stop | Out-Null
        $bindings = @(Get-WebBinding -Name 'WSUS Administration' -Protocol https -Port 8531 -ErrorAction Stop)
    }
    if ($bindings.Count -ne 1) { throw 'Could not create WSUS HTTPS binding on port 8531.' }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $null = $bindings[0].AddSslCertificate($cert.Thumbprint, 'My')
    }
    finally { $ErrorActionPreference = $savedPreference }
    $readback = @(Get-WebBinding -Name 'WSUS Administration' -Protocol https -Port 8531 -ErrorAction Stop)
    if ($readback.Count -ne 1) { throw 'WSUS HTTPS binding readback is missing or ambiguous.' }
    $hash = $readback[0].certificateHash
    if ($hash -is [byte[]]) { $hash = [BitConverter]::ToString($hash).Replace('-', '') }
    if ([string]$hash -ne $cert.Thumbprint -or $readback[0].certificateStoreName -ine 'My') {
        throw 'WSUS certificate binding readback did not match; SSL settings were not changed.'
    }
    if (@(Get-WebBinding -Name 'WSUS Administration' -Protocol http -Port 8530 -ErrorAction Stop).Count -eq 0) {
        New-WebBinding -Name 'WSUS Administration' -IPAddress '*' -Port 8530 -Protocol http -ErrorAction Stop | Out-Null
    }
    $required = @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')
    foreach ($path in @('') + @('Content', 'Inventory', 'ReportingWebService', 'SelfUpdate') + $required) {
        $location = if ($path) { "WSUS Administration/$path" } else { 'WSUS Administration' }
        $flags = if ($path -in $required) { 'Ssl' } else { 'None' }
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $location `
            -Filter 'system.webServer/security/access' -Name sslFlags -Value $flags -ErrorAction Stop
    }
    $output = Invoke-MemLabsWsusUtil -Arguments @('configuressl', $Fqdn)
    $urls = @([regex]::Matches($output, 'https://[^\s''"<>]+') | ForEach-Object { $_.Value.TrimEnd('/') })
    if ($urls -notcontains "https://${Fqdn}:8531") { throw "WsusUtil configuressl did not return the expected HTTPS URL: $output" }
    $state = Get-MemLabsWsusHttpsState -Fqdn $Fqdn
    if (-not $state.Passed) { throw ($state.Details -join ' ') }
    Write-Verbose ($state.Details -join ' ')
}
