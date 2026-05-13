###############################################################################
# Common.TwoTierPKI.ps1
#
# Host-driven orchestrator for two-tier PKI (Standalone Offline Root CA +
# Enterprise Subordinate CA on DC). Called after Phase2 completes when
# cmOptions.UseOfflineRootCA is enabled.
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

function Install-TwoTierPKI {
    <#
    .SYNOPSIS
        Orchestrates a two-tier PKI deployment using an offline root CA and an
        enterprise subordinate CA on the DC.

    .DESCRIPTION
        This function runs after Phase2 completes. It:
          Step 1: Configures the Standalone Root CA (installs ADCS, CDP/AIA, exports cert+CRL)
          Step 2: Prepares the DC as Intermediate CA (IIS, CRL vdir, publishes root to AD, installs Sub CA with -OutputCertRequestFile)
          Step 3: Signs the CSR on the Root CA (Submit, Approve, Retrieve)
          Step 4: Completes the Intermediate CA (installs cert, configures CDP/AIA, publishes CRL)
          Step 5: Shuts down the Root CA VM

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
    $dcVM = $DeployConfig.virtualMachines | Where-Object { $_.role -eq "DC" -and $_.SubordinateCA } | Select-Object -First 1

    if (-not $rootCAVM) {
        Write-Log "[TwoTierPKI] ERROR: No StandaloneRootCA VM found in config" -Failure
        return $false
    }
    if (-not $dcVM) {
        Write-Log "[TwoTierPKI] ERROR: No DC with SubordinateCA flag found in config" -Failure
        return $false
    }

    $rootCAVMName = $rootCAVM.vmName
    $dcVMName = $dcVM.vmName
    $domainName = $DeployConfig.vmOptions.domainName
    $domainShort = $domainName.Split(".")[0]
    $rootCAName = "CSSRoot-CA"
    $intCAName = "$domainShort-$dcVMName-CA"
    $intCAServer = "$dcVMName.$domainName"
    $webURL = "http://pki.$domainName/crl/"
    $webFolderPath = "C:\inetpub\wwwroot\CRL\"
    $rootCAFilesPath = "C:\temp\RootCAFiles\"
    $intCAFilesPath = "C:\temp\IntermediateCAFiles\"

    # Host staging folder for cert file exchange
    $hostStagingPath = Join-Path $env:TEMP "MemLabs_TwoTierPKI_$($DeployConfig.vmOptions.domainName)"
    if (-not (Test-Path $hostStagingPath)) {
        New-Item -ItemType Directory -Path $hostStagingPath -Force | Out-Null
    }

    Write-Log "[TwoTierPKI] Root CA VM: $rootCAVMName | DC VM: $dcVMName"
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
                # Install PSPKI module
                _Log "Installing PSPKI module..."
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                if (-not (Get-Module -ListAvailable -Name PSPKI)) {
                    $retryCount = 0
                    $installed = $false
                    while (-not $installed -and $retryCount -lt 3) {
                        $retryCount++
                        try {
                            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                            Install-Module -Name PSPKI -Force -SkipPublisherCheck -MaximumVersion 4.2.0 | Out-Null
                            $installed = $true
                        }
                        catch {
                            _Log "PSPKI install attempt $retryCount failed: $($_.Exception.Message)"
                            if ($retryCount -lt 3) {
                                Start-Sleep -Seconds 10
                                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                            } else { throw }
                        }
                    }
                }

                # Write CAPolicy.inf
                _Log "Writing CAPolicy.inf..."
                $caPolicyContent = @"
[Version]
Signature="`$Windows NT`$"

[certsrv_server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=20
CRLPeriod=Weeks
CRLPeriodUnits=26
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
                # Ensure PSPKI is available even on re-run
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                if (-not (Get-Module -ListAvailable -Name PSPKI)) {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                    Install-Module -Name PSPKI -Force -SkipPublisherCheck -MaximumVersion 4.2.0 | Out-Null
                }

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

            Import-Module PSPKI -Force

            # Configure CDP (idempotent - removes existing http/file entries and re-adds)
            _Log "Configuring CDP..."
            $crlList = Get-CACrlDistributionPoint
            foreach ($crl in $crlList) {
                if ($crl.Uri -like '*http*' -or $crl.Uri -like '*file*') {
                    Remove-CACrlDistributionPoint $crl.Uri -Force | Out-Null
                }
            }
            Add-CACRLDistributionPoint -Uri "$($WebURL)$($RootCAName)%8%9.crl" -AddToCertificateCDP -AddToFreshestCrl -Force | Out-Null

            # Configure AIA (idempotent)
            _Log "Configuring AIA..."
            Get-CAAuthorityInformationAccess | Where-Object { $_.Uri -like '*http*' -or $_.Uri -like '*file*' } | Remove-CAAuthorityInformationAccess -Force | Out-Null
            Add-CAAuthorityInformationAccess -AddToCertificateAia "$($WebURL)$($RootCAName).crt" -Force | Out-Null

            # Set DSConfigDN (standalone CA needs this for AD-aware templates)
            _Log "Setting DSConfigDN..."
            $dnParts = $DomainName.Split(".")
            $configDN = "CN=Configuration," + (($dnParts | ForEach-Object { "DC=$_" }) -join ",")
            & certutil.exe -setreg CA\DSConfigDN $configDN | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -setreg CA\DSConfigDN returned exit code $LASTEXITCODE" }

            # Set CRL periods (idempotent registry writes)
            _Log "Setting CRL periods..."
            & certutil.exe -setreg CA\CRLPeriodUnits 26 | Out-Null
            & certutil.exe -setreg CA\CRLPeriod "Weeks" | Out-Null
            & certutil.exe -setreg CA\CRLDeltaPeriodUnits 0 | Out-Null
            & certutil.exe -setreg CA\CRLDeltaPeriod "Days" | Out-Null
            & certutil.exe -setreg CA\CRLOverlapPeriodUnits 1 | Out-Null
            & certutil.exe -setreg CA\CRLOverlapPeriod "Weeks" | Out-Null

            # Enable auditing
            _Log "Enabling audit..."
            & certutil.exe -setreg CA\AuditFilter 127 | Out-Null

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

    $result = Invoke-VmCommand -VmName $rootCAVMName -VmDomainName "WORKGROUP" `
        -ScriptBlock $step1Script `
        -ArgumentList $rootCAName, $domainName, $webURL, $rootCAFilesPath `
        -DisplayName "TwoTierPKI Step 1: Configure Root CA"

    if ($result.ScriptBlockFailed -or -not $result.ScriptBlockOutput.Success) {
        $err = if ($result.ScriptBlockFailed) { $result.ScriptBlockFailed } else { $result.ScriptBlockOutput.Error }
        Write-Log "[TwoTierPKI] Step 1 FAILED: $err" -Failure
        if ($result.ScriptBlockOutput.Log) {
            foreach ($line in $result.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][RootCA] $line" -LogOnly }
        }
        return $false
    }
    foreach ($line in $result.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][RootCA] $line" -LogOnly }
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
    # STEP 2: Prepare Intermediate CA (DC)
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 2: Preparing Intermediate CA on $dcVMName..." -NoIndent

    # First, copy root CA files from host to DC
    # Ensure the destination directory exists on the remote VM before copying.
    # Copy-Item -ToSession fails with cryptic errors if the target dir is missing.
    $null = Invoke-VmCommand -VmName $dcVMName -VmDomainName $domainName -DisplayName "Create RootCAFiles dir" -SuppressLog `
        -ScriptBlock { New-Item -ItemType Directory -Path "C:\temp\RootCAFiles" -Force | Out-Null }
    $copyFailed = $false
    foreach ($fileName in $filesToCopy) {
        $srcOnHost = Join-Path $hostStagingPath $fileName
        if (-not (Test-Path $srcOnHost)) {
            Write-Log "[TwoTierPKI] ERROR: Source file not found on host: $srcOnHost" -Failure
            $copyFailed = $true
            continue
        }
        $copyOk = Copy-ItemSafe -Path $srcOnHost -Destination "C:\temp\RootCAFiles\" -VMName $dcVMName -VMDomainName $domainName
        if (-not $copyOk) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy '$fileName' to DC" -Failure
            $copyFailed = $true
        }
    }
    if ($copyFailed) {
        Write-Log "[TwoTierPKI] ERROR: One or more Root CA files failed to copy to DC" -Failure
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

            # Publish root cert to AD (idempotent with -f flag)
            _Log "Publishing root cert to AD..."
            $rootCertFile = Join-Path $RootCAFilesPath "$RootCAName.crt"
            if (-not (Test-Path $rootCertFile)) {
                throw "Root CA certificate not found: $rootCertFile"
            }
            & certutil.exe -dspublish -f $rootCertFile RootCA | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -dspublish RootCA exit code $LASTEXITCODE" }
            & certutil.exe -dspublish -f $rootCertFile NTAuthCA | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -dspublish NTAuthCA exit code $LASTEXITCODE" }

            # Publish root CRL to AD (idempotent with -f flag)
            _Log "Publishing root CRL to AD..."
            $crlFiles = Get-ChildItem -Path $RootCAFilesPath -Filter "*.crl" -ErrorAction SilentlyContinue
            foreach ($crl in $crlFiles) {
                & certutil.exe -dspublish -f $crl.FullName | Out-Null
            }

            # Create DNS alias pki.<domain> pointing to this DC (idempotent)
            _Log "Creating DNS alias pki.$DomainName..."
            $dcHostName = $env:COMPUTERNAME
            try {
                $existing = Get-DnsServerResourceRecord -ZoneName $DomainName -Name "pki" -RRType CName -ErrorAction SilentlyContinue
                if (-not $existing) {
                    Add-DnsServerResourceRecordCName -ZoneName $DomainName -Name "pki" -HostNameAlias "$dcHostName.$DomainName" | Out-Null
                }
            }
            catch {
                _Log "  DNS alias creation failed (non-fatal): $($_.Exception.Message)"
            }

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

    $result2 = Invoke-VmCommand -VmName $dcVMName -VmDomainName $domainName `
        -ScriptBlock $step2Script `
        -ArgumentList $intCAName, $intCAServer, $domainName, $webURL, $webFolderPath, $rootCAName, $rootCAFilesPath, $intCAFilesPath `
        -DisplayName "TwoTierPKI Step 2: Prepare Intermediate CA"

    if ($result2.ScriptBlockFailed -or -not $result2.ScriptBlockOutput.Success) {
        $err = if ($result2.ScriptBlockFailed) { $result2.ScriptBlockFailed } else { $result2.ScriptBlockOutput.Error }
        Write-Log "[TwoTierPKI] Step 2 FAILED: $err" -Failure
        if ($result2.ScriptBlockOutput.Log) {
            foreach ($line in $result2.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][DC] $line" -LogOnly }
        }
        return $false
    }
    foreach ($line in $result2.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][DC] $line" -LogOnly }

    # If Sub CA is already fully complete (cert installed, service running), skip Steps 3-4
    if ($result2.ScriptBlockOutput.AlreadyComplete) {
        Write-Log "[TwoTierPKI] Step 2: Subordinate CA already operational - skipping Steps 3-4"
    }
    else {
        Write-Log "[TwoTierPKI] Step 2 complete: Intermediate CA prepared, CSR generated"

        #---------------------------------------------------------------------------
        # HOST COPY: CSR from DC → host → Root CA
        #---------------------------------------------------------------------------
        $reqFileName = [System.IO.Path]::GetFileName($result2.ScriptBlockOutput.ReqFile)
        if ([string]::IsNullOrWhiteSpace($reqFileName)) {
            Write-Log "[TwoTierPKI] ERROR: Step 2 did not return a valid CSR file path" -Failure
            return $false
        }
        Write-Log "[TwoTierPKI] Copying CSR '$reqFileName' from DC to Root CA via host..." -LogOnly

        # DC → host
        $copyResult = Copy-ItemFromVM -Path $result2.ScriptBlockOutput.ReqFile -Destination $hostStagingPath -VMName $dcVMName -VMDomainName $domainName
        if (-not $copyResult) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy CSR from DC to host" -Failure
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

                # Use certutil -submit (never shows UI dialogs, unlike certreq
                # which can pop a template-picker or CA-picker even with -config).
                _Log "Submitting certificate request via certutil: $reqFile"

                # certutil -submit [-config CA] <req> [<cert> [<chain> [<fullresponse>]]]
                $submitOutput = & certutil.exe -submit -config "$caConfig" "$reqFile" "$cerFile" 2>&1
                $submitExitCode = $LASTEXITCODE
                _Log "certutil -submit exit code: $submitExitCode"
                foreach ($line in $submitOutput) { _Log "  certutil: $line" }

                # Parse the request ID from certutil output regardless of exit code
                $requestID = $null
                foreach ($line in $submitOutput) {
                    if ($line -match 'RequestId:\s*(\d+)') {
                        $requestID = $Matches[1]
                        break
                    }
                }
                if (-not $requestID) {
                    foreach ($line in $submitOutput) {
                        if ($line -match 'RequestId[^:]*:\s*"?(\d+)') {
                            $requestID = $Matches[1]
                            break
                        }
                    }
                }

                if ($submitExitCode -eq 0 -and (Test-Path $cerFile) -and (Get-Item $cerFile).Length -gt 0) {
                    # Certificate was issued immediately (auto-approve / policy module accepted)
                    _Log "Certificate issued and retrieved immediately (request ID: $requestID)."
                }
                elseif ($submitExitCode -eq 5 -or ($requestID -and -not (Test-Path $cerFile))) {
                    # Request is pending (standalone CA default). Approve and retrieve.
                    if (-not $requestID) {
                        throw "Could not parse request ID from certutil -submit output"
                    }
                    _Log "Request pending with ID: $requestID. Approving..."

                    # Approve (resubmit) the pending request
                    $approveOutput = & certutil.exe -resubmit $requestID 2>&1
                    $approveExitCode = $LASTEXITCODE
                    _Log "certutil -resubmit exit code: $approveExitCode"
                    foreach ($line in $approveOutput) { _Log "  certutil: $line" }

                    if ($approveExitCode -ne 0) {
                        throw "certutil -resubmit failed (exit code $approveExitCode): $($approveOutput | Out-String)"
                    }

                    Start-Sleep -Seconds 3

                    # Retrieve the issued certificate via certreq -retrieve
                    # (certreq -retrieve does NOT show UI when given an
                    # explicit -config and request ID)
                    _Log "Retrieving issued certificate for request ID $requestID..."
                    $retrieveOutput = & certreq.exe -retrieve -f -config "$caConfig" $requestID "$cerFile" 2>&1
                    $retrieveExitCode = $LASTEXITCODE
                    _Log "certreq -retrieve exit code: $retrieveExitCode"
                    foreach ($line in $retrieveOutput) { _Log "  certreq: $line" }

                    if ($retrieveExitCode -ne 0) {
                        # Fallback: try certutil -view to export the cert
                        _Log "certreq -retrieve failed; trying certutil -view as fallback..."
                        $viewOutput = & certutil.exe -view -restrict "RequestID=$requestID" -out RawCertificate 2>&1
                        $viewExitCode = $LASTEXITCODE
                        _Log "certutil -view exit code: $viewExitCode"
                        if ($viewExitCode -eq 0) {
                            # certutil -view dumps the cert as Base64 in the
                            # output. Extract and write to file.
                            $certLines = @()
                            $inCert = $false
                            foreach ($line in $viewOutput) {
                                $lineStr = "$line"
                                if ($lineStr -match '-----BEGIN CERTIFICATE-----') { $inCert = $true }
                                if ($inCert) { $certLines += $lineStr }
                                if ($lineStr -match '-----END CERTIFICATE-----') { $inCert = $false }
                            }
                            if ($certLines.Count -gt 2) {
                                Set-Content -Path $cerFile -Value ($certLines -join "`n") -Force
                                _Log "Certificate extracted from certutil -view output ($($certLines.Count) lines)"
                            }
                            else {
                                throw "certreq -retrieve failed and certutil -view did not contain a certificate"
                            }
                        }
                        else {
                            throw "certreq -retrieve failed (exit code $retrieveExitCode) and certutil -view also failed: $($viewOutput | Out-String)"
                        }
                    }
                }
                else {
                    throw "certutil -submit failed (exit code $submitExitCode): $($submitOutput | Out-String)"
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

        $result3 = Invoke-VmCommand -VmName $rootCAVMName -VmDomainName "WORKGROUP" `
            -ScriptBlock $step3Script `
            -ArgumentList $intCAFilesPath, $intCAServer, $intCAName, $rootCAName `
            -DisplayName "TwoTierPKI Step 3: Sign CSR on Root CA"

        if ($result3.ScriptBlockFailed -or -not $result3.ScriptBlockOutput.Success) {
            $err = if ($result3.ScriptBlockFailed) { $result3.ScriptBlockFailed } else { $result3.ScriptBlockOutput.Error }
            Write-Log "[TwoTierPKI] Step 3 FAILED: $err" -Failure
            if ($result3.ScriptBlockOutput.Log) {
                foreach ($line in $result3.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][RootCA] $line" -LogOnly }
            }
            return $false
        }
        foreach ($line in $result3.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][RootCA] $line" -LogOnly }
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
        # host → DC
        $cerOnHost = Join-Path $hostStagingPath $cerFileName
        if (-not (Test-Path $cerOnHost)) {
            Write-Log "[TwoTierPKI] ERROR: Signed cert not found on host at $cerOnHost" -Failure
            return $false
        }
        $null = Invoke-VmCommand -VmName $dcVMName -VmDomainName $domainName -DisplayName "Create IntermediateCAFiles dir" -SuppressLog `
            -ScriptBlock { New-Item -ItemType Directory -Path "C:\temp\IntermediateCAFiles" -Force | Out-Null }
        $copyOk = Copy-ItemSafe -Path $cerOnHost -Destination $intCAFilesPath -VMName $dcVMName -VMDomainName $domainName
        if (-not $copyOk) {
            Write-Log "[TwoTierPKI] ERROR: Failed to copy signed cert to DC" -Failure
            return $false
        }

        #---------------------------------------------------------------------------
        # STEP 4: Complete Intermediate CA (DC)
        #---------------------------------------------------------------------------
        Write-Log "[TwoTierPKI] Step 4: Completing Intermediate CA configuration on $dcVMName..." -NoIndent

        $step4Script = {
            param($IntCAName, $DomainName, $WebURL, $WebFolderPath, $IntCAFilesPath, $IntCAServer)

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
                            $null = & certutil.exe -ping 2>&1
                            if ($LASTEXITCODE -eq 0) { return $true }
                        }
                    } catch {}
                    Start-Sleep -Seconds 2
                }
                return $false
            }

            try {
                # Idempotency: check if CA is already fully operational
                $alreadyOperational = $false
                try {
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        $null = & certutil.exe -ping 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $alreadyOperational = $true
                            _Log "Intermediate CA already operational (certsvc running and responsive)"
                        }
                    }
                } catch {}

                $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"

                if (-not $alreadyOperational) {
                    if (-not (Test-Path $cerFile)) {
                        throw "Signed certificate file not found: $cerFile"
                    }

                    # Install the issued certificate
                    _Log "Installing issued certificate: $cerFile"
                    & certutil.exe -installcert $cerFile | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        # Check if it's already installed (exit code varies)
                        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                        if ($svc) {
                            _Log "certutil -installcert returned $LASTEXITCODE but certsvc exists - may already be installed"
                        }
                        else {
                            throw "certutil -installcert failed with exit code $LASTEXITCODE"
                        }
                    }

                    # Activate CA
                    _Log "Starting/restarting certsvc to activate CA..."
                    Restart-Service certsvc -ErrorAction SilentlyContinue
                    if (-not (Wait-CertSvcReady -TimeoutSec 60)) {
                        throw "CA service did not become responsive after certificate installation"
                    }
                    _Log "CA service is ready."
                }

                # Import PSPKI for CDP/AIA configuration
                Import-Module PSPKI -Force -ErrorAction SilentlyContinue

                # Configure CRL Distribution Points (idempotent - clear and re-add)
                _Log "Configuring CDP..."
                $crlList = Get-CACrlDistributionPoint
                foreach ($crl in $crlList) {
                    if ($crl.Uri -like '*http*' -or $crl.Uri -like '*file*') {
                        Remove-CACrlDistributionPoint $crl.Uri -Force | Out-Null
                    }
                }
                Add-CACRLDistributionPoint -Uri "file://$($WebFolderPath)$($IntCAName)%8%9.crl" -PublishToServer -PublishDeltaToServer -Force | Out-Null
                Add-CACRLDistributionPoint -Uri "$($WebURL)$($IntCAName)%8%9.crl" -AddToCertificateCDP -AddToFreshestCrl -Force | Out-Null

                # Configure AIA (idempotent)
                _Log "Configuring AIA..."
                Get-CAAuthorityInformationAccess | Where-Object { $_.Uri -like '*http*' -or $_.Uri -like '*file*' } | Remove-CAAuthorityInformationAccess -Force | Out-Null
                Add-CAAuthorityInformationAccess -AddToCertificateAia "$($WebURL)$($IntCAName).crt" -Force | Out-Null

                # Set CRL periods (idempotent registry writes)
                _Log "Setting CRL periods..."
                & certutil.exe -setreg CA\CRLPeriodUnits 2 | Out-Null
                & certutil.exe -setreg CA\CRLPeriod "Weeks" | Out-Null
                & certutil.exe -setreg CA\CRLDeltaPeriodUnits 1 | Out-Null
                & certutil.exe -setreg CA\CRLDeltaPeriod "Days" | Out-Null
                & certutil.exe -setreg CA\CRLOverlapPeriodUnits 12 | Out-Null
                & certutil.exe -setreg CA\CRLOverlapPeriod "Hours" | Out-Null
                & certutil.exe -setreg CA\ValidityPeriodUnits 5 | Out-Null
                & certutil.exe -setreg CA\ValidityPeriod "Years" | Out-Null

                # Enable auditing
                _Log "Enabling audit..."
                & certutil.exe -setreg CA\AuditFilter 127 | Out-Null

                # Activate changes
                _Log "Restarting certsvc to apply changes..."
                Restart-Service certsvc
                if (-not (Wait-CertSvcReady -TimeoutSec 60)) {
                    _Log "WARNING: CA service slow to respond after final restart"
                }

                # Publish CRL
                _Log "Publishing CRL..."
                & certutil.exe -crl | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: certutil -crl returned exit code $LASTEXITCODE" }

                _Log "Step 4 complete. Intermediate CA is fully operational."
                return @{ Success = $true; Log = $report.ToArray() }
            }
            catch {
                _Log "FAILED: $($_.Exception.Message)"
                return @{ Success = $false; Log = $report.ToArray(); Error = $_.Exception.Message }
            }
        }

        $result4 = Invoke-VmCommand -VmName $dcVMName -VmDomainName $domainName `
            -ScriptBlock $step4Script `
            -ArgumentList $intCAName, $domainName, $webURL, $webFolderPath, $intCAFilesPath, $intCAServer `
            -DisplayName "TwoTierPKI Step 4: Complete Intermediate CA"

        if ($result4.ScriptBlockFailed -or -not $result4.ScriptBlockOutput.Success) {
            $err = if ($result4.ScriptBlockFailed) { $result4.ScriptBlockFailed } else { $result4.ScriptBlockOutput.Error }
            Write-Log "[TwoTierPKI] Step 4 FAILED: $err" -Failure
            if ($result4.ScriptBlockOutput.Log) {
                foreach ($line in $result4.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][DC] $line" -LogOnly }
            }
            return $false
        }
        foreach ($line in $result4.ScriptBlockOutput.Log) { Write-Log "[TwoTierPKI][DC] $line" -LogOnly }
        Write-Log "[TwoTierPKI] Step 4 complete: Intermediate CA operational"
    }

    #---------------------------------------------------------------------------
    # STEP 5: Shutdown Root CA VM
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 5: Shutting down Root CA VM '$rootCAVMName'..."
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
