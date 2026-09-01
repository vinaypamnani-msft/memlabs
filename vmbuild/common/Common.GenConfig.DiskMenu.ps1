# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
# Common.GenConfig.DiskMenu.ps1
#
# Dedicated per-VM disk management sub-menu for genconfig.
#
# Replaces the legacy "A = Add disk / R = Remove last disk" inline actions in
# the per-VM property menu (Common.GenConfig.VMList.ps1) with a richer screen
# that supports:
#   - Add a new disk (picks the next free letter E..Y, with a contextual
#     default size: 400GB for the first disk on a SQL-capable role, 250GB
#     otherwise).
#   - Edit any existing disk's size.
#   - Remove any disk (not just the last one), enforcing the same guard rules
#     the legacy `R` handler used (FileServer floor, SQL/CM/WSUS paths).
#   - Delete key on a disk row as a shortcut for Remove.
#
# All actions share the same helper functions so the per-VM dispatcher can
# also call Invoke-AddDisk / Invoke-RemoveDisk directly in the future without
# duplicating logic.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Returns the list of disk letters currently configured on the VM, in
# ascending order. Empty array if additionalDisks is missing.
function Get-VMDiskLetters {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )
    if ($null -eq $VirtualMachine.additionalDisks) {
        return @()
    }
    return @(
        $VirtualMachine.additionalDisks.PSObject.Properties |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
}

# Returns the next free disk letter (E..Y, excluding the reserved S) for this
# VM, or $null if all are already used.
function Get-NextDiskLetter {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )
    $used = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    foreach ($code in 69..89) {  # 'E'..'Y'
        $letter = [char]$code
        # S: is reserved for the SQL ISO mount (SqlSetup SourcePath). Never
        # offer it as an additional data disk.
        if ($letter -eq 'S') { continue }
        if ($used -notcontains [string]$letter) {
            return [string]$letter
        }
    }
    return $null
}

# Ensures a fresh WSUS/SUP VM has a dedicated 250GB content disk. Existing
# VMs are deliberately immutable here because adding a config disk does not
# attach a VHD to hardware that Phase 1 already created.
function Set-WsusDedicatedContentDisk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [string] $Size = '250GB'
    )

    if ($VirtualMachine.ExistingVM) {
        return $false
    }

    $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    $wsusLetter = $null
    if ("$($VirtualMachine.wsusContentDir)" -match '^([E-Y]):\\') {
        $candidate = $Matches[1].ToUpperInvariant()
        if ($candidate -ne 'S') {
            $wsusLetter = $candidate
        }
    }

    $sharedWithConfiguredRole = $false
    foreach ($path in @($VirtualMachine.cmInstallDir, $VirtualMachine.sqlInstanceDir)) {
        if ($wsusLetter -and "$path" -match "^$wsusLetter`:\\") {
            $sharedWithConfiguredRole = $true
            break
        }
    }

    $configMgrCanSelectDrive = $VirtualMachine.Role -in @('CAS', 'Primary', 'Secondary') -or $VirtualMachine.InstallDP
    $hasAlternateConfigMgrDisk = @($letters | Where-Object { $_ -ne $wsusLetter }).Count -gt 0
    $hasDedicatedDisk = $wsusLetter -and
        ($letters -contains $wsusLetter) -and
        (-not $sharedWithConfiguredRole) -and
        ((-not $configMgrCanSelectDrive) -or $hasAlternateConfigMgrDisk)

    if ($hasDedicatedDisk) {
        return $true
    }

    $newLetter = Get-NextDiskLetter -VirtualMachine $VirtualMachine
    if (-not $newLetter) {
        return $false
    }

    if ($null -eq $VirtualMachine.additionalDisks) {
        $disks = [PSCustomObject]@{ $newLetter = $Size }
        $VirtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disks -Force
    }
    else {
        $VirtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $newLetter -Value $Size -Force
    }
    $VirtualMachine | Add-Member -MemberType NoteProperty -Name 'wsusContentDir' -Value "$newLetter`:\WSUS" -Force

    return $true
}

# Describes how the given disk letter is consumed by the VM's role config.
# Returns a short human-readable string.
function Get-VMDiskUsage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [Parameter(Mandatory = $true)]
        [string] $Letter
    )
    $prefix = "$Letter`:"
    $uses = @()
    if ($VirtualMachine.SqlInstanceDir -and $VirtualMachine.SqlInstanceDir.StartsWith($prefix)) {
        $uses += "SQL Instance ($($VirtualMachine.SqlInstanceDir))"
    }
    if ($VirtualMachine.cmInstallDir -and $VirtualMachine.cmInstallDir.StartsWith($prefix)) {
        $uses += "ConfigMgr ($($VirtualMachine.cmInstallDir))"
    }
    if ($VirtualMachine.wsusContentDir -and $VirtualMachine.wsusContentDir.StartsWith($prefix)) {
        $uses += "WSUS ($($VirtualMachine.wsusContentDir))"
    }
    if ($VirtualMachine.Role -eq "FileServer") {
        $uses += "FileServer share"
    }
    if ($uses.Count -eq 0) {
        return "free"
    }
    return ($uses -join ", ")
}

