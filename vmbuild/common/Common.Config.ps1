# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
########################
### Config Functions ###
########################

function Test-SiteSystemClientOperatingSystem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )

    $role = ''
    $operatingSystem = ''
    if ($VirtualMachine.PSObject.Properties.Name -contains 'Role') {
        $role = "$($VirtualMachine.Role)"
    }
    if ($VirtualMachine.PSObject.Properties.Name -contains 'operatingSystem') {
        $operatingSystem = "$($VirtualMachine.operatingSystem)"
    }

    return ($role -eq 'SiteSystem' -and $operatingSystem -like 'Windows 11*')
}

# Returns the top-level site server VM from a config (CAS preferred, else standalone
# Primary, i.e. a Primary with no parentSiteCode). Returns $null when no top-level
# site server is present. Used by genconfig, summary, deploy rehydration, and
# validation to locate the canonical owner of the cmOptions block.
function Get-TopLevelSiteServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $Config
    )
    if (-not $Config -or -not $Config.virtualMachines) { return $null }
    $cas = $Config.virtualMachines | Where-Object {
        $_.role -eq 'CAS' -and -not $_.parentSiteCode
    } | Select-Object -First 1
    if ($cas) { return $cas }
    return $Config.virtualMachines | Where-Object {
        $_.role -eq 'Primary' -and -not $_.parentSiteCode
    } | Select-Object -First 1
}

# Returns the cmOptions block for a config, whether it lives at the root
# (legacy/in-flight) or on the top-level site server VM (post-migration shape).
# Returns $null if neither location has it. Read-only convenience for genconfig
# and other load-time consumers; deploy-time consumers should keep reading
# $deployConfig.cmOptions which New-DeployConfig rehydrates.
function Get-CmOptionsFromSiteServerBackup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string] $VmName,
        [Parameter(Mandatory = $true)] [string] $DomainName
    )
    # Host-context only (needs PSDirect). Remotes into the site server and returns
    # the cmOptions object from the OLDEST C:\staging\DSC\deployConfig*.json backup.
    # The site server renames its existing deployConfig.json to
    # deployConfig_<timestamp>.json before every overwrite, so the oldest backup is
    # the ORIGINAL build config -- which carries the authoritative UsePKI even on
    # legacy builds that never persisted cmOptions to the VM note. Returns $null on
    # any failure or when no backup carries a cmOptions block.
    if (-not $Common -or $Common.InJob) { return $null }
    try {
        $recoverCmScript = {
            try {
                $files = @(Get-ChildItem -Path 'C:\staging\DSC' -Filter 'deployConfig*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
                foreach ($f in $files) {
                    try { $o = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    if ($o.cmOptions) { return ($o.cmOptions | ConvertTo-Json -Depth 5 -Compress) }
                }
            }
            catch {}
            return ''
        }
        $recoverResult = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -ScriptBlock $recoverCmScript -SuppressLog
        if ($recoverResult -and $recoverResult.ScriptBlockOutput) {
            $recoveredCm = $recoverResult.ScriptBlockOutput | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($recoveredCm) { return $recoveredCm }
        }
    }
    catch {}
    return $null
}

function Get-ConfigCmOptions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $Config
    )
    if ($null -ne $Config.cmOptions) { return $Config.cmOptions }
    $topLevel = Get-TopLevelSiteServer -Config $Config
    if ($topLevel -and $topLevel.cmOptions) { return $topLevel.cmOptions }
    # Add-to-existing fallback: a child Primary (parentSiteCode set) may carry
    # the cmOptions block when the parent CAS lives in the existing deployment
    # and isn't in this config. Return the first CAS/Primary that has one.
    $anySiteServer = $Config.virtualMachines | Where-Object {
        $_.role -in @('CAS', 'Primary') -and $_.cmOptions
    } | Select-Object -First 1
    if ($anySiteServer) { return $anySiteServer.cmOptions }
    # Domain-level fallback: in add-to-existing scenarios the CAS/Primary may
    # not be in the config at all (user is only adding new VMs). Check the
    # existing VMs in the domain from the Hyper-V VM-note cache.
    if ($Config.vmOptions.domainName) {
        try {
            $existingVMs = Get-List -Type VM -DomainName $Config.vmOptions.domainName
            $existingSiteServer = $existingVMs | Where-Object {
                $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode -and $_.cmOptions
            } | Select-Object -First 1
            if ($existingSiteServer) { return $existingSiteServer.cmOptions }

            # CAS/Primary exists but has no cmOptions in its VM note (deployed
            # before cmOptions was persisted). Synthesize from domainDefaults
            # and safe defaults so validation passes and new VMs deploy.
            $anySiteServerInDomain = $existingVMs | Where-Object {
                $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode
            } | Select-Object -First 1
            if ($anySiteServerInDomain) {
                # RECOVERY: the note has no cmOptions, but the site server keeps a timestamped
                # backup of its deployConfig before every overwrite (C:\staging\DSC\deployConfig_*.json).
                # The OLDEST backup is the ORIGINAL build's config, which DID carry cmOptions --
                # including the authoritative UsePKI -- even in legacy builds that never persisted
                # cmOptions to the VM note. Remote in, read it, stamp it onto the note (so future
                # runs read it directly), and return it. This is far more reliable than inferring
                # UsePKI from per-VM flags: legacy defaulted DC.InstallCA=$true even for NON-PKI
                # labs, so InstallCA/derived pkiOptions.EnablePKI cannot distinguish PKI from eHTTP.
                # Guarded to host context (needs PSDirect); silently falls through to synthesize.
                $recoveredCm = Get-CmOptionsFromSiteServerBackup -VmName $anySiteServerInDomain.vmName -DomainName $Config.vmOptions.domainName
                if ($recoveredCm) {
                    Write-Log "Get-ConfigCmOptions: Recovered cmOptions (UsePKI=$($recoveredCm.UsePKI)) from '$($anySiteServerInDomain.vmName)' deployConfig backup on disk; stamping onto its VM note." -Verbose
                    try { Set-VMNote -vmName $anySiteServerInDomain.vmName -vmNote ([PSCustomObject]@{ cmOptions = $recoveredCm }) } catch {}
                    return $recoveredCm
                }

                # CAS/Primary exists but has no cmOptions in its VM note (deployed
                # before cmOptions was persisted). Synthesize from domainDefaults
                # and safe defaults so validation passes and new VMs deploy.
                $dcVM = $existingVMs | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                $inferredVersion = if ($dcVM -and $dcVM.domainDefaults -and $dcVM.domainDefaults.CMVersion) {
                    $dcVM.domainDefaults.CMVersion
                } else {
                    Get-CMLatestBaselineVersion
                }
                $inferredUsePKI = if ($dcVM -and $dcVM.pkiOptions -and $dcVM.pkiOptions.EnablePKI) { $true } else { $false }
                $synthesized = [PSCustomObject]@{
                    Version             = $inferredVersion
                    Install             = $true
                    PrePopulateObjects  = $true
                    EVALVersion         = $false
                    OfflineSCP          = $false
                    OfflineSUP          = $false
                    UsePKI              = $inferredUsePKI
                    EnableBLM           = $false
                    WsusImportBaseline  = $true
                }
                Write-Log "Get-ConfigCmOptions: Synthesized cmOptions from defaults (Version=$inferredVersion, UsePKI=$inferredUsePKI) - existing site server $($anySiteServerInDomain.vmName) had no cmOptions in VM note." -Verbose
                return $synthesized
            }
        }
        catch {
            # Cache may not be available (e.g. in-job context). Fall through.
        }
    }
    return $null
}

# Resolves a symbolic ConfigMgr media choice to the concrete version used by
# deployment and validation. Explicit numeric targets pass through unchanged.
function Resolve-CmVersionAlias {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    if ($Version -eq 'current-branch') {
        return Get-CMLatestBaselineVersion
    }
    return $Version
}

# Resolves symbolic ConfigMgr media choices before cmOptions is copied or
# rehydrated for deployment.  Historically current-branch lived only at the
# config root, but modern GenConfig files may also carry an authoritative copy
# on the top-level site server (and resolved copies on other site-role VMs).
# Every copy must be normalized or Resolve-VmCmOptions can return the symbolic
# value and select the stale web baseline instead of the latest shipped media.
function Resolve-ConfigCmVersionAliases {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $Config
    )

    $cmOptionsBlocks = @()
    if ($Config.cmOptions) {
        $cmOptionsBlocks += $Config.cmOptions
    }
    foreach ($vm in @($Config.virtualMachines)) {
        if ($vm.cmOptions) {
            $cmOptionsBlocks += $vm.cmOptions
        }
    }

    $aliases = @($cmOptionsBlocks | Where-Object { $_.Version -eq 'current-branch' })
    if ($aliases.Count -eq 0) { return }

    $latestBaseline = Resolve-CmVersionAlias -Version 'current-branch'
    foreach ($cmOptions in $aliases) {
        $cmOptions.Version = $latestBaseline
    }
}

# Resolves the cmOptions block that should apply to a given VM, by walking up
# its hierarchy to the top-level site server (CAS or standalone Primary) that
# owns the canonical block. Returns $null when the VM has no hierarchy
# affiliation (e.g. DC/DomainMember not bound to a site).
#
# Walks: $vm -> parentSiteCode -> ... -> top. For Passive/SiteSystem VMs which
# only have a SiteCode (no parentSiteCode), finds the owning CAS/Primary in the
# same SiteCode and resumes the walk from there. Cycle-guarded.
function Resolve-VmCmOptions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $true)] [object] $vm
    )
    if ($null -ne $vm.cmOptions) { return $vm.cmOptions }
    $current = $vm
    $visited = @{}
    while ($current) {
        if ($null -ne $current.cmOptions) { return $current.cmOptions }
        $key = "$($current.vmName)"
        if ($visited[$key]) { return $null }
        $visited[$key] = $true

        if ($current.parentSiteCode) {
            $current = $Config.virtualMachines | Where-Object {
                $_.SiteCode -eq $current.parentSiteCode -and $_.Role -in 'CAS', 'Primary'
            } | Select-Object -First 1
            continue
        }

        if ($current.SiteCode) {
            $owner = $Config.virtualMachines | Where-Object {
                $_.SiteCode -eq $current.SiteCode -and $_.Role -in 'CAS', 'Primary' -and $_.vmName -ne $current.vmName
            } | Select-Object -First 1
            if (-not $owner) { return $null }
            $current = $owner
            continue
        }

        return $null
    }
    return $null
}

# Stamps a resolved cmOptions block onto every site-role VM (CAS/Primary/
# Secondary/PassiveSite/SiteSystem) in the config that doesn't already carry
# one, so DSC phases can read $ThisVM.cmOptions directly without per-hierarchy
# guesswork. Deep-clones via JSON round-trip so later mutations don't bleed
# across VMs.
function Set-VmCmOptionsResolved {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object] $Config
    )
    if (-not $Config -or -not $Config.virtualMachines) { return }
    $siteRoles = @('CAS', 'Primary', 'Secondary', 'PassiveSite', 'SiteSystem')
    foreach ($vm in $Config.virtualMachines) {
        if ($vm.Role -notin $siteRoles) { continue }
        if ($null -ne $vm.cmOptions) { continue }
        $resolved = Resolve-VmCmOptions -Config $Config -vm $vm
        if (-not $resolved) { continue }
        $clone = $resolved | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
        $vm | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $clone -Force
    }
}

# Migrates a config's root-level cmOptions onto the top-level site server VM.
# Idempotent: a no-op when root cmOptions is already absent. Called from
# Get-UserConfiguration after all existing root-level reads have completed.
# When no site-server VM exists in the file to receive it (e.g. add-to-existing
# configs that only contain PassiveSite/SiteSystem/FileServer), the root block
# is preserved so Get-ConfigCmOptions and downstream consumers can still find
# it.
function Move-CmOptionsToTopLevelSiteServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $Config
    )
    if ($null -eq $Config.cmOptions) { return }
    $topLevel = Get-TopLevelSiteServer -Config $Config
    if (-not $topLevel) {
        # Add-to-existing scenarios: the file may only contain a child Primary
        # (parentSiteCode references a CAS in the existing deployment, which
        # isn't in this file). Fall back to any CAS/Primary so the authored
        # cmOptions are preserved instead of silently dropped.
        $topLevel = $Config.virtualMachines | Where-Object {
            $_.role -in @('CAS', 'Primary')
        } | Select-Object -First 1
    }
    if (-not $topLevel) {
        # No site-server VM in this file at all (e.g. PassiveSite/SiteSystem-only
        # add-to-existing). Leave root cmOptions intact - it's still the only
        # place it can live, and Get-ConfigCmOptions checks $Config.cmOptions
        # first.
        return
    }
    # Deep-clone via JSON round-trip so subsequent mutations of either copy
    # don't bleed across.
    if ($null -eq $topLevel.cmOptions) {
        $clone = $Config.cmOptions | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
        $topLevel | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $clone -Force
    }
    $Config.PSObject.Properties.Remove('cmOptions')
}

function Resolve-ConfigVmReference {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $VmReference,
        [Parameter(Mandatory = $false)]
        [object[]] $VmNames = $null,
        [Parameter(Mandatory = $false)]
        [string] $Prefix = $null
    )

    if ([string]::IsNullOrWhiteSpace($VmReference)) { return $VmReference }

    $normalized = $VmReference
    $ansiPattern = [regex]'\x1b\[[0-9;?]*[A-Za-z]'
    $normalized = $ansiPattern.Replace($normalized, '').Trim()

    if ($normalized.Length -ge 2 -and $normalized.StartsWith('[') -and $normalized.EndsWith(']')) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }

    $normalized = $normalized.Trim("'")
    $normalized = $normalized.Trim('"')

    if (-not $VmNames -or @($VmNames).Count -eq 0) {
        return $normalized
    }

    $candidateNames = @($VmNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
    if ($candidateNames.Count -eq 0) { return $normalized }

    $exactMatch = $candidateNames | Where-Object { $_ -ieq $normalized } | Select-Object -First 1
    if ($exactMatch) { return $exactMatch }

    if ($Prefix) {
        if (-not $normalized.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $prefixedCandidate = "$Prefix$normalized"
            $prefixedMatch = $candidateNames | Where-Object { $_ -ieq $prefixedCandidate } | Select-Object -First 1
            if ($prefixedMatch) { return $prefixedMatch }
        }
        else {
            $unprefixedCandidate = $normalized.Substring($Prefix.Length)
            $unprefixedMatch = $candidateNames | Where-Object { $_ -ieq $unprefixedCandidate } | Select-Object -First 1
            if ($unprefixedMatch) { return $unprefixedMatch }
        }
    }

    return $normalized
}

function Add-VmNamePrefix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $Prefix,
        [Parameter(Mandatory = $false)]
        [object[]] $BaseNames = $null
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    if ([string]::IsNullOrEmpty($Prefix)) { return $Name }

    # A reference to a VM defined in this config is stored UNPREFIXED -- that is what
    # the unconditional vmName prepend means -- even when the base name happens to
    # begin with the prefix text (prefix "CS", VM "CSSQL"). Matching the config's own
    # base names is the only way to tell that apart from an already-prefixed value,
    # which a bare StartsWith test gets wrong in both directions.
    $baseMatch = @($BaseNames | Where-Object { $_ -and ($_ -ieq $Name) }) | Select-Object -First 1
    if ($baseMatch) { return $Prefix + $baseMatch }

    if ($Name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Already prefixed. Re-derive it from the base name so a casing difference in
        # the config still produces the exact string the VM is named.
        $stripped = $Name.Substring($Prefix.Length)
        $strippedMatch = @($BaseNames | Where-Object { $_ -and ($_ -ieq $stripped) }) | Select-Object -First 1
        if ($strippedMatch) { return $Prefix + $strippedMatch }
        return $Name
    }

    return $Prefix + $Name
}

function Remove-VmNamePrefix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $Name,
        [Parameter(Mandatory = $false)]
        [string] $Prefix
    )

    # SQLAO witness/backup share names are derived from the de-prefixed cluster
    # name, so every caller must strip identically or the deploy and the validator
    # look at different shares. .Replace() throws on an empty oldValue, which is
    # exactly what an optional (blank) prefix produces.
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    if ([string]::IsNullOrEmpty($Prefix)) { return $Name }
    return $Name.Replace($Prefix, "")
}

