# Common.GenConfig.PKIMenus.ps1
#
# PKI Settings submenu — controls PKI infrastructure deployment independent
# of ConfigMgr, with an optional CM HTTPS toggle.
#
# Menu items:
#   [1] EnablePKI          — Deploy CA infrastructure (works with or without CM)
#   [2] IssuingCAVM        — VM hosting the Issuing CA (shown when EnablePKI = true)
#   [3] UseOfflineRoot     — Two-tier PKI with offline root CA
#   [4] OfflineRootCAVM    — VM hosting the Offline Root CA (shown when UseOfflineRoot = true)
#   [C] UsePKI for CM      — Use HTTPS for CM roles (only shown when cmOptions exists)

function Get-PKIOptionsSummary {
    $options = $Global:Config.pkiOptions
    if (-not $options) { return "" }

    $sep = Format-OptionToken -Color "DimGray" -Text "  ·  "
    $tokens = @()

    # EnablePKI badge
    $enabledMark = if ($options.EnablePKI) { "✓" } else { "✗" }
    $enabledColor = if ($options.EnablePKI) { "ForestGreen" } else { "Tan" }
    $tokens += (Format-OptionToken -Color "DimGray" -Text "CA ") + (Format-OptionToken -Color $enabledColor -Text $enabledMark)

    if ($options.EnablePKI) {
        # Issuing CA VM
        $caVM = if ($options.IssuingCAVM) { $options.IssuingCAVM } else { "(default DC)" }
        $tokens += (Format-OptionToken -Color "DimGray" -Text "Issuing ") + (Format-OptionToken -Color "LightSteelBlue" -Text $caVM)

        # Offline Root
        $rootMark = if ($options.UseOfflineRoot) { "✓" } else { "✗" }
        $rootColor = if ($options.UseOfflineRoot) { "ForestGreen" } else { "Tan" }
        $tokens += (Format-OptionToken -Color "DimGray" -Text "OfflineRoot ") + (Format-OptionToken -Color $rootColor -Text $rootMark)

        if ($options.UseOfflineRoot -and $options.OfflineRootCAVM) {
            $tokens += (Format-OptionToken -Color "DimGray" -Text "RootCA ") + (Format-OptionToken -Color "LightSteelBlue" -Text $options.OfflineRootCAVM)
        }
    }

    $Output = $tokens -join $sep
    $MaxWidth = ($host.UI.RawUI.WindowSize.Width - 38)
    return (Limit-AnsiString -Text $Output -MaxVisible $MaxWidth)
}

function Get-ListOfPossibleCAVMs {
    # Returns VM names eligible to host an Issuing (Enterprise) CA.
    # DCs are the natural choice (AD integration), but any domain-joined server works.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object] $Config = $global:config
    )
    $list = @()
    # DCs first (preferred)
    $list += @($Config.virtualMachines | Where-Object { $_.role -in 'DC', 'BDC' } | ForEach-Object { $_.vmName })
    # Other domain-joined servers
    $list += @($Config.virtualMachines | Where-Object { $_.role -notin 'DC', 'BDC', 'StandaloneRootCA', 'WorkgroupMember', 'AADClient', 'InternetClient' -and -not $_.Hidden } | ForEach-Object { $_.vmName })
    # Deduplicate
    $list = $list | Select-Object -Unique
    return $list
}

