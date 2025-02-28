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
        [AllowEmptyCollection()]
        [System.Collections.ArrayList][ref] $MenuItems,
        [string] $ItemName,
        [string] $ItemText,
        [string] $Color1 = $Global:Common.Colors.GenConfigNormal,
        [string] $Color2 = $Global:Common.Colors.GenConfigNormalNumber,
        [bool] $Selectable = $true,
        [bool] $Selected = $false,
        [string] $Function = $null,
        [string] $HelpText = $null,
        [string] $HelpFunction = $null        
    )


    if ($Selected -eq $true) {
        foreach ($menuItem2 in $MenuItems) {
            if ($menuItem2.Selected) {
                $Selected = $false
                break
            }
        }
    }
    $MenuItem = New-MenuItem -MenuItems ([ref]$MenuItems) -itemName $ItemName -text $ItemText -color1 $color1 -color2 $color2 -selectable:$selectable -selected:$selected -function $funtion -helpText $helpText -helpFunction $HelpFunction     

    
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
    
    #$MenuItems.Add($MenuItem) | out-null
    write-log -LogOnly "$($MenuItems.Count) Adding $MenuItem"
    return $MenuItem

}



function Update-MenuItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList][ref]$menuItems,
        [Parameter(Mandatory = $true)]
        [string]$itemname,
        [string]$text,
        [string]$color1,
        [string]$color2,
        [bool]$selectable = $false,
        [bool]$selected = $false,
        [string]$function,
        [bool]$multiSelected = $false,
        [bool]$displayed = $false,
        [string]$helptext
    )

    foreach ($menuItem in $menuItems) {
        if ($menuItem.ItemName -eq $itemname) {
            write-Log -verbose "Updating $menuItem"
            if ($text) {
                $menuItem.Text = $text
            }
            if ($color1) {
                $menuItem.Color1 = $color1
            }
            if ($color2) {
                $menuItem.Color2 = $color2
            }
            if ($PSBoundParameters.ContainsKey('selectable')) {
                $menuItem.selectable = $selectable
            }
            if ($PSBoundParameters.ContainsKey('selected')) {
                $menuItem.selectable = $selected
            }
            if ($function) {
                $menuItem.Function = $function
            }
            if ($PSBoundParameters.ContainsKey('multiSelected')) {
                $menuItem.multiSelected = $multiSelected
            }
            if ($PSBoundParameters.ContainsKey('displayed')) {
                $menuItem.displayed = $displayed
            }
            if ($helptext) {
                $menuItem.helptext = $helptext
            }
            break
        }
    }
    return $menuItems
}

function New-MenuItem {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList][ref]$menuItems,
        [string]$itemname,
        [string]$text,
        [string]$color1 = $Global:Common.Colors.GenConfigDefault,
        [string]$color2 = $Global:Common.Colors.GenConfigDefaultNumber,
        [switch]$selectable = $false,
        [switch]$selected = $false,
        [string]$function,
        [switch]$multiSelected = $false,
        [switch]$displayed = $false,
        [string]$helptext,
        [string]$helpFunction = $null
    )
    write-log -Verbose "Adding $itemName to menu.. Current Count $($menuItems.Count)"
    if ($text) {
        $TextValue = $text -split "%"

        if (-not [string]::IsNullOrWhiteSpace($TextValue[1])) {
            $color1 = $TextValue[1]
            if (-not [string]::IsNullOrWhiteSpace($TextValue[2])) {
                $color2 = $TextValue[2]
            }
            else {
                $color2 = $color1
            }
        }
        $text = $TextValue[0]
    }
    else {
        $TextValue = $null
    }

    if ($itemName) {
        if ($itemName.StartsWith("H") -and $ItemName.Length -gt 1) {
            $itemName = $itemName.SubString(1)
            write-log -verbose "Updated MenuItem with itemname '$itemName' with helptext $text"
            Update-MenuItem -menuItems ([ref]$menuItems) -itemname $itemName -helptext $text
            return
        }
        if ($itemName.StartsWith("*")) {            
            $selectable = $false
            if ($itemName.StartsWith("*F")) {
                $function = $text
                $text = $null
            }
            else {                    
                $function = $null                
            }   
            #$itemName = $null        
        }
    }
   
    $MenuItem = [PSCustomObject]@{
        itemName      = $itemname
        Text          = $text               
        Color1        = $color1
        Color2        = $color2
        Selectable    = $selectable
        Selected      = $selected
        Function      = $function
        MultiSelected = $multiSelected
        Displayed     = $displayed
        HelpText      = $helptext
    }

    if (-not $helptext -and $helpFunction) {
        Write-Log -Verbose "Running $HelpFunction $text"
        $HelpText = Invoke-Expression -Command "$HelpFunction -Text ""$text"""
    }

    if ($helptext) {
        $MenuItem.HelpText = $helptext
    }
    $MenuItems.Add($MenuItem) | out-null
    Write-Log -Verbose "Returning $MenuItem"    
    
    return $MenuItem
    
}

