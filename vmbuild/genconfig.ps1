[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Used when calling from New-Lab")]
    [Switch] $InternalUseOnly
)

$return = [PSCustomObject]@{
    ConfigFileName = $null
    DeployNow      = $false
    ForceNew       = $false
}

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };

if (-not $InternalUseOnly.IsPresent) {
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }

    # Dot source common
    . $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose
}

$configDir = Join-Path $PSScriptRoot "config"
$sampleDir = Join-Path $PSScriptRoot "config\samples"

Write-Host -ForegroundColor Cyan ""
Write-Host -ForegroundColor Cyan "New-Lab Configuration generator:"
Write-Host -ForegroundColor Cyan "You can use this tool to customize most options."
Write-Host -ForegroundColor Cyan "Press Ctrl-C to exit without saving."
Write-Host -ForegroundColor Cyan ""

function write-help {
    $color = [System.ConsoleColor]::DarkGray
    Write-Host -ForegroundColor $color "Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Enter]" -NoNewline
    Write-Host -ForegroundColor $color " to skip a section Press " -NoNewline
    Write-Host -ForegroundColor Yellow "[Ctrl-C]" -NoNewline
    Write-Host -ForegroundColor $color " to exit without saving."
}

function Write-Option {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Option to display. Eg 1")]
        [string] $option,
        [Parameter(Mandatory = $true, HelpMessage = "Description of the option")]
        [string] $text,
        [Parameter(Mandatory = $false, HelpMessage = "Description Color")]
        [object] $color,
        [Parameter(Mandatory = $false, HelpMessage = "Option Color")]
        [object] $color2
    )

    if ($null -eq $color) {
        $color = [System.ConsoleColor]::Gray
    }
    if ($null -eq $color2) {
        $color2 = [System.ConsoleColor]::White
    }
    write-host "[" -NoNewline
    Write-Host -ForegroundColor $color2 $option -NoNewline
    Write-Host "] ".PadRight(4 - $option.Length) -NoNewLine

    while (-not [string]::IsNullOrWhiteSpace($text)) {
        #write-host $text
        $indexLeft = $text.IndexOf('[')
        $indexRight = $text.IndexOf(']')
        if ($indexRight -eq -1 -and $indexLeft -eq -1) {
            Write-Host -ForegroundColor $color "$text" -NoNewline
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
                Write-Host -ForegroundColor $color "$text2Display" -NoNewline
                Write-Host -ForegroundColor DarkGray "]" -NoNewline
                $text = $text.Substring($indexRight)
                $text = $text.Substring(1)
            }
            if ($indexLeft -lt $indexRight) {
                $text2Display = $text.Substring(0, $indexLeft)
                Write-Host -ForegroundColor $color "$text2Display" -NoNewline
                Write-Host -ForegroundColor DarkGray "[" -NoNewline
                $text = $text.Substring($indexLeft)
                $text = $text.Substring(1)
            }
        }

    }
    write-host
}

function Select-ConfigMenu {
    while ($true) {
        $customOptions = [ordered]@{ "1" = "Create New Domain%white%green" }
        $domainCount = (get-list -Type UniqueDomain | Measure-Object).Count
        $customOptions += [ordered]@{"2" = "Expand Existing Domain [$($domainCount) existing domain(s)]%white%green"; }
        $customOptions += [ordered]@{"*B" = ""; "*BREAK" = "---  Load Config ($configDir)%cyan"; "3" = "Load Sample Configuration%gray%green"; "4" = "Load saved config from File%gray%green"; "*B3" = ""; }
        $vmsRunning = (Get-List -Type VM | Where-Object { $_.State -eq "Running" } | Measure-Object).Count
        $vmsTotal = (Get-List -Type VM | Measure-Object).Count
        $os = Get-Ciminstance Win32_OperatingSystem | Select-Object @{Name = "FreeGB"; Expression = { [math]::Round($_.FreePhysicalMemory / 1mb, 0) } }, @{Name = "TotalGB"; Expression = { [int]($_.TotalVisibleMemorySize / 1mb) } }
        $availableMemory = [math]::Round($(Get-AvailableMemoryGB), 0)
        $disk = Get-Volume -DriveLetter E
        $customOptions += [ordered]@{"*BREAK2" = "---  Manage Lab [Mem Free: $($availableMemory)GB/$($os.TotalGB)GB] [E: Free $([math]::Round($($disk.SizeRemaining/1GB),0))GB/$([math]::Round($($disk.Size/1GB),0))GB] [VMs Running: $vmsRunning/$vmsTotal]%cyan"; }
        $customOptions += [ordered]@{"R" = "Regenerate Rdcman file (memlabs.rdg) from Hyper-V config%gray%green" ; "D" = "Domain Hyper-V management (Start/Stop/Compact/Delete)%gray%green"; "P" = "Show Passwords" }

        $pendingCount = (get-list -type VM | Where-Object { $_.InProgress -eq "True" }).Count

        if ($pendingCount -gt 0 ) {
            $customOptions += @{"F" = "Delete ($($pendingCount)) Failed/In-Progress VMs (These may have been orphaned by a cancelled deployment)%Yellow%Yellow" }
        }
        Write-Host
        Write-Host -ForegroundColor cyan "---  Create Config"
        $response = Get-Menu -Prompt "Select menu option" -AdditionalOptions $customOptions -NoNewLine

        write-Verbose "1 response $response"
        if (-not $response) {
            continue
        }
        $SelectedConfig = $null
        switch ($response.ToLowerInvariant()) {
            "1" { $SelectedConfig = Select-NewDomainConfig }
            "2" { $SelectedConfig = Show-ExistingNetwork }
            "3" { $SelectedConfig = Select-Config $sampleDir -NoMore }
            "4" { $SelectedConfig = Select-Config $configDir -NoMore }
            "r" { New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$true }
            "f" { Select-DeletePending }
            "d" { Select-DomainMenu }
            "P" {
                Write-Host
                Write-Host "Password for all accounts is: " -NoNewline
                Write-Host -foregroundColor Green "$($Common.LocalAdmin.GetNetworkCredential().Password)"
                Write-Host
                get-list -type vm | Where-Object { $_.Role -eq "DC" } | ft domain, adminName , @{Name = "Password"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | out-host
            }
            Default {}
        }
        if ($SelectedConfig) {
            Write-Verbose "SelectedConfig : $SelectedConfig"
            return $SelectedConfig
        }
    }
}


function Select-DomainMenu {

    $domainList = @()
    foreach ($item in (Get-DomainList)) {
        $stats = Get-DomainStatsLine -DomainName $item

        $domainList += "$($item.PadRight(22," ")) $stats"
    }

    if ($domainList.Count -eq 0) {
        Write-Host
        Write-Host -ForegroundColor Red "No Domains found. Please delete VM's manually from hyper-v"

        return
    }

    $domainExpanded = Get-Menu -Prompt "Select existing domain" -OptionArray $domainList
    if ([string]::isnullorwhitespace($domainExpanded)) {
        return $null
    }
    $domain = ($domainExpanded -Split " ")[0]

    Write-Verbose "2 Select-DomainMenu"
    while ($true) {
        Write-Host
        Write-Host "Domain '$domain' contains these resources:"
        Write-Host
        $vmsInDomain = get-list -type vm  -DomainName $domain
        if (-not $vmsInDomain) {
            return
        }
        ($vmsInDomain | Select-Object VmName, State, Role, SiteCode, DeployedOS, MemoryStartupGB, DiskUsedGB, SqlVersion | Format-Table | Out-String).Trim() | out-host
        #get-list -Type VM -DomainName $domain | Format-Table | Out-Host

        $customOptions = [ordered]@{
            "1" = "Stop VMs in domain";
            "2" = "Start VMs in domain";
            "3" = "Compact all VHDX's in domain (requires domain to be stopped)";
            "S" = "Snapshot all VM's in domain"
        }
        $checkPoint = $null
        $DC = get-list -type vm  -DomainName $domain | Where-Object { $_.role -eq "DC" }
        if ($DC) {
            $checkPoint = Get-VMCheckpoint -VMName $DC.vmName -Name 'MemLabs Snapshot' -ErrorAction SilentlyContinue
        }
        if ($checkPoint) {
            $customOptions += [ordered]@{ "R" = "Restore all VM's to last snapshot"; "X" = "Delete (merge) domain Snapshots" }
        }
        $customOptions += [ordered]@{"D" = "Delete VMs in Domain%Yellow%Red" }
        $response = Get-Menu -Prompt "Select domain options" -AdditionalOptions $customOptions

        write-Verbose "1 response $response"
        if (-not $response) {
            return
        }

        switch ($response.ToLowerInvariant()) {
            "1" { Select-StopDomain -domain $domain }
            "2" { Select-StartDomain -domain $domain }
            "3" { select-OptimizeDomain -domain $domain }
            "d" {
                Select-DeleteDomain -domain $domain
                return
            }
            "s" { select-SnapshotDomain -domain $domain }
            "r" { select-RestoreSnapshotDomain -domain $domain }
            "x" { select-DeleteSnapshotDomain -domain $domain }
            Default {}
        }
    }
}


function select-SnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain
    )
    Write-Host
    Write-Host -ForegroundColor Yellow "It is reccommended to stop VM's before snapshotting. Please select which VM's to stop."
    Select-StopDomain -domain $domain
    $vms = get-list -type vm -DomainName $domain

    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    return
                }
                Write-Host "Checkpointing $($vm.VmName)"

                $notesFile = Join-Path (get-vm $($vm.VmName)).Path 'MemLabs.Notes.json'
                (get-vm $($vm.VmName)).notes | Out-File $notesFile


                Checkpoint-VM -Name $vm.VmName -SnapshotName 'MemLabs Snapshot' -ErrorAction Stop
                $complete = $true
            }
            catch {
                $tries++
                Start-Sleep 10

            }
        }
    }

    write-host
    Write-Host "$domain has been CheckPointed"

}

function select-RestoreSnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain
    )

    $vms = get-list -type vm -DomainName $domain
    $missingVMS = @()

    foreach ($vm in $vms) {
        $checkPoint = Get-VMCheckpoint -VMName $vm.vmName -Name 'MemLabs Snapshot' -ErrorAction SilentlyContinue | Sort-Object CreationTime | Select-Object -Last 1
        if (-not $checkPoint) {
            $missingVMS += $vm.VmName
        }
    }
    if ($missingVMS.Count -gt 0) {
        Write-Host
        $DeleteVMs = Read-Host2 -Prompt "The following VM's do not have checkpoints. [$($missingVMs -join ",")]  Delete them? (y/N)" -HideHelp
    }

    $startAll = Read-Host2 -Prompt "Start All vms after restore? (Y/n)" -HideHelp
    if ($startAll.ToLowerInvariant() -eq "n" -or $startAll.ToLowerInvariant() -eq "no") {
        $startAll = $null
    }
    else {
        $startAll = "A"
    }

    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    return
                }
                $checkPoint = Get-VMCheckpoint -VMName $vm.vmName -Name 'MemLabs Snapshot' -ErrorAction SilentlyContinue | Sort-Object CreationTime | Select-Object -Last 1

                if ($checkPoint) {
                    Write-Host "Restoring $($vm.VmName)"
                    $checkPoint | Restore-VMCheckpoint -Confirm:$false
                    $notesFile = Join-Path (get-vm $($vm.VmName)).Path 'MemLabs.Notes.json'
                    if (Test-Path $notesFile) {
                        $notes = Get-Content $notesFile
                        set-vm -VMName $vm.vmName -notes $notes
                    }

                }
                $complete = $true
            }
            catch {
                Start-Sleep 10
                $tries++

            }
        }
    }
    Get-List -FlushCache | out-null

    if ($missingVMS.Count -gt 0) {
        #Write-Host
        #$response2 = Read-Host2 -Prompt "The following VM's do not have checkpoints. [$($missingVMs -join ",")]  Delete them? (y/N)" -HideHelp
        if ($DeleteVMs.ToLowerInvariant() -eq "y" -or $DeleteVMs.ToLowerInvariant() -eq "yes") {
            foreach ($item in $missingVMS) {
                Remove-VirtualMachine -VmName $item
            }
            New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
        }

    }
    write-host
    Write-Host "$domain has been Restored"
    Select-StartDomain -domain $domain -response $startAll
}

function select-DeleteSnapshotDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To SnapShot")]
        [string] $domain
    )

    $vms = get-list -type vm -DomainName $domain

    foreach ($vm in $vms) {
        $complete = $false
        $tries = 0
        While ($complete -ne $true) {
            try {
                if ($tries -gt 10) {
                    return
                }
                $checkPoint = Get-VMCheckpoint -VMName $vm.vmName -Name 'MemLabs Snapshot' -ErrorAction SilentlyContinue

                if ($checkPoint) {
                    Write-Host "Merging $($vm.VmName)"
                    Remove-VMCheckpoint -VMName $vm.vmName -Name "MemLabs Snapshot"
                }
                $notesFile = Join-Path (get-vm $($vm.VmName)).Path 'MemLabs.Notes.json'
                if (Test-Path $notesFile) {
                    Remove-Item $notesFile -Force
                }
                $complete = $true
            }
            catch {
                Start-Sleep 10
                $tries++

            }
        }
    }

    write-host
    Write-Host "$domain has been CheckPointed"

}

function select-OptimizeDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain
    )
    select-StopDomain $domain

    $vms = get-list -type vm -DomainName $domain

    $size = (Get-List -type vm -domain $domain | measure-object -sum DiskUsedGB).sum
    write-Host "Total size of VMs in $domain before optimize: $([math]::Round($size,2))GB"
    foreach ($vm in $vms) {
        #Get-VHD -VMId $vm.VmId | Optimize-VHD -Mode Full
        foreach ($hd in Get-VHD -VMId $vm.VmId) {
            #    Mount-VHD -Path $hd.Path
            try {
                Mount-VHD -Path $hd.Path -ReadOnly -ErrorAction Stop
                Optimize-VHD -Path $hd.Path -Mode Full -ErrorAction Continue
            }
            finally {
                Dismount-VHD -Path $hd.Path
            }
        }
    }

    get-list -type VM -ResetCache | out-null
    $sizeAfter = (Get-List -type vm -domain $domain | measure-object -sum DiskUsedGB).sum
    write-Host "Total size of VMs in $domain after optimize: $([math]::Round($sizeAfter,2))GB"
    write-host
    Write-Host "$domain has been stopped and optimized. Make sure to restart the domain if neccessary."

}

