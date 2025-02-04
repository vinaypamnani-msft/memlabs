############################
### Menu Functions ###
############################
#Common.NewMenu.ps1

# Offers a menu for any array passed in.
# This is used for Sql Versions, Roles, Etc

# Description: This script demonstrates how to create a simple navigation menu in PowerShell.

# Get the current cursor position as a Coordinates object (X, Y) from the console.
function Get-CursorPosition {
    $x, $y = $Host.UI.RawUI.CursorPosition -split ',' # Split the cursor position into X and Y coordinates
    return @{x = $x; y = $y } # Return the cursor position as a hashtable
}

# Set the cursor position to the specified coordinates (X, Y) in the console.
function Set-CursorPosition {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$X, # The X coordinate

        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$Y # The Y coordinate
    )

    # Set the cursor position to the specified coordinates
    $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates($X, $Y)
}

function Add-MenuItem {
    [CmdletBinding()]
    param (
        #[Parameter(Mandatory = $true, HelpMessage = "Menu Items array")]
        #[AllowEmptyCollection()]
        [Parameter(Mandatory = $true, HelpMessage = "Menu Name")]
        [string] $MenuName,
        [array] $MenuItems,
        [string] $ItemName,
        [string] $ItemText,
        [string] $Color1 = $Global:Common.Colors.GenConfigNormal,
        [string] $Color2 = $Global:Common.Colors.GenConfigNormalNumber,
        [bool] $Selectable = $true,
        [bool] $Selected = $false,
        [string] $Function = $null        
    )


    if ($Selected -eq $true) {
        foreach ($menuItem2 in $MenuItems) {
            if ($menuItem2.Selected) {
                $Selected = $false
                break
            }
        }
    }
    $MenuItem = [PSCustomObject]@{
        itemName      = $ItemName
        Text          = $ItemText
        Color1        = $Color1
        Color2        = $Color2
        Selectable    = $Selectable
        Selected      = $Selected
        Function      = $Function
        MultiSelected = $false
    }

    
    if ($Global:MenuHistory) {
        if ($Global:MenuHistory[$menuName]) {
            $currentItem = $Global:MenuHistory[$menuName]
            #Write-Log "found $currentItem for $menuName"
        }              
    }


    if ($ItemName -eq $currentItem) {
        foreach ($menuItem2 in $MenuItems) {
            $menuItem2.Selected = $false
        }
        $MenuItem.Selected = $true

    }
    
    $MenuItems += $MenuItem
    return $MenuItems

}

