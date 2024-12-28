#InstallDPMPClient.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName
$DomainName = $DomainFullName.Split(".")[0]
$NetbiosDomainName = $deployConfig.vmOptions.domainNetBiosName

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }

# bug fix to not deploy to other sites clients (also multi-network bug if we allow multi networks)
#$ClientNames = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not ($_.hidden -eq $true)} -and -not ($_.SqlVersion)).vmName -join ","

$usePKI = $deployConfig.cmOptions.UsePKI
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
$ValidSiteCodes = @($SiteCode)
$ReportingSiteCodes = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq $SiteCode } | Select-Object -Expand SiteCode
$ValidSiteCodes += $ReportingSiteCodes

foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" } ) {
    if ($vm.siteCode -in $ValidSiteCodes) {
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
    }
}

# Trim nulls/blanks
$DPNames = $DPs.ServerName | Where-Object { $_ -and $_.Trim() }
$PullDPNames = $PullDPs.ServerName | Where-Object { $_ -and $_.Trim() }
$MPNames = $MPs.ServerName | Where-Object { $_ -and $_.Trim() }

Write-DscStatus "MP role to be installed on '$($MPNames -join ',')'"
Write-DscStatus "DP role to be installed on '$($DPNames -join ',')'"
Write-DscStatus "Pull DP role to be installed on '$($PullDPNames -join ',')'"

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

