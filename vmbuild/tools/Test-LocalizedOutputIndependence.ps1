<#
.SYNOPSIS
    Verifies production decisions do not depend on localized native-command text.
#>
[CmdletBinding()]
param (
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
trap {
    Write-Host "FAIL  unhandled test error: $($_.Exception.Message)"
    $script:Failures++
    break
}

function Assert-LocalizedOutput {
    param ([bool]$Condition, [string]$What)

    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $script:Failures++ }
}

function Get-ParsedSource {
    param ([string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $realErrors = @($errors | Where-Object { $_.ErrorId -ne 'ModuleNotFoundDuringParse' })
    Assert-LocalizedOutput ($realErrors.Count -eq 0) "$Path parses"
    return [pscustomobject]@{ Ast = $ast; Text = [IO.File]::ReadAllText($Path) }
}

$phase3Path = Join-Path $RootPath 'DSC\phases\Phase3.ps1'
$installCmPath = Join-Path $RootPath 'DSC\phases\InstallAndUpdateSCCM.ps1'
$templatePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$stallPath = Join-Path $RootPath 'tools\Watch-DscStall.ps1'

$phase3 = Get-ParsedSource $phase3Path
$installCm = Get-ParsedSource $installCmPath
$template = Get-ParsedSource $templatePath
$validation = Get-ParsedSource $validationPath
$stall = Get-ParsedSource $stallPath

Assert-LocalizedOutput ($phase3.Text -notmatch 'netsh\s+winhttp\s+show\s+proxy') 'Phase 3 does not parse localized netsh proxy output'
Assert-LocalizedOutput ($phase3.Text -match "GetEnvironmentVariable\('HTTPS_PROXY', 'Machine'\)" -and
    $phase3.Text -match "GetEnvironmentVariable\('NO_PROXY', 'Machine'\)") 'Phase 3 uses machine-scoped proxy handoff values'
$proxyMatchAssignments = @($phase3.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$proxyMatches'
        }, $true))
Assert-LocalizedOutput ($proxyMatchAssignments.Count -eq 1) 'Phase 3 proxy route matcher is extractable'
if ($proxyMatchAssignments.Count -eq 1) {
    $proxyMatches = & ([scriptblock]::Create($proxyMatchAssignments[0].Right.Extent.Text))
    Assert-LocalizedOutput (& $proxyMatches ([Uri]'http://ihost.example:3128') ([Uri]'http://IHOST.example:3128')) 'exact proxy route matches ordinally under Turkish-sensitive names'
    Assert-LocalizedOutput (-not (& $proxyMatches ([Uri]'http://old.example:3128') ([Uri]'http://new.example:3128'))) 'stale proxy host does not match'
    Assert-LocalizedOutput (-not (& $proxyMatches ([Uri]'https://ihost.example:3128') ([Uri]'http://ihost.example:3128'))) 'wrong proxy scheme does not match'
    Assert-LocalizedOutput (-not (& $proxyMatches ([Uri]'http://ihost.example:8080') ([Uri]'http://ihost.example:3128'))) 'wrong proxy port does not match'
    Assert-LocalizedOutput (-not (& $proxyMatches ([Uri]'https://aka.ms') ([Uri]'http://ihost.example:3128'))) 'direct or bypassed destination does not match the configured proxy'
}

Assert-LocalizedOutput ($template.Text -notmatch 'netsh\s+winhttp\s+show\s+proxy') 'DSC proxy resources do not parse localized netsh output'
Assert-LocalizedOutput ($template.Text -match 'WinHttpGetDefaultProxyConfiguration') 'DSC proxy readback uses the WinHTTP API'
Assert-LocalizedOutput ($template.Text -match 'AccessType -ne 3' -and $template.Text -match 'OrdinalIgnoreCase') 'WinHTTP named-proxy state is compared ordinally'

Assert-LocalizedOutput ($installCm.Text -notmatch 'nltest\s+/dsgetdc') 'SQL preflight does not parse localized nltest output'
Assert-LocalizedOutput ($installCm.Text -match 'LOGONSERVER' -and
    $installCm.Text -match 'Resolve-DnsName.+_ldap\._tcp\.dc\._msdcs') 'SQL preflight uses structured DC fallback sources'
