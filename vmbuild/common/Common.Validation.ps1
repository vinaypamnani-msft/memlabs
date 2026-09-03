# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
function Add-ValidationMessage {
    param (
        [string]$Message,
        [object]$ReturnObject,
        [switch]$Failure,
        [switch]$Warning,
        [switch]$Information
    )
    Write-Log -Verbose $Message

    # Informational messages are NON-BLOCKING advisories / auto-fix notices.
    # They must NOT increment Problems (the .Valid gate keys on Problems) and
    # must NOT land in .Message (which Convert-ValidationMessages / the menu
    # funnel into hard error lines). They are collected separately in
    # .InfoMessage so callers can surface them as advisories without failing
    # validation. Short-circuit here before the blocking bookkeeping below.
    if ($Information.IsPresent) {
        if (-not ($ReturnObject.PSObject.Properties.Name -contains 'Informational')) {
            $ReturnObject | Add-Member -NotePropertyName Informational -NotePropertyValue 0 -Force
        }
        if (-not ($ReturnObject.PSObject.Properties.Name -contains 'InfoMessage')) {
            $ReturnObject | Add-Member -NotePropertyName InfoMessage -NotePropertyValue ([System.Text.StringBuilder]::new()) -Force
        }
        $ReturnObject.Informational += 1
        [void]$ReturnObject.InfoMessage.AppendLine($Message)
        try {
            $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
            $callerName = if ($caller) { $caller.FunctionName } else { '<unknown>' }
            $callerLine = if ($caller) { $caller.ScriptLineNumber } else { 0 }
            Write-Log "[ValidationInformation] $Message  (from $callerName`:$callerLine)" -LogOnly
        }
        catch {
            Write-Log "[ValidationInformation] $Message" -LogOnly
        }
        return
    }

    $ReturnObject.Problems += 1
    [void]$ReturnObject.Message.AppendLine($Message)


    if ($Failure.IsPresent) {
        $ReturnObject.Failures += 1
        # Log every failure with caller context so we can correlate menu
        # errors back to the validation site (and time) that produced them.
        try {
            $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
            $callerName = if ($caller) { $caller.FunctionName } else { '<unknown>' }
            $callerLine = if ($caller) { $caller.ScriptLineNumber } else { 0 }
            Write-Log "[ValidationFailure] $Message  (from $callerName`:$callerLine)" -LogOnly
        } catch {
            Write-Log "[ValidationFailure] $Message" -LogOnly
        }
    }

    if ($Warning.IsPresent) {
        $ReturnObject.Warnings += 1
        try {
            $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1)
            $callerName = if ($caller) { $caller.FunctionName } else { '<unknown>' }
            $callerLine = if ($caller) { $caller.ScriptLineNumber } else { 0 }
            Write-Log "[ValidationWarning] $Message  (from $callerName`:$callerLine)" -LogOnly
        } catch {
            Write-Log "[ValidationWarning] $Message" -LogOnly
        }
    }
}

function Write-ValidationMessages {

    param (
        [object]$TestObject
    )

    $messages = $($TestObject.Message) -split "\r\n"
    foreach ($msg in $messages.Trim()) {
        Write-RedX $msg
    }
}
function Convert-ValidationMessages {

    param (
        [object]$TestObject
    )

    $messages = $($TestObject.Message) -split "\r\n"
    foreach ($msg in $messages.Trim()) {
        if (-not [string]::IsNullOrWhiteSpace($msg)) {
            Add-ErrorMessage -message $msg
        }
    }
}

function Test-ValidVmOptions {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    # prefix
    # vmOptions.prefix is OPTIONAL. When blank, VM names equal their base names.
    # The isolation the prefix used to guarantee is now enforced directly on the
    # names themselves by the always-on cross-domain name-conflict check in
    # Test-Configuration, so neither a blank prefix nor a prefix shared with
    # another domain is a failure by itself.

    # basePath
    if (-not $ConfigObject.vmOptions.basePath) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath not present in vmOptions. You must specify the base path where the Virtual Machines will be created." -ReturnObject $ReturnObject -Failure
    }
    else {
        if (-not $ConfigObject.vmOptions.basepath.Contains(":\")) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify the full path. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
        }
        else {
            $driveLetter = $ConfigObject.vmOptions.basepath.Substring(0, 1)
            if (-not (Test-Path "$driveLetter`:\")) {
                Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify a valid path. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
            }

            if ($driveLetter -in "C", "D", "Z") {
                Add-ValidationMessage -Message "VM Options Validation: vmOptions.basePath value [$($ConfigObject.vmOptions.basePath)] is invalid. You must specify a drive letter other than C/D/Z. For example: E:\VirtualMachines" -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # domainName
    if (-not $ConfigObject.vmOptions.domainName) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName not present in vmOptions. You must specify the Domain name." -ReturnObject $ReturnObject -Failure
    }
    else {

        # contains .
        if (-not $ConfigObject.vmOptions.domainName.Contains(".")) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName value [$($ConfigObject.vmOptions.domainName)] is invalid. You must specify the Full Domain name. For example: contoso.com" -ReturnObject $ReturnObject -Failure
        }

        # valid domain name
        $pattern = "^((?!-)[A-Za-z0-9-]{1,63}(?<!-)\.)+[A-Za-z]{2,6}$"
        if (-not ($ConfigObject.vmOptions.domainName -match $pattern)) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName value [$($ConfigObject.vmOptions.domainName)] contains invalid characters, is too long, or too short. You must specify a valid Domain name. For example: contoso.com." -ReturnObject $ReturnObject -Failure
        }

        #$netBiosDomain = $ConfigObject.vmOptions.domainName.Split(".")[0]
        $netBiosDomain = $ConfigObject.vmOptions.domainNetBiosName
        if ($netBiosDomain.Length -gt 15) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName [$($ConfigObject.vmOptions.domainName)] is too long. Netbios domain name [$netBiosDomain] must be less than 15 chars." -ReturnObject $ReturnObject -Failure
        }

        if ($netBiosDomain.Length -lt 1) {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.domainName  [$($ConfigObject.vmOptions.domainName)] is too short. Must be at least 1 chars." -ReturnObject $ReturnObject -Failure
        }
    }

    # adminName
    if (-not $ConfigObject.vmOptions.adminName) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.adminName not present in vmOptions. You must specify the Domain Admin user name that will be created." -ReturnObject $ReturnObject -Failure
    }
    else {

        Test-ValidUserName -name $ConfigObject.vmoptions.adminName -vmName "VM Options"
    }

    # network
    if (-not $ConfigObject.vmOptions.network) {
        Add-ValidationMessage -Message "VM Options Validation: vmOptions.network not present in vmOptions. You must specify the Network subnet for the environment." -ReturnObject $ReturnObject -Failure
    }
    else {
        $pattern1 = "^(192.168)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]).0)$"
        $pattern2 = "^(10)(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){2,2}.0$"
        $pattern3 = "^(172).(1[6-9]|2[0-9]|3[0-1])(.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])).0$"

        

        if ($ConfigObject.vmOptions.network -eq "10.250.250.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'Cluster'. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }

        if ($ConfigObject.vmOptions.network -eq "10.250.251.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'ClusterV2'. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }

        if ($ConfigObject.vmOptions.network -eq "10.1.0.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'External'. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }


        if ($ConfigObject.vmOptions.network -eq "172.31.250.0") {
            Add-ValidationMessage -Message "VM Options Validation: vmOptions.network [$($ConfigObject.vmoptions.network)] value is reserved for 'Internet' clients. Please use a different subnet." -ReturnObject $ReturnObject -Warning
        }


        $networks = @($ConfigObject.vmOptions.network)

        foreach ($vm in $($ConfigObject.virtualMachines)) {
            if ($vm.network) {
                #write-log "Adding $($vm.network)"
                $networks += $vm.network
            }
        }
        $existingSubnets = Get-List -Type Network -SmartUpdate 
        foreach ($testNetwork in $networks) {
            write-log "testing $testNetwork" -Verbose
            if (-not ($testNetwork -match $pattern1 -or $testNetwork -match $pattern2 -or $testNetwork -match $pattern3)) {
                Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] value is invalid. You must specify a valid Class C Subnet. For example: 192.168.1.0" -ReturnObject $ReturnObject -Failure
            }

            $existingSubnet = $existingSubnets | Where-Object { $_.Network -eq $($testNetwork) }
            if ($existingSubnet) {
                if (-not ($($ConfigObject.vmoptions.domainName) -in $($existingSubnet.Domain))) {
                    Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] with vmOptions.domainName [$($ConfigObject.vmoptions.domainName)] is in use by existing Domain [$($existingSubnet.Domain)]. You must specify a different network" -ReturnObject $ReturnObject -Failure
                }

                $CASorPRIorSEC = ($ConfigObject.virtualMachines | where-object { $_.role -in "CAS", "Primary", "Secondary" -and (-not $_.Network) -and (-not $_.Hidden) })
                if ($CASorPRIorSEC) {
                    $existingCASorPRIorSEC = @()
                    $existingCASorPRIorSEC += Get-List -Type VM -SmartUpdate | Where-Object { $_.Network -eq $($testNetwork) } | Where-Object { ($_.Role -in "CAS", "Primary", "Secondary") }
                    if ($existingCASorPRIorSEC.Count -gt 0) {
                        if ($ConfigObject.vmOptions.domainName -ne $existingSubnet.Domain) {
                            Add-ValidationMessage -Message "VM Options Validation: Network [$($testNetwork)] is in use by an existing SiteServer in [$($existingSubnet.Domain)]. You must specify a different network" -ReturnObject $ReturnObject -Warning
                        }
                    }

                }
            }
        }


    }
}

function Resolve-DomainVmReference {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $ConfigObject,
        [Parameter(Mandatory = $false)]
        [string] $VmReference
    )

    if ([string]::IsNullOrWhiteSpace($VmReference)) { return $null }

    $knownVmNames = @($ConfigObject.virtualMachines | ForEach-Object { $_.vmName })
    $resolved = Resolve-ConfigVmReference -VmReference $VmReference -VmNames $knownVmNames -Prefix $ConfigObject.vmOptions.prefix

    $vmInConfig = $ConfigObject.virtualMachines | Where-Object { $_.vmName -ieq $resolved } | Select-Object -First 1
    if ($vmInConfig) {
        return [PSCustomObject]@{
            Exists       = $true
            ResolvedName = $vmInConfig.vmName
            Vm           = $vmInConfig
            InConfig     = $true
        }
    }

    $existingVm = $null
    if ($ConfigObject.vmOptions -and $ConfigObject.vmOptions.domainName) {
        try {
            $existingDomainVms = @(Get-List -Type VM -DomainName $ConfigObject.vmOptions.domainName)
            if ($existingDomainVms.Count -gt 0) {
                $existingNames = @($existingDomainVms | ForEach-Object { $_.vmName })
                $resolvedExisting = Resolve-ConfigVmReference -VmReference $resolved -VmNames $existingNames -Prefix $ConfigObject.vmOptions.prefix
                $existingVm = $existingDomainVms | Where-Object { $_.vmName -ieq $resolvedExisting } | Select-Object -First 1
                if ($existingVm) {
                    $resolved = $existingVm.vmName
                }
            }
        }
        catch {
            $existingVm = $null
        }
    }

    return [PSCustomObject]@{
        Exists       = [bool]$existingVm
        ResolvedName = $resolved
        Vm           = $existingVm
        InConfig     = $false
    }
}