function Select-StartDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain,
        [Parameter(Mandatory = $false, HelpMessage = "Prepopulate response")]
        [string] $response = $null
    )

    while ($true) {
        Write-Host

        $vms = get-list -type vm -DomainName $domain

        $notRunning = $vms | Where-Object { $_.State -ne "Running" }
        if ($notRunning -and ($notRunning | Measure-Object).count -gt 0) {
            Write-Host "$(($notRunning | Measure-Object).count) VM's in '$domain' are not Running"
        }
        else {
            Write-Host "All VM's in '$domain' are already Running"
            return
        }


        $vmsname = $notRunning | Select-Object -ExpandProperty vmName
        $customOptions = [ordered]@{"A" = "Start All VMs" ; "C" = "Start Critial VMs only (DC/SiteServers/Sql)" }
        while ($null -eq $response) {
            $response = Get-Menu -Prompt "Select VM to Start" -OptionArray $vmsname -AdditionalOptions $customOptions -Test:$false
            break
        }

        if ([string]::IsNullOrWhiteSpace($response)) {
            return
        }
        if ($response -eq "A" -or $response -eq "C") {
            $CriticalOnly = $false
            if ($response -eq "C") {
                $CriticalOnly = $true
            }
            $dc = $vms | Where-Object { $_.Role -eq "DC" }
            $sqlServers = $vms | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion }
            $cas = $vms | Where-Object { $_.Role -eq "CAS" }
            $pri = $vms | Where-Object { $_.Role -eq "Primary" }
            $other = $vms | Where-Object { $_.vmName -notin $dc.vmName -and $_.vmName -notin $sqlServers.vmName -and $_.vmName -notin $cas.vmName -and $_.vmName -notin $pri.vmName }

            $waitSecondsDC = 20
            $waitSeconds = 10
            if ($dc -and ($dc.State -ne "Running")) {
                write-host "DC [$($dc.vmName)] state is [$($dc.State)]. Starting VM and waiting $waitSecondsDC seconds before continuing"
                start-vm $dc.vmName
                start-Sleep -Seconds $waitSecondsDC
            }

            if ($sqlServers) {
                foreach ($sql in $sqlServers) {
                    if ($sql.State -ne "Running") {
                        write-host "SQL Server [$($sql.vmName)] state is [$($sql.State)]. Starting VM and waiting $waitSeconds seconds before continuing"
                        start-vm $sql.vmName
                    }
                }
                start-sleep $waitSeconds
            }

            if ($cas) {
                foreach ($ss in $cas) {
                    if ($ss.State -ne "Running") {
                        write-host "CAS [$($ss.vmName)] state is [$($ss.State)]. Starting VM and waiting $waitSeconds seconds before continuing"
                        start-vm $ss.vmName
                    }
                }
                start-sleep $waitSeconds
            }

            if ($pri) {
                foreach ($ss in $pri) {
                    if ($ss.State -ne "Running") {
                        write-host "Primary [$($ss.vmName)] state is [$($ss.State)]. Starting VM and waiting $waitSeconds seconds before continuing"
                        start-vm $ss.vmName
                    }
                }
                start-sleep $waitSeconds
            }
            if ($CriticalOnly -eq $false) {
                foreach ($vm in $other) {
                    if ($vm.State -ne "Running") {
                        write-host "VM [$($vm.vmName)] state is [$($vm.State)]. Starting VM"
                        start-job -Name $vm.vmName -ScriptBlock { param($vm) start-vm $vm } -ArgumentList $vm.vmName | Out-Null
                    }
                }
            }
            get-job | wait-job | out-null
            get-job | remove-job | out-null
            get-list -type VM -ResetCache | out-null
            if ($CriticalOnly -eq $false) {
                return
            }
            else {
                continue
            }
        }
        else {
            start-vm $response
            get-job | wait-job | out-null
            get-job | remove-job | out-null
            get-list -type VM -ResetCache | out-null
        }
    }
}

function Select-StopDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain
    )


    While ($true) {
        Write-Host
        $vms = get-list -type vm -DomainName $domain
        $running = $vms | Where-Object { $_.State -ne "Off" }
        if ($running -and ($running | Measure-Object).count -gt 0) {
            Write-host "$(($running| Measure-Object).count) VM's in '$domain' are currently running."
        }
        else {
            Write-host "All VM's in '$domain' are already turned off."
            return
        }

        $vmsname = $running | Select-Object -ExpandProperty vmName
        $customOptions = [ordered]@{"A" = "Stop All VMs" ; "C" = "Stop non-critical VMs (All except: DC/SiteServers/SQL)" }
        $response = Get-Menu -Prompt "Select VM to Stop" -OptionArray $vmsname -AdditionalOptions $customOptions -Test:$false

        if ([string]::IsNullOrWhiteSpace($response)) {
            return
        }
        if ($response -eq "A" -or $response -eq "C") {

            $nonCriticalOnly = $false
            if ($response -eq "C") {
                $nonCriticalOnly = $true
            }
            foreach ($vm in $vms) {
                if ($nonCriticalOnly -eq $true) {
                    if ($vm.Role -eq "CAS" -or $vm.Role -eq "Primary" -or $vm.Role -eq "DC" -or ($vm.Role -eq "DomainMember" -and $null -ne $vm.SqlVersion) ) {
                        continue
                    }
                }
                $vm2 = Get-VM $vm.vmName -ErrorAction SilentlyContinue
                if ($vm2.State -eq "Running") {
                    Write-Host "$($vm.vmName) is [$($vm2.State)]. Shutting down VM. Will forcefully stop after 5 mins"
                    start-job -Name $vm.vmName -ScriptBlock { param($vm) stop-vm $vm -force } -ArgumentList $vm.vmName | Out-Null
                }
            }
            get-job | wait-job | Out-Null
            get-job | remove-job | Out-Null
            get-list -type VM -ResetCache | out-null
            return
        }
        else {
            stop-vm $response -force
            get-job | wait-job | Out-Null
            get-job | remove-job | Out-Null
            get-list -type VM -ResetCache | out-null
        }

    }
}

function Select-DeleteDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain To Stop")]
        [string] $domain
    )

    while ($true) {
        $vms = get-list -type vm -DomainName $domain | Select-Object -ExpandProperty vmName
        if (-not $vms) {
            return
        }
        $customOptions = [ordered]@{"D" = "Delete All VMs" }
        $response = Get-Menu -Prompt "Select VM to Delete" -OptionArray $vms -AdditionalOptions $customOptions -Test:$false

        if ([string]::IsNullOrWhiteSpace($response)) {
            return
        }
        if ($response -eq "D") {
            Write-Host "Selecting 'Yes' will permantently delete all VMs and scopes."
            $response = Read-Host2 -Prompt "Are you sure? (y/N)" -HideHelp
            if (-not [String]::IsNullOrWhiteSpace($response)) {
                if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
                    Remove-Domain -DomainName $domain
                    Get-List -type VM -ResetCache | Out-Null
                    return
                }
            }
        }
        else {
            $response2 = Read-Host2 -Prompt "Delete VM $response? (Y/n)" -HideHelp

            if ($response2.ToLowerInvariant() -eq "n" -or $response2.ToLowerInvariant() -eq "no") {
                continue
            }
            else {
                Remove-VirtualMachine -VmName $response
                Get-List -type VM -ResetCache | Out-Null
                continue
            }
        }
    }
}

function Select-DeletePending {

    get-list -Type VM | Where-Object { $_.InProgress -eq "True" } | Format-Table | Out-Host
    Write-Host "Please confirm these VM's are not currently in process of being deployed."
    Write-Host "Selecting 'Yes' will permantently delete all VMs and scopes."
    $response = Read-Host2 -Prompt "Are you sure? (y/N)" -HideHelp
    if (-not [String]::IsNullOrWhiteSpace($response)) {
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            Remove-InProgress
            Get-List -type VM -ResetCache | Out-Null
        }
    }
}
function get-VMOptionsSummary {

    $options = $Global:Config.vmOptions
    $domainName = "[$($options.domainName)]".PadRight(21)
    $Output = "$domainName [Prefix $($options.prefix)] [Network $($options.network)] [Username $($options.adminName)] [Location $($options.basePath)]"
    return $Output
}

function get-CMOptionsSummary {

    $options = $Global:Config.cmOptions
    $ver = "[$($options.version)]".PadRight(21)
    $Output = "$ver [Install $($options.install)] [Update $($options.updateToLatest)] [DPMP $($options.installDPMPRoles)] [Push Clients $($options.pushClientToDomainMembers)]"
    return $Output
}

function get-VMSummary {

    $vms = $Global:Config.virtualMachines

    $numVMs = ($vms | Measure-Object).Count
    $numDCs = ($vms | Where-Object { $_.Role -eq "DC" } | Measure-Object).Count
    $numDPMP = ($vms | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count
    $numPri = ($vms | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
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

function Select-MainMenu {
    while ($true) {
        $preOptions = [ordered]@{}
        $preOptions += [ordered]@{ "*G" = "---  Global Options%cyan%cyan"; "V" = "Global VM Options `t $(get-VMOptionsSummary)%gray%green" }
        if ($Global:Config.cmOptions) {
            $preOptions += [ordered]@{"C" = "Global CM Options `t $(get-CMOptionsSummary)%gray%green" }
        }
        $preOptions += [ordered]@{ "*V1" = ""; "*V" = "---  Virtual Machines%cyan%cyan" }
        $customOptions = [ordered]@{}
        #$customOptions += @{"3" = "Virtual Machines `t`t $(get-VMSummary)" }

        $i = 0
        #$valid = Get-TestResult -SuccessOnError
        foreach ($virtualMachine in $global:config.virtualMachines) {

            $i = $i + 1
            $name = Get-VMString $virtualMachine
            $customOptions += [ordered]@{"$i" = "$name%white%green" }
            #write-Option "$i" "$($name)"
        }

        $customOptions += [ordered]@{ "N" = "New Virtual Machine%DarkGreen%Green"; "*D1" = ""; "*D" = "---  Deployment%cyan%cyan"; "S" = "Save Configuration and Exit%gray%green" }
        if ($InternalUseOnly.IsPresent) {
            $customOptions += [ordered]@{ "D" = "Deploy Config%Green%Green" }
        }
        if ($enableDebug) {
            $customOptions += [ordered]@{ "R" = "Return deployConfig" }
        }
        #write-Option -color DarkGreen -Color2 Green "N" "New Virtual Machine"

        $response = Get-Menu -Prompt "Select menu option" -OptionArray $optionArray -AdditionalOptions $customOptions -preOptions $preOptions -Test:$false
        write-Verbose "response $response"
        if (-not $response) {
            continue
        }
        switch ($response.ToLowerInvariant()) {
            "v" { Select-Options -Rootproperty $($Global:Config) -PropertyName vmOptions -prompt "Select Global Property to modify" }
            "c" { Select-Options -Rootproperty $($Global:Config) -PropertyName cmOptions -prompt "Select ConfigMgr Property to modify" }
            "d" { return $true }
            "s" { return $false }
            "r" { return Test-Configuration -InputObject $Global:Config }
            default { Select-VirtualMachines $response }
        }
    }
}

function Get-ValidSubnets {

    $subnetlist = @()
    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "192.168." + $i + ".0"
        $found = $false
        foreach ($subnet in (Get-SubnetList)) {
            if ($subnet.Subnet -eq $newSubnet) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            if ($subnetlist.Count -gt 2) {
                break
            }

        }

    }

    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "172.16." + $i + ".0"
        $found = $false
        foreach ($subnet in (Get-SubnetList)) {
            if ($subnet.Subnet -eq $newSubnet) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            if ($subnetlist.Count -gt 5) {
                break
            }

        }
    }

    for ($i = 1; $i -lt 254; $i++) {
        $newSubnet = "10.0." + $i + ".0"
        $found = $false
        foreach ($subnet in (Get-SubnetList)) {
            if ($subnet.Subnet -eq $newSubnet) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $subnetlist += $newSubnet
            if ($subnetlist.Count -gt 8) {
                break
            }
        }
    }
    return $subnetlist
}

function Get-NewMachineName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the new machine")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "OS of the new machine")]
        [String] $OS,
        [Parameter(Mandatory = $false, HelpMessage = "Site Code")]
        [String] $SiteCode,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )


    $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Measure-Object).Count
    $ConfigCount = ($ConfigToCheckvirtualMachines | Where-Object { $_.Role -eq $Role } | Measure-Object).count
    Write-Verbose "[Get-NewMachineName] found $RoleCount machines in HyperV with role $Role"
    $RoleName = $Role
    if ($Role -eq "OSDClient") {
        $RoleName = "OSD"
    }
    if ($Role -eq "DomainMember" -or [string]::IsNullOrWhiteSpace($Role) -or $Role -eq "WorkgroupMember" -or $Role -eq "AADClient" -or $role -eq "InternetClient") {
        if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
            $RoleName = "Mem"
        }
        else {
            $RoleName = "Member"
        }

        if ($OS -like "*Server*") {
            if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                $RoleName = "Srv"
            }
            else {
                $RoleName = "Server"
            }
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -like "*Server*" } | Measure-Object).Count
            $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -like "*Server*" } | Measure-Object).count
        }
        else {
            if (($ConfigToCheck.vmOptions.prefix.length) -gt 4) {
                $RoleName = "Cli"
            }
            else {
                $RoleName = "Client"
            }
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { -not ($_.deployedOS -like "*Server*") } | Measure-Object).Count
            $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { -not ($_.OperatingSystem -like "*Server*") } | Measure-Object).count

        }


        if ($Role -eq "WorkgroupMember") {
            $RoleName = "WG"
        }
        if ($Role -eq "InternetClient") {
            $RoleName = "INT"
        }
        if ($Role -eq "AADClient") {
            $RoleName = "AAD"
        }
        if ($Role -eq "FileServer") {
            $RoleName = "FS"
        }
        Write-Verbose "Rolename is now $RoleName"

        if ($OS -like "Windows 10*") {
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -like "Windows 10*" } | Measure-Object).Count
            $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -like "Windows 10*" } | Measure-Object).count
            $RoleName = "W10" + $RoleName
        }
        if ($OS -like "Windows 11*") {
            $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -like "Windows 11*" } | Measure-Object).Count
            $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -like "Windows 11*" } | Measure-Object).count
            $RoleName = "W11" + $RoleName
        }

        switch ($OS) {
            "Server 2022" {
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -eq "Server 2022" } | Measure-Object).Count
                $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -eq "Server 2022" } | Measure-Object).count
                $RoleName = "W22" + $RoleName
            }
            "Server 2019" {
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -eq "Server 2019" } | Measure-Object).Count
                $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -eq "Server 2019" } | Measure-Object).count
                $RoleName = "W19" + $RoleName
            }
            "Server 2016" {
                $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Where-Object { $_.deployedOS -eq "Server 2016" } | Measure-Object).Count
                $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Where-Object { $_.OperatingSystem -eq "Server 2016" } | Measure-Object).count
                $RoleName = "W16" + $RoleName
            }
            Default {}
        }
    }

    if (($role -eq "Primary") -or ($role -eq "CAS") -or ($role -eq "PassiveSite")) {
        if ([String]::IsNullOrWhiteSpace($SiteCode)) {
            $newSiteCode = Get-NewSiteCode $Domain -Role $Role
        }
        else {
            $newSiteCode = $SiteCode
        }
        $NewName = $newSiteCode + "SITE"
        if ($role -eq "PassiveSite") {
            $NewName = $NewName + "-P"
        }
        return $NewName
    }

    #if ($role -eq "DPMP") {
    #    $PSVM = $ConfigToCheck.VirtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1
    #    if ($PSVM -and $PSVM.SiteCode) {
    #        return $($PSVM.SiteCode) + $role
    #    }
    #}
    if ($Role -eq "FileServer") {
        $RoleName = "FS"
        $RoleCount = (get-list -Type VM -DomainName $Domain | Where-Object { $_.Role -eq $Role } | Measure-Object).Count
        $ConfigCount = ($ConfigToCheck.virtualMachines | Where-Object { $_.Role -eq $Role } | Measure-Object).count
    }
    Write-Verbose "[Get-NewMachineName] found $ConfigCount machines in Config with role $Role"
    $TotalCount = [int]$RoleCount + [int]$ConfigCount

    [int]$i = 1
    while ($true) {
        $NewName = $RoleName + ($TotalCount + $i)
        if ($null -eq $ConfigToCheck) {
            write-log "[Get-NewMachineName] Config is NULL..  Machine names will not be checked. Please notify someone of this bug."
            #break
        }
        if (($ConfigToCheck.virtualMachines | Where-Object { $_.vmName -eq $NewName } | Measure-Object).Count -eq 0) {

            $newNameWithPrefix = ($ConfigToCheck.vmOptions.prefix) + $NewName
            if ((Get-List -Type VM | Where-Object { $_.vmName -eq $newNameWithPrefix } | Measure-Object).Count -eq 0) {
                break
            }
        }
        $i++
    }
    return $NewName
}

