# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
function get-VMOptionsSummary {

    $options = $Global:Config.vmOptions
    if ($null -eq $options.timeZone) {
        $currentTimeZone = (Get-TimeZone).Id
        $options | Add-Member -MemberType NoteProperty -Name "timeZone" -Value $currentTimeZone -Force
    }
    if ($null -eq $options.locale) {
        $options | Add-Member -MemberType NoteProperty -Name "locale" -Value "en-US" -Force
    }

    # Color-coded tokens (Option C: hybrid — labels only where the value is ambiguous)
    #   Prefix [PRO-]   -> LightSteelBlue    (identity bracket — most useful, leftmost)
    #   Domain          -> Gold              (the headline)
    #   Network         -> LightSteelBlue
    #   Admin user      -> Chartreuse
    #   Locale          -> Plum              (least useful, drops first when truncated)
    #   TZ              -> Plum
    #   Path            -> LightSteelBlue    (last — drops first)
    #   Separator       -> DimGray
    $sep = Format-OptionToken -Color "DimGray" -Text "  ·  "

    $tokens = @(
        if ($options.prefix) { Format-OptionToken -Color "LightSteelBlue" -Text "[$($options.prefix)]" }
        Format-OptionToken -Color "Gold" -Text $options.domainName
        Format-OptionToken -Color "LightSteelBlue" -Text $options.network
        Format-OptionToken -Color "Chartreuse" -Text $options.adminName
        (Format-OptionToken -Color "DimGray" -Text "Loc ") + (Format-OptionToken -Color "Plum" -Text $options.locale)
        (Format-OptionToken -Color "DimGray" -Text "TZ ") + (Format-OptionToken -Color "Plum" -Text $options.timeZone)
        Format-OptionToken -Color "LightSteelBlue" -Text $options.basePath
    )
    $Output = $tokens -join $sep

    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 38)
    return (Limit-AnsiString -Text $Output -MaxVisible $MaxWidth)
}

function get-CMOptionsSummary {
    [CmdletBinding()]
    param (
        # Optional: render summary for an arbitrary cmOptions block (e.g. the one
        # attached to a specific site server VM). When omitted, falls back to
        # $Global:Config.cmOptions for legacy callers.
        [Parameter(Mandatory = $false)]
        [object] $CmOptions
    )
    $fixedConfig = $Global:Config.virtualMachines | Where-Object { -not $_.hidden }
    if ($null -eq $CmOptions) {
        $options = $Global:Config.cmOptions
    }
    else {
        $options = $CmOptions
    }
    if ($null -eq $options) { return "" }

    # Version (red if tech-preview, otherwise green). Use baseline number when SCP is Offline.
    $verText = $options.version
    if ($options.OfflineSCP) {
        $baseline = (Get-CMBaselineVersion -CMVersion $options.version).baselineVersion
        if ($baseline) { $verText = $baseline }
    }
    $verColor = if ($options.version -eq "tech-preview") { "Tomato" } else { "ForestGreen" }

    # License: green if Licensed, red if EVAL
    $isEval = ($options.EVALVersion -or $options.version -eq "tech-preview")
    $licenseText = if ($isEval) { "EVAL" } else { "Licensed" }
    $licenseColor = if ($isEval) { "Tomato" } else { "ForestGreen" }

    # Install — green ✓ or red ✗
    $installColor = if ($options.install) { "ForestGreen" } else { "Tomato" }
    $installMark = if ($options.install) { "✓" } else { "✗" }

    # Auth — PKI is the more secure choice (green); EHTTP is the default (khaki/yellow)
    $authText = if ($options.UsePKI) { "PKI" } else { "EHTTP" }
    $authColor = if ($options.UsePKI) { "ForestGreen" } else { "Khaki" }

    # SCP — Online cyan, Offline tan
    $scpText = if ($options.OfflineSCP) { "Offline" } else { "Online" }
    $scpColor = if ($options.OfflineSCP) { "Tan" } else { "PaleTurquoise" }

    $sep = Format-OptionToken -Color "DimGray" -Text "  ·  "

    $tokens = @(
        (Format-OptionToken -Color "DimGray" -Text "CM ") + (Format-OptionToken -Color $verColor -Text $verText)
        Format-OptionToken -Color $licenseColor -Text $licenseText
        (Format-OptionToken -Color "DimGray" -Text "Install ") + (Format-OptionToken -Color $installColor -Text $installMark)
        (Format-OptionToken -Color "DimGray" -Text "Auth ") + (Format-OptionToken -Color $authColor -Text $authText)
        (Format-OptionToken -Color "DimGray" -Text "SCP ") + (Format-OptionToken -Color $scpColor -Text $scpText)
    )

    # SUP Offline badge — only shown when a SUP is present AND OfflineSUP is set (non-default)
    $testSystem = $fixedConfig | Where-Object { $_.installSUP }
    if ($testSystem -and $options.OfflineSUP) {
        $tokens += (Format-OptionToken -Color "DimGray" -Text "SUP ") + (Format-OptionToken -Color "Tan" -Text "Offline")
    }

    # BLM badge — always shown so users can tell at a glance whether BitLocker
    # Management is on for this site server (green ✓ when on, tan ✗ when off).
    $blmColor = if ($options.EnableBLM) { "ForestGreen" } else { "Tan" }
    $blmMark = if ($options.EnableBLM) { "✓" } else { "✗" }
    $tokens += (Format-OptionToken -Color "DimGray" -Text "BLM ") + (Format-OptionToken -Color $blmColor -Text $blmMark)

    $Output = $tokens -join $sep

    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 38)
    return (Limit-AnsiString -Text $Output -MaxVisible $MaxWidth)
}