function Test-ValidCmOptions {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    # Resolve cmOptions wherever it lives now (root, top-level site server, or any
    # CAS/Primary in add-to-existing configs). After Move-CmOptionsToTopLevelSiteServer
    # the block no longer lives at $ConfigObject.cmOptions for new configs.
    $cmOptions = Get-ConfigCmOptions -Config $ConfigObject
    if (-not $cmOptions) {
        Add-ValidationMessage -Message "CM Options Validation: no cmOptions block found on the config or on any CAS/Primary VM." -ReturnObject $ReturnObject -Failure
        return
    }

    # version
    if ($Common.Supported.CMVersions -notcontains $cmOptions.version) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions contains invalid CM Version [$($cmOptions.version)]. Must be one of [$($Common.Supported.CMVersions -join ',')]." -ReturnObject $ReturnObject -Failure
    }

    # install
    if ($cmOptions.install -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.install has an invalid value [$($cmOptions.install)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # usePKI
    if ($cmOptions.usePKI -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.usePKI has an invalid value [$($cmOptions.usePKI)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    # EnableBLM
    if ($null -ne $cmOptions.EnableBLM -and $cmOptions.EnableBLM -isnot [bool]) {
        Add-ValidationMessage -Message "CM Options Validation: cmOptions.EnableBLM has an invalid value [$($cmOptions.EnableBLM)]. Value must be either 'true' or 'false' without any quotes." -ReturnObject $ReturnObject -Failure
    }

    if ($cmOptions.EnableBLM) {
        # BLM requires ConfigMgr 2002 or later
        $blmMinVersion = "2002"
        $cmVer = $cmOptions.Version
        if ($cmVer -and $cmVer -ne "current-branch" -and $cmVer -ne "tech-preview" -and $cmVer -lt $blmMinVersion) {
            Add-ValidationMessage -Message "CM Options Validation: BitLocker Management requires ConfigMgr version 2002 or later. Current version is [$cmVer]." -ReturnObject $ReturnObject -Failure
        }

        # Warn if domain-joined client VMs lack TPM (non-domain roles excluded — they don't receive BLM policy)
        $clientVMs = $ConfigObject.virtualMachines | Where-Object { $_.role -eq "DomainMember" -and -not $_.Hidden }
        if ($clientVMs) {
            $noTPM = $clientVMs | Where-Object { $_.tpmEnabled -eq $false }
            if ($noTPM) {
                Add-ValidationMessage -Message "BLM Warning: The following client VMs have tpmEnabled=false and will require a startup password for BitLocker: $($noTPM.vmName -join ', '). Consider enabling vTPM for unattended encryption." -ReturnObject $ReturnObject -Warning
            }
        }

        # Reject BitLocker on non-domain roles
        $badBLM = $ConfigObject.virtualMachines | Where-Object { $_.BitLocker -eq $true -and $_.role -in 'InternetClient', 'WorkgroupMember', 'AADClient' -and -not $_.Hidden }
        if ($badBLM) {
            Add-ValidationMessage -Message "BLM Validation: BitLocker cannot be used on non-domain-joined VMs (they never receive ConfigMgr BLM policy). Removing BitLocker from: $($badBLM.vmName -join ', ')." -ReturnObject $ReturnObject -Warning
            foreach ($vm in $badBLM) { $vm.PsObject.Members.Remove("BitLocker") }
        }
    }

    # Office deployment validation
    $officeVMs = $ConfigObject.virtualMachines | Where-Object { $_.installOffice -and $_.installOffice -ne $false -and -not $_.Hidden }
    if ($officeVMs) {
        $hasPrimary = $ConfigObject.virtualMachines | Where-Object { $_.role -eq 'Primary' -and -not $_.Hidden }
        if (-not $hasPrimary) {
            Add-ValidationMessage -Message "Office Validation: installOffice is set on $($officeVMs.vmName -join ', ') but no Primary site server exists to create the SCCM application deployment. Removing installOffice." -ReturnObject $ReturnObject -Warning
            foreach ($vm in $officeVMs) { $vm.installOffice = $false }
        }
        elseif (-not $cmOptions.PrePopulateObjects) {
            Add-ValidationMessage -Message "Office Validation: installOffice requires PrePopulateObjects (Office deployment runs during perfloading). Removing from: $($officeVMs.vmName -join ', ')." -ReturnObject $ReturnObject -Warning
            foreach ($vm in $officeVMs) { $vm.installOffice = $false }
        }

        # Reject Office on server OS
        $serverOffice = $officeVMs | Where-Object { $_.operatingSystem -like '*Server*' }
        if ($serverOffice) {
            Add-ValidationMessage -Message "Office Validation: installOffice is not supported on Server OS. Removing from: $($serverOffice.vmName -join ', ')." -ReturnObject $ReturnObject -Warning
            foreach ($vm in $serverOffice) { $vm.installOffice = $false }
        }

        # Reject Office when pushClient is disabled
        $noPushOffice = $officeVMs | Where-Object { $_.pushClient -eq $false }
        if ($noPushOffice) {
            Add-ValidationMessage -Message "Office Validation: installOffice requires pushClient (SCCM client agent needed for deployment). Removing from: $($noPushOffice.vmName -join ', ')." -ReturnObject $ReturnObject -Warning
            foreach ($vm in $noPushOffice) { $vm.installOffice = $false }
        }
    }

    # pushClient target-site validation. pushClient is a site code string (the
    # site to push the client from) or $false. Verify each explicit site code
    # exists, and enforce one-site-per-subnet (a subnet maps to exactly one
    # boundary group, so two VMs on the same subnet cannot push to different
    # sites).
    try {
        $pushRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
        $pushVMs = @($ConfigObject.virtualMachines | Where-Object {
                $_.role -in $pushRoles -and -not $_.Hidden -and ($_.pushClient -is [string]) -and $_.pushClient
            })
        if ($pushVMs.Count -gt 0) {
            $eligiblePush = @(Get-EligiblePushSites -Config $ConfigObject -Domain $ConfigObject.vmOptions.domainName)
            $validCodes = @($eligiblePush | ForEach-Object { $_.SiteCode })

            # 1) Unknown site code -> re-resolve to a real one (or $false).
            $badSite = @($pushVMs | Where-Object { $validCodes -notcontains $_.pushClient })
            if ($badSite.Count -gt 0) {
                foreach ($vm in $badSite) {
                    $fixed = Resolve-PushClientSite -VM $vm -Config $ConfigObject -Domain $ConfigObject.vmOptions.domainName -EligibleSites $eligiblePush
                    $vm.pushClient = $fixed
                }
                Add-ValidationMessage -Message "Client Push Validation: pushClient on $($badSite.vmName -join ', ') referenced a site code that does not exist; reset to the resolved site (or disabled where no site applies)." -ReturnObject $ReturnObject -Information
                $pushVMs = @($pushVMs | Where-Object { ($_.pushClient -is [string]) -and $_.pushClient })
            }

            # 2) One-site-per-subnet. Group the still-valid pushed VMs by subnet.
            $defaultNet = $ConfigObject.vmOptions.network
            $bySubnet = @{}
            foreach ($vm in $pushVMs) {
                $net = if ($vm.network) { $vm.network } else { $defaultNet }
                if (-not $net) { continue }
                if (-not $bySubnet.ContainsKey($net)) { $bySubnet[$net] = @() }
                $bySubnet[$net] += $vm
            }
            foreach ($net in $bySubnet.Keys) {
                $vmsOnNet = @($bySubnet[$net])
                $distinct = @($vmsOnNet | ForEach-Object { $_.pushClient } | Select-Object -Unique)
                # A subnet that hosts its own Primary/Secondary site server is
                # bound to that site (the site server's BG always covers its
                # subnet), so EVERY pushed VM there must target it -- even a lone
                # mis-set client (distinct count 1).
                $ownSite = $eligiblePush | Where-Object { $_.Network -eq $net } | Select-Object -First 1
                if ($ownSite) {
                    $target = $ownSite.SiteCode
                    $offenders = @($vmsOnNet | Where-Object { $_.pushClient -ne $target })
                    if ($offenders.Count -gt 0) {
                        foreach ($vm in $offenders) { $vm.pushClient = $target }
                        Add-ValidationMessage -Message "Client Push Validation: subnet $net hosts site server $target; $($offenders.vmName -join ', ') were repointed to push from $target (a site server's subnet maps to its own boundary group)." -ReturnObject $ReturnObject -Information
                    }
                }
                elseif ($distinct.Count -gt 1) {
                    # No site server on this subnet: coerce all to the first seen.
                    $target = $distinct[0]
                    foreach ($vm in $vmsOnNet) { $vm.pushClient = $target }
                    Add-ValidationMessage -Message "Client Push Validation: VMs on subnet $net targeted different sites ($($distinct -join ', ')). A subnet maps to one boundary group; all were set to push from $target." -ReturnObject $ReturnObject -Information
                }
            }
        }
    }
    catch {
        Write-Log "pushClient validation skipped: $($_.Exception.Message)" -LogOnly -Warning
    }

    if ($cmOptions.usePKI) {
        # When UsePKI is enabled, pkiOptions must have a valid IssuingCAVM
        if (-not $ConfigObject.pkiOptions) {
            $ConfigObject | Add-Member -MemberType NoteProperty -Name "pkiOptions" -Value ([PSCustomObject]@{
                EnablePKI       = $true
                IssuingCAVM     = ""
                UseOfflineRoot  = $false
                OfflineRootCAVM = ""
            }) -Force
        }
        if (-not $ConfigObject.pkiOptions.EnablePKI) {
            $ConfigObject.pkiOptions.EnablePKI = $true
        }
        if ($ConfigObject.pkiOptions.EnablePKI) {
            $caRef = Resolve-DomainVmReference -ConfigObject $ConfigObject -VmReference $ConfigObject.pkiOptions.IssuingCAVM
            $caVM = if ($caRef) { $caRef.ResolvedName } else { $null }
            if ($caVM -and $caVM -ne $ConfigObject.pkiOptions.IssuingCAVM) {
                $ConfigObject.pkiOptions.IssuingCAVM = $caVM
            }
            if ($caVM) {
                if (-not $caRef.Exists) {
                    Add-ValidationMessage -Message "PKI Validation: pkiOptions.IssuingCAVM references VM [$caVM] which does not exist in the configuration." -ReturnObject $ReturnObject -Failure
                }
            }
        }
    }

    # Validate pkiOptions
    if ($ConfigObject.pkiOptions -and $ConfigObject.pkiOptions.EnablePKI) {
        # Validate IssuingCAVM references a real VM
        $caRef = Resolve-DomainVmReference -ConfigObject $ConfigObject -VmReference $ConfigObject.pkiOptions.IssuingCAVM
        $caVM = if ($caRef) { $caRef.ResolvedName } else { $null }
        if ($caVM -and $caVM -ne $ConfigObject.pkiOptions.IssuingCAVM) {
            $ConfigObject.pkiOptions.IssuingCAVM = $caVM
        }
        if ($caVM) {
            if (-not $caRef.Exists) {
                Add-ValidationMessage -Message "PKI Validation: pkiOptions.IssuingCAVM references VM [$caVM] which does not exist in the configuration." -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # Validate UseOfflineRoot / StandaloneRootCA
    $rootCAVMs = @($ConfigObject.virtualMachines | Where-Object { $_.role -eq "StandaloneRootCA" })
    $offlineRootEnabled = $ConfigObject.pkiOptions -and $ConfigObject.pkiOptions.UseOfflineRoot
    if ($rootCAVMs.Count -gt 1) {
        Add-ValidationMessage -Message "VM Validation: Only one StandaloneRootCA VM is allowed per configuration. Found $($rootCAVMs.Count)." -ReturnObject $ReturnObject -Failure
    }
    if ($rootCAVMs.Count -ge 1 -and -not $offlineRootEnabled) {
        Add-ValidationMessage -Message "VM Validation: StandaloneRootCA role requires UseOfflineRoot to be enabled in PKI Settings." -ReturnObject $ReturnObject -Failure
    }
    if ($offlineRootEnabled -and $rootCAVMs.Count -eq 0) {
        Add-ValidationMessage -Message "VM Validation: pkiOptions.UseOfflineRoot is enabled but no StandaloneRootCA VM is defined." -ReturnObject $ReturnObject -Failure
    }

    # Validate Proxy role -- at most one per configuration (a single domain
    # may only host one Squid forward proxy; clients use it via useProxy).
    $proxyVMs = @($ConfigObject.virtualMachines | Where-Object { $_.role -eq "Proxy" })
    if ($proxyVMs.Count -gt 1) {
        Add-ValidationMessage -Message "VM Validation: Only one Proxy VM is allowed per configuration. Found $($proxyVMs.Count)." -ReturnObject $ReturnObject -Failure
    }
    foreach ($pvm in $proxyVMs) {
        if (-not (Test-VmIsLinux -Vm $pvm)) {
            Add-ValidationMessage -Message "VM Validation: Proxy VM [$($pvm.vmName)] must be Linux (osFamily=Linux or operatingSystem like 'Ubuntu*'). Got osFamily=[$($pvm.osFamily)] operatingSystem=[$($pvm.operatingSystem)]." -ReturnObject $ReturnObject -Failure
        }
    }

    # Cross-domain enforcement: a domain may host at most one Proxy. If the
    # new config adds a Proxy and the domain already has one deployed (i.e.
    # not in this new config), reject -- two proxies would race for the
    # static .2 address and clients would have ambiguous routing.
    $newProxiesNotHidden = @($proxyVMs | Where-Object { -not $_.hidden })
    if ($newProxiesNotHidden.Count -ge 1 -and $ConfigObject.vmOptions.domainName) {
        $existingProxies = $null
        try {
            $existingProxies = @(Get-List -Type VM -DomainName $ConfigObject.vmOptions.domainName |
                    Where-Object { $_.role -eq 'Proxy' -and ($newProxiesNotHidden.vmName -notcontains $_.vmName) })
        }
        catch { $existingProxies = @() }
        if ($existingProxies.Count -gt 0) {
            $existingNames = ($existingProxies | Select-Object -ExpandProperty vmName) -join ', '
            $newNames = ($newProxiesNotHidden | Select-Object -ExpandProperty vmName) -join ', '
            Add-ValidationMessage -Message "VM Validation: Domain [$($ConfigObject.vmOptions.domainName)] already has a Proxy VM [$existingNames]. Only one Proxy per domain is allowed; remove [$newNames] from the config or delete the existing proxy first." -ReturnObject $ReturnObject -Failure
        }
    }

    # If any VM is opted-in to use the proxy (per-VM useProxy=true), a
    # reachable Proxy VM must exist -- either in this config or already
    # deployed (hidden) in the same domain. Otherwise clients get
    # configured to point at a host that doesn't exist and the host-side
    # ACLs deny-all their Internet egress. domainDefaults.UseProxyFor*
    # are seed-only hints for Add-NewVMForRole and are never consulted
    # at runtime / validation -- per-VM useProxy is the sole source of
    # truth.
    if (Get-Command Test-VmUsesProxy -ErrorAction SilentlyContinue) {
        $optedIn = @($ConfigObject.virtualMachines | Where-Object {
                -not $_.hidden -and (Test-VmUsesProxy -Vm $_ -DeployConfig $ConfigObject)
            })
        if ($optedIn.Count -gt 0 -and $proxyVMs.Count -eq 0) {
            $existingProxy = $null
            try {
                $existingProxy = @(Get-List -Type VM -DomainName $ConfigObject.vmOptions.domainName |
                        Where-Object { $_.role -eq 'Proxy' })
            }
            catch { $existingProxy = $null }
            if (-not $existingProxy -or $existingProxy.Count -eq 0) {
                $names = ($optedIn | Select-Object -ExpandProperty vmName) -join ', '
                Add-ValidationMessage -Message "VM Validation: one or more VMs have useProxy=true but no Proxy VM exists in this config or the existing '$($ConfigObject.vmOptions.domainName)' domain. Affected VM(s): $names. Add a Linux VM with role=Proxy, or set useProxy=false on the affected VMs." -ReturnObject $ReturnObject -Failure
            }
        }
    }
    if ($offlineRootEnabled -and $ConfigObject.pkiOptions.OfflineRootCAVM) {
        $offlineRootRefResult = Resolve-DomainVmReference -ConfigObject $ConfigObject -VmReference $ConfigObject.pkiOptions.OfflineRootCAVM
        $offlineRootRef = if ($offlineRootRefResult) { $offlineRootRefResult.ResolvedName } else { $null }
        if ($offlineRootRef -and $offlineRootRef -ne $ConfigObject.pkiOptions.OfflineRootCAVM) {
            $ConfigObject.pkiOptions.OfflineRootCAVM = $offlineRootRef
        }
        if (-not $offlineRootRefResult.Exists) {
            Add-ValidationMessage -Message "PKI Validation: pkiOptions.OfflineRootCAVM references VM [$offlineRootRef] which does not exist in the configuration." -ReturnObject $ReturnObject -Failure
        }
        elseif ($offlineRootRefResult.Vm -and $offlineRootRefResult.Vm.role -ne 'StandaloneRootCA') {
            Add-ValidationMessage -Message "PKI Validation: pkiOptions.OfflineRootCAVM references VM [$offlineRootRef] which does not have the StandaloneRootCA role." -ReturnObject $ReturnObject -Failure
        }
    }

}
function Test-MachineNameExists {
    param (
        [string] $name,
        [object] $ReturnObject,
        [object] $config

    )

    if (-not $name) {
        throw "Test-ValidMachineName called without a VMName"
    }

    write-log "Testing $name" -Verbose

    $nameWithPrefix = $config.vmOptions.prefix + $name
    $vm = Get-List2 -deployConfig $config -SmartUpdate | where-object { $_.vmName -eq $name -or $_.vmName -eq $nameWithPrefix }

    if (-not $vm) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid reference VM: $name. VM does not exist." -ReturnObject $ReturnObject -Warning
    }
}

function Test-ValidMachineName {
    param (
        [string] $name,
        [object] $ReturnObject,
        [switch] $LinuxName,
        [switch] $EnforceNetBios,
        [switch] $FailOnLength
    )

    if (-not $name) {
        throw "Test-ValidMachineName called without a VMName"
    }

    write-log "Testing $name" -Verbose
    $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>_') + '\]' + '\"'+'\s')]"

    # 15-char limit is a Windows NetBIOS / AD sAMAccountName constraint. It
    # applies to every Windows VM, AND to any DOMAIN-JOINED Linux VM: realm join
    # derives the machine account name from the hostname truncated to 15 chars,
    # so an over-15 name (e.g. PS1-LINUXCLIENT2) is silently truncated to a
    # possibly-colliding account (PS1-LINUXCLIENT). A non-domain Linux VM is only
    # bound by the 64-char hostname limit below.
    # -FailOnLength is passed for names that actually BECOME an AD computer object
    # in this deployment (the VM itself, the cluster CNO, the listener VCO). Those
    # must block: with an optional prefix the deployment relies on the NetBIOS name
    # being the whole name, so silent truncation would break the uniqueness rule the
    # cross-domain conflict check enforces.
    if (($name.Length -gt 15) -and (-not $LinuxName -or $EnforceNetBios)) {
        $nameKind = if ($LinuxName) { "domain-joined Linux VM's AD machine account name (the hostname is truncated to 15 chars)" } else { "Windows computer name" }
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid name: $name. $nameKind cannot be more than 15 characters long (Currently $($name.Length))." -ReturnObject $ReturnObject -Failure:$FailOnLength -Warning:(-not $FailOnLength)
    }

    if ($LinuxName -and $name.Length -gt 64) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] has invalid name: $name. Linux hostname cannot be more than 64 characters long (Currently $($name.Length))." -ReturnObject $ReturnObject -Warning
    }

    if ($name -match $pattern) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] contains invalid characters in $name." -ReturnObject $ReturnObject -Failure
    }

    if ($name.EndsWith(".")) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] cannot end with '.'." -ReturnObject $ReturnObject -Failure
    }
    
    if ($name -eq $env:COMPUTERNAME) {
        Add-ValidationMessage -Message "VM Validation: Domain Name [$name] is invalid. Cannot be the same name as the Host VM [$($env:COMPUTERNAME)]." -ReturnObject $ReturnObject -Warning
    }
}

