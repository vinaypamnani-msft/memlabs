# ConfigureCMProxy.ps1
# Apply ConfigMgr site-system proxy settings to any opted-in site systems.
# Extracted from the tail of InstallRoles.ps1 so it runs unconditionally
# from ScriptWorkflow (the SUP-skip early-returns inside InstallRoles.ps1
# meant this never executed for sites with no SUP).
#
# Idempotent: re-runs safely on retries. Gated by Configuration.ConfigureCMProxy
# status so it skips once completed.

param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$DomainFullName = $deployConfig.vmOptions.domainName

$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

if (-not $Configuration.ConfigureCMProxy) {
    $item = [PSCustomObject]@{
        Status    = 'NotStart'
        StartTime = ''
        EndTime   = ''
    }
    $Configuration | Add-Member -MemberType NoteProperty -Name "ConfigureCMProxy" -Value $item -Force
}

$Configuration.ConfigureCMProxy.Status = 'Running'
$Configuration.ConfigureCMProxy.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

try {
    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    $proxyClients = @($deployConfig.virtualMachines | Where-Object {
        $_.useProxy -eq $true -and $_.role -ne 'Proxy'
    })

    # If there's no Proxy VM or no opted-in clients in this snapshot of
    # deployConfig, don't mark Completed -- otherwise a deploy that ran
    # before the Proxy was hydrated into deployConfig (or before the user
    # toggled useProxy on a SiteSystem) latches Completed forever and the
    # next deploy that DOES have the Proxy never gets the proxy applied.
    # Leave Status='NotStart' so the ScriptWorkflow gate re-runs us.
    if (-not $proxyVm -or $proxyClients.Count -eq 0) {
        $proxyState = if ($proxyVm) { "Proxy=$($proxyVm.vmName)" } else { "Proxy=<none>" }
        Write-DscStatus "ConfigureCMProxy: nothing to do. $proxyState; opted-in clients=$($proxyClients.Count); total VMs in deployConfig=$(@($deployConfig.virtualMachines).Count)"
        $Configuration.ConfigureCMProxy.Status = 'NotStart'
    }
    else {
        # Connect to the CM site PS drive (sets $SiteCode and cd's into <SiteCode>:\)
        . $PSScriptRoot\Connect-CMSite.ps1 -Tag "[ConfigureCMProxy]"

        $proxyFqdn = "$($proxyVm.vmName).$DomainFullName"
        $proxyPort = 3128
        Write-DscStatus "Applying CM proxy ($proxyFqdn`:$proxyPort) to $($proxyClients.Count) opted-in VM(s)"

        $siteSystemRoles = @('CAS', 'Primary', 'Secondary', 'SiteSystem', 'PassiveSite', 'WSUS', 'SQLAO', 'FileServer')
        foreach ($cvm in $proxyClients) {
            if ($cvm.role -notin $siteSystemRoles -and -not ($cvm.installSUP -eq $true)) { continue }

            $fqdn = "$($cvm.vmName).$DomainFullName"
            $ss = Get-CMSiteSystemServer -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue
            if (-not $ss) {
                Write-DscStatus "$fqdn`: not a CM site system (yet); skipping proxy config"
                continue
            }

            try {
                Set-CMSiteSystemServer -SiteSystemServerName $fqdn -UseProxy $true `
                    -ProxyServerName $proxyFqdn -ProxyServerPort $proxyPort `
                    -ErrorAction Stop *>&1 | Out-File $global:StatusLog -Append
                Write-DscStatus "$fqdn`: site system proxy set -> $proxyFqdn`:$proxyPort"
            }
            catch {
                Write-DscStatus "$fqdn`: Set-CMSiteSystemServer -UseProxy failed: $_"
            }

            if ($cvm.installSUP -eq $true) {
                $sup = Get-CMSoftwareUpdatePoint -SiteSystemServerName $fqdn -ErrorAction SilentlyContinue
                if ($sup) {
                    try {
                        Set-CMSoftwareUpdatePoint -SiteSystemServerName $fqdn -UseProxy $true `
                            -ErrorAction Stop *>&1 | Out-File $global:StatusLog -Append
                        Write-DscStatus "$fqdn`: SUP UseProxy enabled"
                    }
                    catch {
                        Write-DscStatus "$fqdn`: Set-CMSoftwareUpdatePoint -UseProxy failed: $_"
                    }
                }
            }
        }

        $Configuration.ConfigureCMProxy.Status = 'Completed'
    }
}
catch {
    Write-DscStatus "ConfigureCMProxy failed: $_"
    $Configuration.ConfigureCMProxy.Status = 'Error'
}

$Configuration.ConfigureCMProxy.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