function Get-UserConfiguration {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Configuration Name/File")]
        [string]$Configuration
    )

    $return = [PSCustomObject]@{
        Loaded     = $false
        Config     = $null
        Message    = $null
        ConfigPath = $null
    }

    # Add extension
    if (-not $Configuration.ToLowerInvariant().EndsWith(".json")) {
        if (-not $Configuration.ToLowerInvariant().EndsWith(".memlabs")) {
            $Configuration = "$Configuration.json"
        }
    }

    $configPath = $Configuration
    if (-not (Test-Path $configPath)) {
        # Get deployment configuration
        $configPath = Join-Path $Common.ConfigPath $Configuration
        if (-not (Test-Path $configPath)) {
            $testConfigPath = Join-Path $Common.ConfigPath "tests\$Configuration"
            if (-not (Test-Path $testConfigPath)) {
                $return.Message = "Get-UserConfiguration: $Configuration not found in $configPath or $testConfigPath. Please create the config manually or use genconfig.ps1, and try again."
                return $return
            }
            $configPath = $testConfigPath
        }
    }
    try {
        Write-Log "Loading $configPath." -LogOnly
        $return.ConfigPath = $configPath
        $config = Get-Content $configPath -Force | ConvertFrom-Json

        #Apply Fixes to Config

        # vmOptions.prefix is optional. Normalize a missing/blank prefix to "" (never
        # $null): call sites do $prefix.ToLower() and .Replace($prefix, ""), and both
        # throw on $null while the same calls on "" are handled.
        if ($config.vmOptions) {
            if ([string]::IsNullOrWhiteSpace($config.vmOptions.prefix)) {
                $config.vmOptions | Add-Member -MemberType NoteProperty -Name "prefix" -Value "" -Force
            }
        }

        if ($config.cmOptions) {
            #Version                   = $latestVersion
            #Install                   = $true
            #PushClientToDomainMembers = $true
            #PrePopulateObjects        = $true
            #EVALVersion               = $false
            #InstallSCP                = $true
            #OfflineSCP                = $false
            #OfflineSUP                = $false
            #UsePKI                    = $false
            if ($null -eq ($config.cmOptions.EVALVersion)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "EVALVersion" -Value $false -Force
            }
            if ($null -eq ($config.cmOptions.UsePKI)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "UsePKI" -Value $false -Force
            }
            # Legacy: migrate UseOfflineRootCA from cmOptions to DC-level UseOfflineRoot
            if ($config.cmOptions.PSObject.Properties['UseOfflineRootCA']) {
                if ($config.cmOptions.UseOfflineRootCA) {
                    # Migrate: enable UseOfflineRoot on the first DC with InstallCA
                    foreach ($vm in @($config.virtualMachines | Where-Object { $_.role -eq 'DC' -and $_.InstallCA })) {
                        if (-not $vm.PSObject.Properties['UseOfflineRoot'] -or -not $vm.UseOfflineRoot) {
                            $vm | Add-Member -MemberType NoteProperty -Name 'UseOfflineRoot' -Value $true -Force
                            break
                        }
                    }
                }
                $config.cmOptions.PSObject.Properties.Remove('UseOfflineRootCA')
            }
            if ($null -eq ($config.cmOptions.PrePopulateObjects)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "PrePopulateObjects" -Value $true -Force
            }
            if ($null -eq ($config.cmOptions.OfflineSCP)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "OfflineSCP" -Value $false -Force
            }
            if ($null -eq ($config.cmOptions.OfflineSUP)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "OfflineSUP" -Value $false -Force
            }
            if ($null -eq ($config.cmOptions.WsusImportBaseline)) {
                # Pre-built WSUS categories baseline cab (vmbuild\azureFiles\tools\wsus\WsusCategoriesBaseline.cab),
                # imported via wsusutil before MU sync. Default-on; safe no-op when no cab is shipped.
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "WsusImportBaseline" -Value $true -Force
            }
            if ($null -eq ($config.cmOptions.EnableBLM)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "EnableBLM" -Value $false -Force
            }
            if ($null -eq ($config.cmOptions.Version)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "Version" -Value "current-branch" -Force
            }
            if ($null -eq ($config.cmOptions.Install)) {
                $config.cmOptions | Add-Member -MemberType NoteProperty -Name "Version" -Value $true -Force
            }
        }

        # --- pkiOptions: migrate from per-VM InstallCA/UseOfflineRoot if missing ---
        if (-not $config.PSObject.Properties['pkiOptions']) {
            $enablePKI = $false
            $issuingCAVM = ""
            $useOfflineRoot = $false
            $offlineRootCAVM = ""
            # Derive from existing per-VM properties
            $dcWithCA = $config.virtualMachines | Where-Object { $_.role -eq 'DC' -and $_.InstallCA } | Select-Object -First 1
            if ($dcWithCA) {
                $enablePKI = $true
                $issuingCAVM = $dcWithCA.vmName
                if ($dcWithCA.UseOfflineRoot) {
                    $useOfflineRoot = $true
                    $rootVM = $config.virtualMachines | Where-Object { $_.role -eq 'StandaloneRootCA' } | Select-Object -First 1
                    if ($rootVM) { $offlineRootCAVM = $rootVM.vmName }
                }
            }
            $config | Add-Member -MemberType NoteProperty -Name "pkiOptions" -Value ([PSCustomObject]@{
                EnablePKI       = $enablePKI
                IssuingCAVM     = $issuingCAVM
                UseOfflineRoot  = $useOfflineRoot
                OfflineRootCAVM = $offlineRootCAVM
            }) -Force
        }

        # Sync: if cmOptions.UsePKI is true, ensure pkiOptions.EnablePKI is also true
        if ($config.cmOptions -and $config.cmOptions.UsePKI -and $config.pkiOptions -and -not $config.pkiOptions.EnablePKI) {
            $config.pkiOptions.EnablePKI = $true
            if (-not $config.pkiOptions.IssuingCAVM) {
                $firstDC = $config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                if ($firstDC) { $config.pkiOptions.IssuingCAVM = $firstDC.vmName }
            }
        }

        if ($config.pkiOptions) {
            $knownVmNames = @($config.virtualMachines | ForEach-Object { $_.vmName })
            if ($config.pkiOptions.IssuingCAVM) {
                $config.pkiOptions.IssuingCAVM = Resolve-ConfigVmReference -VmReference $config.pkiOptions.IssuingCAVM -VmNames $knownVmNames -Prefix $config.vmOptions.prefix
            }
            if ($config.pkiOptions.OfflineRootCAVM) {
                $config.pkiOptions.OfflineRootCAVM = Resolve-ConfigVmReference -VmReference $config.pkiOptions.OfflineRootCAVM -VmNames $knownVmNames -Prefix $config.vmOptions.prefix
            }
        }

        if ($null -ne $config.vmOptions.domainAdminName) {
            if ($null -eq ($config.vmOptions.adminName)) {
                $config.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $config.vmOptions.domainAdminName -force
            }
            $config.vmOptions.PsObject.properties.Remove('domainAdminName')
        }

        # Determine if BLM is enabled for this domain (from config or existing site server's VM note)
        $blmEnabledForDomain = $false
        if ($config.cmOptions -and $config.cmOptions.EnableBLM) {
            $blmEnabledForDomain = $true
        }
        elseif ($config.vmOptions.domainName) {
            # No cmOptions.EnableBLM in this config — check existing top-level site server
            try {
                $existingSiteVMs = Get-List -Type VM -DomainName $config.vmOptions.domainName
                $topLevelSite = $existingSiteVMs | Where-Object {
                    $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode -and $_.cmOptions
                } | Select-Object -First 1
                if ($topLevelSite -and $topLevelSite.cmOptions.EnableBLM) {
                    $blmEnabledForDomain = $true
                    Write-Log "BLM enabled for domain '$($config.vmOptions.domainName)' (from existing site server '$($topLevelSite.vmName)' VM note)" -Verbose
                }
            }
            catch {
                # Non-fatal; Get-List may not be available in all contexts
            }
        }

        $normalizedIssuingCAVM = $null
        if ($config.pkiOptions -and $config.pkiOptions.IssuingCAVM) {
            $knownVmNames = @($config.VirtualMachines | ForEach-Object { $_.vmName })
            $normalizedIssuingCAVM = Resolve-ConfigVmReference -VmReference $config.pkiOptions.IssuingCAVM -VmNames $knownVmNames -Prefix $config.vmOptions.prefix
            $config.pkiOptions.IssuingCAVM = $normalizedIssuingCAVM
        }

        foreach ($vm in $config.VirtualMachines) {

            # Linux VMs run with static memory (Hyper-V Dynamic Memory on Linux
            # is flaky), so dynamicMinRam is meaningless. Strip it from configs
            # that picked it up before the AddVM guard was in place.
            if ($vm.osFamily -eq 'Linux' -and $vm.PSObject.Properties['dynamicMinRam']) {
                $vm.PsObject.properties.Remove('dynamicMinRam')
            }

            if ($null -ne $vm.SQLInstanceName) {
                if ($null -eq $vm.sqlPort) {
                    if ($vm.SQLInstanceName -eq "MSSQLSERVER") {
                        $vm | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value "1433" -force
                    }
                    else {
                        $vm | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value "2433" -force
                    }
                }
            }
            if ($null -ne $vm.AlwaysOnName ) {
                if ($null -eq ($vm.AlwaysOnGroupName)) {
                    $vm | Add-Member -MemberType NoteProperty -Name "AlwaysOnGroupName" -Value $vm.AlwaysOnName -force
                }
                if ($null -eq ($vm.AlwaysOnListenerName)) {
                    $vm | Add-Member -MemberType NoteProperty -Name "AlwaysOnListenerName" -Value $vm.AlwaysOnName -force
                }
                $vm.PsObject.properties.Remove('AlwaysOnName')

            }

            if ($vm.role -eq "DPMP") {
                $vm.role = "SiteSystem"
            }

            # Derive InstallCA from pkiOptions (authoritative source).
            # Applies to any domain-joined VM (DC, BDC, or member server).
            # Client OS VMs (Windows 10/11) can never host a CA; skip them entirely.
            $isClientOS = $vm.operatingSystem -and $vm.operatingSystem -like "Windows 1*"
            if ($vm.role -notin 'StandaloneRootCA', 'WorkgroupMember', 'AADClient', 'InternetClient' -and -not $isClientOS) {
                if ($config.pkiOptions -and $config.pkiOptions.EnablePKI) {
                        if ($normalizedIssuingCAVM -eq $vm.vmName) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallCA" -Value $true -Force
                    }
                    elseif ($null -eq $vm.InstallCA) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallCA" -Value $false -Force
                    }
                }
                elseif ($vm.role -eq "DC" -and $null -eq $vm.InstallCA) {
                    # Legacy fallback: no pkiOptions yet, use cmOptions.UsePKI (DC only for compat)
                    if ($config.cmOptions.UsePKI) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallCA" -Value $true -Force
                    }
                }
                # Derive UseOfflineRoot from pkiOptions
                if ($config.pkiOptions -and $config.pkiOptions.EnablePKI -and $normalizedIssuingCAVM -eq $vm.vmName) {
                    $vm | Add-Member -MemberType NoteProperty -Name "UseOfflineRoot" -Value ([bool]$config.pkiOptions.UseOfflineRoot) -Force
                }
                elseif ($vm.InstallCA -and $null -eq $vm.UseOfflineRoot) {
                    $vm | Add-Member -MemberType NoteProperty -Name "UseOfflineRoot" -Value $false -Force
                }
                # Flag as SubordinateCA when UseOfflineRoot is enabled.
                # Skip forest-trust subordinates (externalDomainJoinSiteCode
                # uses ThisParams.RootCA to subordinate to a different forest's root).
                if ($vm.InstallCA -and $vm.UseOfflineRoot -and (-not $vm.externalDomainJoinSiteCode)) {
                    $vm | Add-Member -MemberType NoteProperty -Name "SubordinateCA" -Value $true -Force
                }
            }
            #add missing Properties
            $isClientOsSiteSystem = Test-SiteSystemClientOperatingSystem -VirtualMachine $vm
            if ($vm.Role -in "SiteSystem", "CAS", "Primary") {
                if (-not $isClientOsSiteSystem -and $null -eq $vm.InstallRP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
                }
                if (-not $isClientOsSiteSystem -and $null -eq $vm.InstallSUP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $false -Force
                }
                # InstallDP / InstallMP are valid on a SiteSystem AND on a Primary: a
                # Primary can host its own DP/MP in ADDITION to dedicated SiteSystem DPs
                # (e.g. so it can serve as a Pull DP's source). Default both to false so
                # the properties exist and are editable / readable everywhere.
                if ($vm.Role -in "SiteSystem", "Primary") {
                    if (-not $isClientOsSiteSystem -and $null -eq $vm.InstallMP) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallMP" -Value $false -Force
                    }
                    if ($null -eq $vm.InstallDP) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallDP" -Value $false -Force
                    }
                }
                if ($vm.Role -eq "SiteSystem" -and -not $isClientOsSiteSystem) {
                    if ($null -eq $vm.InstallSMSProv) {
                        $vm | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
                    }
                    # MP database replica: only meaningful on a dedicated SiteSystem MP.
                    # Default useDatabaseReplica=false so the property exists (editable).
                    # replicaSqlServerVM/replicaDbName are only injected when enabled; the
                    # default replica SQL host is the MP's own VM (local SQL), and the
                    # default database name is CM_<SiteCode>.
                    if ($vm.InstallMP) {
                        if ($null -eq $vm.useDatabaseReplica) {
                            $vm | Add-Member -MemberType NoteProperty -Name "useDatabaseReplica" -Value $false -Force
                        }
                        if ($vm.useDatabaseReplica) {
                            if ([string]::IsNullOrWhiteSpace($vm.replicaSqlServerVM)) {
                                $vm | Add-Member -MemberType NoteProperty -Name "replicaSqlServerVM" -Value $vm.vmName -Force
                            }
                            if ([string]::IsNullOrWhiteSpace($vm.replicaDbName)) {
                                $vm | Add-Member -MemberType NoteProperty -Name "replicaDbName" -Value ("CM_" + [string]$vm.siteCode) -Force
                            }
                        }
                    }
                }
            }

            if ($vm.SqlVersion -and -not $isClientOsSiteSystem) {
                foreach ($listVM in $config.VirtualMachines) {
                    if ($listVM.RemoteSQLVM -eq $vm.VmName) {
                        if ($null -eq $vm.InstallRP) {
                            $vm | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force                            
                        }
                        if ($null -eq $vm.InstallSMSProv) {
                            $vm | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
                        }
                    }
                }
            }

            # BitLocker property: auto-add when BLM is enabled and VM has TPM.
            # Skip non-domain roles — they never receive ConfigMgr BLM policy.
            if ($blmEnabledForDomain -and $vm.tpmEnabled -and $vm.role -notin 'InternetClient', 'WorkgroupMember', 'AADClient') {
                if ($null -eq $vm.BitLocker) {
                    # Default true on client OS, false on server OS
                    $isClientOS = $vm.operatingSystem -and $vm.operatingSystem -like "Windows 1*"
                    $vm | Add-Member -MemberType NoteProperty -Name "BitLocker" -Value ([bool]$isClientOS) -Force
                }
            }
            # Strip BitLocker from non-domain roles in case it was set manually
            if ($vm.role -in 'InternetClient', 'WorkgroupMember', 'AADClient' -and $null -ne $vm.BitLocker) {
                $vm.PsObject.Members.Remove("BitLocker")
            }

            # installOffice property: normalize for DomainMember client-OS VMs.
            # Valid values: $false, "Current", "MonthlyEnterprise", "SemiAnnual".
            # Only allowed on DomainMember VMs with a client OS (Windows 10/11)
            # and pushClient enabled (SCCM client required for deployment).
            $isClientOS = $vm.operatingSystem -and $vm.operatingSystem -like "Windows 1*" -and $vm.operatingSystem -notlike "*Server*"
            if ($vm.role -eq 'DomainMember' -and $isClientOS) {
                if ($null -eq $vm.installOffice) {
                    $vm | Add-Member -MemberType NoteProperty -Name "installOffice" -Value $false -Force
                }
                elseif ($vm.installOffice -notin @($false, 'Current', 'MonthlyEnterprise', 'SemiAnnual')) {
                    # Coerce legacy $true or invalid values to 'Current'
                    if ($vm.installOffice -eq $true) {
                        $vm.installOffice = 'Current'
                    }
                    else {
                        $vm.installOffice = $false
                    }
                }
                # Strip if pushClient is explicitly disabled — SCCM client is required
                if ($vm.installOffice -and $vm.installOffice -ne $false -and $vm.pushClient -eq $false) {
                    $vm.installOffice = $false
                }
            }
            elseif ($null -ne $vm.installOffice) {
                $vm.PsObject.Members.Remove("installOffice")
            }

            # pushClient property: auto-add for DomainMember and site system VMs.
            # Precedence: existing per-VM value > legacy cmOptions.pushClientToDomainMembers
            # (DomainMember-only) > domainDefaults.PushCMClientToClients/Servers/SiteSystems
            # > canonical per-role fallback (Clients ON, Servers OFF, SiteSystems OFF).
            # The stored value is a TARGET SITE CODE string (push from that site)
            # or $false (no push). Legacy boolean $true is migrated to a concrete
            # site code below so the genconfig dropdown, client push, and boundary
            # creation all key off the same explicit site.
            $siteSystemRoles = @('Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
            if (($vm.role -eq 'DomainMember' -or $vm.role -in $siteSystemRoles)) {
                if ($null -eq $vm.pushClient) {
                    # Canonical per-role fallback, matching Get-NewDomainDefaults
                    # (NewDomain.ps1): Clients ON, Servers OFF, SiteSystems OFF.
                    # Site servers install the CM client LOCALLY during CM setup,
                    # so they must NOT be a client-push target by default. The old
                    # hardcoded $true fallback here (used when domainDefaults
                    # predates the PushCMClientToSiteSystems key, e.g. an existing
                    # domain) is what wrongly turned pushClient ON for site servers.
                    if ($vm.role -in $siteSystemRoles) {
                        $key = 'PushCMClientToSiteSystems'
                        $pushDefault = $false
                    }
                    else {
                        $isClientOS = $vm.operatingSystem -and $vm.operatingSystem -like "Windows 1*"
                        if ($isClientOS) { $key = 'PushCMClientToClients'; $pushDefault = $true }
                        else { $key = 'PushCMClientToServers'; $pushDefault = $false }
                    }
                    # Legacy single-value cmOptions.pushClientToDomainMembers is a
                    # DomainMember-only knob; it must never force a site system on.
                    if ($vm.role -eq 'DomainMember' -and $config.cmOptions -and ($null -ne $config.cmOptions.pushClientToDomainMembers)) {
                        $pushDefault = [bool]$config.cmOptions.pushClientToDomainMembers
                    }
                    elseif ($config.domainDefaults -and ($null -ne $config.domainDefaults.$key)) {
                        $pushDefault = [bool]$config.domainDefaults.$key
                    }
                    $vm | Add-Member -MemberType NoteProperty -Name "pushClient" -Value $pushDefault -Force
                }

                # Migrate a boolean/stale pushClient to its resolved TARGET SITE
                # CODE. Only when a CM site exists in the config or existing
                # domain (a CM-less domain pushes nothing; leaving the boolean is
                # harmless since every consumer also gates on cmManagesDomain).
                if (-not (($vm.pushClient -is [bool]) -and ($vm.pushClient -eq $false))) {
                    $domForPush = $null
                    if ($config.vmOptions) { $domForPush = $config.vmOptions.domainName }
                    $eligibleForPush = @(Get-EligiblePushSites -Config $config -Domain $domForPush)
                    if ($eligibleForPush.Count -gt 0) {
                        $resolvedSite = Resolve-PushClientSite -VM $vm -Config $config -Domain $domForPush -EligibleSites $eligibleForPush
                        if ($resolvedSite) {
                            if ($vm.pushClient -ne $resolvedSite) { $vm.pushClient = $resolvedSite }
                        }
                        else {
                            $vm.pushClient = $false
                        }
                    }
                }
            }
        }

        Resolve-ConfigCmVersionAliases -Config $config

        if ($null -ne $config.cmOptions.updateToLatest ) {
            if ($config.cmOptions.updateToLatest -eq $true) {
                $config.cmOptions.version = Get-CMLatestVersion
            }
            $config.cmOptions.PsObject.properties.Remove('updateToLatest')
        }

        if ($null -eq $config.vmOptions.domainNetBiosName ) {
            $netbiosName = $config.vmOptions.domainName.Split(".")[0]
            $config.vmOptions | Add-Member -MemberType NoteProperty -Name "domainNetBiosName" -Value $netbiosName -force
        }

        if ($null -ne $config.cmOptions.installDPMPRoles) {
            $config.cmOptions.PsObject.properties.Remove('installDPMPRoles')
            foreach ($vm in $config.virtualMachines) {
                if ($vm.Role -eq "SiteSystem") {
                    $vm | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                    if (-not (Test-SiteSystemClientOperatingSystem -VirtualMachine $vm)) {
                        $vm | Add-Member -MemberType NoteProperty -Name "installMP" -Value $true -Force
                    }
                }
            }
        }

        # Auto-heal Pull DP sources: a Pull DP's source MUST be an installed DP,
        # otherwise Add-CMDistributionPoint -SourceDistributionPoint fails ("No object
        # corresponds to the specified parameters") and the pull DP never installs. If
        # the source is a site server (Primary/Secondary/SiteSystem) that isn't yet
        # flagged as a DP, enable installDP on it so the pull DP has a real source. A
        # source that still can't be a DP (e.g. a non-site-server role) is left alone
        # and hard-fails config validation.
        foreach ($vm in $config.virtualMachines) {
            if ([string]::IsNullOrWhiteSpace($vm.pullDPSourceDP)) { continue }
            $srcVM = $config.virtualMachines | Where-Object { $_.vmName -eq $vm.pullDPSourceDP } | Select-Object -First 1
            if ($srcVM -and ($srcVM.Role -in "Primary", "Secondary", "SiteSystem") -and (-not $srcVM.installDP)) {
                Write-Log "Get-UserConfiguration: Pull DP [$($vm.vmName)] source [$($srcVM.vmName)] is not a DP; enabling installDP on the source." -LogOnly
                if ($null -eq $srcVM.installDP) {
                    $srcVM | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                }
                else {
                    $srcVM.installDP = $true
                }
            }
        }

        # Every Primary site MUST have a DP and an MP. If none is configured for a
        # Primary's site (no dedicated SiteSystem DP/MP, no pull DP, and the Primary
        # itself hasn't opted in), auto-enable the missing role ON THE PRIMARY so the
        # site is functional. Recording it in the config (rather than relying solely
        # on the deploy-time site-server fallback) makes the intent visible and keeps
        # Phase 11 validation satisfied. Only Primaries present in this config are
        # considered, so add-to-existing (where the Primary is a hidden existing VM)
        # is untouched. CAS sites host no DP/MP and are skipped.
        foreach ($vm in $config.virtualMachines) {
            if ($vm.Role -ne "Primary") { continue }
            $primarySiteCode = $vm.siteCode
            if ([string]::IsNullOrWhiteSpace($primarySiteCode)) { continue }

            $siteHasDP = $config.virtualMachines | Where-Object { $_.siteCode -eq $primarySiteCode -and $_.installDP -eq $true } | Select-Object -First 1
            if (-not $siteHasDP) {
                Write-Log "Get-UserConfiguration: No DP configured for site $primarySiteCode; enabling installDP on Primary $($vm.vmName)." -LogOnly
                if ($null -eq $vm.installDP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                }
                else {
                    $vm.installDP = $true
                }
            }

            $siteHasMP = $config.virtualMachines | Where-Object { $_.siteCode -eq $primarySiteCode -and $_.installMP -eq $true } | Select-Object -First 1
            if (-not $siteHasMP) {
                Write-Log "Get-UserConfiguration: No MP configured for site $primarySiteCode; enabling installMP on Primary $($vm.vmName)." -LogOnly
                if ($null -eq $vm.installMP) {
                    $vm | Add-Member -MemberType NoteProperty -Name "installMP" -Value $true -Force
                }
                else {
                    $vm.installMP = $true
                }
            }
        }

        # Migrate root-level cmOptions onto the top-level site server VM.
        # Runs last so the legacy-shape reads above still see $config.cmOptions.
        Move-CmOptionsToTopLevelSiteServer -Config $config

        $return.Loaded = $true
        $return.Config = $config
        return $return
    }
    catch {
        $return.Message = "Get-UserConfiguration: Failed to load $configPath. $_"
        Write-Log "Get-UserConfiguration Trace: $($_.ScriptStackTrace)" -LogOnly
        return $return
    }
}