function get-VMSummary {

    $vms = $Global:Config.virtualMachines

    $numVMs = ($vms | Measure-Object).Count
    $numDCs = ($vms | Where-Object { $_.Role -in ("DC", "BDC") } | Measure-Object).Count
    $numDPMP = ($vms | Where-Object { $_.installDP -or $_.enablePullDP } | Measure-Object).Count
    $numPri = ($vms | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
    $numSec = ($vms | Where-Object { $_.Role -eq "Secondary" } | Measure-Object).Count
    $numCas = ($vms | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
    $numMember = ($vms | Where-Object { $_.Role -eq "WorkgroupMember" -or $_.Role -eq "AADClient" -or $_.Role -eq "InternetClient" -or ($_.Role -eq "DomainMember" -and $null -eq $_.SqlVersion) } | Measure-Object).Count
    $numSQL = ($vms | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion } | Measure-Object).Count
    $RoleList = ""
    if ($numDCs -gt 0 ) {
        $RoleList += "[DC]"
    }
    if ($numCas -gt 0 ) {
        $RoleList += "[CAS]"
    }
    if ($numPri -gt 0 ) {
        $RoleList += "[Primary]"
    }
    if ($numSec -gt 0 ) {
        $RoleList += "[Secondary]"
    }
    if ($numDPMP -gt 0 ) {
        $RoleList += "[DPMP]"
    }
    if ($numSQL -gt 0 ) {
        $RoleList += "[$numSQL SQL]"
    }
    if ($numMember -gt 0 ) {
        $RoleList += "[$numMember Member(s)]"
    }
    $num = "[$numVMs VM(s)]".PadRight(21)
    $Output = "$num $RoleList"
    if ($numVMs -lt 4) {
        $Output += " {$(($vms | Select-Object -ExpandProperty vmName) -join ",")}"
    }
    return $Output
}


function Get-SortedProperties {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Property to Sort")]
        [object] $property
    )

    # Single source of truth for the menu render order.
    #   Key   = NoteProperty name as it appears on the object.
    #   Value = label emitted to the caller (some are case-adjusted for display).
    # Properties not present on the object are silently skipped. Properties
    # present but not in this list fall through to the catch-all at the end
    # (unless they're in $hidden).
    $order = [ordered]@{
        'vmName'              = 'vmName'
        'DeploymentType'      = 'DeploymentType'
        'domainName'          = 'DomainName'
        'prefix'              = 'Prefix'
        'network'             = 'Network'
        'DefaultServerOS'     = 'DefaultServerOS'
        'DefaultClientOS'     = 'DefaultClientOS'
        'DefaultSqlVersion'   = 'DefaultSqlVersion'
        'UseDynamicMemory'    = 'UseDynamicMemory'
        'IncludeClients'      = 'IncludeClients'
        # ConfigMgr group (positioned together so New Domain wizard can
        # render a section header above CMVersion).
        'CMVersion'              = 'CMVersion'
        'IncludeSSMSOnNONSQL'    = 'IncludeSSMSOnNONSQL'
        'EnableSUPOnSiteServers' = 'EnableSUPOnSiteServers'
        # Client-push group (section header attaches to PushCMClientToClients).
        'PushCMClientToClients'     = 'PushCMClientToClients'
        'PushCMClientToServers'     = 'PushCMClientToServers'
        'PushCMClientToSiteSystems' = 'PushCMClientToSiteSystems'
        # Proxy Settings group (section header attaches to UseProxyForClients).
        'UseProxyForClients'        = 'UseProxyForClients'
        'UseProxyForCM'             = 'UseProxyForCM'
        'adminName'           = 'AdminName'
        'basePath'            = 'BasePath'
        'domainUser'          = 'DomainUser'
        'role'                = 'Role'
        'memory'              = 'Memory'
        'dynamicMinRam'       = 'DynamicMinRam'
        'virtualProcs'        = 'VirtualProcs'
        'operatingSystem'     = 'OperatingSystem'
        'sqlVersion'          = 'sqlVersion'
        'sqlInstanceName'     = 'sqlInstanceName'
        'sqlInstanceDir'      = 'sqlInstanceDir'
        'sqlPort'             = 'sqlPort'
        'SqlAgentAccount'     = 'SqlAgentAccount'
        'SqlServiceAccount'   = 'SqlServiceAccount'
        'remoteSQLVM'         = 'RemoteSQLVM'
        'cmInstallDir'        = 'cmInstallDir'
        'parentSiteCode'      = 'ParentSiteCode'
        'siteCode'            = 'SiteCode'
        'siteName'            = 'SiteName'
        # Per-VM cmOptions on top-level site servers (post-migration shape).
        # Rendered as a colored summary; selecting it dives into the sub-menu.
        'cmOptions'           = 'cmOptions'
        'remoteContentLibVM'  = 'RemoteContentLibVM'
        'tpmEnabled'          = 'tpmEnabled'
        'BitLocker'           = 'BitLocker'
        'InstallSSMS'         = 'InstallSSMS'
        'installOffice'       = 'InstallOffice'
        'pushClient'          = 'pushClient'
        'additionalDisks'     = 'AdditionalDisks'
        'installDP'           = 'InstallDP'
        'enablePullDP'        = 'EnablePullDP'
        'installMP'           = 'InstallMP'
        'useDatabaseReplica'  = 'useDatabaseReplica'
        'replicaSqlServerVM'  = 'replicaSqlServerVM'
        'replicaDbName'       = 'replicaDbName'
        'installRP'           = 'InstallRP'
        'installSUP'          = 'InstallSUP'
        'installSMSProv'      = 'InstallSMSProv'
        'Version'             = 'Version'
        'Install'             = 'Install'
        'EVALVersion'         = 'EVALVersion'
        'UsePKI'              = 'UsePKI'
        'OfflineSCP'          = 'OfflineSCP'
        'OfflineSUP'          = 'OfflineSUP'
        'WsusImportBaseline'  = 'WsusImportBaseline'
        'PrePopulateObjects'  = 'PrePopulateObjects'
        'EnableBLM'           = 'EnableBLM'
    }

    # Properties that may exist on the object but must never be surfaced in
    # the menu (legacy, internal flags, or rendered elsewhere).
    $hidden = @(
        'installCA'
        'UseOfflineRoot'
        'SubordinateCA'
        '_autoAddedByOfflineRootCA'
        '_autoAddedByProxy'
        'pushClientToDomainMembers'
        'osFamily'
        'replicaSqlAutoAdded'
        'replicaSqlOrigMemory'
        'replicaSqlOrigVirtualProcs'
        'replicaSqlOrigDynamicMinRam'
    )

    $memberNames = @($property | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    $sorted = @()

    foreach ($key in $order.Keys) {
        if ($memberNames -contains $key) {
            $sorted += $order[$key]
        }
    }

    # Catch-all: anything present on the object but not in $order or $hidden
    # gets appended at the end so new properties surface without code changes.
    foreach ($name in $memberNames) {
        if ($order.Contains($name)) { continue }
        if ($hidden -contains $name) { continue }
        $sorted += $name
    }

    return $sorted
}


#$TextToDisplay = Get-AdditionalInformation -item $item -data $TextValue[0]
function Get-AdditionalInformationColor {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Item Name")]
        [string] $item,
        [Parameter(Mandatory = $false, HelpMessage = "Raw value")]
        [string] $data
    )
    switch ($item) {
        "vmName" {
            $color = $Global:Common.Colors.GenConfigVMName
        }
        "Role" {
            $color = $Global:Common.Colors.GenConfigVMRole
        }
        "RemoteSQLVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "replicaSqlServerVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "remoteContentLibVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "OtherNode" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "FileServerVM" {
            $color = $Global:Common.Colors.GenConfigVMRemoteServer
        }
        "SiteCode" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "siteName" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "ParentSiteCode" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "cmInstallDir" {
            $color = $Global:Common.Colors.GenConfigSiteCode
        }
        "SqlVersion" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlInstanceName" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlInstanceDir" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "sqlPort" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlAgentAccount" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }
        "SqlServiceAccount" {
            $color = $Global:Common.Colors.GenConfigSQLProp
        }        

    }
    switch ($value) {
        "True" {
            $color = $Global:Common.Colors.GenConfigTrue
        }
        "False" {
            $color = $Global:Common.Colors.GenConfigFalse
        }
    }
    return $color
}

