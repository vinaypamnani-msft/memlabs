<#
.SYNOPSIS
    Verifies proxy changes stay within the provider's site and its secondaries.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

$path = Join-Path $RootPath 'DSC\phases\ConfigureCMProxy.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
$connections = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.Extent.Text -like '. $PSScriptRoot\Connect-CMSite.ps1*'
}, $true))
if ($connections.Count -ne 1) { throw 'Expected one ConfigMgr connection boundary.' }
$connection = $connections[0].Extent
$text = $ast.Extent.Text.Remove($connection.StartOffset, $connection.EndOffset - $connection.StartOffset).
    Insert($connection.StartOffset, '$SiteCode = $script:TestSiteCode')
$proxyScript = [scriptblock]::Create($text)

function Write-DscStatus {
    param([string] $Message, [switch] $Failure)
    if ($Failure) { $script:WorkflowFailures.Add($Message) }
}
function Write-StatusLogEntry {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $Message)
    process {}
}
function Get-CMSiteSystemServer {
    param($SiteSystemServerName, $SiteCode, $ErrorAction)
    $script:Queries.Add("System:$SiteCode`:$SiteSystemServerName")
    if ($SiteCode -notin $script:OwnedSites -or $script:MissingSystem) { return }
    [pscustomobject]@{ SiteCode = $SiteCode }
}
function Get-CMSoftwareUpdatePoint {
    param($SiteSystemServerName, $SiteCode, $ErrorAction)
    $script:Queries.Add("SUP:$SiteCode`:$SiteSystemServerName")
    if ($SiteCode -notin $script:OwnedSites -or $script:MissingSup) { return }
    [pscustomobject]@{ SiteCode = $SiteCode }
}
function Set-CMSiteSystemServer {
    param($SiteSystemServerName, $SiteCode, $EnableProxy, $ProxyServerName, $ProxyServerPort, $ErrorAction)
    if ($script:FailSet) { throw 'Injected proxy setter failure' }
    $script:Changes.Add("System:$SiteCode`:$SiteSystemServerName`:$EnableProxy")
    if ($EnableProxy) {
        Assert-Equal 'PROXY.lab.test' $ProxyServerName 'Proxy endpoint changed.'
        Assert-Equal 3128 $ProxyServerPort 'Proxy port changed.'
    }
}
function Set-CMSoftwareUpdatePoint {
    param($SiteSystemServerName, $SiteCode, $UseProxy, $ErrorAction)
    $script:Changes.Add("SUP:$SiteCode`:$SiteSystemServerName`:$UseProxy")
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ("MemLabs-CmProxy-" + [guid]::NewGuid())
$null = New-Item -Path $testDirectory -ItemType Directory
$configPath = Join-Path $testDirectory 'deploy.json'
$workflowPath = Join-Path $testDirectory 'ScriptWorkflow.json'

try {
    foreach ($enable in @($false, $true)) {
        $vms = @([pscustomobject]@{ vmName = 'PROXY'; role = 'Proxy' })
        foreach ($site in @('PS1', 'PS2', 'PS3')) {
            $vms += [pscustomobject]@{
                vmName = "$site-SITE"; role = 'Primary'; siteCode = $site
                parentSiteCode = 'CAS'; useProxy = $enable
            }
            $vms += [pscustomobject]@{
                vmName = "$site-SUP"; role = 'SiteSystem'; siteCode = $site
                installSUP = $true; useProxy = $enable
            }
            $vms += [pscustomobject]@{
                vmName = "$site-SEC"; role = 'Secondary'; siteCode = "S$site"
                parentSiteCode = $site; installSUP = $true; useProxy = $enable
            }
        }
        $vms += [pscustomobject]@{
            vmName = 'CAS-SITE'; role = 'CAS'; siteCode = 'CAS'; useProxy = $enable
        }
        $vms += [pscustomobject]@{
            vmName = 'CLIENT'; role = 'DomainMember'; siteCode = 'PS1'; useProxy = $enable
        }
        @{ vmOptions = @{ domainName = 'lab.test' }; virtualMachines = $vms } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath

        foreach ($site in @('PS1', 'PS2', 'PS3', 'CAS')) {
            $script:TestSiteCode = $site
            $script:OwnedSites = @($site)
            if ($site -ne 'CAS') { $script:OwnedSites += "S$site" }

            foreach ($mode in @('Success', 'MissingSystem', 'MissingSup', 'FailSet')) {
                $script:MissingSystem = $mode -eq 'MissingSystem'
                $script:MissingSup = $mode -eq 'MissingSup'
                $script:FailSet = $mode -eq 'FailSet'
                $script:Queries = [Collections.Generic.List[string]]::new()
                $script:Changes = [Collections.Generic.List[string]]::new()
                $script:WorkflowFailures = [Collections.Generic.List[string]]::new()
                '{}' | Set-Content -LiteralPath $workflowPath
                & $proxyScript -ConfigFilePath $configPath -LogPath $testDirectory
                $state = Get-Content -LiteralPath $workflowPath -Raw | ConvertFrom-Json

                $expectedStatus = if ($mode -eq 'Success' -or ($site -eq 'CAS' -and $mode -eq 'MissingSup')) {
                    'Completed'
                } else { 'NotStart' }
                Assert-Equal $expectedStatus $state.ConfigureCMProxy.Status "$site/$enable/$mode workflow state."
                Assert-Equal ($expectedStatus -eq 'NotStart') ($script:WorkflowFailures.Count -gt 0) `
                    "$site/$enable/$mode must report genuine owned-site failures."
                $foreignQueries = @($script:Queries | Where-Object { ($_ -split ':')[1] -notin $script:OwnedSites })
                Assert-Equal 0 $foreignQueries.Count "$site queried another primary or its secondaries."

                if ($mode -eq 'Success') {
                    $expectedChanges = @("System:$site`:$site-SITE.lab.test`:$enable")
                    if ($site -ne 'CAS') {
                        $expectedChanges += "System:$site`:$site-SUP.lab.test`:$enable"
                        $expectedChanges += "SUP:$site`:$site-SUP.lab.test`:$enable"
                        $expectedChanges += "System:S$site`:$site-SEC.lab.test`:$enable"
                        $expectedChanges += "SUP:S$site`:$site-SEC.lab.test`:$enable"
                    }
                    Assert-Equal (($expectedChanges | Sort-Object) -join ',') `
                        (($script:Changes | Sort-Object) -join ',') "$site proxy targets and flags."
                }
            }
        }
    }
    Write-Host 'PASS -- proxy enable/disable isolates primaries and CAS, includes owned secondaries, and preserves retryable failures.'
}
finally {
    Remove-Item -LiteralPath $configPath, $workflowPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDirectory -Force
}
