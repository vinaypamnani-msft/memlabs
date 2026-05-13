###############################################################################
# Common.TwoTierPKI.ps1
#
# Host-driven orchestrator for two-tier PKI (Standalone Offline Root CA +
# Enterprise Subordinate CA on DC). Called after Phase2 completes when
# cmOptions.UseOfflineRootCA is enabled.
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

        try {
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
            Import-Module PSPKI -Force

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

            Start-Sleep -Seconds 5

            # Configure CDP
            _Log "Configuring CDP..."
            $crlList = Get-CACrlDistributionPoint
            foreach ($crl in $crlList) {
                if ($crl.Uri -like '*http*' -or $crl.Uri -like '*file*') {
                    Remove-CACrlDistributionPoint $crl.Uri -Force | Out-Null
                }
            }
            Add-CACRLDistributionPoint -Uri "$($WebURL)$($RootCAName)%8%9.crl" -AddToCertificateCDP -AddToFreshestCrl -Force | Out-Null

            # Configure AIA
            _Log "Configuring AIA..."
            Get-CAAuthorityInformationAccess | Where-Object { $_.Uri -like '*http*' -or $_.Uri -like '*file*' } | Remove-CAAuthorityInformationAccess -Force | Out-Null
            Add-CAAuthorityInformationAccess -AddToCertificateAia "$($WebURL)$($RootCAName).crt" -Force | Out-Null

            # Set DSConfigDN (standalone CA needs this for AD-aware templates)
            _Log "Setting DSConfigDN..."
            $dnParts = $DomainName.Split(".")
            $configDN = "CN=Configuration," + (($dnParts | ForEach-Object { "DC=$_" }) -join ",")
            & certutil.exe -setreg CA\DSConfigDN $configDN | Out-Null

            # Set CRL periods
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
            Start-Sleep -Seconds 5
            & certutil.exe -crl | Out-Null

            # Export Root CA cert and CRL
            _Log "Exporting Root CA cert and CRL..."
            if (-not (Test-Path $RootCAFilesPath)) {
                New-Item -ItemType Directory -Path $RootCAFilesPath -Force | Out-Null
            }

            # Export cert
            $rootCertPath = Join-Path $RootCAFilesPath "$RootCAName.crt"
            & certutil.exe -ca.cert $rootCertPath | Out-Null

            # Export CRL
            $crlSourceDir = "C:\Windows\System32\CertSrv\CertEnroll\"
            $crlFiles = Get-ChildItem -Path $crlSourceDir -Filter "*.crl" -ErrorAction SilentlyContinue
            foreach ($f in $crlFiles) {
                Copy-Item -Path $f.FullName -Destination $RootCAFilesPath -Force
            }

            _Log "Step 1 complete. Files exported to $RootCAFilesPath"
            $exportedFiles = @(Get-ChildItem $RootCAFilesPath | Select-Object -ExpandProperty Name)
            _Log "Exported files: $($exportedFiles -join ', ')"

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
    foreach ($fileName in $filesToCopy) {
        $srcPath = Join-Path $rootCAFilesPath $fileName
        Copy-ItemFromVM -Path $srcPath -Destination $hostStagingPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"
    }
    Write-Log "[TwoTierPKI] Root CA files copied to host: $hostStagingPath"

    #---------------------------------------------------------------------------
    # STEP 2: Prepare Intermediate CA (DC)
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 2: Preparing Intermediate CA on $dcVMName..." -NoIndent

    # First, copy root CA files from host to DC
    foreach ($fileName in $filesToCopy) {
        $srcOnHost = Join-Path $hostStagingPath $fileName
        Copy-ItemSafe -Path $srcOnHost -Destination "C:\temp\RootCAFiles\" -VMName $dcVMName -VMDomainName $domainName
    }

    $step2Script = {
        param($IntCAName, $IntCAServer, $DomainName, $WebURL, $WebFolderPath, $RootCAName, $RootCAFilesPath, $IntCAFilesPath)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        try {
            # Install IIS
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

            # Enable double-escaping (required for delta CRL files with '+' in name)
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

            # Publish root cert to AD
            _Log "Publishing root cert to AD..."
            $rootCertFile = Join-Path $RootCAFilesPath "$RootCAName.crt"
            & certutil.exe -dspublish -f $rootCertFile RootCA | Out-Null
            & certutil.exe -dspublish -f $rootCertFile NTAuthCA | Out-Null

            # Publish root CRL to AD
            _Log "Publishing root CRL to AD..."
            $crlFiles = Get-ChildItem -Path $RootCAFilesPath -Filter "*.crl" -ErrorAction SilentlyContinue
            foreach ($crl in $crlFiles) {
                & certutil.exe -dspublish -f $crl.FullName | Out-Null
            }

            # Create DNS alias pki.<domain> pointing to this DC
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

            # Install ADCS role
            _Log "Installing ADCS role..."
            Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null

            # Install Enterprise Subordinate CA with offline request file
            _Log "Installing Enterprise Subordinate CA '$IntCAName' (offline enrollment)..."
            if (-not (Test-Path $IntCAFilesPath)) {
                New-Item -ItemType Directory -Path $IntCAFilesPath -Force | Out-Null
            }
            $reqFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.req"

            Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa `
                -CACommonName $IntCAName `
                -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                -KeyLength 2048 `
                -HashAlgorithmName SHA256 `
                -OutputCertRequestFile $reqFile `
                -Force | Out-Null

            _Log "CSR generated: $reqFile"
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
    Write-Log "[TwoTierPKI] Step 2 complete: Intermediate CA prepared, CSR generated"

    #---------------------------------------------------------------------------
    # HOST COPY: CSR from DC → host → Root CA
    #---------------------------------------------------------------------------
    $reqFileName = [System.IO.Path]::GetFileName($result2.ScriptBlockOutput.ReqFile)
    Write-Log "[TwoTierPKI] Copying CSR '$reqFileName' from DC to Root CA via host..." -LogOnly

    # DC → host
    Copy-ItemFromVM -Path $result2.ScriptBlockOutput.ReqFile -Destination $hostStagingPath -VMName $dcVMName -VMDomainName $domainName
    # host → Root CA
    $reqOnHost = Join-Path $hostStagingPath $reqFileName
    Copy-ItemSafe -Path $reqOnHost -Destination $intCAFilesPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"

    #---------------------------------------------------------------------------
    # STEP 3: Sign CSR on Root CA
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 3: Signing CSR on Root CA..." -NoIndent

    $step3Script = {
        param($IntCAFilesPath, $IntCAServer, $IntCAName)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        try {
            # Import PSPKI
            _Log "Importing PSPKI..."
            Import-Module PSPKI -Force

            $reqFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.req"
            $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"

            _Log "Submitting certificate request: $reqFile"

            # Submit the request
            $submitResult = Submit-CertificateRequest -Path $reqFile -CertificationAuthority (Get-CertificationAuthority)
            _Log "Request submitted. Request ID: $($submitResult.RequestID), Status: $($submitResult.Status)"

            # Approve the request (standalone CA holds requests pending by default).
            # Status enum values vary across PSPKI versions ("Pending", "Taken Under Submission", etc.),
            # so we approve unless already issued.
            if ($submitResult.Status -ne "Issued") {
                _Log "Approving pending request (Status='$($submitResult.Status)')..."
                try {
                    $submitResult | Approve-CertificateRequest | Out-Null
                    _Log "Request approved."
                }
                catch {
                    _Log "Approve-CertificateRequest threw (may already be issued): $($_.Exception.Message)"
                }
            }

            # Retrieve the issued certificate
            _Log "Retrieving issued certificate..."
            $requestID = $submitResult.RequestID
            & certreq.exe -retrieve $requestID $cerFile | Out-Null

            if (Test-Path $cerFile) {
                _Log "Certificate retrieved: $cerFile"
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
        -ArgumentList $intCAFilesPath, $intCAServer, $intCAName `
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
    Copy-ItemFromVM -Path $result3.ScriptBlockOutput.CerFile -Destination $hostStagingPath -VMName $rootCAVMName -VMDomainName "WORKGROUP"
    # host → DC
    $cerOnHost = Join-Path $hostStagingPath $cerFileName
    Copy-ItemSafe -Path $cerOnHost -Destination $intCAFilesPath -VMName $dcVMName -VMDomainName $domainName

    #---------------------------------------------------------------------------
    # STEP 4: Complete Intermediate CA (DC)
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 4: Completing Intermediate CA configuration on $dcVMName..." -NoIndent

    $step4Script = {
        param($IntCAName, $DomainName, $WebURL, $WebFolderPath, $IntCAFilesPath, $IntCAServer)

        $ErrorActionPreference = 'Stop'
        $report = [System.Collections.Generic.List[string]]::new()
        function _Log($m) { $report.Add("$(Get-Date -Format 'HH:mm:ss') $m") }

        try {
            $cerFile = Join-Path $IntCAFilesPath "${IntCAServer}_${IntCAName}.cer"

            # Install the issued certificate
            _Log "Installing issued certificate: $cerFile"
            & certutil.exe -installcert $cerFile | Out-Null

            # Activate CA
            _Log "Restarting certsvc to activate CA..."
            Restart-Service certsvc
            Start-Sleep -Seconds 5

            # Configure CRL Distribution Points
            _Log "Configuring CDP..."
            $crlList = Get-CACrlDistributionPoint
            foreach ($crl in $crlList) {
                if ($crl.Uri -like '*http*' -or $crl.Uri -like '*file*') {
                    Remove-CACrlDistributionPoint $crl.Uri -Force | Out-Null
                }
            }
            Add-CACRLDistributionPoint -Uri "file://$($WebFolderPath)$($IntCAName)%8%9.crl" -PublishToServer -PublishDeltaToServer -Force | Out-Null
            Add-CACRLDistributionPoint -Uri "$($WebURL)$($IntCAName)%8%9.crl" -AddToCertificateCDP -AddToFreshestCrl -Force | Out-Null

            # Configure AIA
            _Log "Configuring AIA..."
            Get-CAAuthorityInformationAccess | Where-Object { $_.Uri -like '*http*' -or $_.Uri -like '*file*' } | Remove-CAAuthorityInformationAccess -Force | Out-Null
            Add-CAAuthorityInformationAccess -AddToCertificateAia "$($WebURL)$($IntCAName).crt" -Force | Out-Null

            # Set CRL periods
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
            Start-Sleep -Seconds 5

            # Publish CRL
            _Log "Publishing CRL..."
            & certutil.exe -crl | Out-Null

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

    #---------------------------------------------------------------------------
    # STEP 5: Shutdown Root CA VM
    #---------------------------------------------------------------------------
    Write-Log "[TwoTierPKI] Step 5: Shutting down Root CA VM '$rootCAVMName'..."
    try {
        Stop-VM -Name $rootCAVMName -Force -ErrorAction Stop
        Write-Log "[TwoTierPKI] Root CA VM shut down successfully."
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