function Get-MenuItems {
    [CmdletBinding()]
    [OutputType([System.Collections.ArrayList])]
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
        [AllowEmptyCollection()]
        [System.Collections.ArrayList] $ExistingmenuItems = $null,
        [switch] $MultiSelect,
        [switch] $AllSelected,
        [switch] $split
    )


    if ($Global:MenuHistory) {
        if ($Global:MenuHistory[$menuName]) {
            $currentItem = $Global:MenuHistory[$menuName]
            Write-Log -verbose "[MenuHistory] found '$($currentItem -join ",")' for '$menuName'"
            $AllSelected = $false
        }              
    }

    $HelpFunction = $null
    Write-Log -verbose "Get-MenuItems started with CurrentValue = $CurrentValue"
    $foundSelected = $false
    $FoundMultiSelectItem = $false
    #Define an array of MenuItems

    $MenuItems = [System.Collections.ArrayList]@()
    Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"
  
    if ($ExistingmenuItems) {
        $MenuItems = $ExistingmenuItems       
    }    
    Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"
    if ($null -ne $preOptions) {
        foreach ($item in $preOptions.keys) {
            
            $value = $preOptions."$($item)"
            if ($item -eq "*HF") {
                $HelpFunction = $value
                write-log -verbose "Setting HelpFunction to $value"
                continue
            }
            $menuItem = New-MenuItem -MenuItems ([ref]$MenuItems) -selectable -text $value -itemname $item
            
            Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"
            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"

                if ($TextValue[0].StartsWith("$")) {
                    continue
                }
               
                if (-not $foundSelected) {
                    if ($item -eq $currentItem) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                        Write-Log -verbose "1FoundSelected True $item"
                    }
                    if ($CurrentValue) {
                        if ($item -eq $CurrentValue) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                            Write-Log -verbose "2FoundSelected True $item"
                        }
                        if ($TextValue[0] -eq $CurrentValue) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                            Write-Log -verbose "3FoundSelected True $item"
                        }
                    }
                }
                #$MenuItem.itemName = $item
                #$MenuItem.Text = $TextValue[0]
                #$MenuItems += $MenuItem
                             
            }
        }
    }

    if ($null -ne $additionalOptions) {
        foreach ($item in $additionalOptions.keys) {
            $value = $additionalOptions."$($item)"
            if ($item -eq "*HF") {
                $HelpFunction = $value
                write-log -verbose "Setting HelpFunction to $value in Additional Options"
                break
            }
        }
    }

    $i = 0

    foreach ($option in $OptionArray) {
        if (-not [String]::IsNullOrWhiteSpace($option)) {
            $i = $i + 1
            $item = $option
            $menuItem = New-MenuItem -MenuItems ([ref]$MenuItems) -selectable -text $item -color1 $Global:Common.Colors.GenConfigNormal -color2 $Global:Common.Colors.GenConfigDefaultNumber  
            Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"         

            if (-not [String]::IsNullOrWhiteSpace($item)) {
                
                $TextValue = $item -split "%"

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
                            Write-Log -verbose "4FoundSelected True $i"
                            
                        }
                        if ($CurrentValue) {
                            if ($item -eq $CurrentValue) {
                                $MenuItem.Selected = $true
                                $foundSelected = $true
                                Write-Log -verbose "5FoundSelected True $i"
                            }
                            if ($TextValue[0] -eq $CurrentValue) {
                                $MenuItem.Selected = $true
                                $foundSelected = $true
                                Write-Log -verbose "6FoundSelected True $i"
                            }
                        }
                    }
                }
                $MenuItem.itemName = [string]$i

                if ($HelpFunction) {
                    Write-Log -Verbose "Running $HelpFunction $item"
                    if ($HelpFunction -eq "Get-NewDomainConfigHelp") {
                        $menuItem.HelpText = Get-NewDomainConfigHelp $item
                    }
                    else {
                        $menuItem.HelpText = Invoke-Expression -Command "& $HelpFunction ""$item"""
                    }
                }
                #$MenuItem.Text = $TextValue[0]
                #$MenuItems += $MenuItem   
                $FoundMultiSelectItem = $true                   
            }
        }
    }

    if ($null -ne $additionalOptions) {
        foreach ($item in $additionalOptions.keys) {
            $value = $additionalOptions."$($item)"
            if ($item -eq "*HF") {                
                continue
            }
            Write-Log -verbose "MenuItem Before $MenuItem"
            $MenuItem = New-MenuItem -MenuItems ([ref]$MenuItems) -selectable -text $value -itemname $item
            Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"
            Write-Log -verbose "New-MenuItem returned $MenuItem"
            if (-not [String]::IsNullOrWhiteSpace($item)) {
                $TextValue = $value -split "%"
                
                if ($TextValue[0].StartsWith("$")) {
                    continue
                }
                
                if (-not $foundSelected) {
                    if ($item -eq $currentItem) {
                        $MenuItem.Selected = $true
                        $foundSelected = $true
                        Write-Log -verbose "7FoundSelected True $item"
                    }
                    if ($CurrentValue) {
                        if ($item -eq $CurrentValue) {
                            Write-Log -verbose "8FoundSelected True $item $MenuItem"
                            $MenuItem.Selected = $true
                            $foundSelected = $true                            
                        }
                        if ($TextValue[0] -eq $CurrentValue) {
                            $MenuItem.Selected = $true
                            $foundSelected = $true
                            Write-Log -verbose "9FoundSelected True $item"
                        }
                    }
                }
                #$MenuItem.itemName = $item
                #$MenuItem.Text = $TextValue[0]
                #$MenuItems += $MenuItem   
            }
        }
    }

    if ($MultiSelect -and $FoundMultiSelectItem) {
        
        $null = New-MenuItem -MenuItems ([ref]$MenuItems) -ItemName "*B"
        $null = New-MenuItem -MenuItems ([ref]$MenuItems) -ItemName "A" -text "All Entries" -color1 $Global:Common.Colors.GenConfigTrue -color2 $Global:Common.Colors.GenConfigTrue -selectable  -helptext "Select all multi-select entries"      
        $null = New-MenuItem -MenuItems ([ref]$MenuItems) -ItemName "N" -text "No Entries" -color1 $Global:Common.Colors.GenConfigFalse -color2 $Global:Common.Colors.GenConfigFalse -selectable  -helptext "De-select all multi-select entries"               
        $null = New-MenuItem -MenuItems ([ref]$MenuItems) -ItemName "D" -text "Done with selections" -color1 $Global:Common.Colors.GenConfigDefault -color2 $Global:Common.Colors.GenConfigDefaultNumber -selectable -selected -helptext "Confirm multi-select entries and continue"       

    }
    Write-Log -Verbose "MenuItems is currently $MenuItems $($MenuItems.GetType())"
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
        $null = New-MenuItem -MenuItems ([ref]$MenuItems)
    }
    write-log -verbose "Returning $MenuItems of type $($MenuItems.GetType())"
    return (, [System.Collections.ArrayList]$MenuItems) # Return the menu items
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
        [AllowEmptyCollection()]
        [System.Collections.ArrayList] $menuItems = $null,
        [Parameter(Mandatory = $false, HelpMessage = "Do Not clear the screen.. Dangerous")]
        [switch] $NoClear,
        [switch] $MultiSelect,
        [switch] $AllSelected
    )

    $host.ui.RawUI.FlushInputBuffer()
    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'Continue'
    try {
        if (!$NoNewLine) {
            write-Host
            Write-Verbose "[$menuName] 4 Get-Menu2"
        }

        if ($null -eq $menuItems) {
        
            $temp = Get-MenuItems -OptionArray $OptionArray -CurrentValue $CurrentValue -additionalOptions $additionalOptions -preOptions $preOptions -menuName $MenuName -MultiSelect:$MultiSelect -AllSelected:$AllSelected -split:$split
            write-log -verbose "Get-MenuItems returned $temp. type: $($temp.GetType())"
            $menuItems = $temp
            Write-Log -LogOnly "[$menuName] [Get-Menu2] MenuItems Count $($menuItems.Count) '$menuItems'"
        }
   
        if (-not $Global:MenuHistory) {
            $Global:MenuHistory = @{}
        }
        Write-Log -LogOnly "[$menuName] [Get-Menu2] MenuItems Count $($menuItems.Count) '$menuItems'"
        #foreach ($menuItem in $menuItems) {
        #    write-host "[Get-Menu2] Item: $menuItem"
        #}
        $response = Show-Menu -menuName $MenuName -menuItems ([ref]$menuItems) -NoClear:$false -MultiSelect:$MultiSelect
        if ($response -is [array] -or $response.MultiSelected) {
            $ReturnValue = @()
            foreach ($item in $response) {
                $ReturnValue += $item.Text
            }
            #$ReturnValue = @($response | Select-Object -ExpandProperty Text)
            $Global:MenuHistory[$menuName] = $ReturnValue
            write-log -verbose "[MenuHistory] [Array] Setting $menuName to $ReturnValue with $($ReturnValue.Count) items"
            #$returnValue = @($ReturnValue | ForEach-Object { $_ })
            return $ReturnValue
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
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}


function Get-RoomLeftFromCurrentPosition {
    $WindowSizeY = ($host.UI.RawUI.WindowSize.Height - 6) # Get the height of the console window, subtract 1 since its 0 based, subtract 4 for the help
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
        [AllowEmptyCollection()]
        [System.Collections.ArrayList][ref]$menuItems, # The array of menu items
        [Switch]$NoClear = $false,
        [Switch]$MultiSelect = $false

    )
    $LongestBreakLine = 0
    $Operation = ""
    While ($true) {
        $found = $false
        $HelpFound = $false
        $HelpNeeded = $false
        foreach ($menuitem in $menuItems) {
            if ($operation -eq "PGUP") {
                $menuitem.Displayed = $false
            }

            if ($operation -eq "PGDN") {
                if ($menuitem.Displayed -eq $false -and $menuitem.Selectable) {
                    $found = $true
                }
            }
            if ($menuitem.itemName.StartsWith("*B")) {
                $len = $menuitem.Text.Length
                if ($len -gt $LongestBreakLine) {
                    $LongestBreakLine = $len
                }
            }
            if ($menuitem.itemname -eq "*HELP") {
                $HelpFound = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($menuitem.HelpText)) {
                $HelpNeeded = $true
            }
        }
        if ($operation -eq "PGDN" -and -not $found) {
            foreach ($menuitem in $menuItems) {
                $menuitem.Displayed = $false
            }
            $operation = ""
        }

        
       
        $WindowSizeY = $host.UI.RawUI.WindowSize.Height - 1 # Get the height of the console window, subtract 1 since its 0 based
        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        $RoomLeft = Get-RoomLeftFromCurrentPosition
        $RoomLeft -= $ErrorCount
        if ($NoClear -and $RoomLeft -lt $menuItems.Count) {
            $NoClear = $false
        }

        if (-not $NoClear) {
            Write-Host "`e[2J`e[H"
            #$NoClear = $true
        }
        
        Write-Log -Activity $menuName

        $RoomLeft = Get-RoomLeftFromCurrentPosition

        if ($RoomLeft -lt $menuItems.Count) {
            Write-Host "`e[2J`e[H" #Try Clearing the screen again.  Maybe this gives us enough room.
        }
        if (-not $HelpFound -and $HelpNeeded) {
            $HelpPosition = Get-CursorPosition
            Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText "" -Color None -wait:$false
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
            if ($operation -eq "PGDN") {
                if ($menuItem.Displayed) {
                    $menuItem.Displayed = $false
                    continue
                }
                if (-not $menuItem.Displayed -and $menuitem.Selectable) {
                    $operation = "PGDNDone"
                }
            }
            $RoomLeft = Get-RoomLeftFromCurrentPosition
            if ($RoomLeft -le 3) {
                $menuItem.Displayed = $false                
                $Operation = "PgDnNeeded"
                continue
            }
            $CurrentPosition = Get-CursorPosition
            Set-CursorPosition -x 0 -y $CurrentPosition.Y  # Make sure we are at the beginning of the line   

            if ($menuItem.Function) {
                $menuItem.Displayed = $true
                Invoke-Expression -Command $menuItem.Function
                
                continue
            }
            if ($menuitem.Selectable) {
                if ($menuItem.Selected) {
                    #$arrow = "-> " 
                    #$arrow = "⟶ "
                    #$arrow = "➤ "
                    $arrow = "━➤ "
                    Write-Host $arrow -ForegroundColor Yellow -NoNewline
                }
                else {
                    Write-Host "   " -ForegroundColor Cyan -NoNewline
                }
            }

        

            
            $CurrentPosition = Get-CursorPosition
            $menuItem | Add-Member -MemberType NoteProperty -Name "CurrentPosition" -Value $CurrentPosition.Y -force
            if ($menuItem.Selectable) {    
                Set-CursorPosition -x 3 -y $CurrentPosition.Y  # Make sure we are at the beginning of the line       
                Write-Option $menuItem.itemName $menuItem.Text -color $menuItem.Color1 -Color2 $menuItem.Color1 -MultiSelect:$MultiSelect -MultiSelected:$menuItem.MultiSelected
                $menuItem.Displayed = $true
            }
            else {
                if ($Maxshrink) {
                    continue
                }
                if ($shrink -and [string]::IsNullOrWhiteSpace($menuItem.Text)) {
                    continue
                }

                $StartDashColor = "SlateGray"
                $EndDashColor = "SlateGray"
                $indentSpaces = 3
                $center = $true
                $SpacesAroundWords = 4
                $StartDashes = 3

                if ($menuItem.itemName -eq "*HELP") {
                    $HelpPosition = Get-CursorPosition
                    Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText "" -Color None -wait:$false
                    continue
                }

                if ($menuItem.itemName.StartsWith("*B") -and -not [string]::isnullorwhitespace($menuitem.Text)) {
                    if ($center) {

                        $NumOfDash = [math]::Round((($LongestBreakLine - $menuitem.Text.Length) + ($SpacesAroundWords * 2) + 2 ) / 2)
                        $breakPrefix = "─" * $NumOfDash
                        if ([bool](($LongestBreakLine - $menuitem.Text.Length) % 2)) {
                            $NumOfDash += 1
                        }
                        $breakPostfix = "─" * $NumOfDash                        
                    }
                    else {
                        $NumOfDash = [math]::Round((($LongestBreakLine - $menuitem.Text.Length) + ($SpacesAroundWords * 2) - $StartDashes))
                        $breakPrefix = "─" * $StartDashes
                        $breakPostfix = "─" * $NumOfDash 
                    }
                    $WordSpace = " " * $SpacesAroundWords
                    
                    Write-Host2 $(" " * $indentSpaces) -NoNewline
                    Write-Host2 -ForegroundColor $StartDashColor $($breakPrefix + $WordSpace) -NoNewline
                    write-host2 -ForeGroundColor $menuItem.Color1 $menuItem.Text -NoNewline
                    Write-Host2 -ForegroundColor $EndDashColor $($WordSpace + $breakPostfix)
                    
                }
                else {
                    #Write-Host2 -ForegroundColor "MediumPurple" $menuItem.itemName -NoNewline
                    write-host2 -ForeGroundColor $menuItem.Color1 $menuItem.Text
                }
                $menuItem.Displayed = $true
            }                        
            
        }   
        $CurrentPosition = (Get-CursorPosition).Y - $menuItems.Count 

        $AnySelections = $menuItems | Where-Object { $_.Selectable }
        if ($AnySelections) {
            $prompt = "Press Enter to select, Up/Down/Left/Right to navigate, ESC to exit"
        }
        else {
            $prompt = "No Selections. Press Left/Enter or Escape to exit"
        }
        #$currentValue = "T"
        if (-not $Maxshrink) {
            Write-Host ""
        }
        if ($Operation -eq "PGDNDone") {
            $Operation = ""
            Write-Host2
            Write-Host2 "Press [PgUp] to see more" -ForegroundColor Yellow
        }
        if ($Operation -eq "PGDNNeeded") {
            $Operation = ""
            Write-Host2
            Write-Host2 "Press [PgDn] to see more" -ForegroundColor Yellow
        }
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
        $PromptPosition = Get-CursorPosition               
        $return = Start-Navigation -menuItems $MenuItems -startOfmenu $MenuStart -PromptPosition $PromptPosition -HelpPosition $HelpPosition -MultiSelect:$MultiSelect
        Set-CursorPosition -x $PromptPosition.X -y $PromptPosition.Y
        write-host
        if ($return) {
            
            if (-not [string]::IsNullOrWhiteSpace($return.Action)) {
                $operation = $return.Action
                write-log -verbose "OP: $operation"
                #Start-Sleep -seconds 1
            }
            else {
                write-log -verbose "Ret: '$return' Type: $($return.GetType())"
                #if ($return.GetType() -eq "System.Object[]") {
                $return = $return | ForEach-Object { $_ }
                write-log -verbose "Ret2: '$return' Type: $($return.GetType()) count: $($return.Count)"
                #}
                return $return
            }
        }
        else {
            write-log -verbose "NoRet: $return"
        }
    }


}