function Get-FilesForConfiguration {
    param (
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile", HelpMessage = "Configuration Name for which to download the files.")]
        [string]$Configuration,
        [Parameter(Mandatory = $false, ParameterSetName = "ConfigObject", HelpMessage = "Configuration Object for which to download the files.")]
        [object]$InputObject,
        [Parameter(Mandatory = $false, ParameterSetName = "All", HelpMessage = "Get all files.")]
        [switch]$DownloadAll,
        [Parameter(Mandatory = $false, HelpMessage = "Skip Hash Testing of downloaded files.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the image, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    # Load config file
    if ($Configuration -and -not $DownloadAll) {
        $result = Get-UserConfiguration -Configuration $Configuration
        if ($result.Loaded) {
            $config = $result.Config
            $Global:ConfigFile = $ConfigPath
        }
    }

    # Config object
    if ($InputObject) {
        $config = $InputObject
    }

    # Get unique items from config
    if ($config) {
        $cfgCmOptions = Get-ConfigCmOptions -Config $config
        $operatingSystemsToGet = $config.virtualMachines.operatingSystem | Select-Object -Unique
        $sqlVersionsToGet = $config.virtualMachines.sqlVersion | Select-Object -Unique
        $cmVersionsToGet = $cfgCmOptions.version | Select-Object -Unique
        if ($cfgCmOptions.PrePopulateObjects) {
            $OsVersionsToGet = @("Windows 11 24h2", "Windows 10 22h2")
        }
    }

    Write-Log "Downloading/Verifying Files required by specified config..." -Activity

    $allSuccess = $true

    foreach ($file in $Common.AzureFileList.OS) {

        if ($file.id -eq "vmbuildadmin") { continue }
        # Honor an explicit 'local' flag for images that genuinely aren't in
        # Azure storage. NOTE: the Ubuntu images are NOT local -- they're regular
        # file-list entries (with md5) and are downloaded from storage like any
        # other OS image.
        if ($file.local) { continue }
        if (-not $DownloadAll -and $operatingSystemsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
            $allSuccess = $false
        }
    }

    foreach ($file in $Common.AzureFileList.ISO) {
        if (-not $DownloadAll -and $sqlVersionsToGet -notcontains $file.id) { continue }
        $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
            $allSuccess = $false
        }
    }

    foreach ($file in $Common.AzureFileList.CMVersions) {
        if ($file.filename) {
            if (-not $DownloadAll -and ($cmVersionsToGet -notin $file.versions)) { 
                write-log "CM Version $cmVersionsToGet is not in $($file.versions)" -verbose
                continue 
            }
            $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
            if (-not $worked) {
                Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
                $allSuccess = $false
            }
        }
    }

    #Check if any siteservers are in the config
    $siteServers = $null
    $siteServers = $config.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary") }

    # WSUS categories baseline cab: lives in SupportFiles, but only downloaded
    # when the config actually has a ConfigMgr SUP (installSUP=true) and the
    # import opt-in (cmOptions.WsusImportBaseline, default $true) hasn't been
    # turned off. A PURE standalone WSUS (role=WSUS without installSUP) is NOT
    # a ConfigMgr SUP -- it has no InstallRoles/Phase-8 import path, so it must
    # always populate its catalog via a natural Microsoft Update sync; the cab
    # is intentionally never downloaded/staged for it.
    # Pre-DSC (Common.ScriptBlocks.ps1) reads this from
    # azureFiles\tools\wsus\WsusCategoriesBaseline.cab; the SupportFiles
    # filename matches that relative path so Get-FileWithHash lands it there.
    $wsusVms = $config.virtualMachines | Where-Object { $_.installSUP -eq $true }
    $wsusImportEnabled = $true
    if ($cfgCmOptions -and $cfgCmOptions.PSObject.Properties['WsusImportBaseline'] -and $cfgCmOptions.WsusImportBaseline -eq $false) {
        $wsusImportEnabled = $false
    }
    if ($DownloadAll -or ($wsusImportEnabled -and $wsusVms)) {
        $wsusCab = $Common.AzureFileList.SupportFiles | Where-Object { $_.id -eq "WSUS Categories Baseline" }
        if ($wsusCab) {
            $worked = Get-FileFromStorage -File $wsusCab -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
            if (-not $worked) {
                Write-Log -Verbose "WSUS Categories Baseline cab failed to download via Get-FileFromStorage; WSUSSync will fall back to MU sync."
                # Non-fatal: the cab is an optimization, not a deploy requirement.
            }
        }
    }

    if ($DownloadAll -or ($cfgCmOptions.PrePopulateObjects -and $siteServers) ) {
        $baselineFile = $Common.AzureFileList.SupportFiles | Where-Object { $_.id -eq "Prepopulate Baselines" }
        $worked = Get-FileFromStorage -File $baselineFile -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
        if (-not $worked) {
            Write-Log -Verbose "$baselineFile Failed to download via Get-FileFromStorage"
            $allSuccess = $false
        }

        foreach ($file in $Common.AzureFileList.OSISO) {
            if (-not $DownloadAll -and $OsVersionsToGet -notcontains $file.id) { continue }
            $worked = Get-FileFromStorage -File $file -ForceDownloadFiles:$ForceDownloadFiles -WhatIf:$WhatIf -UseCDN:$UseCDN -IgnoreHashFailure:$IgnoreHashFailure
            if (-not $worked) {
                Write-Log -Verbose "$file Failed to download via Get-FileFromStorage"
                $allSuccess = $false
            }
        }

        #Get a list of all OSISO files, and delete any .ISO files in the OS folder that are not in the list
        $osISOFiles = $Common.AzureFileList.OSISO
        #Get Just the filenames without iso\os in front, eg iso\os\Windows11_24h2.iso becomes Windows11_24h2.iso
        $osISOFileNames = $osISOFiles| ForEach-Object { [System.IO.Path]::GetFileName($_.filename) }
        #Join AzureFilesPath + ISO\OS
        $ISOPath = Join-Path $Common.AzureFilesPath "ISO\OS"
        $osFiles = Get-ChildItem -Path $ISOPath -Filter "*.iso" -Recurse 
        if ($osFiles) {
            $staleOsFiles = @($osFiles | Where-Object { $osISOFileNames -notcontains $_.Name })
            if ($staleOsFiles.Count -gt 0) {
                Write-Log "Deleting old OS ISO files that are not in the filelist.json: $($staleOsFiles | ForEach-Object { $_.FullName })" -LogOnly
            }
            foreach ($file in $osFiles) {
                #Check if the file is not in the list of osISOFileNames
                if ($osISOFileNames -contains $file.Name) {
                    Write-Log "Keeping $($file.FullName) as it is in the filelist.json." -LogOnly
                    #Write-GreenCheck "Keeping $($file.FullName) as it is in the current config."
                    continue
                }
                try {
                    #Log to screen using Write-GreenCheck that the file is being deleted
                    Write-GreenCheck "Deleting old OS ISO file: $($file.FullName)"
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop -ProgressAction SilentlyContinue                   
                    #Remove the .MD5 file if it exists
                    $md5File = "$($file.FullName).md5"  
                    if (Test-Path $md5File) {
                        Write-GreenCheck "Deleting old OS ISO MD5 file: $md5File"
                        Remove-Item -Path $md5File -Force -ErrorAction Stop -ProgressAction SilentlyContinue
                    }
                    
                }
                catch {
                    Write-Log "Failed to delete file $($file.FullName): $_" -Failure
                    $allSuccess = $false
                }
            }
        }

    }
    

    return $allSuccess
}

function New-DeployConfig {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object] $configObject
    )
    try {

        # --- Legacy-lab PKI recovery (must run BEFORE trusting the config's cmOptions) ---
        # A lab first built on the legacy branch never persisted cmOptions to its VM notes.
        # When such a lab is later re-deployed with a regenerated config, that config can
        # carry a cmOptions block whose UsePKI is $false even though the site was actually
        # built as PKI (HTTPS) -- legacy defaulted DC.InstallCA=$true even for eHTTP labs,
        # so PKI cannot be inferred from per-VM flags. The stale $false makes the guest run
        # EnableEHTTP.ps1, the MP web cert is never bound, and the HTTPS MP install fails
        # with MSI 25055 (SMS_MP never created -> Phase 11 functional validation fails).
        # The site server keeps a timestamped backup of every deployConfig it was given;
        # the OLDEST is the original build config and carries the authoritative UsePKI.
        # So: when the existing top-level site server's VM NOTE has no cmOptions at all
        # (the legacy signal), recover cmOptions from that backup, stamp the note (so future
        # runs read it directly), and adopt it here -- overriding the possibly-stale config
        # block and dropping any per-VM clones so Set-VmCmOptionsResolved re-derives them.
        # Host-context only (needs PSDirect). A genuine modern eHTTP lab persists cmOptions
        # to its note, so this is skipped for it.
        if ($Common -and -not $Common.InJob -and $configObject.vmOptions.domainName) {
            try {
                $existingDomainVMs = Get-List -Type VM -DomainName $configObject.vmOptions.domainName
                $topSiteServer = $existingDomainVMs | Where-Object { $_.role -in @('CAS', 'Primary') -and -not $_.parentSiteCode } | Select-Object -First 1
                if ($topSiteServer -and -not $topSiteServer.cmOptions) {
                    $backupCm = Get-CmOptionsFromSiteServerBackup -VmName $topSiteServer.vmName -DomainName $configObject.vmOptions.domainName
                    if ($backupCm) {
                        Write-Log "New-DeployConfig: '$($topSiteServer.vmName)' VM note had no cmOptions (legacy build); recovered cmOptions (UsePKI=$($backupCm.UsePKI)) from its oldest deployConfig backup. Stamping note and adopting for this deploy (prevents eHTTP/MP 25055)." -Verbose
                        try { Set-VMNote -vmName $topSiteServer.vmName -vmNote ([PSCustomObject]@{ cmOptions = $backupCm }) } catch {}
                        # Adopt for THIS deploy, overriding the stale block the regenerated
                        # config carries. Move-CmOptionsToTopLevelSiteServer may already have
                        # copied that stale (UsePKI=$false) block onto the in-config top site
                        # server VM, and Resolve-VmCmOptions walks VM->VM (it does NOT read root),
                        # so we must overwrite it THERE for the corrected value to propagate to
                        # this hierarchy's child site systems. Also mirror onto root for the guest
                        # fallback read ($deployConfig.cmOptions). We deliberately touch ONLY this
                        # recovered top site server (not every site VM) so a second hierarchy in
                        # the same config keeps its own cmOptions.
                        $topInConfig = $configObject.virtualMachines | Where-Object { $_.vmName -eq $topSiteServer.vmName } | Select-Object -First 1
                        if ($topInConfig) {
                            $topClone = $backupCm | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
                            $topInConfig | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $topClone -Force
                        }
                        $configObject | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $backupCm -Force
                    }
                }
            }
            catch {
                Write-Log "New-DeployConfig: legacy PKI cmOptions recovery check failed: $($_.Exception.Message)" -LogOnly
            }
        }

        # Rehydrate root-level cmOptions from the top-level site server VM if needed,
        # so downstream deploy/DSC/validation/phases consumers can keep reading
        # $deployConfig.cmOptions without change. Per-VM is the canonical storage;
        # root is a derived read-only mirror within this DeployConfig snapshot.
        if ($null -eq $configObject.cmOptions) {
            $rootCmOptions = Get-ConfigCmOptions -Config $configObject
            if ($rootCmOptions) {
                $configObject | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $rootCmOptions -Force
            }
        }

        # Stamp every site-role VM with its own resolved cmOptions block so
        # multi-hierarchy deployments (e.g. one CAS + one standalone Primary with
        # differing version/PKI/Offline settings) get correct per-VM values in
        # DSC phases. The root $configObject.cmOptions remains as a single-top
        # mirror for legacy reads; new/updated DSC phases prefer $ThisVM.cmOptions.
        Set-VmCmOptionsResolved -Config $configObject

        if ($null -ne ($configObject.vmOptions.domainName)) { 
            if (($configObject.vmOptions.domainName) -eq "AUTO") {
                $domains = (Get-ValidDomainNames)
                $domainEntry = ($domains.Keys | sort-object { $_.Length } | Select-Object -first 1)
                $domainPrefix = $domains[$domainEntry] 
                $configObject.vmOptions.domainName = $domainEntry
                $configObject.vmOptions.prefix = $domainPrefix
            }
        }
        if ($null -ne ($configObject.vmOptions.network)) { 
            if (($configObject.vmOptions.network) -eq "AUTO") {                
                $configObject.vmOptions.network = (Get-ValidSubnets)[0]                
            }
        }
        # domainAdminName was renamed, this is here for backward compat
        if ($null -ne ($configObject.vmOptions.domainAdminName)) {
            if ($null -eq ($configObject.vmOptions.adminName)) {
                $configObject.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $configObject.vmOptions.domainAdminName -force
            }
            $configObject.vmOptions.PsObject.properties.Remove('domainAdminName')
        }

        # add prefix to vm names
        # The prefix is optional. Normalize blank/missing to "" first: at "" every
        # .StartsWith() below returns true so the prepend no-ops and vmName stays the
        # base name, and downstream $prefix.ToLower()/.Replace() callers stop throwing.
        if ($configObject.vmOptions -and [string]::IsNullOrWhiteSpace($configObject.vmOptions.prefix)) {
            $configObject.vmOptions | Add-Member -MemberType NoteProperty -Name "prefix" -Value "" -Force
        }
        $virtualMachines = $configObject.virtualMachines
        # Snapshot the base names before the loop mutates them; Add-VmNamePrefix needs
        # them to tell an unprefixed reference from one that already carries the prefix.
        $prefix = $configObject.vmOptions.prefix
        $baseVmNames = @($virtualMachines | Where-Object { -not $_.Hidden -and $_.vmName } | ForEach-Object { "$($_.vmName)" })
        foreach ($item in $virtualMachines | Where-Object { -not $_.Hidden -and $_.vmName } ) {
            $item.vmName = $prefix + $item.vmName
            if ($item.pullDPSourceDP) {
                $item.pullDPSourceDP = Add-VmNamePrefix -Name $item.pullDPSourceDP -Prefix $prefix -BaseNames $baseVmNames
            }

            # DHCP relay mappings are authored intent. Keep only the two
            # portable fields and prefix references to VMs created by this
            # config. Existing VM notes already carry the deployed VM name and
            # therefore must not be prefixed a second time.
            if ($item.role -eq 'DHCPRelay' -and $item.relayMappings) {
                $normalizedRelayMappings = @()
                foreach ($mapping in @($item.relayMappings)) {
                    if ($null -eq $mapping) { continue }
                    $targetVm = "$($mapping.distributionPointVM)".Trim()
                    if ($targetVm -and $baseVmNames -contains $targetVm) {
                        $targetVm = Add-VmNamePrefix -Name $targetVm -Prefix $prefix -BaseNames $baseVmNames
                    }
                    $normalizedRelayMappings += [pscustomobject]@{
                        clientNetwork      = "$($mapping.clientNetwork)".Trim()
                        distributionPointVM = $targetVm
                    }
                }
                $item.relayMappings = @($normalizedRelayMappings)
            }

            if ($item.remoteSQLVM) {
                $item.remoteSQLVM = Add-VmNamePrefix -Name $item.remoteSQLVM -Prefix $prefix -BaseNames $baseVmNames
            }

            if ($item.replicaSqlServerVM) {
                $item.replicaSqlServerVM = Add-VmNamePrefix -Name $item.replicaSqlServerVM -Prefix $prefix -BaseNames $baseVmNames
            }

            if ($item.wsusDataBaseServer -and $item.wsusDataBaseServer -ne "WID") {
                $item.wsusDataBaseServer = Add-VmNamePrefix -Name $item.wsusDataBaseServer -Prefix $prefix -BaseNames $baseVmNames
            }

            if ($item.domainUser) {
                $item.domainUser = $prefix + $item.domainUser
            }
        }

        $SQLAOPriVMs = $virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not $_.Hidden }
        foreach ($SQLAO in $SQLAOPriVMs) {
            if ($SQLAO) {
                if ($SQLAO.fileServerVM) {
                    $SQLAO.fileServerVM = Add-VmNamePrefix -Name $SQLAO.fileServerVM -Prefix $prefix -BaseNames $baseVmNames
                }
                if ($SQLAO.OtherNode) {
                    $SQLAO.OtherNode = Add-VmNamePrefix -Name $SQLAO.OtherNode -Prefix $prefix -BaseNames $baseVmNames
                }
                # CNO / VCO are new AD objects, not references to a VM in this config.
                if ($SQLAO.ClusterName) {
                    $SQLAO.ClusterName = Add-VmNamePrefix -Name $SQLAO.ClusterName -Prefix $prefix
                }
                if ($SQLAO.AlwaysOnListenerName) {
                    $SQLAO.AlwaysOnListenerName = Add-VmNamePrefix -Name $SQLAO.AlwaysOnListenerName -Prefix $prefix
                }
            }
        }

        $PassiveVMs = $virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and -not $_.Hidden }
        if ($PassiveVMs) {
            foreach ($PassiveVM in $PassiveVMs) {
                # Add prefix to FS
                if ($PassiveVM.remoteContentLibVM) {
                    $PassiveVM.remoteContentLibVM = Add-VmNamePrefix -Name $PassiveVM.remoteContentLibVM -Prefix $prefix -BaseNames $baseVmNames
                }
            }
        }

        $pmpcVMs = $virtualMachines | Where-Object { $_.InstallPatchMyPC -and -not $_.Hidden } 
        if ($pmpcVMs) {
            foreach ($pmpcVM in $pmpcVMs) {
                if ($pmpcVM.PatchMyPCFileServer) {
                    $pmpcVM.PatchMyPCFileServer = Add-VmNamePrefix -Name $pmpcVM.PatchMyPCFileServer -Prefix $prefix -BaseNames $baseVmNames
                }
            }
        }

        # Add prefix to pkiOptions VM references
        if ($configObject.pkiOptions) {
            $knownVmNames = @($virtualMachines | ForEach-Object { $_.vmName })
            if ($configObject.pkiOptions.IssuingCAVM) {
                $configObject.pkiOptions.IssuingCAVM = Resolve-ConfigVmReference -VmReference $configObject.pkiOptions.IssuingCAVM -VmNames $knownVmNames -Prefix $prefix
                $configObject.pkiOptions.IssuingCAVM = Add-VmNamePrefix -Name $configObject.pkiOptions.IssuingCAVM -Prefix $prefix -BaseNames $baseVmNames
            }
            if ($configObject.pkiOptions.OfflineRootCAVM) {
                $configObject.pkiOptions.OfflineRootCAVM = Resolve-ConfigVmReference -VmReference $configObject.pkiOptions.OfflineRootCAVM -VmNames $knownVmNames -Prefix $prefix
                $configObject.pkiOptions.OfflineRootCAVM = Add-VmNamePrefix -Name $configObject.pkiOptions.OfflineRootCAVM -Prefix $prefix -BaseNames $baseVmNames
            }
        }

        # create params object

        $DCName = ($virtualMachines | Where-Object { $_.role -eq "DC" }).vmName
        $existingDCName = Get-ExistingForDomain -DomainName $configObject.vmOptions.domainName -Role "DC"
        if (-not $DCName) {
            $DCName = $existingDCName
        }

        $params = [PSCustomObject]@{
            DomainName      = $configObject.vmOptions.domainName
            DCName          = $DCName
            ExistingDCName  = $existingDCName
            ThisMachineName = $null
        }

        $sysCenterId = "SysCenterId"
        $sysCenterIdPath = Join-Path (Get-MemlabsDataRoot) "$sysCenterId.txt"
        if (Test-Path $sysCenterIdPath) {
            $id = Get-Content $sysCenterIdPath -ErrorAction SilentlyContinue
            if ($id) {
                $params | Add-Member -MemberType NoteProperty -Name $sysCenterId -Value $id.Trim() -Force
            }
        }

        $productID = "productID"
        $productIdPath = Join-Path (Get-MemlabsDataRoot) "$productID.txt"
        if (Test-Path $productIdPath) {
            $prodid = Get-Content $productIdPath -ErrorAction SilentlyContinue
            if ($prodid) {
                $params | Add-Member -MemberType NoteProperty -Name $productID -Value $prodid.Trim() -Force
            }
        }

        $deploy = [PSCustomObject]@{
            cmOptions       = $configObject.cmOptions
            vmOptions       = $configObject.vmOptions
            pkiOptions      = $configObject.pkiOptions
            virtualMachines = $virtualMachines
            parameters      = $params
        }

        if ($configObject.domainDefaults) {
            $deploy | Add-Member -MemberType NoteProperty -Name "domainDefaults" -Value $configObject.domainDefaults -force
        }
        return $deploy
    }
    catch {
        Write-Exception -ExceptionInfo $_ -AdditionalInfo ($configObject | ConvertTo-Json)
    }
}
#Add-ExistingVMToDeployConfig -vmName $ActiveNodeVM.remoteSQLVM -configToModify $config
function Add-RemoteSQLVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true
    )
    Write-Log -Verbose "Adding Hidden SQL to config $vmName"
    Add-ExistingVMToDeployConfig -vmName $vmName -configToModify $configToModify -hidden:$hidden
    $remoteSQLVM = Get-VMFromList2 -deployConfig $configToModify -vmName $vmName -SmartUpdate:$true -Global:$true
    if (-not $remoteSQLVM) {
        Write-Log "Could not get $vmName from List2.  Please make sure this VM exists in Hyper-V, and if it does not, please modify the hyper-v config to reflect the new name" -Failure
        return
    }
    Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.VmName -configToModify $configToModify -hidden:$hidden
    if ($remoteSQLVM.OtherNode) {
        Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.OtherNode -configToModify $configToModify -hidden:$hidden
    }
    if ($remoteSQLVM.fileServerVM) {
        Add-ExistingVMToDeployConfig -vmName $remoteSQLVM.fileServerVM -configToModify $configToModify -hidden:$hidden
    }
}
function Add-ExistingVMsToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $config
    )

    #Update Cache
    get-list -type vm -SmartUpdate | out-null

    # Add existing DC to list
    if ($config.virtualMachines | Where-Object { $_.role -notin ("OSDClient") }) {
        $existingDC = $config.parameters.ExistingDCName
        if ($existingDC) {
            # create a dummy VM object for the existingDC
            Add-ExistingVMToDeployConfig -vmName $existingDC -configToModify $config
        }
    }

    # Add DCs from other domains, if needed
    $dc = $config.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Add Primary to list when new VMs need BLM collection membership (Phase 8 EnableBLM),
    # ConfigMgr client push (Phase 8 PushClients), or OSD content/PXE reconciliation.
    # Without a hidden Primary, Get-Phase8ConfigurationData returns no nodes and Phase 8
    # is skipped. OSD also needs same-subnet DP objects in deployConfig so perfloading can
    # map each live CM DP back to its VM subnet; mark those support nodes metadata-only so
    # they inform the Primary's run without receiving their own Phase 8 DSC job.
    $newBLMVMs = @($config.virtualMachines | Where-Object { $_.BitLocker -eq $true -and -not $_.hidden })
    $pushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
    $newPushVMs = @($config.virtualMachines | Where-Object {
            $_.role -in $pushableRoles -and -not $_.hidden -and ($_.pushClient -ne $false)
        })
    $newOsdVMs = @($config.virtualMachines | Where-Object { $_.role -eq 'OSDClient' -and -not $_.hidden })
    $phase8PrimaryNames = @()
    if ($newBLMVMs.Count -gt 0 -or $newPushVMs.Count -gt 0) {
        $phase8PrimaryNames += @(Get-ExistingForDomain -DomainName $config.vmOptions.domainName -Role "Primary" | Select-Object -First 1)
    }
    $existingOsdDps = @()
    $existingOsdRelays = @()
    $osdPrimaryNames = @()
    if ($newOsdVMs.Count -gt 0) {
        $osdDefaultNetwork = "$($config.vmOptions.network)"
        $newOsdNetworks = @($newOsdVMs | ForEach-Object {
                if ($_.network) { "$($_.network)" } else { $osdDefaultNetwork }
            } | Where-Object { $_ } | Select-Object -Unique)
        $existingDomainVMsForOsd = @(Get-List -Type VM -DomainName $config.vmOptions.domainName)
        $existingOsdDps = @($existingDomainVMsForOsd | Where-Object {
                if (-not ($_.installDP -or $_.enablePullDP)) { return $false }
                $dpNetwork = if ($_.network) { "$($_.network)" } else { $osdDefaultNetwork }
                return $newOsdNetworks -contains $dpNetwork
            })
            # A stored relay can target a DP on another subnet. Resolve against the
            # complete existing-domain inventory before hidden entries are added,
            # then pull both the relay and target into this deployment.
            $osdPathsBeforeHiddenMerge = @(Get-OsdPxePaths -Config $config -Inventory (@($config.virtualMachines) + @($existingDomainVMsForOsd)))
            $relayPathRows = @($osdPathsBeforeHiddenMerge | Where-Object { $_.mode -eq 'Relay' })
            $relayTargetNames = @($relayPathRows | ForEach-Object { $_.distributionPointVM } | Where-Object { $_ } | Select-Object -Unique)
            $relayVmNames = @($relayPathRows | ForEach-Object { $_.relayVM } | Where-Object { $_ } | Select-Object -Unique)
            $relayVmNames += @($existingDomainVMsForOsd | Where-Object {
                $_.role -eq 'DHCPRelay' -and @($_.relayMappings | Where-Object {
                    "$($_.clientNetwork)" -in $newOsdNetworks
                    }).Count -gt 0
                } | ForEach-Object { $_.vmName })
            $relayVmNames = @($relayVmNames | Where-Object { $_ } | Select-Object -Unique)
            $existingOsdDps += @($existingDomainVMsForOsd | Where-Object { $_.vmName -in $relayTargetNames })
            $existingOsdDps = @($existingOsdDps | Group-Object -Property vmName | ForEach-Object { $_.Group | Select-Object -First 1 })
            $existingOsdRelays = @($existingDomainVMsForOsd | Where-Object { $_.vmName -in $relayVmNames })
        $configuredOsdDps = @($config.virtualMachines | Where-Object {
                if (-not ($_.installDP -or $_.enablePullDP)) { return $false }
                $dpNetwork = Get-OsdEffectiveNetwork -VM $_ -Config $config
                return $newOsdNetworks -contains $dpNetwork
            })
        $allSiteServersForOsd = @($config.virtualMachines) + @($existingDomainVMsForOsd)
        $osdOwnerPrimaryCodes = @()
        foreach ($osdDp in @($configuredOsdDps) + @($existingOsdDps)) {
            $ownerSiteCode = "$($osdDp.siteCode)"
            if (-not $ownerSiteCode) { continue }
            $owningSecondary = $allSiteServersForOsd | Where-Object {
                $_.role -eq 'Secondary' -and $_.siteCode -eq $ownerSiteCode
            } | Select-Object -First 1
            if ($owningSecondary -and $owningSecondary.parentSiteCode) {
                $ownerSiteCode = "$($owningSecondary.parentSiteCode)"
            }
            $osdOwnerPrimaryCodes += $ownerSiteCode
        }
        $osdOwnerPrimaryCodes = @($osdOwnerPrimaryCodes | Where-Object { $_ } | Select-Object -Unique)
        $osdPrimaryNames = @($existingDomainVMsForOsd | Where-Object {
                $_.role -eq 'Primary' -and $_.siteCode -in $osdOwnerPrimaryCodes
            } | ForEach-Object { $_.vmName })
        $phase8PrimaryNames += $osdPrimaryNames
    }

    foreach ($primaryName in @($phase8PrimaryNames | Where-Object { $_ } | Select-Object -Unique)) {
        Add-ExistingVMToDeployConfig -vmName $primaryName -configToModify $config
    }

    if ($newOsdVMs.Count -gt 0) {
        foreach ($existingOsdDp in $existingOsdDps) {
            $dpAlreadyInConfig = $config.virtualMachines.vmName -contains $existingOsdDp.vmName
            Add-ExistingVMToDeployConfig -vmName $existingOsdDp.vmName -configToModify $config
            $metadataDp = $config.virtualMachines | Where-Object {
                -not $dpAlreadyInConfig -and $_.vmName -eq $existingOsdDp.vmName -and $_.hidden -and $_.role -ne 'Primary'
            } | Select-Object -First 1
            if ($metadataDp) {
                $metadataDp | Add-Member -MemberType NoteProperty -Name 'osdMetadataOnly' -Value $true -Force
            }
        }
        foreach ($existingOsdRelay in $existingOsdRelays) {
            Add-ExistingVMToDeployConfig -vmName $existingOsdRelay.vmName -configToModify $config
        }

        # These come in hidden, and Phase 11 skips hidden VMs -- so the run that INTRODUCES
        # OSD validated none of it: not the DP that serves PXE, not the Primary that owns the
        # boot image and the task-sequence deployments. Mark them so Phase 11 alone can opt
        # them back in; they still stay out of Phase 1 and 10, which would rebuild them.
        foreach ($osdVmName in @(@($existingOsdDps | ForEach-Object { $_.vmName }) + @($existingOsdRelays | ForEach-Object { $_.vmName }) + @($osdPrimaryNames) + @($configuredOsdDps | ForEach-Object { $_.vmName }) | Where-Object { $_ } | Select-Object -Unique)) {
            $osdVm = $config.virtualMachines | Where-Object { $_.vmName -eq $osdVmName } | Select-Object -First 1
            if ($osdVm) { $osdVm | Add-Member -MemberType NoteProperty -Name 'osdValidate' -Value $true -Force }
        }
    }

    # The BLM / client-push / OSD blocks above can pull domain-joined VMs into a config that
    # was OSDClient-only when the DC decision was made at the top. Those VMs get their DSC
    # PUSHED BY THE DC, so without it they sit until the local-compile fallback fires.
    if (-not $dc) {
        if ($config.virtualMachines | Where-Object { $_.role -notin ("OSDClient") }) {
            $existingDCName = $config.parameters.ExistingDCName
            if ($existingDCName) {
                Add-ExistingVMToDeployConfig -vmName $existingDCName -configToModify $config
                $dc = $config.virtualMachines | Where-Object { $_.role -eq "DC" }
            }
        }
    }

    if ($dc) {
        if ($null -ne $dc.ForestTrust -and $dc.ForestTrust -ne "NONE") {
            $OtherDC = get-list -Type vm -DomainName $dc.ForestTrust | Where-Object { $_.Role -eq "DC" }
            Add-ExistingVMToDeployConfig -vmName $OtherDC.vmName -configToModify $config -OtherDC:$true

            # Multi-tier PKI: the remote forest's ENTERPRISE issuing CA can live
            # on a member server that is neither the DC (added above) nor the
            # site server (added below). InstallRootCertificate's
            # certutil -ca.chain must be able to REACH that CA host, so start it
            # too. The offline StandaloneRootCA is intentionally excluded -- it
            # stays offline by design and its certificate is retrieved through
            # the issuing CA's chain, not by contacting the root directly.
            $RemoteIssuingCAs = get-list -Type vm -DomainName $dc.ForestTrust | Where-Object { $_.InstallCA -and $_.Role -ne "StandaloneRootCA" }
            foreach ($caVM in $RemoteIssuingCAs) {
                Add-ExistingVMToDeployConfig -vmName $caVM.vmName -configToModify $config
            }

            if ($null -ne $dc.externalDomainJoinSiteCode -and $dc.externalDomainJoinSiteCode -ne "NONE") {
                $RemoteSiteServer = Get-SiteServerForSiteCode -deployConfig $config -SiteCode $dc.externalDomainJoinSiteCode -DomainName $dc.ForestTrust -type VM
                if ($RemoteSiteServer.Role -eq "Secondary") {
                    write-Log "Remote Site server is a Secondary, adding Primary to list" -LogOnly
                    $PrimarySiteServer = Get-SiteServerForSiteCode -deployConfig $config -SiteCode $RemoteSiteServer.ParentSiteCode -DomainName $dc.ForestTrust -type VM
                    write-Log "Adding $($PrimarySiteServer.vmName) to list" -LogOnly
                    Add-ExistingVMToDeployConfig -vmName $PrimarySiteServer.vmName -configToModify $config
                }
                Add-ExistingVMToDeployConfig -vmName $RemoteSiteServer.vmName -configToModify $config
            }

        }
    }

    # Add Primary to list, when adding SiteSystem, also add the current site server to the list.
    $systems = $config.virtualMachines | Where-Object { $_.role -eq "SiteSystem" -or $_.SqlVersion }
    #$systems = $config.virtualMachines | Where-Object { $_.role -eq "SiteSystem" -and -not $_.Hidden }
    foreach ($system in $systems) {
        if ($system.SiteCode) {
            $siteCode = $System.SiteCode
        }
        else {
            $siteCode = Get-SiteCodeForSQLServer -deployConfig $config -SqlServer $system.VmName -SmartUpdate:$false
            if (-not $siteCode) {
                continue
            }
        }
        $systemSite = Get-PrimarySiteServerForSiteCode -deployConfig $config -siteCode $siteCode -type VM -SmartUpdate:$false
        if ($systemSite) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.vmName -configToModify $config
            if ($systemSite.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $systemSite.RemoteSQLVM -configToModify $config
            }            
        }
        $systemSite = Get-SiteServerForSiteCode -deployConfig $config -siteCode $siteCode -type VM -SmartUpdate:$false
        if ($systemSite) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.vmName -configToModify $config
            if ($systemSite.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $systemSite.RemoteSQLVM -configToModify $config
            }
        }
        if ($systemSite.pullDPSourceDP) {
            Add-ExistingVMToDeployConfig -vmName $systemSite.pullDPSourceDP -configToModify $config
        }
        if ($system.RemoteSQLVM) {
            Add-RemoteSQLVMToDeployConfig -vmName $system.RemoteSQLVM -configToModify $config
        }
        # MP database replica hosted on an EXISTING SQL server: pull it in as hidden
        # so Phase 4 reaches it and can add the SQL 'Replication' feature. New (in
        # this config, non-hidden) replica SQL is already present, so skip it.
        if ($system.replicaSqlServerVM) {
            $replicaAlreadyInConfig = $config.virtualMachines | Where-Object { $_.vmName -eq $system.replicaSqlServerVM -and -not $_.hidden }
            if (-not $replicaAlreadyInConfig) {
                Add-RemoteSQLVMToDeployConfig -vmName $system.replicaSqlServerVM -configToModify $config
            }
        }
        if ($system.wsusDataBaseServer) {
            if ($system.wsusDataBaseServer -ne "WID") {
                Add-RemoteSQLVMToDeployConfig -vmName $system.wsusDataBaseServer -configToModify $config
            }
        }
    }

    # Add Primary to list, when adding Secondary
    $Secondaries = $config.virtualMachines | Where-Object { $_.role -eq "Secondary" -and -not $_.Hidden }
    foreach ($Secondary in $Secondaries) {
        $primary = Get-SiteServerForSiteCode -deployConfig $config -sitecode $Secondary.parentSiteCode -type VM -SmartUpdate:$false
        if ($primary) {
            Add-ExistingVMToDeployConfig -vmName $primary.vmName -configToModify $config
            if ($primary.RemoteSQLVM) {
                Add-RemoteSQLVMToDeployConfig -vmName $primary.RemoteSQLVM -configToModify $config
            }
        }
    }

    # Add Primary to list, when adding Passive
    $PassiveVMs = $config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and -not $_.Hidden }
    foreach ($PassiveVM in $PassiveVMs) {
        $ActiveNode = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PassiveVM.siteCode -SmartUpdate:$false
        if ($ActiveNode) {
            $ActiveNodeVM = Get-VMFromList2 -deployConfig $config -vmName $ActiveNode -SmartUpdate:$false
            if ($ActiveNodeVM) {
                if ($ActiveNodeVM.remoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $ActiveNodeVM.remoteSQLVM -configToModify $config
                }
                Add-ExistingVMToDeployConfig -vmName $ActiveNode -configToModify $config
            }
        }
    }

    # Add CAS to list, when adding primary
    $PriVMS = $config.virtualMachines | Where-Object { $_.role -eq "Primary" -and -not $_.Hidden }
    foreach ($PriVM in $PriVMS) {
        if ($PriVM.parentSiteCode) {
            $CAS = Get-SiteServerForSiteCode -deployConfig $config -siteCode $PriVM.parentSiteCode -type VM -SmartUpdate:$false
            if ($CAS) {
                Add-ExistingVMToDeployConfig -vmName $CAS.vmName -configToModify $config
                if ($CAS.RemoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $CAS.RemoteSQLVM -configToModify $config
                }
            }
        }
    }


    # If any machine has a RemoteSQLVM, add it.  This will also add the OtherNode
    $vms = $config.virtualMachines
    foreach ($vm in $vms) {
        if ($vm.RemoteSQLVM) {
            Add-RemoteSQLVMToDeployConfig -vmName $vm.RemoteSQLVM -configToModify $config
        }
        if ($vm.wsusDataBaseServer) {
            if ($vm.wsusDataBaseServer -ne "WID") {
                Add-RemoteSQLVMToDeployConfig -vmName $vm.wsusDataBaseServer -configToModify $config
            }
        }
    }


    # Add FS to list, when adding SQLAO
    $SQLAOVMs = $config.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not $_.Hidden }
    foreach ($SQLAOVM in $SQLAOVMs) {
        if ($SQLAOVM.FileServerVM) {
            Add-ExistingVMToDeployConfig -vmName $SQLAOVM.FileServerVM -configToModify $config
        }
        if ($SQLAOVM.OtherNode) {
            Add-ExistingVMToDeployConfig -vmName $SQLAOVM.OtherNode -configToModify $config
        }
    }

    $wsus = $config.virtualMachines | Where-Object { $_.role -eq "WSUS" -and -not $_.Hidden }
    foreach ($sup in $wsus) {
        if ($sup.InstallSUP) {
            $ss = Get-SiteServerForSiteCode -deployConfig $config -sitecode $sup.siteCode -type VM -SmartUpdate:$false
            if ($ss) {
                Add-ExistingVMToDeployConfig -vmName $ss.vmName -configToModify $config
                if ($ss.RemoteSQLVM) {
                    Add-RemoteSQLVMToDeployConfig -vmName $ss.RemoteSQLVM -configToModify $config
                }
            }
        }
    }
    # Check if any new VM's need remote SQL VM added
    $vms = $config.virtualMachines
    foreach ($vm in $vms) {
        if ($vm.RemoteSQLVM) {
            Add-RemoteSQLVMToDeployConfig -vmName $vm.RemoteSQLVM -configToModify $config
        }
    }

    # Add existing Proxy VM to list when any non-hidden VM opts into useProxy.
    # Phase 5 DSC (ConfigureCMProxy.ps1) needs the Proxy VM in deployConfig
    # to apply Set-CMSiteSystemServer -UseProxy on opted-in site systems.
    $proxyClients = @($config.virtualMachines | Where-Object { $_.useProxy -eq $true -and -not $_.Hidden })
    if ($proxyClients.Count -gt 0) {
        $proxyInConfig = @($config.virtualMachines | Where-Object { $_.role -eq 'Proxy' }).Count -gt 0
        if (-not $proxyInConfig) {
            $existingProxy = Get-ExistingForDomain -DomainName $config.vmOptions.domainName -Role 'Proxy'
            if ($existingProxy) {
                $proxyName = if ($existingProxy -is [array]) { $existingProxy[0] } else { $existingProxy }
                Add-ExistingVMToDeployConfig -vmName $proxyName -configToModify $config
            }
        }
    }

    # Heal a SQLAO node whose partner (OtherNode) no longer exists. If the
    # second AG node was removed (e.g. via the remove script / Remove-Lab),
    # the surviving node's note still carries a dangling OtherNode pointing at
    # a VM that isn't on the host -- the OtherNode add above
    # (Add-ExistingVMToDeployConfig) silently skips it because the VM is gone,
    # so it never lands in virtualMachines. Left in place, every OtherNode-keyed
    # step tries to reach the missing node and fails: the Phase 8 host preflight
    # admin-add (Common.Phases.ps1), the Phase 8 DSC SQL pre-flight $sqlNode2
    # WMI probe (InstallAndUpdateSCCM.ps1), the Phase 11 AG-health validator
    # (Common.Validation.Functional.ps1), and Get-SQLAOConfig's 2-node cluster
    # build. Clear OtherNode here so the node degrades cleanly to a single-node
    # (degraded) Availability Group: the cluster / AG / listener built in Phase 5
    # still physically exist on the surviving node, AlwaysOnListenerName stays
    # set so $installToAO and CM Setup keep using the existing listener, and
    # every OtherNode-gated step naturally no-ops (Get-SQLAOConfig already
    # returns $null without OtherNode by design -- "we don't care about
    # secondary"). This runs in Test-Configuration's Add-Existing pass, before
    # ConvertTo-DeployConfigEx, so the whole deploy (every phase + ScriptWorkflow)
    # sees the healed config.
    foreach ($sqlao in @($config.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode })) {
        $partnerPresent = $config.virtualMachines | Where-Object { $_.vmName -eq $sqlao.OtherNode } | Select-Object -First 1
        if (-not $partnerPresent) {
            Write-Log "$($sqlao.vmName): SQLAO partner node '$($sqlao.OtherNode)' was not found on this host (it appears to have been removed). Clearing OtherNode and treating '$($sqlao.vmName)' as a single-node (degraded) Availability Group -- CM Setup will keep using the existing AG listener '$($sqlao.AlwaysOnListenerName)'." -Warning
            $sqlao.PSObject.Properties.Remove('OtherNode')
        }
    }
}

