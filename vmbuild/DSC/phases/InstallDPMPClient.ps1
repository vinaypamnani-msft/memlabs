#InstallDPMPClient.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","

# Per-VM cmOptions wins over the rehydrated global for multi-hierarchy deploys.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$usePKI = $cmo.UsePKI
if (-not $usePKI) {
    $usePKI = $false
}
# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    Write-DscStatus "Failed to get SMS Provider for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    return
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}


$DPs = @()
$MPs = @()
$PullDPs = @()
$BareSiteSystems = @()
$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes

foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" } ) {
    if ($vm.siteCode -in $ValidSiteCodes) {
        $hasAnyRole = $vm.installDP -or $vm.installMP -or $vm.installSUP -or $vm.installRP -or $vm.installSMSProv
        if ($vm.installDP) {
            if ($vm.enablePullDP) {
                $PullDPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                    SourceDP       = $vm.pullDPSourceDP
                }
            }
            else {
                $DPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                }
            }
        }
        if ($vm.installMP) {
            if ($vm.siteCode -notin $ReportingSiteCodes) {
                $MPs += [PSCustomObject]@{
                    ServerName     = $vm.vmName
                    ServerSiteCode = $vm.siteCode
                }
            }
            else {
                Write-DscStatus "Skip MP role for $($vm.vmName) since it's a remote site system in Secondary site"
            }
        }
        # Register VMs with no automated roles so they appear in the console
        # and roles (e.g. Reporting Services Point) can be added manually.
        if (-not $hasAnyRole) {
            $BareSiteSystems += [PSCustomObject]@{
                ServerName     = $vm.vmName
                ServerSiteCode = $vm.siteCode
            }
        }
    }
}

# Trim nulls/blanks
$DPNames = $DPs.ServerName | Where-Object { $_ -and $_.Trim() }
$PullDPNames = $PullDPs.ServerName | Where-Object { $_ -and $_.Trim() }
$MPNames = $MPs.ServerName | Where-Object { $_ -and $_.Trim() }

# Quick check: verify all expected DPs and MPs are already installed
$allInstalled = $true
foreach ($DP in $DPs) {
    if ([string]::IsNullOrWhiteSpace($DP.ServerName)) { continue }
    $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
    if (-not (Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $DP.ServerSiteCode)) {
        $allInstalled = $false
        break
    }
}
if ($allInstalled) {
    foreach ($PDP in $PullDPs) {
        if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) { continue }
        $DPFQDN = $PDP.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $PDP.ServerSiteCode)) {
            $allInstalled = $false
            break
        }
    }
}
if ($allInstalled) {
    foreach ($MP in $MPs) {
        if ([string]::IsNullOrWhiteSpace($MP.ServerName)) { continue }
        $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMManagementPoint -SiteSystemServerName $MPFQDN)) {
            $allInstalled = $false
            break
        }
    }
}
# Also verify at least 1 DP and 1 MP exist in the site
if ($allInstalled) {
    $dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
    $mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count
    if ($dpCount -eq 0 -or $mpCount -eq 0) {
        $allInstalled = $false
    }
}
# Check bare site systems are registered
if ($allInstalled) {
    foreach ($BSS in $BareSiteSystems) {
        if ([string]::IsNullOrWhiteSpace($BSS.ServerName)) { continue }
        $BSSFQDN = $BSS.ServerName.Trim() + "." + $DomainFullName
        if (-not (Get-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode)) {
            $allInstalled = $false
            break
        }
    }
}

if ($allInstalled) {
    Write-DscStatus "All DP/MP roles already installed. Skipping InstallDPMPClient."
    $Configuration.InstallDP.Status = 'Completed'
    $Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration.InstallMP.Status = 'Completed'
    $Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    return
}

Write-DscStatus "MP role to be installed on '$($MPNames -join ',')'"
Write-DscStatus "DP role to be installed on '$($DPNames -join ',')'"
Write-DscStatus "Pull DP role to be installed on '$($PullDPNames -join ',')'"