# Normalize a size string. Accepts "100", "100GB", "100 GB" (any case).
# Returns the normalized "<n>GB" string on success, or $null on failure.
function ConvertTo-DiskSize {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string] $InputValue
    )
    if ([string]::IsNullOrWhiteSpace($InputValue)) {
        return $null
    }
    $trimmed = $InputValue.Trim().ToUpperInvariant() -replace '\s+', ''
    if ($trimmed -match '^(\d+)(GB)?$') {
        return "$($matches[1])GB"
    }
    return $null
}

# True if $Size (already normalized "<n>GB") falls in the supported range.
function Test-DiskSizeInput {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Size
    )
    if ($Size -notmatch '^(\d+)GB$') { return $false }
    $n = [int]$matches[1]
    return ($n -ge 10 -and $n -le 1000)
}

# Returns the suggested default size (string, e.g. "400GB") for a brand-new
# disk on this VM. First disk on a SQL-capable role => 400GB; otherwise 250GB.
function Get-DefaultDiskSize {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )
    $existing = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($existing.Count -eq 0) {
        $sqlRoles = @("Primary", "CAS", "Secondary", "SQLAO", "WSUS")
        if ($VirtualMachine.sqlVersion -or ($sqlRoles -contains $VirtualMachine.Role)) {
            return "400GB"
        }
    }
    return "250GB"
}

# Returns $null if removing $Letter is allowed; otherwise a human-readable
# refusal string. Generalized from the legacy R handler in
# Common.GenConfig.VMList.ps1 (~L991-L1051) so that any disk, not just the
# last one, can be checked.
function Test-DiskRemovable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [Parameter(Mandatory = $true)]
        [string] $Letter
    )
    $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($letters -notcontains $Letter) {
        return "Disk $Letter`: is not configured on this VM"
    }
    if ($VirtualMachine.Role -eq "FileServer" -and $letters.Count -le 2) {
        return "FileServers must have at least 2 additional disks"
    }
    $prefix = "$Letter`:"
    if ($VirtualMachine.SqlInstanceDir -and $VirtualMachine.SqlInstanceDir.StartsWith($prefix)) {
        return "SQL is configured to install to $($VirtualMachine.SqlInstanceDir). Cannot remove"
    }
    if ($VirtualMachine.cmInstallDir -and $VirtualMachine.cmInstallDir.StartsWith($prefix)) {
        return "ConfigMgr is configured to install to $($VirtualMachine.cmInstallDir). Cannot remove"
    }
    if ($VirtualMachine.wsusContentDir -and $VirtualMachine.wsusContentDir.StartsWith($prefix)) {
        return "WSUS is configured to use $($VirtualMachine.wsusContentDir). Cannot remove"
    }
    return $null
}

# Returns a short one-line summary like "E:400GB, F:200GB" for use in the
# per-VM menu's "Manage Disks (...)" entry.
function Get-DiskShortSummary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )
    $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($letters.Count -eq 0) {
        return "no additional disks"
    }
    $parts = foreach ($l in $letters) {
        "$l`:$($VirtualMachine.additionalDisks.$l)"
    }
    return ($parts -join ", ")
}

# ---------------------------------------------------------------------------
# Shared action helpers (callable from sub-menu or, in the future, inline)
# ---------------------------------------------------------------------------

# Add a new disk. Returns $true on success, $false on cancel/failure.
function Invoke-AddDisk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )
    $letter = Get-NextDiskLetter -VirtualMachine $VirtualMachine
    if (-not $letter) {
        Write-Host
        Write-RedX "No free disk letters available (E..Y are all in use)"
        return $false
    }
    $default = Get-DefaultDiskSize -VirtualMachine $VirtualMachine
    while ($true) {
        $raw = Read-Host2 -Prompt "New disk $letter`: size (10GB - 1000GB)" -currentValue $default
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $raw = $default
        }
        if ($raw -eq "ESCAPE") {
            return $false
        }
        $size = ConvertTo-DiskSize -InputValue $raw
        if (-not $size -or -not (Test-DiskSizeInput -Size $size)) {
            Write-RedX "Invalid size '$raw'. Enter a number 10-1000 (e.g. 250 or 250GB)."
            continue
        }
        if ($null -eq $VirtualMachine.additionalDisks) {
            $obj = [PSCustomObject]@{ $letter = $size }
            $VirtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $obj -Force
        }
        else {
            $VirtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $letter -Value $size -Force
        }
        return $true
    }
}

