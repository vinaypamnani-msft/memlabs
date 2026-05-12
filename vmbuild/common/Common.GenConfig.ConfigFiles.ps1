Function Get-ConfigFiles {
    param(
        [string] $ConfigPath,
        [switch] $SortByName
    )
  
    if (-not (Test-Path $ConfigPath)) {
        write-log "No files found in $configPath" -Warning
        return
    }
   
    $files = @()
    $files += Get-ChildItem $ConfigPath\*.json -Include "Standalone.json", "Hierarchy.json" | Sort-Object -Property Name -Descending
    #$files += Get-ChildItem $ConfigPath\*.json -Include "TechPreview.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "NoConfigMgr.json"
    $files += Get-ChildItem $ConfigPath\*.json -Include "AddToExisting.json"
    $files += Get-ChildItem $ConfigPath\*.json -Exclude "_*", "Hierarchy.json", "Standalone.json", "AddToExisting.json", "TechPreview.json", "NoConfigMgr.json" | Sort-Object -Descending -Property LastWriteTime


    if ($SortByName) {
        $files = $files | sort-Object -Property Name
    }
    return $files
}

function Show-ConfigLegend {
    param (
        [switch] $LineCount
    )
    if ($LineCount) {
        return 5
    }
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigJsonGood "  == Green  - Fully Deployed"
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigJsonBad  "  == Red    - Partially Deployed"
    Write-Host2 -ForegroundColor  $Global:Common.Colors.GenConfigNoCM    "  == Brown  - Not Deployed - New Domain"
    Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigNormal   "  == Normal - Not Deployed - Needs existing domain" 
    Write-Host2
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


    $SortByName = $false
    if ($ConfigPath.EndsWith("tests")) {
        $SortByName = $true
    }    
        
    $responseValid = $false
    while ($responseValid -eq $false) {
        $optionArray = @()


        If ($SortByName) {
            Write-Log -SubActivity "Viewing config files located in $ConfigPath -- Sorted by Name"
            $files = Get-ConfigFiles -ConfigPath $ConfigPath -SortByName
        }
        Else {
            Write-Log -SubActivity "Viewing config files located in $ConfigPath -- Sorted by date"
            $files = Get-ConfigFiles -ConfigPath $ConfigPath
        }

        $i = 0
        $currentVMs = Get-List -type VM
        $maxLength = 40
        $MaxWidth = ($host.UI.RawUI.WindowSize.Width - $maxLength - 12)
        
        foreach ($file in $files) {
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $len = $filename.Length

            if ($len -gt $maxLength) {
                $maxLength = $len
            }
        }
        foreach ($file in $files) {
            $i = $i + 1
            $savedConfigJson = $null
            $savedNotes = ""
            $color = $Global:Common.Colors.GenConfigNormal
            try {
                $savedConfigJson = Get-Content $file | ConvertFrom-Json
            }
            catch {
                Write-Log "Failed to parse config file '$($file.FullName)': $_" -Warning
            }

            $savedNotes = "[" + $file.LastWriteTime.GetDateTimeFormats()[2].PadLeft(8) + "]"

            if ($savedConfigJson) {
                $Found = 0
                $notFound = 0
                foreach ($vm in $savedConfigJson.virtualMachines) {
                    $vmName = $savedConfigJson.vmOptions.Prefix + $vm.vmName
                    if ($currentVms.VmName -contains $vmName) {
                        $Found++
                    }
                    else {
                        $notFound++
                    }
                }
                $hasDC = $savedConfigJson.virtualMachines | Where-Object { $_.role -eq "DC" }
                

                if ($hasDC) {
                    $savedNotes += " [New Domain: $($savedConfigJson.vmoptions.domainName)]"
                    $color = $Global:Common.Colors.GenConfigNoCM
                }
                else {
                    $savedNotes += " [Existing Domain: $($savedConfigJson.vmoptions.domainName)]"
                }
                if ($found -gt 0) {
                    $color = $Global:Common.Colors.GenConfigJsonGood
                    if ($notFound -gt 0) {
                        $color = $Global:Common.Colors.GenConfigJsonBad
                    }
                }
                $savedNotes += "[Deployed: $($Found.ToString().PadRight(2))] [Missing: $($notFound.ToString().PadRight(2))] "
                $savedNotes += "$($savedConfigJson.virtualMachines.VmName -join ", ")"
                
                if ($savedNotes.Length -ge $MaxWidth) {
                    $savedNotes = $savedNotes.Substring(0, $MaxWidth - 3) + "..."
                }
               
            }
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $optionArray += $($filename.PadRight($maxLength) + " " + $savedNotes) + "%$color"

        }
        $preOptionsArray = [ordered]@{"*F5" = "Show-ConfigLegend" }

        if ($SortByName) {
            $preOptionsArray += [ordered]@{"S" = "Sort by Date%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        }
        else {
            $preOptionsArray += [ordered]@{"S" = "Sort by Name%$($Global:Common.Colors.GenConfigNonDefault)%$($Global:Common.Colors.GenConfigNonDefaultNumber)" }
        }
        $customOptions = [ordered]@{}        
        $menuName = "Select Config File to load"

        if ($ConfigPath -like "*tests*") {
            $menuName = "Select TEST Config File to load"
        }
        $response = Get-Menu2 -MenuName $menuName -prompt "Which config do you want to load" -preOptions $preOptionsArray -OptionArray $optionArray -additionalOptions $customOptions -split -test:$false -return

        if ($response.ToLowerInvariant() -eq "s") {
            $SortByName = !$SortByName
            continue
        }

        $responseValid = $true
        if (-not $response -or $response -eq "ESCAPE") {
            return
        }
    }
    $UserConfig = Get-UserConfiguration -Configuration $response
    if ($userConfig.Loaded) {
        Write-GreenCheck "Loaded Configuration: $response" -NoIndent
    }
    else {
        Write-Redx "Failed to load Configuration: $($UserConfig.ConfigPath)" -NoIndent
        return
    }
    $Global:configfile = $UserConfig.ConfigPath


    $configSelected = $UserConfig.config
    #$configSelected = Get-Content $Global:configfile -Force | ConvertFrom-Json

    if ($null -ne $configSelected.vmOptions.domainAdminName) {
        if ($null -eq ($configSelected.vmOptions.adminName)) {
            $configSelected.vmOptions | Add-Member -MemberType NoteProperty -Name "adminName" -Value $configSelected.vmOptions.domainAdminName
        }
        $configSelected.vmOptions.PsObject.properties.Remove('domainAdminName')
    }
    if ($null -ne $configSelected.cmOptions.installDPMPRoles) {
        $configSelected.cmOptions.PsObject.properties.Remove('installDPMPRoles')
        foreach ($vm in $configSelected.virtualMachines) {
            if ($vm.Role -eq "SiteSystem") {
                $vm | Add-Member -MemberType NoteProperty -Name "installDP" -Value $true -Force
                $vm | Add-Member -MemberType NoteProperty -Name "installMP" -Value $true -Force
            }
        }
    }
    if ($vm.Role -eq "SiteSystem") {
        if (-not $vm.InstallSMSProv) {
            $vm | Add-Member -MemberType NoteProperty -Name "InstallSMSProv" -Value $false -Force
        }
    }
    return $configSelected
}