# Set the pointer display as per the menu
function Set-PointerDisplayAsPerMenu {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$menuItems, # The array of menu items

        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$selectedIndex,
        [switch]$MultiSelect = $false,
        [switch]$Wait
    )
    [System.Console]::CursorVisible = $false
    for ($i = 0; $i -lt $menuItems.Count; $i++) {
        if (-not ($menuItems[$i].Displayed)) {
            continue
        }
        if ($menuItems[$i].Selectable) {
            Set-CursorPosition -x 0 -y $menuItems[$i].CurrentPosition
            if ($i -eq $selectedIndex) {
                $menuItems[$i].Selected = $true
                
                if ($wait) {
                    $arrow = "⏳ "
                    $color = "Red"
                }
                else {
                    $arrow = "━➤ "
                    $color = "Yellow"
                }
                
                Write-Host $arrow -ForegroundColor $color -NoNewline
                #Write-Host $arrow -ForegroundColor Yellow
            
            }
            else {
                $menuItems[$i].Selected = $false
                Write-Host "   "
            }
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


Function Update-HelpText {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$HelpPosition, # The cursor position

        [Parameter(Mandatory = $false)]
        [string]$CurrentHelpText, # The buffer to display
        [Parameter(Mandatory = $false)] 
        [string]$Color, 
        [switch] $wait # HourGlass is showing
    )

    Set-CursorPosition -X $HelpPosition.X -Y $HelpPosition.Y 

    #Write-Host           
    Write-Host (" " * ($host.UI.RawUI.WindowSize.Width - 2))
    Write-Host (" " * ($host.UI.RawUI.WindowSize.Width - 2))
    Write-Host (" " * ($host.UI.RawUI.WindowSize.Width - 2))  
    if (-not [string]::IsNullOrWhiteSpace($CurrentHelpText) -and -not $wait) {         
        Set-CursorPosition -X 0 -Y $HelpPosition.Y
        write-host2 " ╭───────────────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor MediumOrchid
        write-host2 " │" -nonewline -ForegroundColor MediumOrchid
        write-host2 "🕮  " -ForegroundColor BlanchedAlmond -noNewLine
        write-host2 "$CurrentHelpText" -foregroundColor $Color
        write-host2 " ╰───────────────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor MediumOrchid
    
    }
}

function Update-Prompt {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$PromptPosition, # The cursor position
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$HelpPosition, # The cursor position
        [Parameter(Mandatory = $false)] # Mandatory parameter
        [string]$buffer, # The buffer to display

        [Parameter(Mandatory = $false)] # Mandatory parameter
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$MenuItems = $null,

        [Parameter(Mandatory = $false)] # Mandatory parameter
        [int]$SelectedIndex = -1,
        [switch] $wait # HourGlass is showing

    )
    [System.Console]::CursorVisible = $false
    $CurrentValue = $null
    $cursorPosition = Get-CursorPosition # Get the current cursor position
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    write-host "             " -NoNewline
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    if ($MenuItems -and $selectedIndex -ne -1) {
        if ($MenuItems[$selectedIndex].Selectable) {
            $CurrentValue = $MenuItems[$selectedIndex].ItemName
            $CurrentHelpText = $MenuItems[$selectedIndex].HelpText
            $CurrentColor = $MenuItems[$selectedIndex].Color1            
        }
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
        #[System.Console]::CursorVisible = $true 
    }
    $BlinkLocation = Get-CursorPosition

    Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText $CurrentHelpText -Color $CurrentColor -wait:$wait
    #$roomleft = Get-RoomLeftFromCurrentPosition
    #if ($roomleft -ge 3) {
    #  Update-HelpText -HelpPosition $BlinkLocation -CurrentHelpText $CurrentHelpText -Color $MenuItems[$selectedIndex].Color1 -wait:$wait
    #}    
    Set-CursorPosition -X $BlinkLocation.X -Y $BlinkLocation.Y
    [System.Console]::CursorVisible = $true 
}

