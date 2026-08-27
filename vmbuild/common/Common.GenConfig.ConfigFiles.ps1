# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
function Write-ConfigJsonFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Config,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        throw "Config directory does not exist: $directory"
    }

    $tempPath = Join-Path $directory (".$([System.IO.Path]::GetFileName($fullPath)).$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = "$tempPath.bak"
    try {
        $json = $Config | ConvertTo-Json -Depth 5 -ErrorAction Stop
        $json | Out-File -LiteralPath $tempPath -ErrorAction Stop
        $null = Get-Content -LiteralPath $tempPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Replace($tempPath, $fullPath, $backupPath)
        }
        else {
            [System.IO.File]::Move($tempPath, $fullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ([System.IO.File]::Exists($backupPath)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

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

        foreach ($file in $files) {
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $len = $filename.Length

            if ($len -gt $maxLength) {
                $maxLength = $len
            }
        }

        # Budget for the entire rendered row. Get-Menu2 prepends menu chrome
        # (arrow + "[NN] " + brackets/padding) -- reserve ~12 cols for that
        # plus a small safety slack so we never wrap onto a second line.
        # Use Get-LiveWindowSize when available -- $host.UI.RawUI.WindowSize
        # can return a stale width right after a resize in ConPTY hosts
        # (Windows Terminal), which would compute the budget for the OLD width.
        $hostW = 0
        try {
            if (Get-Command Get-LiveWindowSize -ErrorAction Ignore) {
                $live = Get-LiveWindowSize
                if ($live) { $hostW = [int]$live.Width }
            }
        } catch { }
        if (-not $hostW) { $hostW = $host.UI.RawUI.WindowSize.Width }
        $rowMaxWidth = $hostW - 12
        if ($rowMaxWidth -lt ($maxLength + 10)) { $rowMaxWidth = $maxLength + 10 }
        foreach ($file in $files) {
            $i = $i + 1
            $savedConfigJson = $null
            $savedNotes = ""
            $color = $Global:Common.Colors.GenConfigNormal
            try {
                $savedConfigJson = Get-Content $file | ConvertFrom-Json
            }
            catch {
                Write-Log "Skipping invalid config file '$($file.FullName)'. Repair it or rename it outside '*.json' before loading. JSON error: $_" -Warning
                continue
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
            }
            $filename = [System.Io.Path]::GetFileNameWithoutExtension($file.Name)
            $rowText = $filename.PadRight($maxLength) + " " + $savedNotes
            if ($rowText.Length -gt $rowMaxWidth) {
                $rowText = $rowText.Substring(0, $rowMaxWidth - 3) + "..."
            }
            $optionArray += $rowText + "%$color"

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