Assert-LocalizedOutput ($installCm.Text -match '(?s)if \(-not \$dcName\).+?retrying DNS resolution') 'unknown DC discovery remains unknown and retries'

Assert-LocalizedOutput ($validation.Text -notmatch 'revocation check passed') 'certificate revocation does not parse certutil success prose'
Assert-LocalizedOutput ($validation.Text -notmatch 'certutil\.exe -verify -urlfetch') 'certificate revocation does not parse certutil verification output'
Assert-LocalizedOutput ($validation.Text -match 'X509RevocationMode\]::Online' -and
    $validation.Text -match 'X509RevocationFlag\]::ExcludeRoot' -and
    $validation.Text -match '\.ChainStatus') 'certificate revocation uses typed X509Chain status'
Assert-LocalizedOutput ($validation.Text -match 'Get-ItemPropertyValue.+CRLDeltaPeriodUnits') 'CA delta CRL configuration comes from CertSvc registry'
Assert-LocalizedOutput ($validation.Text -match '(?s)\$ErrorActionPreference\s*=\s*''Continue''.+?\$dcdiag\s*=\s*& dcdiag\.exe.+?\$dcdiagExitCode\s*=\s*\$LASTEXITCODE.+?\$ErrorActionPreference\s*=\s*\$savedErrorActionPreference' -and
    $validation.Text -match 'elseif \(\$dcdiagExitCode -ne 0\)') 'dcdiag verdict uses its native exit code'
Assert-LocalizedOutput ($validation.Text -notmatch 'failed test') 'dcdiag verdict does not parse localized failure prose'
Assert-LocalizedOutput ($validation.Text -match '(?s)\$ErrorActionPreference\s*=\s*''Continue''.+?\$scLines\s*=\s*@\(& nltest.+?\$scExitCode\s*=\s*\$LASTEXITCODE.+?\$ErrorActionPreference\s*=\s*\$savedErrorActionPreference' -and
    $validation.Text -match 'if \(\$scExitCode -eq 0\)') 'nltest secure-channel verdict uses its native exit code'
Assert-LocalizedOutput ($validation.Text -notmatch 'NERR_Success|Connection Status = 0') 'nltest verdict does not parse localized success prose'
Assert-LocalizedOutput ($validation.Text -notmatch 'certutil\.exe -store CA CRL|NextUpdate:') 'base CRL freshness does not parse localized certutil labels'
Assert-LocalizedOutput ($validation.Text -match 'CX509CertificateRevocationList' -and
    $validation.Text -match '\$crl\.BaseCRL' -and $validation.Text -match '\$crl\.NextUpdate') 'base CRL freshness uses typed CRL properties'

$guestPayloadAssignment = @($stall.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$guestPayload'
        }, $true))
Assert-LocalizedOutput ($guestPayloadAssignment.Count -eq 1) 'stall watcher has one embedded guest payload'
if ($guestPayloadAssignment.Count -eq 1) {
    $guestPayload = $guestPayloadAssignment[0].Right.Extent.Text -replace "^@'\r?\n", '' -replace "\r?\n'@$", ''
    Assert-LocalizedOutput (-not [string]::IsNullOrWhiteSpace($guestPayload)) 'stall watcher guest payload extraction is nonempty'
    $guestTokens = $null
    $guestErrors = $null
    $guestAst = [System.Management.Automation.Language.Parser]::ParseInput($guestPayload, [ref]$guestTokens, [ref]$guestErrors)
    Assert-LocalizedOutput ($guestErrors.Count -eq 0) 'stall watcher guest payload parses'
    Assert-LocalizedOutput ($guestPayload -notmatch 'sc\.exe\s+queryex|SERVICE_NAME:|PID\\s\*') 'stall watcher does not parse localized sc.exe labels'

    $serviceReaderDefinition = @($guestAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text -match 'MemLabs\.ServiceProcessReader'
            }, $true) | Sort-Object { $_.Extent.EndOffset - $_.Extent.StartOffset } | Select-Object -First 1)
    $servicePidFunction = @($guestAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-ServicePid'
            }, $true))
    Assert-LocalizedOutput ($serviceReaderDefinition.Count -eq 1 -and $servicePidFunction.Count -eq 1) 'stall watcher SCM reader definitions are extractable'
    if ($serviceReaderDefinition.Count -eq 1 -and $servicePidFunction.Count -eq 1) {
        . ([scriptblock]::Create($serviceReaderDefinition[0].Extent.Text))
        . ([scriptblock]::Create($servicePidFunction[0].Extent.Text))
        foreach ($serviceName in @('winmgmt', 'winrm')) {
            $typedPid = @(Get-ServicePid -Name $serviceName)
            $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
            Assert-LocalizedOutput ($typedPid.Count -eq 1 -and $typedPid[0] -is [int]) "SCM reader returns one integer for $serviceName"
            Assert-LocalizedOutput ($typedPid[0] -eq [int]$service.ProcessId) "SCM reader agrees with healthy-host WMI for $serviceName"
        }
        Assert-LocalizedOutput ((Get-ServicePid -Name 'MemLabsGuaranteedMissingService') -eq 0) 'SCM reader returns zero for a missing service'
    }
}