# Register bare site systems (no DP/MP/SUP/RP) in the console so roles can
# be added manually after deployment (e.g. Reporting Services Point).
foreach ($BSS in $BareSiteSystems) {
    if ([string]::IsNullOrWhiteSpace($BSS.ServerName)) { continue }
    $BSSFQDN = $BSS.ServerName.Trim() + "." + $DomainFullName
    $existing = Get-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode
    if (-not $existing) {
        Write-DscStatus "Registering bare site system $BSSFQDN in site $($BSS.ServerSiteCode)"
        New-CMSiteSystemServer -SiteSystemServerName $BSSFQDN -SiteCode $BSS.ServerSiteCode *>&1 | Write-StatusLogEntry
    }
    else {
        Write-DscStatus "Site system $BSSFQDN already registered in site $($BSS.ServerSiteCode)"
    }
}

foreach ($DP in $DPs) {

    if ([string]::IsNullOrWhiteSpace($DP.ServerName)) {
        Write-DscStatus "Found an empty DP ServerName. Skipping"
        continue
    }

    $DPFQDN = $DP.ServerName.Trim() + "." + $DomainFullName
    Install-DP -ServerFQDN $DPFQDN -ServerSiteCode $DP.ServerSiteCode -usePKI:$usePKI
}

foreach ($MP in $MPs) {

    if ([string]::IsNullOrWhiteSpace($MP.ServerName)) {
        Write-DscStatus "Found an empty MP ServerName. Skipping"
        continue
    }

    $MPFQDN = $MP.ServerName.Trim() + "." + $DomainFullName
    Install-MP -ServerFQDN $MPFQDN -ServerSiteCode $MP.ServerSiteCode -usePKI:$usePKI
}

# A Pull DP requires its Source DP to already be an INSTALLED standard DP.
# Add-CMDistributionPoint -EnablePullDP -SourceDistributionPoint throws
# "No object corresponds to the specified parameters" (a terminating error that
# aborts this whole script) when the source isn't a DP yet. The source is
# frequently the site server itself (e.g. the Primary), which is NOT in $DPs and
# only gets a DP from the "force install DP on Site Server" fallback further
# below -- code that never runs once the pull-DP add throws. That leaves the site
# with no DP and the pull DP permanently uninstalled. Install every unique pull-DP
# source as a standard DP FIRST so the source object exists before we add pull DPs.
$EnsuredSourceDPs = @{}
foreach ($PDP in $PullDPs) {
    if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) { continue }
    if ([string]::IsNullOrWhiteSpace($PDP.SourceDP)) { continue }
    $SourceDPFQDN = $PDP.SourceDP.Trim() + "." + $DomainFullName
    if ($EnsuredSourceDPs.ContainsKey($SourceDPFQDN)) { continue }
    $EnsuredSourceDPs[$SourceDPFQDN] = $true
    if (-not (Get-CMDistributionPoint -SiteSystemServerName $SourceDPFQDN -SiteCode $PDP.ServerSiteCode)) {
        Write-DscStatus "Pull DP source '$SourceDPFQDN' is not a Distribution Point yet. Installing standard DP on the source first (required before adding pull DPs)."
        Install-DP -ServerFQDN $SourceDPFQDN -ServerSiteCode $PDP.ServerSiteCode -usePKI:$usePKI
    }
}

foreach ($PDP in $PullDPs) {

    if ([string]::IsNullOrWhiteSpace($PDP.ServerName)) {
        Write-DscStatus "Found an empty Pull DP ServerName. Skipping"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($PDP.SourceDP)) {
        Write-DscStatus "Found Pull DP $($PDP.ServerName) with empty SourceDP. Skipping"
        continue
    }

    $DPFQDN = $PDP.ServerName.Trim() + "." + $DomainFullName
    $SourceDPFQDN = $PDP.SourceDP.Trim() + "." + $DomainFullName
    Install-PullDP -ServerFQDN $DPFQDN -ServerSiteCode $PDP.ServerSiteCode -SourceDPFQDN $SourceDPFQDN -usePKI:$usePKI
}

# Force install DP/MP on PS Site Server if none present
$dpCount = (Get-CMDistributionPoint -SiteCode $SiteCode | Measure-Object).Count
$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count

if ($dpCount -eq 0) {
    Write-DscStatus "No DP's were found in this site. Forcing DP install on Site Server $ThisMachineName"
    Install-DP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode -usePKI:$usePKI
}

if ($mpCount -eq 0) {
    Write-DscStatus "No MP's were found in this site. Forcing MP install on Site Server $ThisMachineName"
    Install-MP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode -usePKI:$usePKI
}

# Mark completed
$Configuration.InstallDP.Status = 'Completed'
$Configuration.InstallDP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration.InstallMP.Status = 'Completed'
$Configuration.InstallMP.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