function Get-AdditionalInformation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Item Name")]
        [string] $item,
        [Parameter(Mandatory = $false, HelpMessage = "Raw value")]
        [string] $data
    )
    #$global:config

    $origData = $data

    # vmOptions.prefix is optional; with a blank prefix the "(full name)" preview
    # would just repeat the value, so it is suppressed below.
    $configPrefix = "$($global:config.vmOptions.Prefix)"

    switch ($item) {

        "RemoteSQLVM" {
            $remoteSQL = $global:config.virtualMachines | Where-Object { $_.vmName -eq $data }
            $name = $($configPrefix + $data)
            if ($remoteSQL) {
                if ($remoteSQL.OtherNode) {
                    $data = $data.PadRight(21) + "($name) [SQL Always On Cluster]"
                }
                elseif ($configPrefix) {
                    $data = $data.PadRight(21) + "($name)"
                }
            }
        }
        "ClusterName" {
            if ($configPrefix) {
                $data = $data.PadRight(21) + "($($configPrefix + $data))"
            }
        }

        "AlwaysOnListenerName" {
            if ($configPrefix) {
                $data = $data.PadRight(21) + "($($configPrefix + $data))"
            }
        }

        "vmName" {
            if ($configPrefix -and -not $data.StartsWith($configPrefix)) {
                $data = $data.PadRight(21) + "($($configPrefix + $data))"
            }
        }

        "prefix" {
            if ([string]::IsNullOrWhiteSpace($data)) {
                $data = "(none) - VM names are used as-is"
            }
        }

        "domainUser" {
            $prefixLower = $configPrefix.ToLower()
            if ($prefixLower -and -not $data.StartsWith($prefixLower)) {
                $data = $data.PadRight(21) + "($($prefixLower + $data))"
            }
        }

        "memory" {
            #add Available memory
        }
        "parentSiteCode" {
            #list serverName/role
        }
        "network" {
            $data = Get-EnhancedSubnetList -SubnetList $data -ConfigToCheck $global:config | Select-Object -First 1
        }
        default { }
    }

    foreach ($err in $global:GenConfigErrorMessages) {
        if ($err.property -eq $item) {
            $data = $origData.PadRight(21) + "[x] " + $err.message
            $global:GenConfigErrorMessages = @($global:GenConfigErrorMessages | where-object { $_.message -ne $err.message })
            break
        }
    }

    return $data
}