function Get-MenuItems {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Menu Name")]
        [string] $MenuName,
        [Parameter(Mandatory = $false, HelpMessage = "Array of objects to display a menu from")]
        [object] $OptionArray,
        [Parameter(Mandatory = $false, HelpMessage = "The default if enter is pressed")]
        [string] $CurrentValue,
        [Parameter(Mandatory = $false, HelpMessage = "Additional Menu options, in dictionary format.. X = Exit")]
        [object] $additionalOptions = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Pre Menu options, in dictionary format.. X = Exit")]
        [object] $preOptions = $null,
        [object] $menuItems = $null,
        [switch] $MultiSelect,
        [switch] $AllSelected
    )


    if ($Global:MenuHistory) {
        if ($Global:MenuHistory[$menuName]) {
            $currentItem = $Global:MenuHistory[$menuName]
            Write-Log -verbose "[MenuHistory] found '$($currentItem -join ",")' for '$menuName'"
            $AllSelected = $false
        }              
    }

    $foundSelected = $false
    $FoundMultiSelectItem = $false
    #Define an array of MenuItems
    if ($null -eq $menuItems) {
        $MenuItems = @()
    }
    else {
        $foundSelected = $true
    }

    
    if ($null -ne $preOptions) {
        foreach ($item in $preOptions.keys) {
            $MenuItem = [PSCustomObject]@{
                itemName      = $null
                Text          = $null                
                Color1        = $Global:Common.Colors.GenConfigDefault
                Color2        = $Global:Common.Colors.GenConfigDefaultNumber
                Selectable    = $true
                Selected      = $false
                Function      = $null
                MultiSelected = $false
            }
            $value = $preOptions."$($item)"

            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $MenuItem.color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $MenuItem.color2 = $TextValue[2]
                    }
                    else {
                        $MenuItem.color2 = $MenuItem.color1
                    }
                }

                if ($TextValue[0].StartsWith("$")) {
                    continue
                }

                if ($item.StartsWith("*")) {
                    $MenuItem.Selectable = $false
                    if ($item.StartsWith("*F")) {
                        $MenuItem.Function = $TextValue[0]
                    }
                    else {                    
                        $MenuItem.Text = $TextValue[0]
                    }
                    $MenuItems += $MenuItem                    
                    continue
                }
                if (-not $foundSelected) {
                    if ($item -eq $currentItem) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                    if ($item -eq $CurrentValue) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                    if ($TextValue[0] -eq $CurrentValue) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                }
                $MenuItem.itemName = $item
                $MenuItem.Text = $TextValue[0]
                $MenuItems += $MenuItem
                             
            }
        }
    }

    $i = 0

    foreach ($option in $OptionArray) {
        if (-not [String]::IsNullOrWhiteSpace($option)) {
            $i = $i + 1
            $item = $option
            $MenuItem = [PSCustomObject]@{
                itemName      = $null
                Text          = $null                
                Color1        = $Global:Common.Colors.GenConfigNormal
                Color2        = $Global:Common.Colors.GenConfigDefaultNumber
                Selectable    = $true
                Selected      = $false
                Function      = $null
                MultiSelected = $false
            }

            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $item -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $MenuItem.color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $MenuItem.color2 = $TextValue[2]
                    }
                    else {
                        $MenuItem.color2 = $MenuItem.color1
                    }
                }
                if (-not $foundSelected) {
                    if ($MultiSelect) {
                        if ($AllSelected) {
                            $MenuItem.MultiSelected = $true                            
                        }
                        else {
                            if ($currentItem) {
                                if ($TextValue[0] -in $currentItem ) {
                                    $MenuItem.MultiSelected = $true
                                }                            
                            }
                        }
                    }
                    else {
                        if ($i -eq $currentItem) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                        }
                        if ($item -eq $CurrentValue) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                        }
                        if ($TextValue[0] -eq $CurrentValue) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                        }
                    }
                }
                $MenuItem.itemName = $i
                $MenuItem.Text = $TextValue[0]
                $MenuItems += $MenuItem   
                $FoundMultiSelectItem = $true                   
            }
        }
    }

    if ($null -ne $additionalOptions) {
        foreach ($item in $additionalOptions.keys) {
            $value = $additionalOptions."$($item)"

            $MenuItem = [PSCustomObject]@{
                itemName      = $null
                Text          = $null                
                Color1        = $Global:Common.Colors.GenConfigDefault
                Color2        = $Global:Common.Colors.GenConfigDefaultNumber
                Selectable    = $true
                Selected      = $false
                Function      = $null
                MultiSelected = $false
            }


            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
                    $MenuItem.color1 = $TextValue[1]
                    if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                        $MenuItem.color2 = $TextValue[2]
                    }
                    else {
                        $MenuItem.color2 = $MenuItem.color1
                    }
                }

                if ($TextValue[0].StartsWith("$")) {
                    continue
                }
                if ($item.StartsWith("*")) {
                    $MenuItem.Selectable = $false     
                    if ($item.StartsWith("*F")) {
                        $MenuItem.Function = $TextValue[0]
                    }
                    else {                    
                        $MenuItem.Text = $TextValue[0]
                    }                                   
                    $MenuItems += $MenuItem                    
                    continue
                }
                if (-not $foundSelected) {
                    if ($item -eq $currentItem) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                    if ($item -eq $CurrentValue) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                    if ($TextValue[0] -eq $CurrentValue) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                    }
                }
                $MenuItem.itemName = $item
                $MenuItem.Text = $TextValue[0]
                $MenuItems += $MenuItem   
            }
        }
    }

    if ($MultiSelect -and $FoundMultiSelectItem) {
        $MenuItem = [PSCustomObject]@{
            itemName      = "*B"
            Text          = $null              
            Color1        = $Global:Common.Colors.GenConfigDefault
            Color2        = $Global:Common.Colors.GenConfigDefaultNumber
            Selectable    = $false
            Selected      = $false
            Function      = $null
            MultiSelected = $false
        }
        $MenuItems += $MenuItem 
        $MenuItem = [PSCustomObject]@{
            itemName      = "A"
            Text          = "All Entries"               
            Color1        = $Global:Common.Colors.GenConfigTrue 
            Color2        = $Global:Common.Colors.GenConfigTrue 
            Selectable    = $true
            Selected      = $false
            Function      = $null
            MultiSelected = $false
        }
        $MenuItems += $MenuItem 
        $MenuItem = [PSCustomObject]@{
            itemName      = "N"
            Text          = "No Entries"               
            Color1        = $Global:Common.Colors.GenConfigFalse
            Color2        = $Global:Common.Colors.GenConfigFalse
            Selectable    = $true
            Selected      = $false
            Function      = $null
            MultiSelected = $false
        }
        $MenuItems += $MenuItem 
        $MenuItem = [PSCustomObject]@{
            itemName      = "D"
            Text          = "Done with selections"               
            Color1        = $Global:Common.Colors.GenConfigDefault
            Color2        = $Global:Common.Colors.GenConfigDefaultNumber
            Selectable    = $true
            Selected      = $true
            Function      = $null
            MultiSelected = $false
        }
        $MenuItems += $MenuItem 

    }
    
    if (-not $foundSelected) {
        foreach ($menuItem in $MenuItems) {
            if ($menuItem.Selected) {
                $foundSelected = $true
                break
            }
        }
    }

    if (-not $foundSelected) {
        foreach ($menuItem in $MenuItems) {
            if ($menuItem.Selectable) {
                $menuItem.Selected = $true
                break
            }
        }
    }
    if ($MenuItems.Count -eq 0) {
        $MenuItem = [PSCustomObject]@{
            itemName      = $null
            Text          = $null                
            Color1        = $Global:Common.Colors.GenConfigDefault
            Color2        = $Global:Common.Colors.GenConfigDefaultNumber
            Selectable    = $false
            Selected      = $false
            Function      = $null
            MultiSelected = $false
        }
        $MenuItems += $MenuItem
    }
    return $MenuItems # Return the menu items
}

