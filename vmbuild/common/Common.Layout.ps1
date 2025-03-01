Function Get-LabVMs {
    param (
        [Parameter(Mandatory = $false)]
        [switch] $LineCount,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name")]
        [string] $DomainName
    )

    $vms = Get-List -Type VM -domain $DomainName
    if ($LineCount) {
        return $vms.count + 2
    }

    if ($vms) {
        
        # Define colors for state and role
        $stateColor = @{ "Running" = "Green"; "Off" = "Red" }
        $roleColor = @{ "CAS" = "Yellow"; "Primary" = "Yellow"; "DC" = "White"; "SiteSystem" = "Yellow"; "DomainMember" = "Cyan" }

        # Extract properties and headers
        $properties = @("VmName", "Domain", "State", "Role", "SiteCode", "DeployedOS", "MemoryStartupGB", "DiskUsedGB", "SqlVersion", "LastKnownIP")
        $headers = @("VM Name", "Domain", "State", "Role", "Site", "Deployed OS", "Memory", "Disk Used", "SQL Version", "Last Known IP")

        $maxWidth = $host.UI.RawUI.WindowSize.Width
        # Calculate max width for each column (across ALL VMs for consistency)
        $columnWidths = foreach ($i in 0..($headers.Length - 1)) {
            $headerLength = $headers[$i].Length
            $maxDataLength = ($vms | ForEach-Object { 
                    $value = $_.($properties[$i])
                    if ($i -in 6, 7) { "$value GB" } else { "$value" } 
                } | Measure-Object -Property Length -Maximum).Maximum
            
            if ($i -eq $headers.Length - 1) {
                [Math]::Max($headerLength, $maxDataLength)
            }  # Last column doesnt need padding
            else { 
                [Math]::Max($headerLength, $maxDataLength) + 2 
            }  # Add padding           
        }
        $totalwidth = $columnWidths | Measure-Object -Sum | Select-Object -ExpandProperty Sum
        if ($totalwidth -ge $maxWidth) {
            $columnWidths = foreach ($i in 0..($headers.Length - 1)) {
                $headerLength = $headers[$i].Length
                $maxDataLength = ($vms | ForEach-Object { 
                        $value = $_.($properties[$i])
                        if ($i -in 6, 7) { "$value GB" } else { "$value" } 
                    } | Measure-Object -Property Length -Maximum).Maximum
                
                if ($i -eq $headers.Length - 1) {
                    [Math]::Max($headerLength, $maxDataLength)
                }  # Last column doesnt need padding
                else { 
                    [Math]::Max($headerLength, $maxDataLength) + 1
                }  # Add padding           
            }
        }
        $totalwidth = $columnWidths | Measure-Object -Sum | Select-Object -ExpandProperty Sum
        if ($totalwidth -ge $maxWidth) {
            $columnWidths = foreach ($i in 0..($headers.Length - 2)) {
                $headerLength = $headers[$i].Length
                $maxDataLength = ($vms | ForEach-Object { 
                        $value = $_.($properties[$i])
                        if ($i -in 6, 7) { "$value GB" } else { "$value" } 
                    } | Measure-Object -Property Length -Maximum).Maximum
                
                if ($i -eq $headers.Length - 1) {
                    [Math]::Max($headerLength, $maxDataLength)
                }  # Last column doesnt need padding
                else { 
                    [Math]::Max($headerLength, $maxDataLength) + 1
                }  # Add padding           
            }
        }
        # Group VMs by Domain
        $groups = $vms | Sort-Object -Property Domain, VmName | Group-Object -Property Domain

        $first = $true
        # Display tables per domain
        foreach ($group in $groups) {
            if ($first) {
                $first = $false
            }
            else {
                Write-Host
            }
            $domainVMs = $group.Group

            # Print header for the domain
            for ($i = 0; $i -lt $headers.Length; $i++) {
                $width = $columnWidths[$i]  # $columnWidths is an array of columns' width
                if ($width) {
                    Write-Host ("{0,-$width}" -f $headers[$i]) -NoNewline -ForegroundColor White -BackgroundColor DarkBlue
                }
            }
            Write-Host ""

            # Print rows for the domain
            foreach ($vm in $domainVMs) {
                $rowData = @(
                    $vm.VmName,
                    $vm.Domain,
                    $vm.State,
                    $vm.Role,
                    $vm.SiteCode,
                    $vm.DeployedOS,
                    "$($vm.MemoryStartupGB) GB",
                    "$([Math]::Round($vm.DiskUsedGB, 2)) GB",
                    $vm.SqlVersion,
                    $vm.LastKnownIP
                )

                for ($i = 0; $i -lt $headers.Length; $i++) {
                    $value = $rowData[$i]
                    $width = $columnWidths[$i]
                    if (-not $width) {
                        continue
                    }
                    $formatString = "{0,-$width}"

                    # Apply color logic
                    if ($i -eq 2) {
                        $StateString = $value
                        If ($StateString -eq "Running") { $stateString = "On" }
                        # State column
                        if ($stateColor[$value]) {
                            $color = $stateColor[$value]
                        }
                        else {
                            $color = "PapayaWhip"
                        }
                        Write-Host2 ($formatString -f $value) -NoNewline -ForegroundColor $color
                    }
                    elseif ($i -eq 3) {
                        # Role column
                        if ($roleColor[$value]) {
                            $color = $roleColor[$value]
                        }
                        else {
                            $color = "PapayaWhip"
                        }

                        Write-Host2 ($formatString -f $value) -NoNewline -ForegroundColor $color
                    }
                    else {
                        Write-Host ($formatString -f $value) -NoNewline
                    }
                }
                Write-Host ""  # Newline
            }

           
        }
    }
    else {
        Write-Host "No VMs found." -ForegroundColor Red
    }
}