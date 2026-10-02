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
}
$domainSession = [pscustomobject]@{
    _GuestIdentity = 'CSTEST1\vmbuildadmin'
    _GuestComputerName = 'CT1-PS2SITE'
    _GuestIdentityIsLocal = $false
}
if (Test-VmSessionIdentityCompatible -Session $localSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true) {
    throw 'A local SAM session was accepted for domain-required work.'
}
if (-not (Test-VmSessionIdentityCompatible -Session $domainSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $true)) {
    throw 'A domain session was rejected for domain-required work.'
}
if (-not (Test-VmSessionIdentityCompatible -Session $localSession -VmName 'CT1-PS2SITE' -RequireDomainIdentity $false)) {
    throw 'A local session was rejected for ordinary non-strict work.'
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
if (@([regex]::Matches($jobsText, '\$global:MemLabsRequireDomainIdentity\s*=\s*\[bool\]')).Count -ne 2) {
    throw 'Phase 10 and Phase 11 do not both require domain identity for domain-joined Windows roles.'
}

Write-Host 'PASS -- PSDirect uses UPN credentials and rejects local identities for domain-required work.'