function Add-ModifiedExistingVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [object] $vm,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true
    )

    $vmName = $vm.vmName

    Write-Log -verbose "Adding Modified $($vmName) to Deploy config"
    $existingConfigVM = $configToModify.virtualMachines | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    if ($existingConfigVM -and -not $existingConfigVM.hidden) {
        Write-Log "Not adding $vmName as it already exists in deployConfig" -LogOnly
        return
    }
    $existingVM = (get-list -Type VM | where-object { $_.vmName -eq $vmName })
    if (-not $existingVM) {
        Write-Log "Not adding $vmName as it does not exist as an existing VM" -LogOnly
        return
    }

    Write-Log -Verbose "Adding $vmName as a modified existing VM"
    if ($existingVM.state -ne "Running") {
        Start-VM2 -Name $existingVM.vmName
    }

    $newVMObject = [PSCustomObject]@{
        hidden = $hidden
    }

    $vmNote = $vm
    $propsToExclude = @(
        "LastKnownIP",
        "inProgress",
        "success",
        "deployedOS",
        "domain",
        "network",
        "prefix",
        "domaindefaults"
        "pkiOptions",
        "memLabsDeployVersion",
        "memLabsVersion",
        "adminName",
        "lastUpdate",
        "source",
        "vmID",
        "switch"
    )
    foreach ($prop in $vmNote.PSObject.Properties) {
        if ($prop.Name -in $propsToExclude) {
            continue
        }

        if ($prop.Name.EndsWith("-Original")) {
            continue
        }
        $newVMObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }

    if (-not $newVMObject.vmName) {
        throw "Could not add hidden VM, because it does not have a vmName property"
    }
    if ($existingConfigVM) {
        $configToModify.virtualMachines = @($configToModify.virtualMachines | Where-Object { $_.vmName -ne $vmName })
    }
    if ($null -eq $configToModify.virtualMachines) {
        $configToModify | Add-Member -MemberType NoteProperty -Name "virtualMachines" -Value @($newVMObject) -Force
    }
    else {
        $configToModify.virtualMachines += $newVMObject
    }
}

function Add-ExistingVMToDeployConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Existing VM Name")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $configToModify,
        [Parameter(Mandatory = $false, HelpMessage = "Should this be added as hidden?")]
        [bool] $hidden = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Is This a DC from another domain?")]
        [bool] $OtherDC = $false
    )

    Write-Log -verbose "Adding $vmName to Deploy config"
    if ($configToModify.virtualMachines.vmName -contains $vmName) {
        Write-Log "Not adding $vmName as it already exists in deployConfig" -LogOnly
        return
    }

    $existingVM = (get-list -Type VM | where-object { $_.vmName -eq $vmName })
    if (-not $existingVM) {
        Write-Log "Not adding $vmName as it does not exist as an existing VM" -LogOnly
        return
    }

    Write-Log -Verbose "Adding $vmName as an existing VM"
    if ($existingVM.state -ne "Running") {
        Start-VM2 -Name $existingVM.vmName
    }

    $newVMObject = [PSCustomObject]@{
        hidden = $hidden
    }

    $vmNote = Get-VMNote -VMName $vmName
    $propsToExclude = @(
        "LastKnownIP",
        "inProgress",
        "success",
        "deployedOS",
        #"domain",
        "network",
        "prefix",
        "memLabsDeployVersion",
        "memLabsVersion",
        "adminName",
        "lastUpdate"
    )
    foreach ($prop in $vmNote.PSObject.Properties) {
        if ($prop.Name -in $propsToExclude) {
            continue
        }
        $newVMObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
    }

    if (-not $newVMObject.vmName) {
        throw "Could not add hidden VM, because it does not have a vmName property"
    }
    if ($OtherDC) {
        $newVMObject.role = "OtherDC"
    }
    if ($null -eq $configToModify.virtualMachines) {
        $configToModify | Add-Member -MemberType NoteProperty -Name "virtualMachines" -Value @($newVMObject) -Force
    }
    else {
        $configToModify.virtualMachines += $newVMObject
    }
}

function Add-VMToAccountLists {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Current Item")]
        [object] $thisVM,
        [Parameter(Mandatory = $true, HelpMessage = "VMToAdd")]
        [object] $VM,
        [Parameter(Mandatory = $true, HelpMessage = "Account Lists")]
        [object] $accountLists,
        [Parameter(Mandatory = $true, HelpMessage = "Deploy Config")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SQLSysAdminAccounts")]
        [switch] $SQLSysAdminAccounts,
        [Parameter(Mandatory = $false, HelpMessage = "LocalAdminAccounts")]
        [switch]$LocalAdminAccounts,
        [Parameter(Mandatory = $false, HelpMessage = "WaitOnDomainJoin")]
        [switch] $WaitOnDomainJoin

    )

    if (($thisVM.vmName).Count -gt 1 -or (($thisVM.vmName).ToCharArray() -contains ' ')) {
        Write-Log "$($thisVM.vmName) contains invalid data"
        return
    }

    foreach ($vmToAdd in $VM) {
        if ($thisVM.vmName -eq $vmToAdd.vmName) {
            continue
        }

        $DName = $deployConfig.vmOptions.domainNetBiosName
        if ($SQLSysAdminAccounts) {
            $accountLists.SQLSysAdminAccounts += "$DNAME\$($vmToAdd.vmName)$"
        }
        if ($LocalAdminAccounts) {
            $accountLists.LocalAdminAccounts += "$($vmToAdd.vmName)$"
        }
        if ($WaitOnDomainJoin) {
            if (-not $vmToAdd.hidden) {
                $accountLists.WaitOnDomainJoin += $vmToAdd.vmName
            }
        }
    }
}

function Get-VMDeployedNetwork {
    <#
    .SYNOPSIS
    Returns the REAL subnet of an already-deployed VM, or $null.

    Add-ExistingVMToDeployConfig deliberately strips 'network' from every hidden
    VM it injects, so anything that reads $vm.network straight off the config
    silently falls back to the NEW deployment's vmOptions.network -- which makes
    every pre-existing site server and client look like it lives on the subnet
    currently being deployed. PS5.1-safe.
    #>
    param (
        [Parameter(Mandatory = $false)] [string] $VmName,
        [Parameter(Mandatory = $false)] [string] $Domain
    )

    if ([string]::IsNullOrWhiteSpace($VmName)) { return $null }
    try {
        if ($Domain) { $list = Get-List -Type VM -DomainName $Domain }
        else { $list = Get-List -Type VM }
        $match = $list | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
        if ($match -and $match.network) { return $match.network }
    }
    catch {
        Write-Log "Get-VMDeployedNetwork: lookup failed for '$VmName': $($_.Exception.Message)" -LogOnly -Warning
    }
    return $null
}

function Get-OsdEffectiveNetwork {
    <#
    .SYNOPSIS
    Returns a VM's effective subnet for OSD DP placement and validation.

    .DESCRIPTION
    New VMs carry network directly. Hidden existing-VM entries deliberately do
    not, so use ConvertTo-DeployConfigEx metadata or the deployed VM as fallback
    before using the deployment default.
    #>
    param (
        [Parameter(Mandatory = $true)] [object] $VM,
        [Parameter(Mandatory = $true)] [object] $Config
    )

    if ($VM.network) { return "$($VM.network)" }
    if ($VM.thisParams -and $VM.thisParams.vmNetwork) { return "$($VM.thisParams.vmNetwork)" }
    if ($VM.hidden -and $VM.vmName) {
        $deployedNetwork = Get-VMDeployedNetwork -VmName $VM.vmName -Domain $Config.vmOptions.domainName
        if ($deployedNetwork) { return "$deployedNetwork" }
    }
    return "$($Config.vmOptions.network)"
}

function Get-OsdPxePaths {
    <#
    .SYNOPSIS
    Resolves the ConfigMgr PXE path for every distinct OSDClient subnet.

    .DESCRIPTION
    This is the shared, read-only topology model used by configuration,
    boundary generation, Phase 8 and validation. A same-subnet Distribution
    Point always wins over one well-formed stored relay mapping. Conflicting
    mappings and incomplete DP metadata fail closed as Invalid rows.

    Inventory is injectable so focused tests can run without Hyper-V. When it
    is omitted, Get-List2 supplies deployed VM notes and the config supplies
    hidden metadata-only entries.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $false)] [AllowNull()] [object[]] $Inventory
    )

    $inventoryWasSupplied = $PSBoundParameters.ContainsKey('Inventory')
    if (-not $inventoryWasSupplied) {
        $Inventory = @(Get-List2 -DeployConfig $Config)
    }

    # Config entries are authoritative for in-flight edits. Add deployed
    # inventory only for names not represented by the config.
    $allVMs = @()
    $seenVmNames = @{}
    foreach ($candidate in @($Config.virtualMachines) + @($Inventory)) {
        if ($null -eq $candidate) { continue }
        $vmName = "$($candidate.vmName)".Trim()
        if (-not $vmName) { continue }
        $key = $vmName.ToLowerInvariant()
        if ($seenVmNames.ContainsKey($key)) {
            # Hidden config entries intentionally omit live-only facts such as
            # LastKnownIP and network. Fill only absent/blank properties from
            # deployed inventory; never overwrite an authored in-flight edit.
            $existingCandidate = $seenVmNames[$key]
            foreach ($property in $candidate.PSObject.Properties) {
                $existingProperty = $existingCandidate.PSObject.Properties[$property.Name]
                if (-not $existingProperty -or $null -eq $existingProperty.Value -or
                    ($existingProperty.Value -is [string] -and [string]::IsNullOrWhiteSpace($existingProperty.Value))) {
                    $existingCandidate | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
                }
            }
            continue
        }
        $mergedCandidate = [pscustomobject]@{}
        foreach ($property in $candidate.PSObject.Properties) {
            $mergedCandidate | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
        }
        $seenVmNames[$key] = $mergedCandidate
        $allVMs += $mergedCandidate
    }

    $osdClients = @($allVMs | Where-Object { $_.role -eq 'OSDClient' })
    if ($osdClients.Count -eq 0) { return @() }

    # An OSDClient in a lab without ConfigMgr remains a bare VM; there is no
    # ConfigMgr PXE topology to resolve or validate.
    $hasCmSite = @($allVMs | Where-Object { $_.role -in @('CAS', 'Primary', 'Secondary') }).Count -gt 0
    if (-not $hasCmSite) { return @() }

    $osdNetworks = @($osdClients | ForEach-Object {
            Get-OsdEffectiveNetwork -VM $_ -Config $Config
        } | Where-Object { $_ } | Select-Object -Unique)
    $distributionPoints = @($allVMs | Where-Object {
            $_.installDP -eq $true -or $_.enablePullDP -eq $true
        })
    $relayVMs = @($allVMs | Where-Object { $_.role -eq 'DHCPRelay' })
    $relayMappingRecords = @()
    foreach ($relayVM in $relayVMs) {
        foreach ($mapping in @($relayVM.relayMappings | Where-Object { $null -ne $_ })) {
            $relayMappingRecords += [pscustomobject]@{ RelayVM = $relayVM; Mapping = $mapping }
        }
    }
    # Defensive transient shape used by import/validation callers: authored
    # configs store mappings on the relay VM, but a detached mapping must be
    # reported as Invalid rather than disappearing into a confident Missing.
    foreach ($mapping in @($Config.relayMappings | Where-Object { $null -ne $_ })) {
        $relayOwner = $null
        if ($mapping.relayVM) {
            $relayOwner = $relayVMs | Where-Object { $_.vmName -eq "$($mapping.relayVM)" } | Select-Object -First 1
        }
        $relayMappingRecords += [pscustomobject]@{ RelayVM = $relayOwner; Mapping = $mapping }
    }

    foreach ($clientNetwork in $osdNetworks) {
        $matchingMappings = @($relayMappingRecords | Where-Object {
                "$($_.Mapping.clientNetwork)" -eq "$clientNetwork"
            })

        $directDps = @($distributionPoints | Where-Object {
                (Get-OsdEffectiveNetwork -VM $_ -Config $Config) -eq $clientNetwork
            })
        $directWithoutSite = @($directDps | Where-Object { [string]::IsNullOrWhiteSpace("$($_.siteCode)") })
        $directSiteCodes = @($directDps | ForEach-Object { "$($_.siteCode)" } | Where-Object { $_ } | Select-Object -Unique)

        $invalidReason = $null
        if ($matchingMappings.Count -gt 1) {
            $owners = @($matchingMappings | ForEach-Object {
                    if ($_.RelayVM) { "$($_.RelayVM.vmName)" } else { '<missing>' }
                } | Select-Object -Unique)
            $invalidReason = "conflicting relay mappings on $($owners -join ', ')"
        }
        elseif ($matchingMappings.Count -eq 1 -and -not $matchingMappings[0].RelayVM) {
            $missingRelayName = "$($matchingMappings[0].Mapping.relayVM)"
            if (-not $missingRelayName) { $missingRelayName = '<unspecified>' }
            $invalidReason = "relay VM '$missingRelayName' is missing"
        }
        elseif ($directWithoutSite.Count -gt 0) {
            $invalidReason = "same-subnet DP(s) lack site ownership: $(@($directWithoutSite.vmName) -join ', ')"
        }
        elseif ($directSiteCodes.Count -gt 1) {
            $invalidReason = "same-subnet DPs belong to conflicting sites: $($directSiteCodes -join ', ')"
        }

        if ($invalidReason) {
            [pscustomobject]@{
                clientNetwork                 = "$clientNetwork"
                mode                          = 'Invalid'
                relayVM                       = $null
                relayIPv4                     = $null
                distributionPointVM           = $null
                distributionPointNetwork      = $null
                distributionPointSiteCode     = $null
                distributionPointIPv4         = $null
                reason                        = $invalidReason
            }
            continue
        }

        # One stale mapping is harmless when a usable local DP exists. Emit
        # every local DP so all eligible direct targets retain current behavior.
        if ($directDps.Count -gt 0) {
            foreach ($directDp in $directDps) {
                $directDpIp = $null
                if ($directDp.AssignedIP) { $directDpIp = "$($directDp.AssignedIP)" }
                [pscustomobject]@{
                    clientNetwork                 = "$clientNetwork"
                    mode                          = 'Direct'
                    relayVM                       = $null
                    relayIPv4                     = $null
                    distributionPointVM           = "$($directDp.vmName)"
                    distributionPointNetwork      = "$(Get-OsdEffectiveNetwork -VM $directDp -Config $Config)"
                    distributionPointSiteCode     = "$($directDp.siteCode)"
                    distributionPointIPv4         = $directDpIp
                    reason                        = $null
                }
            }
            continue
        }

        if ($matchingMappings.Count -eq 0) {
            [pscustomobject]@{
                clientNetwork                 = "$clientNetwork"
                mode                          = 'Missing'
                relayVM                       = $null
                relayIPv4                     = $null
                distributionPointVM           = $null
                distributionPointNetwork      = $null
                distributionPointSiteCode     = $null
                distributionPointIPv4         = $null
                reason                        = 'no same-subnet DP or relay mapping'
            }
            continue
        }

        $relayVM = $matchingMappings[0].RelayVM
        $mapping = $matchingMappings[0].Mapping
        $targetName = "$($mapping.distributionPointVM)".Trim()
        $targetDp = $allVMs | Where-Object { $_.vmName -eq $targetName } | Select-Object -First 1
        $targetNetwork = $null
        if ($targetDp) { $targetNetwork = Get-OsdEffectiveNetwork -VM $targetDp -Config $Config }
        $targetIpValues = @()
        if ($targetDp) {
            $targetIpValues += @($targetDp.AssignedIP, $targetDp.LastKnownIP)
            if ($targetDp.thisParams) {
                $targetIpValues += @($targetDp.thisParams.AssignedIP, $targetDp.thisParams.IPv4Address)
            }
            if (-not $inventoryWasSupplied -and $targetNetwork) {
                try {
                    $targetHostVm = Get-VM2 -Name $targetDp.vmName -ErrorAction Stop
                    $targetAdapter = @($targetHostVm | Get-VMNetworkAdapter -ErrorAction Stop |
                        Where-Object { $_.SwitchName -eq $targetNetwork }) | Select-Object -First 1
                    if ($targetAdapter) {
                        $targetIpValues += @($targetAdapter.IPAddresses)
                        $targetMac = ("$($targetAdapter.MacAddress)" -replace '[-:]', '').ToUpperInvariant()
                        if ($targetMac) {
                            $targetReservation = Get-DhcpServerv4Reservation -ScopeId $targetNetwork -ErrorAction Stop |
                                Where-Object { ("$($_.ClientId)" -replace '[-:]', '').ToUpperInvariant() -eq $targetMac } |
                                Select-Object -First 1
                            if ($targetReservation) { $targetIpValues += "$($targetReservation.IPAddress.IPAddressToString)" }
                        }
                    }
                }
                catch {
                    # Existing metadata may still be complete. The caller fails
                    # closed below when no source yields a stable IPv4 value.
                }
            }
        }
        $targetIpValues = @($targetIpValues | ForEach-Object {
                $candidateIp = "$_" -replace '/\d+$', ''
                $parsedCandidateIp = $null
                if ($_ -and [System.Net.IPAddress]::TryParse($candidateIp, [ref]$parsedCandidateIp) -and
                    $parsedCandidateIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $parsedCandidateIp.IPAddressToString
                }
            } | Select-Object -Unique)
        $targetKnownIp = $null
        if ($targetIpValues.Count -eq 1) { $targetKnownIp = "$($targetIpValues[0])" }
        $relayIp = $null
        if ("$clientNetwork" -match '^(\d{1,3}\.){3}0$') {
            $relayIp = "$clientNetwork" -replace '\.0$', '.4'
        }

        $relayIsLinux = $relayVM.osFamily -eq 'Linux' -or "$($relayVM.operatingSystem)" -like 'Ubuntu*'
        if (-not $relayIsLinux) { $invalidReason = "relay VM '$($relayVM.vmName)' is not Linux" }
        elseif (-not $targetName) { $invalidReason = "relay VM '$($relayVM.vmName)' has a mapping with no target DP" }
        elseif (-not $targetDp) { $invalidReason = "target DP '$targetName' is missing" }
        elseif (-not ($targetDp.installDP -eq $true -or $targetDp.enablePullDP -eq $true)) { $invalidReason = "target '$targetName' is not a Distribution Point" }
        elseif ([string]::IsNullOrWhiteSpace("$($targetDp.siteCode)")) { $invalidReason = "target DP '$targetName' lacks site ownership" }
        elseif ($targetIpValues.Count -gt 1) { $invalidReason = "target DP '$targetName' has conflicting IPv4 metadata: $($targetIpValues -join ', ')" }
        elseif ($targetIpValues.Count -eq 0) { $invalidReason = "target DP '$targetName' has no stable IPv4 metadata" }
        elseif ($targetNetwork -eq $clientNetwork) { $invalidReason = "target DP '$targetName' is on the client subnet and must be used directly" }
        elseif (-not $relayIp) { $invalidReason = "client network '$clientNetwork' is not a supported /24 network ID" }

        if ($invalidReason) {
            $invalidTargetNetwork = $null
            $invalidTargetSiteCode = $null
            $invalidTargetIp = $null
            if ($targetNetwork) { $invalidTargetNetwork = "$targetNetwork" }
            if ($targetDp) {
                $invalidTargetSiteCode = "$($targetDp.siteCode)"
                if ($targetKnownIp) { $invalidTargetIp = $targetKnownIp }
            }
            [pscustomobject]@{
                clientNetwork                 = "$clientNetwork"
                mode                          = 'Invalid'
                relayVM                       = "$($relayVM.vmName)"
                relayIPv4                     = $relayIp
                distributionPointVM           = $targetName
                distributionPointNetwork      = $invalidTargetNetwork
                distributionPointSiteCode     = $invalidTargetSiteCode
                distributionPointIPv4         = $invalidTargetIp
                reason                        = $invalidReason
            }
            continue
        }

        $relayTargetIp = $null
        if ($targetKnownIp) { $relayTargetIp = $targetKnownIp }
        [pscustomobject]@{
            clientNetwork                 = "$clientNetwork"
            mode                          = 'Relay'
            relayVM                       = "$($relayVM.vmName)"
            relayIPv4                     = "$relayIp"
            distributionPointVM           = "$($targetDp.vmName)"
            distributionPointNetwork      = "$targetNetwork"
            distributionPointSiteCode     = "$($targetDp.siteCode)"
            distributionPointIPv4         = $relayTargetIp
            reason                        = $null
        }
    }
}

function Get-OsdBoundaryMappings {
    <#
    .SYNOPSIS
    Returns the boundary mapping required by each OSDClient subnet.

    .DESCRIPTION
    OSD clients do not receive client push, and a DP-only SiteSystem normally
    does not either. Derive each subnet's owning site from the shared PXE path
    model. Missing and invalid paths never fabricate a boundary owner.
    #>
    param (
        [Parameter(Mandatory = $true)] [object] $Config
    )

    $mappedSubnets = @{}
    foreach ($path in @(Get-OsdPxePaths -Config $Config)) {
        if ($path.mode -notin @('Direct', 'Relay')) { continue }
        $subnet = "$($path.clientNetwork)"
        if (-not $subnet -or $mappedSubnets.ContainsKey($subnet)) { continue }
        if ([string]::IsNullOrWhiteSpace("$($path.distributionPointSiteCode)")) { continue }

        $mappedSubnets[$subnet] = $true
        [pscustomobject]@{
            SiteCode = "$($path.distributionPointSiteCode)"
            Subnet   = "$subnet"
        }
    }
}

function Get-EligiblePushSites {
    <#
    .SYNOPSIS
    Returns the site servers a client can be pushed to (the sites that own a
    boundary group): every Primary and Secondary in the config AND in the
    existing domain. Each entry: [PSCustomObject]@{ SiteCode; Network; Role }.
    De-duplicated by SiteCode (config entry wins so an in-flight subnet change
    is reflected). Used by Resolve-PushClientSite, the genconfig dropdown, and
    validation. PS5.1-safe (no ternary / null-conditional).
    #>
    param (
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain
    )

    $sites = @()
    $seen = @{}

    $lookupDomain = $Domain
    if (-not $lookupDomain -and $Config -and $Config.vmOptions) { $lookupDomain = $Config.vmOptions.domainName }

    # Config sites first (authoritative for an in-progress edit / fresh deploy).
    if ($Config -and $Config.virtualMachines) {
        $defaultNet = $null
        if ($Config.vmOptions) { $defaultNet = $Config.vmOptions.network }
        foreach ($vm in ($Config.virtualMachines | Where-Object { $_.role -in 'Primary', 'Secondary' })) {
            if (-not $vm.siteCode) { continue }
            $key = $vm.siteCode.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $net = $vm.network
            # An existing site server carries no 'network' in the config; using
            # $defaultNet here would put it on the subnet being deployed now and
            # make it tie with (and lose to) the new Primary on every subnet match.
            if (-not $net) { $net = Get-VMDeployedNetwork -VmName $vm.vmName -Domain $lookupDomain }
            if (-not $net) { $net = $defaultNet }
            $sites += [PSCustomObject]@{ SiteCode = $vm.siteCode; Network = $net; Role = $vm.role }
            $seen[$key] = $true
        }
    }

    # Existing domain sites (for add-to-existing where the Primary is hidden).
    if ($Domain) {
        try {
            foreach ($e in @(Get-ExistingSiteServer -DomainName $Domain | Where-Object { $_.Role -in 'Primary', 'Secondary' })) {
                if (-not $e.SiteCode) { continue }
                $key = $e.SiteCode.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $sites += [PSCustomObject]@{ SiteCode = $e.SiteCode; Network = $e.Network; Role = $e.Role }
                $seen[$key] = $true
            }
        }
        catch {
            Write-Log "Get-EligiblePushSites: failed to enumerate existing site servers for '$Domain': $($_.Exception.Message)" -LogOnly -Warning
        }
    }

    return $sites
}

function Resolve-PushClientSite {
    <#
    .SYNOPSIS
    Resolves a VM's effective client-push TARGET site code.
    pushClient is a site code string (push from that site) or $false (no push).
    Returns the site code string, or $false when the VM should not get a client.

    Resolution:
      - pushClient -eq $false           -> $false (explicit opt-out).
      - pushClient is a valid site code -> that site code (kept as-is).
      - pushClient -eq $true / invalid  -> auto-resolve: the site whose own
        subnet matches this VM's subnet, else the FIRST Primary, else the first
        eligible site. $false when no CM site exists at all.
    This makes every legacy pushClient=$true VM on a given subnet resolve to the
    same site, so the subnet->site mapping (and its boundary) is consistent.
    PS5.1-safe (no ternary / null-conditional).
    #>
    param (
        [Parameter(Mandatory = $true)] [object] $VM,
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain,
        [Parameter(Mandatory = $false)] [object] $EligibleSites
    )

    if ($null -eq $VM) { return $false }

    # Explicit opt-out (boolean $false).
    if (($VM.pushClient -is [bool]) -and ($VM.pushClient -eq $false)) { return $false }

    $eligible = @($EligibleSites)
    if (-not $eligible -or $eligible.Count -eq 0) {
        $eligible = @(Get-EligiblePushSites -Config $Config -Domain $Domain)
    }
    if (-not $eligible -or $eligible.Count -eq 0) { return $false }

    $codes = @($eligible | ForEach-Object { $_.SiteCode })

    # Already a valid site code string -> keep it.
    if (($VM.pushClient -is [string]) -and $VM.pushClient -and ($codes -contains $VM.pushClient)) {
        return $VM.pushClient
    }

    # Needs resolution ($true, an invalid/stale code, or defaulting).
    $subnet = $null
    if ($VM.network) { $subnet = $VM.network }
    else {
        $lookupDomain = $Domain
        if (-not $lookupDomain -and $Config -and $Config.vmOptions) { $lookupDomain = $Config.vmOptions.domainName }
        $subnet = Get-VMDeployedNetwork -VmName $VM.vmName -Domain $lookupDomain
    }
    if (-not $subnet -and $Config -and $Config.vmOptions) { $subnet = $Config.vmOptions.network }

    if ($subnet) {
        $match = $eligible | Where-Object { $_.Network -eq $subnet } | Select-Object -First 1
        if ($match) { return $match.SiteCode }
    }

    $firstPri = $eligible | Where-Object { $_.Role -eq 'Primary' } | Select-Object -First 1
    if ($firstPri) { return $firstPri.SiteCode }

    return (@($eligible)[0]).SiteCode
}

function Get-PushClientSubnetLock {
    <#
    .SYNOPSIS
    Returns the site code that OWNS a subnet because a Primary/Secondary site
    server lives on it (in the config or already deployed), else $null. A site
    server's own subnet maps to its boundary group unconditionally, so any
    client there must push from that site. PS5.1-safe.
    #>
    param (
        [Parameter(Mandatory = $false)] [string] $Subnet,
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain,
        [Parameter(Mandatory = $false)] [string] $ExcludeVmName,
        [Parameter(Mandatory = $false)] [string] $DefaultNet
    )
    if (-not $Subnet) { return $null }
    $lookupDomain = $Domain
    if (-not $lookupDomain -and $Config -and $Config.vmOptions) { $lookupDomain = $Config.vmOptions.domainName }
    if ($Config -and $Config.virtualMachines) {
        foreach ($o in $Config.virtualMachines) {
            if ($ExcludeVmName -and $o.vmName -eq $ExcludeVmName) { continue }
            if ($o.role -notin @('Primary', 'Secondary')) { continue }
            if (-not $o.siteCode) { continue }
            $on = $o.network
            # Existing site servers carry no 'network' in the config; $DefaultNet
            # would falsely place them on the subnet being deployed now.
            if (-not $on) { $on = Get-VMDeployedNetwork -VmName $o.vmName -Domain $lookupDomain }
            if (-not $on) { $on = $DefaultNet }
            if ($on -eq $Subnet) { return $o.siteCode }
        }
    }
    if ($Domain) {
        try {
            $svr = @(Get-List -Type VM -DomainName $Domain | Where-Object {
                    $_.network -eq $Subnet -and $_.role -in @('Primary', 'Secondary') -and $_.siteCode -and
                    (-not ($ExcludeVmName -and $_.vmName -eq $ExcludeVmName))
                }) | Select-Object -First 1
            if ($svr) { return $svr.siteCode }
        }
        catch {
            Write-Log "Get-PushClientSubnetLock: deployed-site lookup failed for '$Subnet': $($_.Exception.Message)" -LogOnly -Warning
        }
    }
    return $null
}

