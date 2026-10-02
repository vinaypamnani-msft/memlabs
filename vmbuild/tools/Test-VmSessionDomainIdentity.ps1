<#
.SYNOPSIS
    Verifies domain-sensitive PSDirect work cannot run as a local SAM account.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$commonPath = Join-Path $RootPath 'Common.ps1'

function Import-FunctionDefinition {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$commonPath has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-FunctionDefinition -Name 'Get-VmSessionCredentialUserName')
. (Import-FunctionDefinition -Name 'Get-VmSessionGuestIdentity')
. (Import-FunctionDefinition -Name 'Test-VmSessionIdentityProbeCompatible')
. (Import-FunctionDefinition -Name 'Test-VmSessionIdentityCompatible')

if ((Get-VmSessionCredentialUserName -VmName 'CT1-PS2SITE' -VmDomainName 'cstest1.com' -AccountName 'vmbuildadmin') -ne 'vmbuildadmin@cstest1.com') {
    throw 'DNS-domain credentials are not rendered as a UPN.'
}
if ((Get-VmSessionCredentialUserName -VmName 'CT1-PS2SITE' -VmDomainName 'WORKGROUP' -AccountName 'vmbuildadmin') -ne 'CT1-PS2SITE\vmbuildadmin') {
    throw 'Workgroup credentials are not rendered as a local SAM principal.'
}
if ((Get-VmSessionCredentialUserName -VmName 'CT1-PS2SITE' -VmDomainName 'cstest1.com' -AccountName 'admin@cstest1.com') -ne 'admin@cstest1.com') {
    throw 'An explicit UPN was not preserved.'
}

$localSession = [pscustomobject]@{
    _GuestIdentity = 'DESKTOP-123\vmbuildadmin'
    _GuestComputerName = 'DESKTOP-123'
    _GuestIdentityIsLocal = $true
    _GuestUserDomain = 'DESKTOP-123'
    _GuestUserDnsDomain = ''
    _GuestUserName = 'vmbuildadmin'
}
$domainSession = [pscustomobject]@{
    _GuestIdentity = 'CSTEST1\vmbuildadmin'
    _GuestComputerName = 'CT1-PS2SITE'
    _GuestIdentityIsLocal = $false
    _GuestUserDomain = 'CSTEST1'
    _GuestUserDnsDomain = 'cstest1.com'
    _GuestUserName = 'vmbuildadmin'
}
if (Test-VmSessionIdentityCompatible -Session $localSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true `
    -ExpectedDomainName 'cstest1.com' -ExpectedAccountName 'vmbuildadmin') {
    throw 'A local SAM session was accepted for domain-required work.'
}
if (-not (Test-VmSessionIdentityCompatible -Session $domainSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true `
        -ExpectedDomainName 'cstest1.com' -ExpectedAccountName 'vmbuildadmin')) {
    throw 'A domain session was rejected for domain-required work.'
}
if (-not (Test-VmSessionIdentityCompatible -Session $localSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $false)) {
    throw 'A local session was rejected for ordinary non-strict work.'
}
$wrongDomainSession = [pscustomobject]@{
    _GuestIdentity = 'FABRIKAM\vmbuildadmin'
    _GuestComputerName = 'CT1-PS2SITE'
    _GuestIdentityIsLocal = $false
    _GuestUserDomain = 'FABRIKAM'
    _GuestUserDnsDomain = 'fabrikam.com'
    _GuestUserName = 'vmbuildadmin'
}
if (Test-VmSessionIdentityCompatible -Session $wrongDomainSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true `
    -ExpectedDomainName 'cstest1.com' -ExpectedAccountName 'vmbuildadmin') {
    throw 'A trusted-forest session from the wrong DNS domain was accepted.'
}
$wrongUserSession = [pscustomobject]@{
    _GuestIdentity = 'CSTEST1\admin'
    _GuestComputerName = 'CT1-PS2SITE'
    _GuestIdentityIsLocal = $false
    _GuestUserDomain = 'CSTEST1'
    _GuestUserDnsDomain = 'cstest1.com'
    _GuestUserName = 'admin'
}
if (Test-VmSessionIdentityCompatible -Session $wrongUserSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true `
    -ExpectedDomainName 'cstest1.com' -ExpectedAccountName 'vmbuildadmin') {
    throw 'A different user from the requested domain was accepted.'
}