$proxyFunction = @($template.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsWinHttpDefaultProxy'
        }, $true))
Assert-LocalizedOutput ($proxyFunction.Count -eq 1) 'typed WinHTTP helper has one definition'
if ($proxyFunction.Count -eq 1) {
    . ([scriptblock]::Create($proxyFunction[0].Extent.Text))
    $proxyReads = @(1..10 | ForEach-Object { Get-MemLabsWinHttpDefaultProxy })
    Assert-LocalizedOutput ($proxyReads.Count -eq 10) 'typed WinHTTP helper returns one result per read'
    Assert-LocalizedOutput (@($proxyReads | Where-Object { $_.AccessType -isnot [int] -or $_.Error -isnot [int] }).Count -eq 0) 'typed WinHTTP results contain numeric access and error fields'
}

$savedPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Stop'
    $nativeOutput = $null
    $nativeExitCode = -1
    $innerPreference = $ErrorActionPreference
    try {
        try {
            $ErrorActionPreference = 'Continue'
            $nativeOutput = @(& $env:ComSpec /d /c 'echo localized-error 1>&2 & exit /b 7' 2>&1)
            $nativeExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $innerPreference
        }
    }
    catch {
        Assert-LocalizedOutput $false "native stderr escaped Continue guard: $($_.Exception.Message)"
    }
    Assert-LocalizedOutput ($nativeExitCode -eq 7) 'PS5-safe native guard captures nonzero exit after stderr'
    Assert-LocalizedOutput ($nativeOutput.Count -gt 0) 'PS5-safe native guard preserves diagnostic stderr'
    Assert-LocalizedOutput ($ErrorActionPreference -eq 'Stop') 'PS5-safe native guard restores caller error preference'
}
finally {
    $ErrorActionPreference = $savedPreference
}

$savedCulture = [Globalization.CultureInfo]::CurrentCulture
$savedUiCulture = [Globalization.CultureInfo]::CurrentUICulture
try {
    $turkish = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    [Globalization.CultureInfo]::CurrentCulture = $turkish
    [Globalization.CultureInfo]::CurrentUICulture = $turkish
    Assert-LocalizedOutput ([string]::Equals('IHOST:3128', 'ihost:3128', [StringComparison]::OrdinalIgnoreCase)) 'proxy comparison is Turkish-safe'

    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        Assert-LocalizedOutput ($chain.ChainPolicy.RevocationMode -eq 'NoCheck') 'typed X509Chain API is available under Turkish culture'
    }
    finally {
        $chain.Dispose()
    }
}
finally {
    [Globalization.CultureInfo]::CurrentCulture = $savedCulture
    [Globalization.CultureInfo]::CurrentUICulture = $savedUiCulture
}

Write-Host "Engine: $($PSVersionTable.PSVersion); failures: $script:Failures"
if ($script:Failures -gt 0) { exit 1 }
exit 0