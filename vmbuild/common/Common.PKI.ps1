###############################################################################
# Common.PKI.ps1
#
# Host-driven PKI orchestrator. Handles both single-tier (Enterprise Root CA)
# and two-tier (Standalone Offline Root CA + Enterprise Subordinate CA)
# deployments on any domain-joined VM. Called after Phase2 completes when
# pkiOptions.EnablePKI is set and a VM has InstallCA = $true.
#
# Entry point: Install-PKI (dispatches to Install-SingleTierPKI or
# Install-TwoTierPKI based on UseOfflineRoot).
#
# IDEMPOTENT: Every step detects existing state and skips work already done.
# Safe to re-run after partial failure — will resume from where it left off.
#
# Uses PSDirect (Invoke-VmCommand / Copy-ItemSafe) for all VM communication.
###############################################################################

function Copy-ItemFromVM {
    <#
    .SYNOPSIS
        Copy a file FROM a guest VM to the host via PSDirect (Copy-Item -FromSession).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $VMDomainName
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $ps = Get-VmSession -VmName $VMName -VmDomainName $VMDomainName
    if (-not $ps) {
        Write-Log "[Copy-ItemFromVM] Failed to get session for $VMName" -Failure
        return $false
    }
    try {
        Copy-Item -FromSession $ps -Path $Path -Destination $Destination -Force -ErrorAction Stop
        Write-Log "[Copy-ItemFromVM] Copied $Path from $VMName to $Destination" -LogOnly
        return $true
    }
    catch {
        Write-Log "[Copy-ItemFromVM] Failed: $($_.Exception.Message)" -Failure
        return $false
    }
}

function Test-PKIStepResult {
    <#
    .SYNOPSIS
        Checks an Invoke-VmCommand result for success/failure, logs output, and returns $true/$false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Result,
        [Parameter(Mandatory)] [string] $StepName,
        [Parameter(Mandatory)] [string] $LogPrefix,
        [string] $LogSource = "CA",
        [switch] $LogOnly,
        [string] $Indent = ""
    )

    if ($Result.ScriptBlockFailed -or -not $Result.ScriptBlockOutput.Success) {
        $err = if ($Result.ScriptBlockFailed) { $Result.ScriptBlockFailed } else { $Result.ScriptBlockOutput.Error }
        Write-Log "${Indent}[$LogPrefix] $StepName FAILED: $err" -Failure
        if ($Result.ScriptBlockOutput.Log) {
            foreach ($line in $Result.ScriptBlockOutput.Log) { Write-Log "${Indent}  [$LogPrefix][$LogSource] $line" }
        }
        return $false
    }
    foreach ($line in $Result.ScriptBlockOutput.Log) {
        if ($LogOnly) { Write-Log "${Indent}  [$LogPrefix][$LogSource] $line" -LogOnly }
        else { Write-Log "${Indent}  [$LogPrefix][$LogSource] $line" }
    }
    return $true
}

function Install-PKIDnsAlias {
    <#
    .SYNOPSIS
        Creates a pki.<domain> DNS CNAME on the DC pointing to the CA VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DcVMName,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [string] $CAHostAlias
    )

    Write-Log "[PKI] Creating DNS alias pki.$DomainName -> $CAHostAlias (on DC $DcVMName)..." -LogOnly
    $null = Invoke-VmCommand -VmName $DcVMName -VmDomainName $DomainName -DisplayName "PKI: Create pki DNS alias" -SuppressLog `
        -ScriptBlock {
            param($ZoneName, $HostAlias)
            try {
                $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name "pki" -RRType CName -ErrorAction SilentlyContinue
                if (-not $existing) {
                    Add-DnsServerResourceRecordCName -ZoneName $ZoneName -Name "pki" -HostNameAlias $HostAlias | Out-Null
                }
            }
            catch {
                # Non-fatal — CRL distribution still works via direct hostname
                Write-Warning "DNS alias pki.$ZoneName creation failed: $($_.Exception.Message)"
            }
        } -ArgumentList $DomainName, $CAHostAlias
}

function Install-PKICertificateTemplates {
    <#
    .SYNOPSIS
        Imports and publishes certificate templates on the Issuing CA VM.
        Shared by both single-tier and two-tier paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CAVMName,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [object] $DeployConfig,
        [Parameter(Mandatory)] [string] $LogPrefix
    )

    # Determine which templates are needed
    $hasIISServers = @($DeployConfig.virtualMachines | Where-Object {
        ($_.role -in "CAS", "Primary", "Secondary", "PassiveSite") -or
        $_.InstallSUP -or $_.InstallMP -or $_.InstallDP -or $_.InstallRP
    }).Count -gt 0

    $templateList = @()
    if ($hasIISServers) {
        $templateList += 'ConfigMgrWebServerCertificate'
        $templateList += 'ConfigMgrClientDistributionPointCertificate'
    }
    $templateList += 'ConfigMgrClientCertificate'

    Write-Log "[$LogPrefix] Importing $($templateList.Count) certificate template(s) on $CAVMName..." -NoIndent
    $stepStart = Get-Date

    $templateScript = {
        param($DomainName, $TemplateListString)

        $TemplateList = $TemplateListString -split '\|'
        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        function Find-TemplateInAD([string]$cn) {
            try {
                $configCtx = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $searchBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configCtx"
                $ds = New-Object System.DirectoryServices.DirectorySearcher(
                    [ADSI]"LDAP://$searchBase", "(cn=$cn)")
                $ds.PropertiesToLoad.AddRange(@('cn','msPKI-Cert-Template-OID'))
                return $ds.FindOne()
            } catch { return $null }
        }

        function Reset-TemplateCache {
            foreach ($hive in @('HKLM','HKCU')) {
                $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
            }
            Restart-Service -Name CertSvc -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                try {
                    $null = & certutil.exe -ping 2>&1
                    if ($LASTEXITCODE -eq 0) { return }
                } catch {}
            }
        }

        try {
            $dnPath = 'DC=' + $DomainName.Replace('.', ',DC=')

            # Ensure ldifde.exe is available (only present by default on DCs;
            # member servers need RSAT-ADDS-Tools installed)
            if (-not (Get-Command ldifde.exe -ErrorAction SilentlyContinue)) {
                _Log "ldifde.exe not found - installing RSAT-ADDS-Tools..."
                $feat = Install-WindowsFeature RSAT-ADDS-Tools -ErrorAction Stop
                if ($feat.Success) {
                    _Log "  RSAT-ADDS-Tools installed successfully"
                } else {
                    throw "Failed to install RSAT-ADDS-Tools (needed for ldifde.exe)"
                }
            }

            # ---- Phase A: Import templates into AD via ldifde ----
            foreach ($tplName in $TemplateList) {
                $found = Find-TemplateInAD $tplName
                if ($found) {
                    _Log "Template '$tplName' already exists in AD - skipping import"
                    continue
                }

                $ldfSource = "C:\staging\DSC\CertificateTemplates\$tplName.ldf"
                if (-not (Test-Path $ldfSource)) {
                    _Log "FATAL: LDF file not found: $ldfSource"
                    return @{ Success = $false; Log = $report.ToArray(); Error = "LDF not found: $ldfSource" }
                }

                $ldfTarget = "C:\temp\$tplName.ldf"
                (Get-Content $ldfSource) -replace 'DC=TEMPLATE,DC=com', $dnPath |
                    Set-Content $ldfTarget -Force

                _Log "Importing template '$tplName' via ldifde..."
                $output = & ldifde.exe -i -k -f $ldfTarget 2>&1
                _Log "  ldifde exit code: $LASTEXITCODE"
                if ($output) { _Log "  ldifde output: $($output -join ' ')" }

                $verify = Find-TemplateInAD $tplName
                if (-not $verify) {
                    _Log "FATAL: Template '$tplName' NOT found in AD after ldifde import"
                    return @{ Success = $false; Log = $report.ToArray(); Error = "Template '$tplName' import failed (not in AD)" }
                }
                _Log "  Verified: '$tplName' exists in AD"
            }

            # ---- Phase B: Set ACLs and add templates to the CA ----
            Reset-TemplateCache
            $publishFailed = $false

            # ---- Phase B1: Set ACLs on templates ----
            $enrollGuid     = [Guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
            $autoEnrollGuid = [Guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
            $configCtx = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $tplBaseDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configCtx"

            $tplIndex = 0
            foreach ($tplName in $TemplateList) {
                $tplIndex++
                $groupName = switch ($tplName) {
                    'ConfigMgrWebServerCertificate'               { 'ConfigMgr IIS Servers' }
                    'ConfigMgrClientDistributionPointCertificate' { 'ConfigMgr IIS Servers' }
                    'ConfigMgrClientCertificate'                  { 'Domain Computers' }
                }
                $doAutoEnroll = ($tplName -eq 'ConfigMgrClientCertificate')

                _Log "[$tplIndex/$($TemplateList.Count)] Setting ACL on '$tplName' for '$groupName'..."
                $retries = 0
                $aclOk = $false
                while ($retries -lt 5 -and -not $aclOk) {
                    $retries++
                    try {
                        $ntAccount = New-Object System.Security.Principal.NTAccount($groupName)
                        $groupSid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])

                        $tplDN = "CN=$tplName,$tplBaseDN"
                        $tplEntry = [ADSI]"LDAP://$tplDN"
                        if (-not $tplEntry.distinguishedName) { throw "Template not found at $tplDN" }

                        $acl = $tplEntry.ObjectSecurity

                        $readRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                            $groupSid,
                            [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
                            [System.Security.AccessControl.AccessControlType]::Allow
                        )
                        $acl.AddAccessRule($readRule)

                        $enrollRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                            $groupSid,
                            [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                            [System.Security.AccessControl.AccessControlType]::Allow,
                            $enrollGuid
                        )
                        $acl.AddAccessRule($enrollRule)

                        if ($doAutoEnroll) {
                            $autoEnrollRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                                $groupSid,
                                [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
                                [System.Security.AccessControl.AccessControlType]::Allow,
                                $autoEnrollGuid
                            )
                            $acl.AddAccessRule($autoEnrollRule)
                        }

                        $tplEntry.ObjectSecurity = $acl
                        $tplEntry.CommitChanges()
                        $aclOk = $true
                        $perms = if ($doAutoEnroll) { 'Read, Enroll, AutoEnroll' } else { 'Read, Enroll' }
                        _Log "  ACL set successfully ($perms)"
                    } catch {
                        _Log "  ACL attempt $retries failed: $($_.Exception.Message)"
                        Start-Sleep -Seconds 2
                    }
                }
                if (-not $aclOk) {
                    _Log "FATAL: Failed to set ACL on '$tplName' after $retries attempts"
                    $publishFailed = $true
                }
            }

            if ($publishFailed) {
                _Log "Aborting: ACL phase failed"
                return @{ Success = $false; Log = $report.ToArray(); Error = "Template ACL failures (see log)" }
            }

            # ---- Phase B2: Issue Add-CATemplate for ALL templates ----
            _Log "Publishing all $($TemplateList.Count) template(s) to CA..."
            foreach ($tplName in $TemplateList) {
                try {
                    ADCSAdministration\Add-CATemplate -Name $tplName -Force -ErrorAction Stop
                    _Log "  Add-CATemplate '$tplName': ok"
                } catch {
                    _Log "  Add-CATemplate '$tplName' failed: $($_.Exception.Message) (will retry in verify loop)"
                }
            }

            # ---- Phase B3: Verify all templates published ----
            Reset-TemplateCache
            $remaining = [System.Collections.Generic.List[string]]::new($TemplateList)
            $maxVerifyRetries = 30
            $verifyAttempt = 0
            _Log "Verifying all templates are published (max $maxVerifyRetries attempts)..."

            while ($remaining.Count -gt 0 -and $verifyAttempt -lt $maxVerifyRetries) {
                $verifyAttempt++
                try {
                    $published = @(ADCSAdministration\Get-CATemplate -ErrorAction SilentlyContinue)
                } catch { $published = @() }

                $confirmed = @()
                foreach ($tplName in @($remaining)) {
                    if (@($published | Where-Object { $_.Name -eq $tplName }).Count -gt 0) {
                        _Log "  Template '$tplName' confirmed published (attempt $verifyAttempt)"
                        $confirmed += $tplName
                    }
                }
                foreach ($c in $confirmed) { [void]$remaining.Remove($c) }
                if ($remaining.Count -eq 0) { break }

                foreach ($tplName in $remaining) {
                    try {
                        ADCSAdministration\Add-CATemplate -Name $tplName -Force -ErrorAction SilentlyContinue
                    } catch {}
                }

                _Log "  $($remaining.Count) template(s) not yet visible; flushing cache (attempt $verifyAttempt/$maxVerifyRetries)..."
                Reset-TemplateCache
            }

            if ($remaining.Count -gt 0) {
                foreach ($tplName in $remaining) {
                    _Log "FATAL: Could not publish '$tplName' to CA after $maxVerifyRetries attempts"
                }
                $publishFailed = $true
            }

            # ---- Phase C: Final validation ----
            Reset-TemplateCache
            try { & certutil.exe -pulse 2>&1 | Out-Null } catch {}

            _Log "Validating CA template advertisements..."
            $caOut = & certutil.exe -catemplates 2>&1
            foreach ($tplName in $TemplateList) {
                if ($caOut -match [regex]::Escape($tplName)) {
                    _Log "  CA advertises '$tplName': OK"
                } else {
                    _Log "  CA does NOT advertise '$tplName': FAIL"
                    $publishFailed = $true
                }
            }

            if ($publishFailed) {
                _Log "Template publishing FAILED: one or more templates could not be published"
                return @{ Success = $false; Log = $report.ToArray(); Error = "Template publish/ACL failures (see log)" }
            }

            _Log "Certificate templates imported and published successfully."
            return @{ Success = $true; Log = $report.ToArray() }
        }
        catch {
            _Log "FAILED: $($_.Exception.Message)"
            return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
        }
    }

    Flush-LogBuffer -All
    $result = Invoke-VmCommand -VmName $CAVMName -VmDomainName $DomainName `
        -ScriptBlock $templateScript `
        -ArgumentList $DomainName, ($templateList -join '|') `
        -DisplayName "$LogPrefix`: Import certificate templates"

    if (-not (Test-PKIStepResult -Result $result -StepName "Certificate template import" -LogPrefix $LogPrefix -LogSource "CA")) {
        return $false
    }
    $elapsed = ((Get-Date) - $stepStart).TotalSeconds
    Write-Log "  [$LogPrefix] Certificate templates ready ($([int]$elapsed)s)"
    return $true
}