function Resolve-PushClientWithLock {
    <#
    .SYNOPSIS
    Resolves a VM's pushClient honoring: explicit opt-out ($false) stays off; a
    Primary/Secondary site server on the subnet LOCKS the value to its site
    code; otherwise the VM's CURRENT value is kept when it is still a valid
    eligible site ("prefer the current value if it still makes sense"); else
    falls back to Resolve-PushClientSite. PS5.1-safe.
    #>
    param (
        [Parameter(Mandatory = $true)] [object] $VM,
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain,
        [Parameter(Mandatory = $false)] [object] $EligibleSites,
        [Parameter(Mandatory = $false)] [string] $DefaultNet
    )
    if (($VM.pushClient -is [bool]) -and ($VM.pushClient -eq $false)) { return $false }
    $eligible = @($EligibleSites)
    if (-not $eligible -or $eligible.Count -eq 0) { return $VM.pushClient }
    $codes = @($eligible | ForEach-Object { $_.SiteCode })
    $subnet = $DefaultNet
    if ($VM.network) { $subnet = $VM.network }
    $lock = Get-PushClientSubnetLock -Subnet $subnet -Config $Config -Domain $Domain -ExcludeVmName $VM.vmName -DefaultNet $DefaultNet
    if ($lock) { return $lock }
    if (($VM.pushClient -is [string]) -and $VM.pushClient -and ($codes -contains $VM.pushClient)) { return $VM.pushClient }
    return (Resolve-PushClientSite -VM $VM -Config $Config -Domain $Domain -EligibleSites $eligible)
}

function Update-PushClientTargets {
    # Re-resolve pushClient for each VM in $Targets via Resolve-PushClientWithLock
    # and write back only when the value changes. The changed VM itself is updated
    # silently; affected peers get a one-line note. PS5.1-safe.
    param (
        [Parameter(Mandatory = $false)] [object] $Targets,
        [Parameter(Mandatory = $false)] [object] $ChangedVM,
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain,
        [Parameter(Mandatory = $false)] [object] $Eligible,
        [Parameter(Mandatory = $false)] [string] $DefaultNet
    )
    foreach ($vm in @($Targets)) {
        if (-not $vm) { continue }
        if (-not ($vm.PSObject.Properties.Name -contains 'pushClient')) { continue }
        if (($vm.pushClient -is [bool]) -and ($vm.pushClient -eq $false)) { continue }
        $new = Resolve-PushClientWithLock -VM $vm -Config $Config -Domain $Domain -EligibleSites $Eligible -DefaultNet $DefaultNet
        if ($null -ne $new -and $vm.pushClient -ne $new) {
            $vm.pushClient = $new
            if (-not $ChangedVM -or ($vm -ne $ChangedVM)) {
                $sn = $DefaultNet
                if ($vm.network) { $sn = $vm.network }
                Write-Host2 -ForegroundColor Khaki "  Recalculated $($vm.vmName) push site -> $new (subnet $sn)."
            }
        }
    }
}

function Update-PushClientForNetworkChange {
    <#
    .SYNOPSIS
    Recalculate pushClient after a single VM's network changed in genconfig.
    The moved VM is always re-resolved (its current value is kept when it still
    makes sense for the new subnet). When the moved VM is a Primary/Secondary
    SITE SERVER, every VM whose effective subnet is the site server's OLD or NEW
    network (an explicit per-VM network OR the default vmOptions.network) is
    re-resolved too, because moving a site server changes which site owns those
    subnets' boundary groups. PS5.1-safe.
    #>
    param (
        [Parameter(Mandatory = $true)] [object] $ChangedVM,
        [Parameter(Mandatory = $false)] [string] $OldNetwork,
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain
    )
    if (-not $Config -or -not $Config.virtualMachines) { return }
    if (-not $ChangedVM) { return }
    if (-not $Domain -and $Config.vmOptions) { $Domain = $Config.vmOptions.domainName }
    $eligible = @(Get-EligiblePushSites -Config $Config -Domain $Domain)
    if (-not $eligible -or $eligible.Count -eq 0) { return }
    $defaultNet = $null
    if ($Config.vmOptions) { $defaultNet = $Config.vmOptions.network }
    $pushRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')

    $targets = @($ChangedVM)
    if ($ChangedVM.role -in @('Primary', 'Secondary')) {
        $newNet = $defaultNet
        if ($ChangedVM.network) { $newNet = $ChangedVM.network }
        $affected = @($OldNetwork, $newNet) | Where-Object { $_ } | Select-Object -Unique
        foreach ($vm in $Config.virtualMachines) {
            if ($vm -eq $ChangedVM) { continue }
            if ($vm.role -notin $pushRoles) { continue }
            $vn = $defaultNet
            if ($vm.network) { $vn = $vm.network }
            if ($vn -and ($affected -contains $vn)) { $targets += $vm }
        }
    }
    Update-PushClientTargets -Targets $targets -ChangedVM $ChangedVM -Config $Config -Domain $Domain -Eligible $eligible -DefaultNet $defaultNet
}

function Update-PushClientForDefaultNetworkChange {
    <#
    .SYNOPSIS
    Recalculate pushClient after the DEFAULT network (vmOptions.network) changed.
    Every VM that rides the default (no explicit per-VM network) just moved
    subnet, so re-resolve every push-capable VM whose effective subnet is the
    OLD or NEW default. PS5.1-safe.
    #>
    param (
        [Parameter(Mandatory = $false)] [string] $OldDefault,
        [Parameter(Mandatory = $true)] [object] $Config,
        [Parameter(Mandatory = $false)] [string] $Domain
    )
    if (-not $Config -or -not $Config.virtualMachines) { return }
    if (-not $Domain -and $Config.vmOptions) { $Domain = $Config.vmOptions.domainName }
    $eligible = @(Get-EligiblePushSites -Config $Config -Domain $Domain)
    if (-not $eligible -or $eligible.Count -eq 0) { return }
    $newDefault = $null
    if ($Config.vmOptions) { $newDefault = $Config.vmOptions.network }
    $affected = @($OldDefault, $newDefault) | Where-Object { $_ } | Select-Object -Unique
    $pushRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
    $targets = @()
    foreach ($vm in $Config.virtualMachines) {
        if ($vm.role -notin $pushRoles) { continue }
        $vn = $newDefault
        if ($vm.network) { $vn = $vm.network }
        if ($vn -and ($affected -contains $vn)) { $targets += $vm }
    }
    Update-PushClientTargets -Targets $targets -ChangedVM $null -Config $Config -Domain $Domain -Eligible $eligible -DefaultNet $newDefault
}


function Get-SQLAOConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Config to Modify")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SQLAONAME")]
        [object] $vmName
    )
    Write-Log "Running Get-SQLAOConfig for $vmName" -LogOnly
    $PrimaryAO = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vmName }

    if (-not $PrimaryAO) {
        Write-Log -Failure "Could not find Primary SQLAO VM $vmName"
        return $null
    }
    if (-not ($PrimaryAO.OtherNode)) {
        #ignore this.. We run this on all SQLAO nodes,and don't care about secondary
        return $null
    }

    $SecondAO = $PrimaryAO.OtherNode
    $FSAO = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "FileServer" -and $_.vmName -eq $PrimaryAO.FileServerVM }
    #$DC = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "DC" }

    $ClusterName = $PrimaryAO.ClusterName
    $ClusterNameNoPrefix = Remove-VmNamePrefix -Name $ClusterName -Prefix $deployConfig.vmOptions.prefix

    $ServiceAccount = $PrimaryAO.SqlServiceAccount
    $AgentAccount = $PrimaryAO.SqlAgentAccount

    $Domain = $deployConfig.vmOptions.domainName
    $DN = 'DC=' + $Domain.Replace('.', ',DC=')    
    $cnUsersName = "CN=Users,$DN"
    $cnComputersName = "CN=Computers,$DN"
    #$netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $netbiosName = $deployConfig.vmOptions.domainNetBiosName
    if (-not ($PrimaryAO.ClusterIPAddress)) {
        $vm = Get-List -SmartUpdate -Type VM | where-object { $_.vmName -eq $PrimaryAO.vmName }
        if ($vm.ClusterIPAddress) {
            write-log "Setting Cluster IP from vmNotes" -verbose
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "ClusterIPAddress" -Value $vm.ClusterIPAddress -Force
            $PrimaryAO | Add-Member -MemberType NoteProperty -Name "AGIPAddress" -Value $vm.AGIPAddress -Force
        }
        else {
            write-log "Cluster IP not found in VMNotes" -verbose

        }
    }
    if (-not ($PrimaryAO.ClusterIPAddress)) {
        write-log "Cluster IP is not yet set. Skipping SQLAO Config for $vmName" -LogOnly
        return
        #throw "Primary SQLAO $($PrimaryAO.vmName) does not have a ClusterIP assigned."
    }

    # Warn if ClusterIP or AGIP are on the legacy heartbeat subnet.
    # These labs need a full re-deploy to get domain-subnet IPs.
    # Use the node's OWN network (it may sit on a secondary network), not the
    # domain default vmOptions.network, so the warning names the right subnet.
    $domainNetwork = if ($PrimaryAO.network) { $PrimaryAO.network } else { $deployConfig.vmOptions.network }
    $domainPrefix = ($domainNetwork -replace '\.\d+$', '.')
    if ($PrimaryAO.ClusterIPAddress -match '^10\.250\.250\.') {
        write-log "$vmName`: WARNING: ClusterIPAddress $($PrimaryAO.ClusterIPAddress) is on the heartbeat subnet, not the domain subnet ($domainPrefix*). Cluster steps will be skipped." -Warning
    }
    if ($PrimaryAO.AGIPAddress -match '^10\.250\.250\.') {
        write-log "$vmName`: WARNING: AGIPAddress $($PrimaryAO.AGIPAddress) is on the heartbeat subnet, not the domain subnet ($domainPrefix*). AG listener may not be reachable." -Warning
    }

    $config = [PSCustomObject]@{
        GroupName                  = $ClusterName + "Group"
        GroupMembers               = @("$($PrimaryAO.vmName)$", "$($SecondAO)$", "$($ClusterName)$")
        GroupMembersFQ             = @("$($netbiosName + "\" + $PrimaryAO.vmName)$", "$($netbiosName + "\" + $SecondAO)$", "$($netbiosName + "\" + $ClusterName)$")
        SqlServiceAccount          = $ServiceAccount
        SqlServiceAccountFQ        = $netbiosName + "\" + $ServiceAccount
        SqlAgentServiceAccount     = $AgentAccount
        SqlAgentServiceAccountFQ   = $netbiosName + "\" + $AgentAccount
        OULocationUser             = $cnUsersName
        OULocationDevice           = $cnComputersName
        ClusterNodes               = @($PrimaryAO.vmName, $SecondAO)
        WitnessLocalPath           = "F:\$($ClusterNameNoPrefix)-Witness"
        BackupLocalPath            = "F:\$($ClusterNameNoPrefix)-Backup"
        AlwaysOnGroupName          = $PrimaryAO.AlwaysOnGroupName
        PrimaryNodeName            = $PrimaryAO.vmName
        SecondaryNodeName          = $SecondAO
        FileServerName             = $FSAO.vmName
        ClusterIPAddress           = $PrimaryAO.ClusterIPAddress + "/24"
        AGIPAddress                = $PrimaryAO.AGIPAddress + "/255.255.255.0"
        PrimaryReplicaServerName   = $PrimaryAO.vmName + "." + $deployConfig.vmOptions.DomainName
        SecondaryReplicaServerName = $PrimaryAO.OtherNode + "." + $deployConfig.vmOptions.DomainName
        AlwaysOnListenerName       = $PrimaryAO.AlwaysOnListenerName
        AlwaysOnListenerNameFQDN   = $PrimaryAO.AlwaysOnListenerName + "." + $deployConfig.vmOptions.DomainName
        WitnessShareFQ             = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Witness"
        BackupShareFQ              = "\\" + $PrimaryAO.fileServerVM + "\" + "$($ClusterNameNoPrefix)-Backup"
        WitnessShare               = "$($ClusterNameNoPrefix)-Witness"
        BackupShare                = "$($ClusterNameNoPrefix)-Backup"
        SQLAOPort                  = 1500
    }

    Write-Log "SQLAO Config Generated for $vmName" -LogOnly
    return $config
}

function Get-ValidCASSiteCodes {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [String]$Domain
    )

    $existingSiteCodes = @()
    $existingSiteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "CAS" | Select-Object -ExpandProperty SiteCode

    if ($Config) {
        $containsCS = $Config.virtualMachines.role -contains "CAS"
        if ($containsCS) {
            $CSVM = $Config.virtualMachines | Where-Object { $_.role -eq "CAS" }
            $existingSiteCodes += $CSVM.siteCode
        }
    }

    return ($existingSiteCodes | Select-Object -Unique)
}

function Get-ValidPRISiteCodes {
    param (
        [Parameter(Mandatory = $false)]
        [object]$Config,
        [Parameter(Mandatory = $true)]
        [String]$Domain
    )

    $existingSiteCodes = @()
    $existingSiteCodes += Get-ExistingSiteServer -DomainName $Domain -Role "Primary" | Select-Object -ExpandProperty SiteCode

    if ($Config) {
        $containsPS = $Config.virtualMachines.role -contains "Primary"
        if ($containsPS) {
            $PSVM = $Config.virtualMachines | Where-Object { $_.role -eq "Primary" }
            $existingSiteCodes += $PSVM.siteCode
        }
    }

    return ($existingSiteCodes | Select-Object -Unique)
}

function Get-ExistingForDomain {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "SiteSystem", "DomainMember", "Secondary", "Proxy")]
        [string]$Role
    )

    try {

        $existingValue = @()
        $vmList = Get-List -Type VM -DomainName $DomainName
        foreach ($vm in $vmList) {
            if ($vm.Role.ToLowerInvariant() -eq $Role.ToLowerInvariant()) {
                $existingValue += $vm.VmName
            }
        }

        if ($existingValue.Count -gt 0) {
            return $existingValue
        }

        return $null

    }
    catch {
        Write-Log "Failed to get existing $Role from $DomainName. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-ExistingSiteServer {
    param(
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [ValidateSet("CAS", "Primary", "Secondary")]
        [string]$Role,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [string]$SiteCode
    )

    try {

        if ($DomainName) {
            $vmList = Get-List -Type VM -DomainName $DomainName
        }
        else {
            $vmList = Get-List -Type VM
        }

        if ($Role) {
            $vmList = $vmList | Where-Object { $_.Role -eq $Role }
        }

        $existingValue = @()
        foreach ($vm in $vmList) {
            $so = $null
            if ($vm.role -in "CAS", "Primary", "Secondary") {
                if ($PSBoundParameters.ContainsKey("SiteCode") -and $vm.siteCode.ToLowerInvariant() -eq $SiteCode.ToLowerInvariant()) {

                    $so = [PSCustomObject]@{
                        VmName   = $vm.VmName
                        Role     = $vm.Role
                        SiteCode = $vm.siteCode
                        Domain   = $vm.domain
                        State    = $vm.State
                        Network  = $vm.Network
                    }
                    $existingValue += $so
                }

                if (-not $PSBoundParameters.ContainsKey("SiteCode")) {

                    $so = [PSCustomObject]@{
                        VmName   = $vm.VmName
                        Role     = $vm.Role
                        SiteCode = $vm.siteCode
                        Domain   = $vm.domain
                        State    = $vm.State
                        Network  = $vm.Network
                    }
                    $existingValue += $so
                }
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Failed to get existing site servers. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-ExistingForNetwork {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Network")]
        [string]$Network,
        [Parameter(Mandatory = $false, HelpMessage = "VM Role")]
        [ValidateSet("DC", "CAS", "Primary", "SiteSystem", "DomainMember", "Secondary")]
        [string]$Role,
        [Parameter(Mandatory = $false, HelpMessage = "VMName to exclude")]
        [string] $exclude = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Config To Check")]
        [object] $config
    )

    try {

        $existingValue = @()
        if ($config) {
            $vmList = Get-List2 -DeployConfig $config | Where-Object { $_.network -eq $Network }
        }
        else {
            $vmList = Get-List -Type VM | Where-Object { $_.network -eq $Network }
        }
        foreach ($vm in $vmList) {
            if ($exclude -and $vm.VmName -eq $exclude) {
                continue
            }
            if ($vm.role) {
                if ($vm.Role.ToLowerInvariant() -eq $Role.ToLowerInvariant()) {
                    $existingValue += $vm.VmName
                }
            }
        }

        return $existingValue

    }
    catch {
        Write-Log "Failed to get existing $Role from $Subnet. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-ParentSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName
    )

    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    if ($DomainName) {
        $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) })
        if ($vmList) {
            $first = $vmList | Select-Object -First 1
   
            $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) })

            if ($type -eq "Name") {
                return ($vmList | Select-Object -First 1).vmName
            }
            else {
                return $vmList | Select-Object -First 1
            }
        }
        return
    }

    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        $first = $configVMs | Select-Object -First 1

        $configVMs = @()
        $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
        $first = $configVMs | Select-Object -First 1
        
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return $configVMs | Select-Object -First 1
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        $first = $existingVMs | Select-Object -First 1
      
        $existingVMs = @()
        $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) }
        $first = $existingVMs | Select-Object -First 1
        
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return $existingVMs | Select-Object -First 1
        }
    }
    Add-ErrorMessage "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $($deployConfig.vmOptions.DomainName)"
    throw "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $($deployConfig.vmOptions.DomainName)"
    
    return $null
}

function Get-TopSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName
    )

    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    if ($DomainName) {
        $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) })
        if ($vmList) {
            $first = $vmList | Select-Object -First 1
            while ($first.ParentSiteCode) {        
                $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) })
                $first = $vmList | Select-Object -First 1
            }
            if ($type -eq "Name") {
                return ($vmList | Select-Object -First 1).vmName
            }
            else {
                return $vmList | Select-Object -First 1
            }
        }
        return
    }

    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        $first = $configVMs | Select-Object -First 1
        while ($first.ParentSiteCode) {        
            $configVMs = @()
            $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
            $first = $configVMs | Select-Object -First 1
        }
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return $configVMs | Select-Object -First 1
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        $first = $existingVMs | Select-Object -First 1
        while ($first.ParentSiteCode) {        
            $existingVMs = @()
            $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $($first.ParentSiteCode) -and ($_.role -in $SiteServerRoles) }
            $first = $existingVMs | Select-Object -First 1
        }
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return $existingVMs | Select-Object -First 1
        }
    }
    Add-ErrorMessage "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $($deployConfig.vmOptions.DomainName)"
    throw "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $($deployConfig.vmOptions.DomainName)"
    
    return $null
}

function Get-SiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName

    )
    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    if ($DomainName) {
        $vmList = @(get-list -type VM -domain $DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) })
        if ($vmList) {
            if ($type -eq "Name") {
                return ($vmList | Select-Object -First 1).vmName
            }
            else {
                return $vmList | Select-Object -First 1
            }
        }
        return
    }


    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return $configVMs | Select-Object -First 1
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName -SmartUpdate:$SmartUpdate | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return $existingVMs | Select-Object -First 1
        }
    }
    throw "Could not find current or existing SiteServer for SiteCode: $SiteCode Domain: $DomainName"
    return $null
}


function Get-SqlServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $false, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name",
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Domain Name")]
        [string] $DomainName

    )
    if (-not $SiteCode) {
        throw "SiteCode is NULL"
        return $null
    }


    if ($DomainName) {
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -DomainName $DomainName -type VM
    }
    else {
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -type VM
    }
    if ($SiteServer.RemoteSQLVM) {
        if ($type -eq "Name") {
            Return $SiteServer.RemoteSQLVM
        }
        else {
            if ($DomainName) {
                $remoteSQL = get-list -type VM -domain $DomainName | Where-Object { $_.VmName -eq $SiteServer.RemoteSQLVM }
            }
            else {
                $remoteSQL = $deployConfig.virtualMachines | Where-Object { $_.VmName -eq $SiteServer.RemoteSQLVM }
            }
            if ($type -eq "Name") {
                return $remoteSQL.vmName
            }
            else {
                return $remoteSQL
            }
        }
    }

    if ($type -eq "Name") {
        return $SiteServer.vmName
    }
    else {
        return $SiteServer
    }
}

function Get-LabWsusUrl {
    <#
    .SYNOPSIS
    Determine the WSUS server URL for a VM based on deployment config.
    Mirrors the client-push network-affinity logic from Common.GenConfig.ps1.
    Returns [PSCustomObject]@{ WsusUrl = string; IsRealWsus = bool }
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $DeployConfig,
        [Parameter(Mandatory = $true)]
        [object] $CurrentItem
    )

    $domainName = $DeployConfig.vmOptions.domainName
    $allVMs = $DeployConfig.virtualMachines

    # Determine protocol/port from PKI setting
    $usePKI = [bool]$DeployConfig.cmOptions.UsePKI
    $protocol = if ($usePKI) { "https" } else { "http" }
    $port = if ($usePKI) { 8531 } else { 8530 }

    # --- Step 1: Will this VM get a ConfigMgr client? (mirrors Common.GenConfig.ps1 ~L1396)
    $pushableRoles = @('DomainMember', 'Primary', 'CAS', 'Secondary', 'SiteSystem', 'PassiveSite')
    $getsClient = $CurrentItem.role -in $pushableRoles -and $CurrentItem.pushClient -ne $false

    if ($getsClient) {
        # Find the Primary that would push to this VM (same network or child Secondary's network)
        $primaries = @($allVMs | Where-Object { $_.role -eq 'Primary' })
        $matchedPrimary = $null
        foreach ($pri in $primaries) {
            # Direct network match
            if ($pri.network -eq $CurrentItem.network) {
                $matchedPrimary = $pri
                break
            }
            # Check child Secondaries' networks
            $childSecondaries = @($allVMs | Where-Object { $_.role -eq 'Secondary' -and $_.parentSiteCode -eq $pri.siteCode })
            foreach ($sec in $childSecondaries) {
                if ($sec.network -eq $CurrentItem.network) {
                    $matchedPrimary = $pri
                    break
                }
            }
            if ($matchedPrimary) { break }
        }

        if ($matchedPrimary) {
            # Find a SUP for this Primary's siteCode (skip CAS — upstream only)
            $supVM = $allVMs | Where-Object {
                $_.installSUP -eq $true -and $_.siteCode -eq $matchedPrimary.siteCode
            } | Select-Object -First 1

            if ($supVM) {
                $fqdn = "$($supVM.vmName).$domainName"
                return [PSCustomObject]@{ WsusUrl = "${protocol}://${fqdn}:${port}"; IsRealWsus = $true }
            }
        }
    }

    # --- Step 2: No client or no SUP found — check for standalone WSUS
    $standaloneWsus = $allVMs | Where-Object { $_.role -eq 'WSUS' } | Select-Object -First 1
    if ($standaloneWsus) {
        $fqdn = "$($standaloneWsus.vmName).$domainName"
        return [PSCustomObject]@{ WsusUrl = "${protocol}://${fqdn}:${port}"; IsRealWsus = $true }
    }

    # --- Step 3: Fallback — fake WSUS
    return [PSCustomObject]@{ WsusUrl = "http://localhost"; IsRealWsus = $false }
}

function Get-VmBgInfoProperties {
    <#
    .SYNOPSIS
    Build the values BgInfo renders in the "MemLabs Configuration" block of the wallpaper.

    .DESCRIPTION
    Every value is derived from the deployment config, not from the guest, so the
    wallpaper describes the lab MemLabs was asked to build. Each field is always
    returned (blank ones as "-") so a re-deploy that drops a role overwrites the
    old text instead of leaving it stale.

    Returns an array of [PSCustomObject]@{ Name; Value }, where Name is the value
    name under HKLM:\SOFTWARE\MemLabs\BgInfo that SERVER.bgi / CLIENT.bgi read.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $DeployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "VM object from the deploy config")]
        [object] $CurrentItem
    )

    $none = "-"
    $sep = "  |  "
    $vmOptions = $DeployConfig.vmOptions
    $cmOptions = $DeployConfig.cmOptions

    # --- Lab: domain, this VM's subnet, and the VM-name prefix
    $labParts = @()
    if ($vmOptions.domainName) { $labParts += $vmOptions.domainName }
    $network = if ($CurrentItem.network) { $CurrentItem.network } else { $vmOptions.network }
    if ($network) { $labParts += "subnet $network" }
    if ($vmOptions.prefix) { $labParts += "prefix $($vmOptions.prefix)" }

    # --- Role: the MemLabs role plus its place in the ConfigMgr hierarchy
    $roleParts = @()
    if ($CurrentItem.role) { $roleParts += $CurrentItem.role }
    if ($CurrentItem.siteCode) {
        $site = "site $($CurrentItem.siteCode)"
        if ($CurrentItem.siteName) { $site += " ($($CurrentItem.siteName))" }
        $roleParts += $site
    }
    if ($CurrentItem.parentSiteCode) { $roleParts += "parent site $($CurrentItem.parentSiteCode)" }
    if ($CurrentItem.OtherNode) { $roleParts += "cluster partner $($CurrentItem.OtherNode)" }

    # --- Installed roles: what this VM actually gets stood up on it
    $installed = @()
    switch ($CurrentItem.role) {
        "CAS" { $installed += "Central Administration Site" }
        "Primary" { $installed += "Primary Site Server" }
        "Secondary" { $installed += "Secondary Site Server" }
        "PassiveSite" { $installed += "Passive Site Server" }
        "SQLAO" { $installed += "SQL Always On node" }
        "WSUS" { $installed += "WSUS" }
        "FileServer" { $installed += "File Server" }
        "Proxy" { $installed += "Squid proxy" }
        "StandaloneRootCA" { $installed += "Standalone Root CA" }
    }
    if ($CurrentItem.InstallCA) { $installed += "Certificate Authority" }
    if ($CurrentItem.installMP) { $installed += "Management Point" }
    if ($CurrentItem.enablePullDP) { $installed += "Pull Distribution Point" }
    elseif ($CurrentItem.installDP) { $installed += "Distribution Point" }
    if ($CurrentItem.installSUP) { $installed += "Software Update Point" }
    if ($CurrentItem.installRP) { $installed += "Reporting Services Point" }
    if ($CurrentItem.useDatabaseReplica) { $installed += "MP Database Replica" }
    if ($CurrentItem.remoteContentLibVM) { $installed += "Remote Content Library on $($CurrentItem.remoteContentLibVM)" }
    if ($CurrentItem.installSSMS) { $installed += "SSMS" }
    if ($CurrentItem.installOffice) { $installed += "Office" }

    # --- SQL: local instance, or the remote SQL this site server was pointed at
    $sqlParts = @()
    if ($CurrentItem.sqlVersion) {
        $sqlParts += $CurrentItem.sqlVersion
        $instance = if ($CurrentItem.sqlInstanceName) { $CurrentItem.sqlInstanceName } else { "MSSQLSERVER" }
        $port = if ($CurrentItem.sqlPort) { $CurrentItem.sqlPort } else { "1433" }
        $sqlParts += "$instance on port $port"
    }
    if ($CurrentItem.remoteSQLVM) { $sqlParts += "remote SQL on $($CurrentItem.remoteSQLVM)" }
    if ($CurrentItem.AlwaysOnListenerName) { $sqlParts += "AG listener $($CurrentItem.AlwaysOnListenerName)" }

    # --- ConfigMgr: hierarchy-wide options, so it reads the same on every VM in the lab
    $cmParts = @()
    if ($cmOptions -and $cmOptions.install) {
        if ($cmOptions.version) { $cmParts += $cmOptions.version }
        if ($cmOptions.EVALVersion) { $cmParts += "EVAL media" }
        if ($cmOptions.UsePKI) { $cmParts += "PKI / HTTPS" } else { $cmParts += "Enhanced HTTP" }
        if ($cmOptions.pushClientToDomainMembers) { $cmParts += "client push enabled" }
    }
    else {
        $cmParts += "not installed"
    }

    # --- Proxy: which Squid VM this one is routed through, if any
    $proxy = "not used"
    if ($CurrentItem.role -eq "Proxy") {
        $proxy = "this VM is the lab proxy (Squid on 3128)"
    }
    else {
        # Common.Linux.ps1 only loads under PowerShell 7; VMBuild.cmd still has a 5.1
        # fallback launch path, where per-VM useProxy is the same source of truth.
        if (Get-Command Test-VmUsesProxy -ErrorAction SilentlyContinue) {
            $usesProxy = Test-VmUsesProxy -Vm $CurrentItem -DeployConfig $DeployConfig
        }
        else {
            $usesProxy = [bool]$CurrentItem.useProxy -and $CurrentItem.role -notin @("DC", "BDC", "StandaloneRootCA")
        }

        if ($usesProxy) {
            $proxyVm = $DeployConfig.virtualMachines | Where-Object { $_.role -eq "Proxy" } | Select-Object -First 1
            $proxyName = if ($proxyVm) { $proxyVm.vmName } else { Get-ExistingForDomain -DomainName $vmOptions.domainName -Role "Proxy" | Select-Object -First 1 }
            $proxy = if ($proxyName) { "$proxyName.$($vmOptions.domainName):3128" } else { "enabled (proxy VM not found)" }
        }
    }

    $lab = if ($labParts.Count) { $labParts -join $sep } else { $none }
    $role = if ($roleParts.Count) { $roleParts -join $sep } else { $none }
    $installedRoles = if ($installed.Count) { $installed -join ", " } else { $none }
    $sql = if ($sqlParts.Count) { $sqlParts -join $sep } else { $none }

    $values = [ordered]@{
        Lab            = $lab
        Role           = $role
        InstalledRoles = $installedRoles
        SQL            = $sql
        ConfigMgr      = $cmParts -join $sep
        Proxy          = $proxy
    }

    return @($values.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = [string]$_.Value } })
}