function Test-CrossDomainNameConflict {
    param (
        [object[]] $NewVMs,
        [object[]] $ExistingVMs,
        [string] $ConfigDomain,
        [object] $ReturnObject
    )

    # MemLabs reaches every lab machine by NetBIOS name, so a cluster CNO or an AG
    # listener VCO has to be as globally unique across the host as a VM name.
    # vmOptions.prefix is optional and therefore no longer guarantees that.
    # vmName-vs-vmName is checked by the caller (it has the extra same-domain
    # re-deploy/role rules), so this pass covers only the virtual-name dimension.
    $otherDomainVMs = @($ExistingVMs | Where-Object { $_.domain -and $ConfigDomain -and ($_.domain -ne $ConfigDomain) })
    if ($otherDomainVMs.Count -eq 0) { return }

    $otherVirtualNames = @($otherDomainVMs | ForEach-Object { $_.ClusterName; $_.AlwaysOnListenerName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $otherVmNames = @($otherDomainVMs | ForEach-Object { $_.vmName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $otherAllNames = @($otherVmNames + $otherVirtualNames)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($newVM in $NewVMs) {
        $candidates.Add(@{ Label = "Cluster name"; Value = "$($newVM.ClusterName)"; Against = $otherAllNames })
        $candidates.Add(@{ Label = "AlwaysOn listener name"; Value = "$($newVM.AlwaysOnListenerName)"; Against = $otherAllNames })
        $candidates.Add(@{ Label = "VM"; Value = "$($newVM.vmName)"; Against = $otherVirtualNames })
    }

    # Both SQLAO nodes can carry the same ClusterName, so report each name once.
    $reported = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        $name = $candidate.Value
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($reported -contains $name) { continue }
        if (@($candidate.Against | Where-Object { $_ -eq $name }).Count -eq 0) { continue }
        $reported.Add($name)
        Add-ValidationMessage -Message "Name Conflict: $($candidate.Label) [$name] is already in use by another domain on this host. NetBIOS names must be unique across all deployments; rename it, or set a vmOptions.prefix that keeps it distinct." -ReturnObject $ReturnObject -Failure
    }
}

function Test-ValidUserName {
    param (
        [string] $name,
        [string] $vmName
    )

    if (-not $name) {
        return
    }
    if ($name -in "Administrator", "vmBuildAdmin" , "default" , "cm_svc" , "guest", "krbtgt") {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] cannot be a Reserved Name, as these accounts exist by default and cannot be added" -ReturnObject $return -Warning
    }
    # Windows reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9) cannot be
    # used as an account/sam name, even with an extension (e.g. NUL.txt).
    if ($name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] is a reserved Windows device name and cannot be used." -ReturnObject $return -Failure
    }
    # Disallowed characters for a domain/sam account name. Includes $ (denotes a
    # machine account) and % on top of the SAM-invalid set.
    $pattern = "[$([Regex]::Escape('/\[:;|=,@+*?<>$%') + '\]' + '\"'+'\s')]"
    if ($name -match $pattern) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] contains invalid characters. You must specify a valid domain username. For example: bob" -ReturnObject $return -Failure
    }

    if ($name.Length -gt 64) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] is too long. Must be less than 64 chars" -ReturnObject $return -Failure
    }

    if ($name.Length -lt 3) {
        Add-ValidationMessage -Message "User Validation: $($vmName) User [$name] is too short. Must be at least 3 chars" -ReturnObject $return -Failure
    }
}

function Test-ValidVmSupported {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw "No VM provided"
    }

    $vmName = $VM.vmName

    $vmName = Add-VmNamePrefix -Name $vmName -Prefix $ConfigObject.vmOptions.prefix
    $isLinuxVm = Test-VmIsLinux -Vm $VM
    # A domain-joined Linux VM must also honor the 15-char NetBIOS limit (its AD
    # machine account name is the hostname truncated to 15 chars).
    $enforceNetBios = $isLinuxVm -and ($VM.PSObject.Properties.Name -contains 'joinDomain') -and [bool]$VM.joinDomain
    Test-ValidMachineName $vmName -ReturnObject $ReturnObject -LinuxName:$isLinuxVm -EnforceNetBios:$enforceNetBios -FailOnLength

    if ($VM.remoteSQLVM) {
        Test-ValidMachineName $VM.remoteSQLVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.remoteSQLVM -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.replicaSqlServerVM) {
        Test-ValidMachineName $VM.replicaSqlServerVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.replicaSqlServerVM -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.wsusDataBaseServer) {
        if ($VM.wsusDataBaseServer -ne "WID") {
            Test-ValidMachineName $VM.wsusDataBaseServer -ReturnObject $ReturnObject
            Test-MachineNameExists $VM.wsusDataBaseServer -ReturnObject $ReturnObject -config $ConfigObject

            # The WSUS DB server can be an EXISTING, already-deployed SQL VM (e.g. adding a
            # SUP to an existing MP/DP and pointing its WSUS DB at the deployed site server).
            # Such a VM is not in $ConfigObject.virtualMachines yet (existing VMs are folded
            # in later by Add-ExistingVMsToDeployConfig), so resolve it the same way the
            # existence check above does -- via Get-List2, which includes existing VMs.
            $nameWithPrefix = $ConfigObject.vmOptions.prefix + $VM.wsusDataBaseServer
            $SQLVM = Get-List2 -deployConfig $ConfigObject -SmartUpdate | Where-Object { $_.vmName -eq $($VM.wsusDataBaseServer) -or $_.vmName -eq $nameWithPrefix }
            if (-not $SQLVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$($VM.wsusDataBaseServer)] does not contain sql; When deploying WSUS Role with remote SQL, you must specify the SQL VM." -ReturnObject $ReturnObject -Warning
            }
        }
    }

    if ($VM.fileServerVM) {
        Test-ValidMachineName $VM.fileServerVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.fileServerVM -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.pullDPSourceDP) {
        Test-ValidMachineName $VM.pullDPSourceDP -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.pullDPSourceDP -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.OtherNode) {
        Test-ValidMachineName $VM.OtherNode -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.OtherNode -ReturnObject $ReturnObject -config $ConfigObject        
    }

    if ($VM.AlwaysOnListenerName) {
        Test-ValidMachineName $VM.AlwaysOnListenerName -ReturnObject $ReturnObject -FailOnLength
    }

    if ($VM.remoteContentLibVM) {
        Test-ValidMachineName $VM.remoteContentLibVM -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.remoteContentLibVM -ReturnObject $ReturnObject -config $ConfigObject
    }
    if ($VM.PatchMyPCFileServer) {
        Test-ValidMachineName $VM.PatchMyPCFileServer -ReturnObject $ReturnObject
        Test-MachineNameExists $VM.PatchMyPCFileServer -ReturnObject $ReturnObject -config $ConfigObject
    }

    if ($VM.ClusterName) {
        Test-ValidMachineName $VM.ClusterName -ReturnObject $ReturnObject -FailOnLength
    }

    if ($VM.SqlInstanceName) {
        Test-ValidMachineName $VM.SqlInstanceName -ReturnObject $ReturnObject
    }


    # Supported OS
    if ($VM.role -ne "OSDClient") {
        # Linux VMs (e.g. role=Proxy / osFamily=Linux) use locally-built
        # base images via baseimagestaging\New-LinuxBaseImage.ps1 and may
        # not appear in the active _fileList*.json OS list. Skip the Azure
        # supported-OS check for them; the Linux deploy path handles the
        # base-image check separately.
        # Inline check (don't depend on Test-VmIsLinux being loaded yet).
        $isLinuxVm = $false
        $linuxReason = $null
        $vmRoleStr = if ($null -ne $VM.role) { [string]$VM.role } else { '' }
        $vmOsStr = if ($null -ne $VM.operatingSystem) { [string]$VM.operatingSystem } else { '' }
        $vmOsFamilyStr = $null
        if ($VM.PSObject.Properties.Name -contains 'osFamily') { $vmOsFamilyStr = [string]$VM.osFamily }

        if ($vmRoleStr -ieq 'Proxy') { $isLinuxVm = $true; $linuxReason = 'role=Proxy' }
        elseif ($vmOsFamilyStr -ieq 'Linux') { $isLinuxVm = $true; $linuxReason = 'osFamily=Linux' }
        elseif ($vmOsStr -like 'Ubuntu*' -or $vmOsStr -like 'Debian*' -or $vmOsStr -like 'Linux*') { $isLinuxVm = $true; $linuxReason = "operatingSystem=$vmOsStr" }
        elseif (Get-Command -Name Test-VmIsLinux -ErrorAction SilentlyContinue) {
            if (Test-VmIsLinux -Vm $VM) { $isLinuxVm = $true; $linuxReason = 'Test-VmIsLinux' }
        }

        if (-not $isLinuxVm) {
            if ($Common.Supported.OperatingSystems -notcontains $vm.operatingSystem) {
                Write-Log "[Test-ValidVmSupported] [$vmName] failing OS check: role=[$vmRoleStr] osFamily=[$vmOsFamilyStr] operatingSystem=[$vmOsStr]" -LogOnly
                Add-ValidationMessage -Message "VM Validation: [$vmName] does not contain a supported operatingSystem [$($vm.operatingSystem)]." -ReturnObject $ReturnObject -Failure
            }
        }
        else {
            Write-Log "[Test-ValidVmSupported] [$vmName] bypassing supported-OS check ($linuxReason)" -LogOnly
            # A VM identified as Linux (role/osFamily/Test-VmIsLinux) MUST carry a
            # Linux operatingSystem. Otherwise the Phase-1 download loop requests a
            # Windows image (keyed on operatingSystem) and the Linux create path
            # can't resolve its base VHDX -- observed on a LinuxClient whose
            # operatingSystem was 'Windows 11': Ubuntu Desktop never downloaded and
            # VM_Create failed with "Linux base image ... not found".
            if (-not ($vmOsStr -like 'Ubuntu*' -or $vmOsStr -like 'Debian*' -or $vmOsStr -like 'Linux*')) {
                Add-ValidationMessage -Message "VM Validation: [$vmName] is a Linux VM ($linuxReason) but its operatingSystem [$vmOsStr] is not a Linux OS. Linux VMs must use a Linux operatingSystem (e.g. 'Ubuntu Server 24.04 LTS' or 'Ubuntu Desktop 24.04 LTS')." -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # Windows 11 TPM
    if ($vm.operatingSystem -like "Windows 11*" -and $vm.tpmEnabled -eq $false) {
        Add-ValidationMessage -Message "VM Validation: [$vmName] does not have TPM enabled (required for Windows 11)." -ReturnObject $ReturnObject -Failure
    }

    # Supported DSC Roles for Existing scenario
    if ($configObject.parameters.ExistingDCName) {
        # Supported DSC Roles for Existing Scenario
        if ($Common.Supported.RolesForExisting -notcontains $vm.role -and $vm.role -ne "DC") {
            # DC is caught in Test-ValidDC
            $supportedRoles = $Common.Supported.RolesForExisting -join ", "
            Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)] for existing environment. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
        }
    }
    else {
        # Supported DSC Roles
        if ($Common.Supported.Roles -notcontains $vm.role) {
            $supportedRoles = $Common.Supported.Roles -join ", "
            Add-ValidationMessage -Message "VM Validation: [$vmName] contains an unsupported role [$($vm.role)] for a new environment. Supported values are: $supportedRoles" -ReturnObject $ReturnObject -Failure
        }
    }

}

function Test-ValidVmMemory {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Memory
    if (-not $VM.memory) {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] does not contain memory value []. Specify desired memory; For example: 4GB" -ReturnObject $ReturnObject -Failure
    }
    else {

        $vmMemory = $VM.memory

        # not string
        if ($vmMemory -isnot [string]) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Specify desired memory; For example: 4GB" -ReturnObject $ReturnObject -Failure
        }

        # memory doesn't contain MB/GB
        if ($vmMemory -is [string] -and -not ($vmMemory.ToUpperInvariant().EndsWith("MB") -or $vmMemory.ToUpperInvariant().EndsWith("GB"))) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Specify desired memory with MB/GB; For example: 4GB" -ReturnObject $ReturnObject -Failure
        }

        # numeric portion (everything before the MB/GB suffix) must be a whole number;
        # guard the [int] casts below so a non-numeric value (e.g. "*GB") yields a clean
        # validation message instead of throwing "Cannot convert value '*' to type System.Int32".
        if ($vmMemory -is [string] -and ($vmMemory.ToUpperInvariant().EndsWith("MB") -or $vmMemory.ToUpperInvariant().EndsWith("GB"))) {

            $vmMemoryNumber = $vmMemory.ToUpperInvariant().Replace("MB", "").Replace("GB", "")
            $parsedMemory = 0

            if (-not [int]::TryParse($vmMemoryNumber, [ref]$parsedMemory)) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Specify a whole number with MB/GB; For example: 4GB" -ReturnObject $ReturnObject -Failure
            }
            else {
                # memory less than 512MB
                if ($vmMemory.ToUpperInvariant().EndsWith("MB") -and $parsedMemory -lt 512 ) {
                    Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Should be more than 512MB" -ReturnObject $ReturnObject -Failure
                }

                # memory greater than 64GB
                if ($vmMemory.ToUpperInvariant().EndsWith("GB") -and $parsedMemory -gt 64 ) {
                    Add-ValidationMessage -Message "$vmRole Validation: [$vmName] memory value [$vmMemory] is invalid. Should be less than 64GB" -ReturnObject $ReturnObject -Failure
                }
            }
        }

        # Windows 11 memory floor: 4GB. A 2GB Win11 client exhausts commit under the
        # deploy load (CM client + DSC + first-boot servicing) and trips a known
        # Windows kernel bug -- a critical DcomLaunch svchost dies when a thread stack
        # can't grow at the commit limit (0xEF CRITICAL_PROCESS_DIED / STATUS_STACK_OVERFLOW,
        # microsoft/OS bug 56918928), BSOD'ing the VM mid-build. genconfig already
        # defaults Win11 to 4GB, but hand-authored configs can specify less. Detect and
        # REPAIR in place (raise to 4GB) with a Warning so the config self-heals.
        if ($vmMemory -is [string] -and ($vmMemory.ToUpperInvariant().EndsWith("MB") -or $vmMemory.ToUpperInvariant().EndsWith("GB")) `
                -and $VM.operatingSystem -like "Windows 11*" -and $VM.role -notin @("DC", "BDC")) {
            $memBytes = 0
            try { $memBytes = [int64]($vmMemory / 1) } catch { $memBytes = 0 }
            if ($memBytes -gt 0 -and $memBytes -lt 4GB) {
                $VM.memory = "4GB"
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] Windows 11 memory [$vmMemory] raised to 4GB. A 2GB Win11 client exhausts commit under the deploy load and can BSOD (0xEF, Windows OS bug 56918928); 4GB is the safe floor." -ReturnObject $ReturnObject -Warning
            }
        }
        # Linux memory floor: 2GB. At 1GB a Linux guest sharing a host with 20+
        # booting Windows VMs can fail to reach userspace at all -- PL-OREGANO
        # started its kernel and never wrote a single log line to its disk, so
        # cloud-init never ran and the hostname was still the base image's.
        # Repair in place like the Win11 floor above so old configs self-heal.
        if ($vmMemory -is [string] -and ($vmMemory.ToUpperInvariant().EndsWith("MB") -or $vmMemory.ToUpperInvariant().EndsWith("GB")) `
                -and (Test-VmIsLinux -Vm $VM)) {
            $memBytes = 0
            try { $memBytes = [int64]($vmMemory / 1) } catch { $memBytes = 0 }
            if ($memBytes -gt 0 -and $memBytes -lt 2GB) {
                $VM.memory = "2GB"
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] Linux memory [$vmMemory] raised to 2GB. Below this a Linux VM can fail to boot under deploy-time host contention." -ReturnObject $ReturnObject -Warning
            }
        }
    }

}