function Get-Menu2 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Name of the menu")]
        [string] $MenuName,
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
        [switch] $NoNewLine,
        [Parameter(Mandatory = $false, HelpMessage = "Split response")]
        [switch] $split,
        [Parameter(Mandatory = $false, HelpMessage = "timeout")]
        [int] $timeout = 0,
        [Parameter(Mandatory = $false, HelpMessage = "Hide Help")]
        [bool] $HideHelp = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Hint for help to show we will return from this menu on enter")]
        [switch] $return,
        [Parameter(Mandatory = $false, HelpMessage = "PrePopulated MenuItems")]
        [object] $menuItems = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Do Not clear the screen.. Dangerous")]
        [switch] $NoClear,
        [switch] $MultiSelect,
        [switch] $AllSelected
    )

    $host.ui.RawUI.FlushInputBuffer()

    if (!$NoNewLine) {
        write-Host
        Write-Verbose "[$menuName] 4 Get-Menu2"
    }

    if ($null -eq $menuItems) {
        $menuItems = Get-MenuItems -OptionArray $OptionArray -CurrentValue $CurrentValue -additionalOptions $additionalOptions -preOptions $preOptions -menuName $MenuName -MultiSelect:$MultiSelect -AllSelected:$AllSelected
        Write-Log -LogOnly "[$menuName] [Get-Menu2] MenuItems Count $($menuItems.Count) '$menuItems'"
    }
   
    if (-not $Global:MenuHistory) {
        $Global:MenuHistory = @{}
    }

    $response = Show-Menu -menuItems $menuItems -menuName $MenuName -NoClear:$NoClear -MultiSelect:$MultiSelect
    if ($response -is [array] -or $response.MultiSelected) {
        $ReturnValue = @($response | Select-Object -ExpandProperty Text)
        $Global:MenuHistory[$menuName] = $ReturnValue
        write-log -verbose "[MenuHistory] [Array] Setting $menuName to $ReturnValue with $($ReturnValue.Count) items"
        $returnValue = @($ReturnValue | ForEach-Object {$_})
        return $returnValue
    }
    else {
        if ($response.itemName) {
            $response = $response.itemName
            $Global:MenuHistory[$menuName] = $response   
            write-log -verbose "[MenuHistory] Setting $menuName to $response"   
        }
    }
    write-host
    #else {
    #     Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
    #     if (-not [String]::IsNullOrWhiteSpace($currentValue)) {
    #         Write-Host " [" -NoNewline
    #         Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPromptCurrentItem $currentValue -NoNewline
    #         Write-Host "] " -NoNewline
    #     }
    # }





    #$response = get-ValidResponse -Prompt $Prompt -max $i -CurrentValue $CurrentValue -AdditionalOptions $totalOptions -TestBeforeReturn:$Test -timeout:$timeout -HideHelp:$HideHelp -return:$return

    if (-not [String]::IsNullOrWhiteSpace($response)) {
        $i = 0
        foreach ($option in $OptionArray) {
            $i = $i + 1
            if ($i -eq $response) {
                if ($split) {
                    $option = $option -Split " " | Select-Object -First 1
                }
                Write-Log -LogOnly "[$menuName] [Get-Menu2] Returned (O) '$option'"
                return $option
            }
        }
        if ($split) {
            $response = $response -Split " " | Select-Object -First 1
        }
        Write-Log -LogOnly "[$menuName] [Get-Menu2] Returned (R) '$response'"

        return $response
    }
    else {
        Write-Log -LogOnly  "[$menuName] [Get-Menu2] Returned (CV) '$CurrentValue'"
        return $CurrentValue
    }
    Write-Log -LogOnly  "[$menuName] [Get-Menu2] Didnt Return Anything"
}