# Edit the size of an existing disk. Returns $true on success, $false on
# cancel/failure.
function Invoke-EditDiskSize {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [Parameter(Mandatory = $true)]
        [string] $Letter
    )
    $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($letters -notcontains $Letter) {
        Write-RedX "Disk $Letter`: is not configured on this VM"
        return $false
    }
    $current = $VirtualMachine.additionalDisks.$Letter
    while ($true) {
        $raw = Read-Host2 -Prompt "New size for disk $Letter`: (10GB - 1000GB)" -currentValue $current
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $false  # no change
        }
        if ($raw -eq "ESCAPE") {
            return $false
        }
        $size = ConvertTo-DiskSize -InputValue $raw
        if (-not $size -or -not (Test-DiskSizeInput -Size $size)) {
            Write-RedX "Invalid size '$raw'. Enter a number 10-1000 (e.g. 250 or 250GB)."
            continue
        }
        if ($size -eq $current) {
            return $false
        }
        $VirtualMachine.additionalDisks.$Letter = $size
        # If shrinking a disk that hosts a role payload, warn (do not block).
        $usage = Get-VMDiskUsage -VirtualMachine $VirtualMachine -Letter $Letter
        if ($usage -ne "free") {
            $oldN = [int]($current -replace 'GB','')
            $newN = [int]($size -replace 'GB','')
            if ($newN -lt $oldN) {
                Write-Host
                Write-Host2 -ForegroundColor Yellow "Warning: disk $Letter`: hosts $usage. Verify the new size is sufficient."
            }
        }
        return $true
    }
}

# Remove a disk, enforcing the guard rules. Returns $true on success, $false
# on rejection/failure.
function Invoke-RemoveDisk {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [Parameter(Mandatory = $true)]
        [string] $Letter
    )
    $reason = Test-DiskRemovable -VirtualMachine $VirtualMachine -Letter $Letter
    if ($reason) {
        # Surface the rejection inline on the disk row in the VM Properties
        # menu (consumed by the disk-row builder on next redraw), matching
        # how property edits show validation errors. Use a stable
        # property key per VM+letter so multiple VMs don't collide.
        $diskErrKey = "disk:$($VirtualMachine.vmName):$Letter"
        Add-ErrorMessage -property $diskErrKey -message $reason
        return $false
    }
    $VirtualMachine.additionalDisks.PSObject.Properties.Remove($Letter)
    $remaining = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($remaining.Count -eq 0) {
        $VirtualMachine.PSObject.Properties.Remove('additionalDisks')
    }
    return $true
}

# ---------------------------------------------------------------------------
# Sub-menu
# ---------------------------------------------------------------------------