function Test-ValidVmDisks {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Additional Disks
    if ($VM.additionalDisks) {
        # S is reserved for the SQL ISO mount (Phase 4 SqlSetup SourcePath), so
        # it is excluded from the valid additional-disk letters.
        $validLetters = 69..89 | ForEach-Object { [char]$_ } | Where-Object { $_ -ne 'S' }    # Letters E-Y excluding S
        $disks = $VM.additionalDisks
        $disks | Get-Member -MemberType NoteProperty | ForEach-Object {

            # S is reserved for the SQL ISO mount
            if ($_.Name -eq 'S') {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains additional disk [S]; S: is reserved for the SQL ISO mount and cannot be used as a data disk." -ReturnObject $ReturnObject -Failure
            }
            # valid drive letter
            elseif ($_.Name.Length -ne 1 -or $validLetters -notcontains $_.Name) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must have a single drive letter between E and Y (excluding S)." -ReturnObject $ReturnObject -Failure
            }

            $size = $($vm.additionalDisks."$($_.Name)")

            if (-not $size.ToUpperInvariant().EndsWith("GB")) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Specify desired size in GB; For example: 200GB" -ReturnObject $ReturnObject -Failure
            }

            if ($size.ToUpperInvariant().EndsWith("GB") -and $([int]$size.ToUpperInvariant().Replace("GB", "")) -lt 10 ) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must be larger than 10GB" -ReturnObject $ReturnObject -Failure
            }

            if ($size.ToUpperInvariant().EndsWith("GB") -and $([int]$size.ToUpperInvariant().Replace("GB", "")) -gt 1000 ) {
                Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid additional disks [$disks]; Disks must be less than 1000GB" -ReturnObject $ReturnObject -Failure
            }
        }
    }

}

function Test-ValidVmProcs {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    if (-not $VM.virtualProcs -or -not $VM.virtualProcs -is [int]) {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid virtualProcs [$($vm.virtualProcs)]. Specify desired virtualProcs; For example: 2" -ReturnObject $ReturnObject -Failure
    }
    else {
        $virtualProcs = $VM.virtualProcs
        if ([int]$virtualProcs -gt 16 -or [int]$virtualProcs -lt 1) {
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] virtualProcs value [$virtualProcs] is invalid. Specify a value from 1-16." -ReturnObject $ReturnObject -Failure
        }
        elseif ([int]$virtualProcs -lt 2 -and (Test-VmIsLinux -Vm $VM)) {
            # A single vCPU is what turned a slow Linux boot into one that never
            # finished; repair in place to match the 2GB memory floor.
            $VM.virtualProcs = 2
            Add-ValidationMessage -Message "$vmRole Validation: [$vmName] Linux virtualProcs [$virtualProcs] raised to 2. A single vCPU cannot reliably complete boot under deploy-time host contention." -ReturnObject $ReturnObject -Warning
        }
    }

}

function Test-ValidVmServerOS {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    if ($VM.operatingSystem -notlike "*Server*") {
        Add-ValidationMessage -Message "$vmRole Validation: [$vmName] contains invalid OS [$($VM.operatingSystem)]. OS must be a Server OS for Primary/CAS/SiteSystem roles, or when SQL is selected." -ReturnObject $ReturnObject -Warning
    }

}

function Test-ValidVmPath {
    param (
        [object] $VM,
        [string] $PathProperty,
        [string] $ValidPathExample,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    if (-not $VM.$PathProperty) {
        return
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # path
    if (-not $VM.$PathProperty.Contains(":\") -or $VM.$PathProperty.EndsWith(":") -or $VM.$PathProperty.EndsWith("\")) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. Value must be a valid path; For example: ""$ValidPathExample""." -ReturnObject $ReturnObject -Failure
    }
    else {

        # valid drive
        $installDrive = $VM.$PathProperty.Substring(0, 1)

        if ($installDrive -in "A", "B", "D", "Z") {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. A/B/D/Z drive letters are not allowed." -ReturnObject $ReturnObject -Failure
        }

        if ($installDrive -ne "C" -and -not $VM.additionalDisks) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must be defined." -ReturnObject $ReturnObject -Warning
        }

        if ($installDrive -ne "C" -and $VM.additionalDisks) {
            $defined = $VM.additionalDisks | Get-Member -Name $installDrive
            if (-not $defined) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid $PathProperty [$($VM.$PathProperty)]. When using a drive other than C, additionalDisks must contain the desired drive letter." -ReturnObject $ReturnObject -Warning
            }
        }

    }
}

function Test-ValidRoleDC {
    param (
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    $DCVM = $configObject.virtualMachines | Where-Object { $_.role -eq "DC" }
    $vmRole = "DC"

    $containsDC = $configObject.virtualMachines.role -contains "DC"
    $existingDC = $configObject.parameters.ExistingDCName
    $domain = $ConfigObject.vmOptions.domainName

    if ($containsDC) {

        if ($DCVM.Count -gt 1) {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple DC roles found in this domain [$domain]. Adding a DC to existing environment is not supported. (Use the BDC role instead)" -ReturnObject $ReturnObject -Warning
        }

        if ($existingDC) {
            if ($DCVM.VmName -ne $existingDC) {
                Add-ValidationMessage -Message "$vmRole Validation: DC Role specified in configuration and existing DC [$existingDC] found in this domain [$domain]. Adding a DC to existing environment is not supported. (Use the BDC role instead)" -ReturnObject $ReturnObject -Warning
            }
        }

        # $MyInvocation.BoundParameters.ConfigObject.VirtualMachines | Out-Host
        if (Test-SingleRole -VM $DCVM -ReturnObject $ReturnObject) {

            # Server OS
            Test-ValidVmServerOS -VM $DCVM -ReturnObject $ReturnObject

            # No SQL on DC
            if ($DCVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: Adding SQL on Domain Controller is not supported." -ReturnObject $ReturnObject -Warning
            }

        }
    }
    else {

        # Existing Scenario, without existing DC Name
        if (-not $existingDC) {
            Add-ValidationMessage -Message "$vmRole Validation: DC role not specified in the configuration file and existing DC not found." -ReturnObject $ReturnObject -Warning
        }

        if ($existingDC) {

            # Check VM exists in Hyper-V
            $vm = Get-List -type VM -SmartUpdate | Where-Object { $_.vmName -eq $existingDC }
            if (-not $vm) {
                Add-ValidationMessage -Message "$vmRole Validation: Existing DC found [$existingDC] but VM with the same name was not found in Hyper-V." -ReturnObject $ReturnObject -Warning
            }
            else {
                if ($vm.State -eq "Running") {
                    # Check network in Hyper-V
                    # $vmnet = Get-VM -Name $existingDC -ErrorAction SilentlyContinue | Get-VMNetworkAdapter
                    # if ($vmnet.SwitchName -ne $configObject.vmOptions.network) {
                    #     Add-ValidationMessage -Message "$vmRole Validation: Existing DC [$existingDC] found but VM Switch [$($vmnet.SwitchName)] doesn't match specified network [$($configObject.vmOptions.network)]." -ReturnObject $ReturnObject -Warning
                    # }
                }
                else {
                    Start-VM2 -Name $vm.vmName
                    $vm = Get-List -type VM -SmartUpdate
                    if ($vm.State -ne "Running") {
                        # VM Not running, cannot validate network
                        Add-ValidationMessage -Message "$vmRole Validation: Existing DC [$existingDC] found but VM is not Running." -ReturnObject $ReturnObject -Warning
                    }
                }

                # Account validation
                $vmProps = Get-List -Type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $_.role -eq "DC" }
                if ($vmProps.AdminName -ne $ConfigObject.vmOptions.adminName) {
                    Add-ValidationMessage -Message "Account Validation: Existing DC [$existingDC] is using a different admin name [$($ConfigObject.vmOptions.adminName)] for deployment. You must use the existing admin user [$($vmProps.AdminName)]." -ReturnObject $ReturnObject -Warning
                    Get-List -type VM -SmartUpdate | Out-Null
                }
            }
        }
    }
}

function Test-ValidRoleSiteServer {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # MP database replica is only supported on dedicated SiteSystem MP VMs, never
    # on the Primary/CAS/Secondary site server itself (even when it hosts its own MP).
    # This function runs for every VM with a SiteCode (including SiteSystem MPs), so
    # only flag the actual site-server roles; SiteSystem MPs are validated separately
    # in Test-ValidRoleSiteSystem.
    if ($VM.useDatabaseReplica -and $vmRole -in ("CAS", "Primary", "Secondary")) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has useDatabaseReplica set, which is not supported on a $vmRole site server. The MP database replica is only supported on dedicated SiteSystem Management Point VMs." -ReturnObject $ReturnObject -Failure
    }

    # Primary/CAS must contain SQL
    if (-not $VM.sqlVersion -and -not $VM.remoteSQLVM -and $vmRole -in ("CAS", "Primary")) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain sqlVersion; When deploying $vmRole Role, you must specify the SQL Version." -ReturnObject $ReturnObject -Warning
    }

    # Secondary parentSiteCode must belong to a Primary
    if ($VM.parentSiteCode -and $vmRole -eq "Secondary") {

        $anyPsInConfig = $ConfigObject.virtualMachines | Where-Object { $_.role -eq "Primary" }
        if ($anyPsInConfig) {
            #Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified with Primary Site which is currently not supported. Please add Secondary after building the Primary." -ReturnObject $return -Warning
        }

        $psInConfig = $ConfigObject.virtualMachines | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $VM.parentSiteCode }
        if (-not $psInConfig) {
            $primary = Get-SiteServerForSiteCode -deployConfig $ConfigObject -sitecode $VM.parentSiteCode -type VM
            if (-not $primary) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains parentSiteCode [$($VM.parentSiteCode)], but a primary site with this siteCode was not found." -ReturnObject $ReturnObject -Warning
            }
        }
    }

    # Remote SQL
    if ($VM.remoteSQLVM) {
        $sqlServerName = $VM.remoteSQLVM
        $SQLVM = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $sqlServerName }

        # Remote SQL must contain sqlVersion
        if ($SQLVM) {
            if (-not $SQLVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$sqlServerName] does not contain sqlVersion; When deploying $vmRole Role with remote SQL, you must specify the SQL Version for SQL VM." -ReturnObject $ReturnObject -Warning
            }
        }
        else {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$sqlServerName] does not exist; When deploying $vmRole Role with remote SQL, you must include the remote SQL VM." -ReturnObject $ReturnObject -Warning
            Write-Verbose "VMs are $($ConfigObject.virtualMachines.vmName)"
        }

        # Minimum Memory
        if ($VM.memory / 1 -lt 3GB) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] must contain a minimum of 3GB memory when using remote SQL." -ReturnObject $ReturnObject -Failure
        }

    }
    else {
        if ($VM.SqlVersion) {
            # Local SQL
            $minMem = 6
            if ($vmRole -eq "Secondary") { $minMem = 3 }
            if ($vmRole -eq "SiteSystem") { $minMem = 4 }
            # Minimum Memory
            if ($VM.memory / 1 -lt $minMem * 1GB) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has SQL; must contain a minimum of $($minMem)GB memory." -ReturnObject $ReturnObject -Failure
            }
        }
    }

    # Site Code
    if ($VM.siteCode.Length -ne 3) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code [$($VM.siteCode)] Must be exactly 3 chars." -ReturnObject $ReturnObject -Failure
    }

    # Parent Site Code
    if ($VM.parentSiteCode -and $VM.parentSiteCode.Length -ne 3) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code [$($VM.parentSiteCode)] Must be exactly 3 chars." -ReturnObject $ReturnObject -Failure
    }

    # invalid site codes
    $pattern = "^[a-zA-Z0-9]+$"
    if (-not ($VM.siteCode -match $pattern)) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains invalid Site Code (Must be AlphaNumeric) [$($VM.siteCode)]." -ReturnObject $ReturnObject -Failure
    }

    # reserved site codes
    if ($VM.siteCode.ToUpperInvariant() -in "AUX", "CON", "NUL", "PRN", "SMS", "ENV") {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] reserved for Configuration Manager and Windows." -ReturnObject $ReturnObject -Failure
    }

    if ($vm.Role -in "CAS", "Primary", "Secondary" ) {
        $otherVMs = $ConfigObject.VirtualMachines | Where-Object { $_.vmName -ne $VM.vmName } | Where-Object { $null -ne $_.Sitecode } | Where-Object { $_.Role -in "CAS", "Primary", "Secondary" }
        foreach ($vmWithSiteCode in $otherVMs) {
            if ($VM.siteCode.ToUpperInvariant() -eq $vmWithSiteCode.siteCode.ToUpperInvariant() -and ($vmWithSiteCode.role -in "CAS", "Primary", "Secondary")) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] that is already used by another siteserver [$($vmWithSiteCode.vmName)]." -ReturnObject $ReturnObject -Failure
            }
        }

        $otherVMs = Get-List -type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $null -ne $_.siteCode } | Where-Object { $_.Role -in "CAS", "Primary", "Secondary" }
        foreach ($vmWithSiteCode in $otherVMs) {
            if ($VM.siteCode.ToUpperInvariant() -eq $vmWithSiteCode.siteCode.ToUpperInvariant() -and ($vmWithSiteCode.role -in "CAS", "Primary", "Secondary")) {
                if ($vmName -ne $($vmWithSiteCode.vmName)) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains Site Code [$($VM.siteCode)] that is already used by another siteserver [$($vmWithSiteCode.vmName)]." -ReturnObject $ReturnObject -Failure
                }
            }
        }
    }

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    # install dir
    Test-ValidVmPath -VM $VM -PathProperty "cmInstallDir" -ValidPathExample "E:\ConfigMgr" -ReturnObject $ReturnObject

}

function Test-ValidRolePassiveSite {
    param (
        [object] $VM,
        [object] $ConfigObject,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    # install dir
    Test-ValidVmPath -VM $VM -PathProperty "cmInstallDir" -ValidPathExample "E:\ConfigMgr" -ReturnObject $ReturnObject

    if (-not $VM.remoteContentLibVM) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain remoteContentLibVM; When deploying $vmRole Role, you must specify the FileServer where Content Library will be hosted." -ReturnObject $ReturnObject -Warning
    }

    if ($VM.remoteContentLibVM) {
        $fsInConfig = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $VM.remoteContentLibVM }
        if (-not $fsInConfig) {
            $fsVM = Get-List -type VM -DomainName $($ConfigObject.vmOptions.DomainName) -SmartUpdate | Where-Object { $_.vmName -eq $VM.remoteContentLibVM }
        }
        else {
            $fsVM = $fsInConfig
        }

        if (-not $fsVM) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] configuration contains remoteContentLibVM [$($VM.remoteContentLibVM)] which does not exist in Configuration or Hyper-V." -ReturnObject $ReturnObject -Warning
        }

        if ($fsVM -and $fsVM.role -ne "FileServer") {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] configuration contains remoteContentLibVM [$($VM.remoteContentLibVM)] which currently has role [$($fsVM.role)]. remoteContentLibVM role must be FileServer." -ReturnObject $ReturnObject -Warning
        }
    }

    if (-not $VM.siteCode) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain siteCode; When deploying $vmRole Role, you must specify the siteCode of an Active Site Server." -ReturnObject $ReturnObject -Warning
    }
    else {
        $assInConfig = $ConfigObject.virtualMachines | Where-Object { $_.sitecode -eq $VM.siteCode -and ($_.role -eq "CAS" -or $_.role -eq "Primary") }
        if (-not $assInConfig) {
            $assVM = Get-ExistingSiteServer -DomainName $ConfigObject.vmOptions.DomainName -SiteCode $VM.siteCode

            if (($assVM | Measure-Object).Count -eq 0) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which doesn't belong to an existing Site Server." -ReturnObject $ReturnObject -Warning
            }

            if (($assVM | Measure-Object).Count -gt 1) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which already contains a passive site server." -ReturnObject $ReturnObject -Warning
            }
        }
    }
}

function Test-ValidRoleFileServer {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # Server OS
    Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject

    if (-not $VM.additionalDisks) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain additionalDisks. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
    }
    else {
        $edrive = $VM.additionalDisks | Get-Member -Name "E"
        $fdrive = $VM.additionalDisks | Get-Member -Name "F"

        if (-not $edrive) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain E drive. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
        }

        if (-not $fdrive) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain F drive. FileServer must contain E and F drives." -ReturnObject $ReturnObject -Warning
        }
    }

}