# Start the navigation menu
# The navigation menu is started with the specified menu items and selected index
function Start-Navigation {
    param (
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [AllowEmptyCollection()]
        [System.Collections.ArrayList]$menuItems, # The array of menu items
        
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [int]$startOfmenu, # The selected index
        [Parameter(Mandatory = $true)] # Mandatory parameter
        [object]$PromptPosition, 
        [object]$HelpPosition, 
        [switch]$MultiSelect = $false
    )

    $i = 0
    $selectedIndex = 0
    $NumSelectable = 0
    $ValidChars = @()
    $foundSelected = $false
    foreach ($menuItem in $menuItems) {
        if ($null -ne $menuItem.itemName -and $menuItem.Selectable) {
            $ValidChars += $menuItem.itemName.ToString().Substring(0, 1).ToUpperInvariant()
            $NumSelectable++
            write-log -logonly "Found Selectable Item $menuItem" 
        }

        if ($menuItem.Selected -and $menuItem.Displayed) {
            $foundSelected = $true
            $selectedIndex = $i
        }
        $i++       
    }
    $i = 0
    if (-not $foundSelected) {
        foreach ($menuItem in $menuItems) {
            if ($menuItem.Selectable -and $menuItem.Displayed) {
                $selectedIndex = $i
                break
            }
            $i++
        }
    }
    Write-log -Verbose "Start-Navigation NumSelectable: $NumSelectable $ValidChars"

    $CPosition = Get-CursorPosition # Get the current cursor position
    [System.Console]::CursorVisible = $false # Hide the cursor
    $startSize = $Host.UI.RawUI.WindowSize
    # Loop until the user presses the Escape key
    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
    #Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText $menuItems[$selectedIndex].HelpText -Color $menuItems[$selectedIndex].Color1 -wait:$false
    while ($true) {
        $currentsize = $Host.UI.RawUI.WindowSize
        if ($currentsize -ne $startSize) {
            return
        }

        #Update-Prompt -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        
        $key = Get-KeyStroke # Get the key stroke from the user
        $currentsize = $Host.UI.RawUI.WindowSize
        if ($currentsize -ne $startSize) {
            return
        }
        # Handle the key stroke

        if ($key.VirtualKeyCode -eq 34 -or $key.VirtualKeyCode -eq 33) {
            # PGDN = 34, PGUP = 33
            $MoreItems = $false
            foreach ($item in $menuItems) {
                if ($item.Selectable -and -not $item.Displayed ) {
                    $MoreItems = $true
                    break
                }
            }
            if ($MoreItems) {
                if ($key.VirtualKeyCode = 34) {
                    $return = [PSCustomObject]@{
                        Action      = "PGDN"
                        CurrentMenu = $MenuItems
                    }
                    return $return
                }
                if ($key.VirtualKeyCode -eq 33) {
                    $return = [PSCustomObject]@{
                        Action      = "PGUP"
                        CurrentMenu = $MenuItems
                    }
                    return $return
                }
            }
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        }
       
        if ($key.VirtualKeyCode -eq 13 -or $key.VirtualKeyCode -eq 39 -or $key.Character -eq " ") {
            # 13 = Enter key, 39 = Right arrow key
            Write-Log -verbose -LogOnly "Entering return function"
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
            if ($NumSelectable -eq 0) {
                Write-Log -verbose -LogOnly "Entering return function - Return ESCAPE"
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

                    $buffer = $null
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
                    Write-Log -verbose -LogOnly "Entering return function - Int selected"
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

                    $buffer = $null
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
                    Write-Log -verbose -LogOnly "Entering return function - A selected"
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

                    $buffer = $null
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex                    
                    Write-Log -verbose -LogOnly "Entering return function - N selected"
                    continue
                }

                if ($($menuItems[$selectedIndex].ItemName) -eq "D") {

                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect -Wait
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                    $return = [array]($menuItems | Where-Object { $_.MultiSelected -eq $true })
                    if (-not $return) {
                        return "NOITEMS"
                    }                 
                    return $return
                }
            }


            if ($buffer) {
                foreach ($menuItem in $menuItems) {
                    if ($menuItem.ItemName) {
                        if ($menuItem.ItemName.ToString().ToUpperInvariant() -eq $buffer.ToUpperInvariant()) {
                            $selectedIndex = $i
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -Wait
                            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                            Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
                            return $menuItems[$selectedIndex]
                        }
                    }
                }
                $selectedIndex = -1
                Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer

                continue
               
            }
            else {
                
                Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -Wait
                Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
                return $menuItems[$selectedIndex]
            }
            
        }
        
        if ($key.VirtualKeyCode -eq 38 -or $key.VirtualKeyCode -eq 0x23 -or $key.VirtualKeyCode -eq 34) {
            # 38 = Up arrow key
            # 0x23 = END key
            
            # If the selected index is greater than 0, move the selection up
            if ($key.VirtualKeyCode -eq 0x23 -or $key.VirtualKeyCode -eq 34) {
                $selectedIndex = -1
            }
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
                if ($menuItems[$selectedIndex].Selectable -and $menuItems[$selectedIndex].Displayed) {
                    break
                }
                $i++
            }
            
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect # Display the menu with the new selected index
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        }
     
        if ($key.VirtualKeyCode -eq 40 -or $key.VirtualKeyCode -eq 0x24 -or $key.VirtualKeyCode -eq 33) {
            # 40 = Down arrow key
            # 0x24 = HOME key
            # If the selected index is less than the last item, move the selection down
            
            $buffer = $null
            if ($key.VirtualKeyCode -eq 0x24 -or $key.VirtualKeyCode -eq 33) {
                $selectedIndex = -1
            }
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
                if ($menuItems[$selectedIndex].Selectable -and $menuItems[$selectedIndex].Displayed) {
                    break
                }
                $i++
            }            
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect # Display the menu with the new selected index
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
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
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer
                }
            }
            if (-not $buffer) {
                Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
            }
        }
        
        if ($key.VirtualKeyCode -eq 27 -or $key.VirtualKeyCode -eq 37) {
            if ($MultiSelect) {
                $Global:MenuHistory[$menuName] = @($menuItems | Where-Object { $_.MultiSelected -eq $true } | Select-Object -ExpandProperty Text)                
            }
            else {
                $Global:MenuHistory[$menuName] = $MenuItems[$selectedIndex].ItemName                
            }
            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -Wait -MultiSelect:$MultiSelect
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
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
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        }
    }

    [System.Console]::CursorVisible = $true # Show the cursor
}



