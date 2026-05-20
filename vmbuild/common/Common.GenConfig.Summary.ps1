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
        Format-OptionToken -Color "LightSteelBlue" -Text "[$($options.prefix)]"
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
    $fixedConfig = $Global:Config.virtualMachines | Where-Object { -not $_.hidden }
    $options = $Global:Config.cmOptions

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

    # Push Clients — green ✓ when on, tan ✗ when off (intentional, not error)
    $pushColor = if ($options.pushClientToDomainMembers) { "ForestGreen" } else { "Tan" }
    $pushMark = if ($options.pushClientToDomainMembers) { "✓" } else { "✗" }

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
        (Format-OptionToken -Color "DimGray" -Text "Push ") + (Format-OptionToken -Color $pushColor -Text $pushMark)
        (Format-OptionToken -Color "DimGray" -Text "Auth ") + (Format-OptionToken -Color $authColor -Text $authText)
        (Format-OptionToken -Color "DimGray" -Text "SCP ") + (Format-OptionToken -Color $scpColor -Text $scpText)
    )

    # SUP Offline badge — only shown when a SUP is present AND OfflineSUP is set (non-default)
    $testSystem = $fixedConfig | Where-Object { $_.installSUP }
    if ($testSystem -and $options.OfflineSUP) {
        $tokens += (Format-OptionToken -Color "DimGray" -Text "SUP ") + (Format-OptionToken -Color "Tan" -Text "Offline")
    }

    # BLM badge — only shown when EnableBLM is set (non-default)
    if ($options.EnableBLM) {
        $tokens += (Format-OptionToken -Color "DimGray" -Text "BLM ") + (Format-OptionToken -Color "ForestGreen" -Text "✓")
    }

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

    $Sorted = @()
    $members = $property | Get-Member -MemberType NoteProperty
    if ($members.Name -contains "vmName") {
        $sorted += "vmName"
    }
    if ($members.Name -contains "DeploymentType") {
        $sorted += "DeploymentType"
    }
    if ($members.Name -contains "domainName") {
        $sorted += "DomainName"
    }
    if ($members.Name -contains "CMVersion") {
        $sorted += "CMVersion"
    }
    if ($members.Name -contains "prefix") {
        $sorted += "Prefix"
    }
    if ($members.Name -contains "network") {
        $sorted += "Network"
    }
    if ($members.Name -contains "DefaultServerOS") {
        $sorted += "DefaultServerOS"
    }
    if ($members.Name -contains "DefaultClientOS") {
        $sorted += "DefaultClientOS"
    }
    if ($members.Name -contains "DefaultSqlVersion") {
        $sorted += "DefaultSqlVersion"
    }
    if ($members.Name -contains "UseDynamicMemory") {
        $sorted += "UseDynamicMemory"
    }
    if ($members.Name -contains "IncludeClients") {
        $sorted += "IncludeClients"
    }
    if ($members.Name -contains "IncludeSSMSOnNONSQL") {
        $sorted += "IncludeSSMSOnNONSQL"
    }
    if ($members.Name -contains "adminName") {
        $sorted += "AdminName"
    }
    if ($members.Name -contains "basePath") {
        $sorted += "BasePath"
    }
    if ($members.Name -contains "domainUser") {
        $sorted += "DomainUser"
    }
    if ($members.Name -contains "role") {
        $sorted += "Role"
    }
    if ($members.Name -contains "memory") {
        $sorted += "Memory"
    }
    if ($members.Name -contains "dynamicMinRam") {
        $sorted += "DynamicMinRam"
    }
    if ($members.Name -contains "virtualProcs") {
        $sorted += "VirtualProcs"
    }
    if ($members.Name -contains "operatingSystem") {
        $sorted += "OperatingSystem"
    }
    if ($members.Name -contains "sqlVersion") {
        $sorted += "sqlVersion"
    }
    if ($members.Name -contains "sqlInstanceName") {
        $sorted += "sqlInstanceName"
    }
    if ($members.Name -contains "sqlInstanceDir") {
        $sorted += "sqlInstanceDir"
    }
    if ($members.Name -contains "sqlPort") {
        $sorted += "sqlPort"
    }
    if ($members.Name -contains "SqlAgentAccount") {
        $sorted += "SqlAgentAccount"
    }
    if ($members.Name -contains "SqlServiceAccount") {
        $sorted += "SqlServiceAccount"
    }    
    if ($members.Name -contains "remoteSQLVM") {
        $sorted += "RemoteSQLVM"
    }
    if ($members.Name -contains "cmInstallDir") {
        $sorted += "cmInstallDir"
    }
    if ($members.Name -contains "parentSiteCode") {
        $sorted += "ParentSiteCode"
    }
    if ($members.Name -contains "siteCode") {
        $sorted += "SiteCode"
    }
    if ($members.Name -contains "siteName") {
        $sorted += "SiteName"
    }
    if ($members.Name -contains "remoteContentLibVM") {
        $sorted += "RemoteContentLibVM"
    }
    if ($members.Name -contains "tpmEnabled") {
        $sorted += "tpmEnabled"
    }
    if ($members.Name -contains "BitLocker") {
        $sorted += "BitLocker"
    }
    if ($members.Name -contains "InstallSSMS") {
        $sorted += "InstallSSMS"
    }

    if ($members.Name -contains "additionalDisks") {
        $sorted += "AdditionalDisks"
    }
    if ($members.Name -contains "installDP") {
        $sorted += "InstallDP"
    }
    if ($members.Name -contains "enablePullDP") {
        $sorted += "EnablePullDP"
    }
    if ($members.Name -contains "installMP") {
        $sorted += "InstallMP"
    }
    if ($members.Name -contains "installRP") {
        $sorted += "InstallRP"
    }
    if ($members.Name -contains "installSUP") {
        $sorted += "InstallSUP"
    }
    if ($members.Name -contains "installSMSProv") {
        $sorted += "InstallSMSProv"
    }
    if ($members.Name -contains "Version") {
        $sorted += "Version"
    }
    if ($members.Name -contains "Install") {
        $sorted += "Install"
    }
    if ($members.Name -contains "EVALVersion") {
        $sorted += "EVALVersion"
    }
    if ($members.Name -contains "UsePKI") {
        $sorted += "UsePKI"
    }
    if ($members.Name -contains "OfflineSCP") {
        $sorted += "OfflineSCP"
    }
    if ($members.Name -contains "OfflineSUP") {
        $sorted += "OfflineSUP"
    }
    if ($members.Name -contains "PushClientToDomainMembers") {
        $sorted += "PushClientToDomainMembers"
    }
    if ($members.Name -contains "PrePopulateObjects") {
        $sorted += "PrePopulateObjects"
    }
    if ($members.Name -contains "EnableBLM") {
        $sorted += "EnableBLM"
    }
  
    switch ($members.Name) {
        "vmName" {  }
        "role" {  }
        "memory" { }
        "dynamicMinRam" { }
        "domainUser" {}
        "virtualProcs" { }
        "operatingSystem" {  }
        "siteCode" { }
        "siteName" { }
        "parentSiteCode" { }
        "sqlVersion" { }
        "sqlInstanceName" {  }
        "sqlInstanceDir" { }
        "sqlPort" { }
        "SqlAgentAccount" { }
        "SqlServiceAccount" { }
        "additionalDisks" { }
        "cmInstallDir" { }
        "DeploymentType" { }
        "domainName" { }
        "prefix" { }
        "CMVersion" { }
        "network" { }
        "DefaultServerOS" { }
        "DefaultClientOS" { }
        "DefaultSqlVersion" { }
        "UseDynamicMemory" {}
        "IncludeClients" { }
        "IncludeSSMSOnNONSQL" { }  
        "adminName" { }
        "basePath" { }
        "remoteSQLVM" {}
        "remoteContentLibVM" {}
        "tpmEnabled" {}
        "BitLocker" {}
        "installSSMS" {}
        "installCA" {}
        "UseOfflineRoot" {}
        "SubordinateCA" {}
        "_autoAddedByOfflineRootCA" {}
        "enablePullDP" {}
        "installSUP" {}
        "installDP" {}
        "installMP" {}
        "installRP" {}
        "installSMSProv" {}
        "version" {}
        "install" {}
        "EVALVersion" {}
        "UsePKI" {}
        "OfflineSCP" {}
        "OfflineSUP" {}
        "pushClientToDomainMembers" {}
        "PrePopulateObjects" {}
        "EnableBLM" {}


        Default { $sorted += $_ }
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

    switch ($item) {

        "RemoteSQLVM" {
            $remoteSQL = $global:config.virtualMachines | Where-Object { $_.vmName -eq $data }
            $name = $($global:config.vmOptions.Prefix + $data)
            if ($remoteSQL) {
                if ($remoteSQL.OtherNode) {
                    $data = $data.PadRight(21) + "($name) [SQL Always On Cluster]"
                }
                else {
                    $data = $data.PadRight(21) + "($name)"
                }
            }
        }
        "ClusterName" {
            $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
        }

        "AlwaysOnListenerName" {
            $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
        }

        "vmName" {
            if (-not $data.StartsWith($global:config.vmOptions.Prefix)) {
                $data = $data.PadRight(21) + "($($global:config.vmOptions.Prefix+$data))"
            }
        }

        "domainUser" {
            $prefixLower = $global:config.vmOptions.Prefix.ToLower()
            if (-not $data.StartsWith($prefixLower)) {
                $data = $data.PadRight(21) + "($($prefixLower+$data))"
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

    if ($virtualMachine.remoteSQLVM) {
        $sqlVM = $allVMs | Where-Object { $_.vmName -eq $virtualMachine.remoteSQLVM }
        if ($sqlVM.OtherNode) { $name += "  SQL AO [$($sqlVM.vmName),$($sqlVM.OtherNode)]" }
        else { $name += "  Remote SQL [$($virtualMachine.remoteSQLVM)]" }
    }    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
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
                $siteVM = $allVMs | Where-Object { $_.RemoteSQLVM -eq $virtualMachine.vmName -and $_.role -in ("CAS", "Primary", "Secondary") } | Select-Object -First 1

                if ($siteVM -and $siteVM.SiteCode) {
                    try {
                        $color = $ColorMap[$($siteVM.SiteCode)]
                    }
                    catch {}
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
