<#
.SYNOPSIS
    Executes the Linux proxy-client script twice against sandbox files.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $vmbuildRoot 'scripts\linux\roles\proxy-client.sh'
$linuxSourcePath = Join-Path $vmbuildRoot 'common\Common.Linux.ps1'
$scriptBlocksPath = Join-Path $vmbuildRoot 'common\Common.ScriptBlocks.ps1'

$source = Get-Content -LiteralPath $scriptPath -Raw
if ($source.Contains('sed -i "\#${BEGIN_MARK}#,\#${END_MARK}#d"')) {
    throw 'proxy-client.sh still uses markers beginning with the sed delimiter.'
}
if (-not $source.Contains('sed -i "/^${BEGIN_MARK}$/,/^${END_MARK}$/d"')) {
    throw 'proxy-client.sh does not remove the exact managed marker range.'
}

$bash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $bash) { throw 'Git Bash is required for the Linux proxy-client regression test.' }

. $linuxSourcePath
$renderedScript = Get-LinuxProxyClientBashScript -ProxyHost '192.168.50.2' -ProxyPort 3128 `
    -Domain 'cstest5.com' -BypassNetwork '192.168.50.0'

function ConvertTo-GitBashPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $escaped = $Path.Replace("'", "'\''")
    $result = @(& $bash -lc "cygpath -u '$escaped'" 2>&1)
    if ($LASTEXITCODE -ne 0 -or $result.Count -ne 1) {
        throw "Could not convert '$Path' to a Git Bash path: $($result -join '; ')"
    }
    return "$($result[0])".Trim()
}

$testRoot = Join-Path $env:TEMP ("memlabs-proxy-client-" + [guid]::NewGuid().ToString('N'))
$environmentPath = Join-Path $testRoot 'environment'
$aptPath = Join-Path $testRoot 'apt\00-memlabs-proxy'
$profilePath = Join-Path $testRoot 'profile\memlabs-proxy.sh'
$renderedScriptPath = Join-Path $testRoot 'proxy-client-rendered.sh'
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
[IO.File]::WriteAllText($renderedScriptPath, ($renderedScript -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
@'
KEEP_BEFORE=1
# >>> memlabs-proxy >>>
OLD_PROXY=remove-me
# <<< memlabs-proxy <<<
KEEP_AFTER=1
'@ | Set-Content -LiteralPath $environmentPath -Encoding ASCII

$saved = @{}
$testEnvironment = @{
    MEMLABS_ENVIRONMENT_FILE = ConvertTo-GitBashPath $environmentPath
    MEMLABS_APT_PROXY_FILE = ConvertTo-GitBashPath $aptPath
    MEMLABS_PROFILE_PROXY_FILE = ConvertTo-GitBashPath $profilePath
    MEMLABS_SKIP_SNAP_PROXY = '1'
}
try {
    foreach ($key in $testEnvironment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $testEnvironment[$key], 'Process')
    }
    $bashScriptPath = ConvertTo-GitBashPath $renderedScriptPath
    foreach ($pass in 1..2) {
        $output = @(& $bash $bashScriptPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "proxy-client.sh pass $pass failed: $($output -join [Environment]::NewLine)"
        }
        if ($output[-1] -ne 'PROXY_READY') {
            throw "proxy-client.sh pass $pass did not emit PROXY_READY: $($output -join '; ')"
        }
    }

    $environmentText = Get-Content -LiteralPath $environmentPath -Raw
    if (@([regex]::Matches($environmentText, '(?m)^# >>> memlabs-proxy >>>$')).Count -ne 1 -or
        @([regex]::Matches($environmentText, '(?m)^# <<< memlabs-proxy <<<$')).Count -ne 1) {
        throw "Proxy marker block was not idempotent:`n$environmentText"
    }
    if ($environmentText -match 'OLD_PROXY=remove-me' -or
        $environmentText -notmatch '(?m)^KEEP_BEFORE=1$' -or
        $environmentText -notmatch '(?m)^KEEP_AFTER=1$') {
        throw "Managed-block replacement damaged unrelated environment content:`n$environmentText"
    }
    $expectedNoProxy = 'localhost,127.0.0.1,::1,.cstest5.com,192.168.50.2,192.168.50.0/24,192.168.50.1'
    if ($environmentText -notmatch 'http_proxy="http://192\.168\.50\.2:3128"' -or
        -not $environmentText.Contains("no_proxy=`"$expectedNoProxy`"")) {
        throw "Proxy environment values were not written correctly:`n$environmentText"
    }
    if ((Get-Content -LiteralPath $aptPath -Raw) -notmatch 'Acquire::https::Proxy "http://192\.168\.50\.2:3128";') {
        throw 'APT proxy configuration was not written.'
    }
    if ((Get-Content -LiteralPath $profilePath -Raw) -notmatch 'export HTTPS_PROXY="http://192\.168\.50\.2:3128"') {
        throw 'Profile proxy configuration was not written.'
    }

    $linuxSource = Get-Content -LiteralPath $linuxSourcePath -Raw
    $scriptBlockSource = Get-Content -LiteralPath $scriptBlocksPath -Raw
    $aclRepair = $linuxSource.IndexOf('$null = Set-LinuxSshPrivateKeyAcl -PrivateKeyPath $privateKeyPath')
    $keyValidation = $linuxSource.IndexOf('$pairCheck = Test-LinuxSshKeyPairMatches')
    if ($aclRepair -lt 0 -or $keyValidation -lt 0 -or $aclRepair -gt $keyValidation) {
        throw 'SSH private-key ACL repair does not run before cached pair validation.'
    }
    $preflightStart = $linuxSource.IndexOf('function Repair-LinuxAdminSshKeyPair')
    $preflightAclRepair = $linuxSource.IndexOf('$null = Set-LinuxSshPrivateKeyAcl -PrivateKeyPath $privateKeyPath', $preflightStart)
    $preflightValidation = $linuxSource.IndexOf('$check = Test-LinuxSshKeyPairMatches', $preflightStart)
    if ($preflightStart -lt 0 -or $preflightAclRepair -lt 0 -or
        $preflightValidation -lt 0 -or $preflightAclRepair -gt $preflightValidation) {
        throw 'Linux SSH preflight does not repair copied private-key ACLs before validation.'
    }
    if ($linuxSource -notmatch 'LinuxRoleConfigurationFailureSummary\s*=\s*"module=\$\(\$op\.Name\); exit=\$exitCode"') {
        throw 'Linux role configuration does not preserve the failed module and exit code.'
    }
    if ($scriptBlockSource -notmatch 'Linux_Configure failed\$failureSuffix') {
        throw 'The Phase 3 console does not surface the Linux failure summary.'
    }
}
finally {
    foreach ($key in $testEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- Linux proxy-client configuration is executable, idempotent, and reports module failures.'