function Get-NewSiteCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Role of the machine CAS/Primary")]
        [String] $Role
    )

    if ($Role -eq "CAS") {
        $NumberOfCAS = (Get-ExistingForDomain -DomainName $Domain -Role CAS | Measure-Object).Count
        #     if ($NumberOfCAS -eq 0) {
        #         return "CAS"
        #     }
        #else {
        return "CS" + ($NumberOfCAS + 1)
        #}
    }
    $NumberOfPrimaries = (Get-ExistingForDomain -DomainName $Domain -Role Primary | Measure-Object).Count
    #$NumberOfCas = (Get-ExistingForDomain -DomainName $Domain -Role CAS | Measure-Object).Count

    return "PS" + ($NumberOfPrimaries + 1)
}

function Get-ValidDomainNames {
    # Old List.. Some have netbios portions longer than 15 chars
    #$ValidDomainNames = [System.Collections.ArrayList]("adatum.com", "adventure-works.com", "alpineskihouse.com", "bellowscollege.com", "bestforyouorganics.com", "contoso.com", "contososuites.com",
    #   "consolidatedmessenger.com", "fabrikam.com", "fabrikamresidences.com", "firstupconsultants.com", "fourthcoffee.com", "graphicdesigninstitute.com", "humongousinsurance.com",
    #   "lamnahealthcare.com", "libertysdelightfulsinfulbakeryandcafe.com", "lucernepublishing.com", "margiestravel.com", "munsonspicklesandpreservesfarm.com", "nodpublishers.com",
    #   "northwindtraders.com", "proseware.com", "relecloud.com", "fineartschool.net", "southridgevideo.com", "tailspintoys.com", "tailwindtraders.com", "treyresearch.net", "thephone-company.com",
    #  "vanarsdelltd.com", "wideworldimporters.com", "wingtiptoys.com", "woodgrovebank.com", "techpreview.com" )

    #Trimmed list, only showing domains with 15 chars or less in netbios portion
    $ValidDomainNames = @{"adatum.com" = "ADA-" ; "adventure-works.com" = "ADV-" ; "alpineskihouse.com" = "ALP-" ; "bellowscollege.com" = "BLC-" ; "contoso.com" = "CON-" ; "contososuites.com" = "COS-" ;
        "fabrikam.com" = "FAB-" ; "fourthcoffee.com" = "FOR-" ;
        "lamnahealthcare.com" = "LAM-"  ; "margiestravel.com" = "MGT-" ; "nodpublishers.com" = "NOD-" ;
        "proseware.com" = "PRO-" ; "relecloud.com" = "REL-" ; "fineartschool.net" = "FAS-" ; "southridgevideo.com" = "SRV-" ; "tailspintoys.com" = "TST-" ; "tailwindtraders.com" = "TWT-" ; "treyresearch.net" = "TRY-";
        "vanarsdelltd.com" = "VAN-" ; "wingtiptoys.com" = "WTT-" ; "woodgrovebank.com" = "WGB-" ; "techpreview.com" = "TEC-"
    }
    foreach ($domain in (Get-DomainList)) {
        $ValidDomainNames.Remove($domain.ToLowerInvariant())
    }

    $usedPrefixes = Get-List -Type UniquePrefix
    foreach ($dname in $ValidDomainNames.Keys) {
        foreach ($usedPrefix in $usedPrefixes) {
            if ($ValidDomainNames[$dname].ToLowerInvariant() -eq $usedPrefix.ToLowerInvariant()) {
                Write-Verbose ("Removing $dname")
                $ValidDomainNames.Remove($dname)
            }
        }
    }
    return $ValidDomainNames
}


function get-PrefixForDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain
    )

    $existingDomains = get-list -Type UniqueDomain
    if ($existingDomains -contains $Domain) {
        $existingPrefix = (Get-List -type VM -DomainName $domain | Where-Object { $_.Role -eq "DC" }).Prefix

        if (-not [string]::IsNullOrWhiteSpace($existingPrefix)) {
            return $existingPrefix
        }
    }
    $ValidDomainNames = Get-ValidDomainNames
    $prefix = $($ValidDomainNames[$domain])
    if ([String]::IsNullOrWhiteSpace($prefix)) {
        $prefix = ($domain.ToUpper().SubString(0, 3) + "-") -replace "\.", ""
    }
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    return $prefix

}
function select-NewDomainName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [Object] $ConfigToCheck = $global:config
    )
    if ($ConfigToCheck.virtualMachines.role -contains "DC") {
        while ($true) {
            $ValidDomainNames = Get-ValidDomainNames

            $domain = $null
            $customOptions = @{ "C" = "Custom Domain" }

            while (-not $domain) {
                $domain = Get-Menu -Prompt "Select Domain" -OptionArray $($ValidDomainNames.Keys | Sort-Object { $_.length }) -additionalOptions $customOptions -CurrentValue ((Get-ValidDomainNames).Keys | sort-object { $_.Length } | Select-Object -first 1) -Test:$false
                if ($domain.ToLowerInvariant() -eq "c") {
                    $domain = Read-Host2 -Prompt "Enter Custom Domain Name:"
                }
                if ($domain.Length -lt 3) {
                    $domain = $null
                }
            }
            if ((get-list -Type UniqueDomain) -contains $domain.ToLowerInvariant()) {
                Write-Host
                Write-Host -ForegroundColor Red "Domain is already in use. Please use the Expand option to expand the domain"
                continue
            }
            return $domain
        }
    }
    else {
        $existingDomains = @()
        $existingDomains += get-list -Type UniqueDomain
        if ($existingDomains.count -eq 0) {
            Write-Host
            Write-Host "No DC configured, and no existing domains found. Please Ctrl-C to start over and create a new domain"
            return
        }
        $domain = $null
        while (-not $domain) {
            $domain = Get-Menu -Prompt "Select Domain" -OptionArray $existingDomains -CurrentValue $ConfigToCheck.vmoptions.domainName -test:$false
        }
        return $domain
    }
}



function Select-NewDomainConfig {

    $subnetlist = Get-ValidSubnets

    $valid = $false
    while ($valid -eq $false) {

        $customOptions = [ordered]@{ "1" = "CAS and Primary%gray%green"; "2" = "Primary Site only%gray%green"; "3" = "Tech Preview (NO CAS)%red%green" ; "4" = "No ConfigMgr%yellow%green"; }
        $response = $null
        while (-not $response) {
            $response = Get-Menu -Prompt "Select ConfigMgr Options" -AdditionalOptions $customOptions
            if ([string]::IsNullOrWhiteSpace($response)) {
                return
            }
        }

        $CASJson = Join-Path $sampleDir "Hierarchy.json"
        $PRIJson = Join-Path $sampleDir "Standalone.json"
        $NoCMJson = Join-Path $sampleDir "NoConfigMgr.json"
        $TPJson = Join-Path $sampleDir "TechPreview.json"
        switch ($response.ToLowerInvariant()) {
            "1" { $newConfig = Get-Content $CASJson -Force | ConvertFrom-Json }
            "2" { $newConfig = Get-Content $PRIJson -Force | ConvertFrom-Json }
            "3" {
                $newConfig = Get-Content $TPJson -Force | ConvertFrom-Json
                $usedPrefixes = Get-List -Type UniquePrefix
                if ("CTP-" -notin $usedPrefixes) {
                    $prefix = "CTP-"
                }
            }
            "4" { $newConfig = Get-Content $NoCMJson -Force | ConvertFrom-Json }
        }
        #Dummy Values that are likely not to be already used to pass intial validation.
        $newConfig.vmOptions.domainName = "TEMPLATE2222.com"
        $newConfig.vmOptions.network = "10.234.241.0"
        $newConfig.vmOptions.prefix = "z4w"
        $valid = Get-TestResult -Config $newConfig -SuccessOnWarning

        if ($valid) {
            $valid = $false
            while ($valid -eq $false) {
                $domain = select-NewDomainName -ConfigToCheck $newConfig
                if (-not $prefix) {
                    $prefix = get-PrefixForDomain -Domain $domain
                }
                Write-Verbose "Prefix = $prefix"
                $newConfig.vmOptions.domainName = $domain
                $newConfig.vmOptions.prefix = $prefix
                $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
            }
        }

        if ($valid) {
            $valid = $false
            while ($valid -eq $false) {
                $customOptions = @{ "C" = "Custom Subnet" }
                $network = $null
                while (-not $network) {
                    $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist -additionalOptions $customOptions -CurrentValue ($subnetList | Select-Object -First 1)
                    if ($network.ToLowerInvariant() -eq "c") {
                        $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
                    }
                }
                $newConfig.vmOptions.network = $network
                $valid = Get-TestResult -Config $newConfig -SuccessOnWarning
            }
        }
    }
    return $newConfig
}

# Gets the json files from the config\samples directory, and offers them up for selection.
# if 'M' is selected, shows the json files from the config directory.
function Select-Config {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Directory to look for .json files")]
        [string] $ConfigPath,
        # -NoMore switch will hide the [M] More options when we go into the submenu
        [Parameter(Mandatory = $false, HelpMessage = "will hide the [M] More options when we go into the submenu")]
        [switch] $NoMore
    )
    $files = @()
    $files += Get-ChildItem $ConfigPath\*.json -Include "Standalone.json", "Hierarchy.json" | Sort-Object -Property Name -Descending
    $files += Get-ChildItem $ConfigPath\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "NoConfigMgr.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $ConfigPath\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json", "NoConfigMgr.json" | Sort-Object -Descending -Property CreationTime
    $responseValid = $false

    while ($responseValid -eq $false) {
        $i = 0
        foreach ($file in $files) {
            $i = $i + 1
            Write-Option $i $($file.Name)
        }
        if (-Not $NoMore.IsPresent) {
            Write-Option "M" "Show More (Custom and Previous config files)" -color DarkGreen -Color2 Green
            Write-Option "E" "Expand existing network" -color DarkGreen -Color2 Green

        }

        Write-Host
        Write-Verbose "3 Select-Config"
        $response = Read-Host2 -Prompt "Which config do you want to deploy"
        try {
            if ([int]$response -is [int]) {
                if ([int]$response -le [int]$i -and [int]$response -gt 0 ) {
                    $responseValid = $true
                }
            }
        }
        catch {}
        if (-Not $NoMore.IsPresent) {
            if ($response.ToLowerInvariant() -eq "m") {
                $configSelected = Select-Config $configDir -NoMore
                if (-not ($null -eq $configSelected)) {
                    return $configSelected
                }
                $i = 0
                foreach ($file in $files) {
                    $i = $i + 1
                    write-Host "[$i] $($file.Name)"
                }
                if (-Not $NoMore.IsPresent) {
                    Write-Option "M" "Show More (Custom and Previous config files)" -color DarkGreen -Color2 Green
                    Write-Option "E" "Expand existing network" -color DarkGreen -Color2 Green
                }
            }
            if ($response.ToLowerInvariant() -eq "e") {
                $newConfig = Show-ExistingNetwork
                if ($newConfig) {
                    return $newConfig
                }
            }
        }
        else {
            if ($response -eq "") {
                return $null
            }
        }
    }
    $Global:configfile = $files[[int]$response - 1]
    $configSelected = Get-Content $Global:configfile -Force | ConvertFrom-Json
    if ($null -ne $configSelected.vmOptions.domainAdminName) {
        if ($null -eq ($configSelected.vmOptions.adminName)) {
            $configSelected.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $configSelected.vmOptions.domainAdminName
        }
        $configSelected.vmOptions.PsObject.properties.Remove('domainAdminName')
    }

    return $configSelected
}