function Install-SingleTierPKI {
    <#
    .SYNOPSIS
        Installs a single-tier PKI (Enterprise Root CA) on a domain-joined VM.

    .DESCRIPTION
        This function runs after Phase2 completes. It:
          Step 1: Installs ADCS as Enterprise Root CA
          Step 2: Configures CDP/AIA, IIS CRL virtual directory
          Step 3: Creates pki.<domain> DNS CNAME on DC
          Step 4: Imports and publishes certificate templates

        IDEMPOTENT: Each step checks whether its work is already done and skips
        forward if so. Safe to re-run after partial failure.

    .PARAMETER DeployConfig
        The deployment configuration object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$DeployConfig
    )

    Write-Log "### [SingleTierPKI] Starting single-tier PKI deployment" -NoIndent

    # Resolve VMs
    $issuingCAVM = $DeployConfig.virtualMachines | Where-Object { $_.InstallCA } | Select-Object -First 1
    $dcVM = $DeployConfig.virtualMachines | Where-Object { $_.role -eq "DC" } | Select-Object -First 1

    if (-not $issuingCAVM) {
        Write-Log "[SingleTierPKI] ERROR: No VM with InstallCA flag found in config" -Failure
        return $false
    }
    if (-not $dcVM) {
        Write-Log "[SingleTierPKI] ERROR: No DC found in config" -Failure
        return $false
    }

    $caVMName = $issuingCAVM.vmName
    $dcVMName = $dcVM.vmName
    $domainName = $DeployConfig.vmOptions.domainName
    $domainShort = $domainName.Split(".")[0]
    $caName = "$domainShort-$caVMName-CA"
    $webURL = "http://pki.$domainName/crl/"
    $webFolderPath = "C:\inetpub\wwwroot\CRL\"

    Write-Log "[SingleTierPKI] CA VM: $caVMName | DC VM: $dcVMName"
    Write-Log "[SingleTierPKI] Domain: $domainName | CA Name: $caName"

    #---------------------------------------------------------------------------
    # STEP 1: Install Enterprise Root CA + configure CDP/AIA + IIS
    #---------------------------------------------------------------------------
    Write-Log "[SingleTierPKI] Step 1: Installing Enterprise Root CA on $caVMName..." -NoIndent

    $singleTierScript = {
        param($CAName, $DomainName, $WebURL, $WebFolderPath)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        function Wait-CertSvcReady {
            param([int]$TimeoutSec = 60)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        $null = & certutil.exe -ping 2>&1
                        if ($LASTEXITCODE -eq 0) { return $true }
                    }
                } catch {}
                Start-Sleep -Seconds 2
            }
            return $false
        }

        try {
            # Check if CA is already installed (idempotency)
            $caAlreadyInstalled = $false
            try {
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc) {
                    $caAlreadyInstalled = $true
                    _Log "CA service already exists (state: $($svc.Status)) - skipping installation"
                }
            } catch {}

            if (-not $caAlreadyInstalled) {
                # Write CAPolicy.inf
                _Log "Writing CAPolicy.inf..."
                $caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[certsrv_server]
RenewalKeyLength=2048
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=5
CRLPeriod=Weeks
CRLPeriodUnits=2
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=1
LoadDefaultTemplates=0
"@
                Set-Content -Path "C:\Windows\CAPolicy.inf" -Value $caPolicyContent -Force

                # Install ADCS role
                _Log "Installing ADCS role..."
                Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null

                # Install Enterprise Root CA
                _Log "Installing Enterprise Root CA '$CAName'..."
                Install-AdcsCertificationAuthority -CAType EnterpriseRootCa `
                    -CACommonName $CAName `
                    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                    -KeyLength 2048 `
                    -HashAlgorithmName SHA256 `
                    -ValidityPeriod Years `
                    -ValidityPeriodUnits 5 `
                    -Force | Out-Null

                _Log "Waiting for CA service to become ready..."
                if (-not (Wait-CertSvcReady -TimeoutSec 60)) {
                    throw "CA service did not become responsive within 60 seconds"
                }
                _Log "CA service is ready."
            }
            else {
                # Ensure service is running
                if ((Get-Service certsvc).Status -ne 'Running') {
                    Start-Service certsvc
                    if (-not (Wait-CertSvcReady -TimeoutSec 30)) {
                        throw "Could not start existing CA service"
                    }
                }
            }

            # Configure CDP/AIA
            _Log "Configuring CDP extensions..."
            # Remove default CDP entries and add HTTP-based
            $cdpBase = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$CAName\CRLDistributionPoint"
            if (Test-Path $cdpBase) {
                # Keep only ldap:/// and add HTTP CDP
                $httpCDP = "${WebURL}<CaName><CRLNameSuffix><DeltaCRLAllowed>.crl"
                & certutil.exe -setreg CA\CRLPublicationURLs "1:C:\Windows\system32\CertSrv\CertEnroll\%3%8%9.crl\n2:$httpCDP" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CDP returned exit code $LASTEXITCODE" }
            } else {
                _Log "WARNING: CDP registry path not found: $cdpBase"
            }

            _Log "Configuring AIA extensions..."
            $httpAIA = "${WebURL}<ServerDNSName>_<CaName><CertificateName>.crt"
            & certutil.exe -setreg CA\CACertPublicationURLs "1:C:\Windows\system32\CertSrv\CertEnroll\%1_%3%4.crt\n2:$httpAIA" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg AIA returned exit code $LASTEXITCODE" }

            # Set CRL periods (lab-appropriate: long CRL, no delta)
            _Log "Setting CRL periods..."
            $crlRegFailed = $false
            & certutil.exe -setreg CA\CRLPeriodUnits 22 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLPeriod "Weeks" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLOverlapPeriodUnits 12 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLOverlapPeriod "Hours" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLDeltaPeriodUnits 0 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLDeltaPeriod "Days" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\ValidityPeriodUnits 5 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg ValidityPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\ValidityPeriod "Years" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg ValidityPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            if ($crlRegFailed) { _Log "WARNING: One or more CRL registry settings failed - check CA config" }

            # Install IIS (idempotent)
            _Log "Installing IIS Web-Server..."
            Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
            Import-Module WebAdministration

            # Create CRL virtual directory
            _Log "Creating CRL virtual directory..."
            if (-not (Test-Path $WebFolderPath)) {
                New-Item -ItemType Directory -Path $WebFolderPath -Force | Out-Null
            }
            $existingVDir = Get-WebVirtualDirectory -Site "Default Web Site" -Name "CRL" -ErrorAction SilentlyContinue
            if (-not $existingVDir) {
                New-WebVirtualDirectory -Site "Default Web Site" -Name "CRL" -PhysicalPath $WebFolderPath | Out-Null
            }

            # Enable double-escaping
            _Log "Enabling double-escaping on CRL vdir..."
            Set-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\CRL" `
                -Filter "system.webServer/security/requestFiltering" `
                -Name "allowDoubleEscaping" -Value $true

            # Restart CA to apply CDP/AIA changes and publish CRL
            _Log "Restarting CertSvc and publishing CRL..."
            Restart-Service -Name CertSvc -Force
            if (-not (Wait-CertSvcReady -TimeoutSec 30)) {
                _Log "WARNING: CertSvc slow to restart"
            }
            & certutil.exe -crl 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -crl returned exit code $LASTEXITCODE" }
            _Log "CRL published."

            # Copy CRL and cert to web folder
            _Log "Copying CRL and CA cert to web folder..."
            $certEnrollPath = "C:\Windows\system32\CertSrv\CertEnroll"
            Get-ChildItem -Path $certEnrollPath -Filter "*.crl" | Copy-Item -Destination $WebFolderPath -Force
            Get-ChildItem -Path $certEnrollPath -Filter "*.crt" | Copy-Item -Destination $WebFolderPath -Force

            _Log "Single-tier CA installation and configuration complete."
            return @{ Success = $true; Log = $report.ToArray() }
        }
        catch {
            _Log "FAILED: $($_.Exception.Message)"
            return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
        }
    }

    Flush-LogBuffer -All
    $result = Invoke-VmCommand -VmName $caVMName -VmDomainName $domainName `
        -ScriptBlock $singleTierScript `
        -ArgumentList $caName, $domainName, $webURL, $webFolderPath `
        -DisplayName "SingleTierPKI: Install Enterprise Root CA"

    if (-not (Test-PKIStepResult -Result $result -StepName "CA installation" -LogPrefix "SingleTierPKI" -LogSource "CA" -LogOnly)) {
        return $false
    }
    Write-Log "[SingleTierPKI] Step 1 complete: Enterprise Root CA operational"

    #---------------------------------------------------------------------------
    # STEP 2: DNS alias
    #---------------------------------------------------------------------------
    Install-PKIDnsAlias -DcVMName $dcVMName -DomainName $domainName -CAHostAlias "$caVMName.$domainName"

    #---------------------------------------------------------------------------
    # STEP 3: Certificate templates
    #---------------------------------------------------------------------------
    $templateResult = Install-PKICertificateTemplates -CAVMName $caVMName -DomainName $domainName `
        -DeployConfig $DeployConfig -LogPrefix "SingleTierPKI"
    if (-not $templateResult) {
        return $false
    }

    Write-Log "### [SingleTierPKI] Single-tier PKI deployment complete!" -NoIndent
    return $true
}

function Install-PKI {
    <#
    .SYNOPSIS
        Unified PKI deployment entry point. Dispatches to single-tier or
        two-tier based on UseOfflineRoot.

    .PARAMETER DeployConfig
        The deployment configuration object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$DeployConfig
    )

    $caVM = $DeployConfig.virtualMachines | Where-Object { $_.InstallCA } | Select-Object -First 1
    if (-not $caVM) {
        Write-Log "[PKI] ERROR: No VM with InstallCA found" -Failure
        return $false
    }

    if ($caVM.UseOfflineRoot) {
        return Install-TwoTierPKI -DeployConfig $DeployConfig
    }
    else {
        return Install-SingleTierPKI -DeployConfig $DeployConfig
    }
}

function Install-TwoTierPKI {
    <#
    .SYNOPSIS
        Orchestrates a two-tier PKI deployment using an offline root CA and an
        enterprise subordinate CA on a domain-joined VM.

    .DESCRIPTION
        This function runs after Phase2 completes. It:
          Step 1: Configures the Standalone Root CA (installs ADCS, CDP/AIA, exports cert+CRL)
          Step 2: Prepares the Issuing CA VM (IIS, CRL vdir, publishes root to AD, installs Sub CA with -OutputCertRequestFile)
          DNS:    Creates pki.<domain> CNAME on DC pointing to the Issuing CA VM
          Step 3: Signs the CSR on the Root CA (Submit, Approve, Retrieve)
          Step 4: Verifies CA state and pre-conditions on Issuing CA
          Step 5: Installs the subordinate certificate
          Step 6: Activates the CA service
          Step 7: Configures CDP/AIA/CRL on the Issuing CA
          Step 8: Imports and publishes certificate templates (ldifde + native AD ACLs)
          Step 9: Shuts down the Root CA VM

        IDEMPOTENT: Each step checks whether its work is already done and skips
        forward if so. Safe to re-run after partial failure.

    .PARAMETER DeployConfig
        The deployment configuration object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$DeployConfig
    )

    Write-Log "### [TwoTierPKI] Starting two-tier PKI orchestration" -NoIndent

    # Resolve VMs
    $rootCAVM = $DeployConfig.virtualMachines | Where-Object { $_.role -eq "StandaloneRootCA" } | Select-Object -First 1
    $issuingCAVM = $DeployConfig.virtualMachines | Where-Object { $_.SubordinateCA } | Select-Object -First 1
    $dcVM = $DeployConfig.virtualMachines | Where-Object { $_.role -eq "DC" } | Select-Object -First 1

    if (-not $rootCAVM) {
        Write-Log "[TwoTierPKI] ERROR: No StandaloneRootCA VM found in config" -Failure
        return $false
    }
    if (-not $issuingCAVM) {
        Write-Log "[TwoTierPKI] ERROR: No VM with SubordinateCA flag found in config" -Failure
        return $false
    }
    if (-not $dcVM) {
        Write-Log "[TwoTierPKI] ERROR: No DC found in config" -Failure
        return $false
    }

    $rootCAVMName = $rootCAVM.vmName
    $issuingCAVMName = $issuingCAVM.vmName
    $dcVMName = $dcVM.vmName
    $domainName = $DeployConfig.vmOptions.domainName
    $domainShort = $domainName.Split(".")[0]
    $rootCAName = "CSSRoot-CA"
    $intCAName = "$domainShort-$issuingCAVMName-CA"
    $intCAServer = "$issuingCAVMName.$domainName"
    $webURL = "http://pki.$domainName/crl/"
    $webFolderPath = "C:\inetpub\wwwroot\CRL\"
    $rootCAFilesPath = "C:\temp\RootCAFiles\"
    $intCAFilesPath = "C:\temp\IntermediateCAFiles\"

    # Host staging folder for cert file exchange.
    # Wipe any leftovers from a previous (possibly failed) run so stale
    # certs from an old Root CA can never bleed into a fresh deployment.
    $hostStagingPath = Join-Path $env:TEMP "MemLabs_PKI_$($DeployConfig.vmOptions.domainName)"
    if (Test-Path $hostStagingPath) {
        Remove-Item -Path $hostStagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $hostStagingPath -Force | Out-Null

    Write-Log "[TwoTierPKI] Root CA VM: $rootCAVMName | Issuing CA VM: $issuingCAVMName | DC VM: $dcVMName"
    Write-Log "[TwoTierPKI] Domain: $domainName | Root CA Name: $rootCAName | Int CA Name: $intCAName"

    #---------------------------------------------------------------------------
    # STEP 1: Configure Root CA
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 1: Configuring Standalone Root CA on $rootCAVMName..." -NoIndent

    $step1Script = {
        param($RootCAName, $DomainName, $WebURL, $RootCAFilesPath)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        # Helper: wait for certsvc to become responsive after restart
        function Wait-CertSvcReady {
            param([int]$TimeoutSec = 60)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        # Verify CA is actually responding
                        $null = & certutil.exe -ping 2>&1
                        if ($LASTEXITCODE -eq 0) { return $true }
                    }
                } catch {}
                Start-Sleep -Seconds 2
            }
            return $false
        }

        try {
            # Check if CA is already installed (idempotency)
            $caAlreadyInstalled = $false
            try {
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc) {
                    $caAlreadyInstalled = $true
                    _Log "CA service already exists (state: $($svc.Status)) - skipping installation"
                }
            } catch {}

            if (-not $caAlreadyInstalled) {
                # Write CAPolicy.inf
                _Log "Writing CAPolicy.inf..."
                $caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[certsrv_server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=20
CRLPeriod=Years
CRLPeriodUnits=20
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0

[CRLDistributionPoint]
Empty=True

[AuthorityInformationAccess]
Empty=True
"@
                Set-Content -Path "C:\Windows\CAPolicy.inf" -Value $caPolicyContent -Force

                # Install ADCS role
                _Log "Installing ADCS role..."
                Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null

                # Install Standalone Root CA
                _Log "Installing Standalone Root CA '$RootCAName'..."
                Install-AdcsCertificationAuthority -CAType StandaloneRootCa `
                    -CACommonName $RootCAName `
                    -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                    -KeyLength 4096 `
                    -HashAlgorithmName SHA256 `
                    -ValidityPeriod Years `
                    -ValidityPeriodUnits 20 `
                    -Force | Out-Null

                _Log "Waiting for CA service to become ready..."
                if (-not (Wait-CertSvcReady -TimeoutSec 60)) {
                    throw "CA service did not become responsive within 60 seconds after installation"
                }
                _Log "CA service is ready."
            }
            else {
                # Ensure service is running AND responsive. After a VM reboot
                # certsvc may report 'Running' before its internal cert store
                # is fully initialized — certutil -ca.cert will fail in that
                # window. Always wait for ping regardless of reported status.
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc.Status -ne 'Running') {
                    _Log "Starting certsvc (was $($svc.Status))..."
                    Start-Service certsvc -ErrorAction Stop
                }
                _Log "Waiting for CA service to become fully responsive..."
                if (-not (Wait-CertSvcReady -TimeoutSec 90)) {
                    throw "CA service did not become responsive within 90 seconds"
                }
                _Log "CA service is ready."
            }

            # Configure CDP/AIA via native registry operations (no PSPKI needed)
            # The Root CA is a workgroup machine - PSPKI may not be installable
            # (no internet, or gallery issues). Registry writes are instant.
            $caConfigName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" -Name Active -ErrorAction Stop).Active
            $caRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caConfigName"
            _Log "CA registry path: $caRegPath"

            # Configure CDP (idempotent - remove http/file entries and add ours)
            # Root CA CDP: only include HTTP URL in issued certs (flags 6 = AddToCertCDP + AddToFreshest)
            _Log "Configuring CDP..."
            $currentCDP = @()
            try {
                $raw = (Get-ItemProperty $caRegPath -Name CRLPublicationURLs -ErrorAction Stop).CRLPublicationURLs
                if ($raw) { $currentCDP = @($raw) }
            } catch {}
            $filteredCDP = @($currentCDP | Where-Object { $_ -and $_ -notmatch 'http[s]?://' -and $_ -notmatch 'file://' })
            $httpCDP = "6:$($WebURL)$($RootCAName)%8%9.crl"
            $newCDP = $filteredCDP + @($httpCDP)
            Set-ItemProperty $caRegPath -Name CRLPublicationURLs -Value $newCDP
            _Log "  CDP: $($newCDP.Count) entries (added HTTP)"

            # Configure AIA (idempotent)
            # Root CA AIA: include HTTP URL in issued certs (flags 2 = AddToCertificateAia)
            _Log "Configuring AIA..."
            $currentAIA = @()
            try {
                $raw = (Get-ItemProperty $caRegPath -Name CACertPublicationURLs -ErrorAction Stop).CACertPublicationURLs
                if ($raw) { $currentAIA = @($raw) }
            } catch {}
            $filteredAIA = @($currentAIA | Where-Object { $_ -and $_ -notmatch 'http[s]?://' -and $_ -notmatch 'file://' })
            $httpAIA = "2:$($WebURL)$($RootCAName).crt"
            $newAIA = $filteredAIA + @($httpAIA)
            Set-ItemProperty $caRegPath -Name CACertPublicationURLs -Value $newAIA
            _Log "  AIA: $($newAIA.Count) entries (added HTTP)"

            # Set DSConfigDN (standalone CA needs this for AD-aware templates)
            _Log "Setting DSConfigDN..."
            $dnParts = $DomainName.Split(".")
            $configDN = "CN=Configuration," + (($dnParts | ForEach-Object { "DC=$_" }) -join ",")
            & certutil.exe -setreg CA\DSConfigDN $configDN | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CA\DSConfigDN returned exit code $LASTEXITCODE" }

            # Set CRL periods (20-year CRL so Root CA never needs to come back online)
            _Log "Setting CRL periods (20 years)..."
            $crlRegFailed = $false
            & certutil.exe -setreg CA\CRLPeriodUnits 20 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLPeriod "Years" | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLDeltaPeriodUnits 0 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLDeltaPeriod "Days" | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLOverlapPeriodUnits 4 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
            & certutil.exe -setreg CA\CRLOverlapPeriod "Weeks" | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
            if ($crlRegFailed) { _Log "WARNING: One or more CRL registry settings failed" }

            # Enable auditing
            _Log "Enabling audit..."
            & certutil.exe -setreg CA\AuditFilter 127 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg AuditFilter exit $LASTEXITCODE" }

            # Restart CA service and publish CRL
            _Log "Restarting certsvc and publishing CRL..."
            Restart-Service certsvc
            if (-not (Wait-CertSvcReady -TimeoutSec 60)) {
                throw "CA service did not become responsive after restart"
            }
            & certutil.exe -crl | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -crl returned exit code $LASTEXITCODE" }

            # Export Root CA cert and CRL
            _Log "Exporting Root CA cert and CRL..."
            if (-not (Test-Path $RootCAFilesPath)) {
                New-Item -ItemType Directory -Path $RootCAFilesPath -Force | Out-Null
            }

            # Export cert - try CertEnroll directory first (always populated by
            # Install-AdcsCertificationAuthority), then certutil -ca.cert as fallback
            $rootCertPath = Join-Path $RootCAFilesPath "$RootCAName.crt"
            $certEnrollDir = "C:\Windows\System32\CertSrv\CertEnroll\"
            $certEnrollCert = Get-ChildItem -Path $certEnrollDir -Filter "*.crt" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($certEnrollCert) {
                _Log "Copying CA cert from CertEnroll: $($certEnrollCert.Name)"
                Copy-Item -Path $certEnrollCert.FullName -Destination $rootCertPath -Force
            }
            else {
                _Log "No .crt in CertEnroll, trying certutil -ca.cert..."
                $certutilOutput = & certutil.exe -ca.cert $rootCertPath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    _Log "certutil -ca.cert output: $($certutilOutput | Out-String)"
                    throw "certutil -ca.cert failed with exit code $LASTEXITCODE. Output: $($certutilOutput | Out-String)"
                }
            }
            if (-not (Test-Path $rootCertPath)) { throw "Root CA certificate file not created: $rootCertPath" }

            # Export CRL (from CertEnroll - same dir as cert)
            $crlFiles = Get-ChildItem -Path $certEnrollDir -Filter "*.crl" -ErrorAction SilentlyContinue
            if (-not $crlFiles -or $crlFiles.Count -eq 0) {
                # CRL might not exist yet if this is a re-run after cert publish failed.
                # Force a CRL publish and retry.
                _Log "No CRL files found in $certEnrollDir - forcing CRL publish..."
                $crlOutput = & certutil.exe -crl 2>&1
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -crl failed: $($crlOutput | Out-String)" }
                Start-Sleep -Seconds 3
                $crlFiles = Get-ChildItem -Path $certEnrollDir -Filter "*.crl" -ErrorAction SilentlyContinue
            }
            if (-not $crlFiles -or $crlFiles.Count -eq 0) {
                _Log "WARNING: Still no CRL files found in $certEnrollDir after forced publish"
            }
            foreach ($f in $crlFiles) {
                Copy-Item -Path $f.FullName -Destination $RootCAFilesPath -Force
            }

            _Log "Step 1 complete. Files exported to $RootCAFilesPath"
            $exportedFiles = @(Get-ChildItem $RootCAFilesPath | Select-Object -ExpandProperty Name)
            _Log "Exported files: $($exportedFiles -join ', ')"

            if ($exportedFiles.Count -eq 0) {
                throw "No files were exported to $RootCAFilesPath - something went wrong"
            }

            return @{ Success = $true; Log = $report.ToArray(); ExportedFiles = $exportedFiles }
        }
        catch {
            _Log "FAILED: $($_.Exception.Message)"
            return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
        }
    }

    Flush-LogBuffer -All
    $result = Invoke-VmCommand -VmName $rootCAVMName -VmDomainName "WORKGROUP" `
        -ScriptBlock $step1Script `
        -ArgumentList $rootCAName, $domainName, $webURL, $rootCAFilesPath `
        -DisplayName "TwoTierPKI Step 1: Configure Root CA"

    if (-not (Test-PKIStepResult -Result $result -StepName "Step 1" -LogPrefix "TwoTierPKI" -LogSource "RootCA" -LogOnly)) {
        return $false
    }
    Write-Log "[TwoTierPKI] Step 1 complete: Root CA configured"

    #---------------------------------------------------------------------------
    # HOST COPY: Root CA files → host staging
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Copying Root CA files from $rootCAVMName to host staging..." -LogOnly

    $filesToCopy = $result.ScriptBlockOutput.ExportedFiles
    if (-not $filesToCopy -or $filesToCopy.Count -eq 0) {
        Write-Log "[TwoTierPKI] ERROR: No files to copy from Root CA" -Failure
        return $false
    }
    foreach ($fileName in $filesToCopy) {
        $srcPath = Join-Path $rootCAFilesPath $fileName
        $copyResult = Copy-ItemFromVM -Path $srcPath -Destination $hostStagingPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"
        if (-not $copyResult) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy '$fileName' from Root CA to host" -Failure
            return $false
        }
    }
    Write-Log "[TwoTierPKI] Root CA files copied to host: $hostStagingPath"

    #---------------------------------------------------------------------------
    # STEP 2: Prepare Intermediate CA
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 2: Preparing Intermediate CA on $issuingCAVMName..." -NoIndent

    # First, copy root CA files from host to Issuing CA VM
    # Ensure the destination directory exists on the remote VM before copying.
    # Copy-Item -ToSession fails with cryptic errors if the target dir is missing.
    $null = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName -DisplayName "Create RootCAFiles dir" -SuppressLog `
        -ScriptBlock { New-Item -ItemType Directory -Path "C:\temp\RootCAFiles" -Force | Out-Null }
    $copyFailed = $false
    foreach ($fileName in $filesToCopy) {
        $srcOnHost = Join-Path $hostStagingPath $fileName
        if (-not (Test-Path $srcOnHost)) {
            Write-Log "[TwoTierPKI] ERROR: Source file not found on host: $srcOnHost" -Failure
            $copyFailed = $true
            continue
        }
        $copyOk = Copy-ItemSafe -Path $srcOnHost -Destination "C:\temp\RootCAFiles\" -VMName $issuingCAVMName -VMDomainName $domainName
        if (-not $copyOk) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy '$fileName' to Issuing CA VM" -Failure
            $copyFailed = $true
        }
    }
    if ($copyFailed) {
        Write-Log "[TwoTierPKI] ERROR: One or more Root CA files failed to copy to Issuing CA VM" -Failure
        return $false
    }

    $step2Script = {
        param($IntCAName, $IntCAServer, $DomainName, $WebURL, $WebFolderPath, $RootCAName, $RootCAFilesPath, $IntCAFilesPath)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        try {
            # Check if Sub CA is already fully configured (has a valid cert installed)
            $subCAComplete = $false
            $subCAPartial = $false
            try {
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    # CA service running = fully configured (has cert installed)
                    $subCAComplete = $true
                    _Log "Subordinate CA already fully operational (certsvc running). Step 2 already done."
                }
                elseif ($svc) {
                    # Service exists but not running = partially installed (waiting for cert)
                    $subCAPartial = $true
                    _Log "Subordinate CA partially installed (certsvc exists but state=$($svc.Status)). CSR should already exist."
                }
            } catch {}

            if ($subCAComplete) {
                # Already done - just return the CSR path for downstream steps
                $reqFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.req"
                return @{ Success = $true; Log = $report.ToArray(); ReqFile = $reqFile; AlreadyComplete = $true }
            }

            # Install IIS (idempotent)
            _Log "Installing IIS Web-Server..."
            Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
            Import-Module WebAdministration

            # Create CRL virtual directory (idempotent)
            _Log "Creating CRL virtual directory..."
            if (-not (Test-Path $WebFolderPath)) {
                New-Item -ItemType Directory -Path $WebFolderPath -Force | Out-Null
            }
            $existingVDir = Get-WebVirtualDirectory -Site "Default Web Site" -Name "CRL" -ErrorAction SilentlyContinue
            if (-not $existingVDir) {
                New-WebVirtualDirectory -Site "Default Web Site" -Name "CRL" -PhysicalPath $WebFolderPath | Out-Null
            }

            # Enable double-escaping (idempotent)
            _Log "Enabling double-escaping on CRL vdir..."
            Set-WebConfigurationProperty -PSPath "IIS:\Sites\Default Web Site\CRL" `
                -Filter "system.webServer/security/requestFiltering" `
                -Name "allowDoubleEscaping" -Value $true

            # Copy Root CA files to web folder
            _Log "Copying Root CA files to web folder..."
            $rootFiles = Get-ChildItem -Path $RootCAFilesPath -ErrorAction SilentlyContinue
            foreach ($f in $rootFiles) {
                Copy-Item -Path $f.FullName -Destination $WebFolderPath -Force
            }

            # Publish root cert to AD (skip if already present by thumbprint)
            _Log "Publishing root cert to AD..."
            $rootCertFile = Join-Path $RootCAFilesPath "$RootCAName.crt"
            if (-not (Test-Path $rootCertFile)) {
                throw "Root CA certificate not found: $rootCertFile"
            }

            # Check if root CA cert is already in AD's Certification Authorities container
            $rootAlreadyPublished = $false
            try {
                $rootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rootCertFile)
                $rootThumbprint = $rootCert.Thumbprint
                $configCtxLocal = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $caContainer = "CN=Certification Authorities,CN=Public Key Services,CN=Services,$configCtxLocal"
                $searcher = New-Object System.DirectoryServices.DirectorySearcher(
                    [ADSI]"LDAP://$caContainer", "(objectClass=certificationAuthority)")
                $searcher.PropertiesToLoad.Add('cACertificate') | Out-Null
                $results = $searcher.FindAll()
                foreach ($entry in $results) {
                    foreach ($certBytes in $entry.Properties['cacertificate']) {
                        try {
                            $adCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[byte[]]$certBytes)
                            if ($adCert.Thumbprint -eq $rootThumbprint) {
                                $rootAlreadyPublished = $true
                                break
                            }
                        } catch {}
                    }
                    if ($rootAlreadyPublished) { break }
                }
            } catch {
                _Log "  Could not check AD for existing root cert: $($_.Exception.Message)"
            }

            if ($rootAlreadyPublished) {
                _Log "  Root CA cert already published to AD (thumbprint: $rootThumbprint) - skipping"
            } else {
                & certutil.exe -dspublish -f $rootCertFile RootCA | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -dspublish RootCA exit code $LASTEXITCODE" }
                & certutil.exe -dspublish -f $rootCertFile NTAuthCA | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -dspublish NTAuthCA exit code $LASTEXITCODE" }
                _Log "  Root CA cert published to AD"
            }

            # Publish root CRL to AD (idempotent with -f flag)
            _Log "Publishing root CRL to AD..."
            $crlFiles = Get-ChildItem -Path $RootCAFilesPath -Filter "*.crl" -ErrorAction SilentlyContinue
            foreach ($crl in $crlFiles) {
                & certutil.exe -dspublish -f $crl.FullName | Out-Null
            }

            # DNS alias pki.<domain> is created in a separate step that targets the DC.
            # (DnsServer cmdlets are only available on domain controllers.)

            # Write CAPolicy.inf for subordinate CA
            _Log "Writing CAPolicy.inf for subordinate CA..."
            $caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[PolicyStatementExtension]
Policies=InternalPolicy

[InternalPolicy]
OID=1.2.3.4.1455.67.89.5

[certsrv_server]
RenewalKeyLength=2048
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=5
CRLPeriod=Weeks
CRLPeriodUnits=2
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=1
LoadDefaultTemplates=0

[BasicConstraintsExtension]
PathLength=0
Critical=Yes
"@
            Set-Content -Path "C:\Windows\CAPolicy.inf" -Value $caPolicyContent -Force

            # Check if CSR already exists (from previous partial run)
            if (-not (Test-Path $IntCAFilesPath)) {
                New-Item -ItemType Directory -Path $IntCAFilesPath -Force | Out-Null
            }
            $reqFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.req"

            if ($subCAPartial -and (Test-Path $reqFile)) {
                _Log "CSR already exists from previous run: $reqFile - skipping CA installation"
            }
            else {
                # Install ADCS role (idempotent)
                _Log "Installing ADCS role..."
                Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null

                # Install Enterprise Subordinate CA with offline request file
                _Log "Installing Enterprise Subordinate CA '$IntCAName' (offline enrollment)..."
                try {
                    Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa `
                        -CACommonName $IntCAName `
                        -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                        -KeyLength 2048 `
                        -HashAlgorithmName SHA256 `
                        -OutputCertRequestFile $reqFile `
                        -Force | Out-Null
                }
                catch {
                    # If the error is "already installed", check for existing CSR
                    if ($_.Exception.Message -match 'already installed' -and (Test-Path $reqFile)) {
                        _Log "CA role already installed and CSR exists - continuing"
                    }
                    elseif ($_.Exception.Message -match 'already installed') {
                        # CA installed but no CSR - it may have been installed with cert already
                        # Check if certsvc exists (even if stopped = waiting for cert)
                        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                        if ($svc) {
                            _Log "CA already installed (no CSR file found). Generating new CSR via certreq..."
                            # Generate a new CSR from the existing key
                            $infContent = @"
[NewRequest]
Subject = "CN=$IntCAName"
KeyLength = 2048
Exportable = TRUE
UserProtected = FALSE
MachineKeySet = TRUE
ProviderName = "RSA#Microsoft Software Key Storage Provider"
HashAlgorithm = SHA256
RequestType = PKCS10
[RequestAttributes]
CertificateTemplate = SubCA
"@
                            $infFile = Join-Path $IntCAFilesPath "subreq.inf"
                            Set-Content -Path $infFile -Value $infContent -Force
                            & certreq.exe -new $infFile $reqFile | Out-Null
                            if (-not (Test-Path $reqFile)) {
                                throw "Failed to generate CSR. CA is partially installed but CSR could not be created."
                            }
                            _Log "CSR generated from existing installation: $reqFile"
                        }
                        else {
                            throw
                        }
                    }
                    else {
                        throw
                    }
                }

                if (-not (Test-Path $reqFile)) {
                    throw "CSR file was not created: $reqFile"
                }
                _Log "CSR generated: $reqFile"
            }

            _Log "Step 2 complete."
            return @{ Success = $true; Log = $report.ToArray(); ReqFile = $reqFile }
        }
        catch {
            _Log "FAILED: $($_.Exception.Message)"
            return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
        }
    }

    Flush-LogBuffer -All
    $result2 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
        -ScriptBlock $step2Script `
        -ArgumentList $intCAName, $intCAServer, $domainName, $webURL, $webFolderPath, $rootCAName, $rootCAFilesPath, $intCAFilesPath `
        -DisplayName "TwoTierPKI Step 2: Prepare Intermediate CA"

    if (-not (Test-PKIStepResult -Result $result2 -StepName "Step 2" -LogPrefix "TwoTierPKI" -LogSource "CA" -LogOnly)) {
        return $false
    }

    # Create DNS alias pki.<domain> pointing to the Issuing CA VM.
    Install-PKIDnsAlias -DcVMName $dcVMName -DomainName $domainName -CAHostAlias "$issuingCAVMName.$domainName"

    # If Sub CA is already fully complete (cert installed, service running), skip Steps 3-4
    if ($result2.ScriptBlockOutput.AlreadyComplete) {
        Write-Log "[TwoTierPKI] Step 2: Subordinate CA already operational - skipping Steps 3-7"
    }
    else {
        Write-Log "[TwoTierPKI] Step 2 complete: Intermediate CA prepared, CSR generated"

        #---------------------------------------------------------------------------
        # HOST COPY: CSR from Issuing CA → host → Root CA
        #---------------------------------------------------------------------------
        $reqFileName = [System.IO.Path]::GetFileName($result2.ScriptBlockOutput.ReqFile)
        if ([string]::IsNullOrWhiteSpace($reqFileName)) {
            Write-Log "[TwoTierPKI] ERROR: Step 2 did not return a valid CSR file path" -Failure
            return $false
        }
        Write-Log "[TwoTierPKI] Copying CSR '$reqFileName' from Issuing CA to Root CA via host..." -LogOnly

        # Issuing CA → host
        $copyResult = Copy-ItemFromVM -Path $result2.ScriptBlockOutput.ReqFile -Destination $hostStagingPath -VMName $issuingCAVMName -VMDomainName $domainName
        if (-not $copyResult) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy CSR from Issuing CA to host" -Failure
            return $false
        }
        # host → Root CA
        $reqOnHost = Join-Path $hostStagingPath $reqFileName
        if (-not (Test-Path $reqOnHost)) {
            Write-Log "[TwoTierPKI] ERROR: CSR file not found on host at $reqOnHost" -Failure
            return $false
        }
        $null = Invoke-VmCommand -VmName $rootCAVMName -VmDomainName "WORKGROUP" -DisplayName "Create IntermediateCAFiles dir" -SuppressLog `
            -ScriptBlock { New-Item -ItemType Directory -Path "C:\temp\IntermediateCAFiles" -Force | Out-Null }
        $copyOk = Copy-ItemSafe -Path $reqOnHost -Destination $intCAFilesPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"
        if (-not $copyOk) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy CSR to Root CA" -Failure
            return $false
        }

        #---------------------------------------------------------------------------
        # STEP 3: Sign CSR on Root CA
        #---------------------------------------------------------------------------
        Write-Log "[TwoTierPKI] Step 3: Signing CSR on Root CA..." -NoIndent

        $step3Script = {
            param($IntCAFilesPath, $IntCAServer, $IntCAName, $RootCAName)

            $ErrorActionPreference = 'Stop'
            $report = [System.Collections.Generic.List[string]]::new()
            function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

            try {
                $reqFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.req"
                $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"

                # Idempotency: if the cert file already exists, skip signing
                if (Test-Path $cerFile) {
                    $fileSize = (Get-Item $cerFile).Length
                    if ($fileSize -gt 0) {
                        _Log "Certificate file already exists ($fileSize bytes): $cerFile - skipping signing"
                        return @{ Success = $true; Log = $report.ToArray(); CerFile = $cerFile }
                    }
                    else {
                        _Log "Certificate file exists but is empty - removing and re-signing"
                        Remove-Item $cerFile -Force
                    }
                }

                if (-not (Test-Path $reqFile)) {
                    throw "CSR file not found: $reqFile"
                }

                # Build explicit CA config string. -config - in certreq shows
                # an interactive CA picker dialog which fails in PSDirect.
                # Detect from registry (most reliable) or fall back to param.
                $caConfigName = $null
                try {
                    $caConfigName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" -Name Active -ErrorAction Stop).Active
                } catch {}
                if (-not $caConfigName) { $caConfigName = $RootCAName }
                $caConfig = "$env:COMPUTERNAME\$caConfigName"
                _Log "Using CA config: $caConfig"

                # Ensure CA service is running and responsive
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Running') {
                    _Log "Starting certsvc..."
                    Start-Service certsvc -ErrorAction Stop
                }
                # Wait for CA to respond to certutil -ping (same pattern as Step 1)
                _Log "Waiting for CA to become responsive..."
                $deadline = (Get-Date).AddSeconds(90)
                $ready = $false
                while ((Get-Date) -lt $deadline) {
                    $pingOut = & certutil.exe -ping 2>&1
                    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
                    Start-Sleep -Seconds 3
                }
                if (-not $ready) { throw "CA service did not become responsive within 90 seconds" }
                _Log "CA is responsive."

                # Use ICertRequest COM object to submit the CSR. This is the
                # only approach that is:
                #  - Fully non-interactive (no UI dialogs ever)
                #  - Available on ALL Windows Server versions with ADCS
                #  - Independent of certutil/certreq verb availability
                _Log "Submitting certificate request via ICertRequest COM: $reqFile"

                # Read the request file content
                $reqContent = Get-Content -Path $reqFile -Raw

                # Submit via COM
                $CR_IN_BASE64HEADER = 0x0  # PKCS10 with ----BEGIN headers
                $CR_IN_FORMATANY    = 0x0
                $CR_DISP_ISSUED     = 3
                $CR_DISP_UNDER_SUBMISSION = 5

                $certRequest = New-Object -ComObject CertificateAuthority.Request
                _Log "Calling ICertRequest::Submit to $caConfig..."
                $disposition = $certRequest.Submit(
                    $CR_IN_BASE64HEADER,   # encoding flags
                    $reqContent,            # request blob
                    "",                     # attributes (empty for standalone CA)
                    $caConfig               # CA config string
                )
                $requestID = $certRequest.GetRequestId()
                _Log "Submit returned disposition=$disposition, RequestId=$requestID"

                if ($disposition -eq $CR_DISP_UNDER_SUBMISSION) {
                    # Standalone CA puts requests in "pending" state by default.
                    # Approve via ICertAdmin COM.
                    _Log "Request is pending (disposition=5). Approving via ICertAdmin..."
                    $certAdmin = New-Object -ComObject CertificateAuthority.Admin
                    $newDisp = $certAdmin.ResubmitRequest($caConfig, $requestID)
                    _Log "ICertAdmin::ResubmitRequest returned disposition=$newDisp"

                    if ($newDisp -ne $CR_DISP_ISSUED) {
                        throw "ResubmitRequest returned unexpected disposition $newDisp (expected $CR_DISP_ISSUED=Issued)"
                    }

                    # The original $certRequest object still has stale
                    # "pending" state. Must call RetrievePending to refresh
                    # its internal cert buffer before GetCertificate works.
                    _Log "Calling ICertRequest::RetrievePending to refresh state..."
                    $disposition = $certRequest.RetrievePending($requestID, $caConfig)
                    _Log "RetrievePending returned disposition=$disposition"
                }

                if ($disposition -eq $CR_DISP_ISSUED) {
                    # Retrieve the issued certificate
                    _Log "Certificate issued. Retrieving..."
                    $CR_OUT_BASE64HEADER = 0x0  # Base64 with headers
                    $certBase64 = $certRequest.GetCertificate($CR_OUT_BASE64HEADER)
                    Set-Content -Path $cerFile -Value $certBase64 -Force -NoNewline
                    _Log "Certificate written to $cerFile"
                }
                else {
                    # Unexpected disposition
                    $dispMsg = $certRequest.GetDispositionMessage()
                    throw "Certificate request failed. Disposition=$disposition, Message: $dispMsg"
                }

                if (Test-Path $cerFile) {
                    $fileSize = (Get-Item $cerFile).Length
                    if ($fileSize -eq 0) {
                        throw "Certificate file created but is empty (0 bytes): $cerFile"
                    }
                    _Log "Certificate retrieved ($fileSize bytes): $cerFile"
                }
                else {
                    throw "Certificate file not found after retrieval: $cerFile"
                }

                _Log "Step 3 complete."
                return @{ Success = $true; Log = $report.ToArray(); CerFile = $cerFile }
            }
            catch {
                _Log "FAILED: $($_.Exception.Message)"
                return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
            }
        }

        Flush-LogBuffer -All
        $result3 = Invoke-VmCommand -VmName $rootCAVMName -VmDomainName "WORKGROUP" `
            -ScriptBlock $step3Script `
            -ArgumentList $intCAFilesPath, $intCAServer, $intCAName, $rootCAName `
            -DisplayName "TwoTierPKI Step 3: Sign CSR on Root CA"

        if (-not (Test-PKIStepResult -Result $result3 -StepName "Step 3" -LogPrefix "TwoTierPKI" -LogSource "RootCA" -LogOnly)) {
            return $false
        }
        Write-Log "[TwoTierPKI] Step 3 complete: CSR signed"

        #---------------------------------------------------------------------------
        # HOST COPY: Signed cert from Root CA → host → DC
        #---------------------------------------------------------------------------
        $cerFileName = [System.IO.Path]::GetFileName($result3.ScriptBlockOutput.CerFile)
        Write-Log "[TwoTierPKI] Copying signed cert '$cerFileName' from Root CA to DC via host..." -LogOnly

        # Root CA → host
        $copyResult = Copy-ItemFromVM -Path $result3.ScriptBlockOutput.CerFile -Destination $hostStagingPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"
        if (-not $copyResult) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy signed cert from Root CA to host" -Failure
            return $false
        }
        # host → Issuing CA VM
        $cerOnHost = Join-Path $hostStagingPath $cerFileName
        if (-not (Test-Path $cerOnHost)) {
            Write-Log "[TwoTierPKI] ERROR: Signed cert not found on host at $cerOnHost" -Failure
            return $false
        }
        $null = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName -DisplayName "Create IntermediateCAFiles dir" -SuppressLog `
            -ScriptBlock { New-Item -ItemType Directory -Path "C:\temp\IntermediateCAFiles" -Force | Out-Null }
        $copyOk = Copy-ItemSafe -Path $cerOnHost -Destination $intCAFilesPath -VMName $issuingCAVMName -VMDomainName $domainName
        if (-not $copyOk) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy signed cert to Issuing CA VM" -Failure
            return $false
        }

        #---------------------------------------------------------------------------
        # STEPS 4-7: Complete Intermediate CA
        #   4: Verify pre-conditions (cert file exists, CA state)
        #   5: Install subordinate certificate
        #   6: Activate CA service
        #   7: Configure CDP/AIA/CRL
        #---------------------------------------------------------------------------
        $step4to7Start = Get-Date

        # --- Step 4: Verify CA state ---
        Write-Log "[TwoTierPKI] Step 4: Verifying CA state on $issuingCAVMName..." -NoIndent
        Flush-LogBuffer -All

        $step4Script = {
            param($IntCAName, $IntCAFilesPath, $IntCAServer)

            $ErrorActionPreference = 'Stop'
            $report = [System.Collections.Generic.List[string]]::new()
            function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

            try {
                $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"
                _Log "Expected cert path: $cerFile"

                # Check if CA is already fully operational
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    _Log "certsvc is Running - checking responsiveness..."
                    $null = & certutil.exe -ping 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        _Log "CA operational (ping OK) - no install needed"
                        return @{ Success = $true; Log = $report.ToArray(); State = 'Operational' }
                    } else {
                        _Log "certsvc Running but ping failed (exit $LASTEXITCODE)"
                    }
                    return @{ Success = $true; Log = $report.ToArray(); State = 'RunningButNotReady' }
                } elseif ($svc) {
                    _Log "certsvc exists, state=$($svc.Status) - needs cert install"
                } else {
                    _Log "certsvc not found - ADCS not installed?"
                    return @{ Success = $false; Log = $report.ToArray(); Error = "certsvc service not found. ADCS may not be installed." }
                }

                # Verify cert file
                if (-not (Test-Path $cerFile)) {
                    _Log "FATAL: cert file not found: $cerFile"
                    return @{ Success = $false; Log = $report.ToArray(); Error = "Signed certificate not found: $cerFile" }
                }
                $fileSize = (Get-Item $cerFile).Length
                _Log "Cert file exists ($fileSize bytes)"

                # Validate it's parseable
                try {
                    $testCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerFile)
                    _Log "  Subject: $($testCert.Subject)"
                    _Log "  Issuer: $($testCert.Issuer)"
                    _Log "  Thumbprint: $($testCert.Thumbprint)"
                    _Log "  Valid: $($testCert.NotBefore) to $($testCert.NotAfter)"
                } catch {
                    return @{ Success = $false; Log = $report.ToArray(); Error = "Cert file invalid: $($_.Exception.Message)" }
                }

                return @{ Success = $true; Log = $report.ToArray(); State = 'NeedsInstall'; CerFile = $cerFile }
            }
            catch {
                _Log "FAILED: $($_.Exception.Message)"
                return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
            }
        }

        $result7 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
            -ScriptBlock $step4Script `
            -ArgumentList $intCAName, $intCAFilesPath, $intCAServer `
            -DisplayName "TwoTierPKI Step 4: Verify CA state"

        if (-not (Test-PKIStepResult -Result $result7 -StepName "Step 4" -LogPrefix "TwoTierPKI" -LogSource "CA" -Indent "  ")) {
            return $false
        }

        $caState = $result7.ScriptBlockOutput.State
        Write-Log "  [TwoTierPKI] Step 4: CA state = $caState"

        if ($caState -eq 'Operational') {
            Write-Log "  [TwoTierPKI] CA already operational - skipping Steps 5-6"
        }
        else {
            # --- Step 5: Install subordinate certificate ---
            Write-Log "[TwoTierPKI] Step 5: Installing subordinate certificate on $issuingCAVMName..."
            Flush-LogBuffer -All

            $step5Script = {
                param($IntCAName, $IntCAFilesPath, $IntCAServer, $RootCAFilesPath)

                $ErrorActionPreference = 'Stop'
                $report = [System.Collections.Generic.List[string]]::new()
                function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

                try {
                    $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"
                    _Log "Installing certificate: $cerFile"

                    # Ensure root CA cert is in local Trusted Root store (certutil -installcert
                    # validates the chain and can hang doing revocation checks if the root
                    # is only published to AD and GP hasn't refreshed yet)
                    $rootCerts = Get-ChildItem -Path $RootCAFilesPath -Filter "*.crt" -ErrorAction SilentlyContinue
                    if (-not $rootCerts) {
                        $rootCerts = Get-ChildItem -Path $RootCAFilesPath -Filter "*.cer" -ErrorAction SilentlyContinue
                    }
                    foreach ($rc in $rootCerts) {
                        _Log "Adding Root CA cert to local Trusted Root store: $($rc.Name)"
                        $null = & certutil.exe -addstore Root $rc.FullName 2>&1
                        _Log "  certutil -addstore Root: exit $LASTEXITCODE"
                    }

                    # Also import Root CRLs so chain validation doesn't try to fetch online
                    $rootCrls = Get-ChildItem -Path $RootCAFilesPath -Filter "*.crl" -ErrorAction SilentlyContinue
                    foreach ($crl in $rootCrls) {
                        _Log "Adding Root CRL to local store: $($crl.Name)"
                        $null = & certutil.exe -addstore Root $crl.FullName 2>&1
                    }

                    $installOutput = & certutil.exe -installcert -f $cerFile 2>&1
                    _Log "certutil -installcert exit code: $LASTEXITCODE"
                    if ($installOutput) { _Log "Output: $($installOutput | Out-String)" }

                    if ($LASTEXITCODE -ne 0) {
                        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                        if ($svc) {
                            _Log "certsvc exists despite error - cert may already be installed"
                        } else {
                            throw "certutil -installcert failed (exit $LASTEXITCODE)"
                        }
                    }

                    # Verify the cert was installed by checking certsvc can be queried
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    _Log "certsvc state after install: $($svc.Status)"

                    return @{ Success = $true; Log = $report.ToArray() }
                }
                catch {
                    _Log "FAILED: $($_.Exception.Message)"
                    return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
                }
            }

            $result5 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
                -ScriptBlock $step5Script `
                -ArgumentList $intCAName, $intCAFilesPath, $intCAServer, $rootCAFilesPath `
                -DisplayName "TwoTierPKI Step 5: Install subordinate certificate"

            if (-not (Test-PKIStepResult -Result $result5 -StepName "Step 5" -LogPrefix "TwoTierPKI" -LogSource "CA" -Indent "  ")) {
                return $false
            }
            Write-Log "  [TwoTierPKI] Step 5 complete: Certificate installed"

            # --- Step 6: Activate CA service ---
            Write-Log "[TwoTierPKI] Step 6: Starting certsvc and waiting for CA readiness..."
            Flush-LogBuffer -All

            $step6Script = {
                $ErrorActionPreference = 'Stop'
                $report = [System.Collections.Generic.List[string]]::new()
                function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

                try {
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    if (-not $svc) { throw "certsvc service not found" }
                    _Log "certsvc current state: $($svc.Status)"

                    if ($svc.Status -ne 'Running') {
                        _Log "Starting certsvc..."
                        try {
                            Start-Service certsvc -ErrorAction Stop
                            _Log "Start-Service succeeded"
                        } catch {
                            _Log "Start-Service failed: $($_.Exception.Message) - trying Restart..."
                            Restart-Service certsvc -Force -ErrorAction Stop
                            _Log "Restart-Service succeeded"
                        }
                    } else {
                        _Log "certsvc already running"
                    }

                    # Wait for CA to become responsive (certutil -ping confirms
                    # the ICertRequest2 RPC interface is alive).
                    # We intentionally do NOT call certutil -ca.cert here because
                    # it performs chain/revocation validation which can hang when
                    # the Root CA's CDP is not yet reachable.
                    _Log "Waiting for CA responsiveness (certutil -ping)..."
                    $deadline = (Get-Date).AddSeconds(60)
                    $attempts = 0
                    while ((Get-Date) -lt $deadline) {
                        $attempts++
                        try {
                            $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                            if ($svc -and $svc.Status -eq 'Running') {
                                $null = & certutil.exe -ping 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    _Log "  Attempt ${attempts}: ping OK - CA is responsive"
                                    return @{ Success = $true; Log = $report.ToArray() }
                                } else {
                                    if ($attempts % 5 -eq 0) {
                                        _Log "  Attempt ${attempts}: ping failed (exit ${LASTEXITCODE})"
                                    }
                                }
                            } else {
                                if ($attempts % 5 -eq 0) {
                                    $st = if ($svc) { $svc.Status } else { 'NotFound' }
                                    _Log "  Attempt ${attempts}: certsvc=$st"
                                }
                            }
                        } catch {}
                        Start-Sleep -Seconds 2
                    }

                    # Timeout - collect diagnostics
                    $svcState = (Get-Service certsvc -ErrorAction SilentlyContinue).Status
                    $pingOut = & certutil.exe -ping 2>&1
                    _Log "TIMEOUT after $attempts attempts. certsvc=$svcState, ping exit=$LASTEXITCODE"
                    _Log "  Ping output: $($pingOut | Out-String)"
                    throw "CA did not become responsive within 60s ($attempts attempts)"
                }
                catch {
                    _Log "FAILED: $($_.Exception.Message)"
                    return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
                }
            }

            $result6 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
                -ScriptBlock $step6Script `
                -DisplayName "TwoTierPKI Step 6: Activate CA service"

            if (-not (Test-PKIStepResult -Result $result6 -StepName "Step 6" -LogPrefix "TwoTierPKI" -LogSource "CA" -Indent "  ")) {
                return $false
            }
            Write-Log "  [TwoTierPKI] Step 6 complete: CA service is fully operational"
        }

        $step456Elapsed = ((Get-Date) - $step4to7Start).TotalSeconds
        Write-Log "  [TwoTierPKI] Steps 4-6 complete ($([int]$step456Elapsed)s)"

        # --- Step 7: Configure CDP/AIA/CRL ---
        Write-Log "[TwoTierPKI] Step 7: Configuring CDP, AIA, CRL periods..."
        Flush-LogBuffer -All

        $step7Script = {
            param($IntCAName, $DomainName, $WebURL, $WebFolderPath)

            $ErrorActionPreference = 'Stop'
            $report = [System.Collections.Generic.List[string]]::new()
            function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

            function Wait-CertSvcReady {
                param([int]$TimeoutSec = 60)
                $deadline = (Get-Date).AddSeconds($TimeoutSec)
                while ((Get-Date) -lt $deadline) {
                    try {
                        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                        if ($svc -and $svc.Status -eq 'Running') {
                            $null = & certutil.exe -ping 2>&1
                            if ($LASTEXITCODE -eq 0) { return $true }
                        }
                    } catch {}
                    Start-Sleep -Seconds 2
                }
                return $false
            }

            try {
                # Resolve the active CA config name from registry
                $caConfigName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration" -Name Active -ErrorAction Stop).Active
                $caRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caConfigName"
                _Log "CA registry path: $caRegPath (active config: $caConfigName)"

                # Configure CRL Distribution Points (CDP)
                _Log "Configuring CDP (CRLPublicationURLs)..."
                $currentCDP = @()
                try {
                    $raw = (Get-ItemProperty $caRegPath -Name CRLPublicationURLs -ErrorAction Stop).CRLPublicationURLs
                    if ($raw) { $currentCDP = @($raw) }
                } catch {}
                _Log "  Current CDP entries: $($currentCDP.Count)"
                foreach ($e in $currentCDP) { _Log "    $e" }

                $filteredCDP = @($currentCDP | Where-Object { $_ -and $_ -notmatch 'http[s]?://' -and $_ -notmatch 'file://' })
                $fileEntry = "65:file://$($WebFolderPath)$($IntCAName)%8%9.crl"
                $httpEntry = "6:$($WebURL)$($IntCAName)%8%9.crl"
                $newCDP = $filteredCDP + @($fileEntry, $httpEntry)
                Set-ItemProperty $caRegPath -Name CRLPublicationURLs -Value $newCDP
                _Log "  New CDP entries: $($newCDP.Count)"
                foreach ($e in $newCDP) { _Log "    $e" }

                # Configure Authority Information Access (AIA)
                _Log "Configuring AIA (CACertPublicationURLs)..."
                $currentAIA = @()
                try {
                    $raw = (Get-ItemProperty $caRegPath -Name CACertPublicationURLs -ErrorAction Stop).CACertPublicationURLs
                    if ($raw) { $currentAIA = @($raw) }
                } catch {}
                _Log "  Current AIA entries: $($currentAIA.Count)"
                foreach ($e in $currentAIA) { _Log "    $e" }

                $filteredAIA = @($currentAIA | Where-Object { $_ -and $_ -notmatch 'http[s]?://' -and $_ -notmatch 'file://' })
                $httpAIA = "2:$($WebURL)$($IntCAName).crt"
                $newAIA = $filteredAIA + @($httpAIA)
                Set-ItemProperty $caRegPath -Name CACertPublicationURLs -Value $newAIA
                _Log "  New AIA entries: $($newAIA.Count)"
                foreach ($e in $newAIA) { _Log "    $e" }

                # Set CRL periods
                _Log "Setting CRL periods..."
                $crlRegFailed = $false
                & certutil.exe -setreg CA\CRLPeriodUnits 2 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\CRLPeriod "Weeks" | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\CRLDeltaPeriodUnits 1 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\CRLDeltaPeriod "Days" | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLDeltaPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\CRLOverlapPeriodUnits 12 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\CRLOverlapPeriod "Hours" | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CRLOverlapPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\ValidityPeriodUnits 5 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg ValidityPeriodUnits exit $LASTEXITCODE"; $crlRegFailed = $true }
                & certutil.exe -setreg CA\ValidityPeriod "Years" | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg ValidityPeriod exit $LASTEXITCODE"; $crlRegFailed = $true }
                if ($crlRegFailed) { _Log "WARNING: One or more CRL registry settings failed" }
                _Log "  CRL periods set."

                # Enable auditing
                _Log "Enabling CA audit..."
                & certutil.exe -setreg CA\AuditFilter 127 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg AuditFilter exit $LASTEXITCODE" }

                # Restart certsvc to apply CDP/AIA/CRL changes
                _Log "Restarting certsvc to apply configuration..."
                Restart-Service certsvc -Force
                if (-not (Wait-CertSvcReady -TimeoutSec 90)) {
                    _Log "WARNING: CA slow to respond after config restart (may still be building CRL)"
                }
                _Log "CA restarted successfully."

                # Publish CRL
                _Log "Publishing CRL..."
                $crlOutput = & certutil.exe -crl 2>&1
                if ($LASTEXITCODE -ne 0) {
                    _Log "WARNING: certutil -crl returned exit code ${LASTEXITCODE}: $($crlOutput | Out-String)"
                } else {
                    _Log "  CRL published successfully."
                }

                # Copy CA cert to web folder for AIA
                _Log "Copying CA cert to web folder for AIA..."
                $destCert = Join-Path $WebFolderPath "$IntCAName.crt"
                # Get CA cert from local machine store (avoids certutil -ca.cert chain validation hang)
                $caCert = Get-ChildItem Cert:\LocalMachine\CA | Where-Object { $_.Subject -match $caConfigName } | Select-Object -First 1
                if (-not $caCert) {
                    # Fallback: try CertEnroll directory
                    $certEnroll = Get-ChildItem "C:\Windows\System32\CertSrv\CertEnroll\*.crt" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($certEnroll) {
                        Copy-Item -Path $certEnroll.FullName -Destination $destCert -Force
                        _Log "  CA cert copied from CertEnroll to $destCert"
                    } else {
                        _Log "WARNING: Could not find CA cert for AIA web folder"
                    }
                } else {
                    [System.IO.File]::WriteAllBytes($destCert, $caCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                    _Log "  CA cert exported from store to $destCert"
                }

                # Final verification
                _Log "Verifying CA is operational..."
                $null = & certutil.exe -ping 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Final verification failed: certutil -ping returned $LASTEXITCODE"
                }
                _Log "Step 4 config complete. Intermediate CA is fully configured."
                return @{ Success = $true; Log = $report.ToArray() }
            }
            catch {
                _Log "FAILED: $($_.Exception.Message)"
                return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
            }
        }

        $result7 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
            -ScriptBlock $step7Script `
            -ArgumentList $intCAName, $domainName, $webURL, $webFolderPath `
            -DisplayName "TwoTierPKI Step 7: Configure CDP/AIA/CRL"

        if (-not (Test-PKIStepResult -Result $result7 -StepName "Step 7" -LogPrefix "TwoTierPKI" -LogSource "CA" -Indent "  ")) {
            return $false
        }
        $step7Elapsed = ((Get-Date) - $step4to7Start).TotalSeconds
        Write-Log "  [TwoTierPKI] Step 7 complete: Intermediate CA operational ($([int]$step7Elapsed)s)"
    }

    #---------------------------------------------------------------------------
    # STEP 8: Import certificate templates (shared helper)
    #---------------------------------------------------------------------------
    $templateResult = Install-PKICertificateTemplates -CAVMName $issuingCAVMName -DomainName $domainName `
        -DeployConfig $DeployConfig -LogPrefix "TwoTierPKI"
    if (-not $templateResult) {
        return $false
    }

    #---------------------------------------------------------------------------
    # STEP 9: Shutdown Root CA VM
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 9: Shutting down Root CA VM '$rootCAVMName'..."
    try {
        $vmState = (Get-VM -Name $rootCAVMName -ErrorAction SilentlyContinue).State
        if ($vmState -eq 'Off') {
            Write-Log "[TwoTierPKI] Root CA VM already off."
        }
        else {
            Stop-VM -Name $rootCAVMName -Force -ErrorAction Stop
            Write-Log "[TwoTierPKI] Root CA VM shut down successfully."
        }
    }
    catch {
        Write-Log "[TwoTierPKI] WARNING: Failed to shut down Root CA VM: $($_.Exception.Message)" -Warning
    }

    # Cleanup host staging
    try {
        Remove-Item -Path $hostStagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {}

    Write-Log "### [TwoTierPKI] Two-tier PKI deployment complete!" -NoIndent
    return $true
}