$script:IdentityProbeMode = 'Timeout'
$script:OrphanCalls = 0
function Add-OrphanRunspace {
    param($Runspace, $PowerShell, $Session, [string]$Reason, [string]$VmName, $Job)
    $script:OrphanCalls++
}

$timeoutProbe = Get-VmSessionGuestIdentity -Session ([pscustomobject]@{}) -VmName 'CT1-PS2SITE' `
    -TimeoutSeconds 1 -ProbeOperation { param($Session); Start-Sleep -Seconds 10 }
if ($timeoutProbe.Succeeded -or -not $timeoutProbe.TimedOut -or -not $timeoutProbe.ChannelBroken -or
    -not $timeoutProbe.Abandoned -or $script:OrphanCalls -ne 1) {
    throw "Identity timeout was not bounded/classified/parked: succeeded=$($timeoutProbe.Succeeded) timedOut=$($timeoutProbe.TimedOut) channelBroken=$($timeoutProbe.ChannelBroken) abandoned=$($timeoutProbe.Abandoned) orphanCalls=$script:OrphanCalls."
}

$successProbe = Get-VmSessionGuestIdentity -Session ([pscustomobject]@{}) -VmName 'CT1-PS2SITE' `
    -TimeoutSeconds 3 -ProbeOperation {
        param($Session)
        [pscustomobject]@{
            Identity = 'DESKTOP-456\vmbuildadmin'
            ComputerName = 'DESKTOP-456'
            IsLocal = $true
            UserDomain = 'DESKTOP-456'
            UserDnsDomain = ''
            UserName = 'vmbuildadmin'
        }
    }
if (-not $successProbe.Succeeded -or -not $successProbe.IsLocal -or
    $successProbe.Identity -ne 'DESKTOP-456\vmbuildadmin' -or
    $successProbe.ComputerName -ne 'DESKTOP-456') {
    throw "Identity probe did not classify the guest's actual computer authority: identity=$($successProbe.Identity) computer=$($successProbe.ComputerName) local=$($successProbe.IsLocal)."
}

$identityDiagnostics = @{ ChannelBroken = $false; FailureReasons = @(); LastError = $null }
$compatible = Test-VmSessionIdentityCompatible -Session ([pscustomobject]@{}) -VmName 'CT1-PS2SITE' `
    -RequireDomainIdentity $true -Diagnostics $identityDiagnostics `
    -ProbeOperation { param($Session); Start-Sleep -Seconds 10 }
if ($compatible -or -not $identityDiagnostics.ChannelBroken -or
    $identityDiagnostics.FailureReasons -notcontains 'identity-probe-failed') {
    throw 'A timed-out identity probe was not propagated as a broken session channel.'
}

$reprobeMarker = Join-Path ([IO.Path]::GetTempPath()) "memlabs-identity-reprobe-$PID.txt"
Remove-Item -LiteralPath $reprobeMarker -Force -ErrorAction SilentlyContinue
$escapedMarker = $reprobeMarker.Replace("'", "''")
$reprobeOperation = [scriptblock]::Create(
    "param(`$Session) [IO.File]::WriteAllText('$escapedMarker', 'ran'); throw 'must not run'"
)
$abandonedSession = [pscustomobject]@{ _IdentityProbeAbandoned = $true }
$abandonedDiagnostics = @{ ChannelBroken = $false; FailureReasons = @(); LastError = $null }
$abandonedCompatible = Test-VmSessionIdentityCompatible -Session $abandonedSession -VmName 'CT1-PS2SITE' `
    -RequireDomainIdentity $true -ExpectedDomainName 'cstest1.com' -ExpectedAccountName 'vmbuildadmin' `
    -Diagnostics $abandonedDiagnostics -ProbeOperation $reprobeOperation