function Get-VmBgInfoBackgroundColor {
    <#
    .SYNOPSIS
    Desktop background colour for a VM's BgInfo wallpaper, keyed off its MemLabs role.

    .DESCRIPTION
    SERVER.bgi and CLIENT.bgi already ship different colours (slate vs blue), so a
    per-role colour is just widening something BgInfo already honours -- it makes a
    wall of RDP thumbnails readable without reading any text. Every colour is dark
    because the .bgi renders its text in white and pale yellow.

    Returns a COLORREF (0x00BBGGRR, NOT RGB) or $null for roles that should keep
    whichever colour the template itself carries.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM object from the deploy config")]
        [object] $CurrentItem
    )

    $palette = @{
        DC          = @(0, 100, 60)     # green   - directory
        BDC         = @(0, 100, 60)
        CAS         = @(96, 48, 128)    # purple  - top of hierarchy
        Primary     = @(0, 82, 140)     # blue    - primary site
        Secondary   = @(0, 110, 120)    # teal    - secondary site
        PassiveSite = @(70, 70, 120)    # indigo  - HA partner
        SiteSystem  = @(60, 90, 110)    # steel   - DP/MP/SUP/RP
        SQLAO       = @(140, 50, 45)    # maroon  - database
        WSUS        = @(105, 95, 30)    # olive
        FileServer  = @(110, 80, 40)    # brown
        Proxy       = @(120, 45, 100)   # magenta
    }

    $rgb = $null
    if ($CurrentItem.role -and $palette.ContainsKey($CurrentItem.role)) {
        $rgb = $palette[$CurrentItem.role]
    }
    elseif ($CurrentItem.sqlVersion) {
        $rgb = $palette['SQLAO']
    }

    if (-not $rgb) { return $null }
    return ([int]$rgb[0]) -bor ([int]$rgb[1] -shl 8) -bor ([int]$rgb[2] -shl 16)
}

function Set-BgiBackgroundColor {
    <#
    .SYNOPSIS
    Overwrite the Background COLORREF inside a .bgi file's bytes, in place.

    .DESCRIPTION
    .bgi records are [UInt32 nameLen][name ASCII + NUL][UInt32 type][UInt32 dataLen][data];
    Background is a type-4 DWORD. Only those 4 data bytes are touched.

    .OUTPUTS
    [bool] $true when the Background record was found and patched.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = ".bgi file bytes, modified in place")]
        [byte[]] $Bytes,
        [Parameter(Mandatory = $true, HelpMessage = "COLORREF (0x00BBGGRR)")]
        [int] $ColorRef
    )

    $offset = 0
    while ($offset + 12 -le $Bytes.Length) {
        $nameLen = [BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        if ($nameLen -lt 1 -or $offset + $nameLen + 8 -gt $Bytes.Length) { return $false }
        $name = [Text.Encoding]::ASCII.GetString($Bytes, $offset, $nameLen - 1)
        $offset += $nameLen
        $type = [BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        $dataLen = [BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        if ($offset + $dataLen -gt $Bytes.Length) { return $false }
        if ($name -eq "Background" -and $type -eq 4 -and $dataLen -eq 4) {
            [BitConverter]::GetBytes([uint32]$ColorRef).CopyTo($Bytes, $offset)
            return $true
        }
        $offset += $dataLen
    }
    return $false
}

function Set-VmBgInfoConfig {
    <#
    .SYNOPSIS
    Publish a VM's MemLabs lab configuration to the guest so BgInfo can render it.

    .DESCRIPTION
    Writes the HKLM:\SOFTWARE\MemLabs\BgInfo values consumed by the "MemLabs
    Configuration" block in SERVER.bgi / CLIENT.bgi, and refreshes those two .bgi
    files under C:\staging\bginfo so a VM built from a base image that predates the
    block still renders it. BgInfo runs from a Startup shortcut, so the refreshed
    text appears at the next logon.

    Purely cosmetic, so failures are logged and never thrown.

    .PARAMETER Status
    Where the deploy is when this runs. 'Deploying' (Phase 2) leaves the wallpaper
    saying so, which is what a VM whose deploy died later still shows -- that is the
    whole point of writing this twice. Defaults to 'Deploying' rather than being
    Mandatory: Test-MandatoryParamCalls only flags calls that bind NO mandatory
    parameter, so a future call site dropping this one would not be caught and would
    hang the job on a prompt. Understating progress is the safe way to be wrong.

    .OUTPUTS
    [bool] $true when the guest was updated.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $DeployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "VM object from the deploy config")]
        [object] $CurrentItem,
        [Parameter(Mandatory = $false, HelpMessage = "Deployment state to stamp on the wallpaper")]
        [ValidateSet("Deploying", "Validated")]
        [string] $Status = "Deploying"
    )

    $vmName = $CurrentItem.vmName
    $statusText = if ($Status -eq "Validated") { "(validated)" } else { "-- deploy in progress" }
    $items = @(Get-VmBgInfoProperties -DeployConfig $DeployConfig -CurrentItem $CurrentItem) +
        [PSCustomObject]@{ Name = "Status"; Value = $statusText }

    # The two templates are ~4KB each, so they ride along as base64 in the same
    # PSDirect call instead of paying for a separate Copy-ItemSafe job.
    $backgroundColor = Get-VmBgInfoBackgroundColor -CurrentItem $CurrentItem
    $bgiFiles = @()
    foreach ($bgi in @("SERVER.bgi", "CLIENT.bgi")) {
        $source = Join-Path $Common.StagingInjectPath "staging\bginfo\$bgi"
        if (Test-Path -LiteralPath $source) {
            $bytes = [IO.File]::ReadAllBytes($source)
            if ($null -ne $backgroundColor -and -not (Set-BgiBackgroundColor -Bytes $bytes -ColorRef $backgroundColor)) {
                Write-Log "[BgInfo] $vmName`: $bgi has no Background record; the role colour was not applied." -Warning -LogOnly
            }
            $bgiFiles += [PSCustomObject]@{ Name = $bgi; Base64 = [Convert]::ToBase64String($bytes) }
        }
    }
    if ($bgiFiles.Count -ne 2) {
        Write-Log "[BgInfo] $vmName`: Found $($bgiFiles.Count) of 2 .bgi templates under $($Common.StagingInjectPath)\staging\bginfo; the guest may keep rendering an older layout." -Warning -LogOnly
    }

    $write_BgInfoConfig = {
        param($Items, $BgiFiles)
        # BgInfo ships 32-bit (live.sysinternals.com/bginfo.exe, PE machine 0x014C) and the
        # shortcut launches it, so WOW64 redirects its HKLM\SOFTWARE reads into WOW6432Node.
        # Writing only the native view renders "(none)" for every field while a 64-bit
        # readback truthfully reports them all present -- it is reading the other view.
        $regPaths = @("HKLM:\SOFTWARE\MemLabs\BgInfo")
        if (Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node") {
            $regPaths += "HKLM:\SOFTWARE\WOW6432Node\MemLabs\BgInfo"
        }
        $expected = @($Items | ForEach-Object { $_.Name }) + "Deployed"
        # Stamped in the guest's own time zone -- the host may not share it.
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"

        foreach ($regPath in $regPaths) {
            try {
                if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null }
                foreach ($item in $Items) {
                    New-ItemProperty -Path $regPath -Name $item.Name -PropertyType String -Value $item.Value -Force -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -Path $regPath -Name "Deployed" -PropertyType String -Value $stamp -Force -ErrorAction Stop | Out-Null
            }
            catch {
                throw "BgInfo registry write failed at $regPath`: $($_.Exception.Message)"
            }
        }

        # Report what is actually READABLE in every view BgInfo might use -- a wallpaper
        # full of "(none)" with a log line claiming success is the failure this catches.
        $missing = @()
        foreach ($regPath in $regPaths) {
            $props = @(@(Get-Item -LiteralPath $regPath -ErrorAction SilentlyContinue).Property)
            foreach ($name in $expected) {
                if ($name -notin $props) { $missing += "$regPath\$name" }
            }
        }
        $total = $expected.Count * $regPaths.Count
        $readable = $total - $missing.Count

        $refreshed = 0
        $bgiDir = "C:\staging\bginfo"
        # "0 refreshed" must not mean both "already current" and "BgInfo isn't staged here".
        if (-not (Test-Path -LiteralPath $bgiDir)) {
            $bgiNote = "; $bgiDir NOT PRESENT - BgInfo is not staged on this VM"
        }
        else {
            foreach ($file in $BgiFiles) {
                $target = Join-Path $bgiDir $file.Name
                $current = ""
                if (Test-Path -LiteralPath $target) {
                    $current = [Convert]::ToBase64String([IO.File]::ReadAllBytes($target))
                }
                if ($current -ne $file.Base64) {
                    [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($file.Base64))
                    $refreshed++
                }
            }
            $bgiNote = ", $refreshed of $(@($BgiFiles).Count) .bgi template(s) refreshed"
        }
        $note = "$readable/$total values readable in $($regPaths.Count) registry view(s)$bgiNote"
        if ($missing.Count) { $note += "; MISSING: $($missing -join ', ')" }
        return $note
    }

    $result = Invoke-VmCommand -VmName $vmName -VmDomainName $DeployConfig.vmOptions.domainName -ScriptBlock $write_BgInfoConfig `
        -ArgumentList @($items, $bgiFiles) -DisplayName "Update BgInfo lab configuration" -SuppressLog

    if ($result.ScriptBlockFailed) {
        Write-Log "[BgInfo] $vmName`: Failed to publish the lab configuration to the guest. $($result.ScriptBlockOutput)" -Warning -LogOnly
        return $false
    }

    # The guest counts what it can read back, so MISSING means the wallpaper will
    # render "(none)" -- say so here rather than leaving it to be discovered visually.
    if ("$($result.ScriptBlockOutput)" -match 'MISSING|NOT PRESENT') {
        Write-Log "[BgInfo] $vmName`: $($result.ScriptBlockOutput)" -Warning -LogOnly
        return $false
    }

    Write-Log "[BgInfo] $vmName`: $($result.ScriptBlockOutput)" -LogOnly
    return $true
}

function get-RoleForSitecode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Sitecode")]
        [string] $siteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToCheck = $global:config
    )

    $SiteServerRoles = @("Primary", "Secondary", "CAS")
    $configVMs = @()
    $configVMs += $configToCheck.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs.Count -eq 1) {
        return ($configVMs | Select-Object -First 1).Role
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $ConfigToCheck.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs.Count -eq 1) {
        return ($existingVMs | Select-Object -First 1).Role
    }
    return $null
}

function Get-VMFromList2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [object] $vmName,
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Get VMs from all domains")]
        [bool] $Global = $false
    )

    $vm = Get-List2 -DeployConfig $deployConfig -SmartUpdate:$SmartUpdate | Where-Object { $_.vmName -eq $vmName }
    if ($vm) {
        return $vm
    }
    else {
        if ($Global) {
            $vm = Get-List -Type VM | Where-Object { $_.vmName -eq $vmName }
            if ($vm) {
                return $vm
            }
        }
    }
}

function Get-SiteCodeForSQLServer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SQLServer VMName")]
        [object] $SqlServer,
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true
    )
    $vm = Get-List2 -DeployConfig $deployConfig -SmartUpdate:$SmartUpdate | Where-Object { $_.RemoteSQLVM -eq $SqlServer }
    if ($vm) {
        if ($vm.siteCode) {
            return $vm.siteCode
        }
    }
}

function Get-PrimarySiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "SmartUpdate")]
        [bool] $SmartUpdate = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -SmartUpdate:$SmartUpdate
    if (-not $SiteServer) {
        throw "Could not find SiteServer for SiteCode: $SiteCode"
    }
    $roleforSite = get-RoleForSitecode -ConfigToCheck $deployConfig -siteCode $SiteCode
    if ($roleforSite -eq "Primary") {
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteCode -type VM -SmartUpdate:$false
        }
    }
    if ($roleforSite -eq "Secondary") {
        $SiteServerVM = Get-VMFromList2 -deployConfig $deployConfig -vmName $SiteServer -SmartUpdate:$false
        if (-not $SiteServer) {
            write-host $SiteServerVM | ConvertTo-Json
            throw "Could not find VM $SiteServer"
        }
        $SiteServer = Get-SiteServerForSiteCode -deployConfig $deployConfig -SiteCode $SiteServerVM.parentSiteCode  -SmartUpdate:$false
        if (-not $SiteServer) {
            write-host $SiteServerVM | ConvertTo-Json
            throw "Secondary: Could not find SiteServer for SiteCode: $($SiteServerVM.parentSiteCode)"
        }
        if ($type -eq "Name") {
            return $SiteServer
        }
        else {
            return Get-VMFromList2 -deployConfig $deployConfig -vmName $SiteServer  -SmartUpdate:$false
        }
    }
}

function Get-PassiveSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServerRoles = @("PassiveSite")
    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return ($configVMs | Select-Object -First 1)
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return ($existingVMs | Select-Object -First 1)
        }
    }
    return $null
}

function Get-ActiveSiteServerForSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DeployConfig")]
        [object] $deployConfig,
        [Parameter(Mandatory = $true, HelpMessage = "SiteCode")]
        [object] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Return Object Type")]
        [ValidateSet("Name", "VM")]
        [string] $type = "Name"
    )
    $SiteServerRoles = @("Primary", "CAS")
    $configVMs = @()
    $configVMs += $deployConfig.virtualMachines | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) -and -not $_.hidden }
    if ($configVMs) {
        if ($type -eq "Name") {
            return ($configVMs | Select-Object -First 1).vmName
        }
        else {
            return ($configVMs | Select-Object -First 1)
        }
    }
    $existingVMs = @()
    $existingVMs += get-list -type VM -domain $deployConfig.vmOptions.DomainName | Where-Object { $_.SiteCode -eq $siteCode -and ($_.role -in $SiteServerRoles) }
    if ($existingVMs) {
        if ($type -eq "Name") {
            return ($existingVMs | Select-Object -First 1).vmName
        }
        else {
            return ($existingVMs | Select-Object -First 1)
        }
    }
    return $null
}

function Get-NetworkList {

    param(
        [Parameter(Mandatory = $false)]
        [string] $DomainName
    )
    try {

        if ($DomainName) {
            return (Get-List -Type Network -DomainName $DomainName)
        }

        return (Get-List -Type Network)

    }
    catch {
        Write-Log "Failed to get network list. $_" -Failure -LogOnly
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-DomainList {

    try {
        return (Get-List -Type UniqueDomain | Sort-Object)
    }
    catch {
        Write-Log "Failed to get domain list. $_" -Failure -LogOnly
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-VMSizeCached {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VM Object")]
        [object] $vm,
        [Parameter(Mandatory = $false, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )

    $jsonFile = $($vm.vmID).toString() + ".disk.json"
    $cacheFile = Join-Path $global:common.CachePath $jsonFile
    Write-Log -hostonly "Cache File $cacheFile" -Verbose
    $vmCacheEntry = $null
    if (Test-Path $cacheFile) {
        try {
            $vmCacheEntry = Get-Content $cacheFile | ConvertFrom-Json
            if ($common.InJob) {
                return $vmCacheEntry
            }
        }
        catch {}
    }


    if ($vmCacheEntry) {
        if (Test-CacheValid -EntryTime $vmCacheEntry.EntryAdded -MaxHours 24) {
            if ($vmCacheEntry.diskSize -and $vmCacheEntry.diskSize -gt 0) {
                return $vmCacheEntry
            }
        }
    }


    #write-host "Making new Entry for $($vm.vmName)"
    # if we didn't return the cache entry, get new data, and add it to cache
    if (-not $Common.InJob) {
        # Sum the actual VHDX file sizes via Get-VM's HardDrives instead of a recursive
        # Get-ChildItem on $vm.Path. Recursing the VM folder is dramatically slower because
        # it walks snapshots, paging files, and per-file metadata for every file.
        $diskSize = 0
        try {
            foreach ($hd in $vm.HardDrives) {
                if ($hd.Path -and (Test-Path -LiteralPath $hd.Path -PathType Leaf)) {
                    $diskSize += [int64](Get-Item -LiteralPath $hd.Path -ErrorAction Stop).Length
                }
            }
        }
        catch {
            # Fall back to the recursive scan if HardDrives enumeration fails for any reason.
            $diskSize = (Get-ChildItem $vm.Path -Recurse -ErrorAction SilentlyContinue | Measure-Object length -sum).sum
        }
        $MemoryStartup = $vm.MemoryStartup
    }
    else {
        $diskSize = 0
        $MemoryStartup = 0
    }
    $MemoryStartup = $vm.MemoryStartup
    $vmCacheEntry = [PSCustomObject]@{
        vmId          = $vm.vmID
        diskSize      = $diskSize
        MemoryStartup = $MemoryStartup
        EntryAdded    = (Get-Date -format "MM/dd/yyyy HH:mm")
    }
    if (-not $Common.InJob) {
        ConvertTo-Json  $vmCacheEntry | Out-File $cacheFile -Force
    }
    return $vmCacheEntry
}

$global:vmNetCache = $null
function Get-VMNetworkCached {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VM Object")]
        [object] $vm,
        [Parameter(Mandatory = $false, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )
    $jsonFile = $($vm.vmID).toString() + ".network.json"
    $cacheFile = Join-Path $global:common.CachePath $jsonFile

    $vmCacheEntry = $null
    if (Test-Path $cacheFile) {
        try {
            $vmCacheEntry = Get-Content $cacheFile | ConvertFrom-Json
            if ($common.InJob) {
                return $vmCacheEntry
            }
        }
        catch {}
    }


    if ($vmCacheEntry) {
        # Switch names rarely change — use a long TTL (30 days)
        if (Test-CacheValid -EntryTime $vmCacheEntry.EntryAdded -MaxHours 720) {
            return $vmCacheEntry
        }
    }

    # Check the in-memory bulk cache (populated by Invoke-VMNetworkBulkWarmup)
    if ($global:Common.NetCache -and $global:Common.NetCache.ContainsKey($vm.Id)) {
        $vmCacheEntry = $global:Common.NetCache[$vm.Id]
        if ($vmCacheEntry.SwitchName) {
            ConvertTo-Json $vmCacheEntry | Out-File $cacheFile -Force
        }
        return $vmCacheEntry
    }

    # if we didn't return the cache entry, get new data, and add it to cache
    Write-Log "Get-VMNetworkCached: cache miss for $($vm.Name), calling Get-VMNetworkAdapter..." -LogOnly
    $vmNet = ($vm | Get-VMNetworkAdapter)
    Write-Log "Get-VMNetworkCached: Get-VMNetworkAdapter returned for $($vm.Name)." -LogOnly
    $vmCacheEntry = [PSCustomObject]@{
        vmId       = $vm.vmID
        SwitchName = $vmNet.SwitchName
        #IPAddresses = $vmNet.IPAddresses
        EntryAdded = (Get-Date -format "MM/dd/yyyy HH:mm")
    }

    # Populate in-memory cache so subsequent calls in the same runspace
    # (e.g. a second Get-List on the same thread) don't repeat the WMI hit.
    if (-not $global:Common.NetCache) { $global:Common.NetCache = @{} }
    $global:Common.NetCache[$vm.Id] = $vmCacheEntry

    if ($vmNet.SwitchName) {
        ConvertTo-Json $vmCacheEntry | Out-File $cacheFile -Force
    }
    return $vmCacheEntry
}

# Bulk-fetch all VM network adapters in a single WMI call and populate the
# in-memory NetCache AND the per-VM .network.json disk cache. Start-Job
# workers (separate processes) can't share in-memory cache, but they CAN
# read the disk files — so pre-populating them here means every job worker
# gets instant cache hits instead of triggering its own WMI calls.
function Invoke-VMNetworkBulkWarmup {
    if ($global:Common.NetCache) { return }  # Already warm

    # Try to hydrate from on-disk cache files written by a previous run.
    # Switch names rarely change, so use a long TTL (24 hours).
    # The per-VM Get-VMNetworkCached already uses 30 days.
    $cachePath = $global:Common.CachePath
    if ($cachePath) {
        $diskFiles = @(Get-ChildItem -Path $cachePath -Filter "*.network.json" -ErrorAction SilentlyContinue)
        if ($diskFiles.Count -gt 0) {
            $cutoff = (Get-Date).AddHours(-24)
            $allFresh = $true
            $loaded = @{}
            foreach ($f in $diskFiles) {
                if ($f.LastWriteTime -lt $cutoff) { $allFresh = $false; break }
                try {
                    $entry = Get-Content $f.FullName -Raw | ConvertFrom-Json
                    if ($entry.vmId) { $loaded[$entry.vmId] = $entry }
                }
                catch { $allFresh = $false; break }
            }
            if ($allFresh -and $loaded.Count -gt 0) {
                $global:Common.NetCache = $loaded
                Write-Log "Invoke-VMNetworkBulkWarmup: loaded $($loaded.Count) adapters from disk cache." -LogOnly
                return
            }
        }
    }

    Write-Log "Invoke-VMNetworkBulkWarmup: fetching all VM network adapters in one call..." -LogOnly
    $global:Common.NetCache = @{}
    try {
        # Run as a job with a timeout so a hung WMI subsystem doesn't block startup indefinitely.
        $job = Start-Job -ScriptBlock { Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue }
        $completed = $job | Wait-Job -Timeout 30
        if (-not $completed) {
            Write-Log "Invoke-VMNetworkBulkWarmup: WMI call timed out after 30s. Skipping." -Warning -LogOnly
            $job | Stop-Job
            $job | Remove-Job -Force
            return
        }
        $allAdapters = $job | Receive-Job
        $job | Remove-Job -Force
        $now = Get-Date -Format "MM/dd/yyyy HH:mm"
        $cachePath = $global:Common.CachePath
        foreach ($adapter in $allAdapters) {
            if (-not $adapter.VMId) { continue }
            $entry = [PSCustomObject]@{
                vmId       = $adapter.VMId
                SwitchName = $adapter.SwitchName
                IPAddress  = ($adapter.IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1)
                EntryAdded = $now
            }
            $global:Common.NetCache[$adapter.VMId] = $entry

            # Persist to disk so Start-Job workers (separate processes) get
            # instant cache hits without any WMI calls.
            if ($entry.SwitchName -and $cachePath) {
                $jsonFile = $adapter.VMId.ToString() + ".network.json"
                $cacheFile = Join-Path $cachePath $jsonFile
                try { ConvertTo-Json $entry | Out-File $cacheFile -Force } catch {}
            }
        }
        Write-Log "Invoke-VMNetworkBulkWarmup: cached $($global:Common.NetCache.Count) adapters." -LogOnly
    }
    catch {
        Write-Log "Invoke-VMNetworkBulkWarmup: failed: $_" -LogOnly
    }
}

function Test-CacheValid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $EntryTime,
        [Parameter(Mandatory = $true)]
        [int] $MaxHours
    )
    $LastUpdateTime = [Datetime]::ParseExact($EntryTime, 'MM/dd/yyyy HH:mm', $null)
    $datediff = New-TimeSpan -Start $LastUpdateTime -End (Get-Date)
    if ($datediff.TotalHours -lt $MaxHours) {
        return $true
    }
    return $false
}

function Start-VMIPRefreshJob {
    <#
    .SYNOPSIS
        Starts a background ThreadJob that refreshes LastKnownIP for running VMs.
    .DESCRIPTION
        After the speed improvements removed the init-time Update-VMInformation
        loop, LastKnownIP is never refreshed. This function starts a lightweight
        background ThreadJob (PS7 only, in-process) that:
          1. Enumerates running VMs via Get-VM
          2. Calls Get-VMNetworkAdapter to obtain IPv4 addresses
          3. Updates the .network.json cache files with the IP
          4. Updates the in-memory $global:vm_List entries
          5. Persists changes to Hyper-V VM Notes via Set-VMNote
        The job runs at low priority and throttles itself so it doesn't
        contend with vmms.exe during interactive use.
    #>
    if ($global:Common.InJob) { return }
    if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Write-Log "Start-VMIPRefreshJob: Start-ThreadJob not available; skipping." -LogOnly
        return
    }

    # ThreadJobs run in a separate runspace — $global: variables and custom
    # functions (Write-Log, Set-VMNote, Get-VM2, etc.) are NOT available.
    # Only built-in / module cmdlets (Get-VM, Get-VMNetworkAdapter) work.
    # Pass the cache path via $using: so the job can write .network.json files.
    $cachePath = $global:Common.CachePath

    $global:VMIPRefreshJob = Start-ThreadJob -Name "MemLabs-IPRefresh" -ScriptBlock {
        $cPath = $using:cachePath
        try {
            # Brief delay to let the host settle after init
            Start-Sleep -Seconds 5

            $virtualMachines = Get-VM | Where-Object { $_.State -eq 'Running' }

            foreach ($vm in $virtualMachines) {
                try {
                    $vmNoteObject = $null
                    if ($vm.Notes) {
                        $vmNoteObject = $vm.Notes | ConvertFrom-Json -ErrorAction Stop
                    }
                    if (-not $vmNoteObject -or [string]::IsNullOrWhiteSpace($vmNoteObject.role)) {
                        continue  # Not a MemLabs VM
                    }

                    $netAdapter = $vm | Get-VMNetworkAdapter
                    $ipAddress = $netAdapter.IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1

                    if ([string]::IsNullOrWhiteSpace($ipAddress)) { continue }

                    # Update .network.json cache file with IP
                    $jsonFile = $vm.vmID.ToString() + ".network.json"
                    $cacheFile = Join-Path $cPath $jsonFile
                    $cacheEntry = [PSCustomObject]@{
                        vmId       = $vm.vmID
                        SwitchName = $netAdapter.SwitchName
                        IPAddress  = $ipAddress
                        EntryAdded = (Get-Date -Format "MM/dd/yyyy HH:mm")
                    }
                    ConvertTo-Json $cacheEntry | Out-File $cacheFile -Force

                    # Persist to VM Notes if IP changed
                    if ($ipAddress -ne $vmNoteObject.LastKnownIP) {
                        if ($null -eq $vmNoteObject.LastKnownIP) {
                            $vmNoteObject | Add-Member -MemberType NoteProperty -Name "LastKnownIP" -Value $ipAddress -Force
                        }
                        else {
                            $vmNoteObject.LastKnownIP = $ipAddress
                        }
                        $vmNoteObject | Add-Member -MemberType NoteProperty -Name "lastUpdate" -Value (Get-Date -Format "MM/dd/yyyy HH:mm") -Force
                        $noteJson = ($vmNoteObject | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
                        $vm | Set-VM -Notes $noteJson -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    # Best-effort per VM; continue with next
                }
            }
        }
        catch {
            # Fatal error; job ends quietly
        }
    }
    Write-Log "Start-VMIPRefreshJob: Background IP refresh job started." -LogOnly
}

function Update-VMInformation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm
    )

    try {
        if ($vm.Notes) {
            $vmNoteObject = $vm.Notes | convertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Could not convert notes $($vm.Notes) from vm $($vm.Name)" -LogOnly -Failure
        return
    }

    $vmname = $vm.Name
    Write-Log -Verbose -HostOnly "Updating $vmname"
    # Update LastKnownIP, and timestamp
    if (-not [string]::IsNullOrWhiteSpace($vmNoteObject)) {
        $LastUpdateTime = [Datetime]::ParseExact($vmNoteObject.LastUpdate, 'MM/dd/yyyy HH:mm', $null)
        $datediff = New-TimeSpan -Start $LastUpdateTime -End (Get-Date)
        # Skip the expensive Get-VMNetworkAdapter call when the VM isn't Running — a stopped
        # VM will never report an IP, and this call dominates init time when many VMs are off
        # (and is the source of the "sometimes fast / sometimes slow" variability).
        $vmIsRunning = ($vm.State -eq 'Running')
        if ($vmIsRunning -and (($datediff.TotalHours -gt 12) -or $null -eq $vmNoteObject.LastKnownIP)) {
            $IPAddress = ($vm | Get-VMNetworkAdapter).IPAddresses | Where-Object { $_ -notlike "*:*" } | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($IPAddress) -and $IPAddress -ne $vmNoteObject.LastKnownIP) {
                if ($null -eq $vmNoteObject.LastKnownIP) {
                    $vmNoteObject | Add-Member -MemberType NoteProperty -Name "LastKnownIP" -Value $IPAddress -force
                }
                else {
                    $vmNoteObject.LastKnownIP = $IPAddress
                }
                Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
            }
            else {
                #Update the Notes LastUpdateTime everytime we scan for it
                if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
                    Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
                }
            }
        }

        $vmDomain = $vmNoteObject.domain
        # Detect if we need to update VM VMName, if VM Note doesn't have vmName prop

        if (-not $vmNoteObject.vmName) {
            $vmNoteObject | Add-Member -MemberType NoteProperty -Name "vmName" -Value $vm.Name -force
            Set-VMNote -vmName $vm.Name -vmNote $vmNoteObject
        }

        # Detect if we need to update VM Note, if VM Note doesn't have siteCode prop
        if ($vmNoteObject.role -in "CAS", "Primary", "PassiveSite") {
            if ($null -eq $vmNoteObject.siteCode -or $vmNoteObject.siteCode.ToString().Length -ne 3) {
                if ($Common.InJob) {
                    Write-Log "Site code for $vmName is missing in VM Note; skipping PSDirect lookup (background job)." -LogOnly
                }
                elseif ($vmState -eq "Running" -and (-not $inProgress)) {
                    try {
                        $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\Identification -Name "Site Code" } -SuppressLog
                        $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        $vmNoteObject | Add-Member -MemberType NoteProperty -Name "siteCode" -Value $siteCode.ToString() -Force
                        Write-Log "Site code for $vmName is missing in VM Note. Adding siteCode $siteCode." -LogOnly
                        Set-VMNote -vmName $vmName -vmNote $vmNoteObject
                    }
                    catch {
                        Write-Log "Failed to obtain siteCode from registry from $vmName" -Warning -LogOnly
                        Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    }
                }
                else {
                    Write-Log "Site code for $vmName is missing in VM Note, but VM is not running [$vmState] or deployment is in progress [$inProgress]." -LogOnly
                }
            }
        }

        # Detect if we need to update VM Note, if VM Note doesn't have siteCode prop
        if ($vmNoteObject.installDP -or $vmNoteObject.enablePullDP) {
            if ($vmNoteObject.role -eq "DPMP") {
                # Rename Role to SiteSystem
                $vmNoteObject.role = "SiteSystem"
                Set-VMNote -vmName $vmName -vmNote $vmNoteObject
            }

            if ($null -eq $vmNoteObject.siteCode -or $vmNoteObject.siteCode.ToString().Length -ne 3) {
                if ($Common.InJob) {
                    Write-Log "Site code for $vmName (DP/MP) is missing in VM Note; skipping PSDirect lookup (background job)." -LogOnly
                }
                elseif ($vmState -eq "Running" -and (-not $inProgress)) {
                    try {
                        $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\DP -Name "Site Code" } -SuppressLog
                        $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        if (-not $siteCode) {
                            $siteCodeFromVM = Invoke-VmCommand -VmName $vmName -VmDomainName $vmDomain -ScriptBlock { Get-ItemPropertyValue -Path HKLM:\SOFTWARE\Microsoft\SMS\Identification -Name "Site Code" } -SuppressLog
                            $siteCode = $siteCodeFromVM.ScriptBlockOutput
                        }
                        if ($siteCode) {
                            $vmNoteObject | Add-Member -MemberType NoteProperty -Name "siteCode" -Value $siteCode.ToString() -Force
                            Write-Log "Site code for $vmName is missing in VM Note. Adding siteCode $siteCode after reading from registry." -LogOnly
                            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
                        }
                    }
                    catch {
                        Write-Log "Failed to obtain siteCode from registry from $vmName" -Warning -LogOnly
                        Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    }
                }
                else {
                    Write-Log "Site code for $vmName is missing in VM Note, but VM is not running [$vmState] or deployment is in progress [$inProgress]." -LogOnly
                }
            }
        }

        # Rename WSUS role to SiteSystem, if SUP
        if ($vmNoteObject.role -eq "WSUS" -and $vmNoteObject.installSUP -eq $true) {
            $vmNoteObject.role = "SiteSystem"
            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
        }

        # Remove installSUP prop if WSUS role, but not SUP
        if ($vmNoteObject.role -eq "WSUS" -and ($null -eq $vmNoteObject.installSUP -or $vmNoteObject.installSUP -eq $false)) {
            $vmNoteObject.PsObject.properties.Remove('installSUP')
            Set-VMNote -vmName $vmName -vmNote $vmNoteObject
        }
    }
}