Function Get-DomainStatsLine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [string]$DomainName
    )
    $stats = ""
    $ExistingCasCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
    $ExistingPriCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
    $ExistingDPMPCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count
    $ExistingSQLCount = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion } | Measure-Object).Count
    $ExistingSubnetCount = (Get-List -Type VM -Domain $DomainName | Select-Object -Property Subnet -unique | measure-object).Count
    $TotalVMs = (Get-List -Type VM -Domain $DomainName | Measure-Object).Count
    $TotalRunningVMs = (Get-List -Type VM -Domain $DomainName | Where-Object { $_.State -ne "Off" } | Measure-Object).Count
    $TotalMem = (Get-List -Type VM -Domain $DomainName | Measure-Object -Sum MemoryGB).Sum
    $TotalMaxMem = (Get-List -Type VM -Domain $DomainName | Measure-Object -Sum MemoryStartupGB).Sum
    $TotalDiskUsed = (Get-List -Type VM -Domain $DomainName | Measure-Object -Sum DiskUsedGB).Sum
    $stats += "[$TotalRunningVMs/$TotalVMs Running VMs, Mem: $($TotalMem.ToString().PadLeft(2," "))GB/$($TotalMaxMem)GB Disk: $([math]::Round($TotalDiskUsed,2))GB]"
    if ($ExistingCasCount -gt 0) {
        $stats += "[CAS VMs: $ExistingCasCount] "
    }
    if ($ExistingPriCount -gt 0) {
        $stats += "[Primary VMs: $ExistingPriCount] "
    }
    if ($ExistingSQLCount -gt 0) {
        $stats += "[SQL VMs: $ExistingSQLCount] "
    }
    if ($ExistingDPMPCount -gt 0) {
        $stats += "[DPMP Vms: $ExistingDPMPCount] "
    }

    if ([string]::IsNullOrWhiteSpace($stats)) {
        $stats = "[No ConfigMgr Roles installed] "
    }

    if ($ExistingSubnetCount -gt 0) {
        $stats += "[Number of Networks: $ExistingSubnetCount] "
    }
    return $stats
}



function Show-ExistingNetwork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $Global:AddToExisting = $true

    $domainList = @()

    foreach ($item in (Get-DomainList)) {
        $stats = Get-DomainStatsLine -DomainName $item

        $domainList += "$($item.PadRight(22," ")) $stats"
    }

    if ($domainList.Count -eq 0) {
        Write-Host
        Write-Host -ForegroundColor Red "No Domains found. Please deploy a new domain"

        return
    }

    while ($true) {
        $domainExpanded = Get-Menu -Prompt "Select existing domain" -OptionArray $domainList
        if ([string]::isnullorwhitespace($domainExpanded)) {
            return $null
        }
        $domain = ($domainExpanded -Split " ")[0]

        get-list -Type VM -DomainName $domain | Format-Table -Property vmname, Role, SiteCode, DeployedOS, MemoryStartupGB, @{Label = "DiskUsedGB"; Expression = { [Math]::Round($_.DiskUsedGB, 2) } }, State, Domain, Subnet, SQLVersion | Out-Host

        $response = Read-Host2 -Prompt "Add new VMs to this domain? (Y/n)" -HideHelp
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                continue
            }
            else {
                break
            }
        }
        else { break }

    }

    $TotalStoppedVMs = (Get-List -Type VM -Domain $domain | Where-Object { $_.State -ne "Running" -and ($_.Role -eq "CAS" -or $_.Role -eq "Primary" -or $_.Role -eq "DC") } | Measure-Object).Count
    if ($TotalStoppedVMs -gt 0) {
        $response = Read-Host2 -Prompt "$TotalStoppedVMs Critical VM's in this domain are not running. Do you wish to start them now? (Y/n)" -HideHelp
        if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
        }
        else {
            Select-StartDomain -domain $domain
        }

    }
    [string]$role = Select-RolesForExisting


    if ($role -eq "H") {
        $role = "PassiveSite"
    }

    if ($role -eq "Primary") {
        $ExistingCasCount = (Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
        if ($ExistingCasCount -gt 0) {

            $existingSiteCodes = @()
            $existingSiteCodes += (Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "CAS" }).SiteCode
            #$existingSiteCodes += ($global:config.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode

            $additionalOptions = @{ "X" = "No Parent - Standalone Primary" }
            $result = Get-Menu -Prompt "Select CAS sitecode to connect primary to:" -OptionArray $existingSiteCodes -CurrentValue $value -additionalOptions $additionalOptions -Test $false
            if ($result.ToLowerInvariant() -eq "x") {
                $ParentSiteCode = $null
            }
            else {
                $ParentSiteCode = $result
            }
            Get-TestResult -SuccessOnError | out-null
        }
    }

    if ($role -eq "PassiveSite") {
        $existingPassive = Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "PassiveSite" }
        $existingSS = Get-List -Type VM -Domain $domain | Where-Object { $_.Role -eq "CAS" -or $_.Role -eq "Primary" }

        $PossibleSS = @()
        foreach ($item in $existingSS) {
            if ($existingPassive.SiteCode -contains $item.Sitecode) {
                continue
            }
            $PossibleSS += $item
        }

        if ($PossibleSS.Count -eq 0) {
            Write-Host
            Write-Host "No siteservers found that are elegible for HA"
            return
        }
        $result = Get-Menu -Prompt "Select sitecode to expand to HA" -OptionArray $PossibleSS.Sitecode -Test $false
        if ([string]::IsNullOrWhiteSpace($result)) {
            return
        }
        $SiteCode = $result
    }

    [string]$subnet = (Get-List -type VM -DomainName $domain | Where-Object { $_.Role -eq "DC" } | Select-Object -First 1).Subnet
    if ($role -ne "InternetClient" -and $role -ne "AADClient" -and $role -ne "PassiveSite") {
        $subnet = Select-ExistingSubnets -Domain $domain -Role $role
        Write-verbose "[Show-ExistingNetwork] Subnet returned from Select-ExistingSubnets '$subnet'"
        if ([string]::IsNullOrWhiteSpace($subnet)) {
            return $null
        }
    }
    Write-verbose "[Show-ExistingNetwork] Calling Get-ExistingConfig '$domain' '$subnet' '$role' '$SiteCode'"
    $newConfig = Get-ExistingConfig -Domain $domain -Subnet $subnet -role $role -ParentSiteCode $ParentSiteCode -SiteCode $Sitecode
    return $newConfig
}
function Select-RolesForExistingList {
    $existingRoles = $Common.Supported.RolesForExisting | Where-Object { $_ -ne "PassiveSite" }
    return $existingRoles
}

function Select-RolesForNewList {
    $Roles = $Common.Supported.Roles | Where-Object { $_ -ne "PassiveSite" }
    return $Roles
}

function Format-Roles{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Roles Array")]
        [object]$Roles
    )

    $newRoles = @()

    $padding = 22
    foreach ($role in $Roles){
        switch ($role){
            "CAS and Primary" { $newRoles += "$($role.PadRight($padding))`t[New CAS and Primary Site]"}
            "Primary" { $newRoles += "$($role.PadRight($padding))`t[New Primary site (Standalone or join a CAS)]"}
            "FileServer" { $newRoles += "$($role.PadRight($padding))`t[New File Server]"}
            "DPMP" { $newRoles += "$($role.PadRight($padding))`t[New DP/MP for an existing Primary Site]"}
            "DomainMember (Server)" { $newRoles += "$($role.PadRight($padding))`t[New VM with Server OS joined to the domain]"}
            "DomainMember (Client)" { $newRoles += "$($role.PadRight($padding))`t[New VM with Client OS joined to the domain]"}
            "WorkgroupMember" { $newRoles += "$($role.PadRight($padding))`t[New VM in workgroup with Internet Access]"}
            "InternetClient" { $newRoles += "$($role.PadRight($padding))`t[New VM in workgroup with Internet Access, isolated from the domain]"}
            "AADClient" { $newRoles += "$($role.PadRight($padding))`t[New VM that boots to OOBE, allowing AAD join from OOBE]"}
            "OSDClient" { $newRoles += "$($role.PadRight($padding))`t[New bare VM without any OS]"}
        }
    }

    return $newRoles

}

function Select-RolesForExisting {
    $existingRoles = Select-RolesForExistingList

    $existingRoles2 = @()

    foreach ($item in $existingRoles) {

        switch ($item) {
            "CAS" { $existingRoles2 += "CAS and Primary" }
            "DomainMember" {
                $existingRoles2 += "DomainMember (Server)"
                $existingRoles2 += "DomainMember (Client)"
            }
            "PassiveSite" {}
            Default { $existingRoles2 += $item }
        }
    }

    $existingRoles2 = Format-Roles $existingRoles2

    $OptionArray = @{ "H" = "Convert an existing CAS or Primary to HA" }

    $role = Get-Menu -Prompt "Select Role to Add" -OptionArray $($existingRoles2) -CurrentValue "DomainMember" -additionalOptions $OptionArray

    $role = $role.Split("[").Trim()
    if ($role -eq "CAS and Primary") {
        $role = "CAS"
    }

    return $role

}

function Select-RolesForNew {
    [System.Collections.ArrayList]$existingRoles = [System.Collections.ArrayList]($Common.Supported.Roles)
    if ($global:config.VirtualMachines.role -contains "DC") {
        $existingRoles.Remove("DC")
    }
    if ($global:config.VirtualMachines.role -contains "Primary") {
        $existingRoles.Remove("Primary")
    }
    if ($global:config.VirtualMachines.role -contains "CAS") {
        $existingRoles.Remove("CAS")
    }
    # if ($global:config.VirtualMachines.role -contains "DPMP") {
    #     $existingRoles.Remove("DPMP")
    # }
    $existingRoles.Remove("PassiveSite")
    $role = Get-Menu -Prompt "Select Role to Add" -OptionArray $($existingRoles) -CurrentValue "DomainMember"
    return $role
}

function Select-OSForNew {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [String] $Role
    )

    $defaultValue = "Server 2022"
    if (($Role -eq "DomainMember") -or ($null -eq $Role) -or ($Role -eq "WorkgroupMember") -or ($Role -eq "InternetClient") ) {
        $OSList = $Common.Supported.OperatingSystems
    }
    else {
        $OSList = $Common.Supported.OperatingSystems | Where-Object { $_ -like "*Server*" }
    }

    if ($Role -eq "InternetClient") {
        $defaultValue = "Windows 10 Latest (64-bit)"
    }
    if ($Role -eq "AADClient") {
        $OSList = $Common.Supported.OperatingSystems | Where-Object { -not ( $_ -like "*Server*" ) }
        $defaultValue = "Windows 10 Latest (64-bit)"
    }
    $role = Get-Menu -Prompt "Select OS" -OptionArray $($OSList) -CurrentValue $defaultValue
    return $role
}

function Select-Subnet {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $configToCheck = $global:config
    )

    if ($configToCheck.virtualMachines.role -contains "DC") {
        $subnetlist = Get-ValidSubnets
        $customOptions = @{ "C" = "Custom Subnet" }
        $network = $null
        while (-not $network) {
            $network = Get-Menu -Prompt "Select Network" -OptionArray $subnetlist -additionalOptions $customOptions -Test:$false -CurrentValue ($configToCheck.vmOptions.network)
            if ($network.ToLowerInvariant() -eq "c") {
                $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
            }
        }
        $response = [string]$network
        return $response
    }
    else {
        $domain = $configToCheck.vmOptions.DomainName
        return Select-ExistingSubnets -Domain $domain -ConfigToCheck $configToCheck
    }



}


