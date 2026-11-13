# Fix-CMFullAdmin: ensure vmbuildadmin is a Full Administrator in the local
# ConfigMgr site so admin console + sqlcmd-via-CM provider both work.

$Fix_CMFullAdmin = {
    param(
        [ValidateRange(1, 6)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 600)][int]$RetrySeconds = 60
    )

    function Get-CmAdminDirectoryEvidence {
        param([string]$AccountName)
        $searcher = [ADSISearcher]"(&(objectCategory=person)(objectClass=user)(sAMAccountName=$AccountName))"
        try {
            $searcher.ClientTimeout = [timespan]::FromSeconds(10)
            $searcher.ServerTimeLimit = [timespan]::FromSeconds(10)
            $searcher.SizeLimit = 1
            $null = $searcher.PropertiesToLoad.Add('distinguishedname')
            $hit = $searcher.FindOne()
            return "DIAG AD resolves account '$AccountName': $([bool]$hit)$(if ($hit) { " ($($hit.Properties['distinguishedname'][0]))" })"
        }
        finally { $searcher.Dispose() }
    }

    $SiteCode = $null
    $identificationPath = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
    if (Test-Path -LiteralPath $identificationPath) {
        try {
            $identification = Get-ItemProperty -LiteralPath $identificationPath -ErrorAction Stop
            $siteCodeProperty = $identification.PSObject.Properties['Site Code']
            if ($siteCodeProperty) { $SiteCode = $siteCodeProperty.Value }
        }
        catch { throw "Could not read ConfigMgr site identification: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        return [pscustomobject]@{ Success = $true; Message = 'No site code; CM not installed or uninstalled - skipping' }
    }

    # Use DNS domain (USERDNSDOMAIN) instead of bare USERDOMAIN; SMS Provider needs FQDN.
    $dnsDomain = $env:USERDNSDOMAIN
    if ([string]::IsNullOrWhiteSpace($dnsDomain)) {
        return [pscustomobject]@{ Success = $false; Message = 'USERDNSDOMAIN is empty; cannot build SMS Provider FQDN' }
    }
    $ProviderMachineName = "$env:COMPUTERNAME.$dnsDomain"
    Write-FixLog "SiteCode=$SiteCode Provider=$ProviderMachineName"

    $consoleRegistry = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup'
    if (-not (Test-Path -LiteralPath $consoleRegistry)) {
        return [pscustomobject]@{ Success = $true; Message = 'CM admin console not installed - skipping' }
    }
    $uiInstallPath = (Get-ItemProperty -LiteralPath $consoleRegistry -ErrorAction Stop).'UI Installation Directory'
    if (-not $uiInstallPath) { throw 'ConfigMgr console registration has no UI Installation Directory' }
    $modulePath = Join-Path $uiInstallPath 'bin\ConfigurationManager.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "ConfigMgr module is missing: $modulePath" }

    $userName = "vmbuildadmin"
    $userDomain = $env:USERDOMAIN
    $domainUserName = "$userDomain\$userName"
    $errs = @()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-FixLog "SiteCode=$SiteCode Target=$domainUserName AuthenticatedIdentity=$identity Module=$modulePath"
    $exists = @()
    for ($i = 1; $i -le $MaximumAttempts; $i++) {
        $createdDrive = $false
        $pushed = $false
        try {
            try {
                $providers = @(Get-CimInstance -Namespace 'root\SMS' -ClassName SMS_ProviderLocation `
                    -OperationTimeoutSec 10 -ErrorAction Stop |
                    Where-Object { $_.SiteCode -ieq $SiteCode -and $_.ProviderForLocalSite -and $_.Machine })
                if ($providers.Count) { $ProviderMachineName = "$($providers[0].Machine)".Trim() }
                Write-FixLog "Attempt $i/$MaximumAttempts provider discovery: $(@($providers | Select-Object -First 5 SiteCode, Machine, ProviderForLocalSite) | ConvertTo-Json -Compress)"
            }
            catch { Write-FixLog "Provider discovery failed; trying $ProviderMachineName`: $($_.Exception.Message)" -Level Warning }
            if ($null -eq (Get-Module ConfigurationManager)) {
                Import-Module $modulePath -ErrorAction Stop | Out-Null
            }
            $drive = Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
            if (-not $drive) {
                $drive = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName -ErrorAction Stop
                $createdDrive = $true
            }
            if ($drive.Root -ine $ProviderMachineName) { throw "CMSite drive '$SiteCode' points to '$($drive.Root)', not '$ProviderMachineName'" }
            Push-Location "$($SiteCode):\" -ErrorAction Stop
            $pushed = $true

            $administrators = @(Get-CMAdministrativeUser -RoleName 'Full Administrator' -ErrorAction Stop)
            $exists = @($administrators | Where-Object { $_.LogonName -ieq $domainUserName })
            Write-FixLog "Attempt $i/${MaximumAttempts}: exact principal present=$([bool]$exists); observed administrators: $(@($administrators | Select-Object -First 10 -ExpandProperty LogonName) -join ', ')"
            if (-not $exists) {
                Write-FixLog "Attempt $i/${MaximumAttempts}: adding $domainUserName as Full Administrator"
                $null = New-CMAdministrativeUser -Name $domainUserName -RoleName 'Full Administrator' `
                    -SecurityScopeName 'All' -CollectionName 'All Systems', 'All Users and User Groups' -ErrorAction Stop
                $exists = @(Get-CMAdministrativeUser -RoleName 'Full Administrator' -ErrorAction Stop |
                    Where-Object { $_.LogonName -ieq $domainUserName })
            }
            if (-not $exists) { throw "SMS Provider did not return the exact principal '$domainUserName' after assignment" }
        }
        catch {
            $msg = "Full Administrator attempt $i/$MaximumAttempts failed: $($_.Exception.Message) [id=$($_.FullyQualifiedErrorId) hresult=$($_.Exception.HResult)]"
            Write-FixLog $msg -Level Warning
            $errs += $msg
        }
        finally {
            if ($pushed) { Pop-Location }
            if ($createdDrive) {
                try { Remove-PSDrive -Name $SiteCode -Force -ErrorAction Stop }
                catch { Write-FixLog "Could not remove the attempt-owned CMSite drive: $($_.Exception.Message)" -Level Warning }
            }
        }
        if ($exists) { break }
        if ($i -lt $MaximumAttempts) {
            Write-FixLog "Provider/account readiness will be retried in $RetrySeconds seconds." -Level Warning
            if ($RetrySeconds -gt 0) { Start-Sleep -Seconds $RetrySeconds }
        }
    }

    $attemptCount = [math]::Min($i, $MaximumAttempts)
    if ($exists) {
        [pscustomobject]@{
            Success = $true
            Message = "Full Administrator '$domainUserName' is present (verified after $attemptCount attempt(s))"
            Attempts = $attemptCount
            State = [pscustomobject]@{ SiteCode = $SiteCode; Provider = $ProviderMachineName; TargetAccount = $domainUserName; Identity = $identity }
        }
    }
    else {
        # Final-failure diagnostics: capture everything needed to tell "SMS Provider
        # not ready / can't resolve the account" from "account genuinely missing in
        # AD", straight from the build log -- without needing access to the box.
        # All best-effort; never throw here. Each line is BOTH written to the fix
        # transcript (Write-FixLog -> pulled by Get-VMFixTranscript) AND returned in
        # Errors[] (logged by the maintenance harness as "[Fix-CMFullAdmin] ERROR: ...").
        $diag = @()
        $diag += "DIAG Provider=$ProviderMachineName SiteCode=$SiteCode Account=$domainUserName (added as '$userName' in domain '$userDomain')"
        try {
            $drive = Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
            $diag += "DIAG CMSite PSDrive online: $([bool]$drive)"
        }
        catch { $diag += "DIAG CMSite PSDrive probe threw: $($_.Exception.Message)" }
        try {
            $current = @(Get-CMAdministrativeUser -ErrorAction SilentlyContinue |
                Select-Object -First 10 -ExpandProperty LogonName -ErrorAction SilentlyContinue)
            if ($current.Count -gt 0) {
                $diag += "DIAG SMS Provider answered; existing administrative users ($($current.Count)): $($current -join ', ')"
            }
            else {
                $diag += "DIAG Get-CMAdministrativeUser returned no users (SMS Provider may not be answering yet)"
            }
        }
        catch { $diag += "DIAG Get-CMAdministrativeUser threw: $($_.Exception.Message)" }
        try {
            $diag += Get-CmAdminDirectoryEvidence -AccountName $userName
        }
        catch { $diag += "DIAG AD lookup of '$userName' threw: $($_.Exception.Message)" }
        foreach ($d in $diag) { Write-FixLog $d -Level Warning }

        [pscustomobject]@{
            Success = $false
            Message = "Failed to verify '$domainUserName' as Full Administrator after $attemptCount attempts"
            Attempts = $attemptCount
            Errors  = @($errs + $diag)
        }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-CMFullAdmin"
    FixVersion        = "261016.0"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @("CASorStandalonePrimary")
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
    ScriptBlock       = $Fix_CMFullAdmin
    RunAsAccount      = $vmNote.adminName
}