function Test-ValidRoleSiteSystem {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        throw
    }

    $vmName = $VM.vmName
    $vmRole = $VM.role

    # A Windows client OS can host only the Distribution Point role. ConfigMgr's
    # DP prerequisite path accepts a workstation SKU; component-server roles do not.
    $serverOnlyRoleSelected = @('installMP', 'installSUP', 'installRP', 'installSMSProv') | Where-Object {
        $VM.PSObject.Properties.Name -contains $_ -and $VM.$_ -eq $true
    }
    $isClientOsSiteSystem = Test-SiteSystemClientOperatingSystem -VirtualMachine $VM
    if ($isClientOsSiteSystem -and $serverOnlyRoleSelected) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] uses client OS [$($VM.operatingSystem)]. A client-OS SiteSystem can host only the Distribution Point role; disable installMP, installSUP, installRP, and installSMSProv." -ReturnObject $ReturnObject -Failure
    }
    elseif ($serverOnlyRoleSelected) {
        Test-ValidVmServerOS -VM $VM -ReturnObject $ReturnObject
    }
    $sqlSelected = @('sqlVersion', 'remoteSQLVM') | Where-Object {
        $VM.PSObject.Properties.Name -contains $_ -and -not [string]::IsNullOrWhiteSpace("$($VM.$_)")
    }
    if ($isClientOsSiteSystem -and $sqlSelected) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] uses client OS [$($VM.operatingSystem)] and contains SQL configuration. MemLabs SQL installation requires Windows Server, and a client-OS SiteSystem supports only the Distribution Point role. Remove sqlVersion/remoteSQLVM or switch the VM back to a Server OS." -ReturnObject $ReturnObject -Failure
    }

    # Role allowed on CAS?
    $allowOnCAS = $true
    if ($VM.installMP -or $VM.installDP) {
        $allowOnCAS = $false
    }

    if (-not $VM.siteCode) {
        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not contain siteCode; When deploying $vmRole Role, you must specify the siteCode of a Primary Site Server." -ReturnObject $ReturnObject -Warning
    }
    else {
        $ssInConfig = $ConfigObject.virtualMachines | Where-Object { $_.sitecode -eq $VM.siteCode -and ($_.role -in "Primary", "Secondary", "CAS") }
        if (-not $ssInConfig) {
            $ssVM = Get-ExistingSiteServer -DomainName $ConfigObject.vmOptions.DomainName -SiteCode $VM.siteCode
            if (($ssVM | Measure-Object).Count -eq 0) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which doesn't belong to an existing Site Server." -ReturnObject $ReturnObject -Warning
            }
        }
    }
    if (-not $allowOnCAS) {
        $casVM = Get-List2 -DeployConfig $ConfigObject | Where-Object { $_.role -eq "CAS" -and $_.siteCode -eq $VM.siteCode }
        if ($casVM) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a SiteSystem role (DP or MP) that is not allowed on CAS." -ReturnObject $ReturnObject -Warning
        }
    }

    if ($VM.pullDPSourceDP) {
        $source = Get-List2 -DeployConfig $ConfigObject | Where-Object { $_.vmName -eq $VM.pullDPSourceDP }
        if ($VM.SiteCode -ne $source.SiteCode) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] contains a siteCode [$($VM.siteCode)] which does not match Source DP [$($source.vmName)] sitecode [$($source.siteCode)]" -ReturnObject $ReturnObject -Warning
        }

        # A Pull DP's source MUST itself be an installed, standard (non-pull) DP.
        # Otherwise Add-CMDistributionPoint -SourceDistributionPoint throws "No object
        # corresponds to the specified parameters" and the pull DP never installs. The
        # source can be a dedicated SiteSystem DP or a site server (Primary) with
        # installDP enabled. This is a hard FAIL -- a pull DP with a non-DP source is a
        # broken config that would silently never provision.
        if (-not $source) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] Pull DP source [$($VM.pullDPSourceDP)] was not found in the configuration or domain." -ReturnObject $ReturnObject -Failure
        }
        elseif (-not $source.installDP) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] Pull DP source [$($source.vmName)] is not a Distribution Point (installDP is not enabled). A Pull DP's source must be an installed DP." -ReturnObject $ReturnObject -Failure
        }
        elseif ($source.enablePullDP) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] Pull DP source [$($source.vmName)] is itself a Pull DP. A Pull DP's source must be a standard (non-pull) DP." -ReturnObject $ReturnObject -Failure
        }
        elseif ($source.role -in 'Primary', 'CAS') {
            # A pull DP's source must be a DP with a LOCAL content library. When a
            # site is made HA (a passive site server with remoteContentLibVM), the
            # site's content library is relocated to a remote share and the site
            # server's DP is REMOVED (InstallPassiveSiteServer.ps1 Remove-CMDistributionPoint
            # before Move-CMContentLibrary) -- a site server with a remote content
            # library cannot host a working DP. If the pull-source-ordering logic then
            # re-adds a DP to that site server, it serves HTTP content from the now-empty
            # local SCCMContentLib and every pull-DP download gets HTTP 404. So a pull DP
            # must NOT source from the site server of an HA site; point it at a dedicated
            # DP (SiteSystem/installDP) that keeps its own local content library instead.
            $haVMs = @($ConfigObject.virtualMachines)
            $haVMs += @(Get-List -type VM -DomainName $ConfigObject.vmOptions.DomainName)
            $haCompanion = $haVMs | Where-Object { $_.remoteContentLibVM -and $_.siteCode -eq $source.siteCode } | Select-Object -First 1
            if ($haCompanion) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] Pull DP source [$($source.vmName)] is the site server of an HA site whose content library is relocated to a remote share (passive site [$($haCompanion.vmName)] remoteContentLibVM [$($haCompanion.remoteContentLibVM)]). Such a site server cannot host a working DP, so a pull DP sourced from it gets HTTP 404 on all content. Point pullDPSourceDP at a dedicated DP with a LOCAL content library instead." -ReturnObject $ReturnObject -Failure
            }
        }

    }

    # MP database replica (SiteSystem MP only)
    if ($VM.useDatabaseReplica) {
        if (-not $VM.installMP) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has useDatabaseReplica enabled but is not a Management Point (installMP). The database replica is only supported on an MP." -ReturnObject $ReturnObject -Failure
        }

        if ([string]::IsNullOrWhiteSpace($VM.replicaDbName)) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has useDatabaseReplica enabled but replicaDbName is empty." -ReturnObject $ReturnObject -Failure
        }

        $replicaVMName = $VM.replicaSqlServerVM
        if ([string]::IsNullOrWhiteSpace($replicaVMName)) {
            Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] has useDatabaseReplica enabled but replicaSqlServerVM is not set." -ReturnObject $ReturnObject -Failure
        }
        else {
            $replicaSQLVM = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $replicaVMName }
            if (-not $replicaSQLVM) {
                $replicaSQLVM = Get-List -type VM -DomainName $ConfigObject.vmOptions.DomainName | Where-Object { $_.vmName -eq $replicaVMName }
            }
            if (-not $replicaSQLVM) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replicaSqlServerVM [$replicaVMName] was not found in the configuration or domain." -ReturnObject $ReturnObject -Failure
            }
            elseif (-not $replicaSQLVM.sqlVersion) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replicaSqlServerVM [$replicaVMName] does not contain SQL (sqlVersion). The replica host must be a SQL Server." -ReturnObject $ReturnObject -Failure
            }
            elseif (($replicaSQLVM.memory) -and (($replicaSQLVM.memory / 1) -lt 4GB)) {
                Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replica SQL host [$replicaVMName] has less than 4GB memory; hosting a database replica may be slow." -ReturnObject $ReturnObject -Warning
            }

            # The replica SQL instance must run as LocalSystem. MP replica setup relies on
            # the machine account for cross-server transactional replication and Service
            # Broker authentication; a domain SQL service/agent account breaks that trust.
            # An absent account defaults to LocalSystem, so only a non-LocalSystem value
            # (e.g. a SQLAO domain account) is a failure.
            if ($replicaSQLVM -and $replicaSQLVM.sqlVersion) {
                if ($replicaSQLVM.SqlServiceAccount -and $replicaSQLVM.SqlServiceAccount -ne "LocalSystem") {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replica SQL host [$replicaVMName] runs the SQL Server service as [$($replicaSQLVM.SqlServiceAccount)]. A replica SQL instance must run as LocalSystem so the machine account can authenticate replication and Service Broker." -ReturnObject $ReturnObject -Failure
                }
                if ($replicaSQLVM.SqlAgentAccount -and $replicaSQLVM.SqlAgentAccount -ne "LocalSystem") {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replica SQL host [$replicaVMName] runs the SQL Server Agent service as [$($replicaSQLVM.SqlAgentAccount)]. A replica SQL instance must run SQL Agent as LocalSystem so the machine account can authenticate the replication agents." -ReturnObject $ReturnObject -Failure
                }
            }

            # NOTE: an existing/already-deployed SQL server (Hidden VM, or one only in
            # the domain) is supported as a replica host. Phase 4 mounts the SQL ISO on
            # it and adds the required SQL 'Replication' feature (Phase4.ps1
            # EnsureSqlReplication); the existing site DB SQL publisher is handled the
            # same way.

            # Replica DB must NOT be hosted on the site's own SQL server.
            if ($VM.siteCode) {
                $siteSql = $null
                try {
                    $siteSql = Get-SqlServerForSiteCode -deployConfig $ConfigObject -SiteCode $VM.siteCode -type Name -SmartUpdate:$false
                }
                catch {
                    $siteSql = $null
                }
                if ($siteSql -and $siteSql -eq $replicaVMName) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] replicaSqlServerVM [$replicaVMName] is the site database server. The MP replica must use a different SQL server." -ReturnObject $ReturnObject -Failure
                }
            }
        }
    }

}

function Test-SingleRole {
    param (
        [object] $VM,
        [object] $ReturnObject
    )

    if (-not $VM) {
        # $MyInvocation | Out-Host
        throw
    }

    $vmRole = $VM.role

    # Single Role
    if ($VM -is [object[]] -and $VM.Count -ne 1) {
        $vmRole = $VM.role | Select-Object -Unique
        if ($vmRole -eq "DC") {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple virtual Machines with $vmRole Role specified in configuration. Only single $vmRole role is supported." -ReturnObject $ReturnObject -Warning
        }
        else {
            Add-ValidationMessage -Message "$vmRole Validation: Multiple machines with $vmRole role cannot be deployed at the same time. You can add more $vmRole machines to your domain after it is deployed." -ReturnObject $ReturnObject -Warning
        }
        return $false
    }

    return $true
}