function Select-ExistingSubnets {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $false, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "config")]
        [object] $ConfigToCheck
    )

    $valid = $false
    if ($ConfigToCheck) {
        $Role = "DomainMember"
        if ($configToCheck.virtualMachines.role -contains "Primary") {
            $Role = "Primary"
        }
        if ($configToCheck.virtualMachines.role -contains "CAS") {
            $Role = "CAS"
        }
    }
    while ($valid -eq $false) {

        $customOptions = @{ "N" = "add New Subnet to domain" }
        $subnetList = @()
        $subnetList += Get-SubnetList -DomainName $Domain | Select-Object -Expand Subnet | Get-Unique

        $subnetListNew = @()
        if ($Role -eq "Primary" -or $Role -eq "CAS") {
            foreach ($subnet in $subnetList) {
                # If a subnet has a Primary or a CAS in it.. we can not add either.
                $existingRolePri = Get-ExistingForSubnet -Subnet $subnet -Role Primary
                $existingRoleCAS = Get-ExistingForSubnet -Subnet $subnet -Role CAS
                if ($null -eq $existingRolePri -and $null -eq $existingRoleCAS) {
                    $subnetListNew += $subnet
                }
            }
        }
        else {
            $subnetListNew = $subnetList
        }

        $subnetListModified = @()
        foreach ($sb in $subnetListNew) {
            if ($sb -eq "Internet") {
                continue
            }
            $SiteCodes = get-list -Type VM -Domain $domain | Where-Object { $null -ne $_.SiteCode -and ($_.Role -eq "Primary" -or $_.Role -eq "CAS") } | Group-Object -Property Subnet | Select-Object Name, @{l = "SiteCode"; e = { $_.Group.SiteCode -join "," } } | Where-Object { $_.Name -eq $sb }  | Select-Object -expand SiteCode
            if ([string]::IsNullOrWhiteSpace($SiteCodes)) {
                $subnetListModified += "$sb"
            }
            else {
                $subnetListModified += "$sb ($SiteCodes)"
            }
        }

        while ($true) {
            [string]$response = $null

            $CurrentValue = $null
            if ($configToCheck) {
                $Currentvalue = $configToCheck.vmOptions.network
            }
            if ($subnetListModified.Length -eq 0) {
                Write-Host
                Write-Host -ForegroundColor Yellow "No valid subnets for the current roles exist in the domain. Please create a new subnet"
                $response = "n"
            }
            else {
                $response = Get-Menu -Prompt "Select existing subnet" -OptionArray $subnetListModified -AdditionalOptions $customOptions -test:$false -CurrentValue $CurrentValue
            }
            write-Verbose "[Select-ExistingSubnets] Get-menu response $response"
            if ([string]::IsNullOrWhiteSpace($response)) {
                Write-Verbose "[Select-ExistingSubnets] Subnet response = null"
                continue
            }
            write-Verbose "response $response"
            $response = $response -Split " " | Select-Object -First 1
            write-Verbose "Sanitized response '$response'"

            if ($response.ToLowerInvariant() -eq "n") {

                $subnetlist = Get-ValidSubnets
                $customOptions = @{ "C" = "Custom Subnet" }
                $network = $null
                while (-not $network) {
                    $network = Get-Menu -Prompt "Select New Network" -OptionArray $subnetlist -additionalOptions $customOptions -Test:$false -CurrentValue $($subnetList | Select-Object -First 1)
                    if ($network.ToLowerInvariant() -eq "c") {
                        $network = Read-Host2 -Prompt "Enter Custom Subnet (eg 192.168.1.0):"
                    }
                }
                $response = [string]$network
                break

            }
            else {
                write-Verbose "Sanitized response was not 'N' it was '$response'"
                break
            }
        }
        $valid = Get-TestResult -Config (Get-ExistingConfig -Domain $Domain -Subnet $response -Role $Role -test:$true) -SuccessOnWarning
    }
    Write-Verbose "[Select-ExistingSubnets] Subnet response = $response"
    return [string]$response
}

function Get-ExistingConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $true, HelpMessage = "Subnet Name")]
        [string] $Subnet,
        [Parameter(Mandatory = $true, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Site code, if we are deploying a primary in a heirarchy")]
        [string] $ParentSiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site code, if we are deploying PassiveSite")]
        [string] $SiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site code, if we are deploying PassiveSite")]
        [bool] $test = $false

    )


    $adminUser = (Get-List -Type vm -DomainName $Domain | Where-Object { $_.Role -eq "DC" }).adminName

    if ([string]::IsNullOrWhiteSpace($adminUser)) {
        $adminUser = "admin"
    }

    Write-Verbose "[Get-ExistingConfig] Generating $Domain $Subnet $role $ParentSiteCode"

    #    $prefix = Get-List -Type UniquePrefix -Domain $Domain | Select-Object -First 1
    $prefix = get-PrefixForDomain -Domain $Domain
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = "NULL-"
    }
    $vmOptions = [PSCustomObject]@{
        prefix     = $prefix
        basePath   = "E:\VirtualMachines"
        domainName = $Domain
        adminName  = $adminUser
        network    = $Subnet
    }
    Write-Verbose "[Get-ExistingConfig] vmOptions: $vmOptions"
    $configGenerated = $null
    $configGenerated = [PSCustomObject]@{
        #cmOptions       = $newCmOptions
        vmOptions       = $vmOptions
        virtualMachines = $()
    }
    Write-Verbose "[Get-ExistingConfig] Config: $configGenerated $($configGenerated.vmOptions.domainName)"
    Add-NewVMForRole -Role $Role -Domain $Domain -ConfigToModify $configGenerated -ParentSiteCode $ParentSiteCode -SiteCode $SiteCode -Quiet:$true -test:$test
    Write-Verbose "[Get-ExistingConfig] Config: $configGenerated"
    return $configGenerated
}

# Replacement for Read-Host that offers a colorized prompt
function Read-Host2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "shows current value in []")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Dont display the help before the prompt")]
        [switch] $HideHelp
    )
    if (-not $HideHelp.IsPresent) {
        write-help
    }
    Write-Host -ForegroundColor Cyan $prompt -NoNewline
    if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
        Write-Host " [" -NoNewline
        Write-Host -ForegroundColor yellow $currentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    Write-Host " : " -NoNewline
    $response = Read-Host
    return $response
}

# Offers a menu for any array passed in.
# This is used for Sql Versions, Roles, Etc
function Get-Menu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Array of objects to display a menu from")]
        [object] $OptionArray,
        [Parameter(Mandatory = $false, HelpMessage = "The default if enter is pressed")]
        [string] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Additional Menu options, in dictionary format.. X = Exit")]
        [object] $additionalOptions = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Pre Menu options, in dictionary format.. X = Exit")]
        [object] $preOptions = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true,
        [Parameter(Mandatory = $false, HelpMessage = "Supress newline")]
        [switch] $NoNewLine
    )

    if (!$NoNewLine) {
        write-Host
        Write-Verbose "4 Get-Menu"
    }

    if ($null -ne $preOptions) {
        foreach ($item in $preOptions.keys) {
            $value = $preOptions."$($item)"
            $color1 = "DarkGreen"
            $color2 = "Green"

            #Write-Host -ForegroundColor DarkGreen [$_] $value
            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                }
                if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                    $color2 = $TextValue[2]
                }
                if ($item.StartsWith("*")) {
                    write-host -ForeGroundColor $color1 $TextValue[0]
                    continue
                }
                Write-Option $item $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }


    $i = 0

    foreach ($option in $OptionArray) {
        $i = $i + 1
        if (-not [String]::IsNullOrWhiteSpace($option)) {
            Write-Option $i $option
        }
    }

    if ($null -ne $additionalOptions) {
        foreach ($item in $additionalOptions.keys) {
            $value = $additionalOptions."$($item)"

            $color1 = "DarkGreen"
            $color2 = "Green"

            #Write-Host -ForegroundColor DarkGreen [$_] $value
            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $color1 = $TextValue[1]
                }
                if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                    $color2 = $TextValue[2]
                }
                if ($item.StartsWith("*")) {
                    write-host -ForeGroundColor $color1 $TextValue[0]
                    continue
                }
                Write-Option $item $TextValue[0] -color $color1 -Color2 $color2
            }
        }
    }
    $totalOptions = $preOptions + $additionalOptions

    $response = get-ValidResponse -Prompt $Prompt -max $i -CurrentValue $CurrentValue -AdditionalOptions $totalOptions -TestBeforeReturn:$Test

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $i = 0
        foreach ($option in $OptionArray) {
            $i = $i + 1
            if ($i -eq $response) {
                Write-Verbose "[Get-Menu] Returned (O) '$option'"
                return $option
            }
        }
        Write-Verbose "[Get-Menu] Returned (R) '$response'"
        return $response
    }
    else {
        Write-Verbose "[Get-Menu] Returned (CV) '$CurrentValue'"
        return $CurrentValue
    }
}

#Checks if the response from the menu was valid.
# Prompt is the prompt to display
# Max is the max int allowed [1], [2], [3], etc
# The current value of the option
# additionalOptions , like [N] New VM, [S] Add SQL, either as a single letter in a string, or keys in a dictionary.
function get-ValidResponse {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $true, HelpMessage = "Max # to be valid.  If your Menu is 1-5, 5 is the max. Higher numbers will fail")]
        [int] $max,
        [Parameter(Mandatory = $false, HelpMessage = "Current value will be returned if enter is pressed")]
        [string] $currentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Extra Valid entries that allow escape.. EG X = Exit")]
        [object] $additionalOptions,
        [switch]
        $AnyString,
        [Parameter(Mandatory = $false, HelpMessage = "Run a test-Configuration before exiting")]
        [switch] $TestBeforeReturn

    )

    $responseValid = $false
    while ($responseValid -eq $false) {
        Write-Host
        Write-Verbose "5 get-ValidResponse"
        $response = Read-Host2 -Prompt $prompt $currentValue
        try {
            if ([String]::IsNullOrWhiteSpace($response)) {
                $responseValid = $true
            }
            else {
                try {
                    if ([int]$response -is [int]) {
                        if ([int]$response -le [int]$max -and [int]$response -gt 0 ) {
                            $responseValid = $true
                        }
                    }
                }
                catch {}
            }
            if ($responseValid -eq $false -and $null -ne $additionalOptions) {
                try {
                    if ($response.ToLowerInvariant() -eq $additionalOptions.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
                catch {}

                foreach ($i in $($additionalOptions.keys)) {
                    if ($response.ToLowerInvariant() -eq $i.ToLowerInvariant()) {
                        $responseValid = $true
                    }
                }
            }
            if ($responseValid -eq $false -and $currentValue -is [bool]) {
                if ($currentValue.ToLowerInvariant() -eq "true" -or $currentValue.ToLowerInvariant() -eq "false") {
                    $responseValid = $false
                    if ($response.ToLowerInvariant() -eq "true") {
                        $response = $true
                        $responseValid = $true
                    }
                    if ($response.ToLowerInvariant() -eq "false") {
                        $response = $false
                        $responseValid = $true
                    }
                }
            }
        }
        catch {}
        if ($TestBeforeReturn.IsPresent -and $responseValid) {
            $responseValid = Get-TestResult -SuccessOnError
        }
    }
    #Write-Host "Returning: $response"
    return $response
}

Function Get-OperatingSystemMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select OS Version" $($Common.Supported.OperatingSystems) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-ParentSiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $valid = $false
    while ($valid -eq $false) {
        $casSiteCodes = Get-ValidCASSiteCodes -config $global:config

        $additionalOptions = @{ "X" = "No Parent - Standalone Primary" }
        $result = Get-Menu -Prompt "Select CAS sitecode to connect primary to:" -OptionArray $casSiteCodes -CurrentValue $CurrentValue -additionalOptions $additionalOptions -Test:$false
        if ($result.ToLowerInvariant() -eq "x") {
            $property."$name" = $null
        }
        else {
            $property."$name" = $result
        }
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}


Function Get-SiteCodeMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [Object] $ConfigToCheck = $global:config
    )
    $valid = $false
    #Get-PSCallStack | out-host
    while ($valid -eq $false) {
        $siteCodes = @()
        $tempSiteCode = ($ConfigToCheck.VirtualMachines | Where-Object { $_.role -eq "Primary" } | Select-Object -first 1).SiteCode
        if (-not [String]::IsNullOrWhiteSpace($tempSiteCode)) {
            $siteCodes += $tempSiteCode
        }
        $siteCodes += Get-ExistingSiteServer -DomainName $ConfigToCheck.vmOptions.domainName -Role "Primary" | Select-Object -ExpandProperty SiteCode -Unique
        if ($siteCodes.Length -eq 0) {
            Write-Host
            write-host "No valid site codes are eligible to accept this DPMP"
            return
        }
        else {
            #write-host $siteCodes
        }
        $result = $null
        while (-not $result) {
            $result = Get-Menu -Prompt "Select sitecode to connect DPMP to" -OptionArray $siteCodes -CurrentValue $CurrentValue -Test:$false
        }
        if ($result.ToLowerInvariant() -eq "x") {
            $property."$name" = $null
        }
        else {
            $property | Add-Member -MemberType NoteProperty -Name $name -Value $result -Force
            #$property."$name" = $result
        }
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}

Function Get-SqlVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select SQL Version" $($Common.Supported.SqlVersions) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $CurrentValue) {
                return
            }
        }
    }
}


Function Set-SiteServerLocalSql {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine
    )

    if ($null -eq $virtualMachine.sqlVersion) {
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL"
    }
    $virtualMachine.virtualProcs = 8
    $virtualMachine.memory = "12GB"

    if ($null -eq $virtualMachine.additionalDisks) {
        $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "100GB" }
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
    }
    else {

        if ($null -eq $virtualMachine.additionalDisks.E) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "E" -Value "250GB"
        }
        if ($null -eq $virtualMachine.additionalDisks.F) {
            $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name "F" -Value "100GB"
        }
    }

    if ($null -ne $virtualMachine.remoteSQLVM) {
        $SQLVM = $virtualMachine.remoteSQLVM
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
        Remove-VMFromConfig -vmName $SQLVM -Config $global:config

    }

}

Function Set-SiteServerRemoteSQL {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Site Server VM Object")]
        [Object] $virtualMachine,
        [Parameter(Mandatory = $true, HelpMessage = "VmName")]
        [string] $vmName
    )

    if ($null -ne $virtualMachine.sqlVersion) {
        $virtualMachine.PsObject.Members.Remove('sqlVersion')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceName')
        $virtualMachine.PsObject.Members.Remove('sqlInstanceDir')
    }
    $virtualMachine.memory = "4GB"
    $virtualMachine.virtualProcs = 4
    if ($null -ne $virtualMachine.additionalDisks.F) {
        $virtualMachine.additionalDisks.PsObject.Members.Remove('F')
    }
    if ($null -ne $virtualMachine.remoteSQLVM) {
        $virtualMachine.PsObject.Members.Remove('remoteSQLVM')
    }
    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'remoteSQLVM' -Value $vmName
}