# Full disk-management screen for a single VM. Loops until the user picks
# Done (`!` or Enter on the Done row) or presses Escape.
function Select-VMDisksMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine
    )

    $menuName = "Disks for $($VirtualMachine.vmName)"
    while ($true) {
        $MenuItems = [System.Collections.ArrayList]@()

        # Header
        $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
            -ItemName "*H" -ItemText "Additional disks for $($VirtualMachine.vmName)" `
            -selectable $false -Color1 $Global:Common.Colors.GenConfigHeader
        $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
            -ItemName "*V" -ItemText "   ──────────────────────────────────────────" `
            -selectable $false -Color1 "SlateGray"

        $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine

        # Map numeric itemName -> disk letter. Menu engine's Write-Option
        # caps itemName width at ~4 chars (PadRight(4 - len) goes negative
        # otherwise), so we use 1-based indices for disk rows and translate
        # back here.
        $indexToLetter = @{}

        if ($letters.Count -eq 0) {
            $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
                -ItemName "*I" -ItemText "   (no additional disks configured)" `
                -selectable $false -Color1 "DarkGray"
        }
        else {
            $idx = 0
            foreach ($l in $letters) {
                $idx++
                $size  = $VirtualMachine.additionalDisks.$l
                $usage = Get-VMDiskUsage -VirtualMachine $VirtualMachine -Letter $l
                $sizePadded = $size.PadRight(8)
                $text = "$l`:  $sizePadded   ($usage)"
                $color = $Global:Common.Colors.GenConfigNormal
                if ($usage -ne "free") {
                    $color = $Global:Common.Colors.GenConfigNonDefault
                }
                # Surface any pending rejection from Invoke-RemoveDisk inline
                # on the row (matches inline disk rows in VM Properties menu).
                # Without this the Delete key on an in-use disk silently
                # bounced the user with no feedback.
                $diskErrKey = "disk:$($VirtualMachine.vmName):$l"
                if ($global:GenConfigErrorMessages) {
                    $diskErr = $global:GenConfigErrorMessages | Where-Object { $_.property -eq $diskErrKey } | Select-Object -First 1
                    if ($diskErr) {
                        $text = $text.PadRight(45) + "[x] $($diskErr.Message)"
                        $color = "Salmon"
                        $global:GenConfigErrorMessages = @($global:GenConfigErrorMessages | Where-Object { $_.property -ne $diskErrKey })
                    }
                }
                $indexToLetter[[string]$idx] = $l
                $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
                    -ItemName ([string]$idx) -ItemText $text -selectable $true `
                    -Deletable $true -Color1 $color
            }
        }

        # Action footer
        $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
            -ItemName "*B" -ItemText "" -selectable $false
        $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
            -ItemName "*V2" -ItemText "   ──────────────────────────────────────────" `
            -selectable $false -Color1 "SlateGray"

        $nextLetter = Get-NextDiskLetter -VirtualMachine $VirtualMachine
        if ($nextLetter) {
            $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
                -ItemName "A" -ItemText "Add a new disk (will be $nextLetter`:)" -selectable $true
        }
        else {
            $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
                -ItemName "*An" -ItemText "   (no free drive letters E..Y remain)" `
                -selectable $false -Color1 "DarkGray"
        }
        if ($letters.Count -gt 0) {
            # Edit-size is reached by picking the disk row directly; no
            # separate [E] action needed.
            $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
                -ItemName "R" -ItemText "Remove a disk" -selectable $true
        }
        $null = Add-MenuItem -MenuName $menuName -MenuItems ([ref]$MenuItems) `
            -ItemName "!" -ItemText "Done (return to VM)" -selectable $true -selected $true `
            -Color1 $Global:Common.Colors.GenConfigHelpHighlight

        $response = Get-Menu2 -MenuName $menuName -menuItems ([ref]$MenuItems) `
            -Prompt "Select a disk to edit, or pick an action" -HideHelp:$true `
            -test:$false -AcceptsDelete

        if ([string]::IsNullOrWhiteSpace($response) -or $response -eq "ESCAPE" -or $response -eq "!") {
            return
        }

        # Delete key on a disk row: "-D<index>"
        if ($response -is [string] -and $response.StartsWith("-D")) {
            $key = $response.Substring(2)
            if ($indexToLetter.ContainsKey($key)) {
                $null = Invoke-RemoveDisk -VirtualMachine $VirtualMachine -Letter $indexToLetter[$key]
                Get-TestResult -SuccessOnError | Out-Null
            }
            continue
        }

        # Numeric pick on a disk row = edit its size.
        if ($indexToLetter.ContainsKey($response)) {
            $null = Invoke-EditDiskSize -VirtualMachine $VirtualMachine -Letter $indexToLetter[$response]
            Get-TestResult -SuccessOnError | Out-Null
            continue
        }

        switch -Regex ($response) {
            '^A$' {
                $null = Invoke-AddDisk -VirtualMachine $VirtualMachine
                Get-TestResult -SuccessOnError | Out-Null
                break
            }
            '^R$' {
                $letter = Select-DiskLetterPrompt -VirtualMachine $VirtualMachine -Action "remove"
                if ($letter) {
                    $null = Invoke-RemoveDisk -VirtualMachine $VirtualMachine -Letter $letter
                    Get-TestResult -SuccessOnError | Out-Null
                }
                break
            }
            default {
                # Unknown response: ignore and redraw.
            }
        }
    }
}

# Prompts for a disk letter; accepts either the letter itself ("E") or its
# 1-based index in the sorted disk list. Returns the letter or $null on
# cancel.
function Select-DiskLetterPrompt {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object] $VirtualMachine,
        [Parameter(Mandatory = $true)]
        [string] $Action
    )
    $letters = Get-VMDiskLetters -VirtualMachine $VirtualMachine
    if ($letters.Count -eq 0) {
        Write-RedX "No disks to $Action"
        return $null
    }
    if ($letters.Count -eq 1) {
        return $letters[0]
    }
    $list = ($letters | ForEach-Object { "$_`:" }) -join ", "
    while ($true) {
        $raw = Read-Host2 -Prompt "Which disk to $Action`? ($list)"
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq "ESCAPE") {
            return $null
        }
        $raw = $raw.Trim().ToUpperInvariant() -replace ':',''
        if ($raw.Length -eq 1 -and ($letters -contains $raw)) {
            return $raw
        }
        if ($raw -match '^\d+$') {
            $idx = [int]$raw
            if ($idx -ge 1 -and $idx -le $letters.Count) {
                return $letters[$idx - 1]
            }
        }
        Write-RedX "Pick one of: $list"
    }
}