function Test-ValidDiskSpace {
    param (
        [Parameter(Mandatory = $true)]
        [object]$ConfigObject,
        [Parameter(Mandatory = $true)]
        [object]$ReturnObject
    )

    try {
        $basePath = $ConfigObject.vmOptions.basePath
        if ([string]::IsNullOrWhiteSpace($basePath) -or -not $basePath.Contains(":\")) {
            # Already covered by Test-ValidVmOptions
            return
        }

        $driveLetter = $basePath.Substring(0, 1)
        $rootPath = "$driveLetter`:\"
        if (-not (Test-Path $rootPath)) {
            return
        }

        # Collect VMs that will actually have an OS VHDX copied (new, non-hidden, non-OSDClient)
        $vmsToCreate = @($ConfigObject.virtualMachines | Where-Object {
                (-not $_.Hidden) -and ($_.Role -ne "OSDClient")
            })

        if ($vmsToCreate.Count -eq 0) {
            return
        }

        $totalRequiredBytes = [int64]0
        $assumedSizeBytes = [int64]16GB
        $unknownSizeVms = @()
        $perVmDetails = @()

        foreach ($vm in $vmsToCreate) {
            $os = $vm.operatingSystem
            if ([string]::IsNullOrWhiteSpace($os)) { continue }

            $sourcePath = $null
            $imageFile = $Common.AzureFileList.OS | Where-Object { $_.id -eq $os } | Select-Object -First 1
            if ($imageFile -and $imageFile.filename) {
                $sourcePath = Join-Path $Common.AzureFilesPath $imageFile.filename
            }

            $size = $null
            if ($sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                try {
                    $size = [int64](Get-Item -LiteralPath $sourcePath -ErrorAction Stop).Length
                }
                catch {
                    $size = $null
                }
            }

            if ($null -eq $size) {
                # Source VHDX not yet downloaded — assume 16GB
                $size = $assumedSizeBytes
                $unknownSizeVms += $vm.vmName
            }

            $totalRequiredBytes += $size
            $perVmDetails += [PSCustomObject]@{
                VmName  = $vm.vmName
                OS      = $os
                Bytes   = $size
                Assumed = ($unknownSizeVms -contains $vm.vmName)
            }
        }

        if ($totalRequiredBytes -le 0) {
            return
        }

        $reserveBytes = [int64]8GB
        $requiredWithReserve = $totalRequiredBytes + $reserveBytes

        # Get free space on the target drive
        $freeBytes = $null
        try {
            $psDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
            $freeBytes = [int64]$psDrive.Free
        }
        catch {
            Add-ValidationMessage -Message "Disk Space Validation: Failed to query free space on drive '$driveLetter`:'. $_" -ReturnObject $ReturnObject -Warning
            return
        }

        $requiredGb = [Math]::Round($totalRequiredBytes / 1GB, 2)
        $reserveGb = [Math]::Round($reserveBytes / 1GB, 2)
        $totalRequiredGb = [Math]::Round($requiredWithReserve / 1GB, 2)
        $freeGb = [Math]::Round($freeBytes / 1GB, 2)

        if ($freeBytes -lt $requiredWithReserve) {
            $shortfallGb = [Math]::Round((($requiredWithReserve - $freeBytes) / 1GB), 2)
            $vmListText = ($perVmDetails | ForEach-Object {
                    $sizeGb = [Math]::Round($_.Bytes / 1GB, 2)
                    if ($_.Assumed) { "$($_.VmName) [~${sizeGb}GB assumed]" } else { "$($_.VmName) [${sizeGb}GB]" }
                }) -join ', '
            Add-ValidationMessage -Message "Disk Space Validation: Not enough free space on drive '$driveLetter`:' to copy VHDX files for $($perVmDetails.Count) VM(s). Required ${requiredGb}GB + ${reserveGb}GB reserve = ${totalRequiredGb}GB. Available: ${freeGb}GB. Short by ${shortfallGb}GB. VMs: $vmListText." -ReturnObject $ReturnObject -Failure
        }
        else {
            Write-Log -Verbose "Disk Space Validation: Drive '$driveLetter`:' has ${freeGb}GB free; deployment requires ${totalRequiredGb}GB (${requiredGb}GB for VHDX copies + ${reserveGb}GB reserve)."
        }

        if ($unknownSizeVms.Count -gt 0) {
            # Only emit as a blocking warning when disk space actually failed
            # (provides context about the assumed sizes). When space is
            # sufficient, just log it - the user can't fix "not downloaded"
            # from the menu and it shouldn't block deployment.
            $notDownloadedMsg = "Disk Space Validation: Source VHDX file(s) not yet downloaded for: $($unknownSizeVms -join ', '). Assumed 16GB each for space calculation; actual size may differ."
            if ($freeBytes -lt $requiredWithReserve) {
                Add-ValidationMessage -Message $notDownloadedMsg -ReturnObject $ReturnObject -Warning
            }
            else {
                Write-Log -Verbose $notDownloadedMsg
            }
        }
    }
    catch {
        Write-Log "Test-ValidDiskSpace: Unexpected error: $_" -LogOnly
    }
}

function Test-Configuration {
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "ConfigFile", HelpMessage = "Configuration File")]
        [string]$FilePath,
        [Parameter(Mandatory = $true, ParameterSetName = "ConfigObject", HelpMessage = "Configuration File")]
        [object]$InputObject,
        [Parameter(Mandatory = $false, HelpMessage = "Fast Mode")]
        [switch]$Fast,
        [Parameter(Mandatory = $false, HelpMessage = "Final Test")]
        [switch]$Final,
        [Parameter(Mandatory = $false, HelpMessage = "Start phase for the deployment; URLs only needed by earlier phases are skipped.")]
        [int]$StartPhase = 0
    )
    #Get-PSCallStack | out-host

    $disableSmartUpdateValue = (Get-Variable -Name 'DisableSmartUpdate' -Scope Global -ErrorAction SilentlyContinue).Value
    $OrigSmartUpdateValue = $disableSmartUpdateValue
    if ($null -eq $OrigSmartUpdateValue ) {
        $OrigSmartUpdateValue = $false
    }

    # Fast-path memoization: when called repeatedly in -Fast mode with SmartUpdate disabled
    # (the genconfig main-menu redraw pattern), the validation result is a pure function of
    # the InputObject contents. Cache by SHA1 of its JSON so back-to-back menu transitions
    # skip the full revalidation pass (New-DeployConfig + ~25 Test-Valid* calls).
    $fastCacheJson = $null
    $fastCacheKey = $null
    $fastCacheEligible = ($Fast.IsPresent -and -not $Final.IsPresent -and $InputObject -and $OrigSmartUpdateValue -eq $true)
    if ($fastCacheEligible) {
        try {
            $fastCacheJson = $InputObject | ConvertTo-Json -Depth 5 -Compress
            $sha = [System.Security.Cryptography.SHA1]::Create()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($fastCacheJson)
                $fastCacheKey = [System.BitConverter]::ToString($sha.ComputeHash($bytes))
            }
            finally {
                $sha.Dispose()
            }
            if ($global:TestConfigFastCache -and $global:TestConfigFastCache.Key -eq $fastCacheKey) {
                $cachedFailures = 0
                try { $cachedFailures = [int]$global:TestConfigFastCache.Value.Failures } catch { }
                if ($cachedFailures -gt 0) {
                    # Self-heal: a cached failure may be a ghost from a prior run
                    # under different validator logic. Drop the entry and fall
                    # through to a fresh validation pass; if the failure is
                    # real, the re-run reproduces it and re-caches it below.
                    Write-Log "[Test-Configuration] cache HIT with Failures=$cachedFailures (hash $($fastCacheKey.Substring(0,12))) - invalidating cache and re-running validators to confirm" -LogOnly
                    $global:TestConfigFastCache = $null
                }
                else {
                    Write-Log "[Test-Configuration] cache HIT (hash $($fastCacheKey.Substring(0,12))) Failures=0 - returning prior TestObject without re-running validators" -LogOnly
                    return $global:TestConfigFastCache.Value
                }
            }
        }
        catch {
            $fastCacheKey = $null
        }
    }

    try {

        $return = [PSCustomObject]@{
            Valid        = $false
            DeployConfig = $null
            Message      = [System.Text.StringBuilder]::new()
            Failures     = 0
            Warnings     = 0
            Problems     = 0
            Informational = 0
            InfoMessage  = [System.Text.StringBuilder]::new()
        }
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Filepath" -PercentComplete 1
        if ($FilePath) {
            try {
                $configObject = Get-Content $FilePath -Force | ConvertFrom-Json
                #update cache, and then disable re-loading it until we complete
                get-list2 -deployConfig $configObject -SmartUpdate | out-null                                
                $global:DisableSmartUpdate = $true
            }
            catch {
                $return.Message = "Failed to load $FilePath as JSON. Please check if the config is valid or create a new one using genconfig.ps1"
                $return.Problems += 1
                $return.Failures += 1
                Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
                return $return
            }
        }

        if ($InputObject) {
            # Convert to Json and back to make a copy of the object, so the original is not modified.
            # Reuse the JSON we already produced for the fast-cache key when available.
            try {
                if ($fastCacheJson) {
                    $configObject = $fastCacheJson | ConvertFrom-Json
                }
                else {
                    $configObject = $InputObject | ConvertTo-Json -Depth 5 | ConvertFrom-Json
                }
            }
            catch {
                $return.Message = "Failed to load Config as JSON. Please check if the config is valid or create a new one using genconfig.ps1"
                $return.Problems += 1
                $return.Failures += 1
                Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
                return $return
            }
        }

        # InputObject could be blank
        # if (-not $InputObject -and -not $FilePath) {
        #     if ($InputObject -isnot [System.Management.Automation.PSCustomObject]) {
        #         $return.Message = "InputObject is invalid. Please check if the config is valid or create a new one using genconfig.ps1"
        #         $return.Problems += 1
        #         $return.Failures += 1
        #         return $return
        #     }
        # }

        # Get deployConfig without existing VM's for validation
        Write-Progress2 -Activity "Validating Configuration" -Status "Creating DeployConfig" -PercentComplete 5
        $deployConfig = New-DeployConfig -configObject $configObject

        #if ($deployConfig.virtualMachines.Count -eq 0) {
        #    $return.Message = "Configuration contains no Virtual Machines. Nothing to deploy."
        #    $return.Problems += 1
        #$return.Failures += 1
        #    Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
        #    return $return
        #}

        $virtualMachinesNoExisting = $deployConfig.virtualMachines | Where-Object { -not $_.Hidden }
        # Contains roles
        if ($deployConfig.virtualMachines) {
            # Note: $virtualMachinesNoExisting is an array of VM *objects*. Use .role to extract the
            # role string from each object before testing membership.
            $rolesInDeployment = @($virtualMachinesNoExisting | ForEach-Object { $_.role })
            $containsCS = $rolesInDeployment -contains "CAS"
            $containsPS = $rolesInDeployment -contains "Primary"
            $containsSiteSystem = $rolesInDeployment -contains "SiteSystem"
            $containsPassive = $rolesInDeployment -contains "PassiveSite"
            $containsSecondary = $rolesInDeployment -contains "Secondary"
        }
        else {
            $containsCS = $containsPS = $containsSiteSystem = $containsPassive = $containsSecondary = $false
        }

        $needCMOptions = $containsCS -or $containsPS -or $containsSiteSystem -or $containsPassive -or $containsSecondary

        # VM Options
        # ===========
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Vm Options" -PercentComplete 7
        Test-ValidVmOptions -ConfigObject $deployConfig -ReturnObject $return

        Test-ValidMachineName $deployConfig.vmOptions.domainNetBiosName -ReturnObject $return
        # CM Options
        # ===========

        # CM Version
        if ($needCMOptions) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing CM Options" -PercentComplete 8
            Test-ValidCmOptions -ConfigObject $deployConfig -ReturnObject $return
        }

        # VM Validations
        # ==============

        $i = 8
        foreach ($vm in $deployConfig.virtualMachines) {
            $vmName = $vm.VmName
            $i++
            if ($i -ge 35) {
                $i = 35
            }
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Vm $($vm.vmName)" -PercentComplete $i
            # Supported values
            Test-ValidVmSupported -VM $vm -ConfigObject $deployConfig -ReturnObject $return

            # Valid Memory
            Test-ValidVmMemory -VM $vm -ReturnObject $return

            # virtualProcs
            Test-ValidVmProcs -VM $vm -ReturnObject $return

            # Valid additionalDisks
            Test-ValidVmDisks -VM $vm -ReturnObject $return


            if ($vm.Role -eq "Primary") {
                $passiveSite = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" -and $_.siteCode -eq $vm.SiteCode }
                if ($passiveSite) {
                    write-log -verbose "Checking Passive Site Server has DP in sitecode"
                    # Include existing VMs so an existing DP in the site satisfies the remote contentlib
                    # requirement when adding a new Passive to an existing Primary.
                    $list2ForDP = Get-List2 -deployConfig $deployConfig
                    # A pull DP does NOT count: it has no local content of its own (it
                    # pulls from a source DP), so it can't be the site's content source.
                    # An HA site (remote content library, site server can't be a DP) must
                    # have at least one REAL DP -- a non-pull SiteSystem DP with a LOCAL
                    # content library -- or nothing can serve content (and any pull DP in
                    # the site has nothing to pull from).
                    $DPsForSiteCode = $list2ForDP | Where-Object { $_.Role -eq "SiteSystem" -and $_.siteCode -eq $vm.SiteCode -and $_.installDP -eq $true -and (-not $_.enablePullDP) }
                    if (-not $DPsForSiteCode) {
                        Add-ValidationMessage -Message "Passive Validation: [$($vm.vmName)] SiteCode $($vm.SiteCode) does not contain a real (non-pull) DP with a local content library, which is required with a remote content library. A pull DP does not count -- it has no content of its own to serve; add a dedicated SiteSystem DP (installDP, not a pull DP)." -ReturnObject $return -Failure
                    }
                    else {
                        write-log -verbose "Passive Site has DP $($DPsForSiteCode.vmName)"
                    }

                    # An HA site server cannot host a DP. HA relocates the site's content
                    # library to a remote share (passive server's remoteContentLibVM ->
                    # Move-CMContentLibrary) and InstallPassiveSiteServer.ps1 removes the
                    # site server's DP before the move -- a site server with a remote content
                    # library can't serve content. If a DP is (re-)added to it anyway (e.g. the
                    # pull-DP-source logic auto-enables installDP on a pull source), it serves
                    # HTTP content from the now-empty local SCCMContentLib and every pull-DP
                    # download gets HTTP 404. So the site server's own DP must stay off; the
                    # site's DP has to be a dedicated SiteSystem DP (checked above).
                    if ($vm.installDP -eq $true) {
                        Add-ValidationMessage -Message "Passive Validation: [$($vm.vmName)] is an HA site server (passive [$($passiveSite.vmName)]) whose content library is relocated to a remote share, so it cannot host a Distribution Point (HA removes the site server's DP; any DP re-added to it serves content from the empty local library -> HTTP 404). Set installDP=false on [$($vm.vmName)] and use a dedicated SiteSystem DP for the site." -ReturnObject $return -Failure
                    }
                }
            }

            if ($vm.sqlVersion) {

                # Supported SQL
                if ($Common.Supported.SqlVersions -notcontains $vm.sqlVersion) {
                    Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain a supported sqlVersion [$($vm.sqlVersion)]." -ReturnObject $return -Failure
                }

                # Client-OS SiteSystems have a dedicated SQL failure in
                # Test-ValidRoleSiteSystem. Do not add the older generic Server-OS
                # warning as a second error; it obscures the actionable reason and
                # was the only message surfaced by GenConfig after a stale Add SQL
                # action. Every other SQL host still requires a Server OS here.
                if (-not (Test-SiteSystemClientOperatingSystem -VirtualMachine $vm)) {
                    Test-ValidVmServerOS -VM $vm -ReturnObject $return
                }

                # sqlInstance dir
                Test-ValidVmPath -VM $vm -PathProperty "sqlInstanceDir" -ValidPathExample "F:\SQL" -ReturnObject $return

                # sqlInstanceName
                if (-not $vm.sqlInstanceName) {
                    Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain sqlInstanceName." -ReturnObject $return -Warning
                }

                if ($vm.Role -ne "Secondary") {
                    if (-not $vm.sqlport) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] does not contain sqlport." -ReturnObject $return -Warning
                    }

                    # Put number first to force numeric comparisons
                    if ((1 -gt $vm.sqlport) -or (65535 -lt $vm.sqlport)) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] sqlport: $($vm.sqlport) Out of range" -ReturnObject $return -Warning
                    }

                    if ($vm.sqlport -in 21, 80, 135, 139, 443, 445, 860, 1434, 2382, 2383, 2393, 2394, 2725, 3260, 3389, 4022, 5022, 7022) {
                        Add-ValidationMessage -Message "SQL Validation: [$($vm.vmName)] sqlPort cannot use OS reserved port #" -ReturnObject $return -Warning
                    }
                }
                # Minimum SQL Memory
                if ($VM.memory / 1 -lt 4GB) {
                    Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] must contain a minimum of 4GB memory when using SQL." -ReturnObject $return -Failure
                }

                if ($vm.Role -eq "SQLAO") {
                    if ($vm.sqlport -ne 1433) {
                        Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] SQL Port must be 1433 on SQLAO due to issue SqlServerDSC #329" -ReturnObject $return -Failure
                    }
                    # SQLAO requires domain service accounts: the WSFC cluster + AG
                    # endpoints authenticate as the SQL service identity, so LocalSystem
                    # is not usable. (The genconfig picker hides the LocalSystem option
                    # for SQLAO; this catches a hand-edited config too.)
                    if ($vm.SqlServiceAccount -eq "LocalSystem") {
                        Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] SQLAO cannot use LocalSystem for SqlServiceAccount. A domain account is required for the cluster/Availability Group." -ReturnObject $return -Failure
                    }
                    if ($vm.SqlAgentAccount -eq "LocalSystem") {
                        Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] SQLAO cannot use LocalSystem for SqlAgentAccount. A domain account is required for the cluster/Availability Group." -ReturnObject $return -Failure
                    }
                    if ($vm.sqlVersion -match '201[0-6]') {
                        Add-ValidationMessage -Message "SQL Validation: VM [$($vm.vmName)] SQLAO does not support $($vm.sqlVersion). Use SQL Server 2017 or later." -ReturnObject $return -Failure
                    }
                    # Both replicas of a SQLAO pair must sit on the SAME domain network.
                    # The failover cluster forms a single client-facing cluster IP + AG
                    # listener IP on one subnet; if the two nodes live on different
                    # networks, no single IP is hostable by both and New-Cluster fails
                    # with "no appropriate ClusterAndClient network was found to host it".
                    # Only the primary node carries OtherNode, so check from there.
                    if ($vm.OtherNode) {
                        $otherVm = $ConfigObject.virtualMachines | Where-Object { $_.vmName -eq $vm.OtherNode }
                        if ($otherVm) {
                            $thisNet  = if ($vm.network) { $vm.network } else { $ConfigObject.vmOptions.network }
                            $otherNet = if ($otherVm.network) { $otherVm.network } else { $ConfigObject.vmOptions.network }
                            if ($thisNet -ne $otherNet) {
                                Add-ValidationMessage -Message "SQL Validation: SQLAO nodes [$($vm.vmName)] ($thisNet) and [$($vm.OtherNode)] ($otherNet) are on different networks. Both replicas must share one network so the cluster/AG IP is hostable by both." -ReturnObject $return -Failure
                            }
                        }
                    }
                }
            }

            # WSUS Validations
            # ================
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing WSUS" -PercentComplete 37
            if ($vm.Role -eq "WSUS" -or $vm.InstallSUP) {
                if (-not $vm.wsusContentDir) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not have a wsusContentDir." -ReturnObject $return -Failure
                }
                if ($vm.InstallSup -and -not $vm.SiteCode) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] does not have a SiteCode." -ReturnObject $return -Failure
                }

                # Determine if this WSUS/SUP will use the Windows Internal Database (WID).
                # Mirrors Phase6.ps1: WID is used unless a SQL database server is specified
                # (explicit wsusDataBaseServer other than WID, a local sqlVersion, a
                # remoteSQLVM, or a resolved WSUSSqlServer).
                $usesWid = $false
                if ($vm.wsusDataBaseServer) {
                    $usesWid = ($vm.wsusDataBaseServer -eq "WID")
                }
                else {
                    $usesWid = -not ($vm.sqlVersion -or $vm.remoteSQLVM -or $vm.thisParams.WSUSSqlServer)
                }

                if ($usesWid) {
                    # WID co-located with WSUS is memory-hungry: during the first full
                    # catalog sync the WsusPool IIS app pool plus the WID sqlservr.exe
                    # can exceed 4-5GB. On an undersized VM the pool hits its memory
                    # recycle cap mid-Categories, returns 503, and the sync is killed /
                    # restarts forever. Require at least 8GB so the first sync survives.
                    $memGB = $null
                    if ($vm.memory -is [string]) {
                        $m = $vm.memory.ToUpperInvariant()
                        if ($m.EndsWith("GB")) { $memGB = [int]$m.Replace("GB", "") }
                        elseif ($m.EndsWith("MB")) { $memGB = [math]::Floor([int]$m.Replace("MB", "") / 1024) }
                    }
                    if ($null -ne $memGB -and $memGB -lt 8) {
                        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] uses WID for the WSUS database and has only [$($vm.memory)] memory. WID + WSUS catalog sync needs at least 8GB or the first sync gets OOM/recycle-killed mid-sync. Increase memory to 8GB or more, or use a remote SQL server." -ReturnObject $return -Failure
                    }
                }

                if ($vm.InstallSUP) {                  
                    $property = $vm
                    if ($property.ParentSiteCode -or $property.SiteCode) {
                        $sitecode = $property.SiteCode                    
                        if ($sitecode) {
                            $Parent = Get-ParentSiteServerForSiteCode -deployConfig $deployConfig -siteCode $sitecode -type VM -SmartUpdate:$false
                         
                            if ($Parent.SiteCode) {
                                $list2 = Get-List2 -deployConfig $deployConfig
                                $existingSUP = $list2 | Where-Object { $_.InstallSUP -and $_.SiteCode -eq $Parent.SiteCode }
                                if (-not $existingSUP) {                                                       
                                    Add-ValidationMessage -Message "$vmName SUP role cannot be installed on downlevel sites until the parent site ($($Parent.SiteCode)) has a SUP" -ReturnObject $return -Failure
                                }
                            }
                            else {
                                if ($vm.role -eq "CAS") {
                                    # Include existing VMs (Get-List2) so that when modifying a config,
                                    # a SUP already deployed on the child Primary still counts.
                                    $list2 = Get-List2 -deployConfig $deployConfig

                                    #Get a list of child site codes
                                    $childSiteCodes = @($list2 | Where-Object { $_.ParentSiteCode -eq $vm.sitecode } | Select-Object -ExpandProperty SiteCode -Unique)

                                    # This is the Top Level Site, Child sites should have a SUP role. Validate that.
                                    $childSites = @($list2 | Where-Object { ($_.SiteCode -in $childSiteCodes) -and $_.InstallSUP })

                                    if ($childSites.Count -eq 0) {
                                        #Add-ValidationMessage -Message "$vmName SUP role can not be installed on the CAS site ($($sitecode)) without a Primary ($($childSiteCodes -join ',')) site having a SUP role." -ReturnObject $return -Failure
                                        Add-ValidationMessage -Message "$vmName SUP role installed on the CAS ($($sitecode)) must also have a SUP on a Primary ($($childSiteCodes -join ',')) site." -ReturnObject $return -Failure
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Test-ValidUserName -name $vm.domainUser -vmName $vm.vmName

            # SQL service/agent accounts are created as domain users (unless set
            # to the built-in LocalSystem), so hold them to the same naming rules
            # as domainUser: reserved names, reserved device names, invalid chars,
            # and length.
            if ($vm.SqlServiceAccount -and $vm.SqlServiceAccount -ne "LocalSystem") {
                Test-ValidUserName -name $vm.SqlServiceAccount -vmName $vm.vmName
            }
            if ($vm.SqlAgentAccount -and $vm.SqlAgentAccount -ne "LocalSystem") {
                Test-ValidUserName -name $vm.SqlAgentAccount -vmName $vm.vmName
            }

        }

        # DC Validation
        # ==============
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing DC" -PercentComplete 35
        Test-ValidRoleDC -ConfigObject $deployConfig -ReturnObject $return

       

        # CAS Validations
        # ==============
        if ($containsCS) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing CAS" -PercentComplete 39
            $CSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "CAS" }
            foreach ($CSVM in $CSVMs) {
                $vmName = $CSVM.vmName
                $vmRole = $CSVM.role

                # Single CAS
                #if (Test-SingleRole -VM $CSVM -ReturnObject $return) {

                # CAS without Primary
                if (-not $containsPS) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified without Primary Site; When deploying CAS Role, you must add a Primary Role as well." -ReturnObject $return -Warning
                }

                # Validate CAS role
                #Test-ValidRoleSiteServer -VM $CSVM -ConfigObject $deployConfig -ReturnObject $return

                #}
            }
        }

        #siteName Validations
        # ==============

        foreach ($vm in $deployConfig.virtualMachines) {
            if ($vm.siteName) {
                if ($vm.siteName.Length -gt 127) {
                    Add-ValidationMessage -Message "$vmRole Validation: VM [$($vm.vmName)] siteName is greater than 127 chars" -ReturnObject $return -Warning
                }
            }
            if ($vm.SiteCode) {
                Test-ValidRoleSiteServer -VM $vm -ConfigObject $deployConfig -ReturnObject $return
            }
        }

        # Primary Validations
        # ==============
        if ($containsPS) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Primary" -PercentComplete 42
            # Validate Primary role
            $PSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" }

            # Cache CAS site codes once — same for every Primary in this deployment.
            $cachedCasSiteCodes = $null

            # if (Test-SingleRole -VM $PSVM -ReturnObject $return) {

            foreach ($PSVM in $PSVMs) {

                $vmName = $PSVM.vmName
                $vmRole = $PSVM.role
                $psParentSiteCode = $PSVM.parentSiteCode
                #Test-ValidRoleSiteServer -VM $PSVM -ConfigObject $deployConfig -ReturnObject $return

                # Valid parent Site Code
                if ($psParentSiteCode) {
                    if ($null -eq $cachedCasSiteCodes) {
                        $cachedCasSiteCodes = @(Get-ValidCASSiteCodes -Config $deployConfig -Domain $deployConfig.vmOptions.domainName)
                    }
                    $parentCodes = $cachedCasSiteCodes -join ","
                    if ($psParentSiteCode -notin $cachedCasSiteCodes) {
                        Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] contains parentSiteCode [$psParentSiteCode] which is invalid. Valid Parent Site Codes: $parentCodes" -ReturnObject $return -Warning
                    }
                }

                # Other Site servers must be running
                if ($psParentSiteCode -and $deployConfig.cmOptions.updateToLatest) {
                    $notRunning = Get-ExistingSiteServer -DomainName $deployConfig.vmOptions.domainName | Where-Object { $_.State -ne "Running" }
                    $notRunningNames = $notRunning.vmName -join ","
                    if ($notRunning.Count -gt 0) {
                        Add-ValidationMessage -Message "$vmRole Validation: Primary [$vmName] requires other site servers [$notRunningNames] to be running." -ReturnObject $return -Warning
                        Get-List -type VM -SmartUpdate | Out-Null
                    }
                }

                # CAS with Primary, without parentSiteCode
                # Only validate when this Primary actually claims a parent;
                # a Primary with no parentSiteCode is a standalone top-level
                # hierarchy and is allowed to coexist with a CAS in the same
                # config (each owns its own cmOptions block).
                if ($containsCS -and $psParentSiteCode) {
                    if ($psParentSiteCode -notin $CSVMs.siteCode) {
                        $casSiteCodesList = ($CSVMs.siteCode -join ",")
                        Add-ValidationMessage -Message "$vmRole Validation: VM [$vmName] specified with CAS, but parentSiteCode [$psParentSiteCode] does not match any CAS Site Code [$casSiteCodesList]." -ReturnObject $return -Warning
                    }
                }

            }
        }

        # Secondary Validations
        # ======================
        if ($containsSecondary) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Secondary" -PercentComplete 45
            $SecondaryVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" }

            #if (Test-SingleRole -VM $SecondaryVMs -ReturnObject $return) {

            # Prep for multi-subnet, but blocked right now by Test-SingleRole
            foreach ($SECVM in $SecondaryVMs) {
                #Test-ValidRoleSiteServer -VM $SECVM -ConfigObject $deployConfig -ReturnObject $return
            }

            #}

        }

        # Passive Validations
        # ===================
        if ($containsPassive) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Passive" -PercentComplete 50
            $passiveVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }

            foreach ($VM in $passiveVM) {
                Test-ValidRolePassiveSite -VM $VM -ConfigObject $deployConfig -ReturnObject $return
            }

        }

        # FileServer Validations
        # ======================
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing FileServer" -PercentComplete 55
        $FSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "FileServer" }
        foreach ($FSVM in $FSVMs) {
            Test-ValidRoleFileServer -VM $FSVM -ReturnObject $return
        }

        # Site System Validations
        # ========================
        if ($containsSiteSystem) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Site System" -PercentComplete 60
            $systems = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" }

            foreach ($VM in $systems) {
                Test-ValidRoleSiteSystem -VM $VM -ReturnObject $return
            }
        }

        # OSDClient Validations
        # =====================
        # An OSDClient PXE-boots to run an OS-deployment task sequence. PXE is a
        # subnet-local DHCP broadcast, so an OSDClient can only boot from a DP on
        # its OWN subnet (memlabs does not configure cross-subnet DHCP relay / ip-
        # helper). With no DP on the subnet, perfloading distributes no OSD content
        # there and PXE can't work -- but perfloading only WARNs at BUILD time, by
        # which point the mis-configured lab is already deploying. Catch it up front
        # so the user adds a DP (or moves the OSDClient) before deploying.
        $osdClientVMs = @($deployConfig.virtualMachines | Where-Object { $_.role -eq "OSDClient" })
        if ($osdClientVMs.Count -gt 0) {
            # Include EXISTING VMs so an already-deployed DP on the subnet counts
            # (avoids a false block when adding an OSDClient to an existing lab).
            $allVmsForOsd = Get-List2 -deployConfig $deployConfig
            # OSD is a ConfigMgr feature: only meaningful when the topology has a CM
            # site (a site server). In a No-ConfigMgr lab an OSDClient is just an
            # empty Gen2 VM with no OSD/PXE to do, so don't require a DP for it.
            $hasCmSite = @($allVmsForOsd | Where-Object { $_.role -in 'CAS', 'Primary', 'Secondary' }).Count -gt 0
            if ($hasCmSite) {
                $osdDefaultNet = $deployConfig.vmOptions.network
                $osdNetOf = { param($v) if ($v.network) { "$($v.network)" } else { "$osdDefaultNet" } }
                # A DP is any VM that installs one -- a real DP or a pull DP (both can
                # host OSD content + have PXE enabled). Matches perfloading's DP search.
                $osdDpSubnets = @($allVmsForOsd | Where-Object { $_.installDP -eq $true -or $_.enablePullDP -eq $true } | ForEach-Object { & $osdNetOf $_ } | Where-Object { $_ } | Select-Object -Unique)
                foreach ($osd in $osdClientVMs) {
                    $osdNet = & $osdNetOf $osd
                    if ($osdDpSubnets -notcontains $osdNet) {
                        Add-ValidationMessage -Message "OSDClient Validation: VM [$($osd.vmName)] is on subnet [$osdNet], which has no Distribution Point. An OSDClient PXE-boots from a subnet-local DP (cross-subnet PXE is not supported), so OSD content can't be distributed there and PXE can't work. Add a DP (a Primary/SiteSystem with installDP, or a pull DP) on subnet [$osdNet], or place the OSDClient on a subnet that already has one." -ReturnObject $return -Warning
                    }
                }
            }
        }

        # MP database replica: two replicas on the SAME SQL server must use SEPARATE
        # instances. Group replica MPs by their replica SQL host and fail if any two
        # resolve to the same server + instance.
        $replicaMPs = @($deployConfig.virtualMachines | Where-Object { $_.role -eq "SiteSystem" -and $_.installMP -and $_.useDatabaseReplica -and $_.replicaSqlServerVM })
        foreach ($grp in ($replicaMPs | Group-Object -Property replicaSqlServerVM)) {
            if ($grp.Count -lt 2) { continue }
            $instanceMap = @{}
            foreach ($mp in $grp.Group) {
                $replicaSQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $mp.replicaSqlServerVM } | Select-Object -First 1
                if (-not $replicaSQLVM) {
                    $replicaSQLVM = Get-List -type VM -DomainName $deployConfig.vmOptions.DomainName | Where-Object { $_.vmName -eq $mp.replicaSqlServerVM } | Select-Object -First 1
                }
                $instance = "MSSQLSERVER"
                if ($replicaSQLVM -and $replicaSQLVM.sqlInstanceName) {
                    $instance = $replicaSQLVM.sqlInstanceName
                }
                $key = $instance.ToUpperInvariant()
                if ($instanceMap.ContainsKey($key)) {
                    Add-ValidationMessage -Message "Role Conflict: MPs [$($instanceMap[$key])] and [$($mp.vmName)] both host a database replica on SQL server [$($mp.replicaSqlServerVM)] instance [$instance]. Each replica on a shared SQL server must use a separate SQL instance." -ReturnObject $return -Failure
                }
                else {
                    $instanceMap[$key] = $mp.vmName
                }
            }
        }

        # Role Conflicts
        # ==============
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Roles" -PercentComplete 65
        # CAS/Primary must include DC
        if (($containsCS -or $containsPS) -and -not $deployConfig.parameters.DCName ) {
            Add-ValidationMessage -Message "Role Conflict: CAS or Primary role specified but a new/existing DC was not found; CAS/Primary roles require a DC." -ReturnObject $return -Warning
        }

        # Primary site without CAS
        $PSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" -and $_.parentSiteCode }
        $SSVMs = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" }
        # Cache Get-List2 result once for both loops below — same expensive call.
        $existingList2 = $null
        if ($PSVMs -or $SSVMs) {
            $existingList2 = @(Get-List2 -DeployConfig $deployConfig)
        }
        foreach ($PSVM in $PSVMs) {
            $existingCS = $existingList2 | Where-Object { $_.role -eq "CAS" -and $_.siteCode -eq $PSVM.parentSiteCode }
            if (-not $existingCS) {
                Add-ValidationMessage -Message "Role Conflict: $($PSVM.vmName) with parentSiteCode $($PSVM.parentSiteCode) requires a CAS, which was not found." -ReturnObject $return -Warning
            }
        }

        # Secondary site without parent
        foreach ($SSVM in $SSVMs) {
            $existingPS = $existingList2 | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $SSVM.parentSiteCode }
            if (-not $existingPS) {
                Add-ValidationMessage -Message "Role Conflict: $($SSVM.vmName) with parentSiteCode [$($SSVM.parentSiteCode)] requires a Primary, which was not found." -ReturnObject $return -Warning
            }
        }

        # tech preview and hierarchy
        if ($deployConfig.cmOptions.version -eq "tech-preview") {
            $anyPS = $deployConfig.VirtualMachines | Where-Object { $_.role -eq "Primary" }
            if ($anyPS.Count -gt 1) {
                Add-ValidationMessage -Message "Version Conflict: Tech-Preview specified with more than one Primary; Tech Preview doesn't support support multiple sites." -ReturnObject $return -Warning
            }
            if ($anyPS.Count -eq 1) {
                if ($anyPS.parentSiteCode) {
                    Add-ValidationMessage -Message "Version Conflict: Tech-Preview specified with a parent Site Code [$($anyPS.parentSiteCode)]; Tech Preview doesn't support support a Hierarchy." -ReturnObject $return -Warning
                }
            }
            $anyCS = $deployConfig.VirtualMachines | Where-Object { $_.role -eq "CAS" }
            if ($anyCS) {
                Add-ValidationMessage -Message "Version Conflict: Tech-Preview specified with a CAS; Tech Preview doesn't support CAS." -ReturnObject $return -Warning
            }
        }

        # Total Memory
        # =============
        if ($final) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Memory" -PercentComplete 75

            $totalMemory = ($deployConfig.virtualMachines.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum).Sum / 1GB
            $availableMemory = Get-AvailableMemoryGB -ExcludeVMs $deployConfig.virtualMachines.vmName

            if ($totalMemory -gt $availableMemory) {
                if (-not $enableDebug) {
                    Add-ValidationMessage -Message "Deployment Validation: Total Memory Required [$($totalMemory)GB] is greater than available memory [$($availableMemory)GB] [8GB buffer]." -ReturnObject $return -Warning
                }
            }
        }


        # Test URLS
        # ==========

        if ($final) {
            Write-Progress2 -Activity "Testing URLS" -Status "Testing URLS" -PercentComplete 77
            Write-Host
            Write-Log -SubActivity "Testing URLS"

            if (-not $Common.AzureFileList.Urls) {
                Add-ValidationMessage -Message "Deployment Validation: No URLs found to test." -ReturnObject $return -Failure
            }
            else {
                # Build the set of URL keys actually needed by this deployment,
                # taking StartPhase into account so we skip URLs for phases already done.
                # Phase usage: DotNet=2, VCredist/SQLClient/OleDB/SSMS/ADK/ADKPE=3,
                #              hallengren=4, PBIRS=7, ReportBuilder/PMPC/ODBC/ADK/ADKPE=8
                $requiredUrlKeys = @()

                # Phase 2: DotNet
                if ($StartPhase -le 2) {
                    $requiredUrlKeys += 'DotNet'
                }

                # Phase 3: VCredist, VCredistX86, SQLClient, OleDB, ODBC, SSMS, ADK, ADKPE
                if ($StartPhase -le 3) {
                    $requiredUrlKeys += @('VCredist', 'VCredistX86', 'SQLClient', 'OleDB', 'ODBC')

                    $hasSQL = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion }
                    $hasSSMS = $deployConfig.virtualMachines | Where-Object { $_.installSSMS -eq $true }
                    if ($hasSQL -or $hasSSMS) {
                        $requiredUrlKeys += 'SSMS'
                    }

                    $hasSiteServers = $containsCS -or $containsPS -or $containsPassive
                    if ($hasSiteServers) {
                        $requiredUrlKeys += @('ADK', 'ADKPE')
                    }
                }

                # Phase 4: hallengren
                if ($StartPhase -le 4) {
                    if (-not $hasSQL) { $hasSQL = $deployConfig.virtualMachines | Where-Object { $_.sqlVersion } }
                    if ($hasSQL) {
                        $requiredUrlKeys += 'hallengren'
                    }
                }

                # Phase 7: PBIRS
                if ($StartPhase -le 7) {
                    $hasRP = $deployConfig.virtualMachines | Where-Object { $_.installRP -eq $true }
                    if ($hasRP) {
                        $requiredUrlKeys += 'PBIRS'
                    }
                }

                # Phase 8: ReportBuilder, PMPC, ODBC, ADK/ADKPE (also used here)
                if ($StartPhase -le 8) {
                    $hasSiteServers = $containsCS -or $containsPS -or $containsPassive
                    $hasSecondary = $containsSecondary

                    if ($hasSiteServers -or $hasSecondary) {
                        $requiredUrlKeys += 'ReportBuilder'
                    }
                    # ADK/ADKPE are also installed in Phase 8 for CAS/Primary/Passive
                    if ($hasSiteServers) {
                        $requiredUrlKeys += @('ADK', 'ADKPE')
                    }
                    # ODBC also used in Phase 8 for Secondary/CAS/Primary
                    if ($hasSiteServers -or $hasSecondary) {
                        $requiredUrlKeys += 'ODBC'
                    }
                    $hasPMPC = $deployConfig.virtualMachines | Where-Object { $_.InstallPatchMyPC -eq $true }
                    if ($hasPMPC) {
                        $requiredUrlKeys += 'PMPC'
                    }
                }

                # BgInfo is only used during base image creation, skip during deployment.

                # De-duplicate
                $requiredUrlKeys = $requiredUrlKeys | Select-Object -Unique

                $Common.AzureFileList.Urls | ForEach-Object {
                    $_.psobject.properties | ForEach-Object {
                        if ($_.name -notin $requiredUrlKeys) { return }
                        try {
                            if (-not (Test-URL -url $_.value -name $_.name )) {
                                Add-ValidationMessage -Message "Deployment Validation: URL $($_.value) for $($_.name) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                            }
                        }
                        catch {
                            Add-ValidationMessage -Message "Error occurred while testing URL $($_.value) for $($_.name): $($_.Exception.Message)" -ReturnObject $return -Failure
                        }
                    }
                }
            }

            # CM download URLs: only test the version this deployment uses (Phase 8).
            if ($StartPhase -le 8) {
                $cmVersionNeeded = $deployConfig.cmOptions.version
                foreach ($version in $common.AzureFileList.CmVersions) {
                    if (-not $version.filename) {
                        if (-not $cmVersionNeeded) { continue }
                        if ($cmVersionNeeded -notin $version.versions) { continue }
                        try {
                            if (-not (Test-URL -url $version.downloadurl -name $version.baselineVersion )) {
                                Add-ValidationMessage -Message "Deployment Validation: URL $($version.downloadurl) for CM Version $($version.baselineVersion) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                            }
                        }
                        catch {
                            Add-ValidationMessage -Message "Error occurred while testing URL $($version.downloadurl) for CM Version $($version.baselineVersion): $($_.Exception.Message)" -ReturnObject $return -Failure
                        }
                    }
                }
            }

            # SQL CU URLs: only test versions used by VMs in the deployment (Phase 4).
            if ($StartPhase -le 4) {
                $sqlVersionsNeeded = @($deployConfig.virtualMachines.sqlVersion | Where-Object { $_ } | Select-Object -Unique)
                foreach ($sql in $common.AzureFileList.ISO) {
                    if ($sqlVersionsNeeded.Count -eq 0 -or $sql.id -notin $sqlVersionsNeeded) { continue }
                    try {
                        if (-not (Test-URL -url $sql.cuUrl -name $sql.id )) {
                            Add-ValidationMessage -Message "Deployment Validation: CU URL $($sql.cuUrl) for SQL Version $($sql.id) is not working. This may cause deployment failures" -ReturnObject $return -Warning
                        }
                    }
                    catch {
                        Add-ValidationMessage -Message "Error occurred while testing CU URL $($sql.cuUrl) for SQL Version $($sql.id): $($_.Exception.Message)" -ReturnObject $return -Failure
                    }
                }
            }

        }

        # Unique Names
        # =============

        # Names in deployment
        Write-Progress2 -Activity "Validating Configuration" -Status "Testing Unique Names" -PercentComplete 80
        $vmInDeployment = $virtualMachinesNoExisting.vmName
        if ($vmInDeployment) {
            $unique1 = $vmInDeployment | Select-Object -Unique
            $compare = Compare-Object -ReferenceObject $vmInDeployment -DifferenceObject $unique1
            if ($compare) {
                $duplicates = $compare.InputObject -join ","
                Add-ValidationMessage -Message "Name Conflict: Deployment contains duplicate VM names [$duplicates]" -ReturnObject $return -Failure
            }
        }

        # Names in domain: a NEW (non-existing) config VM whose name matches a VM that
        # already exists in Hyper-V is, by MemLabs' own new-vs-existing rule (New-Lab:
        # "prefix+vmName -notin existingVMs.vmName" => new), treated as a RE-DEPLOY /
        # reuse of that existing VM -- which is legitimate and must NOT be blocked
        # (that would break every re-deploy of a saved config, where all VMs already
        # exist). Two things ARE genuine conflicts, though:
        #   1. A name owned by a VM in a DIFFERENT domain. Hyper-V VM names are unique
        #      host-wide, so e.g. deploying CO-DC1 (contoso) when AD-DC1... no -- more
        #      concretely, two labs whose prefixes collide would both resolve a VM to
        #      the same host name (e.g. contoso and adatum both producing DC1). The
        #      second deploy can't create it; it belongs to the other lab. Hard-fail.
        #   2. A same-domain name match whose ROLE differs -- repurposing the name would
        #      overwrite/clobber the existing VM (e.g. an existing DC re-defined as an
        #      OSDClient, or a DomainMember re-defined as WSUS). Hard-fail.
        # A same-domain, same-role match is a normal re-deploy and is NOT flagged.
        if ($vmInDeployment) {
            Write-Progress2 -Activity "Validating Configuration" -Status "Testing Unique Names" -PercentComplete 85
            $configDomain = $deployConfig.vmOptions.domainName
            $allExisting = @(Get-List -Type VM -SmartUpdate)
            foreach ($newVM in $virtualMachinesNoExisting) {
                if (-not $newVM.vmName) { continue }
                $nameMatches = @($allExisting | Where-Object { $_.vmName -eq $newVM.vmName })
                if ($nameMatches.Count -eq 0) { continue }

                # 1. Cross-domain host-wide name collision.
                $otherDomainMatch = $nameMatches | Where-Object { $_.domain -and $configDomain -and ($_.domain -ne $configDomain) } | Select-Object -First 1
                if ($otherDomainMatch) {
                    Add-ValidationMessage -Message "Name Conflict: VM [$($newVM.vmName)] already exists in Hyper-V in a different domain [$($otherDomainMatch.domain)]. Hyper-V VM names must be unique on the host; use a different prefix or name for this deployment." -ReturnObject $return -Failure
                    continue
                }

                # 2. Same-domain reuse with a different role => overwrite.
                $sameDomainMatch = $nameMatches | Where-Object { -not $_.domain -or -not $configDomain -or ($_.domain -eq $configDomain) } | Select-Object -First 1
                if ($sameDomainMatch) {
                    $existingRole = "$($sameDomainMatch.role)".Trim()
                    $newRole = "$($newVM.role)".Trim()
                    if ($existingRole -and $newRole -and ($existingRole -ne $newRole)) {
                        Add-ValidationMessage -Message "Name Conflict: VM [$($newVM.vmName)] already exists in Hyper-V as role [$existingRole], but this deployment defines it as role [$newRole]. Deploying would overwrite the existing VM. Rename the new VM, or remove the existing one first." -ReturnObject $return -Failure
                    }
                }
            }

            # The cluster CNO and AG listener VCO are AD computer objects the host
            # reaches by NetBIOS name, exactly like a VM. vmOptions.prefix is optional,
            # so nothing else keeps them unique across labs.
            Test-CrossDomainNameConflict -NewVMs $virtualMachinesNoExisting -ExistingVMs $allExisting -ConfigDomain $configDomain -ReturnObject $return
        }

        if (-not $fast) {
            # Add existing VM's
            Write-Progress2 -Activity "Validating Configuration" -Status "Adding Existing" -PercentComplete 90
            Add-ExistingVMsToDeployConfig -config $deployConfig

            # Guard: don't silently stack NEW VMs onto a domain whose core
            # infrastructure never finished DEPLOYING. The failed first deploy
            # that leaves a half-built DC / site server (e.g. a Primary with no
            # SQL installed) is exactly the state that produces confusing
            # downstream failures when more VMs are added on top of it.
            # Add-ExistingVMsToDeployConfig has just folded the existing
            # (hidden) VMs into the config, so their persisted lastPhaseComplete
            # is available here.
            #
            # Phase 10 is the last DEPLOYMENT phase; Phase 11 is functional
            # VALIDATION only (it stamps lastPhaseComplete=11). A critical VM at
            # lastPhaseComplete=10 is therefore fully deployed -- only the
            # post-deploy validation pass didn't finish/succeed. That is a
            # legitimately fine base to extend (something the operator is willing
            # to accept), so we do NOT flag it. Only a VM below 10 (deployment
            # itself incomplete) is advised on.
            #
            # Scoped to DC / site servers (the backbone that reliably reaches
            # phase 10 -- powered-off / role-special VMs like OSDClient /
            # StandaloneRootCA are intentionally excluded) and only when there
            # are genuinely NEW (non-hidden) VMs being added. This is an
            # INFORMATION advisory (non-blocking): it is surfaced to the operator
            # but does not fail validation, so a deliberate "I know it's broken,
            # extend anyway" / resume-and-add still works. Flip -Information to
            # -Failure to make it a hard block (or -Warning to block with warning
            # semantics).
            try {
                $newVMsBeingAdded = @($deployConfig.virtualMachines | Where-Object { -not $_.hidden })
                if ($newVMsBeingAdded.Count -gt 0) {
                    $criticalRoles = @('DC', 'CAS', 'Primary', 'Secondary')
                    $existingCriticalVMs = @($deployConfig.virtualMachines | Where-Object { $_.hidden -and ($_.role -in $criticalRoles) })
                    $currentBuildVersion = $Common.MemLabsVersion
                    foreach ($criticalVM in $existingCriticalVMs) {
                        $criticalNote = Get-VMNote -VMName $criticalVM.vmName
                        if (-not $criticalNote) { continue }
                        # Don't flag LEGACY VMs. Phase 11 (validation) didn't exist
                        # in older MemLabs builds, so a VM deployed by an older build
                        # could never reach lastPhaseComplete=10/11 and must not be
                        # treated as "incomplete". Skip the check when the existing
                        # VM was last deployed by an OLDER build than the one running
                        # now. memLabsVersion is the completed-at stamp (set with
                        # -UpdateVersion); memLabsDeployVersion is written on every
                        # note touch, so it's the fallback -- which means a CURRENT-
                        # build VM that failed before the version stamp (the real
                        # footgun: a half-built Primary) still has the current build
                        # in memLabsDeployVersion and is therefore still checked.
                        # String -lt matches the YYMMDD.N comparison Set-VMNote's
                        # own version-update path already uses.
                        $criticalVer = if ($criticalNote.memLabsVersion) { $criticalNote.memLabsVersion } else { $criticalNote.memLabsDeployVersion }
                        if ($currentBuildVersion -and $criticalVer -and ($criticalVer -lt $currentBuildVersion)) {
                            Write-Log "Add-VM completeness pre-check: skipping legacy $($criticalVM.role) '$($criticalVM.vmName)' (deployed by older build $criticalVer < current $currentBuildVersion; predates Phase 11)." -LogOnly
                            continue
                        }
                        # Phase 10 = deployment complete (only Phase 11 validation
                        # outstanding) is acceptable to extend, so only advise when
                        # the deployment itself never finished (below phase 10).
                        $criticalPhase = if ($criticalNote.lastPhaseComplete) { [int]$criticalNote.lastPhaseComplete } else { 0 }
                        if ($criticalPhase -lt 10) {
                            $newNames = ($newVMsBeingAdded | Select-Object -ExpandProperty vmName) -join ', '
                            Add-ValidationMessage -Message "Existing $($criticalVM.role) '$($criticalVM.vmName)' never finished deploying (lastPhaseComplete=$criticalPhase; deployment completes at phase 10, validation at phase 11). Adding new VM(s) [$newNames] on top of an incomplete domain is not recommended -- the underlying deployment failed and stacking more VMs onto it will likely fail too. Finish/repair the existing deployment first (re-run it to completion, or remove + redeploy '$($criticalVM.vmName)'), then add the new VMs." -ReturnObject $return -Information
                        }
                    }
                }
            }
            catch {
                Write-Log "Add-VM completeness pre-check failed (non-fatal): $_" -LogOnly
            }

            # Add thisParams

            $deployConfigEx = ConvertTo-DeployConfigEx -deployConfig $deployConfig
            $return.DeployConfig = $deployConfigEx

            # Disk space validation for VHDX copies (slow: disk I/O for file sizes, drive query)
            Write-Progress2 -Activity "Validating Configuration" -Status "Checking Disk Space" -PercentComplete 92
            Test-ValidDiskSpace -ConfigObject $deployConfig -ReturnObject $return
        }
        else {
            $return.DeployConfig = $deployConfig
        }


        if ($global:SkipValidation) {
            $return.Message = $null
            $return.Valid = $true
            $return.Problems = 0
            $return.Failures = 0
            if ($fastCacheKey) { $global:TestConfigFastCache = @{ Key = $fastCacheKey; Value = $return } }
            return $return
        }

        # Return if validation failed
        if ($return.Problems -ne 0) {
            $return.Message = $return.Message.ToString().Trim()
            Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
            if ($fastCacheKey) { $global:TestConfigFastCache = @{ Key = $fastCacheKey; Value = $return } }
            return $return
        }

        # everything is good
        $return.Valid = $true
        Write-Progress2 -Activity "Validating Configuration" -Status "Validation in progress" -Completed
        if ($fastCacheKey) { $global:TestConfigFastCache = @{ Key = $fastCacheKey; Value = $return } }
        return $return
    }
    catch {
        $return.Message = $_
        $return.Problems += 1
        #$return.Failures += 1
        Write-Exception -ExceptionInfo $_
        Write-Progress2 -Activity "Validating Configuration"  -Completed        
        return $return
    }
    finally {        
        $global:DisableSmartUpdate = $OrigSmartUpdateValue
        Write-Progress2 -Activity "Validating Configuration"  -Completed
    }
}