Function Get-remoteSQLVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $false, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $false, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $additionalOptions = @{ "L" = "Local SQL" }

        $validVMs = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "DomainMember" -and $null -ne $_.SqlVersion } | Select-Object -ExpandProperty vmName

        $CASVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "CAS" }
        $PRIVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }

        if ($Property.Role -eq "CAS") {
            if ($null -ne $PRIVM.remoteSQLVM) {
                #Write-Verbose "Checking "
                $validVMs = $validVMs | Where-Object { $_ -ne $PRIVM.remoteSQLVM }
            }
        }
        if ($Property.Role -eq "Primary") {
            if ($null -ne $CASVM.remoteSQLVM) {
                $validVMs = $validVMs | Where-Object { $_ -ne $CASVM.remoteSQLVM }
            }
        }

        if (($validVMs | Measure-Object).Count -eq 0) {
            $additionalOptions += @{ "N" = "Create a New SQL VM" }
        }
        $result = Get-Menu "Select Remote SQL VM, or Select Local" $($validVMs) $CurrentValue -Test:$false -additionalOptions $additionalOptions

        switch ($result.ToLowerInvariant()) {
            "l" {
                Set-SiteServerLocalSql $property
            }
            "n" {
                $name = $($property.SiteCode) + "SQL"
                Add-NewVMForRole -Role "SQLServer" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $name
                Set-SiteServerRemoteSQL $property $name
            }
            Default {
                if ([string]::IsNullOrWhiteSpace($result)) {
                    continue
                }
                Set-SiteServerRemoteSQL $property $result
            }
        }
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($null -ne $name) {
                if ($property."$name" -eq $CurrentValue) {
                    return
                }
            }
        }
    }
}

Function Get-CMVersionMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        $property."$name" = Get-Menu "Select ConfigMgr Version" $($Common.Supported.CmVersions) $CurrentValue -Test:$false
        if (Get-TestResult -SuccessOnWarning -NoNewLine) {
            return
        }
        else {
            if ($property."$name" -eq $value) {
                return
            }
        }
    }
}
Function Get-RoleMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )

    $valid = $false
    while ($valid -eq $false) {
        if ($Global:AddToExisting -eq $true) {
            $role = Get-Menu "Select Role" $(Select-RolesForExistingList) $CurrentValue -Test:$false
            $property."$name" = $role
        }
        else {
            $role = Get-Menu "Select Role" $(Select-RolesForNewList) $CurrentValue -Test:$false
            $property."$name" = $role
        }

        # If the value is the same.. Dont delete and re-create the VM
        if ($property."$name" -eq $value) {
            # return false if the VM object is still viable.
            return $false
        }

        # In order to make sure the default params like SQLVersion, CMVersion are correctly applied.  Delete the VM and re-create with the same name.
        Remove-VMFromConfig -vmName $property.vmName -ConfigToModify $global:config
        Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config -Name $property.vmName -Quiet:$true

        # We cant do anything with the test result, as our underlying object is no longer in config.
        Get-TestResult -config $global:config -SuccessOnWarning -NoNewLine | out-null

        # return true if the VM is deleted.
        return $true
    }
}

function Get-AdditionalValidations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Base Property Object")]
        [Object] $property,
        [Parameter(Mandatory = $true, HelpMessage = "Name of Notefield to Modify")]
        [string] $name,
        [Parameter(Mandatory = $true, HelpMessage = "Current value")]
        [Object] $CurrentValue
    )
    $value = $property."$($Name)"
    #$name = $($item.Name)
    Write-Verbose "[Get-AdditionalValidations] Prop:'$property' Name:'$name' Current:'$CurrentValue' New:'$value'"
    switch ($name) {
        "E" {
            if (-not $value.EndsWith("GB" -and -not $value.EndsWith("MB"))) {
                if ($CurrentValue.EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
        }
        "F" {
            if (-not $value.EndsWith("GB" -and -not $value.EndsWith("MB"))) {
                if ($CurrentValue.EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
        }
        "G" {
            if (-not $value.EndsWith("GB" -and -not $value.EndsWith("MB"))) {
                if ($CurrentValue.EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
        }
        "memory" {
            if (-not $value.EndsWith("GB" -and -not $value.EndsWith("MB"))) {
                if ($CurrentValue.EndsWith("GB")) {
                    $property.$name = $value.Trim() + "GB"
                }
                if ($CurrentValue.EndsWith("MB")) {
                    $property.$name = $value.Trim() + "MB"
                }
            }
        }
        "vmName" {

            $CASVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "CAS" }
            $PRIVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }

            $Passive = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "PassiveSite" }

            #This is a SQL Server being renamed.  Lets check if we need to update CAS or PRI
            if (($Property.Role -eq "DomainMember") -and ($null -ne $Property.sqlVersion)) {
                if (($null -ne $PRIVM.remoteSQLVM) -and $PRIVM.remoteSQLVM -eq $CurrentValue) {
                    $PRIVM.remoteSQLVM = $value
                }
                if (($null -ne $CASVM.remoteSQLVM) -and ($CASVM.remoteSQLVM -eq $CurrentValue)) {
                    $CASVM.remoteSQLVM = $value
                }
            }

            if ($Property.Role -eq "FileServer" -and $null -ne $Passive) {
                if ($Passive.remoteContentLibVM -eq $CurrentValue) {
                    $Passive.remoteContentLibVM = $value
                }
            }
        }
        "siteCode" {
            if ($property.RemoteSQLVM) {
                $newSQLName = $value + "SQL"
                #Check if the new name is already in use:
                $NewSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newSQLName }
                if ($NewSQLVM) {
                    write-host
                    write-host -ForegroundColor Red "Changing Sitecode would rename SQL VM to " -NoNewline
                    write-host -ForegroundColor Yellow $($NewSQLVM.vmName) -NoNewline
                    write-host -ForegroundColor Red " which already exists. Unable to change sitecode."
                    $property.siteCode = $CurrentValue
                    return
                }
            }

            $newName = Get-NewMachineName -Domain $Global:Config.vmOptions.DomainName -Role $property.role -OS $property.operatingSystem -ConfigToCheck $Global:Config -SiteCode $value
            $NewSSName = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $newName }
            if ($NewSSName) {
                write-host
                write-host -ForegroundColor Red "Changing Sitecode would rename VM to " -NoNewline
                write-host -ForegroundColor Yellow $($NewSSName.vmName) -NoNewline
                write-host -ForegroundColor Red " which already exists. Unable to change sitecode."
                $property.siteCode = $CurrentValue
                return
            }
            #Set the SQL Name after all checks are done.
            if ($property.RemoteSQLVM) {
                $RemoteSQLVM = $Global:Config.virtualMachines | Where-Object { $_.vmName -eq $($property.RemoteSQLVM) }
                $RemoteSQLVM.vmName = $newSQLName
                $property.RemoteSQLVM = $newSQLName
            }
            $property.vmName = $newName
            Write-Verbose "New Name: $newName"
            if ($property.role -eq "CAS") {
                $PRIVM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "Primary" }
                if ($PRIVM) {
                    $PRIVM.ParentSiteCode = $value
                }
            }
            if ($property.role -eq "Primary") {
                $VM = $Global:Config.virtualMachines | Where-Object { $_.Role -eq "DPMP" }
                if ($VM) {
                    if ($VM.siteCode -eq $CurrentValue ) {
                        $VM.SiteCode = $value
                    }
                }
            }
        }
    }
}


function Get-SortedProperties {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Property to Sort")]
        [object] $property
    )

    $Sorted = @()
    $members = $property | Get-Member -MemberType NoteProperty

    if ($members.Name -contains "domainName") {
        $sorted += "domainName"
    }
    if ($members.Name -contains "prefix") {
        $sorted += "prefix"
    }
    if ($members.Name -contains "network") {
        $sorted += "network"
    }
    if ($members.Name -contains "adminName") {
        $sorted += "adminName"
    }
    if ($members.Name -contains "basePath") {
        $sorted += "basePath"
    }

    if ($members.Name -contains "vmName") {
        $sorted += "vmName"
    }
    if ($members.Name -contains "role") {
        $sorted += "role"
    }
    if ($members.Name -contains "memory") {
        $sorted += "memory"
    }
    if ($members.Name -contains "virtualProcs") {
        $sorted += "virtualProcs"
    }
    if ($members.Name -contains "operatingSystem") {
        $sorted += "operatingSystem"
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
    if ($members.Name -contains "remoteSQLVM") {
        $sorted += "remoteSQLVM"
    }
    if ($members.Name -contains "cmInstallDir") {
        $sorted += "cmInstallDir"
    }
    if ($members.Name -contains "parentSiteCode") {
        $sorted += "parentSiteCode"
    }
    if ($members.Name -contains "siteCode") {
        $sorted += "siteCode"
    }
    if ($members.Name -contains "remoteContentLibVM") {
        $sorted += "remoteContentLibVM"
    }

    if ($members.Name -contains "additionalDisks") {
        $sorted += "additionalDisks"
    }

    switch ($members.Name) {
        "vmName" {  }
        "role" {  }
        "memory" { }
        "virtualProcs" { }
        "operatingSystem" {  }
        "siteCode" { }
        "parentSiteCode" { }
        "sqlVersion" { }
        "sqlInstanceName" {  }
        "sqlInstanceDir" { }
        "additionalDisks" { }
        "cmInstallDir" { }
        "domainName" { }
        "prefix" { }
        "network" { }
        "adminName" { }
        "basePath" { }
        "remoteSQLVM" {}
        "remoteContentLibVM" {}

        Default { $sorted += $_ }
    }
    return $sorted
}

# Displays a Menu based on a property, offers options in [1], [2],[3] format
# With additional options passed in via additionalOptions
function Select-Options {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Root of Property to Enumerate and automatically display a menu")]
        [object] $Rootproperty,
        [Parameter(Mandatory = $false, HelpMessage = "Property name")]
        [object] $propertyName,
        [Parameter(Mandatory = $false, HelpMessage = "Property to enumerate.. Can be used instead of RootProperty and propertyName")]
        [object] $propertyEnum,
        [Parameter(Mandatory = $false, HelpMessage = "If Property is an array.. find this element to work on (Base = 1).")]
        [object] $propertyNum,
        [Parameter(Mandatory = $true, HelpMessage = "Prompt to display")]
        [string] $prompt,
        [Parameter(Mandatory = $false, HelpMessage = "Append additional Items to menu.. Eg X = Exit")]
        [PSCustomObject] $additionalOptions,
        [Parameter(Mandatory = $false, HelpMessage = "Run a configuration test. Default True")]
        [bool] $Test = $true
    )

    $property = $null
    :MainLoop   while ($true) {
        if ($null -eq $property -and $null -ne $Rootproperty) {
            $property = $Rootproperty."$propertyName"
        }

        if ($null -ne $propertyNum) {
            $i = 0;
            while ($true) {
                if ($i -eq [int]($propertyNum - 1)) {
                    $property = $propertyEnum[$i]
                    break
                }
                $i = $i + 1
            }
        }

        if ($null -eq $property) {
            $property = $propertyEnum
        }

        Write-Host
        Write-Verbose "6 Select-Options '$property' Root: '$Rootproperty' Name: '$propertyName' Enum: '$propertyEnum' Num '$propertyNum'"
        $i = 0
        #Write-Host "Trying to get $property"
        if ($null -eq $property) {
            return $null
        }

        # Get the Property Names and Values.. Present as Options.
        foreach ($item in (Get-SortedProperties $property)) {
            $i = $i + 1
            $value = $property."$($item)"
            #$padding = 27 - ($i.ToString().Length)
            $padding = 26
            Write-Option $i "$($($item).PadRight($padding," "")) = $value"
        }

        if ($null -ne $additionalOptions) {
            foreach ($item in $additionalOptions.keys) {
                $value = $additionalOptions."$($item)"

                $color1 = "DarkGreen"
                $color2 = "Green"

                #Write-Host -ForegroundColor DarkGreen [$_] $value
                if (-not [String]::IsNullOrWhiteSpace($item)) {
                    $TextValue = $value -split "%"

                    if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                        $color1 = $TextValue[1]
                    }
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $color2 = $TextValue[2]
                    }
                    if ($item.StartsWith("*")) {
                        write-host -ForegroundColor $color1 $TextValue[0]
                        continue
                    }
                    Write-Option $item $TextValue[0] -color $color1 -Color2 $color2
                }
            }
        }
        $response = get-ValidResponse $prompt $i $null $additionalOptions
        if ([String]::IsNullOrWhiteSpace($response)) {
            return
        }

        $return = $null
        if ($null -ne $additionalOptions) {
            foreach ($item in $($additionalOptions.keys)) {
                if ($response.ToLowerInvariant() -eq $item.ToLowerInvariant()) {
                    # Return fails here for some reason. If the values were the same, let the user escape, as no changes were made.
                    $return = $item
                }
            }
        }
        #Return here instead.
        if ($null -ne $return) {
            return $return
        }
        # We got the [1] Number pressed. Lets match that up to the actual value.
        $i = 0
        foreach ($item in (Get-SortedProperties $property)) {

            $i = $i + 1

            if (-not ($response -eq $i)) {
                continue
            }

            $value = $property."$($item)"
            $name = $($item)

            switch ($name) {
                "operatingSystem" {
                    Get-OperatingSystemMenu -property $property -name $name -CurrentValue $value
                    if ($property.role -eq "DomainMember") {
                        if (-not $property.SqlVersion) {
                            $property.vmName = Get-NewMachineName -Domain $Global:Config.vmOptions.DomainName -Role $property.role -OS $property.operatingSystem -ConfigToCheck $Global:Config
                        }
                    }
                    continue MainLoop
                }
                "remoteContentLibVM" {
                    $property.remoteContentLibVM = select-FileServerMenu -HA:$true
                    continue MainLoop
                }
                "domainName" {
                    $domain = select-NewDomainName
                    $property.domainName = $domain
                    $property.prefix = get-PrefixForDomain -Domain $domain
                    Get-TestResult -SuccessOnError | out-null
                    continue MainLoop
                }
                "network" {
                    $network = Select-Subnet
                    $property.network = $network
                    Get-TestResult -SuccessOnError | out-null
                    continue MainLoop
                }
                "ParentSiteCode" {
                    Get-ParentSiteCodeMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }
                "sqlVersion" {
                    Get-SqlVersionMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }
                "remoteSQLVM" {
                    Get-remoteSQLVM -property $property -name $name -CurrentValue $value
                    return "REFRESH"
                }
                "siteCode" {
                    if ($property.role -eq "PassiveSite") {
                        write-host
                        write-host -ForegroundColor Yellow "siteCode can not be manually modified on a Passive server."
                        continue MainLoop
                    }
                    if ($property.role -eq "DPMP") {
                        Get-SiteCodeMenu -property $property -name $name -CurrentValue $value
                        continue MainLoop
                    }
                }
                "role" {
                    if ($property.role -eq "PassiveSite") {
                        write-host
                        write-host -ForegroundColor Yellow "role can not be manually modified on a Passive server. Please disable HA or delete the VM."
                        continue MainLoop
                    }
                    if (Get-RoleMenu -property $property -name $name -CurrentValue $value) {
                        Write-Host -ForegroundColor Yellow "VirtualMachine object was re-created with new role. Taking you back to VM Menu."
                        # VM was deleted.. Lets get outta here.
                        return
                    }
                    else {
                        #VM was not deleted.. We can still edit other properties.
                        continue MainLoop
                    }
                }
                "version" {
                    Get-CMVersionMenu -property $property -name $name -CurrentValue $value
                    continue MainLoop
                }
            }
            # If the property is another PSCustomObject, recurse, and call this function again with the inner object.
            # This is currently only used for AdditionalDisks
            if ($value -is [System.Management.Automation.PSCustomObject]) {
                Select-Options -Rootproperty $property -PropertyName "$Name" -Prompt "Select data to modify" | out-null
            }
            else {
                #The option was not a known name with its own menu, and it wasnt another PSCustomObject.. We can edit it directly.
                $valid = $false
                Write-Host
                Write-Verbose "7 Select-Options"
                while ($valid -eq $false) {
                    if ($value -is [bool]) {
                        $response2 = Get-Menu -Prompt "Select new Value for $($Name)" -CurrentValue $value -OptionArray @("True", "False") -NoNewLine -Test:$false
                    }
                    else {
                        $response2 = Read-Host2 -Prompt "Select new Value for $($Name)" $value
                    }
                    if (-not [String]::IsNullOrWhiteSpace($response2)) {
                        if ($property."$($Name)" -is [Int]) {
                            $property."$($Name)" = [Int]$response2
                        }
                        else {
                            if ($value -is [bool]) {
                                if ($([string]$value).ToLowerInvariant() -eq "true" -or $([string]$value).ToLowerInvariant() -eq "false") {
                                    if ($response2.ToLowerInvariant() -eq "true") {
                                        $response2 = $true
                                    }
                                    elseif ($response2.ToLowerInvariant() -eq "false") {
                                        $response2 = $false
                                    }
                                    else {
                                        $response2 = $value
                                    }
                                }

                            }

                            Write-Verbose ("$_ name = $($_.Name) or $name = $response2 value = '$value'")
                            $property."$($Name)" = $response2
                        }
                        Get-AdditionalValidations -property $property -name $Name -CurrentValue $value
                        if ($Test) {
                            $valid = Get-TestResult -SuccessOnWarning
                        }
                        else {
                            $valid = $true
                        }
                        if ($response2 -eq $value) {
                            $valid = $true
                        }

                    }
                    else {
                        # Enter was pressed. Set the Default value, and test, but dont block.
                        $property."$($Name)" = $value
                        $valid = Get-TestResult -SuccessOnError
                    }
                }
            }
        }
    }
}