function get-VMString {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "config")]
        [object] $config,
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine,
        [switch] $colors

    )

    # Result memoization. get-VMString is called once per VM on every redraw of the
    # Select-MainMenu loop. Inside, it walks Get-List2 (which re-clones the deployConfig
    # via JSON) plus does a second Get-List2 for the color map. With many VMs that's the
    # dominant per-redraw cost. The output is a pure function of the VM, the relevant
    # config bits, the $colors switch, and the console width — cache on a hash of those.
    $vmStringCacheKey = $null
    try {
        $cacheParts = [ordered]@{
            vm     = $virtualMachine
            vms    = $config.virtualMachines
            opts   = $config.vmOptions
            colors = [bool]$colors.IsPresent
            width  = $host.UI.RawUI.WindowSize.Width
        }
        $cacheJson = $cacheParts | ConvertTo-Json -Depth 6 -Compress
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($cacheJson)
            $vmStringCacheKey = [System.BitConverter]::ToString($sha.ComputeHash($bytes))
        }
        finally {
            $sha.Dispose()
        }
        if ($null -eq $global:VMStringCache) {
            $global:VMStringCache = @{}
        }
        if ($global:VMStringCache.ContainsKey($vmStringCacheKey)) {
            return $global:VMStringCache[$vmStringCacheKey]
        }
        # Bound the cache so it can't grow unbounded across long sessions.
        if ($global:VMStringCache.Count -gt 1024) {
            $global:VMStringCache = @{}
        }
    }
    catch {
        $vmStringCacheKey = $null
    }

    $name = $null
    $temp = $null
    $SiteCode = $null
    $modified = get-IsExistingVMModified -virtualMachine $virtualMachine

    # Resolve Get-List2 once and reuse below (color map loop + remoteSQLVM lookup).
    # Get-List2 -DeployConfig clones the config via JSON each call, so collapsing the
    # two call sites is a measurable win when this function is invoked per-VM in a loop.
    $allVMs = get-list2 -deployConfig $config


    if ($virtualMachine.source -eq "hyperv" -or $virtualMachine.vmId) {
        $machineName = $($virtualMachine.vmName).PadRight(19, " ")
    }
    else {
        $machineName = $($($Global:Config.vmOptions.Prefix) + $($virtualMachine.vmName)).PadRight(19, " ")
    }

    $name = "$machineName " + $("[" + $($virtualmachine.role) + "]").PadRight(17, " ")
    if ($virtualMachine.memory) {
        if ($virtualMachine.dynamicMinRam -and ($($virtualMachine.dynamicMinRam) / 1) -lt ($($virtualMachine.memory) / 1)) {
            $mem = $($($virtualMachine.dynamicMinRam) + "-" + $($virtualMachine.memory)).PadLeft(4, " ") 
        }
        else {
            $mem = $($virtualMachine.memory).PadLeft(4, " ")
        }
    }
    else { $mem = "n/a" }
    if ($virtualMachine.virtualProcs) {
        $procs = $($virtualMachine.virtualProcs).ToString().PadLeft(2, " ")
    }
    $Network = $config.vmOptions.Network
    if ($virtualMachine.Network) {
        $Network = $virtualMachine.Network
    }
    $name += " [$network]".PadRight(17, " ")
    if ($modified) {
        $name = $name + "(Modified)"
    }
    $name += " VM [$mem RAM,$procs CPU, $($virtualMachine.OperatingSystem)]"

    # if ($virtualMachine.additionalDisks) {
    #     $name += ", $($virtualMachine.additionalDisks.psobject.Properties.Value.count) Extra Disk(s)]"
    # }
    # else {
    #     $name += "]"
    # }

    if ($virtualMachine.siteCode -and $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.parentSiteCode) {
            $SiteCode += "->$($virtualMachine.parentSiteCode)"
        }
        $name += "  CM  [SiteCode $SiteCode ($($virtualMachine.cmInstallDir))]"
        if ($virtualMachine.installSUP) {
            $name += " [SUP]"
        }
        if ($virtualMachine.installRP) {
            $name += " [RP]"
        }
        if ($virtualMachine.InstallSMSProv) {
            $name += " [PROV]"
        }
        $name = $name.PadRight(39, " ")
    }

    if ($virtualMachine.siteCode -and -not $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.parentSiteCode) {
            $SiteCode += "->$($virtualMachine.parentSiteCode)"
        }
        $temp = "  CM  [SiteCode $SiteCode]"
        if ($virtualMachine.installMP) {
            $temp += " [MP]"
        }
        if ($virtualMachine.installDP -or $virtualMachine.enablePullDP) {
            
            if ($virtualMachine.installDP) {
                if ($virtualMachine.pullDPSourceDP) {
                    $temp += " [Pull DP]"
                }
                else {
                    $temp += " [DP]"
                }
            }
        }
        if ($virtualMachine.installSUP) {
            if (-not ($name.Contains("[SUP]"))) {
                $temp += " [SUP]"
            }
        }
        if ($virtualMachine.installRP) {
            if (-not ($name.Contains("[RP]"))) {
                $temp += " [RP]"
            }
        }
        if ($virtualMachine.InstallSMSProv) {
            if (-not ($name.Contains("[PROV]"))) {
                $temp += " [PROV]"
            }
        }
        $name += $temp.PadRight(39, " ")
    }

    # Clients (DomainMembers) don't own a site code, but when the CM client is
    # pushed to them they report to a site. pushClient carries the authoritative
    # TARGET SITE CODE (Resolve-PushClientSite). Surface it so the details line
    # matches the site-based line color below.
    if (-not $virtualMachine.siteCode -and ($virtualMachine.pushClient -is [string]) -and $virtualMachine.pushClient) {
        $name += "  CM  [Client->$($virtualMachine.pushClient)]"
    }

    if ($virtualMachine.remoteSQLVM) {
        $sqlVM = $allVMs | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        if ($sqlVM.OtherNode) { $name += "  SQL AO [$($sqlVM.vmName),$($sqlVM.OtherNode)]" }
        else { $name += "  Remote SQL [$($virtualMachine.remoteSQLVM)]" }
    }

    # MP database replica: surface the replica SQL server VM the MP reads from
    # (Set-CMManagementPoint -UseSiteDatabase 0), so the summary shows where the
    # MP's database lives instead of leaving the SQL column blank.
    if ($virtualMachine.useDatabaseReplica -and $virtualMachine.replicaSqlServerVM) {
        $name += "  Replica DB [-> $($virtualMachine.replicaSqlServerVM)]"
    }

    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion)]"
    }

    if ($virtualMachine.sqlVersion -and $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion), "
        $name += "$($virtualMachine.sqlInstanceName) ($($virtualMachine.sqlInstanceDir))]"
    }

    if ($virtualMachine.sqlVersion) {
        if ($virtualMachine.installSUP) {
            if (-not ($name.Contains("[SUP]"))) {
                $name += " [SUP]"
            }
        }
        if ($virtualMachine.installRP) {
            if (-not ($name.Contains("[RP]"))) {
                $name += " [RP]"
            }
        }
        if ($virtualMachine.InstallSMSProv) {
            if (-not ($name.Contains("[PROV]"))) {
                $name += " [PROV]"
            }
        }
    }

    if ($virtualMachine.Role -eq 'StandaloneRootCA') {
        $name += " [CA]"
    }
    elseif ($Global:Config.pkiOptions -and $Global:Config.pkiOptions.EnablePKI -and $Global:Config.pkiOptions.IssuingCAVM -eq $virtualMachine.vmName) {
        $name += " [CA]"
    }
    elseif ($virtualMachine.InstallCA) {
        $name += " [CA]"
    }

    if ($virtualMachine.ForestTrust -and $virtualMachine.ForestTrust -ne "NONE") {
        $name += " Trust [$($virtualMachine.ForestTrust)"
        if ($virtualMachine.externalDomainJoinSiteCode) {
            $name += "-->$($virtualMachine.externalDomainJoinSiteCode)"
        }
        $name += "]"
    }
    if (Test-VmIsLinux -Vm $virtualMachine) {
        if ($virtualMachine.enableRDP) { $name += " [RDP]" }
        if ($virtualMachine.joinDomain) { $name += " [AD]" }
    }
    if ($virtualMachine.useProxy) { $name += " [Proxy]" }
    if ($virtualMachine.BitLocker) { $name += " [BL]" }
    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 12)
    # Demoted from -LogOnly: this runs once per VM on every menu redraw and
    # stringifying $virtualMachine is expensive. Promote with -Verbose only
    # when actively diagnosing the label builder.
    write-log "Name is $name for $($virtualMachine.vmName) and max is $MaxWidth" -Verbose

    if ($name.Length -ge $MaxWidth) {
        $name = $name.Substring(0, $MaxWidth - 3) + "..."
    }
  

    $CASColors = @("%PaleGreen", "%YellowGreen", "%SeaGreen", "%MediumSeaGreen", "%SpringGreen", "%Lime", "%LimeGreen")
    $PRIColors = @("%LightSkyBlue", "%CornflowerBlue", "%SlateBlue", "%DeepSkyBlue", "%Turquoise", "%Cyan", "%MediumTurquoise", "%Aquamarine", "%SteelBlue", "%Blue")
    $SECColors = @("%SandyBrown", "%Chocolate", "%Peru", "%DarkGoldenRod", "%Orange", "%RosyBrown", "%SaddleBrown", "%Tan", "%DarkSalmon", "%GoldenRod")


    $ColorMap = New-Object System.Collections.Generic.Dictionary"[String,String]"


    $casCount = 0
    $priCount = 0
    $secCount = 0
    foreach ($vm in $allVMs) {
        switch ($vm.Role) {
            "CAS" {
                try {
                    $ColorMap.Add($vm.SiteCode, $CASColors[$casCount])
                }
                catch {
                    break
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                }
                $casCount++
            }
            "Primary" {
                try {
                    $ColorMap.Add($vm.SiteCode, $PRIColors[$priCount])
                }
                catch {
                    break
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                }
                $priCount++
            }
            "Secondary" {
                try {
                    $ColorMap.Add($vm.SiteCode, $SECColors[$secCount])
                }
                catch {
                    #$ColorMap.Add($vm.SiteCode, "HotPink")
                    break
                }
                $secCount++
            }
        }
    }
    if ($colors) {
        switch ($virtualMachine.Role) {
            "DC" {
                $color = "%Tomato"
            }
            "BDC" {
                $color = "%Tomato"
            }
            "CAS" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "Primary" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]

            }
            "Secondary" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]

            }
            "PassiveSite" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "SiteSystem" {
                $color = $ColorMap[$($virtualMachine.SiteCode)]
            }
            "WSUS" {
                if ($virtualMachine.SiteCode) {
                    try {
                        $color = $ColorMap[$($virtualMachine.SiteCode)]
                    }
                    catch {}
                }
            }
            "SQLAO" {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
                if (-not $virtualMachine.Othernode) {
                    $primaryNode = $allVMs | Where-Object { $_.OtherNode -eq $virtualMachine.vmName }
                }
                else {
                    $primaryNode = $virtualMachine
                }

                $siteVM = $allVMs | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName }
                if ($siteVM) {
                    $color = $ColorMap[$($siteVM.SiteCode)]
                }         

            }
            "DomainMember" {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"

                # pushClient is the authoritative site code this client is pushed
                # from / reports to (Resolve-PushClientSite writes it). Prefer it
                # over the remoteSQL/network heuristics so the line color matches
                # the owning site exactly (the network heuristic mis-colors a
                # client whose push site isn't the site server on its own subnet).
                $pushSiteCode = if ($virtualMachine.pushClient -is [string]) { $virtualMachine.pushClient } else { $null }
                $siteVM = $allVMs | Where-Object { $_.RemoteSQLVM -eq $virtualMachine.vmName -and $_.role -in ("CAS", "Primary", "Secondary") } | Select-Object -First 1

                if ($pushSiteCode -and $ColorMap.ContainsKey($pushSiteCode)) {
                    $color = $ColorMap[$pushSiteCode]
                }
                elseif ($siteVM -and $siteVM.SiteCode) {
                    try {
                        $color = $ColorMap[$($siteVM.SiteCode)]
                    }
                    catch {}
                }
                else {
                    # Color clients to match the Primary/Secondary site that would push the client.
                    # Client-push assignment follows network: a Primary pushes to DomainMembers on its
                    # own network or any of its reporting Secondaries' networks (see ClientPush logic
                    # in Common.GenConfig.ps1). Mirror that here so the menu groups clients visually
                    # with their owning site.
                    $clientNetwork = if ($virtualMachine.Network) { $virtualMachine.Network } else { $config.vmOptions.Network }
                    if ($clientNetwork) {
                        $siteServers = $allVMs | Where-Object { $_.role -in ("Primary", "Secondary") -and $_.SiteCode }
                        # Direct match: site server on same network as the client
                        $owningSite = $siteServers | Where-Object { $_.Network -eq $clientNetwork } | Select-Object -First 1
                        if (-not $owningSite) {
                            # Indirect match: a Secondary on the client's network reports to a Primary
                            $secondaryOnNet = $siteServers | Where-Object { $_.role -eq "Secondary" -and $_.Network -eq $clientNetwork } | Select-Object -First 1
                            if ($secondaryOnNet -and $secondaryOnNet.parentSiteCode) {
                                $owningSite = $siteServers | Where-Object { $_.role -eq "Primary" -and $_.SiteCode -eq $secondaryOnNet.parentSiteCode } | Select-Object -First 1
                            }
                        }
                        if ($owningSite -and $ColorMap.ContainsKey($owningSite.SiteCode)) {
                            $color = $ColorMap[$owningSite.SiteCode]
                        }
                    }
                }

            }
            default {
                $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
            }
        }
        if (-not $color) {
            $color = "%$($Global:Common.Colors.GenConfigNormal)%$($Global:Common.Colors.GenConfigNormalNumber)"
        }
        $name = $name.TrimEnd() + $color
    }

    if ($vmStringCacheKey) {
        $global:VMStringCache[$vmStringCacheKey] = "$name"
    }
    return "$name"
}