function Get-RoomLeftFromCurrentPosition {
    $WindowSizeY = ($host.UI.RawUI.WindowSize.Height - 2) # Get the height of the console window, subtract 1 since its 0 based
    $CurrentPosition = Get-CursorPosition
    $MenuStart = $CurrentPosition.Y
    $RoomLeft = ([int]$WindowSizeY - [int]$MenuStart)
    return $RoomLeft
}

# Read the array of menu items and the selected index and display the menu
function Show-Menu {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [string]$menuName, # The name of the menu

        [Parameter(Mandatory = $true)] # Mandatory parameter
        [array]$menuItems, # The array of menu items
        [Switch]$NoClear = $false,
        [Switch]$MultiSelect = $false

    )
    While ($true) {


        $WindowSizeY = $host.UI.RawUI.WindowSize.Height - 1 # Get the height of the console window, subtract 1 since its 0 based
        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        $RoomLeft = Get-RoomLeftFromCurrentPosition

        if ($NoClear -and $RoomLeft -lt $menuItems.Count) {
            $NoClear = $false
        }

        if (-not $NoClear) {
            Write-Host "`e[2J`e[H"
        }

        Write-Log -Activity $menuName

        $RoomLeft = Get-RoomLeftFromCurrentPosition

        if ($RoomLeft -lt $menuItems.Count) {
            Write-Host "`e[2J`e[H" #Try Clearing the screen again.  Maybe this gives us enough room.
        }

        $RoomLeft = Get-RoomLeftFromCurrentPosition
        if ($RoomLeft -lt $menuItems.Count) {        
            $shrink = $true    
            $roomsaved = 0
            foreach ($menuItem in $menuItems) {
                if (-not $menuItem.Selectable) {
                    if (-not [string]::IsNullOrWhiteSpace($menuItem.Text)) {
                        $roomsaved = $roomsaved + 1
                    }                
                }
            }
        }
        if ($RoomLeft -lt ($menuItems.Count - $roomsaved)) {
            $Maxshrink = $true
        }
        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        foreach ($menuItem in $menuItems) {
            $CurrentPosition = Get-CursorPosition
            Set-CursorPosition -x 0 -y $CurrentPosition.Y  # Make sure we are at the beginning of the line   

            if ($menuItem.Function) {
                if (-not $Maxshrink) {
                    Invoke-Expression -Command $menuItem.Function
                }
                continue
            }
            if ($menuItem.Selected) {
                Write-Host "-> " -ForegroundColor Yellow -NoNewline
            }
            else {
                Write-Host "   " -ForegroundColor Cyan -NoNewline
            }

        
            $CurrentPosition = Get-CursorPosition
            $menuItem | Add-Member -MemberType NoteProperty -Name "CurrentPosition" -Value $CurrentPosition.Y -force
            if ($menuItem.Selectable) {    
                Set-CursorPosition -x 3 -y $CurrentPosition.Y  # Make sure we are at the beginning of the line       
                Write-Option $menuItem.itemName $menuItem.Text -color $menuItem.Color1 -Color2 $menuItem.Color1 -MultiSelect:$MultiSelect -MultiSelected:$menuItem.MultiSelected
            }
            else {
                if ($Maxshrink) {
                    continue
                }
                if ($shrink -and [string]::IsNullOrWhiteSpace($menuItem.Text)) {
                    continue
                }
                write-host2 -ForeGroundColor $menuItem.Color1 $menuItem.Text
            }                        
        }   
        $CurrentPosition = (Get-CursorPosition).Y - $menuItems.Count 

        $AnySelections = $menuItems | Where-Object { $_.Selectable }
        if ($AnySelections) {
            $prompt = "Press Enter to select, Up/Down/Left/Right to navigate, ESC to exit"
        }
        else {
            $prompt = "No Selections.  Press Left or Escape to exit"
        }
        #$currentValue = "T"
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
        $PromptPosition = Get-CursorPosition       

        $return = Start-Navigation -menuItems $MenuItems -startOfmenu $MenuStart -PromptPosition $PromptPosition -MultiSelect:$MultiSelect
        if ($return) {
            return $return
        }
    }


}