Function Get-TestResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if warnings are present")]
        [switch] $SuccessOnWarning,
        [Parameter(Mandatory = $false, HelpMessage = "Returns true even if errors are present")]
        [switch] $SuccessOnError,
        [Parameter(Mandatory = $false, HelpMessage = "Config to check")]
        [object] $config = $Global:Config,
        [Parameter(Mandatory = $false, HelpMessage = "Supress newline")]
        [switch] $NoNewLine
    )
    #If Config hasnt been generated yet.. Nothing to test
    if ($null -eq $config) {
        return $true
    }
    try {
        $c = Test-Configuration -InputObject $Config
        $valid = $c.Valid
        if ($valid -eq $false) {
            Write-Host -ForegroundColor Red "`r`n$($c.Message)"
            if (!$NoNewLine) {
                write-host
            }
            #$MyInvocation | Out-Host
            if ($enableVerbose) {
                Get-PSCallStack | out-host
            }
        }
        if ($SuccessOnWarning.IsPresent) {
            if ( $c.Failures -eq 0) {
                $valid = $true
            }
        }
        if ($SuccessOnError.IsPresent) {
            $valid = $true
        }
    }
    catch {
        return $true
    }
    return $valid
}

function get-VMString {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VirtualMachine Object from config")]
        [object] $virtualMachine
    )

    $machineName = $($($Global:Config.vmOptions.Prefix) + $($virtualMachine.vmName)).PadRight(19, " ")
    $name = "$machineName " + $("[" + $($virtualmachine.role) + "]").PadRight(16, " ")
    $mem = $($virtualMachine.memory).PadLEft(4, " ")
    $procs = $($virtualMachine.virtualProcs).ToString().PadLeft(2, " ")
    $name += " VM [$mem RAM,$procs CPU, $($virtualMachine.OperatingSystem)"

    if ($virtualMachine.additionalDisks) {
        $name += ", $($virtualMachine.additionalDisks.psobject.Properties.Value.count) Extra Disk(s)]"
    }
    else {
        $name += "]"
    }

    if ($virtualMachine.siteCode -and $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.ParentSiteCode) {
            $SiteCode += "->$($virtualMachine.ParentSiteCode)"
        }
        $name += "  CM [SiteCode $SiteCode ($($virtualMachine.cmInstallDir))]"
    }

    if ($virtualMachine.siteCode -and -not $virtualMachine.cmInstallDir) {
        $SiteCode = $virtualMachine.siteCode
        if ($virtualMachine.ParentSiteCode) {
            $SiteCode += "->$($virtualMachine.ParentSiteCode)"
        }
        $name += "  CM [SiteCode $SiteCode]"
    }

    if ($virtualMachine.remoteSQLVM) {
        $name += "  Remote SQL [$($virtualMachine.remoteSQLVM)]"
    }

    if ($virtualMachine.sqlVersion -and -not $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion)]"
    }

    if ($virtualMachine.sqlVersion -and $virtualMachine.sqlInstanceDir) {
        $name += "  SQL [$($virtualMachine.sqlVersion), "
        $name += "$($virtualMachine.sqlInstanceName) ($($virtualMachine.sqlInstanceDir))]"
    }

    return "$name"
}

function Add-NewVMForRole {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Role")]
        [String] $Role,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name")]
        [String] $Domain,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config,
        [Parameter(Mandatory = $false, HelpMessage = "Force VM Name. Otherwise auto-generated")]
        [string] $Name = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Parent Side Code if this is a Primary in a Heirarchy")]
        [string] $ParentSiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Site Code if this is a PassiveSite or a DPMP")]
        [string] $SiteCode = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Override default OS")]
        [string] $OperatingSystem = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Return Created Machine Name")]
        [bool] $ReturnMachineName = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet Mode")]
        [bool] $Quiet = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Test Mode")]
        [bool] $test = $false
    )


    $oldConfig = $configToModify | ConvertTo-Json -Depth 3 | ConvertFrom-Json
    Write-Verbose "[Add-NewVMForRole] Start Role: $Role Domain: $Domain Config: $ConfigToModify OS: $OperatingSystem"

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        if ($role -eq "WorkgroupMember" -or $role -eq "AADClient" -or $role -eq "InternetClient") {
            $operatingSystem = "Windows 10 Latest (64-bit)"
        }
        else {
            $OperatingSystem = "Server 2022"
        }
    }
    $actualRoleName = ($Role -split " ")[0]

    if ($role -eq "SQLServer") {
        $actualRoleName = "DomainMember"
    }

    $memory = "2GB"
    $vprocs = 2

    if ($OperatingSystem.Contains("Server")) {
        $memory = "4GB"
        $vprocs = 4
    }
    $virtualMachine = [PSCustomObject]@{
        vmName          = $null
        role            = $actualRoleName
        operatingSystem = $OperatingSystem
        memory          = $memory
        virtualProcs    = $vprocs
    }
    $existingPrimary = $null
    $existingDPMP = $null
    $NewFSServer = $null
    switch ($Role) {
        "SQLServer" {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "E:\SQL"
            $disk = [PSCustomObject]@{"E" = "120GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            $virtualMachine.Memory = "8GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
        }
        "CAS" {
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr"
            $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "120GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            $newSiteCode = Get-NewSiteCode $Domain -Role $actualRoleName
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode
            $virtualMachine.Memory = "12GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
            $existingPrimary = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Measure-Object).Count
            $existingPrimaryVM = $ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1
            if ($existingPrimaryVM) {
                $existingPrimaryVM | Add-Member -MemberType NoteProperty -Name 'parentSiteCode' -Value $newSiteCode -Force
            }
        }
        "Primary" {
            $existingCAS = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Measure-Object).Count
            if ([string]::IsNullOrWhiteSpace($ParentSiteCode)) {
                $ParentSiteCode = $null
                if ($existingCAS -eq 1) {
                    $ParentSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode
                }
            }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'ParentSiteCode' -Value $ParentSiteCode
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "F:\SQL"
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value "E:\ConfigMgr"
            $disk = [PSCustomObject]@{"E" = "250GB"; "F" = "120GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            $newSiteCode = Get-NewSiteCode $Domain -Role $actualRoleName
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $newSiteCode
            $virtualMachine.Memory = "12GB"
            $virtualMachine.virtualProcs = 8
            $virtualMachine.operatingSystem = $OperatingSystem
            $existingDPMP = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "DPMP" } | Measure-Object).Count

        }
        "PassiveSite" {
            $virtualMachine.memory = "4GB"
            $NewFSServer = $true
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'SiteCode' -Value $SiteCode
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'cmInstallDir' -Value 'E:\ConfigMgr'
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
        }
        "WorkgroupMember" {}
        "InternetClient" {}
        "AADClient" {}
        "DomainMember" { }
        "DomainMember (Server)" { }
        "DomainMember (Client)" {
            if ($OperatingSystem -like "*Server*") {
                $virtualMachine.operatingSystem = "Windows 10 Latest (64-bit)"
            }
            else {
                $virtualMachine.operatingSystem = $OperatingSystem
            }
            $virtualMachine.Memory = "2GB"
        }
        "OSDClient" {
            $virtualMachine.memory = "2GB"
            $virtualMachine.PsObject.Members.Remove('operatingSystem')
        }
        "DPMP" {
            $virtualMachine.memory = "3GB"
            $disk = [PSCustomObject]@{"E" = "250GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
            if (-not $SiteCode) {
                $SiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).SiteCode
                if ($test) {
                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
                }
                else {
                    Get-SiteCodeMenu -property $virtualMachine -name "siteCode" -CurrentValue $SiteCode -ConfigToCheck $configToModify
                }
            }
            else {
                write-log "Adding new DPMP for sitecode $newSiteCode"
                $virtualMachine | Add-Member -MemberType NoteProperty -Name 'siteCode' -Value $SiteCode -Force
            }
        }
        "FileServer" {
            $virtualMachine.memory = "3GB"
            $disk = [PSCustomObject]@{"E" = "500GB"; "F" = "200GB" }
            $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
        }
        "DC" { }
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $machineName = Get-NewMachineName $Domain $actualRoleName -OS $virtualMachine.OperatingSystem -SiteCode $SiteCode -ConfigToCheck $oldConfig
        Write-Verbose "Machine Name Generated $machineName"
    }
    else {
        $machineName = $Name
    }
    $virtualMachine.vmName = $machineName

    if ($null -eq $ConfigToModify.VirtualMachines) {
        $ConfigToModify.virtualMachines = @()
    }

    $ConfigToModify.virtualMachines += $virtualMachine

    if ($role -eq "Primary" -or $role -eq "CAS" -or $role -eq "PassiveSite" -or $role -eq "DPMP") {
        if ($null -eq $ConfigToModify.cmOptions) {
            $newCmOptions = [PSCustomObject]@{
                version                   = "current-branch"
                install                   = $true
                updateToLatest            = $false
                installDPMPRoles          = $true
                pushClientToDomainMembers = $true
            }
            $ConfigToModify | Add-Member -MemberType NoteProperty -Name 'cmOptions' -Value $newCmOptions
        }
    }

    if ($existingPrimary -eq 0) {
        Add-NewVMForRole -Role Primary -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -Quiet:$Quiet
    }

    if ($existingPrimary -gt 0) {
        ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "CAS" } | Select-Object -First 1).SiteCode
    }

    if ($existingDPMP -eq 0) {
        if (-not $newSiteCode) {
            $newSiteCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).SiteCode
        }
        write-log "Adding new DPMP for sitecode $newSiteCode"
        Add-NewVMForRole -Role DPMP -Domain $Domain -ConfigToModify $ConfigToModify -OperatingSystem $OperatingSystem -SiteCode $newSiteCode -Quiet:$Quiet
    }
    if ($NewFSServer -eq $true) {
        #Get-PSCallStack | out-host
        $FSName = select-FileServerMenu -ConfigToModify $ConfigToModify -HA:$true
        $virtualMachine | Add-Member -MemberType NoteProperty -Name 'remoteContentLibVM' -Value $FSName
    }
    #Get-PSCallStack | out-host
    if (-not $Quiet) {
        Write-Host -ForegroundColor Yellow "New Virtual Machine $machineName ($role) was added"
    }
    Write-verbose "[Add-NewVMForRole] Config: $ConfigToModify"
    if ($ReturnMachineName) {
        return $machineName
    }
}