function Get-VMFromHyperV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm
    )

    #$diskSize = (Get-VHD -VMId $vm.ID | Measure-Object -Sum FileSize).Sum
    if (-not $common.InJob) {
        $sizeCache = Get-VMSizeCached -vm $vm
        $diskSizeGB = $sizeCache.diskSize / 1GB
        $memoryStartupGB = $sizeCache.MemoryStartup / 1GB
    }       

    if (-not $memoryStartupGB) {
        $memoryStartupGB = 0
    }

    if (-not $diskSizeGB) {
        $diskSizeGB = 0
    }

    $memoryGB = $vm.MemoryAssigned / 1GB

    if (-not $memoryGB) {
        $memoryGB = 0
    }
    $vmNet = Get-VMNetworkCached -vm $vm

    #VmState is now updated  in Update-VMFromHyperV
    #$vmState = $vm.State.ToString()

    $vmObject = [PSCustomObject]@{
        vmName          = $vm.Name
        vmId            = $vm.Id
        switch          = $vmNet.SwitchName
        memoryGB        = $memoryGB
        memoryStartupGB = $memoryStartupGB
        diskUsedGB      = [math]::Round($diskSizeGB, 2)
    }

    # If the network cache has a cached IP (written by the background IP refresh
    # job), seed LastKnownIP so it's available before VM Notes are parsed.
    if ($vmNet.IPAddress) {
        $vmObject | Add-Member -MemberType NoteProperty -Name "LastKnownIP" -Value $vmNet.IPAddress -Force
    }

    Update-VMFromHyperV -vm $vm -vmObject $vmObject -vmNoteObject $vmNoteObject
    if ($vmObject.Domain) {
        #If we don't have a domain, its not one of ours.
        return $vmObject
    }
    return $null
}

function Update-VMFromHyperV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $vm,
        [Parameter(Mandatory = $false)]
        [object] $vmObject,
        [Parameter(Mandatory = $false)]
        [object] $vmNoteObject
    )

    if (-not $vmNoteObject) {
        try {
            if ($vm.Notes) {
                $vmNoteObject = $vm.Notes | convertFrom-Json -ErrorAction Stop
                #write-log -verbose $vmNoteObject
            }
        }
        catch {
            Write-Log -LogOnly -Failure "Could not convert Notes Object on $($vm.Name) $vmNoteObject"
        }
    }

    if ($vmNoteObject) {
        if ([String]::IsNullOrWhiteSpace($vmNoteObject.role)) {
            # If we don't have a vmName property, this is not one of our VM's
            $vmNoteObject = $null
        }
    }
    if (-not $vmObject) {
        $vmObject = $global:vm_List | Where-Object { $_.vmId -eq $vm.vmID }
    }
    if ($vmNoteObject) {
        $vmState = $vm.State.ToString()
        $adminUser = $vmNoteObject.adminName
        $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }

        $vmObject | Add-Member -MemberType NoteProperty -Name "adminName" -Value $adminUser -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "inProgress" -Value $inProgress -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "state" -Value $vmState -Force
        $vmObject | Add-Member -MemberType NoteProperty -Name "vmBuild" -Value $true -Force

        foreach ($prop in $vmNoteObject.PSObject.Properties) {
            $value = if ($prop.Value -is [string]) { $prop.Value.Trim() } else { $prop.Value }
            switch ($prop.Name) {
                "deployedOS" {
                    $vmObject | Add-Member -MemberType NoteProperty -Name "OperatingSystem" -Value $value -Force
                    $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
                }
                "sqlInstanceName" {
                    if (-not $vmObject.sqlPort) {
                        if ($vmObject.sqlInstanceName -eq "MSSQLSERVER") {
                            $vmObject | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 1433 -Force
                        }
                        else {
                            $vmObject | Add-Member -MemberType NoteProperty -Name "sqlPort" -Value 2433 -Force
                        }
                    }
                }
                default {
                    
                    switch ($value) {
                        "True" {
                            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $true -Force
                            continue
                        }
                        "False" {
                            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $false -Force
                            continue
                        }
                        { $PSItem -like "*GB" -or $PSItem -like "*MB" -or $PSItem -like "*.*" } {
                            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
                            continue
                        }
                        { $PSItem -as [int] -is [int] } {
                            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value ([int]$value) -Force
                            continue
                        }
                        default {
                            $vmObject | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $value -Force
                        }

                        
                    }
                   
                }
            }
        }
    }
    else {
        $vmObject | Add-Member -MemberType NoteProperty -Name "vmBuild" -Value $false -Force
    }

    if ($vmObject.Role -eq "DPMP") {
        $vmObject.Role = "SiteSystem"
    }

    if (-not $vmObject.DynamicMinRam) {
        $vmObject | Add-Member -MemberType NoteProperty -Name "DynamicMinRam" -Value $vmObject.Memory -Force
    }
    #add missing Properties
    $isClientOsSiteSystem = Test-SiteSystemClientOperatingSystem -VirtualMachine $vmObject
    if ($vmObject.Role -in "SiteSystem", "CAS", "Primary") {
        if (-not $isClientOsSiteSystem -and $null -eq $vmObject.InstallRP) {
            $vmObject | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
        }
        if (-not $isClientOsSiteSystem -and $null -eq $vmObject.InstallSUP) {
            $vmObject | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $false -Force
        }
        if ($vmObject.Role -eq "SiteSystem") {
            if (-not $isClientOsSiteSystem -and $null -eq $vmObject.InstallMP) {
                $vmObject | Add-Member -MemberType NoteProperty -Name "InstallMP" -Value $false -Force
            }
            if ($null -eq $vmObject.InstallDP) {
                $vmObject | Add-Member -MemberType NoteProperty -Name "InstallDP" -Value $false -Force
            }
            if (-not $isClientOsSiteSystem -and $null -eq $vmObject.InstallSMSProv) {
                $vmObject | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
            }
        }
    }

    if ($vmObject.SqlVersion -and -not $isClientOsSiteSystem) {
        foreach ($listVM in $global:vm_List) {
            if ($listVM.RemoteSQLVM -eq $vmObject.VmName) {
                if ($null -eq $vmObject.InstallRP) {
                    $vmObject | Add-Member -MemberType NoteProperty -Name "InstallRP" -Value $false -Force
                }
                if ($null -eq $vmObject.InstallSMSProv) {
                    $vmObject | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
                }
            }
        }
    }

}

function Save-VMListDiskCache {
    if ($Common.InJob) { return }
    if (-not $global:vm_List -or $global:vm_List.Count -eq 0) { return }
    try {
        $cachePath = Join-Path $Common.CachePath "vm-list-cache.clixml"
        @($global:vm_List) | Export-Clixml -Path $cachePath -Force -Depth 10
        Write-Log "Save-VMListDiskCache: Wrote $($global:vm_List.Count) VMs to disk cache." -LogOnly
    }
    catch {
        Write-Log "Save-VMListDiskCache: Failed to write disk cache. $_" -LogOnly
    }
}

function Read-VMListDiskCache {
    param([int]$MaxAgeMinutes = 10)
    try {
        $cachePath = Join-Path $Common.CachePath "vm-list-cache.clixml"
        if (-not (Test-Path $cachePath)) { return $null }

        $cacheAge = ((Get-Date) - (Get-Item $cachePath).LastWriteTime).TotalMinutes
        if ($cacheAge -gt $MaxAgeMinutes) {
            Write-Log "Read-VMListDiskCache: Disk cache is $([int]$cacheAge) min old (max $MaxAgeMinutes). Skipping." -LogOnly
            return $null
        }

        $cached = @(Import-Clixml -Path $cachePath)
        if ($cached.Count -eq 0) { return $null }

        Write-Log "Read-VMListDiskCache: Loaded $($cached.Count) VMs from disk cache ($([int]$cacheAge) min old)." -LogOnly
        return $cached
    }
    catch {
        Write-Log "Read-VMListDiskCache: Failed to read disk cache. $_" -LogOnly
        return $null
    }
}

$global:vm_List = $null
$global:vm_List_LastUpdate = $null
function Get-List {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "Type")]
        [ValidateSet("VM", "Switch", "Prefix", "UniqueDomain", "UniqueSwitch", "UniquePrefix", "Network", "UniqueNetwork", "ForestTrust")]
        [string] $Type,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [string] $DomainName,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [switch] $ResetCache,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [switch] $SmartUpdate,
        [Parameter(Mandatory = $true, ParameterSetName = "FlushCache")]
        [switch] $FlushCache,
        [Parameter(Mandatory = $false, ParameterSetName = "Type")]
        [object] $DeployConfig
    )

    $doSmartUpdate = $SmartUpdate.IsPresent
    $inMutex = $false
    $return = $null
    #Get-PSCallStack | out-host
    if ($global:DisableSmartUpdate -eq $true) {
        $doSmartUpdate = $false        
    }
    else {        
        $mutexName = "GetList" + $pid
        $mtx = New-Object System.Threading.Mutex($false, $mutexName)
        #write-log "Attempting to acquire '$mutexName' Mutex" -LogOnly -Verbose
        [void]$mtx.WaitOne()
        $inMutex = $true
        #write-log "acquired '$mutexName' Mutex" -LogOnly -Verbose
    }
    try {

        if ($FlushCache.IsPresent) {
            $global:vm_List = $null
            $global:vm_List_LastUpdate = $null
            $global:TestConfigFastCache = $null
            $global:VMStringCache = $null
            # Remove disk cache so stale data is not reloaded
            try {
                $diskCachePath = Join-Path $Common.CachePath "vm-list-cache.clixml"
                if (Test-Path $diskCachePath) { Remove-Item $diskCachePath -Force -ErrorAction SilentlyContinue }
            } catch {}
            return
        }

        if ($DeployConfig) {
            try {
                $DeployConfigJson = $DeployConfig | ConvertTo-Json -Depth 5
                $DeployConfigClone = $DeployConfigJson | ConvertFrom-Json
            }
            catch {
                write-log "Failed to convert DeployConfig: $DeployConfig" -Failure
                write-log "Failed to convert DeployConfig: $DeployConfigJson" -Failure
                Write-Log "$($_.ScriptStackTrace)" -LogOnly
            }

        }
        if ($ResetCache.IsPresent) {
            $global:vm_List = $null
            $global:vm_List_LastUpdate = $null
        }

        # Seed from disk cache if in-memory list is empty. This lets job
        # workers (Start-Job) skip the expensive Get-VM + Get-VMFromHyperV
        # full-build loop. The subsequent SmartUpdate block will do a
        # lightweight Get-VM + Update-VMFromHyperV refresh to pick up
        # current State values.
        if (-not $global:vm_List) {
            $diskCached = Read-VMListDiskCache
            if ($diskCached) {
                # The disk cache persists across PowerShell restarts and is
                # trusted for up to MaxAgeMinutes. A VM deleted out-of-band
                # (e.g. removed in Hyper-V, or a partial Remove-Lab) since the
                # cache was written would otherwise be RESURRECTED as a ghost
                # VM on the very first plain Get-List of a fresh process --
                # before any -SmartUpdate pass reconciles. So reconcile the
                # seed against live Hyper-V right here (interactive host only;
                # job workers seed cheaply and target a specific VM by name).
                if (-not $Common.InJob) {
                    try {
                        $liveVms = Get-VM -ErrorAction Stop
                        $beforeCount = @($diskCached).Count
                        $diskCached = @($diskCached | Where-Object { $liveVms.vmId -contains $_.vmID })
                        $droppedCount = $beforeCount - $diskCached.Count
                        if ($droppedCount -gt 0) {
                            Write-Log "Get-List: dropped $droppedCount stale VM(s) from disk-cache seed (no longer in Hyper-V); rewriting cache." -LogOnly
                        }
                    }
                    catch {
                        Write-Log "Get-List: disk-cache seed reconcile (Get-VM) failed; using seed as-is. $_" -LogOnly
                        $droppedCount = 0
                    }
                }
                else {
                    $droppedCount = 0
                }

                if ($diskCached -and $diskCached.Count -gt 0) {
                    $global:vm_List = $diskCached
                    # Persist the reconciled list so the next plain
                    # (non-SmartUpdate) Get-List in this process doesn't
                    # re-read the stale file.
                    if ($droppedCount -gt 0) { Save-VMListDiskCache }
                    # Leave vm_List_LastUpdate null so SmartUpdate forces a
                    # refresh pass (cheap: just Get-VM + Update-VMFromHyperV).
                }
                # If reconcile emptied the seed entirely, leave $global:vm_List
                # null so the full rebuild-from-Hyper-V path below runs.
            }
        }

        if ($doSmartUpdate) {
            if ($global:vm_List) {
                # Throttle: skip the expensive Get-VM WMI call if the cache
                # was refreshed less than 3 seconds ago. Rapid-fire menu
                # navigation calls get-list -SmartUpdate multiple times in
                # the same user action; the VM state won't change that fast.
                if ($global:vm_List_LastUpdate -and -not $global:vm_List_Dirty -and ((Get-Date) - $global:vm_List_LastUpdate).TotalSeconds -lt 3) {
                    # Skip refresh, use cached data as-is.
                }
                else {
                # When dirty, update ALL VMs regardless of DomainName filter.
                # The domain filter is an optimization for normal refreshes but
                # breaks cross-domain updates: the first Get-DomainStatsLine
                # call refreshes only its domain's VMs, leaving other domains
                # stale in the cache for the 3-second throttle window.
                $filterByDomain = $DomainName -and -not $global:vm_List_Dirty
                try {
                    try {
                        $virtualMachines = Get-VM
                    }
                    catch {
                        start-sleep -seconds 3
                        $virtualMachines = Get-VM
                    }
                    foreach ( $oldListVM in $global:vm_List) {
                        if ($filterByDomain) {
                            if ($oldListVM.domain -ne $DomainName) {
                                continue
                            }
                        }
                        #Remove Missing VM's
                        if (-not ($virtualMachines.vmId -contains $oldListVM.vmID)) {
                            #write-host "removing $($oldListVM.vmID)"
                            $global:vm_List = $global:vm_List | Where-Object { $_.vmID -ne $oldListVM.vmID }
                        }
                    }
                    foreach ($vm in $virtualMachines) {
                        #if its missing, do a full add
                        $vmFromGlobal = $global:vm_List | Where-Object { $_.vmId -eq $vm.vmID }
                        if ($null -eq $vmFromGlobal) {
                            #    if (-not $global:vm_List.vmID -contains $vmID){
                            #write-host "adding missing vm $($vm.vmName)"
                            $vmObject = Get-VMFromHyperV -vm $vm
                            if ($vmObject) {
                                $global:vm_List += $vmObject
                            }
                        }
                        else {
                            if ($filterByDomain) {
                                if ($vmFromGlobal.domain -ne $DomainName) {
                                    continue
                                }
                            }
                            #else, update the existing entry.
                            Update-VMFromHyperV -vm $vm -vmObject $vmFromGlobal
                        }
                    }
                }
                finally {
                }
                $global:vm_List_LastUpdate = Get-Date
                $global:vm_List_Dirty = $false
                Save-VMListDiskCache
                } # else (throttle)
            }
        }

        if (-not $global:vm_List -and $inMutex) {

            try {
                #This may have been populated while waiting for mutex
                if (-not $global:vm_List) {
                    Write-Log "Obtaining '$Type' list and caching it." -Verbose
                    $return = @()
                    Write-Log "Get-List: calling Get-VM to enumerate all virtual machines..." -LogOnly
                    Flush-LogBuffer -All
                    # Bulk-fetch network adapters in one WMI call before iterating VMs
                    Invoke-VMNetworkBulkWarmup
                    try {
                        $virtualMachines = Get-VM
                    }
                    catch {
                        # vmms can transiently throw "object was not found" right
                        # after the service starts (VM store not yet warm). Retry
                        # once after a short settle rather than failing the build.
                        Write-Log "Get-List: Get-VM threw ($($_.Exception.Message)); retrying after 3s..." -LogOnly
                        Start-Sleep -Seconds 3
                        $virtualMachines = Get-VM
                    }
                    Write-Log "Get-List: Get-VM returned $($virtualMachines.Count) VMs. Building cache..." -LogOnly
                    Flush-LogBuffer -All
                    $vmIndex = 0
                    foreach ($vm in $virtualMachines) {
                        $vmIndex++
                        $vmObject = Get-VMFromHyperV -vm $vm
                        if ($vmObject) {
                            $return += $vmObject
                        }
                    }

                    $global:vm_List = $return
                    $global:vm_List_LastUpdate = Get-Date
                    Save-VMListDiskCache
                }
            }
            finally {

            }

        }
        $return = $global:vm_List

        foreach ($vm in $return) {
            $vm | Add-Member -MemberType NoteProperty -Name "source" -Value "hyperv" -Force
        }
        if ($null -ne $DeployConfigClone) {

            $domain = $DeployConfigClone.vmoptions.domainName
            $network = $DeployConfigClone.vmoptions.network

            $prefix = $DeployConfigClone.vmoptions.prefix
            foreach ($vm in $DeployConfigClone.virtualMachines) {
                $found = $false
                if ($vm.hidden) {
                    continue
                }
                if ($vm.network) {
                    $network = $vm.network
                }
                else {
                    $network = $DeployConfigClone.vmoptions.network
                }
                foreach ($vm2 in $return) {
                    if ($vm2.vmName -eq $vm.vmName) {
                        $vm2.source = "config"
                        $found = $true
                    }
                }
                if ($found) {
                    $return = $return | where-object { $_.vmName -ne $vm.vmName }
                }
                $newVM = $vm
                $newVM | Add-Member -MemberType NoteProperty -Name "network" -Value $network -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "Domain" -Value $domain -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "prefix" -Value $prefix -Force
                $newVM | Add-Member -MemberType NoteProperty -Name "source" -Value "config" -Force
                $return += $newVM
            }
        }
        if ($DomainName) {
            $return = $return | Where-Object { $_.domain -and ($_.domain.ToLowerInvariant() -eq $DomainName.ToLowerInvariant()) }
        }

        $return = $return | Sort-Object -Property * #-Unique

        if ($Type -eq "VM") {
            return $return
        }

        # Include Internet subnets, filtering them out as-needed in Common.Remove
        if ($Type -eq "Switch") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property 'Switch', Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "Network") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Network, Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "Prefix") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -Property Prefix, Domain | Sort-Object -Property * -Unique
        }
        if ($Type -eq "UniqueDomain") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Domain -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "ForestTrust") {

            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Where-Object { $_.ForestTrust -ne "NONE" -and $_.ForestTrust } | Select-Object -Property @("ForestTrust", "Domain") -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniqueSwitch") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty 'Switch' -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniqueNetwork") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Network -Unique -ErrorAction SilentlyContinue
        }
        if ($Type -eq "UniquePrefix") {
            return $return | where-object { -not [String]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Prefix -Unique -ErrorAction SilentlyContinue
        }

    }
    catch {
        Write-Log "Failed to get '$Type' list. $_" -Failure -LogOnly
        write-Log "Trace $($_.ScriptStackTrace)" -Failure -LogOnly
        return $null
    }
    finally {
        if ($mtx) {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
            $mtx = $null
        }
    }
}

function Get-List2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "List")]
        [object] $DeployConfig,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $AllDomains,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $ResetCache,
        [Parameter(Mandatory = $false, ParameterSetName = "List")]
        [switch] $SmartUpdate,
        [Parameter(Mandatory = $true, ParameterSetName = "FlushCache")]
        [switch] $FlushCache
    )

    if ($FlushCache.IsPresent) {
        Get-List -FlushCache
        return
    }

    $return = @()

    if ($AllDomains.IsPresent) {
        $return = Get-List -Type VM -DeployConfig $DeployConfig -ResetCache:$ResetCache -SmartUpdate:$SmartUpdate
    }
    else {
        $return = Get-List -Type VM -DomainName $DeployConfig.vmOptions.domainName -DeployConfig $DeployConfig -ResetCache:$ResetCache -SmartUpdate:$SmartUpdate
    }

    return ($return | Sort-Object -Property source)
}

function Test-InProgress {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $DeployConfig
    )

    $InProgressVMs = @()
    foreach ($thisVM in $deployConfig.virtualMachines) {
        $thisVMObject = Get-VMFromList2 -deployConfig $deployConfig -vmName $thisVM.vmName
        if ($thisVMObject.inProgress -eq $true) {
            $InProgressVMs += $thisVMObject.vmName
        }
    }

    if ($InProgressVMs.Count -gt 0) {
        Write-Host
        write-host2 -ForegroundColor Blue "*************************************************************************************************************************************"
        write-host2 -ForegroundColor Red "ERROR: Virtual Machines: [ $($InProgressVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE."
        write-log "ERROR: Virtual Machines: [ $($InProgressVMs -join ",") ] ARE CURRENTLY IN A PENDING STATE." -LogOnly
        write-host
        write-host2 -ForegroundColor Snow "The Previous deployment may be in progress, or may have failed. Please wait for existing deployments to finish, or delete these in-progress VMs"
        write-host2 -ForegroundColor Blue "*************************************************************************************************************************************"
        return $true
    }

    return $false

}