# Set the pointer display as per the menu
function Set-PointerDisplayAsPerMenu {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [array]$menuItems, # The array of menu items

        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$selectedIndex,
        [switch]$MultiSelect = $false
    )

    for ($i = 0; $i -lt $menuItems.Count; $i++) {
        Set-CursorPosition -x 0 -y $menuItems[$i].CurrentPosition
        if ($i -eq $selectedIndex) {
            $menuItems[$i].Selected = $true
            Write-Host "-> " -ForegroundColor Cyan
            
        }
        else {
            $menuItems[$i].Selected = $false
            Write-Host "   "
        }
        if ($MultiSelect) {
            Set-CursorPosition -x 4 -y $menuItems[$i].CurrentPosition
            if ($menuItems[$i].MultiSelected) {       
                $CHECKMARK = ([char]8730)             
                Write-Host $CHECKMARK -ForegroundColor Green -NoNewline
            }
            else {
                Write-Host " " -NoNewline
            }
        }
    }
}

# Get the key stroke from the user
function Get-KeyStroke {
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") # Read the key stroke without echoing it to the console
    return $key # Return the key stroke
}

# Set the cursor position to the top of the menu
function Set-CursorPositionToTopOfMenu {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$startOfmenu # The number of menu items
    )
    $cursorPosition = Get-CursorPosition # Get the current cursor position
    # Move the cursor up to the top of the menu
    $cursorPosition.Y = $startOfmenu
    # Set the cursor position to the top of the menu
    Set-CursorPosition -X $cursorPosition.X -Y $cursorPosition.Y
}