function select-FileServerMenu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Display HA message")]
        [bool] $HA = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Config to Modify")]
        [object] $ConfigToModify = $global:config
    )
    $result = $null
    if ((Get-ListOfPossibleFileServers -Config $ConfigToModify).Count -eq 0) {
        $result = "n"
    }

    $additionalOptions = @{}
    if ($HA) {
        $additionalOptions += @{ "N" = "Create new FileServer to host Content Library" }
    }
    else {
        $additionalOptions += @{ "N" = "Create a New FileServer VM" }
    }
    while ([string]::IsNullOrWhiteSpace($result)) {
        $result = Get-Menu "Select FileServer VM" $(Get-ListOfPossibleFileServers -Config $ConfigToModify) -Test:$false -additionalOptions $additionalOptions
    }
    switch ($result.ToLowerInvariant()) {
        "n" {
            $result = Add-NewVMForRole -Role "FileServer" -Domain $ConfigToModify.vmOptions.DomainName -ConfigToModify $ConfigToModify -ReturnMachineName:$true
        }
    }
    return $result
}
function Get-ListOfPossibleFileServers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Config")]
        [object] $Config = $global:config
    )
    $FSList = @()
    $FS = $Config.virtualMachines | Where-Object { $_.role -eq "FileServer" }
    foreach ($item in $FS) {
        $FSList += $item.vmName
    }
    $domain = $Config.vmOptions.DomainName
    if ($null -ne $domain) {
        $FSFromList = get-list -type VM -domain $domain | Where-Object { $_.role -eq "FileServer" }
        foreach ($item in $FSFromList) {
            $FSList += $item.vmName
        }
    }
    else {
        if ($null -ne $Config ) {
            Write-Verbose $Config | ConvertTo-Json | Out-Host
        }
        else {
            write-host "Config was null!"
            Get-PSCallStack | Out-Host
        }
    }
    return $FSList
}


function Select-VirtualMachines {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "pre supplied response")]
        [string] $response = $null
    )
    while ($true) {
        Write-Host
        Write-Verbose "8 Select-VirtualMachines"
        if (-not $response) {
            $i = 0
            #$valid = Get-TestResult -SuccessOnError
            foreach ($virtualMachine in $global:config.virtualMachines) {
                $i = $i + 1
                $name = Get-VMString $virtualMachine
                write-Option "$i" "$($name)"
            }
            write-Option -color DarkGreen -Color2 Green "N" "New Virtual Machine"
            $response = get-ValidResponse "Which VM do you want to modify" $i $null "n"
        }
        Write-Log -HostOnly -Verbose "response = $response"
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n") {
                $role = Select-RolesForNew
                $os = Select-OSForNew -Role $role


                Add-NewVMForRole -Role $Role -Domain $Global:Config.vmOptions.domainName -ConfigToModify $global:config -OperatingSystem $os
                if ($role -eq "DC") {
                    $Global:Config.vmOptions.domainName = select-NewDomainName
                    $Global:Config.vmOptions.prefix = get-PrefixForDomain -Domain $($Global:Config.vmOptions.domainName)
                }
                Get-TestResult -SuccessOnError | out-null
                continue
            }
            :VMLoop while ($true) {
                $i = 0
                foreach ($virtualMachine in $global:config.virtualMachines) {
                    $i = $i + 1
                    if ($i -eq $response) {
                        $newValue = "Start"
                        while ($newValue -ne "D" -and -not ([string]::IsNullOrWhiteSpace($($newValue)))) {
                            Write-Log -HostOnly -Verbose "NewValue = '$newvalue'"
                            $customOptions = [ordered]@{ "*B1" = ""; "*B" = "---  Disks%cyan%cyan"; "A" = "Add Additional Disk" }
                            if ($null -eq $virtualMachine.additionalDisks) {
                            }
                            else {
                                $customOptions += [ordered]@{"R" = "Remove Last Additional Disk" }
                            }
                            if (($virtualMachine.Role -eq "Primary") -or ($virtualMachine.Role -eq "CAS")) {
                                $customOptions += [ordered]@{"*B2" = ""; "*S" = "---  ConfigMgr%cyan"; "S" = "Configure SQL (Set local or remote SQL)" }
                                $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                                if ($PassiveNode) {
                                    $customOptions += [ordered]@{"H" = "Remove HA" }
                                }
                                else {
                                    $customOptions += [ordered]@{"H" = "Enable HA" }
                                }
                            }
                            else {
                                if ($virtualMachine.OperatingSystem -and $virtualMachine.OperatingSystem.Contains("Server") -and -not ($virtualMachine.Role -eq "DC")) {
                                    if ($null -eq $virtualMachine.sqlVersion) {
                                        $customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%cyan"; "S" = "Add SQL" }
                                    }
                                    else {
                                        $customOptions += [ordered]@{"*B2" = ""; "*S" = "---  SQL%cyan"; "X" = "Remove SQL" }
                                    }
                                }
                            }

                            $customOptions += [ordered]@{"*B3" = ""; "*D" = "---  VM Management%cyan"; "D" = "Delete this VM%Red%Red" }
                            $newValue = Select-Options -propertyEnum $global:config.virtualMachines -PropertyNum $i -prompt "Which VM property to modify" -additionalOptions $customOptions -Test:$true
                            if (([string]::IsNullOrEmpty($newValue))) {
                                return
                            }
                            if ($newValue -eq "REFRESH") {
                                continue VMLoop
                            }
                            if ($null -ne $newValue -and $newValue -is [string]) {
                                $newValue = [string]$newValue.Trim()
                                #Write-Host "NewValue = '$newValue'"
                                $newValue = [string]$newValue.ToUpper()
                            }
                            if (([string]::IsNullOrEmpty($newValue))) {
                                break VMLoop
                            }
                            if ($newValue -eq "H") {
                                $PassiveNode = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $virtualMachine.siteCode }
                                if ($PassiveNode) {
                                    $FSVM = $global:config.virtualMachines | Where-Object { $_.vmName -eq $PassiveNode.remoteContentLibVM }
                                    if ($FSVM) {
                                        Remove-VMFromConfig -vmName $FSVM.vmName -ConfigToModify $global:config
                                    }
                                    #$virtualMachine.psobject.properties.remove('remoteContentLibVM')
                                    Remove-VMFromConfig -vmName $PassiveNode.vmName -ConfigToModify $global:config
                                }
                                else {
                                    Add-NewVMForRole -Role "PassiveSite" -Domain $global:config.vmOptions.domainName -ConfigToModify $global:config -Name $($virtualMachine.vmName + "-P")  -SiteCode $virtualMachine.siteCode
                                }
                                continue VMLoop

                            }
                            if ($newValue -eq "S") {
                                if ($virtualMachine.Role -eq "Primary" -or $virtualMachine.Role -eq "CAS") {
                                    Get-remoteSQLVM -property $virtualMachine
                                    continue VMLoop
                                }
                                else {
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlVersion' -Value "SQL Server 2019"
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceDir' -Value "C:\SQL"
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'sqlInstanceName' -Value "MSSQLSERVER"
                                    $virtualMachine.virtualProcs = 4
                                    if ($($virtualMachine.memory) / 1GB -lt "4GB" / 1GB) {
                                        $virtualMachine.memory = "4GB"
                                    }
                                }
                            }
                            if ($newValue -eq "X") {
                                $virtualMachine.psobject.properties.remove('sqlversion')
                                $virtualMachine.psobject.properties.remove('sqlInstanceDir')
                                $virtualMachine.psobject.properties.remove('sqlInstanceName')
                            }
                            if ($newValue -eq "A") {
                                if ($null -eq $virtualMachine.additionalDisks) {
                                    $disk = [PSCustomObject]@{"E" = "120GB" }
                                    $virtualMachine | Add-Member -MemberType NoteProperty -Name 'additionalDisks' -Value $disk
                                }
                                else {
                                    $letters = 69
                                    $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                        $letters++
                                    }
                                    if ($letters -lt 90) {
                                        $letter = $([char]$letters).ToString()
                                        $virtualMachine.additionalDisks | Add-Member -MemberType NoteProperty -Name $letter -Value "120GB"
                                    }
                                }
                            }
                            if ($newValue -eq "R") {
                                $diskscount = 0
                                $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                    $diskscount++
                                }
                                if ($diskscount -eq 1) {
                                    $virtualMachine.psobject.properties.remove('additionalDisks')
                                }
                                else {
                                    $i = 0
                                    $virtualMachine.additionalDisks | Get-Member -MemberType NoteProperty | ForEach-Object {
                                        $i = $i + 1
                                        if ($i -eq $diskscount) {
                                            $virtualMachine.additionalDisks.psobject.properties.remove($_.Name)
                                        }
                                    }
                                }
                                if ($diskscount -eq 1) {
                                    $virtualMachine.psobject.properties.remove('additionalDisks')
                                }
                            }
                            if (-not ($newValue -eq "D")) {
                                Get-TestResult -SuccessOnError | out-null
                            }
                        }
                        break VMLoop
                    }
                }
            }
            if ($newValue -eq "D") {
                $i = 0
                $removeVM = $true
                foreach ($virtualMachine in $global:config.virtualMachines) {
                    $i = $i + 1
                    if ($i -eq $response) {
                        if ($virtualMachine.role -eq "FileServer") {
                            $passiveVM = $global:config.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }
                            if ($passiveVM) {
                                if ($passiveVM.remoteContentLibVM -eq $virtualMachine.vmName) {
                                    Write-Host
                                    write-host -ForegroundColor Yellow "This VM is currently used as the RemoteContentLib for $($passiveVM.vmName) and can not be deleted at this time."
                                    $removeVM = $false
                                }
                            }
                        }
                        if ($removeVM -eq $true) {
                            Remove-VMFromConfig -vmName $virtualMachine.vmName -ConfigToModify $global:config
                        }
                    }
                }
                return
            }
        }
        else {
            Get-TestResult -SuccessOnError | Out-Null
            return
        }
    }
}

function Remove-VMFromConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Name of VM to remove.")]
        [string] $vmName,
        [Parameter(Mandatory = $false, HelpMessage = "Config to modify")]
        [object] $configToModify = $global:config
    )
    $DeletedVM = $null
    $newvm = $configToModify.virtualMachines | ConvertTo-Json | ConvertFrom-Json
    $configToModify.virtualMachines = @()
    foreach ($virtualMachine in $newvm) {

        if ($virtualMachine.vmName -ne $vmName) {
            $configToModify.virtualMachines += $virtualMachine
        }
        else {
            $DeletedVM = $virtualMachine
        }
    }
    if ($DeletedVM.Role -eq "CAS") {
        $primaryParentSideCode = ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode
        if ($primaryParentSideCode -eq $DeletedVM.SiteCode) {
            ($ConfigToModify.virtualMachines | Where-Object { $_.Role -eq "Primary" } | Select-Object -First 1).ParentSiteCode = $null
        }

    }
}

function Save-Config {
    [CmdletBinding()]
    param (
        [Parameter()]
        [object]
        $config
    )
    Write-Host
    Write-Verbose "9 Save-Config"

    $file = "$($config.vmOptions.domainName)"
    if ($config.vmOptions.existingDCNameWithPrefix) {
        $file += "-ADD-"
    }
    elseif (-not $config.cmOptions) {
        $file += "-NOSCCM-"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role.ToLowerInvariant() -eq "cas" }) {
        $file += "-CAS-$($config.cmOptions.version)-"
    }
    elseif ($Config.virtualMachines | Where-Object { $_.Role.ToLowerInvariant() -eq "primary" }) {
        $file += "-PRI-$($config.cmOptions.version)-"
    }

    $file += "($($config.virtualMachines.Count)VMs)"
    $date = Get-Date -Format "yyyy-MM-dd"
    $file = $date + "-" + $file

    $filename = Join-Path $configDir $file

    $splitpath = Split-Path -Path $fileName -Leaf
    $response = Read-Host2 -Prompt "Save Filename" $splitpath -HideHelp

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $filename = Join-Path $configDir $response
    }

    if (!$filename.EndsWith("json")) {
        $filename += ".json"
    }

    $config | ConvertTo-Json -Depth 3 | Out-File $filename
    $return.ConfigFileName = Split-Path -Path $fileName -Leaf
    Write-Host "Saved to $filename"
    Write-Host
    Write-Verbose "11"
}
$Global:Config = $null
$Global:Config = Select-ConfigMenu

start-sleep -seconds 1
$Global:DeployConfig = (Test-Configuration -InputObject $Global:Config).DeployConfig
$Global:AddToExisting = $false
$existingDCName = $Global:DeployConfig.parameters.existingDCName
if (-not [string]::IsNullOrWhiteSpace($existingDCName)) {
    $Global:AddToExisting = $true
}
$valid = $false
while ($valid -eq $false) {

    $return.DeployNow = Select-MainMenu
    if ($return.DeployNow -is [PSCustomObject]) {
        return $return.DeployNow
    }
    $c = Test-Configuration -InputObject $Global:Config
    Write-Host
    Write-Verbose "12"

    if ($c.Valid) {
        $valid = $true
    }
    else {
        if ($return.DeployNow -eq $false) {
            Write-Host
            write-host -ForegroundColor Yellow "WARNING: Configuration is not valid. Saving is not advised. Proceed with caution."
            Write-Host -ForegroundColor Red "Configuration contains the following errors: `r`n$($c.Message)`r`n"
            write-host
            $valid = $true
        }
        else {
            Write-Host -ForegroundColor Red "Config file is not valid: `r`n$($c.Message)`r`n"
            Write-Host -ForegroundColor Red "Please fix the problem(s), or hit CTRL-C to exit."
        }
    }

    if ($valid) {
        Show-Summary ($c.DeployConfig)
        Write-Host
        Write-verbose "13"
        if ($return.DeployNow -eq $true) {
            Write-Host -ForegroundColor Green "Please save and exit any RDCMan sessions you have open, as deployment will make modifications to the memlabs.rdg file on the desktop"
        }
        Write-Host "Answering 'no' below will take you back to the previous menu to allow you to make modifications"
        $response = Read-Host2 -Prompt "Everything correct? (Y/n)" -HideHelp
        if (-not [String]::IsNullOrWhiteSpace($response)) {
            if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {
                $valid = $false
            }
        }
    }
}

Save-Config $Global:Config

if (-not $InternalUseOnly.IsPresent) {
    Write-Host "You may deploy this configuration by running the following command:"
    Write-Host "$($PSScriptRoot)\New-Lab.ps1 -Configuration ""$($return.ConfigFileName)"""
}

#================================= NEW LAB SCENERIO ============================================
if ($InternalUseOnly.IsPresent) {

    return $return
}