Function Write-ColorizedBrackets {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [string] $BracketColor = $Global:Common.Colors.GenConfigBrackets
    )
    # If the caller has embedded ANSI color sequences (ESC '[' ... 'm') in the text,
    # the bracket-splitting loop below would slice through the CSI prefix on '[' and
    # corrupt it (the ESC byte ends up alone, and the rest prints as literal text).
    # In that case, write the text as-is and let the embedded colors render.
    if ($text -and $text.Contains([char]27)) {
        Write-Host $text -NoNewline
        return
    }
    while (-not [string]::IsNullOrWhiteSpace($text)) {
        #write-host $text
        $indexLeft = $text.IndexOf('[')
        $indexRight = $text.IndexOf(']')
        if ($indexRight -eq -1 -and $indexLeft -eq -1) {
            Write-Host2 -ForegroundColor $ForegroundColor "$text" -NoNewline
            break
        }
        else {

            if ($indexRight -eq -1) {
                $indexRight = 100000000
            }
            if ($indexLeft -eq -1) {
                $indexLeft = 10000000
            }

            if ($indexRight -lt $indexLeft) {
                $text2Display = $text.Substring(0, $indexRight)
                Write-Host2 -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                Write-Host2 -ForegroundColor $BracketColor "]" -NoNewline
                $text = $text.Substring($indexRight)
                $text = $text.Substring(1)
            }
            if ($indexLeft -lt $indexRight) {
                $text2Display = $text.Substring(0, $indexLeft)
                Write-Host2 -ForegroundColor $ForegroundColor "$text2Display" -NoNewline
                Write-Host2 -ForegroundColor $BracketColor "[" -NoNewline
                $text = $text.Substring($indexLeft)
                $text = $text.Substring(1)
            }
        }

    }
}
Function Write-GreenCheck {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [int] $indent = 2
    )        
    $CHECKMARK = ([char]8730)
    $text = $text.Replace("SUCCESS: ", "")
    if (-not $NoIndent) {
        Write-Host "$(" " * $indent)" -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor LimeGreen "$CHECKMARK" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text

    }
    #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline

    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -LogOnly
    }
}

Function Write-RedX {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [int] $indent = 2
    )
    $text = $text.Replace("ERROR: ", "")
    if (-not $NoIndent) {
        Write-Host "$(" " * $indent)" -NoNewline
    }
        
    Write-Host2 "[" -NoNewLine -ForegroundColor $Global:Common.Colors.GenConfigBrackets
    Write-Host2 -ForeGroundColor Red "x" -NoNewline
    Write-Host2 "] " -NoNewline -ForegroundColor $Global:Common.Colors.GenConfigBrackets
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text

    }
    #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline

    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Failure -LogOnly
    }
}

Function Write-WhiteI {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [int] $indent = 2        
    )
    $text = $text.Replace("Info: ", "")
    if (-not $NoIndent) {
        Write-Host "$(" " * $indent)" -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor White "i" -NoNewline
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Warning -LogOnly
    }
}

Function Write-OrangePoint {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [int] $indent = 2
    )
    $text = $text.Replace("WARNING: ", "")
    if (-not $NoIndent) {
        Write-Host "$(" " * $indent)" -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor Orange "!" -NoNewline
    #Write-Host2 -ForeGroundColor Orange "❗" -NoNewline
    #Write-Host2 -ForeGroundColor Orange "🚩" -NoNewline
    
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Warning -LogOnly
    }
}

Function Write-OrangePoint2 {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $text,
        [Parameter()]
        [switch] $NoNewLine,
        [Parameter()]
        [switch] $NoIndent,
        [Parameter()]
        [switch] $WriteLog,
        [Parameter()]
        [string] $ForegroundColor,
        [Parameter()]
        [int] $indent = 2
    )
    $text = $text.Replace("WARNING: ", "")
    if (-not $NoIndent) {
        Write-Host "$(" " * $indent)" -NoNewline
    }
    Write-Host "[" -NoNewLine
    Write-Host2 -ForeGroundColor Orange "⚠️" -NoNewline
    #Write-Host2 -ForeGroundColor Orange "⚠ " -NoNewline
    #☢️ ⚠️
    #Write-Host2 -ForeGroundColor Orange "❗" -NoNewline
    #Write-Host2 -ForeGroundColor Orange "🚩" -NoNewline
    
    Write-Host "] " -NoNewline
    if ($ForegroundColor) {
        Write-ColorizedBrackets -ForegroundColor $ForegroundColor $text
        #Write-Host -ForegroundColor $ForegroundColor $text -NoNewline
    }
    else {
        Write-Host $text -NoNewline
    }
    if (!$NoNewLine) {
        Write-Host
    }
    if ($WriteLog.IsPresent) {
        Write-Log $text -Warning -LogOnly
    }
}
function Convert-vmNotesToOldFormat {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $vmName
    )

    $newNote = [PSCustomObject]@{}

    $propsToInclude = @("success", "role", "deployedOS", "domain", "adminName", "network", "prefix", "siteCode", "parentSiteCode", "cmInstallDir", "sqlVersion" , "sqlInstanceName", "sqlInstanceDir", "lastupdate" )
    $currentNotes = (Get-vm -VMName $vmName).Notes
    Write-Host "`nOld Notes:`n$currentNotes`n"
    $props = ($currentNotes | Convertfrom-json).psobject.members | Where-Object { $_.Name -in $propsToInclude }
    foreach ($prop in $props) {
        switch ($prop.Name) {
            "operatingSystem" {
                $newNote | Add-Member -MemberType NoteProperty -Name "deployedOS" -Value $prop.Value -Force
            }
            default {
                $newNote | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
            }
        }
    }

    $newJson = ($newNote | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
    Write-Host "`nNew Notes:`n$newJson`n"
    Set-VM -Name $vmName -Notes $newJson

}

Function Show-Summary {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PsCustomObject] $deployConfig
    )

    $fixedConfig = $deployConfig.virtualMachines | Where-Object { -not $_.hidden }
    $existingConfig = $deployConfig.virtualMachines | Where-Object { $_.hidden }
    $DC = $deployConfig.virtualMachines  | Where-Object { $_.role -eq "DC" }

    #$CHECKMARK = ([char]8730)
    $containsPS = $fixedConfig.role -contains "Primary"
    $containsSecondary = $fixedConfig.role -contains "Secondary"
    $containsSiteSystem = $fixedConfig.role -contains "SiteSystem"
    $containsMember = $fixedConfig.role -contains "DomainMember"
    $containsPassive = $fixedConfig.role -contains "PassiveSite"

    Write-Verbose "ContainsPS: $containsPS ContainsSiteSystem: $containsSiteSystem ContainsMember: $containsMember ContainsPassive: $containsPassive"
    if ($DC.ForestTrust -and $DC.ForestTrust -ne "NONE") {
        Write-GreenCheck "Forest Trust: This domain will join a Forest Trust with $($DC.ForestTrust)"
        $remoteDC = Get-List -type VM -DomainName $DC.ForestTrust | Where-Object { $_.Role -eq "DC" }
        if ($remoteDC -and $remoteDC.InstallCA) {
            Write-GreenCheck "Forest Trust: This domain be configured to use the Certificate Authority in $($DC.ForestTrust)"
        }

        if ($DC.externalDomainJoinSiteCode) {
            Write-GreenCheck "Forest Trust: Site code $($DC.externalDomainJoinSiteCode) in domain $($DC.ForestTrust) will be configured to manage client machines in this domain"
        }
    }

    if ($null -ne $($deployConfig.cmOptions) -and $deployConfig.cmOptions.install -eq $true) {

        # Enumerate every top-level site server (CAS or standalone Primary, i.e.
        # any CAS/Primary without a parentSiteCode) and report its hierarchy
        # using *that* server's own cmOptions block. Falls back to the deploy-
        # level cmOptions for hierarchies whose top-level VM hasn't received a
        # per-VM block yet (mid-migration shape).
        $topLevels = @($fixedConfig | Where-Object {
                ($_.Role -in 'CAS', 'Primary') -and -not $_.parentSiteCode
            })

        if (-not $topLevels) {
            # Add-to-existing: the top-level CAS/Primary lives in the already-
            # deployed hierarchy. Check hidden existing VMs in the deployConfig
            # first (cheap), then fall back to Get-ExistingSiteServer in the
            # domain (Hyper-V round-trip). Surface a green confirmation rather
            # than a misleading red X.
            $existingTop = @($existingConfig | Where-Object {
                    ($_.Role -in 'CAS', 'Primary') -and -not $_.parentSiteCode
                }) | Select-Object -First 1
            if (-not $existingTop -and $deployConfig.vmOptions.domainName) {
                $existingTop = @(Get-ExistingSiteServer -DomainName $deployConfig.vmOptions.domainName -Role 'CAS') +
                               @(Get-ExistingSiteServer -DomainName $deployConfig.vmOptions.domainName -Role 'Primary') |
                    Where-Object { $_ -and -not $_.ParentSiteCode } |
                    Select-Object -First 1
            }
            if ($existingTop) {
                $topName = if ($existingTop.VMName) { $existingTop.VMName } else { $existingTop.vmName }
                $topSite = if ($existingTop.SiteCode) { $existingTop.SiteCode } else { $existingTop.siteCode }
                Write-GreenCheck "ConfigMgr will be added to existing hierarchy (top-level: $topName [$topSite])"
            } else {
                Write-RedX "ConfigMgr will not be installed (no top-level site server in config or existing deployment)"
            }
        }

        foreach ($top in $topLevels) {
            $cmo = if ($top.cmOptions) { $top.cmOptions } else { $deployConfig.cmOptions }
            if (-not $cmo -or -not $cmo.install) {
                Write-RedX "$($top.VMName) [$($top.SiteCode)]: ConfigMgr install disabled (cmOptions.install=false)"
                continue
            }

            $hierarchyLabel = if ($top.Role -eq 'CAS') { "CAS hierarchy" } else { "Standalone Primary" }
            $baselineVersion = (Get-CMBaselineVersion -CMVersion $cmo.version).baselineVersion

            # Version line per top-level site server.
            if ($cmo.OfflineSCP -and $baselineVersion -ne $cmo.version) {
                Write-RedX "$($top.VMName) [$($top.SiteCode)] ($hierarchyLabel): ConfigMgr $($cmo.version) selected, but Offline SCP forces baseline $baselineVersion"
            }
            elseif ($baselineVersion -ne $cmo.version) {
                Write-OrangePoint "$($top.VMName) [$($top.SiteCode)] ($hierarchyLabel): ConfigMgr $baselineVersion will be installed and upgraded to $($cmo.version)"
            }
            else {
                Write-GreenCheck "$($top.VMName) [$($top.SiteCode)] ($hierarchyLabel): ConfigMgr $($cmo.version) will be installed"
            }

            # Per-hierarchy CM options. Sub-items are indented (bracket and text)
            # so they read as children of the top-level site-server line above.
            $subIndent = 6
            if ($cmo.PrePopulateObjects) {
                Write-GreenCheck -indent $subIndent "Scripts/apps/task sequences will be pre-populated"
            }
            else {
                Write-OrangePoint -indent $subIndent "Scripts/apps/task sequences will NOT be pre-populated"
            }

            if ($cmo.usePKI) {
                Write-GreenCheck -indent $subIndent "PKI: HTTPS enforced (MP/DP/SUP/RP)"
            }
            else {
                Write-OrangePoint -indent $subIndent "PKI: HTTP/EHTTP will be used for all communication"
            }

            if ($cmo.OfflineSCP) {
                Write-OrangePoint -indent $subIndent "SCP: Will be installed in OFFLINE mode"
            }
            if ($cmo.OfflineSUP) {
                Write-OrangePoint -indent $subIndent "SUP: Will be installed in OFFLINE mode for the top-level site"
            }
            if ($cmo.EnableBLM) {
                Write-GreenCheck -indent $subIndent "BitLocker Management enabled"
            }

            # Hierarchy children: child Primaries (CAS only), their Secondaries,
            # Passive site servers, and per-Primary client push.
            $childPrimaries = @()
            if ($top.Role -eq 'CAS') {
                $childPrimaries = @($fixedConfig | Where-Object {
                        $_.Role -eq 'Primary' -and $_.parentSiteCode -eq $top.SiteCode
                    })
                foreach ($p in $childPrimaries) {
                    Write-GreenCheck -indent $subIndent "Primary $($p.VMName) [$($p.SiteCode)] joins this hierarchy ($($p.SiteCode) -> $($top.SiteCode))"
                }
            }

            # Secondaries reporting to any Primary in this hierarchy.
            $hierarchyPrimaryCodes = @()
            if ($top.Role -eq 'Primary') { $hierarchyPrimaryCodes += $top.SiteCode }
            $hierarchyPrimaryCodes += @($childPrimaries.SiteCode)
            $secondaries = @($fixedConfig | Where-Object {
                    $_.Role -eq 'Secondary' -and $_.parentSiteCode -in $hierarchyPrimaryCodes
                })
            foreach ($s in $secondaries) {
                Write-GreenCheck -indent $subIndent "Secondary $($s.VMName) [$($s.SiteCode)] -> $($s.parentSiteCode)"
            }

            # Passive site servers for any Primary (or CAS) in this hierarchy.
            $hierarchyAllCodes = @($top.SiteCode) + $hierarchyPrimaryCodes | Select-Object -Unique
            $passives = @($fixedConfig | Where-Object {
                    $_.Role -eq 'PassiveSite' -and ($_.SiteCode -in $hierarchyAllCodes)
                })
            if ($passives) {
                foreach ($pv in $passives) {
                    Write-GreenCheck -indent $subIndent "(High Availability) Passive site server $($pv.VMName) for SiteCode $($pv.SiteCode -join ',')"
                }
            }
            else {
                Write-RedX -indent $subIndent "(High Availability) No passive site server in this hierarchy"
            }

            # Client push from every Primary in this hierarchy.
            $pushSources = @()
            if ($top.Role -eq 'Primary') { $pushSources += $top }
            $pushSources += $childPrimaries
            foreach ($cp in $pushSources) {
                if ($cp.thisParams -and $cp.thisParams.ClientPush) {
                    Write-GreenCheck -indent $subIndent "Client Push from $($cp.VMName): [$($cp.thisParams.ClientPush -join ',')]"
                }
                else {
                    Write-OrangePoint -indent $subIndent "Client Push from $($cp.VMName): no eligible clients (pushClient=false on all candidates, or none in network)"
                }
            }
        }

        # Site-system roles (DP/MP/SUP/RP/SMSProv) -- listed globally; the role
        # itself implies the owning hierarchy via the VM's parentSiteCode.
        $testSystem = $fixedConfig | Where-Object { $_.InstallDP -or $_.enablePullDP }
        if ($testSystem) {
            Write-GreenCheck "DP role: $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.InstallMP }
        if ($testSystem) {
            Write-GreenCheck "MP role: $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.installSUP }
        if ($testSystem) {
            Write-GreenCheck "SUP role: $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.installRP }
        if ($testSystem) {
            Write-GreenCheck "RP role: $($testSystem.vmName -Join ",")"
        }

        $testSystem = $fixedConfig | Where-Object { $_.installSMSProv }
        if ($testSystem) {
            Write-GreenCheck "SMS Provider role: $($testSystem.vmName -Join ",")"
        }
    }
    else {
        Write-Verbose "deployConfig.cmOptions.install = $($deployConfig.cmOptions.install)"
        if (($deployConfig.cmOptions.install -eq $true) -and $containsPassive) {
            $PassiveVM = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
        }
        else {
            Write-RedX "ConfigMgr will not be installed"
        }
    }

    #  if (($deployConfig.cmOptions.install -eq $true) -and $containsPassive) {
    #     $PassiveVM = $fixedConfig | Where-Object { $_.Role -eq "PassiveSite" }
    #     Write-GreenCheck "ConfigMgr HA Passive server with Sitecode $($PassiveVM.SiteCode) will be installed"
    # }
    if (-not $null -eq $($deployConfig.vmOptions)) {

        if ($null -eq $deployConfig.parameters.ExistingDCName) {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be created." -NoNewLine
        }
        else {
            Write-GreenCheck "Domain: $($deployConfig.vmOptions.domainName) will be joined." -NoNewLine
        }

        Write-Host " [Default Network $($deployConfig.vmOptions.network)]"
        #Write-GreenCheck "Virtual Machine files will be stored in $($deployConfig.vmOptions.basePath) on host machine"

        $totalMemory = ($fixedConfig.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum).Sum / 1GB
        $runningVMNames = (Get-VM | Where-Object { $_.State -eq "Running" }).Name
        $runningConfigVMs = @($fixedConfig | Where-Object { $_.vmName -in $runningVMNames })
        $alreadyRunningMemory = if ($runningConfigVMs.Count -gt 0) { ($runningConfigVMs.memory | ForEach-Object { $_ / 1 } | Measure-Object -Sum).Sum / 1GB } else { 0 }
        $availableMemory = Get-AvailableMemoryGB -ExcludeVMs $fixedConfig.vmName
        $runningInfo = if ($alreadyRunningMemory -gt 0) { " ($($alreadyRunningMemory)GB already running)" } else { "" }
        $memorySummary = "This configuration will use $($totalMemory)GB$runningInfo out of $($availableMemory)GB deployable RAM on host machine [after 8GB reserve]"
        if ($totalMemory -le $availableMemory) {
            Write-GreenCheck $memorySummary
        }
        else {
            Write-OrangePoint $memorySummary
        }
    }

    if (-not $Common.DevBranch) {
        Write-GreenCheck "Domain Admin account: " -NoNewLine
        Write-Host2 -ForegroundColor DeepPink "$($deployConfig.vmOptions.adminName)" -NoNewline
        Write-Host " Password: " -NoNewLine
        Write-Host2 -ForegroundColor DeepPink "$($Common.LocalAdmin.GetNetworkCredential().Password)"
    }

    # Build row data for the colored deployment summary table.
    $roleColor = @{ "CAS" = "Yellow"; "Primary" = "Yellow"; "DC" = "White"; "SiteSystem" = "Yellow"; "DomainMember" = "Cyan"; "Secondary" = "Yellow"; "PassiveSite" = "Yellow"; "Proxy" = "Green"; "LinuxServer" = "Green" }

    # Build SiteCode-to-color map matching the genconfig VM list colors.
    $CASColors = @("PaleGreen", "YellowGreen", "SeaGreen", "MediumSeaGreen", "SpringGreen", "Lime", "LimeGreen")
    $PRIColors = @("LightSkyBlue", "CornflowerBlue", "SlateBlue", "DeepSkyBlue", "Turquoise", "Cyan", "MediumTurquoise", "Aquamarine", "SteelBlue", "Blue")
    $SECColors = @("SandyBrown", "Chocolate", "Peru", "DarkGoldenRod", "Orange", "RosyBrown", "SaddleBrown", "Tan", "DarkSalmon", "GoldenRod")
    $siteColorMap = @{}
    $casIdx = 0; $priIdx = 0; $secIdx = 0
    foreach ($vm in $fixedConfig) {
        switch ($vm.Role) {
            "CAS"       { if ($vm.SiteCode -and -not $siteColorMap.ContainsKey($vm.SiteCode)) { $siteColorMap[$vm.SiteCode] = $CASColors[$casIdx % $CASColors.Count]; $casIdx++ } }
            "Primary"   { if ($vm.SiteCode -and -not $siteColorMap.ContainsKey($vm.SiteCode)) { $siteColorMap[$vm.SiteCode] = $PRIColors[$priIdx % $PRIColors.Count]; $priIdx++ } }
            "Secondary" { if ($vm.SiteCode -and -not $siteColorMap.ContainsKey($vm.SiteCode)) { $siteColorMap[$vm.SiteCode] = $SECColors[$secIdx % $SECColors.Count]; $secIdx++ } }
        }
    }

    $summaryHeaders = @("VM Name", "Role", "Operating System", "Memory", "Procs", "Site", "Network", "Drives", "Tags", "SQL")
    $summaryRows = @()
    $summaryVmColors = @()
    foreach ($vm in $fixedConfig) {
        $memStr = if (($vm.dynamicMinRam / 1) -lt ($vm.memory / 1) -and ($vm.dynamicMinRam / 1) -ne 0) { "$($vm.dynamicMinRam)-$($vm.memory)" } else { "$($vm.memory)" }
        $siteStr = $vm.siteCode
        if ($vm.ParentSiteCode) { $siteStr += "->$($vm.ParentSiteCode)" }
        $netStr = if ($vm.Network) { $vm.Network } else { $deployConfig.vmOptions.network }
        $vmIsLinux = Test-VmIsLinux -Vm $vm
        $driveStr = ""
        if (-not $vmIsLinux) {
            $diskLetters = @("C") + @($vm.additionalDisks.psobject.Properties.Name | Where-Object { $_ })
            $driveStr = $diskLetters -join ","
        }
        $tags = @()
        if ($vm.InstallCA -or $vm.Role -eq 'StandaloneRootCA') { $tags += "CA" }
        if ($vm.InstallSUP) { $tags += "SUP" }
        if ($vm.InstallRP) { $tags += "RP" }
        if ($vm.InstallMP) { $tags += "MP" }
        if ($vm.InstallSMSProv) { $tags += "PROV" }
        if ($vm.InstallDP) { if ($vm.pullDPSourceDP) { $tags += "Pull DP" } else { $tags += "DP" } }
        if ($vm.useProxy) { $tags += "Proxy" }
        if ($vm.BitLocker) { $tags += "BL" }
        if ($vmIsLinux) {
            if ($vm.enableRDP) { $tags += "RDP" }
            if ($vm.joinDomain) { $tags += "AD" }
        }
        $sqlStr = ""
        if ($null -ne $vm.SqlVersion) { $sqlStr = $vm.SqlVersion }
        elseif ($null -ne $vm.remoteSQLVM) { $sqlStr = "Remote -> $($vm.remoteSQLVM)" }

        # Determine VM name color matching the genconfig VM list menu.
        $vmNameColor = $null
        switch ($vm.Role) {
            { $_ -in "DC", "BDC" } { $vmNameColor = "Tomato" }
            { $_ -in "CAS", "Primary", "Secondary", "PassiveSite", "SiteSystem" } {
                if ($vm.SiteCode -and $siteColorMap.ContainsKey($vm.SiteCode)) { $vmNameColor = $siteColorMap[$vm.SiteCode] }
            }
            "WSUS" {
                if ($vm.SiteCode -and $siteColorMap.ContainsKey($vm.SiteCode)) { $vmNameColor = $siteColorMap[$vm.SiteCode] }
            }
            "SQLAO" {
                $primaryNode = if (-not $vm.OtherNode) { $fixedConfig | Where-Object { $_.OtherNode -eq $vm.vmName } } else { $vm }
                $siteVM = $fixedConfig | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName } | Select-Object -First 1
                if ($siteVM -and $siteVM.SiteCode -and $siteColorMap.ContainsKey($siteVM.SiteCode)) { $vmNameColor = $siteColorMap[$siteVM.SiteCode] }
            }
            "DomainMember" {
                $siteVM = $fixedConfig | Where-Object { $_.RemoteSQLVM -eq $vm.vmName -and $_.role -in ("CAS", "Primary", "Secondary") } | Select-Object -First 1
                if ($siteVM -and $siteVM.SiteCode -and $siteColorMap.ContainsKey($siteVM.SiteCode)) {
                    $vmNameColor = $siteColorMap[$siteVM.SiteCode]
                }
                else {
                    $clientNetwork = if ($vm.Network) { $vm.Network } else { $deployConfig.vmOptions.network }
                    if ($clientNetwork) {
                        $siteServers = $fixedConfig | Where-Object { $_.role -in ("Primary", "Secondary") -and $_.SiteCode }
                        $owningSite = $siteServers | Where-Object { $_.Network -eq $clientNetwork } | Select-Object -First 1
                        if (-not $owningSite) {
                            $secondaryOnNet = $siteServers | Where-Object { $_.role -eq "Secondary" -and $_.Network -eq $clientNetwork } | Select-Object -First 1
                            if ($secondaryOnNet -and $secondaryOnNet.parentSiteCode) {
                                $owningSite = $siteServers | Where-Object { $_.role -eq "Primary" -and $_.SiteCode -eq $secondaryOnNet.parentSiteCode } | Select-Object -First 1
                            }
                        }
                        if ($owningSite -and $siteColorMap.ContainsKey($owningSite.SiteCode)) { $vmNameColor = $siteColorMap[$owningSite.SiteCode] }
                    }
                }
            }
            { $_ -in "Proxy", "LinuxServer" } { $vmNameColor = "Green" }
            "FileServer" { $vmNameColor = "PapayaWhip" }
            "StandaloneRootCA" { $vmNameColor = "PapayaWhip" }
        }
        $summaryVmColors += $vmNameColor

        $summaryRows += , @($vm.vmName, $vm.role, $vm.operatingSystem, $memStr, "$($vm.virtualProcs)", $siteStr, $netStr, $driveStr, ($tags -join ", "), $sqlStr)
    }

    # Auto-size columns.
    $colCount = $summaryHeaders.Count
    $colWidths = @(0) * $colCount
    for ($i = 0; $i -lt $colCount; $i++) {
        $colWidths[$i] = $summaryHeaders[$i].Length
        foreach ($row in $summaryRows) {
            $len = "$($row[$i])".Length
            if ($len -gt $colWidths[$i]) { $colWidths[$i] = $len }
        }
        if ($i -lt $colCount - 1) { $colWidths[$i] += 2 }
    }

    # Render header row.
    Write-Host ""
    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $colCount; $i++) {
        Write-Host ("{0,-$($colWidths[$i])}" -f $summaryHeaders[$i]) -NoNewline -ForegroundColor White -BackgroundColor DarkBlue
    }
    Write-Host ""

    # Render data rows.
    $rowIdx = 0
    foreach ($row in $summaryRows) {
        Write-Host "  " -NoNewline
        for ($i = 0; $i -lt $colCount; $i++) {
            $val = "$($row[$i])"
            $fmt = "{0,-$($colWidths[$i])}"
            if ($i -eq 0 -and $summaryVmColors[$rowIdx]) {
                # VM Name column — colored to match genconfig menu
                Write-Host2 ($fmt -f $val) -NoNewline -ForegroundColor $summaryVmColors[$rowIdx]
            }
            elseif ($i -eq 1) {
                # Role column — colored
                $color = if ($roleColor[$val]) { $roleColor[$val] } else { "PapayaWhip" }
                Write-Host2 ($fmt -f $val) -NoNewline -ForegroundColor $color
            }
            else {
                Write-Host ($fmt -f $val) -NoNewline
            }
        }
        Write-Host ""
        $rowIdx++
    }
    
    $list = Get-List -Type VM
    $existingPrinted = $false
    Foreach ($evm in $existingConfig) {
        $CurrentVM = $list | Where-Object { $_.vmName -eq $evm.vmName }
        $propsToInclude = $common.supported.PropsToUpdate
        if ($CurrentVM) {
            foreach ($prop in $evm.PSObject.Properties) {
                $name = $prop.Name
                if ($name -in $propsToInclude) {
                    if ($evm."$name" -ne $CurrentVM."$name") {
                        if (-not $existingPrinted) {
                            Write-GreenCheck "Changes to the following existing VMs will be performed"
                            $existingPrinted = $true
                        }
                        
                        Write-WhiteI -indent 6 "$($evm.VmName) $name = [$($CurrentVM."$name")] -> [$($evm."$name")]"
                    }
                }
            }
        }
    }
    Write-Host
}