function Update-Prompt {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$PromptPosition, # The cursor position

        [Parameter(Mandatory = $false)] # Mandatory parameter
        [string]$buffer, # The buffer to display

        [Parameter(Mandatory = $false)] # Mandatory parameter
        [object]$MenuItems = $null,

        [Parameter(Mandatory = $false)] # Mandatory parameter
        [int]$SelectedIndex = -1

    )
    $CurrentValue = $null
    $cursorPosition = Get-CursorPosition # Get the current cursor position
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    write-host "             " -NoNewline
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    if ($MenuItems -and $selectedIndex -ne -1) {
        $CurrentValue = $MenuItems[$selectedIndex].ItemName
    }
    if (-not [String]::IsNullOrWhiteSpace($CurrentValue)) {
        Write-Host " [" -NoNewline
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPromptCurrentItem $CurrentValue -NoNewline
        Write-Host "]" -NoNewline
    }
    else {
        Write-Host " [" -NoNewline -ForegroundColor $Global:Common.Colors.GenConfigError2
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigError1 "!!" -NoNewline
        Write-Host "]" -NoNewline -ForegroundColor $Global:Common.Colors.GenConfigError2
    }
    Write-Host ": " -NoNewLine
    if ($buffer) {
        write-host2 $buffer -NoNewline -ForegroundColor Yellow
        [System.Console]::CursorVisible = $true 
    }
    else {
        [System.Console]::CursorVisible = $false
        Set-CursorPosition -X $cursorPosition.X -Y $cursorPosition.Y # Set the cursor position to the original position
    }
    
}

