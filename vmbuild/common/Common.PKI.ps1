# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
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
            # On failure show everything (strip the [LogOnly] marker so it isn't noise).
            foreach ($line in $Result.ScriptBlockOutput.Log) {
                $lineText = ([string]$line) -replace '\[LogOnly\]\s*', ''
                Write-Log "${Indent}  [$LogPrefix][$LogSource] $lineText"
            }
        }
        return $false
    }
    foreach ($line in $Result.ScriptBlockOutput.Log) {
        # A line tagged with [LogOnly] (anywhere -- _Log prepends a timestamp) is
        # routed to the build log file only, keeping verbose/long output (e.g.
        # ldifde dumps) off the console. The marker is stripped before writing.
        $lineText = [string]$line
        $lineLogOnly = $LogOnly
        if ($lineText -match '\[LogOnly\]') {
            $lineLogOnly = $true
            $lineText = $lineText -replace '\[LogOnly\]\s*', ''
        }
        if ($lineLogOnly) { Write-Log "${Indent}  [$LogPrefix][$LogSource] $lineText" -LogOnly }
        else { Write-Log "${Indent}  [$LogPrefix][$LogSource] $lineText" }
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
            # The LDF files contain both the msPKI-Enterprise-Oid object (in
            # CN=OID) and the template object (in CN=Certificate Templates).
            # ldifde -k skips entries that already exist, so re-running is safe.
            $configCtxA = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $oidContainerDN = "CN=OID,CN=Public Key Services,CN=Services,$configCtxA"

            foreach ($tplName in $TemplateList) {
                $found = Find-TemplateInAD $tplName
                $oidMissing = $false

                if ($found) {
                    # Template exists — but does the OID-to-name mapping?
                    $tplOid = ($found.Properties['mspki-cert-template-oid'] | Select-Object -First 1) -as [string]
                    if ($tplOid) {
                        $oidSearch = New-Object System.DirectoryServices.DirectorySearcher(
                            [ADSI]"LDAP://$oidContainerDN",
                            "(msPKI-Cert-Template-OID=$tplOid)")
                        $oidSearch.PropertiesToLoad.Add('cn') | Out-Null
                        $oidMissing = ($null -eq $oidSearch.FindOne())
                    }
                    if (-not $oidMissing) {
                        _Log "Template '$tplName' and OID mapping already exist in AD - skipping"
                        continue
                    }
                    _Log "Template '$tplName' exists but OID mapping is missing - re-importing LDF"
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
                if ($output) { _Log "[LogOnly]  ldifde output: $($output -join ' ')" }

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

        # Live heartbeat to the host. _Log is BUFFERED and only returns when the
        # whole scriptblock finishes, so the long post-dcpromo CA retry loop looks
        # frozen in real time. _Progress emits a Write-Progress record that
        # Invoke-VmCommand -PollProgress forwards live to the operator's console
        # (every call also grows the guest's Progress stream -> a stall heartbeat).
        $caProgressStart = Get-Date
        function _Progress($status) {
            try {
                $el = [int]((Get-Date) - $caProgressStart).TotalSeconds
                Write-Progress -Activity "Enterprise Root CA '$CAName'" -Status "$status (elapsed ${el}s)"
            } catch {}
        }

        # Feature BINARIES (IIS Web-Server on the issuing/sub CA, ADCS on every CA) are
        # pre-staged by Phase 2/3 DSC (InstallFeatureForSCCM InstallCA/IsOfflineRootCA).
        # We DELIBERATELY DO NOT call Install-WindowsFeature here: on some DCs the
        # ServerManager 'Collecting data' WMI provider hangs INDEFINITELY even when the
        # box is IDLE and the feature is already installed (PROVEN on pushlab: guest
        # responsive, W3SVC Running, CertSvc present, yet step2 wedged on the no-op ADCS
        # install). Verify presence with a fast LOCAL service check; if genuinely missing,
        # FAIL FAST with a clear message (fix = ensure Phase 2/3 staged it) instead of a
        # fragile servicing install inside the PKI window.
        function Install-FeatureBounded {
            param([string]$Name, [string]$Label)
            $svcName = switch ($Name) { 'Web-Server' { 'W3SVC' } 'Adcs-Cert-Authority' { 'CertSvc' } default { $null } }
            if (-not $svcName) { return }
            if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
                _Log "$Label -- $Name present (service $svcName); pre-staged by Phase 2/3 DSC."
                _Progress "$Label -- already present (pre-staged); skipping install"
                return
            }
            throw "$Name is NOT installed (service $svcName absent). It must be pre-staged by Phase 2/3 DSC (InstallFeatureForSCCM InstallCA/IsOfflineRootCA); PKI will not run Install-WindowsFeature inside its window."
        }

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

        # A CA is only "installed" once it has been CONFIGURED. The ADCS
        # role feature alone registers the certsvc service but leaves it
        # unconfigured; configuration writes Active=<CAName> under
        # CertSvc\Configuration. Testing the service alone made a FAILED
        # config look "installed", so a retry would skip the real work and
        # then fail trying to start an unconfigured service.
        function Test-CaConfigured {
            $cfgRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
            if (-not (Test-Path $cfgRoot)) { return $false }
            $active = (Get-ItemProperty -Path $cfgRoot -Name 'Active' -ErrorAction SilentlyContinue).Active
            if ([string]::IsNullOrWhiteSpace($active)) { return $false }
            if (-not (Test-Path (Join-Path $cfgRoot $active))) { return $false }
            return $true
        }

        # Enterprise CA setup PUBLISHES to AD (NTAuth / AIA / Enrollment
        # Services under the Configuration NC). On a freshly promoted forest
        # the directory may not be ready to accept those writes yet, which
        # surfaces as 0x80072082 ERROR_DS_RANGE_CONSTRAINT. Gate the install
        # on the Public Key Services container being reachable (proves a DC
        # is answering and the PKI containers exist), and that NTDS is up
        # when the CA is co-located on the DC (the single-tier case).
        # Probe whether the local directory will actually ACCEPT a write into the
        # Configuration NC PKI subtree -- the operation the Enterprise CA publish
        # performs. PROVEN ground truth (fabrikam 2026-06-23, Diag-PKICAConstraint):
        # right after a DC (re)boot the PKI container is READABLE immediately but a
        # Configuration-NC WRITE is rejected with 0x80072082 ERROR_DS_RANGE_CONSTRAINT
        # for a transient window that closes purely on elapsed time (failed at
        # boot+22..40min, SUCCEEDED at boot+64min with the directory otherwise fully
        # healthy). A create+delete of a throwaway container under Public Key Services
        # is the closest safe proxy for the CA's own publish write, so gating attempt 1
        # on it makes attempt 1 wait until the directory is genuinely writable instead
        # of burning real (destructive) CA install/uninstall cycles against a not-yet-
        # ready directory. NOTE: a reboot would RESET this post-boot clock and make the
        # wait LONGER, so we wait it out rather than reboot.
        function Test-ConfigNCWritable {
            try {
                $rootDSE = [ADSI]"LDAP://RootDSE"
                $configNC = $rootDSE.configurationNamingContext
                if (-not $configNC) { return @{ Ready = $false; Transient = $true; Err = "no configNC" } }
                $pks = [ADSI]"LDAP://CN=Public Key Services,CN=Services,$configNC"
                $probeName = "memlabs-pkiprobe-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
                $child = $pks.Create("container", "CN=$probeName")
                $child.SetInfo()
                try { $pks.Delete("container", "CN=$probeName") } catch {}
                return @{ Ready = $true; Transient = $false; Err = $null }
            }
            catch {
                $m = "$($_.Exception.Message)"
                $transient = $m -match '0x80072082|RANGE_CONSTRAINT|acceptable range|0x8007200E|ERROR_DS_BUSY|0x8007200F|UNWILLING_TO_PERFORM|busy'
                return @{ Ready = $false; Transient = $transient; Err = $m }
            }
        }

        function Wait-AdDsReady {
            param([int]$TimeoutSec = 300, [switch]$RequireWritable)
            $waitStart = Get-Date
            $deadline = $waitStart.AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    $ntds = Get-Service -Name NTDS -ErrorAction SilentlyContinue
                    if ($ntds -and $ntds.Status -ne 'Running') { Start-Sleep -Seconds 5; continue }
                    $rootDSE = [ADSI]"LDAP://RootDSE"
                    $configNC = $rootDSE.configurationNamingContext
                    if ($configNC) {
                        $pks = [ADSI]"LDAP://CN=Public Key Services,CN=Services,$configNC"
                        if ($pks.distinguishedName) {
                            if (-not $RequireWritable) { return $true }
                            $probe = Test-ConfigNCWritable
                            if ($probe.Ready) { return $true }
                            # Keep waiting only while the directory is TRANSIENTLY
                            # rejecting the write; a non-transient probe error
                            # (schema/rights) shouldn't block the real install.
                            if (-not $probe.Transient) { return $true }
                        }
                    }
                } catch {}
                # Live heartbeat so the gate visibly advances (it polls every 10s and
                # can wait out the whole settling window) instead of looking frozen.
                try { _Progress "waiting for AD DS to accept a Configuration-NC write ($([int]((Get-Date) - $waitStart).TotalSeconds)s / ${TimeoutSec}s)..." } catch {}
                Start-Sleep -Seconds 10
            }
            return $false
        }

        # Forces an IMMEDIATE schema cache reload on the local DC by writing the
        # schemaUpdateNow operational attribute on RootDSE. This is the supported
        # instant alternative to the ~5-min automatic reload (or a reboot) and is
        # the precise lever for the post-dcpromo window where the freshly-promoted
        # Configuration NC rejects the Enterprise CA publish with
        # 0x80072082 ERROR_DS_RANGE_CONSTRAINT.
        function Invoke-SchemaCacheReload {
            try {
                $rootDSE = [ADSI]"LDAP://RootDSE"
                $rootDSE.Put("schemaUpdateNow", 1)
                $rootDSE.SetInfo()
                return $true
            } catch {
                return $false
            }
        }

        # One-shot diagnostic: bump NTDS '15 Field Engineering' so the next failed
        # publish records the EXACT offending object/attribute in the Directory
        # Service log. Returns the prior value so the caller can restore it.
        function Set-NtdsFieldEngineering {
            param([int]$Level)
            $diagPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics'
            $prior = $null
            try {
                if (Test-Path $diagPath) {
                    $prior = (Get-ItemProperty -Path $diagPath -Name '15 Field Engineering' -ErrorAction SilentlyContinue).'15 Field Engineering'
                    Set-ItemProperty -Path $diagPath -Name '15 Field Engineering' -Value $Level -Type DWord -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            return $prior
        }

        # Pull any constraint/range/attribute Directory Service events since a
        # given time so the exact failing attribute lands in the build log.
        function Get-DsConstraintEvents {
            param([datetime]$Since)
            $out = @()
            try {
                $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue |
                    Where-Object { $_.Message -match 'constraint|range|attribute' } | Select-Object -First 5
                foreach ($e in $evts) {
                    $flat = ($e.Message -replace '\s+', ' ')
                    $out += "DS-Event $($e.Id) @ $($e.TimeCreated.ToString('HH:mm:ss')): " + $flat.Substring(0, [Math]::Min(220, $flat.Length))
                }
            } catch {}
            return $out
        }

        # ── In-flight ADVANCED DIAGNOSTICS (mirrors the two-tier path) ────────
        # Runs automatically when the Enterprise Root CA publish keeps failing, so
        # the ground truth (identity/EA token, Config-NC writability, container
        # DACLs, DC health, topology/replication, certocm.log, DS events) lands in
        # the build log without a manual re-run. Returns a classification the
        # escalation ladder + host reboot decision are gated on.
        function Invoke-PkiPublishDiagnostics {
            param([datetime]$Since, [string]$Reason = "")
            $hasEA = $null; $writeReady = $null; $writeErr = $null
            _Log "──── PKI-DIAG ($Reason) ────"
            try {
                $wi = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                _Log "[PKI-DIAG] Identity: $($wi.Name)  IsSystem=$($wi.IsSystem)"
            } catch {}
            try {
                $g = whoami /groups /fo list 2>&1 | Out-String
                $hasEA = ($g -match '-519\b') -or ($g -match 'Enterprise Admins')
                $hasDA = ($g -match '-512\b') -or ($g -match 'Domain Admins')
                $hasSA = ($g -match '-518\b') -or ($g -match 'Schema Admins')
                _Log "[PKI-DIAG] Token EnterpriseAdmins=$hasEA DomainAdmins=$hasDA SchemaAdmins=$hasSA"
            } catch { _Log "[PKI-DIAG] whoami error: $($_.Exception.Message)" }
            try {
                $probe = Test-ConfigNCWritable
                $writeReady = [bool]$probe.Ready
                $writeErr = "$($probe.Err)"
                _Log "[PKI-DIAG] Config-NC write probe: Ready=$($probe.Ready) Transient=$($probe.Transient) Err=$writeErr"
            } catch { _Log "[PKI-DIAG] write probe error: $($_.Exception.Message)" }
            try {
                $configCtx = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $pksDN = "CN=Public Key Services,CN=Services,$configCtx"
                foreach ($c in 'CN=Certification Authorities', 'CN=NTAuthCertificates', 'CN=Enrollment Services') {
                    try {
                        $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$c,$pksDN")
                        $sec = $de.ObjectSecurity
                        $owner = $sec.GetOwner([System.Security.Principal.NTAccount]).Value
                        $writers = @()
                        foreach ($ace in $sec.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
                            if ("$($ace.ActiveDirectoryRights)" -match 'Write|GenericAll|CreateChild') { $writers += "$($ace.AccessControlType):$($ace.IdentityReference.Value)" }
                        }
                        _Log "[PKI-DIAG] DACL $c owner=$owner writers=[$(( $writers | Select-Object -Unique) -join ', ')]"
                    } catch { _Log "[PKI-DIAG] DACL $c error: $($_.Exception.Message)" }
                }
            } catch {}
            try {
                $dd = dcdiag /test:Services /test:Advertising /test:NetLogons 2>&1 | Out-String
                foreach ($ln in ($dd -split "`r?`n")) { if ($ln -match 'passed test|failed test') { _Log "[PKI-DIAG] dcdiag: $($ln.Trim())" } }
            } catch { _Log "[PKI-DIAG] dcdiag error: $($_.Exception.Message)" }
            try {
                $configCtx2 = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $dcCount = $null
                try {
                    $srch = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://CN=Sites,$configCtx2", "(objectClass=nTDSDSA)")
                    $srch.PageSize = 100
                    $dcCount = @($srch.FindAll()).Count
                } catch {}
                _Log "[PKI-DIAG] Forest DC count (nTDSDSA): $dcCount  (1 => no inter-DC replication possible; a persistent write refusal is purely local readiness)"
                try {
                    $bound = nltest /dsgetdc:$env:USERDNSDOMAIN 2>&1 | Out-String
                    foreach ($ln in ($bound -split "`r?`n")) { if ($ln -match '\bDC:|Dom Name|Flags:|Our Site|The command') { _Log "[PKI-DIAG] dsgetdc: $($ln.Trim())" } }
                } catch {}
                try {
                    $rr = repadmin /showrepl 2>&1 | Out-String
                    foreach ($ln in ($rr -split "`r?`n")) { if ($ln -match 'error|fail|was successful|Last attempt|Source:|Naming Context|only one|no inbound|Default-First') { _Log "[PKI-DIAG] repadmin: $($ln.Trim())" } }
                } catch {}
                $sysvol = Get-SmbShare -Name SYSVOL -ErrorAction SilentlyContinue
                $netlogon = Get-SmbShare -Name NETLOGON -ErrorAction SilentlyContinue
                _Log "[PKI-DIAG] Shares: SYSVOL=$([bool]$sysvol) NETLOGON=$([bool]$netlogon)"
                $dfsr = Get-Service -Name DFSR -ErrorAction SilentlyContinue
                _Log "[PKI-DIAG] DFSR service: $(if ($dfsr) { $dfsr.Status } else { 'absent' })"
                try {
                    $sync = Get-WinEvent -FilterHashtable @{ LogName = 'DFS Replication'; Id = 4602 } -MaxEvents 1 -ErrorAction SilentlyContinue
                    if ($sync) { _Log "[PKI-DIAG] DFSR SYSVOL initial-sync (event 4602) completed at $($sync.TimeCreated)" }
                    else { _Log "[PKI-DIAG] DFSR SYSVOL initial-sync (event 4602): NOT found (SYSVOL may still be converging)" }
                } catch {}
            } catch { _Log "[PKI-DIAG] topology/replication capture error: $($_.Exception.Message)" }
            try {
                if (Test-Path 'C:\Windows\certocm.log') {
                    foreach ($ln in (Get-Content 'C:\Windows\certocm.log' -Tail 25 -ErrorAction SilentlyContinue)) { if ($ln.Trim()) { _Log "[PKI-DIAG] certocm: $ln" } }
                }
            } catch {}
            try {
                $evts2 = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue | Sort-Object TimeCreated | Select-Object -First 25
                foreach ($e in $evts2) { $f = ($e.Message -replace '\s+', ' '); _Log ("[PKI-DIAG] DS Id={0} {1} {2}" -f $e.Id, $e.LevelDisplayName, $f.Substring(0, [Math]::Min(240, $f.Length))) }
            } catch {}
            # AD-TRUTH vs LOGON-TOKEN (the settling-token race test). Enterprise Admins is a
            # UNIVERSAL group expanded into a token by the GC; a token minted before the
            # freshly promoted first DC's GC can expand it LACKS the EA SID even though the
            # account IS an EA in AD. If AD tokenGroups=EA-true but the logon token=EA-false,
            # that's the stale/settling-token cause (a FRESH session / re-run fixes it) --
            # NOT a genuine non-EA account (the closed OS bugs 61015649/61015662).
            $adHasEA = $null
            try {
                $rdse = [ADSI]"LDAP://RootDSE"
                $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $us = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$($rdse.defaultNamingContext)", "(objectSid=$mySid)")
                $ur = $us.FindOne()
                if ($ur) {
                    $ue = $ur.GetDirectoryEntry()
                    $ue.RefreshCache(@('tokenGroups'))
                    $adHasEA = $false
                    foreach ($tg in $ue.Properties['tokenGroups']) {
                        $sidv = (New-Object System.Security.Principal.SecurityIdentifier([byte[]]$tg, 0)).Value
                        if ($sidv -like '*-519') { $adHasEA = $true }
                    }
                }
                _Log "[PKI-DIAG] AD tokenGroups EnterpriseAdmins=$adHasEA  (vs logon-token EA=$hasEA; AD=true & token=false => SETTLING/STALE-TOKEN race -> fresh session fixes it)"
                _Log "[PKI-DIAG] GlobalCatalogReady=$($rdse.isGlobalCatalogReady) (EA is Universal -> expanded via the GC)"
            } catch { _Log "[PKI-DIAG] AD tokenGroups check error: $($_.Exception.Message)" }
            # DIRECT TOKEN ANALYSIS (client/DC side): compare the ACTUAL install-session token
            # to a FRESH one AD would mint now. processEA = does THIS session's Kerberos token
            # carry Enterprise Admins (RID 519)? freshEA = S4U2Self mints a brand-new token for
            # this SAME account from CURRENT directory membership (no password) = what a NEW
            # logon/session would get now. processEA=false while freshEA/adHasEA=true proves the
            # settling-token race TOKEN-SIDE (cached session stale; a fresh session, not a
            # reboot, fixes it).
            $processEA = $null; $freshEA = $null
            try {
                $pg = @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' })
                $processEA = ($pg.Count -gt 0)
            } catch {}
            try {
                $s4u = New-Object System.Security.Principal.WindowsIdentity("$env:USERNAME@$env:USERDNSDOMAIN")
                $fg = @($s4u.Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' })
                $freshEA = ($fg.Count -gt 0)
                $s4u.Dispose()
            } catch { _Log "[PKI-DIAG] S4U fresh-token probe error: $($_.Exception.Message)" }
            _Log "[PKI-DIAG] TOKEN ANALYSIS: processToken EA=$processEA | freshS4U EA=$freshEA | AD tokenGroups EA=$adHasEA"
            if ($processEA -eq $false -and ($freshEA -eq $true -or $adHasEA -eq $true)) {
                _Log "[PKI-DIAG] VERDICT: SETTLING-TOKEN CONFIRMED -- this session's token lacks Enterprise Admins but AD/a fresh logon HAS it; a NEW session fixes it (no reboot needed)."
            }
            $class = 'Unknown'
            if (($hasEA -eq $false -or $processEA -eq $false) -and ($adHasEA -eq $true -or $freshEA -eq $true)) { $class = 'SettlingToken' }
            elseif ($writeReady -eq $false -and $hasEA -eq $false) { $class = 'Structural' }
            elseif ($hasEA -eq $false) { $class = 'TokenNoEA' }
            elseif ($writeReady -eq $false) { $class = 'AccessDenied' }
            elseif ($writeReady -eq $true) { $class = 'RangeConstraint' }
            _Log "[PKI-DIAG] classification=$class"
            # AT-LOGON-TIME proof: Security 4627 'Group Membership' for THIS session's Logon
            # ID lists the exact SIDs that were in the token WHEN THE SESSION WAS MINTED. EA
            # absent there == the stale token was baked at logon (pre-GC-ready). klist shows
            # the TGT age. LogonId via CIM association (no P/Invoke).
            try {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
                $ls = $null
                if ($proc) { $ls = Get-CimAssociatedInstance $proc -ResultClassName Win32_LogonSession -ErrorAction SilentlyContinue | Select-Object -First 1 }
                if ($ls) {
                    $luidHex = ('0x{0:X}' -f [int64]$ls.LogonId)
                    _Log "[PKI-DIAG] Session LogonId=$luidHex  LogonStart=$($ls.StartTime)"
                    $sec4627 = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4627 } -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match [regex]::Escape($luidHex) } | Select-Object -First 1
                    if ($sec4627) {
                        $logonEA = [bool]($sec4627.Message -match 'S-1-5-21-[0-9-]+-519')
                        _Log "[PKI-DIAG] AT-LOGON (4627 GroupMembership for $luidHex): EnterpriseAdmins present=$logonEA @ $($sec4627.TimeCreated)"
                        if (-not $logonEA) { _Log "[PKI-DIAG] => token minted WITHOUT Enterprise Admins at logon (pre-GC-ready) -- settling-token proven AT-LOGON." }
                    }
                    else { _Log "[PKI-DIAG] 4627 GroupMembership for $luidHex not found (Audit Group Membership subcategory may be off, or aged out)." }
                }
            } catch { _Log "[PKI-DIAG] logon-event check error: $($_.Exception.Message)" }
            try {
                $kl = klist 2>&1 | Out-String
                foreach ($ln in ($kl -split "`r?`n")) { if ($ln -match 'Start Time|End Time|Cached TGT|Current LogonId|Server: krbtgt') { _Log "[PKI-DIAG] klist: $($ln.Trim())" } }
            } catch {}
            return @{ Class = $class; HasEA = $hasEA; WriteReady = $writeReady }
        }

        # ── ESCALATION Tier 1: forced token + AD refresh (no reboot) ──────────
        function Invoke-PkiTokenAdRefresh {
            _Log "[PKI-ESC] Tier1: token + AD refresh (klist purge, certutil -pulse, schema reload; bounded gpupdate)."
            # gpupdate can BLOCK for many minutes on a settling/loaded DC -> bound it so it
            # can never wedge the buffered in-guest step (which has no live timeout).
            try {
                $gp = Start-Process -FilePath gpupdate.exe -ArgumentList '/target:computer', '/force' -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                if ($gp -and -not $gp.WaitForExit(90000)) { try { $gp.Kill() } catch {}; _Log "[PKI-ESC] gpupdate exceeded 90s -- killed (non-blocking)." }
            } catch {}
            try { & klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
            try { & klist.exe purge 2>&1 | Out-Null } catch {}
            try { & certutil.exe -pulse 2>&1 | Out-Null } catch {}
            Invoke-SchemaCacheReload | Out-Null
        }

        # ── ESCALATION Tier 2: hard-reset the CA config (no reboot) ───────────
        function Invoke-PkiRoleReinstall {
            # Only tear down the CA CONFIG. Do NOT Remove/Add the Adcs-Cert-Authority ROLE
            # FEATURE: that can require a reboot and BLOCK indefinitely, and it can't fix the
            # settling-token cause anyway (only a fresh host session/PAC does). Real
            # remediation is the host session-refresh + reboot tiers.
            _Log "[PKI-ESC] Tier2: hard-reset CA config (Uninstall-AdcsCertificationAuthority; role feature left installed)."
            try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            # Ensure the 'Audit Group Membership' subcategory is ON so Security event 4627
            # records the token's group SIDs at each logon -- the at-logon EA evidence the
            # settling-token diagnostic reads. Idempotent; left enabled (harmless, low volume).
            # Enabling here guarantees it for the session-refresh + re-run sessions.
            try { & auditpol.exe /set /subcategory:"Group Membership" /success:enable 2>&1 | Out-Null; _Log "Enabled 'Audit Group Membership' (success) so Security 4627 captures token group SIDs at logon." } catch {}
            # Idempotency: only skip when the CA is genuinely CONFIGURED.
            if (Test-CaConfigured) {
                _Log "CA already configured (Active CA present) - skipping installation"
                $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Running') {
                    _Log "Starting certsvc (was $($svc.Status))..."
                    Start-Service certsvc -ErrorAction SilentlyContinue
                }
                if (-not (Wait-CertSvcReady -TimeoutSec 90)) {
                    _Log "WARNING: configured CA service slow to respond"
                }
            }
            else {
                # Service present but not configured => a prior attempt was
                # killed/failed mid-config. Tear down the partial config so a
                # clean re-config can run (the role feature stays installed).
                $svcPre = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                if ($svcPre) {
                    _Log "certsvc present but not configured (partial/failed prior install) - removing partial CA config before (re)install..."
                    try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch { _Log "Uninstall of partial CA config returned: $($_.Exception.Message)" }
                }

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
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
"@
                Set-Content -Path "C:\Windows\CAPolicy.inf" -Value $caPolicyContent -Force

                # Install ADCS role (idempotent)
                _Log "Installing ADCS role..."
                Install-FeatureBounded -Name 'Adcs-Cert-Authority' -Label 'Installing ADCS role' | Out-Null

                # Gate on AD readiness before publishing the Enterprise CA: wait for the
                # directory to ACCEPT a Config-NC WRITE (not just be reachable). Matches two-tier.
                _Log "Verifying AD DS will ACCEPT a Configuration-NC write before CA config (post-boot readiness probe)..."
                _Progress "waiting for AD DS to accept a Configuration-NC write..."
                if (-not (Wait-AdDsReady -TimeoutSec 120 -RequireWritable)) {
                    _Log "WARNING: AD DS Configuration-NC write not confirmed ready after 600s - proceeding; the retry loop will remediate transient publish errors"
                }
                else {
                    _Log "AD DS accepted a Configuration-NC probe write - directory is ready for the Enterprise CA publish."
                }

                # Install Enterprise Root CA with retry + remediation. The AD
                # publish (CCertSrvSetup::SetCASetupProperty -> LDAP writes into
                # the Configuration NC) is REJECTED BY ntdsa with
                # 0x80072082 ERROR_DS_RANGE_CONSTRAINT for a window right after
                # dcpromo, until the freshly-promoted directory / schema cache
                # settles. PROVEN on fabrikam (2026-06-23): a cold promote failed
                # ALL retries at T+0, then succeeded on the FIRST try ~22 min
                # later with NO reboot -- the cure is TIME, not a reboot. So:
                #   (1) a generous time budget (~45 min) of retries that OUTLASTS the
                #       post-boot window (PROVEN to close as late as boot+64min);
                #   (2) on RANGE_CONSTRAINT specifically, force an IMMEDIATE schema
                #       cache reload (schemaUpdateNow) to collapse that ~5-min
                #       post-dcpromo window instead of waiting it out;
                #   (3) one-shot NTDS field-engineering logging so the exact
                #       offending attribute is captured if it still fails.
                # Happy path is untouched: attempt 1 runs immediately and the
                # extra machinery only engages on an actual transient failure
                # (which is rare -- most promotes are ready by the time PKI runs).
                $caConfigured = $false
                $caLastErr = $null
                $maxCaTries = 6
                $feEnabled = $false
                $feLevelPrior = $null
                $caLoopStart = Get-Date
                # SHORT in-guest budget: fail FAST and hand control back to the host, which
                # does the cheap session-refresh (fresh Kerberos PAC = the real settling-token
                # fix) then reboot. A long in-guest retry loop can't fix the token race and
                # just wastes time; a re-run (DC older) works anyway. Diag + ladder fire early.
                $escDiagAt = 2
                $escTier1At = 4
                $escTier2At = 5
                $caLastClass = 'Unknown'
                try {
                    for ($caTry = 1; $caTry -le $maxCaTries; $caTry++) {
                        try {
                            _Log "Installing Enterprise Root CA '$CAName' (attempt $caTry/$maxCaTries)..."
                            _Progress "publishing CA to AD (attempt $caTry/$maxCaTries)..."
                            Install-AdcsCertificationAuthority -CAType EnterpriseRootCa `
                                -CACommonName $CAName `
                                -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                                -KeyLength 2048 `
                                -HashAlgorithmName SHA256 `
                                -ValidityPeriod Years `
                                -ValidityPeriodUnits 5 `
                                -Force | Out-Null
                            $caConfigured = $true
                            break
                        }
                        catch {
                            $caLastErr = $_.Exception.Message
                            # Config may have actually landed even though the cmdlet threw.
                            if (Test-CaConfigured) {
                                _Log "CA reports configured despite error on attempt $caTry ($caLastErr) - accepting."
                                $caConfigured = $true
                                break
                            }
                            $isRange = $caLastErr -match '0x80072082|ERROR_DS_RANGE_CONSTRAINT|acceptable range'
                            $transient = $isRange -or ($caLastErr -match '0x8007200E|ERROR_DS_BUSY|0x8007200F|ERROR_DS_UNWILLING_TO_PERFORM|0x80072030|ERROR_DS_NO_SUCH_OBJECT|directory service')
                            if (-not $transient) {
                                _Log "Non-transient CA install error on attempt $caTry : $caLastErr"
                                throw
                            }
                            _Log "Transient AD-publish error on attempt $caTry : $caLastErr -- remediating (tear down partial config, wait for AD, retry)."
                            _Progress "attempt $caTry/$maxCaTries hit a transient AD error; remediating..."
                            try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
                            try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch {}
                            if ($isRange) {
                                # Post-dcpromo schema-cache window: force an immediate
                                # reload instead of waiting it out (or rebooting).
                                if (Invoke-SchemaCacheReload) { _Log "Forced schema cache reload (schemaUpdateNow) to clear the post-dcpromo publish window." }
                                else { _Log "schemaUpdateNow reload attempt did not take (continuing)." }
                                # One-shot: capture the exact failing attribute next time.
                                if (-not $feEnabled) {
                                    $feLevelPrior = Set-NtdsFieldEngineering -Level 5
                                    $feEnabled = $true
                                    _Log "Enabled NTDS '15 Field Engineering'=5 to capture the exact constraint attribute on the next attempt (prior=$feLevelPrior)."
                                }
                            }
                            # In-flight advanced diagnostics + evidence-gated escalation.
                            if ($caTry -eq $escDiagAt) {
                                $d = Invoke-PkiPublishDiagnostics -Since $caLoopStart -Reason "attempt $caTry still failing"
                                $caLastClass = $d.Class
                            }
                            if ($caTry -eq $escTier1At) {
                                Invoke-PkiTokenAdRefresh
                                $d = Invoke-PkiPublishDiagnostics -Since $caLoopStart -Reason "post-Tier1"
                                $caLastClass = $d.Class
                            }
                            if ($caTry -eq $escTier2At) {
                                Invoke-PkiRoleReinstall
                            }
                            _Progress "attempt $caTry/${maxCaTries}: waiting for AD DS readiness after remediation..."
                            Wait-AdDsReady -TimeoutSec 180 | Out-Null
                            # Backoff with a ~5s heartbeat so the wait is visibly counting
                            # down (not 'hung') and -PollProgress's stall timer keeps resetting.
                            $backoffSec = [Math]::Min(45, 15 * $caTry)
                            $backoffDeadline = (Get-Date).AddSeconds($backoffSec)
                            while ((Get-Date) -lt $backoffDeadline) {
                                $remain = [int]($backoffDeadline - (Get-Date)).TotalSeconds
                                _Progress "attempt $caTry/$maxCaTries failed (post-dcpromo AD settling); next retry in ${remain}s"
                                Start-Sleep -Seconds 5
                            }
                        }
                    }
                }
                finally {
                    if ($feEnabled) {
                        $feRestore = 0
                        if ($null -ne $feLevelPrior) { $feRestore = [int]$feLevelPrior }
                        Set-NtdsFieldEngineering -Level $feRestore | Out-Null
                        _Log "Restored NTDS '15 Field Engineering' to $feRestore."
                        foreach ($ev in (Get-DsConstraintEvents -Since $caLoopStart)) { _Log "[DS diag] $ev" }
                    }
                }
                if (-not $caConfigured) {
                    # Final in-flight capture + reboot recommendation (mirrors two-tier). When
                    # the failure is a token/rights class (SettlingToken / TokenNoEA /
                    # AccessDenied / Structural) rather than the transient RangeConstraint
                    # window, the host session-refresh (fresh PAC) / reboot tier is the lever.
                    $dFinal = Invoke-PkiPublishDiagnostics -Since $caLoopStart -Reason "final failure after $maxCaTries attempts"
                    $caLastClass = $dFinal.Class
                    $caNeedsHostReboot = $false
                    if ($caLastClass -eq 'SettlingToken' -or $caLastClass -eq 'Structural' -or $caLastClass -eq 'AccessDenied' -or $caLastClass -eq 'TokenNoEA') {
                        $caNeedsHostReboot = $true
                        _Log "[PKI-ESC] Recommending a HOST-side session refresh (fresh Kerberos PAC), then reboot if needed: failure classified '$caLastClass' (not the transient RangeConstraint window). A token minted before the GC could expand Enterprise Admins is fixed by a NEW session/PAC."
                    }
                    else {
                        _Log "[PKI-ESC] NOT recommending a reboot: failure classified '$caLastClass' (reboot only resets the post-dcpromo settle clock)."
                    }
                    return @{ Success = $false; Log = $report.ToArray(); Error = "Enterprise Root CA configuration failed after $maxCaTries attempts. Last error: $caLastErr"; NeedsHostReboot = $caNeedsHostReboot; FailClass = $caLastClass }
                }

                _Log "Waiting for CA service to become ready..."
                _Progress "CA published; waiting for CertSvc to come online..."
                if (-not (Wait-CertSvcReady -TimeoutSec 90)) {
                    throw "CA service did not become responsive within 90 seconds"
                }
                _Log "CA service is ready."
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
            Install-FeatureBounded -Name 'Web-Server' -Label 'Installing IIS Web-Server' | Out-Null

            # Create CRL virtual directory -- use appcmd.exe, NOT the WebAdministration
            # module. Import-Module WebAdministration auto-creates the IIS: drive by
            # enumerating sites via WAS/COM, which deadlocks/hangs right after
            # Install-WindowsFeature Web-Server under servicing load. appcmd edits
            # applicationHost.config directly and never touches the IIS: drive provider.
            _Log "Creating CRL virtual directory..."
            if (-not (Test-Path $WebFolderPath)) {
                New-Item -ItemType Directory -Path $WebFolderPath -Force | Out-Null
            }
            $appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
            $existingVDir = & $appcmd list vdir "Default Web Site/CRL" 2>$null
            if (-not $existingVDir) {
                & $appcmd add vdir /app.name:"Default Web Site/" /path:/CRL /physicalPath:"$WebFolderPath" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: appcmd add vdir CRL exit $LASTEXITCODE" }
            }

            # Enable double-escaping
            _Log "Enabling double-escaping on CRL vdir..."
            & $appcmd set config "Default Web Site/CRL" /section:system.webServer/security/requestFiltering /allowDoubleEscaping:true /commit:apphost 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: appcmd set allowDoubleEscaping exit $LASTEXITCODE" }

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

    # CA install with an evidence-gated HOST escalation, identical in shape to the
    # two-tier Step 2 path. The in-guest loop runs its own diagnostics + no-reboot
    # ladder and, on exhaustion, returns NeedsHostReboot=$true ONLY for a token/rights
    # class (SettlingToken / TokenNoEA / AccessDenied / Structural), NOT the transient
    # RangeConstraint window. ROOT-CAUSE (settling-token race): the whole in-guest loop
    # runs in ONE cached PSDirect session whose Kerberos token is minted once; if minted
    # before the freshly promoted first DC's GC could expand the UNIVERSAL Enterprise
    # Admins membership, the token lacks the EA SID and every attempt rides it. So the
    # FIRST host lever is CHEAP: drop the cached session (Remove-VmSessionFromCache) so
    # the next call mints a FRESH token that now carries EA -- no reboot. Only if that
    # still fails do we reboot (also yields a fresh PAC).
    #
    # -AsJob -PollProgress: forward the guest's Write-Progress heartbeats LIVE to the
    # console so the (up to ~45 min) post-dcpromo CA retry loop shows a counting-down
    # status instead of appearing hung. -TimeoutSeconds is a STALL timeout (resets on
    # every guest heartbeat), NOT an absolute deadline; the inner absolute ceiling
    # (max(TimeoutSeconds*6,1800)s = 60 min) hard-bounds a CA that never settles.
    $refreshedSessionForCA = $false
    $rebootedForCA = $false
    $result = $null
    while ($true) {
        $result = Invoke-VmCommand -VmName $caVMName -VmDomainName $domainName `
            -ScriptBlock $singleTierScript `
            -ArgumentList $caName, $domainName, $webURL, $webFolderPath `
            -DisplayName "SingleTierPKI: Install Enterprise Root CA" `
            -AsJob -PollProgress -TimeoutSeconds 600

        $sbOut = $null
        if ($result -and $result.ScriptBlockOutput) { $sbOut = $result.ScriptBlockOutput } else { $sbOut = $result }
        if ($sbOut -and $sbOut.Success) { break }
        $clsCA = if ($sbOut -and $sbOut.FailClass) { "$($sbOut.FailClass)" } elseif (-not ($result -and $result.ScriptBlockOutput)) { "channel-died/timeout" } else { "unknown" }

        # Tier A (cheap, no reboot): drop the cached session and retry. A FRESH session
        # recovers BOTH a DEAD PSDirect channel (guest host died/stalled under load -> no
        # ScriptBlockOutput) and the settling-token race (fresh Kerberos PAC). Fire on ANY fail.
        if (-not $refreshedSessionForCA) {
            Write-Log "[SingleTierPKI] CA install failed (class=$clsCA). Dropping the cached PSDirect session so the retry mints a FRESH channel + logon token, then retrying (no reboot)..." -Warning
            try { Remove-VmSessionFromCache -VmName $caVMName } catch { Write-Log "[SingleTierPKI] session eviction note: $($_.Exception.Message)" }
            $refreshedSessionForCA = $true
            continue
        }
        # Tier B (reboot): the fresh session ALSO failed -> reboot the CA/DC ONCE, then retry.
        if (-not $rebootedForCA) {
            Write-Log "[SingleTierPKI] Fresh session did not clear it (class=$clsCA). Rebooting the CA/DC $caVMName ONCE from the host, then retrying..." -Warning
            try {
                $rebooted = Restart-VM2Smart -Name $caVMName -AllowTurnOff -Reason "PKI Enterprise Root CA failure ($clsCA) - host reboot tier"
                Write-Log "[SingleTierPKI] $caVMName restart issued (restarted=$rebooted); waiting for it to come back ready for PSDirect/AD..."
                $null = Wait-ForVm -VmName $caVMName -PathToVerify "C:\Users" -VmDomainName $domainName -TimeoutMinutes 15
            }
            catch {
                Write-Log "[SingleTierPKI] reboot/wait of $caVMName errored: $($_.Exception.Message) - not retrying further." -Warning
                break
            }
            try { Remove-VmSessionFromCache -VmName $caVMName } catch {}
            $rebootedForCA = $true
            continue
        }
        break
    }

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
            # Check if CA is already CONFIGURED (idempotency). The certsvc SERVICE
            # existing only means the ADCS ROLE binaries are present -- Phase 2 DSC
            # now pre-stages Adcs-Cert-Authority (Phase2WorkgroupMember ->
            # InstallFeatureForSCCM IsOfflineRootCA), which registers certsvc in a
            # Stopped state BEFORE the CA is configured. A CONFIGURED CA is indicated
            # by the Configuration\Active registry value, written by
            # Install-AdcsCertificationAuthority. Testing the service alone made a
            # fresh, unconfigured box look "installed", so the code skipped the real
            # configuration and then FAILED trying to START an unconfigured certsvc
            # ("Cannot start service certsvc on computer '.'"). Mirrors the
            # Test-CaConfigured gate used by the issuing/single-tier CA step.
            $caAlreadyInstalled = $false
            try {
                $cfgRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
                $active = (Get-ItemProperty -Path $cfgRoot -Name 'Active' -ErrorAction SilentlyContinue).Active
                if (-not [string]::IsNullOrWhiteSpace($active) -and (Test-Path (Join-Path $cfgRoot $active))) {
                    $caAlreadyInstalled = $true
                    $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
                    _Log "CA already configured (Active='$active', service state: $($svc.Status)) - skipping installation"
                }
                else {
                    _Log "certsvc present but CA not yet configured (no Configuration\Active) - will configure the Root CA."
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

                # ADCS role BINARIES are pre-staged by Phase 2 DSC (Phase2WorkgroupMember
                # -> InstallFeatureForSCCM IsOfflineRootCA -> Adcs-Cert-Authority). Do NOT
                # call Install-WindowsFeature here: ServerManager's 'Collecting data' WMI
                # provider can hang INDEFINITELY even on an idle box. Verify via the local
                # CertSvc service (registered at feature install, before CA config); if
                # genuinely missing, fail fast with a clear message.
                if (Get-Service -Name CertSvc -ErrorAction SilentlyContinue) {
                    _Log "ADCS role present (service CertSvc); pre-staged by Phase 2 DSC. Skipping Install-WindowsFeature."
                }
                else {
                    throw "Adcs-Cert-Authority is NOT installed (service CertSvc absent) on the offline Root CA. It must be pre-staged by Phase 2 DSC (InstallFeatureForSCCM IsOfflineRootCA); PKI will not run Install-WindowsFeature inside its window."
                }

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

    # Register a static DNS A record (and reverse PTR) for the Root CA on the DC.
    # The Root CA is a workgroup member and won't self-register via dynamic DNS.
    # Other VMs may need to resolve its name for CRL/AIA distribution points.
    try {
        $rootIP = (Get-VMNetworkAdapter -VMName $rootCAVMName -ErrorAction Stop).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        if ($rootIP) {
            $dnsScript = {
                param($vmName, $zone, $ip)
                $existing = Resolve-DnsName -Name "$vmName.$zone" -Type A -Server 127.0.0.1 -DnsOnly -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq 'A' }
                if (-not $existing) {
                    Add-DnsServerResourceRecordA -ZoneName $zone -Name $vmName -IPv4Address $ip -ErrorAction Stop
                }
                # Reverse PTR
                $octets = $ip.Split('.')
                $reverseZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
                $ptrZone = Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue
                if ($ptrZone) {
                    $ptrExisting = Get-DnsServerResourceRecord -ZoneName $reverseZone -Name $octets[3] -RRType Ptr -ErrorAction SilentlyContinue
                    if (-not $ptrExisting) {
                        Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name $octets[3] -PtrDomainName "$vmName.$zone." -ErrorAction Stop
                    }
                }
            }
            $null = Invoke-VmCommand -VmName $dcVMName -VmDomainName $domainName -DisplayName "Register Root CA DNS" -SuppressLog `
                -ScriptBlock $dnsScript -ArgumentList $rootCAVMName, $domainName, $rootIP
            Write-Log "[TwoTierPKI] Registered DNS A record: $rootCAVMName.$domainName -> $rootIP"
        }
        else {
            Write-Log "[TwoTierPKI] Could not determine Root CA IP; skipping DNS registration" -Warning
        }
    }
    catch {
        Write-Log "[TwoTierPKI] DNS registration for Root CA failed: $($_.Exception.Message)" -Warning
    }

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
        # Durable guest-side log that SURVIVES a host-side job kill. $report is BUFFERED
        # and returned only when the scriptblock finishes, so when Invoke-VmCommand stops
        # a stalled job the buffer is LOST and the host log shows nothing. Mirror every
        # _Log/_Progress line to this file (immediate flush) so the host can pull it back
        # after a stall and see EXACTLY where step2 wedged.
        $Step2LogFile = "C:\staging\MemLabs-PKI-Step2.log"
        try {
            $sldir = Split-Path $Step2LogFile -Parent
            if (-not (Test-Path $sldir)) { New-Item -ItemType Directory -Path $sldir -Force | Out-Null }
            "==== PKI Step 2 (Subordinate CA '$IntCAName') start $(Get-Date -Format 'o') PID=$PID ====" | Out-File -FilePath $Step2LogFile -Encoding utf8 -Force
        } catch {}
        function _Log($m) {
            $line = "$(Get-Date -Format 'HH:mm:ss') $m"
            $report.Add($line)
            try { Add-Content -LiteralPath $Step2LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
        }

        # Live heartbeat to the host. _Log is BUFFERED and only returns when the whole
        # scriptblock finishes, so step2 looks frozen in real time. _Progress emits a
        # Write-Progress record that Invoke-VmCommand -PollProgress forwards LIVE to the
        # console AND resets the stall timeout, so a genuine wedge is caught fast while a
        # slow-but-working step is not killed. It ALSO appends to the durable guest log so
        # the LAST heartbeat before a wedge survives a job kill. Mirrors the single-tier CA path.
        $step2ProgressStart = Get-Date
        function _Progress($status) {
            try {
                $el = [int]((Get-Date) - $step2ProgressStart).TotalSeconds
                Write-Progress -Activity "Subordinate CA '$IntCAName'" -Status "$status (elapsed ${el}s)"
                Add-Content -LiteralPath $Step2LogFile -Value "$(Get-Date -Format 'HH:mm:ss') [PROGRESS] $status (elapsed ${el}s)" -ErrorAction SilentlyContinue
            } catch {}
        }

        # Feature BINARIES (IIS Web-Server on the issuing/sub CA, ADCS on every CA) are
        # pre-staged by Phase 2/3 DSC (InstallFeatureForSCCM InstallCA/IsOfflineRootCA).
        # We DELIBERATELY DO NOT call Install-WindowsFeature here: on some DCs the
        # ServerManager 'Collecting data' WMI provider hangs INDEFINITELY even when the
        # box is IDLE and the feature is already installed (PROVEN on pushlab: guest
        # responsive, W3SVC Running, CertSvc present, yet step2 wedged on the no-op ADCS
        # install). Verify presence with a fast LOCAL service check; if genuinely missing,
        # FAIL FAST with a clear message (fix = ensure Phase 2/3 staged it) instead of a
        # fragile servicing install inside the PKI window.
        function Install-FeatureBounded {
            param([string]$Name, [string]$Label)
            $svcName = switch ($Name) { 'Web-Server' { 'W3SVC' } 'Adcs-Cert-Authority' { 'CertSvc' } default { $null } }
            if (-not $svcName) { return }
            if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
                _Log "$Label -- $Name present (service $svcName); pre-staged by Phase 2/3 DSC."
                _Progress "$Label -- already present (pre-staged); skipping install"
                return
            }
            throw "$Name is NOT installed (service $svcName absent). It must be pre-staged by Phase 2/3 DSC (InstallFeatureForSCCM InstallCA/IsOfflineRootCA); PKI will not run Install-WindowsFeature inside its window."
        }

        # The Enterprise Subordinate CA install PUBLISHES to the Configuration NC
        # (Enrollment Services / NTAuth / adds the machine to Cert Publishers) even
        # when it only outputs a CSR. On a freshly promoted forest that publish is
        # rejected by ntdsa with 0x80072082 ERROR_DS_RANGE_CONSTRAINT for a transient
        # window that closes purely on elapsed time (PROVEN single-tier: failed at
        # boot+22..40min, succeeded at boot+64min with the directory otherwise
        # healthy; a reboot RESETS the clock and makes it LONGER, so we wait it out).
        # certutil -dspublish (root/NTAuth) is the SAME Config-NC write earlier in
        # the sequence and hits 0x80070005 ACCESS_DENIED in the same window.
        # These helpers are defined inline because this scriptblock runs in its own
        # remote session and cannot share the single-tier helpers. PS5.1-safe.
        function Test-ConfigNCWritable {
            # Create+delete a throwaway container under Public Key Services -- the
            # closest safe proxy for the CA's own publish write. Readable != writable
            # right after dcpromo; only the WRITE surfaces the 0x80072082 window.
            # The [ADSI] bind + SetInfo() write are SYNCHRONOUS with NO timeout and HANG
            # INDEFINITELY against a wedged/overloaded local DC -- that froze the pre-install
            # gate before its heartbeat could fire. Run in a CHILD JOB capped at 45s so a
            # hung probe is returned as a transient 'busy' and the caller keeps waiting +
            # heart-beating instead of blocking forever.
            $pj = Start-Job -ScriptBlock {
                try {
                    $rootDSE = [ADSI]"LDAP://RootDSE"
                    $configNC = $rootDSE.configurationNamingContext
                    if (-not $configNC) { return @{ Ready = $false; Transient = $true; Err = "no configNC" } }
                    $pks = [ADSI]"LDAP://CN=Public Key Services,CN=Services,$configNC"
                    $probeName = "memlabs-pkiprobe-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
                    $child = $pks.Create("container", "CN=$probeName")
                    $child.SetInfo()
                    try { $pks.Delete("container", "CN=$probeName") } catch {}
                    return @{ Ready = $true; Transient = $false; Err = $null }
                }
                catch {
                    $m = "$($_.Exception.Message)"
                    $transient = $m -match '0x80072082|RANGE_CONSTRAINT|acceptable range|0x8007200E|ERROR_DS_BUSY|0x8007200F|UNWILLING_TO_PERFORM|busy|0x80070005|access is denied'
                    return @{ Ready = $false; Transient = $transient; Err = $m }
                }
            }
            if (Wait-Job $pj -Timeout 45) {
                $r = Receive-Job $pj -ErrorAction SilentlyContinue
                Remove-Job $pj -Force -ErrorAction SilentlyContinue
                if ($r) { return $r }
                return @{ Ready = $false; Transient = $true; Err = "probe returned no result" }
            }
            Stop-Job $pj -ErrorAction SilentlyContinue
            Remove-Job $pj -Force -ErrorAction SilentlyContinue
            return @{ Ready = $false; Transient = $true; Err = "probe timed out after 45s (DC not responding to LDAP write - transient)" }
        }
        function Wait-AdDsReady {
            param([int]$TimeoutSec = 300, [switch]$RequireWritable)
            $waitStart = Get-Date
            $deadline = $waitStart.AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                try {
                    $ntds = Get-Service -Name NTDS -ErrorAction SilentlyContinue
                    if ($ntds -and $ntds.Status -ne 'Running') { Start-Sleep -Seconds 5; continue }
                    $rootDSE = [ADSI]"LDAP://RootDSE"
                    $configNC = $rootDSE.configurationNamingContext
                    if ($configNC) {
                        $pks = [ADSI]"LDAP://CN=Public Key Services,CN=Services,$configNC"
                        if ($pks.distinguishedName) {
                            if (-not $RequireWritable) { return $true }
                            $probe = Test-ConfigNCWritable
                            if ($probe.Ready) { return $true }
                            # Keep waiting only while the directory is TRANSIENTLY
                            # rejecting the write; a non-transient probe error
                            # (schema/rights) shouldn't block the real install.
                            if (-not $probe.Transient) { return $true }
                        }
                    }
                } catch {}
                # Live heartbeat so the gate visibly advances (it polls every 10s and
                # can wait out the whole settling window) instead of looking frozen.
                try { _Progress "waiting for AD DS to accept a Configuration-NC write ($([int]((Get-Date) - $waitStart).TotalSeconds)s / ${TimeoutSec}s)..." } catch {}
                Start-Sleep -Seconds 10
            }
            return $false
        }
        function Invoke-SchemaCacheReload {
            # Supported instant alternative to the ~5-min auto reload / a reboot,
            # the precise lever for the post-dcpromo publish window.
            try {
                $rootDSE = [ADSI]"LDAP://RootDSE"
                $rootDSE.Put("schemaUpdateNow", 1)
                $rootDSE.SetInfo()
                return $true
            } catch { return $false }
        }
        function Set-NtdsFieldEngineering {
            # One-shot: bump so the next failed publish records the EXACT offending
            # object/attribute in the Directory Service log. Returns prior value.
            param([int]$Level)
            $diagPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics'
            $prior = $null
            try {
                if (Test-Path $diagPath) {
                    $prior = (Get-ItemProperty -Path $diagPath -Name '15 Field Engineering' -ErrorAction SilentlyContinue).'15 Field Engineering'
                    Set-ItemProperty -Path $diagPath -Name '15 Field Engineering' -Value $Level -Type DWord -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            return $prior
        }
        function Get-DsConstraintEvents {
            param([datetime]$Since)
            $out = @()
            try {
                $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue |
                    Where-Object { $_.Message -match 'constraint|range|attribute' } | Select-Object -First 5
                foreach ($e in $evts) {
                    $flat = ($e.Message -replace '\s+', ' ')
                    $out += "DS-Event $($e.Id) @ $($e.TimeCreated.ToString('HH:mm:ss')): " + $flat.Substring(0, [Math]::Min(220, $flat.Length))
                }
            } catch {}
            return $out
        }

        # ── In-flight ADVANCED DIAGNOSTICS ────────────────────────────────────
        # Runs automatically when the publish keeps failing, so we capture the
        # ground truth (identity/EA token, Config-NC writability, container DACLs,
        # DC health, certocm.log, DS events) in the build log without a manual
        # re-run. Returns a classification the escalation ladder + host reboot
        # decision are gated on: 'RangeConstraint' (schema/attribute), 'AccessDenied'
        # (Config-NC write refused), 'TokenNoEA' (running id lacks Enterprise Admins),
        # 'Structural' (write refused AND not EA), or 'Unknown'.
        function Invoke-PkiPublishDiagnostics {
            param([datetime]$Since, [string]$Reason = "")
            $hasEA = $null; $writeReady = $null; $writeErr = $null
            _Log "──── PKI-DIAG ($Reason) ────"
            try {
                $wi = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                _Log "[PKI-DIAG] Identity: $($wi.Name)  IsSystem=$($wi.IsSystem)"
            } catch {}
            try {
                $g = whoami /groups /fo list 2>&1 | Out-String
                $hasEA = ($g -match '-519\b') -or ($g -match 'Enterprise Admins')
                $hasDA = ($g -match '-512\b') -or ($g -match 'Domain Admins')
                $hasSA = ($g -match '-518\b') -or ($g -match 'Schema Admins')
                _Log "[PKI-DIAG] Token EnterpriseAdmins=$hasEA DomainAdmins=$hasDA SchemaAdmins=$hasSA"
            } catch { _Log "[PKI-DIAG] whoami error: $($_.Exception.Message)" }
            try {
                $probe = Test-ConfigNCWritable
                $writeReady = [bool]$probe.Ready
                $writeErr = "$($probe.Err)"
                _Log "[PKI-DIAG] Config-NC write probe: Ready=$($probe.Ready) Transient=$($probe.Transient) Err=$writeErr"
            } catch { _Log "[PKI-DIAG] write probe error: $($_.Exception.Message)" }
            try {
                $configCtx = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $pksDN = "CN=Public Key Services,CN=Services,$configCtx"
                foreach ($c in 'CN=Certification Authorities', 'CN=NTAuthCertificates', 'CN=Enrollment Services') {
                    try {
                        $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$c,$pksDN")
                        $sec = $de.ObjectSecurity
                        $owner = $sec.GetOwner([System.Security.Principal.NTAccount]).Value
                        $writers = @()
                        foreach ($ace in $sec.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
                            if ("$($ace.ActiveDirectoryRights)" -match 'Write|GenericAll|CreateChild') { $writers += "$($ace.AccessControlType):$($ace.IdentityReference.Value)" }
                        }
                        _Log "[PKI-DIAG] DACL $c owner=$owner writers=[$(( $writers | Select-Object -Unique) -join ', ')]"
                    } catch { _Log "[PKI-DIAG] DACL $c error: $($_.Exception.Message)" }
                }
            } catch {}
            try {
                $dd = dcdiag /test:Services /test:Advertising /test:NetLogons 2>&1 | Out-String
                foreach ($ln in ($dd -split "`r?`n")) { if ($ln -match 'passed test|failed test') { _Log "[PKI-DIAG] dcdiag: $($ln.Trim())" } }
            } catch { _Log "[PKI-DIAG] dcdiag error: $($_.Exception.Message)" }
            try {
                # Topology + replication-convergence signals: distinguishes an INTRA-DC
                # readiness gate (single-DC forest -> loopback bind, no partner to
                # converge with) from an INTER-DC replication-convergence gate. Captures
                # the DC count, which DC the publish actually binds to, repadmin repl
                # state, and SYSVOL/DFSR initial-sync readiness so the settle-window
                # MECHANISM is recorded in flight, not just inferred from absence.
                $configCtx2 = ([ADSI]"LDAP://RootDSE").configurationNamingContext
                $dcCount = $null
                try {
                    $sr = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://CN=Sites,$configCtx2", "(objectClass=nTDSDSA)")
                    $sr.PageSize = 100
                    $dcCount = @($sr.FindAll()).Count
                } catch {}
                _Log "[PKI-DIAG] Forest DC count (nTDSDSA): $dcCount  (1 => no inter-DC replication possible; a persistent write refusal is purely local readiness)"
                try {
                    $bound = nltest /dsgetdc:$env:USERDNSDOMAIN 2>&1 | Out-String
                    foreach ($ln in ($bound -split "`r?`n")) { if ($ln -match '\bDC:|Dom Name|Flags:|Our Site|The command') { _Log "[PKI-DIAG] dsgetdc: $($ln.Trim())" } }
                } catch {}
                try {
                    $rr = repadmin /showrepl 2>&1 | Out-String
                    foreach ($ln in ($rr -split "`r?`n")) { if ($ln -match 'error|fail|was successful|Last attempt|Source:|Naming Context|only one|no inbound|Default-First') { _Log "[PKI-DIAG] repadmin: $($ln.Trim())" } }
                } catch {}
                $sysvol = Get-SmbShare -Name SYSVOL -ErrorAction SilentlyContinue
                $netlogon = Get-SmbShare -Name NETLOGON -ErrorAction SilentlyContinue
                _Log "[PKI-DIAG] Shares: SYSVOL=$([bool]$sysvol) NETLOGON=$([bool]$netlogon)"
                $dfsr = Get-Service -Name DFSR -ErrorAction SilentlyContinue
                _Log "[PKI-DIAG] DFSR service: $(if ($dfsr) { $dfsr.Status } else { 'absent' })"
                try {
                    $sync = Get-WinEvent -FilterHashtable @{ LogName = 'DFS Replication'; Id = 4602 } -MaxEvents 1 -ErrorAction SilentlyContinue
                    if ($sync) { _Log "[PKI-DIAG] DFSR SYSVOL initial-sync (event 4602) completed at $($sync.TimeCreated)" }
                    else { _Log "[PKI-DIAG] DFSR SYSVOL initial-sync (event 4602): NOT found (SYSVOL may still be converging)" }
                } catch {}
            } catch { _Log "[PKI-DIAG] topology/replication capture error: $($_.Exception.Message)" }
            try {
                if (Test-Path 'C:\Windows\certocm.log') {
                    foreach ($ln in (Get-Content 'C:\Windows\certocm.log' -Tail 25 -ErrorAction SilentlyContinue)) { if ($ln.Trim()) { _Log "[PKI-DIAG] certocm: $ln" } }
                }
            } catch {}
            try {
                $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue | Sort-Object TimeCreated | Select-Object -First 25
                foreach ($e in $evts) { $f = ($e.Message -replace '\s+', ' '); _Log ("[PKI-DIAG] DS Id={0} {1} {2}" -f $e.Id, $e.LevelDisplayName, $f.Substring(0, [Math]::Min(240, $f.Length))) }
            } catch {}
            # AD-TRUTH vs LOGON-TOKEN (the settling-token race test). Enterprise Admins is a
            # UNIVERSAL group expanded into a token by the GC; a token minted before the
            # freshly promoted first DC's GC can expand it LACKS the EA SID even though the
            # account IS an EA in AD. If AD tokenGroups=EA-true but the logon token=EA-false,
            # that's the stale/settling-token cause (a FRESH session / re-run fixes it) --
            # NOT a genuine non-EA account (the closed OS bugs 61015649/61015662).
            $adHasEA = $null
            try {
                $rdse = [ADSI]"LDAP://RootDSE"
                $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                $us = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$($rdse.defaultNamingContext)", "(objectSid=$mySid)")
                $ur = $us.FindOne()
                if ($ur) {
                    $ue = $ur.GetDirectoryEntry()
                    $ue.RefreshCache(@('tokenGroups'))
                    $adHasEA = $false
                    foreach ($tg in $ue.Properties['tokenGroups']) {
                        $sidv = (New-Object System.Security.Principal.SecurityIdentifier([byte[]]$tg, 0)).Value
                        if ($sidv -like '*-519') { $adHasEA = $true }
                    }
                }
                _Log "[PKI-DIAG] AD tokenGroups EnterpriseAdmins=$adHasEA  (vs logon-token EA=$hasEA; AD=true & token=false => SETTLING/STALE-TOKEN race -> fresh session fixes it)"
                _Log "[PKI-DIAG] GlobalCatalogReady=$($rdse.isGlobalCatalogReady) (EA is Universal -> expanded via the GC)"
            } catch { _Log "[PKI-DIAG] AD tokenGroups check error: $($_.Exception.Message)" }
            # DIRECT TOKEN ANALYSIS (client/DC side): compare the ACTUAL install-session token
            # to a FRESH one AD would mint now. processEA = does THIS session's Kerberos token
            # carry Enterprise Admins (RID 519)? freshEA = S4U2Self mints a brand-new token for
            # this SAME account from CURRENT directory membership (no password) = what a NEW
            # logon/session would get now. processEA=false while freshEA/adHasEA=true proves the
            # settling-token race TOKEN-SIDE (cached session stale; a fresh session, not a
            # reboot, fixes it).
            $processEA = $null; $freshEA = $null
            try {
                $pg = @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' })
                $processEA = ($pg.Count -gt 0)
            } catch {}
            try {
                $s4u = New-Object System.Security.Principal.WindowsIdentity("$env:USERNAME@$env:USERDNSDOMAIN")
                $fg = @($s4u.Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' })
                $freshEA = ($fg.Count -gt 0)
                $s4u.Dispose()
            } catch { _Log "[PKI-DIAG] S4U fresh-token probe error: $($_.Exception.Message)" }
            _Log "[PKI-DIAG] TOKEN ANALYSIS: processToken EA=$processEA | freshS4U EA=$freshEA | AD tokenGroups EA=$adHasEA"
            if ($processEA -eq $false -and ($freshEA -eq $true -or $adHasEA -eq $true)) {
                _Log "[PKI-DIAG] VERDICT: SETTLING-TOKEN CONFIRMED -- this session's token lacks Enterprise Admins but AD/a fresh logon HAS it; a NEW session fixes it (no reboot needed)."
            }
            $class = 'Unknown'
            if (($hasEA -eq $false -or $processEA -eq $false) -and ($adHasEA -eq $true -or $freshEA -eq $true)) { $class = 'SettlingToken' }
            elseif ($writeReady -eq $false -and $hasEA -eq $false) { $class = 'Structural' }
            elseif ($hasEA -eq $false) { $class = 'TokenNoEA' }
            elseif ($writeReady -eq $false) { $class = 'AccessDenied' }
            elseif ($writeReady -eq $true) { $class = 'RangeConstraint' }
            _Log "[PKI-DIAG] classification=$class"
            # AT-LOGON-TIME proof: Security 4627 'Group Membership' for THIS session's Logon
            # ID lists the exact SIDs that were in the token WHEN THE SESSION WAS MINTED. EA
            # absent there == the stale token was baked at logon (pre-GC-ready). klist shows
            # the TGT age. LogonId via CIM association (no P/Invoke).
            try {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
                $ls = $null
                if ($proc) { $ls = Get-CimAssociatedInstance $proc -ResultClassName Win32_LogonSession -ErrorAction SilentlyContinue | Select-Object -First 1 }
                if ($ls) {
                    $luidHex = ('0x{0:X}' -f [int64]$ls.LogonId)
                    _Log "[PKI-DIAG] Session LogonId=$luidHex  LogonStart=$($ls.StartTime)"
                    $sec4627 = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4627 } -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match [regex]::Escape($luidHex) } | Select-Object -First 1
                    if ($sec4627) {
                        $logonEA = [bool]($sec4627.Message -match 'S-1-5-21-[0-9-]+-519')
                        _Log "[PKI-DIAG] AT-LOGON (4627 GroupMembership for $luidHex): EnterpriseAdmins present=$logonEA @ $($sec4627.TimeCreated)"
                        if (-not $logonEA) { _Log "[PKI-DIAG] => token minted WITHOUT Enterprise Admins at logon (pre-GC-ready) -- settling-token proven AT-LOGON." }
                    }
                    else { _Log "[PKI-DIAG] 4627 GroupMembership for $luidHex not found (Audit Group Membership subcategory may be off, or aged out)." }
                }
            } catch { _Log "[PKI-DIAG] logon-event check error: $($_.Exception.Message)" }
            try {
                $kl = klist 2>&1 | Out-String
                foreach ($ln in ($kl -split "`r?`n")) { if ($ln -match 'Start Time|End Time|Cached TGT|Current LogonId|Server: krbtgt') { _Log "[PKI-DIAG] klist: $($ln.Trim())" } }
            } catch {}
            return @{ Class = $class; HasEA = $hasEA; WriteReady = $writeReady }
        }

        # ── ESCALATION Tier 1: forced token + AD refresh (no reboot) ──────────
        # For an ACCESS_DENIED / stale-PAC style failure: refresh the machine and
        # user Kerberos context and nudge the directory before the next attempt.
        function Invoke-PkiTokenAdRefresh {
            _Log "[PKI-ESC] Tier1: token + AD refresh (klist purge, certutil -pulse, schema reload; bounded gpupdate)."
            # gpupdate can BLOCK for many minutes on a settling/loaded DC -> bound it so it
            # can never wedge the buffered in-guest step (which has no live timeout).
            try {
                $gp = Start-Process -FilePath gpupdate.exe -ArgumentList '/target:computer', '/force' -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                if ($gp -and -not $gp.WaitForExit(90000)) { try { $gp.Kill() } catch {}; _Log "[PKI-ESC] gpupdate exceeded 90s -- killed (non-blocking)." }
            } catch {}
            try { & klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
            try { & klist.exe purge 2>&1 | Out-Null } catch {}
            try { & certutil.exe -pulse 2>&1 | Out-Null } catch {}
            Invoke-SchemaCacheReload | Out-Null
        }

        # ── ESCALATION Tier 2: hard-reset the CA config (no reboot) ───────────
        function Invoke-PkiRoleReinstall {
            # Only tear down the CA CONFIG. Do NOT Remove/Add the Adcs-Cert-Authority ROLE
            # FEATURE: that can require a reboot and BLOCK indefinitely, and it can't fix the
            # settling-token cause anyway (only a fresh host session/PAC does). Real
            # remediation is the host session-refresh + reboot tiers.
            _Log "[PKI-ESC] Tier2: hard-reset CA config (Uninstall-AdcsCertificationAuthority; role feature left installed)."
            try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }

        try {
            # Ensure the 'Audit Group Membership' subcategory is ON so Security event 4627
            # records the token's group SIDs at each logon -- the at-logon EA evidence the
            # settling-token diagnostic reads. Idempotent; left enabled (harmless, low volume).
            # Enabling here guarantees it for the session-refresh + re-run sessions.
            try { & auditpol.exe /set /subcategory:"Group Membership" /success:enable 2>&1 | Out-Null; _Log "Enabled 'Audit Group Membership' (success) so Security 4627 captures token group SIDs at logon." } catch {}
            _Progress "Step 2: starting (checking existing CA state)..."

            # Environment snapshot (fast LOCAL checks only -- NO ServerManager/CIM/LDAP that
            # could hang). Written to the durable guest log so the FIRST lines tell us the
            # box's servicing/token state when step2 began -- decoupled from the PSDirect
            # channel. Tests the load-INDEPENDENT hypotheses: pending-reboot/CBS wedge and
            # the settling-token (EA-less) race.
            try {
                $upMin = [int]([Environment]::TickCount / 60000)
                _Log "[ENV] UptimeMin=$upMin (approx, from TickCount -- no WMI)"
                $pendReboot = @()
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pendReboot += 'CBS' }
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pendReboot += 'WU' }
                $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                if ($pfro) { $pendReboot += 'PendingFileRename' }
                _Log "[ENV] PendingReboot=$([string]::Join('+', $pendReboot) -replace '^$','none') (a stuck CBS/pending-reboot makes Install-WindowsFeature hang on 'Collecting data' even on an IDLE box)"
                $ti = Get-Service -Name TrustedInstaller -ErrorAction SilentlyContinue
                $tiw = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
                _Log "[ENV] TrustedInstaller=$(if($ti){$ti.Status}else{'absent'}) TiWorkerProcs=$($tiw.Count)"
                $w3 = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
                $cs = Get-Service -Name CertSvc -ErrorAction SilentlyContinue
                _Log "[ENV] Web-Server(W3SVC)=$(if($w3){'present'}else{'ABSENT -> IIS NOT pre-staged'}) ADCS(CertSvc)=$(if($cs){'present'}else{'ABSENT -> ADCS NOT pre-staged'})"
                $g = whoami /groups /fo list 2>&1 | Out-String
                $ea = ($g -match '-519\b') -or ($g -match 'Enterprise Admins')
                _Log "[ENV] Identity=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) TokenEnterpriseAdmins=$ea (false => settling-token race; a fresh host session mints a PAC that carries EA)"
            } catch { _Log "[ENV] snapshot error: $($_.Exception.Message)" }

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
            Install-FeatureBounded -Name 'Web-Server' -Label 'Step 2: installing IIS Web-Server' | Out-Null
            _Progress "Step 2: IIS installed; configuring CRL vdir via appcmd..."

            # Create CRL virtual directory (idempotent) -- use appcmd.exe, NOT the
            # WebAdministration module. Import-Module WebAdministration auto-creates the
            # IIS: drive by enumerating sites via WAS/COM, which deadlocks/hangs right
            # after Install-WindowsFeature Web-Server under servicing load. appcmd edits
            # applicationHost.config directly and never touches the IIS: drive provider.
            _Log "Creating CRL virtual directory..."
            if (-not (Test-Path $WebFolderPath)) {
                New-Item -ItemType Directory -Path $WebFolderPath -Force | Out-Null
            }
            $appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
            $existingVDir = & $appcmd list vdir "Default Web Site/CRL" 2>$null
            if (-not $existingVDir) {
                & $appcmd add vdir /app.name:"Default Web Site/" /path:/CRL /physicalPath:"$WebFolderPath" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { _Log "WARNING: appcmd add vdir CRL exit $LASTEXITCODE" }
            }

            # Enable double-escaping (idempotent)
            _Log "Enabling double-escaping on CRL vdir..."
            & $appcmd set config "Default Web Site/CRL" /section:system.webServer/security/requestFiltering /allowDoubleEscaping:true /commit:apphost 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { _Log "WARNING: appcmd set allowDoubleEscaping exit $LASTEXITCODE" }

            # Copy Root CA files to web folder
            _Log "Copying Root CA files to web folder..."
            $rootFiles = Get-ChildItem -Path $RootCAFilesPath -ErrorAction SilentlyContinue
            foreach ($f in $rootFiles) {
                Copy-Item -Path $f.FullName -Destination $WebFolderPath -Force
            }

            # Publish root cert to AD (skip if already present by thumbprint)
            _Log "Publishing root cert to AD..."
            _Progress "Step 2: publishing root cert to AD (dspublish)..."
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
                # certutil -dspublish writes the root/NTAuth cert into the
                # Configuration NC -- the same write that 0x80070005 / 0x80072082s
                # in the post-dcpromo window. Wait for the directory to ACCEPT a
                # Config-NC write before publishing (happy path: ~1s, zero delay).
                _Log "  Verifying AD DS will ACCEPT a Configuration-NC write before dspublish (post-boot readiness probe)..."
                if (Wait-AdDsReady -TimeoutSec 120 -RequireWritable) {
                    _Log "  AD DS accepted a Configuration-NC probe write - proceeding with dspublish."
                } else {
                    _Log "  WARNING: AD DS Configuration-NC write not confirmed ready after 600s - proceeding; dspublish retries will remediate."
                }
                $publishMaxRetries = 10
                $publishSuccess = $false
                for ($publishAttempt = 1; $publishAttempt -le $publishMaxRetries; $publishAttempt++) {
                    & certutil.exe -dspublish -f $rootCertFile RootCA 2>&1 | Out-Null
                    $rcRoot = $LASTEXITCODE
                    & certutil.exe -dspublish -f $rootCertFile NTAuthCA 2>&1 | Out-Null
                    $rcNTAuth = $LASTEXITCODE
                    if ($rcRoot -eq 0 -and $rcNTAuth -eq 0) {
                        $publishSuccess = $true
                        break
                    }
                    _Log "WARNING: certutil -dspublish failed (attempt $publishAttempt/$publishMaxRetries): RootCA=$rcRoot, NTAuthCA=$rcNTAuth"
                    if ($publishAttempt -lt $publishMaxRetries) {
                        # RANGE_CONSTRAINT/-2147024891 (0x80070005) are the post-dcpromo
                        # window: force an immediate schema reload and wait for a
                        # writable Config-NC before retrying instead of a blind sleep.
                        Invoke-SchemaCacheReload | Out-Null
                        $backoffSec = [Math]::Min(90, 15 * $publishAttempt)
                        _Log "  Waiting up to ${backoffSec}s for AD DS Config-NC write readiness before retry..."
                        if (-not (Wait-AdDsReady -TimeoutSec $backoffSec -RequireWritable)) { Start-Sleep -Seconds 5 }
                    }
                }
                if ($publishSuccess) {
                    _Log "  Root CA cert published to AD"
                } else {
                    _Log "ERROR: certutil -dspublish failed after $publishMaxRetries attempts. Subordinate CA install will likely fail."
                }
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
CRLDeltaPeriodUnits=0
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
                Install-FeatureBounded -Name 'Adcs-Cert-Authority' -Label 'Step 2: installing ADCS role' | Out-Null

                # Enterprise Subordinate CA setup writes Enrollment Services /
                # NTAuth objects to the Configuration NC (even with -OutputCertRequestFile).
                # On a freshly promoted forest that publish is rejected with
                # 0x80072082 ERROR_DS_RANGE_CONSTRAINT for a transient window that
                # closes purely on elapsed time. Wait for the directory to ACCEPT a
                # Config-NC WRITE (not just be reachable) before launching setup, so
                # attempt 1 waits out the window instead of burning a destructive
                # install/uninstall cycle. Happy path: probe write succeeds in ~1s.
                _Log "Verifying AD DS will ACCEPT a Configuration-NC write before subordinate CA config (post-boot readiness probe)..."
                _Progress "waiting for AD DS to accept a Configuration-NC write (pre-install gate)..."
                if (Wait-AdDsReady -TimeoutSec 120 -RequireWritable) {
                    _Log "AD DS accepted a Configuration-NC probe write - directory is ready for the subordinate CA publish."
                } else {
                    _Log "WARNING: AD DS Configuration-NC write not confirmed ready after 120s - proceeding; the retry loop will remediate transient publish errors."
                }

                # Install Enterprise Subordinate CA with offline request file, with
                # retry + remediation mirroring the single-tier Enterprise Root CA
                # path: a generous time budget (~45 min) that OUTLASTS the post-boot
                # window (PROVEN to close as late as boot+64min); on RANGE_CONSTRAINT
                # force an IMMEDIATE schema cache reload; one-shot NTDS field-
                # engineering logging captures the exact offending attribute if it
                # still fails. Happy path is untouched (attempt 1 runs immediately).
                _Log "Installing Enterprise Subordinate CA '$IntCAName' (offline enrollment)..."
                $subConfigured = $false
                $subLastErr = $null
                $maxSubTries = 6
                $feEnabled = $false
                $feLevelPrior = $null
                $subLoopStart = Get-Date
                # SHORT in-guest budget: fail FAST and hand back to the host (cheap session-
                # refresh = the real settling-token fix, then reboot). Diag + ladder fire early.
                $escDiagAt = 2       # first auto-diagnostic snapshot
                $escTier1At = 4      # token + AD refresh (bounded, no reboot)
                $escTier2At = 5      # hard-reset CA config (no reboot)
                $subLastClass = 'Unknown'
                $subNeedsHostReboot = $false
                try {
                    for ($subTry = 1; $subTry -le $maxSubTries; $subTry++) {
                        try {
                            _Log "Installing Enterprise Subordinate CA '$IntCAName' (attempt $subTry/$maxSubTries)..."
                            _Progress "installing subordinate CA (attempt $subTry/$maxSubTries)..."
                            Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa `
                                -CACommonName $IntCAName `
                                -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
                                -KeyLength 2048 `
                                -HashAlgorithmName SHA256 `
                                -OutputCertRequestFile $reqFile `
                                -OverwriteExistingKey `
                                -WarningAction SilentlyContinue `
                                -Force | Out-Null
                            $subConfigured = $true
                            break
                        }
                        catch {
                            $subLastErr = $_.Exception.Message
                            # A prior/interrupted run may have already produced the CSR
                            # (or installed the role) -- that's success, not a retry.
                            if ($subLastErr -match 'already installed' -and (Test-Path $reqFile)) {
                                _Log "CA role already installed and CSR exists - accepting."
                                $subConfigured = $true
                                break
                            }
                            if ($subLastErr -match 'already installed') {
                                # CA installed but the CSR file is GONE. The old recovery ran
                                # `certreq -new`, which (a) HANGS with no timeout in a non-
                                # interactive PSDirect session (PROVEN: step2 wedged here on a
                                # healthy, idle PL-HOAGIE -- durable log's last line was
                                # "Generating new CSR via certreq...") and (b) generates a
                                # MISMATCHED key that does NOT correspond to the installed CA.
                                # Correct recovery: tear down the partial CA so the NEXT attempt
                                # does a clean Install-AdcsCertificationAuthority that regenerates
                                # a matching key + CSR. Bounded by maxSubTries.
                                _Log "CA already installed but CSR file missing -- uninstalling the partial CA so the next attempt reinstalls cleanly (avoids the hang-prone, key-mismatching certreq -new path)."
                                _Progress "tearing down partial CA (CSR missing) for a clean reinstall..."
                                try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
                                Start-Sleep -Seconds 5
                                continue
                            }
                            # Classify the post-dcpromo AD-publish window as transient.
                            $isRange = $subLastErr -match '0x80072082|ERROR_DS_RANGE_CONSTRAINT|acceptable range'
                            $transient = $isRange -or ($subLastErr -match '0x8007200E|ERROR_DS_BUSY|0x8007200F|ERROR_DS_UNWILLING_TO_PERFORM|0x80072030|ERROR_DS_NO_SUCH_OBJECT|0x80070005|access is denied|directory service')
                            if (-not $transient) {
                                _Log "Non-transient subordinate CA install error on attempt $subTry : $subLastErr"
                                throw
                            }
                            _Log "Transient AD-publish error on attempt $subTry : $subLastErr -- remediating (tear down partial config, wait for AD, retry)."
                            try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
                            try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch {}
                            if ($isRange) {
                                if (Invoke-SchemaCacheReload) { _Log "Forced schema cache reload (schemaUpdateNow) to clear the post-dcpromo publish window." }
                                else { _Log "schemaUpdateNow reload attempt did not take (continuing)." }
                                if (-not $feEnabled) {
                                    $feLevelPrior = Set-NtdsFieldEngineering -Level 5
                                    $feEnabled = $true
                                    _Log "Enabled NTDS '15 Field Engineering'=5 to capture the exact constraint attribute on the next attempt (prior=$feLevelPrior)."
                                }
                            }
                            # In-flight advanced diagnostics + evidence-gated escalation ladder.
                            # These fire only at thresholds, so a normal timing-window
                            # deploy (which clears within the budget) is never disturbed.
                            if ($subTry -eq $escDiagAt) {
                                _Progress "attempt $subTry failed; running advanced diagnostics..."
                                $d = Invoke-PkiPublishDiagnostics -Since $subLoopStart -Reason "attempt $subTry still failing"
                                $subLastClass = $d.Class
                            }
                            if ($subTry -eq $escTier1At) {
                                _Progress "escalation Tier1: token + AD refresh..."
                                Invoke-PkiTokenAdRefresh
                                $d = Invoke-PkiPublishDiagnostics -Since $subLoopStart -Reason "post-Tier1"
                                $subLastClass = $d.Class
                            }
                            if ($subTry -eq $escTier2At) {
                                _Progress "escalation Tier2: hard-reset CA config..."
                                Invoke-PkiRoleReinstall
                                # role reinstall drops the CSR path expectation; nothing else to reset.
                            }
                            _Progress "attempt $subTry failed; waiting for AD DS write-readiness..."
                            Wait-AdDsReady -TimeoutSec 180 -RequireWritable | Out-Null
                            $backoffSec = [Math]::Min(45, 15 * $subTry)
                            _Log "Attempt $subTry/$maxSubTries failed (post-dcpromo AD settling); waiting ${backoffSec}s before retry..."
                            $boDeadline = (Get-Date).AddSeconds($backoffSec)
                            while ((Get-Date) -lt $boDeadline) {
                                $rem = [int]($boDeadline - (Get-Date)).TotalSeconds
                                _Progress "attempt $subTry/$maxSubTries failed; next retry in ${rem}s"
                                Start-Sleep -Seconds 5
                            }
                        }
                    }
                }
                finally {
                    if ($feEnabled) {
                        $feRestore = 0
                        if ($null -ne $feLevelPrior) { $feRestore = [int]$feLevelPrior }
                        Set-NtdsFieldEngineering -Level $feRestore | Out-Null
                        _Log "Restored NTDS '15 Field Engineering' to $feRestore."
                        foreach ($ev in (Get-DsConstraintEvents -Since $subLoopStart)) { _Log "[DS diag] $ev" }
                    }
                }
                if (-not $subConfigured) {
                    # Final in-flight capture + reboot recommendation. When the failure
                    # is STRUCTURAL (Config-NC write refused and/or the running identity
                    # lacks Enterprise Admins) rather than the transient timing window,
                    # a host reboot of the DC (which re-establishes a fresh Kerberos PAC
                    # / token in a new session) is the next lever -- so flag it for the
                    # host to act on. A pure RangeConstraint (write probe succeeds) is
                    # NOT flagged: reboot only RESETS the settle clock and makes it worse.
                    $dFinal = Invoke-PkiPublishDiagnostics -Since $subLoopStart -Reason "final failure after $maxSubTries attempts"
                    $subLastClass = $dFinal.Class
                    if ($subLastClass -eq 'SettlingToken' -or $subLastClass -eq 'Structural' -or $subLastClass -eq 'AccessDenied' -or $subLastClass -eq 'TokenNoEA') {
                        $subNeedsHostReboot = $true
                        _Log "[PKI-ESC] Recommending a HOST-side session refresh (fresh Kerberos PAC), then reboot if needed: failure classified '$subLastClass' (not the transient RangeConstraint window). A token minted before the GC could expand Enterprise Admins is fixed by a NEW session/PAC."
                    }
                    else {
                        _Log "[PKI-ESC] NOT recommending a reboot: failure classified '$subLastClass' (reboot only resets the post-dcpromo settle clock)."
                    }
                    return @{ Success = $false; Log = $report.ToArray(); Error = "Enterprise Subordinate CA configuration failed after $maxSubTries attempts. Last error: $subLastErr"; NeedsHostReboot = $subNeedsHostReboot; FailClass = $subLastClass }
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
    # Step 2 with an evidence-gated HOST escalation. The in-guest loop runs its own
    # diagnostics + no-reboot ladder and, on exhaustion, returns NeedsHostReboot=$true
    # ONLY when the failure is a token/rights class (SettlingToken / TokenNoEA /
    # AccessDenied / Structural) rather than the transient RangeConstraint window.
    #
    # ROOT-CAUSE INSIGHT (settling-token race): the whole in-guest loop runs in ONE
    # cached PSDirect session whose Kerberos token is minted ONCE. Enterprise Admins
    # is a UNIVERSAL group expanded by the GC; a token minted before the freshly
    # promoted first DC's GC could expand it LACKS the EA SID even though the account
    # IS an EA -- so every in-guest attempt rides the same EA-less token and can NEVER
    # self-heal, which is why only a re-run (new logon/PAC) fixed it historically.
    # So the FIRST host lever is CHEAP: drop the cached session (Remove-VmSessionFromCache)
    # so the next Invoke-VmCommand mints a FRESH logon token that now carries EA -- no
    # reboot. Only if a fresh session STILL fails do we reboot (also yields a fresh PAC).
    $step2Args = $intCAName, $intCAServer, $domainName, $webURL, $webFolderPath, $rootCAName, $rootCAFilesPath, $intCAFilesPath
    $refreshedSessionForStep2 = $false
    $rebootedForStep2 = $false
    while ($true) {
        # -AsJob is REQUIRED for -TimeoutSeconds to be enforced (Invoke-VmCommand ignores
        # the timeout on the synchronous path -> a wedged in-guest command hangs the host
        # forever). Absolute ceiling large enough for the ~45-min ladder + diagnostics.
        $result2 = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName `
            -ScriptBlock $step2Script `
            -ArgumentList $step2Args `
            -DisplayName "TwoTierPKI Step 2: Prepare Intermediate CA" `
            -AsJob -PollProgress -TimeoutSeconds 300

        $step2Ok = Test-PKIStepResult -Result $result2 -StepName "Step 2" -LogPrefix "TwoTierPKI" -LogSource "CA" -LogOnly
        if ($step2Ok) { break }

        $sb2 = $null
        if ($result2 -and $result2.ScriptBlockOutput) { $sb2 = $result2.ScriptBlockOutput } else { $sb2 = $result2 }
        $cls2 = if ($sb2 -and $sb2.FailClass) { "$($sb2.FailClass)" } elseif (-not ($result2 -and $result2.ScriptBlockOutput)) { "channel-died/timeout" } else { "unknown" }

        # Pull the DURABLE guest-side step2 log so the host log shows WHERE it wedged --
        # the buffered in-guest $report is LOST when a stalled job is killed, which is why
        # "review the logs, you never find anything." Bounded (-AsJob -TimeoutSeconds 60)
        # so a dead channel can't hang the host here too (a synchronous Copy-Item
        # -FromSession WOULD hang, so we pull the CONTENT through the bounded job instead
        # of copying the file). Pulled BEFORE the retry re-runs step2 (which overwrites the
        # guest file). We save the WHOLE file as a standalone artifact in the host logs\
        # folder -- so it syncs back like the Phase 11 guest logs -- AND echo the last 40
        # lines inline into the main log so the wedge point is visible there too.
        try {
            $fullRes = Invoke-VmCommand -VmName $issuingCAVMName -VmDomainName $domainName -DisplayName "Pull Step2 guest log" -SuppressLog `
                -AsJob -TimeoutSeconds 60 `
                -ScriptBlock { if (Test-Path "C:\staging\MemLabs-PKI-Step2.log") { Get-Content -LiteralPath "C:\staging\MemLabs-PKI-Step2.log" } }
            $full = if ($fullRes -and $fullRes.ScriptBlockOutput) { $fullRes.ScriptBlockOutput } else { $fullRes }
            if ($full) {
                $fullLines = @($full)
                # Standalone artifact in logs\ (per-VM + timestamp so retries/reboots don't clobber).
                try {
                    $logsDir = Split-Path $Common.LogPath -Parent
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $stepLogPath = Join-Path $logsDir "$issuingCAVMName-PKI-Step2-$stamp.log"
                    $fullLines | Out-File -LiteralPath $stepLogPath -Encoding utf8 -Force -ErrorAction Stop
                    Write-Log "[TwoTierPKI] Saved full guest step2 log (class=$cls2, $($fullLines.Count) lines) -> $stepLogPath"
                }
                catch { Write-Log "[TwoTierPKI] could not save full guest step2 log to logs folder: $($_.Exception.Message)" -Warning }
                # Inline tail (last 40) so the wedge point shows in the main VMBuild log too.
                $tail = if ($fullLines.Count -gt 40) { $fullLines[-40..-1] } else { $fullLines }
                Write-Log "[TwoTierPKI] ---- last 40 lines of the DURABLE guest step2 log (class=$cls2) ----"
                foreach ($tl in $tail) { Write-Log "[TwoTierPKI][guest-step2] $tl" }
                Write-Log "[TwoTierPKI] ---- end guest step2 log ----"
            }
            else {
                Write-Log "[TwoTierPKI] Could not pull the guest step2 log (channel may be dead or file missing)." -Warning
            }
        }
        catch { Write-Log "[TwoTierPKI] guest step2 log pull errored: $($_.Exception.Message)" -Warning }

        # Tier A (cheap, no reboot): drop the cached session and retry. A FRESH session
        # recovers BOTH failure modes we actually see: (1) a DEAD PSDirect channel (guest
        # host died / stalled under load -> no ScriptBlockOutput) and (2) the settling-token
        # race (fresh Kerberos PAC now carries Enterprise Admins). Fire on ANY step2 failure.
        if (-not $refreshedSessionForStep2) {
            Write-Log "[TwoTierPKI] Step 2 failed (class=$cls2). Dropping the cached PSDirect session so the retry mints a FRESH channel + logon token, then retrying Step 2 (no reboot)..." -Warning
            try { Remove-VmSessionFromCache -VmName $issuingCAVMName } catch { Write-Log "[TwoTierPKI] session eviction note: $($_.Exception.Message)" }
            $refreshedSessionForStep2 = $true
            continue
        }

        # Tier B (reboot): the fresh session ALSO failed -> reboot the CA/DC ONCE (clears a
        # wedged guest + gives a fresh PAC), then retry. Bounded to a single reboot.
        if (-not $rebootedForStep2) {
            Write-Log "[TwoTierPKI] Fresh session did not clear it (class=$cls2). Rebooting the CA/DC $issuingCAVMName ONCE from the host, then retrying Step 2..." -Warning
            try {
                $rebooted = Restart-VM2Smart -Name $issuingCAVMName -AllowTurnOff -Reason "PKI subordinate CA failure ($cls2) - host reboot tier"
                Write-Log "[TwoTierPKI] $issuingCAVMName restart issued (restarted=$rebooted); waiting for it to come back ready for PSDirect/AD..."
                $null = Wait-ForVm -VmName $issuingCAVMName -PathToVerify "C:\Users" -VmDomainName $domainName -TimeoutMinutes 15
            }
            catch {
                Write-Log "[TwoTierPKI] reboot/wait of $issuingCAVMName errored: $($_.Exception.Message) - not retrying further." -Warning
                return $false
            }
            try { Remove-VmSessionFromCache -VmName $issuingCAVMName } catch {}
            $rebootedForStep2 = $true
            continue
        }
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
                & certutil.exe -setreg CA\CRLDeltaPeriodUnits 0 | Out-Null
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