function Select-IssuingCAVMMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false)]
        [string] $CurrentValue = $null
    )

    $result = $null
    if ((Get-ListOfPossibleCAVMs -Config $ConfigToModify).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions = @{}
    $additionalOptions += @{
        "N"  = "Create new VM for CA"
        "HN" = "Adds a new domain-joined server VM to host the Issuing CA"
    }

    while ([string]::IsNullOrWhiteSpace($result)) {
        Write-Log -Activity -NoNewLine "Issuing CA VM Selection"
        $result = Get-Menu2 -MenuName "Issuing CA VM Selection" -prompt "Select VM to host Issuing CA" -optionArray $(Get-ListOfPossibleCAVMs -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    if ($result -eq "ESCAPE") {
        return "ESCAPE"
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "DomainMember" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function Select-OfflineRootCAVMMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false)]
        [string] $CurrentValue = $null
    )

    $result = $null
    $existing = @($ConfigToModify.virtualMachines | Where-Object { $_.role -eq 'StandaloneRootCA' } | ForEach-Object { $_.vmName })
    if ($existing.Count -eq 0) {
        $result = "n"
    }

    $additionalOptions = @{}
    $additionalOptions += @{
        "N"  = "Create new Offline Root CA VM"
        "HN" = "Adds a new standalone workgroup VM to host the Offline Root CA"
    }

    while ([string]::IsNullOrWhiteSpace($result)) {
        Write-Log -Activity -NoNewLine "Offline Root CA VM Selection"
        $result = Get-Menu2 -MenuName "Offline Root CA VM Selection" -prompt "Select VM to host Offline Root CA" -optionArray $existing -Test:$false -additionalOptions $additionalOptions -currentValue $CurrentValue
    }
    if ($result -eq "ESCAPE") {
        return "ESCAPE"
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "StandaloneRootCA" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}

function Select-PKIOptions {
    # Main PKI Settings submenu. Builds a custom menu (not generic Select-Options)
    # because items are conditionally visible and have cascade behavior.
    [CmdletBinding()]
    param()

    $pkiOptions = $Global:Config.pkiOptions
    if (-not $pkiOptions) { return }

    while ($true) {
        $MenuItems = [System.Collections.ArrayList]@()
        $padding = 30

        # ── Section: Issuing CA ──
        $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B1" -ItemText "Issuing CA" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader

        # --- Item 1: EnablePKI ---
        $enableText = if ($pkiOptions.EnablePKI) { "True" } else { "False" }
        $enableColor = if ($pkiOptions.EnablePKI) { $Global:Common.Colors.GenConfigTrue } else { $Global:Common.Colors.GenConfigFalse }
        $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "1" -ItemText "$("EnablePKI".PadRight($padding)) = $enableText" -selectable $true -Color1 $enableColor -HelpFunction "Get-PKIHelp"

        if ($pkiOptions.EnablePKI) {
            # --- Item 2: IssuingCAVM ---
            $caVMText = if ($pkiOptions.IssuingCAVM) { $pkiOptions.IssuingCAVM } else { "(default DC)" }
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "2" -ItemText "$("IssuingCAVM".PadRight($padding)) = $caVMText" -selectable $true -Color1 $Global:Common.Colors.GenConfigVMRemoteServer -HelpFunction "Get-PKIHelp"

            # ── Section: Offline Root CA ──
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B" -ItemText "" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B2" -ItemText "Offline Root CA" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader

            # --- Item 3: UseOfflineRoot ---
            $offlineText = if ($pkiOptions.UseOfflineRoot) { "True" } else { "False" }
            $offlineColor = if ($pkiOptions.UseOfflineRoot) { $Global:Common.Colors.GenConfigTrue } else { $Global:Common.Colors.GenConfigFalse }
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "3" -ItemText "$("UseOfflineRoot".PadRight($padding)) = $offlineText" -selectable $true -Color1 $offlineColor -HelpFunction "Get-PKIHelp"

            if ($pkiOptions.UseOfflineRoot) {
                # --- Item 4: OfflineRootCAVM ---
                $rootVMText = if ($pkiOptions.OfflineRootCAVM) { $pkiOptions.OfflineRootCAVM } else { "(auto-created)" }
                $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "4" -ItemText "$("OfflineRootCAVM".PadRight($padding)) = $rootVMText" -selectable $true -Color1 $Global:Common.Colors.GenConfigVMRemoteServer -HelpFunction "Get-PKIHelp"
            }
        }

        # ── Section: ConfigMgr ──
        if ($Global:Config.cmOptions) {
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B" -ItemText "" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B3" -ItemText "ConfigMgr" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader

            # --- Item C: UsePKI for ConfigMgr ---
            $usePKIText = if ($Global:Config.cmOptions.UsePKI) { "True" } else { "False" }
            $usePKIColor = if ($Global:Config.cmOptions.UsePKI) { $Global:Common.Colors.GenConfigTrue } else { $Global:Common.Colors.GenConfigFalse }
            $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "C" -ItemText "$("UsePKI for ConfigMgr".PadRight($padding)) = $usePKIText" -selectable $true -Color1 $usePKIColor -HelpFunction "Get-PKIHelp"
        }

        # --- Done ---
        $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*B" -ItemText "" -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader
        $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "*V" -ItemText "   ──────────────────────" -selectable $false -Color1 "SlateGray"
        $null = Add-MenuItem -MenuName "PKI Settings" -MenuItems ([ref]$MenuItems) -ItemName "!" -ItemText "Done with changes" -selectable $true -selected $true -Color1 $Global:Common.Colors.GenConfigHelpHighlight -HelpFunction "Get-PKIHelp"

        $response = Get-Menu2 -MenuName "PKI Settings" -menuItems ([ref]$MenuItems) -Prompt "Select PKI option to modify" -HideHelp:$true -test:$false

        if ([String]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE" -or $response -eq "!") {
            return
        }

        switch ($response) {
            "1" {
                # Toggle EnablePKI
                $pkiOptions.EnablePKI = -not $pkiOptions.EnablePKI
                if ($pkiOptions.EnablePKI) {
                    # Auto-fill IssuingCAVM with first DC if empty
                    if (-not $pkiOptions.IssuingCAVM) {
                        $firstDC = $Global:Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                        if ($firstDC) {
                            $pkiOptions.IssuingCAVM = $firstDC.vmName
                        }
                    }
                }
                else {
                    # Cascade: disable everything downstream
                    $pkiOptions.IssuingCAVM = ""
                    $pkiOptions.UseOfflineRoot = $false
                    $pkiOptions.OfflineRootCAVM = ""
                    # Can't use PKI for CM without CA infrastructure
                    if ($Global:Config.cmOptions -and $Global:Config.cmOptions.UsePKI) {
                        $Global:Config.cmOptions.UsePKI = $false
                    }
                }
            }
            "C" {
                if ($Global:Config.cmOptions) {
                    $Global:Config.cmOptions.UsePKI = -not $Global:Config.cmOptions.UsePKI
                    if ($Global:Config.cmOptions.UsePKI) {
                        # Turning on UsePKI auto-enables PKI infrastructure
                        if (-not $pkiOptions.EnablePKI) {
                            $pkiOptions.EnablePKI = $true
                        }
                        # Auto-fill IssuingCAVM with first DC if empty
                        if (-not $pkiOptions.IssuingCAVM) {
                            $firstDC = $Global:Config.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
                            if ($firstDC) {
                                $pkiOptions.IssuingCAVM = $firstDC.vmName
                            }
                        }
                    }
                }
            }
            "2" {
                if ($pkiOptions.EnablePKI) {
                    $result = Select-IssuingCAVMMenu -ConfigToModify $Global:Config -CurrentValue $pkiOptions.IssuingCAVM
                    if ($result -and $result -ne "ESCAPE") {
                        $pkiOptions.IssuingCAVM = $result
                    }
                }
            }
            "3" {
                if ($pkiOptions.EnablePKI) {
                    $pkiOptions.UseOfflineRoot = -not $pkiOptions.UseOfflineRoot
                    if ($pkiOptions.UseOfflineRoot) {
                        # Auto-fill OfflineRootCAVM if a StandaloneRootCA VM already exists
                        if (-not $pkiOptions.OfflineRootCAVM) {
                            $existingRoot = $Global:Config.virtualMachines | Where-Object { $_.role -eq 'StandaloneRootCA' } | Select-Object -First 1
                            if ($existingRoot) {
                                $pkiOptions.OfflineRootCAVM = $existingRoot.vmName
                            }
                        }
                    }
                    else {
                        $pkiOptions.OfflineRootCAVM = ""
                    }
                }
            }
            "4" {
                if ($pkiOptions.EnablePKI -and $pkiOptions.UseOfflineRoot) {
                    $result = Select-OfflineRootCAVMMenu -ConfigToModify $Global:Config -CurrentValue $pkiOptions.OfflineRootCAVM
                    if ($result -and $result -ne "ESCAPE") {
                        $pkiOptions.OfflineRootCAVM = $result
                    }
                }
            }
        }
    }
}

function Get-PKIHelp {
    param($text)

    switch (($text -split "=")[0].Trim()) {
        "EnablePKI" { "Deploy Certificate Authority infrastructure. Works with or without ConfigMgr. Installs an Enterprise CA on the selected VM." }
        "UsePKI for ConfigMgr" { "Use HTTPS for all ConfigMgr roles (DP/MP/SUP/RP). Automatically enables PKI infrastructure if not already enabled." }
        "IssuingCAVM" { "The VM that will host the Issuing (Enterprise) CA. Defaults to the domain controller." }
        "UseOfflineRoot" { "Deploy a two-tier PKI: a Standalone Offline Root CA issues a certificate for an Enterprise Subordinate CA. The Root CA VM is powered off after setup." }
        "OfflineRootCAVM" { "The standalone workgroup VM that will host the Offline Root CA. Auto-created if not specified." }
        "Done with changes" { "Return to the main menu." }
        default { "" }
    }
}