# Start the navigation menu
# The navigation menu is started with the specified menu items and selected index
function Start-Navigation {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [array]$menuItems, # The array of menu items
        
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$startOfmenu, # The selected index
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$PromptPosition, # The selected index
        [switch]$MultiSelect = $false
    )

    $i = 0
    $selectedIndex = 0
    $NumSelectable = 0
    $ValidChars = @()
    foreach ($menuItem in $menuItems) {
        if ($null -ne $menuItem.itemName -and $menuItem.Selectable) {
            $ValidChars += $menuItem.itemName.ToString().Substring(0, 1).ToUpperInvariant()
            $NumSelectable++
        }

        if ($menuItem.Selected) {
            $selectedIndex = $i
        }
        $i++       
    }

    $CPosition = Get-CursorPosition # Get the current cursor position
    [System.Console]::CursorVisible = $false # Hide the cursor
    $startSize = $Host.UI.RawUI.WindowSize
    # Loop until the user presses the Escape key
    while ($true) {
        $currentsize = $Host.UI.RawUI.WindowSize
        if ($currentsize -ne $startSize) {
            return
        }

        Update-Prompt -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        
        $key = Get-KeyStroke # Get the key stroke from the user
        $currentsize = $Host.UI.RawUI.WindowSize
        if ($currentsize -ne $startSize) {
            return
        }
        # Handle the key stroke
        if ($key.VirtualKeyCode -eq 13 -or $key.VirtualKeyCode -eq 39 -or $key.Character -eq " ") {
            # 13 = Enter key, 39 = Right arrow key

            if ($NumSelectable -eq 0) {
                return "ESCAPE"
            }
            
            if ($MultiSelect) {
                $optionInt = ($($menuItems[$selectedIndex].ItemName) -as [int])
                if ($optionInt) {                
                    if ($menuItems[$selectedIndex].MultiSelected) {
                        $menuItems[$selectedIndex].MultiSelected = $false
                    }
                    else {
                        $menuItems[$selectedIndex].MultiSelected = $true
                    }
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    $buffer = $null
                    continue
                }
                if ($($menuItems[$selectedIndex].ItemName) -eq "A") {
                    foreach ($menuItem in $menuItems) {
                        if ($menuItem.Selectable) {
                            $optionInt = ($($menuItem.ItemName) -as [int])
                            if ($optionInt) {
                                $menuItem.MultiSelected = $true
                            }                           
                        }
                    }
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    $buffer = $null
                    continue
                }
                if ($($menuItems[$selectedIndex].ItemName) -eq "N") {
                    foreach ($menuItem in $menuItems) {
                        if ($menuItem.Selectable) {
                            $optionInt = ($($menuItem.ItemName) -as [int])
                            if ($optionInt) {
                                $menuItem.MultiSelected = $false
                            }                           
                        }
                    }
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    $buffer = $null
                    continue
                }

                if ($($menuItems[$selectedIndex].ItemName) -eq "D") {
                    return @($menuItems | Where-Object { $_.MultiSelected -eq $true })
                }
            }


            if ($buffer) {
                foreach ($menuItem in $menuItems) {
                    if ($menuItem.ItemName) {
                        if ($menuItem.ItemName.ToString().ToUpperInvariant() -eq $buffer.ToUpperInvariant()) {
                            $selectedIndex = $i
                            Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
                            return $menuItems[$selectedIndex]
                        }
                    }
                }
                $selectedIndex = -1
                Update-Prompt -PromptPosition $PromptPosition -buffer $buffer
                continue
               
            }
            else {
                Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
                return $menuItems[$selectedIndex]
            }
            
        }
        
        if ($key.VirtualKeyCode -eq 38) {
            # 38 = Up arrow key
            # If the selected index is greater than 0, move the selection up
            $buffer = $null
            $i = 0
            while ($true) {
                if ($i -gt $menuItems.Count) {
                    $selectedIndex = -1
                    break
                }
                if ($selectedIndex -gt 0) {
                    $selectedIndex-- # Decrement the selected index
                }
                else {
                    # If already at the top, cycle to the bottom
                    $selectedIndex = $menuItems.Count - 1
                }
                if ($menuItems[$selectedIndex].Selectable) {
                    break
                }
                $i++
            }
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect # Display the menu with the new selected index
        }
        
        if ($key.VirtualKeyCode -eq 40) {
            # 40 = Down arrow key
            # If the selected index is less than the last item, move the selection down
            $buffer = $null
            $i = 0
            while ($true) {
                if ($i -gt $menuItems.Count) {
                    $selectedIndex = -1
                    break
                }
                if ($selectedIndex -lt ($menuItems.Count - 1)) {
                    $selectedIndex++ # Increment the selected index
                }
                else {
                    # If already at the bottom, cycle to the top
                    $selectedIndex = 0
                }
                if ($menuItems[$selectedIndex].Selectable) {
                    break
                }
                $i++
            }
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect # Display the menu with the new selected index
        }

        if ($key.VirtualKeyCode -eq 8) {
            if ($buffer) {
                
                if ($buffer.Length -le 1) {
                    $buffer = $null
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    [System.Console]::CursorVisible = $false 
                }
                else {
                    $buffer = $buffer.Substring(0, $buffer.Length - 1)
                }
                Set-CursorPosition -X $PromptPosition.x -Y $PromptPosition.y
                write-host2 $buffer -NoNewline -ForegroundColor Yellow
                write-host " " -NoNewline

                if ($buffer) {
                    $i = 0
                    foreach ($menuItem in $menuItems) {
                        if ($menuItem.ItemName) {
                            if ($menuItem.ItemName.ToString().ToUpperInvariant() -eq $buffer.ToUpperInvariant()) {
                                $selectedIndex = $i
                                Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                                break
                            }
                        }
                        $i++       
                    }
                    Update-Prompt -PromptPosition $PromptPosition -buffer $buffer
                }
            }
            if (-not $buffer) {
                Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                Update-Prompt -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
            }
        }
        
        if ($key.VirtualKeyCode -eq 27 -or $key.VirtualKeyCode -eq 37) {
            if ($MultiSelect) {
                $Global:MenuHistory[$menuName] = @($menuItems | Where-Object { $_.MultiSelected -eq $true } | Select-Object -ExpandProperty Text)                
            }
            else {
                $Global:MenuHistory[$menuName] = $MenuItems[$selectedIndex].ItemName                
            }

            # 27 = Escape key
            Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
            #Write-Host "-> You pressed ESC to exit." -ForegroundColor Red # Display the selected menu item
            return "ESCAPE"
        }

        if ($key.Character.ToString().ToUpperInvariant() -in $ValidChars -or ($buffer -and $key.Character.ToString() -in @(0..9))) {
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex -1 -MultiSelect:$MultiSelect
            $buffer = $buffer + $key.Character.ToString().ToUpperInvariant()

            if ($buffer) {
                $i = 0
                $selectedIndex = -1
                foreach ($menuItem in $menuItems) {
                    if ($menuItem.ItemName) {
                        if ($menuItem.ItemName.ToString().ToUpperInvariant() -eq $buffer.ToUpperInvariant()) {
                            $selectedIndex = $i
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                            break
                        }
                    }
                    $i++       
                }
            }
            Update-Prompt -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        }
    }

    [System.Console]::CursorVisible = $true # Show the cursor
}