if ($abandonedCompatible -or (Test-Path -LiteralPath $reprobeMarker) -or
    $abandonedDiagnostics.FailureReasons -notcontains 'identity-probe-abandoned') {
    throw 'An abandoned identity session was re-probed or accepted.'
}
$abandonedNonStrict = Test-VmSessionIdentityCompatible -Session $abandonedSession -VmName 'CT1-PS2SITE' `
    -RequireDomainIdentity $false
if ($abandonedNonStrict) {
    throw 'A non-strict cache lookup accepted an abandoned identity session.'
}
Remove-Item -LiteralPath $reprobeMarker -Force -ErrorAction SilentlyContinue

$commonText = Get-Content -LiteralPath $commonPath -Raw
$jobsText = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Raw
if ($commonText -notmatch 'if \(-not \$requireDomain -and \$localUser -ne \$username\)') {
    throw 'Get-VmSession still offers local fallback during domain-required work.'
}
if ($commonText -notmatch 'Rejecting session created with.+guest identity') {
    throw 'Get-VmSession does not verify the actual guest identity after authentication.'
}
if ($commonText -notmatch 'AsyncWaitHandle\.WaitOne\(\$TimeoutSeconds \* 1000\)') {
    throw 'The guest identity probe is not bounded by a timeout.'
}
if ($commonText -notmatch 'BeginStop\(\$null, \$null\)' -or
    $commonText -notmatch "Reason 'identity probe timeout'") {
    throw 'Timed-out identity probes are not asynchronously cancelled and parked.'
}
$identityFunction = (Import-FunctionDefinition -Name 'Get-VmSessionGuestIdentity').ToString()
if ($identityFunction -match '\bStop-Job\b|\bRemove-Job\b|\bRemove-VmSession\b') {
    throw 'The bounded identity probe synchronously stops/removes a job or session.'
}
if ($commonText -notmatch 'Test-VmSessionIdentityCompatible -Session \$existingPs.+?-RequireDomainIdentity:\$requireDomain') {
    throw 'Cross-key session reuse does not enforce domain identity compatibility.'
}
$creationBlock = [regex]::Match(
    $commonText,
    '(?s)\$identityProbe\s*=\s*if\s*\(\$requireDomain\).+?\$cacheKey\s*=\s*\$entry\.CacheKey'
).Value
if (-not $creationBlock -or
    $creationBlock -notmatch 'Test-VmSessionIdentityProbeCompatible -Probe \$identityProbe' -or
    $creationBlock -match 'Test-VmSessionIdentityCompatible -Session \$ps') {
    throw 'Session creation does not evaluate exactly the first identity probe result.'
}
if (@([regex]::Matches($jobsText, '\$global:MemLabsRequireDomainIdentity\s*=\s*\[bool\]')).Count -ne 2) {
    throw 'Phase 10 and Phase 11 do not both require domain identity for domain-joined Windows roles.'
}
if ($jobsText -notmatch '(?s)Get-VmSessionCredentialUserName.+?-VmDomainName \$deployConfig\.vmOptions\.domainName' -or
    -not $jobsText.Contains('Identity mismatch: expected $targetUser@$targetDomain')) {
    throw 'The direct parallel node-readiness probe bypasses UPN or guest identity validation.'
}
$serialReadinessCalls = @([regex]::Matches(
        $jobsText,
        '(?s)Invoke-VmCommand\s+-VmName\s+\$node\s+-VmDomainName\s+\$deployConfig\.vmOptions\.domainName.+?-DisplayName\s+"DSC: Check Nodes Ready(?: \(fallback\))?"'
    ))
if ($serialReadinessCalls.Count -ne 2 -or
    @($serialReadinessCalls | Where-Object { $_.Value -notmatch '-RequireDomainIdentity' }).Count -ne 0) {
    throw 'A serial node-readiness path can bypass strict domain identity.'
}

$productionFiles = @(
    (Join-Path $RootPath 'Common.ps1'),
    (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'),
    (Join-Path $RootPath 'common\Common.Phases.ps1')
)
$directConstructors = [System.Collections.Generic.List[string]]::new()
foreach ($path in $productionFiles) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $commands = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'New-PSSession'
            }, $true))
    foreach ($command in $commands) {
        $parameters = @($command.CommandElements | Where-Object {
                $_ -is [Management.Automation.Language.CommandParameterAst]
            } | ForEach-Object { $_.ParameterName })
        if ($parameters -contains 'VMId' -or $parameters -contains 'VMName') {
            $directConstructors.Add("$([IO.Path]::GetFileName($path)):$($command.Extent.StartLineNumber)")
        }
    }
}
if ($directConstructors.Count -ne 2) {
    throw "Unexpected production PowerShell Direct constructors found: $($directConstructors -join ', ')"
}

Write-Host 'PASS -- PSDirect uses UPN credentials and rejects local identities for domain-required work.'
