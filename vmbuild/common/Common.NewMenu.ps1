############################
### Menu Functions ###
############################
#Common.NewMenu.ps1

# Offers a menu for any array passed in.
# This is used for Sql Versions, Roles, Etc

# Description: This script demonstrates how to create a simple navigation menu in PowerShell.

# Get the current cursor position as a Coordinates object (X, Y) from the console.
function Get-CursorPosition {
    $pos = $Host.UI.RawUI.CursorPosition
    return @{x = $pos.X; y = $pos.Y }
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
    # Using ::new() is significantly faster than New-Object in hot paths
    $Host.UI.RawUI.CursorPosition = [System.Management.Automation.Host.Coordinates]::new($X, $Y)
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
        [bool] $Deletable = $false,
        [string] $Function = $null,
        [string] $HelpText = $null,
        [string] $HelpFunction = $null        
    )


    if ($Selected -eq $true) {
        write-log "Found pre-selected item for $ItemName $ItemText"
        foreach ($menuItem2 in $MenuItems) {
            if ($menuItem2.Selected) {
                $menuItem2.Selected = $false                
            }
        }
    }
    $MenuItem = New-MenuItem -MenuItems ([ref]$MenuItems) -itemName $ItemName -text $ItemText -color1 $color1 -color2 $color2 -selectable:$selectable -selected:$Selected -function $Function -helpText $helpText -helpFunction $HelpFunction -Deletable:$Deletable  

    
    if ($Global:MenuHistory) {
        if ($Global:MenuHistory[$menuName]) {
            $currentItem = $Global:MenuHistory[$menuName]
            #Write-Log "found $currentItem for $menuName"
        }              
    }


    if ($Selected -eq $false) {
        if ($ItemName -eq $currentItem) {
            foreach ($menuItem2 in $MenuItems) {
                $menuItem2.Selected = $false
            }
            $MenuItem.Selected = $true
            write-log "Setting Selected to $ItemName $ItemText"
        }
    }
    
    #$MenuItems.Add($MenuItem) | out-null
    # -Verbose (was -LogOnly): this fires on every Add-MenuItem call, dozens of times per
    # menu redraw. Forcing a disk write + Get-PSCallStack walk per item makes the
    # property menu feel sluggish to load. Demote to verbose so it only logs when the
    # user explicitly enabled verbose diagnostics.
    write-log -Verbose "$($MenuItems.Count) Adding $MenuItem"
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
        [string]$helpFunction = $null,
        [switch]$deletable = $false
    )
    write-log -Verbose "Adding $itemName to menu.. Current Count $($menuItems.Count) Deletable: $deletable Selected: $selected"
    $linecount = 0
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
        $linecount = 1        
    }
    else {
        $TextValue = $null
        $linecount = 0
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
                #write-host "Running Function $function -LineCount" 
                $linecount = Invoke-Expression -Command "$function -LineCount"                             
            }
            elseif ($itemName -eq "*HELP") {
                $function = $null
                $linecount = $script:MenuLayout.HelpBannerLines  # see Update-HelpText: top border + text + bottom border
            }
            else {                    
                $function = $null   
                $linecount = 1             
            }   
            #$itemName = $null        
        }
        if ($itemName.StartsWith("-D") -and $ItemName.Length -gt 2) {
            $itemName = $itemName.SubString(2)
            $deletable = $true
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
        LineCount     = $linecount
        MultiSelected = $multiSelected
        Displayed     = $displayed
        HelpText      = $helptext
        Operation     = $null
        Deletable     = $deletable
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
        [Parameter(Mandatory = $false, HelpMessage = "Suppress newline")]
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
        [switch] $AllSelected,
        [switch] $AcceptsDelete
    )

    $host.ui.RawUI.FlushInputBuffer()
    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue' # Suppress progress bar output
    try {
        if (!$NoNewLine) {
            write-Host
            Write-Verbose "[$menuName] 4 Get-Menu2"
        }

        if ($null -eq $menuItems) {
        
            $temp = Get-MenuItems -OptionArray $OptionArray -CurrentValue $CurrentValue -additionalOptions $additionalOptions -preOptions $preOptions -menuName $MenuName -MultiSelect:$MultiSelect -AllSelected:$AllSelected -split:$split
            write-log -verbose "Get-MenuItems returned $temp. type: $($temp.GetType())"
            $menuItems = $temp
            Write-Log -Verbose "[$menuName] [Get-Menu2] MenuItems Count $($menuItems.Count) '$menuItems'"
        }
   
        if (-not $Global:MenuHistory) {
            $Global:MenuHistory = @{}
        }
        # Was a duplicate -LogOnly write of the same MenuItems summary. Both interpolate the
        # entire $menuItems collection (one ToString per item) and write to disk on every
        # Get-Menu2 call. Demoted to verbose to keep menu loads snappy.
        Write-Log -Verbose "[$menuName] [Get-Menu2] MenuItems Count $($menuItems.Count) '$menuItems'"
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
                if ($response.Operation -eq "DELETE") {
                    if ($AcceptsDelete) {
                        $response = "-D" + $response.itemName
                        
                    }
                    else {
                        return
                    }
                }
                else {
                    $response = $response.itemName                    
                }

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
        Write-Log -LogOnly  "[$menuName] [Get-Menu2] Did not Return Anything"
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}


function Get-RoomLeftFromCurrentPosition {
    # Reserve rows for the post-menu fixtures that Show-Menu always paints
    # below the items: the PgDn indicator (blank + text) and the prompt
    # (blank + prompt line). RoomLeft is therefore the budget for items +
    # help banner only -- the fixtures are pre-subtracted here so the rest
    # of the layout math doesn't have to think about them.
    $reserved = $script:MenuLayout.PgIndicatorLines + $script:MenuLayout.PromptLines
    $WindowSizeY = $host.UI.RawUI.WindowSize.Height - $reserved
    $CurrentPosition = $Host.UI.RawUI.CursorPosition
    # Use viewport-relative Y so scroll buffer history doesn't shrink available space.
    # CursorPosition.Y is absolute buffer row; WindowPosition.Y is the buffer row at
    # the top of the visible viewport. The difference is the cursor's visual row.
    $viewportTop = $Host.UI.RawUI.WindowPosition.Y
    $relativeY = $CurrentPosition.Y - $viewportTop
    $RoomLeft = ([int]$WindowSizeY - [int]$relativeY)
    return $RoomLeft
}

# Layout constants used by Show-Menu's line-counting math. Single source of
# truth -- consumers (Get-RoomLeftFromCurrentPosition, Get-MenuMetrics,
# Update-HelpText, New-MenuItem, render-loop lookahead) all reference these
# so layout dimensions can't drift apart.
$script:MenuLayout = @{
    HelpBannerLines  = 3   # Update-HelpText paints: top border + text + bottom border.
                           # Text is truncated to one visual row (see Update-HelpText),
                           # so this is an enforced invariant, not an estimate.
    PromptLines      = 2   # Update-Prompt: blank spacer + prompt line
    PgIndicatorLines = 2   # Write-MenuPgIndicator: blank spacer + "Press [PgDn]" line
    TextWidthSlack   = 9   # Reserved leading columns for indent + arrow + numeric prefix;
                           # text is treated as wrapped when length > WindowWidth - this
}

# Page-state constants used by Show-Menu's PgUp/PgDn state machine. Centralized
# so callers compare against a typo-safe symbol instead of bare string literals.
# Start-Navigation produces 'PGUP'/'PGDN'; the render loop produces PgDnNeeded/
# PgDnDone while walking items.
$script:MenuOp = @{
    None       = ''
    PgUp       = 'PGUP'
    PgDn       = 'PGDN'
    PgDnNeeded = 'PgDnNeeded'
    PgDnDone   = 'PgDnDone'
}

# Classify a menu item into one of five kinds. Single source of truth for both
# the layout-shrink logic (which only cares about the 4 non-selectable kinds:
# Function | Header | Blank | Help) and the render loop dispatch (which also
# distinguishes Selectable). Replaces ad-hoc StartsWith/-eq checks scattered
# through the render path.
function Get-MenuItemKind {
    param([Parameter(Mandatory)] $MenuItem)
    if ($MenuItem.Selectable) { return 'Selectable' }
    if ($MenuItem.Function)   { return 'Function' }   # *F (function-rendered summary)
    $name = [string]$MenuItem.itemName
    if ($name -eq '*HELP') { return 'Help' }
    if ($name.StartsWith('*B') -and -not [string]::IsNullOrWhiteSpace($MenuItem.Text)) {
        return 'Header'
    }
    return 'Blank'   # *V ruler, *B/*D spacer with empty text, anything else non-selectable
}

# Sum the rows that items at/after StartIndex would consume during the upcoming
# render pass, respecting the current Shrink plan. Used by the pagination
# lookahead to decide whether trailing items would fit inline (avoiding a
# wasted PgDn page that only holds 1-2 items).
function Get-RemainingMenuRows {
    param(
        [Parameter(Mandatory)][System.Collections.IList]$MenuItems,
        [Parameter(Mandatory)][int]$StartIndex,
        [Parameter(Mandatory)][hashtable]$Shrink
    )
    $wrapAt = $host.UI.RawUI.WindowSize.Width - $script:MenuLayout.TextWidthSlack
    $rows = 0
    for ($i = $StartIndex; $i -lt $MenuItems.Count; $i++) {
        $mi = $MenuItems[$i]
        $kind = Get-MenuItemKind -MenuItem $mi
        if ($kind -ne 'Selectable' -and $Shrink[$kind]) { continue }
        $rows += Get-MenuItemRows -MenuItem $mi -WrapAt $wrapAt
    }
    return $rows
}

# Render the "Press [PgDn]/[PgUp]/[PgUp/PgDn] to see more" indicator and its
# preceding spacer blank. Returns $true when an indicator was actually written.
# Consolidates the three near-duplicate if/elseif branches.
function Write-MenuPgIndicator {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][bool]$PgUpAvailable
    )
    $pgDnNeeded = ($Operation -eq $script:MenuOp.PgDnNeeded)
    $pgDnDone   = ($Operation -eq $script:MenuOp.PgDnDone)
    if (-not $pgDnNeeded -and -not $pgDnDone) { return $false }

    Write-Host2
    if ($pgDnDone) {
        Write-Host2 'Press [PgUp] to see more' -ForegroundColor Yellow
    }
    elseif ($PgUpAvailable) {
        Write-Host2 'Press [PgUp/PgDn] to see more' -ForegroundColor Yellow
    }
    else {
        Write-Host2 'Press [PgDn] to see more' -ForegroundColor Yellow
    }
    return $true
}

# Render a centered "───  Heading Text  ───" break line. Extracted from the
# render loop so the per-kind switch stays declarative.
function Write-MenuHeader {
    param(
        [Parameter(Mandatory)] $MenuItem,
        [Parameter(Mandatory)][int]$LongestBreakLine
    )
    $indentSpaces      = 3
    $spacesAroundWords = 4
    $dashColor         = 'SlateGray'

    $textLen   = $MenuItem.Text.Length
    $padding   = ($LongestBreakLine - $textLen) + ($spacesAroundWords * 2) + 2
    $numOfDash = [math]::Round($padding / 2)
    $prefix    = '─' * $numOfDash
    if ((($LongestBreakLine - $textLen) % 2) -ne 0) { $numOfDash += 1 }
    $postfix   = '─' * $numOfDash
    $wordSpace = ' ' * $spacesAroundWords

    Write-Host2 (' ' * $indentSpaces) -NoNewline
    Write-Host2 -ForegroundColor $dashColor ($prefix + $wordSpace) -NoNewline
    Write-Host2 -ForegroundColor $MenuItem.Color1 $MenuItem.Text -NoNewline
    Write-Host2 -ForegroundColor $dashColor ($wordSpace + $postfix)
}

# Single source of truth for "how many viewport rows does this item consume?".
# Accounts for the +1 wrap row when the item's text exceeds the wrap width.
# All line-counting paths (total, per-tier, and lookahead) call this so the
# numbers can't drift apart.
function Get-MenuItemRows {
    param(
        [Parameter(Mandatory)] $MenuItem,
        [Parameter(Mandatory)][int]$WrapAt
    )
    $rows = [int]$MenuItem.LineCount
    if ([int]$MenuItem.Text.Length -gt $WrapAt) { $rows += 1 }
    return $rows
}

# Walk the menu once and gather every number Show-Menu needs to lay it out:
# total line cost, longest breakline width, whether help is present/needed,
# and the per-tier line cost used by the progressive shrink decision.
function Get-MenuMetrics {
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$MenuItems,
        [Parameter(Mandatory)][int]$WindowWidth
    )
    $wrapAt = $WindowWidth - $script:MenuLayout.TextWidthSlack
    $tiers = @{ Function = 0; Header = 0; Blank = 0; Help = 0 }
    $totalRows = 0
    $longestBreak = 0
    $helpFound = $false
    $helpNeeded = $false

    foreach ($mi in $MenuItems) {
        $rows = Get-MenuItemRows -MenuItem $mi -WrapAt $wrapAt
        $totalRows += $rows

        $name = [string]$mi.itemName
        if ($name.StartsWith('*B') -and $mi.Text.Length -gt $longestBreak) {
            $longestBreak = $mi.Text.Length
        }
        if ($name -eq '*HELP') { $helpFound = $true }
        if (-not [string]::IsNullOrWhiteSpace($mi.HelpText)) { $helpNeeded = $true }

        $kind = Get-MenuItemKind -MenuItem $mi
        if ($kind -ne 'Selectable') { $tiers[$kind] += $rows }
    }

    # When help text is requested but no explicit *HELP slot exists, Show-Menu
    # paints an auto-banner above the menu. Fold its cost directly into the
    # Help tier so Resolve-ShrinkPlan doesn't need a separate parameter for it.
    if ($helpNeeded -and -not $helpFound) {
        $tiers.Help += $script:MenuLayout.HelpBannerLines
        $totalRows  += $script:MenuLayout.HelpBannerLines
    }
    # Note: PromptLines and PgIndicatorLines are NOT added here -- they're
    # pre-reserved inside Get-RoomLeftFromCurrentPosition. RoomLeft is the
    # budget for items + help banner only.

    return [pscustomobject]@{
        TotalLineCount   = $totalRows
        LongestBreakLine = $longestBreak
        HelpFound        = $helpFound
        HelpNeeded       = $helpNeeded
        Tiers            = $tiers
    }
}

# Decide which categories of non-selectable content to drop so the menu fits
# the viewport. Categories are dropped in priority order
# (Function -> Header -> Blank -> Help) until the running deficit reaches zero.
# If all four still aren't enough, the Max flag triggers a legacy
# "hide everything non-selectable" mode. Returned hashtable keys mirror the
# Get-MenuItemKind output so callers can index it directly: $shrink[$kind].
function Resolve-ShrinkPlan {
    param(
        [Parameter(Mandatory)][hashtable]$Tiers,
        [Parameter(Mandatory)][int]$TotalLineCount,
        [Parameter(Mandatory)][int]$RoomLeft
    )
    $plan = @{ Function = $false; Header = $false; Blank = $false; Help = $false; Max = $false }
    $deficit = $TotalLineCount - $RoomLeft
    foreach ($name in 'Function','Header','Blank','Help') {
        if ($deficit -le 0) { break }
        if ($Tiers[$name] -le 0) { continue }
        $plan[$name] = $true
        $deficit -= $Tiers[$name]
    }
    $plan.Max = $plan.Function -and $plan.Header -and $plan.Blank -and $plan.Help -and ($deficit -gt 0)
    return $plan
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
    $Operation = $script:MenuOp.None
    $script:_lastHelpText = $null  # Reset help-text cache for new menu display
    While ($true) {
        # PGUP/PGDN bookkeeping: reset Displayed flags so the upcoming render
        # walk knows where the new page starts. Done before measurement because
        # nothing about line counts depends on these flags.
        if ($Operation -eq $script:MenuOp.PgUp) {
            foreach ($mi in $menuItems) { $mi.Displayed = $false }
        }
        elseif ($Operation -eq $script:MenuOp.PgDn) {
            $pgDnHasMore = $false
            foreach ($mi in $menuItems) {
                if (-not $mi.Displayed -and $mi.Selectable) { $pgDnHasMore = $true; break }
            }
            if (-not $pgDnHasMore) {
                foreach ($mi in $menuItems) { $mi.Displayed = $false }
                $Operation = $script:MenuOp.None
            }
        }

        # Single pass over the menu collects every layout number we need.
        $metrics          = Get-MenuMetrics -MenuItems $menuItems -WindowWidth $host.UI.RawUI.WindowSize.Width
        $TotalLineCount   = $metrics.TotalLineCount
        $LongestBreakLine = $metrics.LongestBreakLine
        $HelpFound        = $metrics.HelpFound
        $HelpNeeded       = $metrics.HelpNeeded

        #$WindowSizeY = $host.UI.RawUI.WindowSize.Height - 1 # Get the height of the console window, subtract 1 since its 0 based
        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        $RoomLeft = Get-RoomLeftFromCurrentPosition
        if ($NoClear -and $RoomLeft -lt $TotalLineCount) {
            $NoClear = $false
        }

        if (-not $NoClear) {
            Write-Host "`e[2J`e[H"
            #$NoClear = $true
        }
        
        # Write-Log -Activity with -NoNewLine already emits one newline (via
        # Write-Host2) so the cursor lands on the row after the activity header.
        # Don't add another bare Write-Host here -- that would burn a blank row
        # at the top of every menu redraw.
        Write-Log -Activity $menuName -NoNewLine

        $RoomLeft = Get-RoomLeftFromCurrentPosition
        if ($RoomLeft -lt $TotalLineCount) {
            Write-Host "`e[2J`e[H" #Try Clearing the screen again.  Maybe this gives us enough room.
            $RoomLeft = Get-RoomLeftFromCurrentPosition
        }

        # Decide which tiers of non-selectable content to drop so the menu fits.
        # Tiers (dropped first to last): Summary -> Header -> Blank -> Help.
        # Help-banner cost is already folded into $metrics.Tiers.Help.
        $shrink    = Resolve-ShrinkPlan -Tiers $metrics.Tiers -TotalLineCount $TotalLineCount -RoomLeft $RoomLeft
        $Maxshrink = $shrink.Max

        if (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help) {
            $HelpPosition = Get-CursorPosition
            Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText "" -Color None -wait:$false
        }
        $PgUpAvailable = ($Operation -eq $script:MenuOp.PgDn)
        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        $passedDisplayedItems = $false
        for ($idx = 0; $idx -lt $menuItems.Count; $idx++) {
            $menuItem = $menuItems[$idx]

            # ---- PgDn page-state: skip items already shown on the previous page,
            # then mark this page "Done" once we hit the first new selectable item.
            if ($Operation -eq $script:MenuOp.PgDn) {
                if ($menuItem.Displayed) {
                    $menuItem.Displayed = $false
                    $passedDisplayedItems = $true
                    continue
                }
                if (-not $passedDisplayedItems) { continue }
                if ($menuItem.Selectable) { $Operation = $script:MenuOp.PgDnDone }
            }

            $kind = Get-MenuItemKind -MenuItem $menuItem

            # ---- Tier-based shrinking: drop whole categories of non-selectable
            # content when the viewport is too small. Selectable items are never
            # dropped here -- they spill to a PgDn page instead.
            if ($kind -ne 'Selectable' -and ($Maxshrink -or $shrink[$kind])) {
                continue
            }

            # ---- Pagination cutoff with lookahead: only paginate when the
            # remaining items wouldn't fit even after reclaiming the rows
            # that the "Press [PgDn]" indicator + spacer would consume
            # (we don't paint the indicator when we're not paginating).
            $RoomLeft = Get-RoomLeftFromCurrentPosition
            $reclaimable = $script:MenuLayout.PgIndicatorLines
            if ($RoomLeft -le $reclaimable) {
                $remainingRows = Get-RemainingMenuRows -MenuItems $menuItems -StartIndex $idx -Shrink $shrink
                if ($remainingRows -gt ($RoomLeft + $reclaimable)) {
                    $menuItem.Displayed = $false
                    $Operation = $script:MenuOp.PgDnNeeded
                    continue
                }
                # else: fall through and render the trailing items inline
            }

            # ---- Per-kind rendering. Function items render via Invoke-Expression
            # and don't get the CurrentPosition stamp (they manage their own
            # cursor). All other kinds get a fresh row anchor stamped onto the
            # item so Update-Prompt can repaint the arrow / checkbox in place.
            $CurrentPosition = Get-CursorPosition
            Set-CursorPosition -x 0 -y $CurrentPosition.Y

            switch ($kind) {
                'Function' {
                    $menuItem.Displayed = $true
                    Invoke-Expression -Command $menuItem.Function
                }
                'Selectable' {
                    $menuItem | Add-Member -MemberType NoteProperty -Name 'CurrentPosition' -Value $CurrentPosition.Y -Force
                    if ($menuItem.Selected) {
                        Write-Host '━➤ ' -ForegroundColor Yellow -NoNewline
                    }
                    else {
                        Write-Host '   ' -ForegroundColor Cyan -NoNewline
                    }
                    Set-CursorPosition -x 3 -y $CurrentPosition.Y
                    Write-Option $menuItem.itemName $menuItem.Text -color $menuItem.Color1 -Color2 $menuItem.Color1 -MultiSelect:$MultiSelect -MultiSelected:$menuItem.MultiSelected
                    $menuItem.Displayed = $true
                }
                'Help' {
                    $menuItem | Add-Member -MemberType NoteProperty -Name 'CurrentPosition' -Value $CurrentPosition.Y -Force
                    $HelpPosition = Get-CursorPosition
                    Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText '' -Color None -wait:$false
                }
                'Header' {
                    $menuItem | Add-Member -MemberType NoteProperty -Name 'CurrentPosition' -Value $CurrentPosition.Y -Force
                    Write-MenuHeader -MenuItem $menuItem -LongestBreakLine $LongestBreakLine
                    $menuItem.Displayed = $true
                }
                'Blank' {
                    $menuItem | Add-Member -MemberType NoteProperty -Name 'CurrentPosition' -Value $CurrentPosition.Y -Force
                    Write-Host2 -ForegroundColor $menuItem.Color1 $menuItem.Text
                    $menuItem.Displayed = $true
                }
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
        # Indicator helper emits its own leading blank, so we don't need the
        # legacy unconditional Write-Host "" here -- it would waste a row when
        # no PgDn/PgUp is shown.
        [void](Write-MenuPgIndicator -Operation $Operation -PgUpAvailable $PgUpAvailable)
        $Operation = $script:MenuOp.None
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
        $PromptPosition = Get-CursorPosition               
        $return = Start-Navigation -menuItems $MenuItems -startOfmenu $MenuStart -PromptPosition $PromptPosition -HelpPosition $HelpPosition -MultiSelect:$MultiSelect
        Set-CursorPosition -x $PromptPosition.X -y $PromptPosition.Y
        write-host
        if ($return) {
            
            if (-not [string]::IsNullOrWhiteSpace($return.Action)) {
                $Operation = $return.Action
                write-log -verbose "OP: $Operation"
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

    # Only update items that actually changed: the previously-selected item
    # and the newly-selected item. Avoids O(n) cursor repositioning + writes
    # on every arrow key press.
    for ($i = 0; $i -lt $menuItems.Count; $i++) {
        if (-not ($menuItems[$i].Displayed)) {
            continue
        }
        if ($menuItems[$i].Selectable) {
            $isTarget = ($i -eq $selectedIndex)
            $wasSelected = $menuItems[$i].Selected

            # Skip items whose visual state hasn't changed
            if (-not $MultiSelect -and -not $Wait -and ($isTarget -eq $wasSelected)) {
                continue
            }

            Set-CursorPosition -x 0 -y $menuItems[$i].CurrentPosition
            if ($isTarget) {
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
            
            }
            else {
                $menuItems[$i].Selected = $false
                Write-Host "   " -NoNewline
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

# Non-blocking wait for either a keypress or a console resize. Returns a
# PSCustomObject with .Key (KeyInfo or $null) and .Resized (bool). Polls the
# window dimensions every PollMs so an idle resize triggers a redraw instead
# of being noticed only after the user presses a key.
function Wait-KeyStrokeOrResize {
    param(
        [Parameter(Mandatory)] $StartSize,
        [int]$PollMs = 75
    )
    while ($true) {
        if ($Host.UI.RawUI.KeyAvailable) {
            return [pscustomobject]@{
                Key     = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                Resized = $false
            }
        }
        $cur = $Host.UI.RawUI.WindowSize
        if ($cur.Width -ne $StartSize.Width -or $cur.Height -ne $StartSize.Height) {
            return [pscustomobject]@{ Key = $null; Resized = $true }
        }
        Start-Sleep -Milliseconds $PollMs
    }
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

    # Skip redraw if help text hasn't changed since last call
    if (-not $wait -and $script:_lastHelpText -eq $CurrentHelpText) {
        return
    }
    $script:_lastHelpText = $CurrentHelpText

    Set-CursorPosition -X $HelpPosition.X -Y $HelpPosition.Y 

    # Use ANSI erase-line (ESC[2K) instead of writing Width-2 spaces per line.
    # This avoids pushing hundreds of characters through the console on each redraw.
    # Row count matches $script:MenuLayout.HelpBannerLines so the metrics math
    # and the actual paint can't disagree.
    for ($i = 0; $i -lt $script:MenuLayout.HelpBannerLines; $i++) {
        Write-Host "`e[2K"
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentHelpText) -and -not $wait) {      

        # Truncate the help text so it fits on a single line. The box
        # pre-clears exactly 3 rows (top border, text, bottom border);
        # if the text wraps to a 2nd visual line it pushes the bottom
        # border down and corrupts the layout. Reserve room for the
        # leading " │🕮  " prefix and trailing margin.
        $maxWidth = $host.UI.RawUI.WindowSize.Width - 6
        $oneLineHelp = ($CurrentHelpText -replace "`r?`n", ' ').Trim()
        if ($maxWidth -gt 4 -and $oneLineHelp.Length -gt $maxWidth) {
            $oneLineHelp = $oneLineHelp.Substring(0, $maxWidth - 1) + '…'
        }

        # Border length: match the text content width, clamped between
        # 50% of the terminal width (minimum) and window width - 2
        # (maximum, to avoid wrapping).  The +5 accounts for the
        # " │🕮  " prefix inside the box.
        $textWidth   = $oneLineHelp.Length + 5
        $halfScreen  = [Math]::Floor($host.UI.RawUI.WindowSize.Width / 2)
        $borderLen   = [Math]::Max($halfScreen, [Math]::Min($textWidth, $host.UI.RawUI.WindowSize.Width - 2))
        $border      = '─' * $borderLen

        Set-CursorPosition -X 0 -Y $HelpPosition.Y
        write-host2 (" ╭" + $border) -ForegroundColor MediumOrchid
        write-host2 " │" -noNewLine -ForegroundColor MediumOrchid
        write-host2 "🕮  " -ForegroundColor BlanchedAlmond -noNewLine
        write-host2 "$oneLineHelp" -foregroundColor $Color
        write-host2 (" ╰" + $border) -ForegroundColor MediumOrchid
    
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
    $AnyHelpText = $false
    [System.Console]::CursorVisible = $false
    $CurrentValue = $null
    #$cursorPosition = Get-CursorPosition # Get the current cursor position
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    write-host "             " -NoNewline
    Set-CursorPosition -X $PromptPosition.X -Y $PromptPosition.Y # Set the cursor position to the prompt position
    if ($MenuItems -and $selectedIndex -ne -1) {
        if ($MenuItems[$selectedIndex].Selectable) {
            $CurrentValue = $MenuItems[$selectedIndex].ItemName
            $CurrentHelpText = $MenuItems[$selectedIndex].HelpText
            $CurrentColor = $MenuItems[$selectedIndex].Color1   
            if (-not [string]::IsNullOrWhiteSpace($CurrentHelpText)) {
                $AnyHelpText = $true
            }
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

    if ($AnyHelpText) {
        Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText $CurrentHelpText -Color $CurrentColor -wait:$wait
    }
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
            # -Verbose (was -LogOnly): fires per selectable item per Start-Navigation call,
            # which adds noticeable disk I/O when redrawing large menus. Demote to verbose.
            write-log -Verbose "Found Selectable Item $menuItem" 
        }

        if ($menuItem.Selected -and $menuItem.Displayed -and $menuItem.Selectable) {
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
    if (-not $HelpPosition) {
        $HelpPosition = $CPosition
    }
    [System.Console]::CursorVisible = $false # Hide the cursor
    $startSize = $Host.UI.RawUI.WindowSize
    # Loop until the user presses the Escape key
    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
    #Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText $menuItems[$selectedIndex].HelpText -Color $menuItems[$selectedIndex].Color1 -wait:$false
    while ($true) {
        # Block until either a key arrives or the console gets resized.
        # On resize we return immediately; Show-Menu's outer loop re-runs
        # Get-MenuMetrics + Resolve-ShrinkPlan and repaints for the new size.
        $event = Wait-KeyStrokeOrResize -StartSize $startSize
        if ($event.Resized) { return }
        $key = $event.Key
        write-log -Verbose -HostOnly "key: $key"

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
                if ($key.VirtualKeyCode -eq 34) {
                    $return = [PSCustomObject]@{
                        Action      = $script:MenuOp.PgDn
                        CurrentMenu = $MenuItems
                    }
                    return $return
                }
                if ($key.VirtualKeyCode -eq 33) {
                    $return = [PSCustomObject]@{
                        Action      = $script:MenuOp.PgUp
                        CurrentMenu = $MenuItems
                    }
                    return $return
                }
            }
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
        }
       
        if ($key.VirtualKeyCode -eq 13 -or $key.VirtualKeyCode -eq 39 -or $key.VirtualKeyCode -eq 45 -or $key.VirtualKeyCode -eq 46 -or $key.Character -eq " ") {
            # 13 = Enter key, 39 = Right arrow key, 45 = Insert, 46 = delete
            Write-Log -verbose -LogOnly "Entering return function"
            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
            if ($NumSelectable -eq 0) {
                Write-Log -verbose -LogOnly "Entering return function - Return ESCAPE"
                return "NOITEMS"
            }

            if ($MultiSelect) {
                
                $optionInt = ($($menuItems[$selectedIndex].ItemName) -as [int])
                if ($optionInt) {                
                    if ($menuItems[$selectedIndex].MultiSelected) {
                        #If insert was pressed, do not remove the selection
                        if ($key.VirtualKeyCode -eq 45) {
                            continue
                        }
                        $menuItems[$selectedIndex].MultiSelected = $false
                    }
                    else {
                        #If delete was pressed, do not enable the selection
                        if ($key.VirtualKeyCode -eq 46) {
                            continue
                        }
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
            else {
                # Insert only works on multiselect.
                if ($key.VirtualKeyCode -eq 45) {
                    continue
                }
            }


            if ($buffer) {
                #If Delete was pressed while something is in the buffer.. Reset.
                if ($key.VirtualKeyCode -eq 46) {
                    $buffer = $null
                    continue
                }
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
                # If delete was pressed with a deletable item, lets mark it for deletion - Fix Me
                if ($key.VirtualKeyCode -eq 46) {
                    if ($menuItems[$selectedIndex].Deletable) {
                        $menuItems[$selectedIndex].Operation = "DELETE"
                        write-log -Verbose "Returning operation DELETE on deletable object"
                    }
                    else {
                        continue
                    }
                }
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
                # Only save to MenuHistory if selectedIndex points to a selectable item
                if ($selectedIndex -ge 0 -and $selectedIndex -lt $menuItems.Count -and $menuItems[$selectedIndex].Selectable) {
                    $Global:MenuHistory[$menuName] = $MenuItems[$selectedIndex].ItemName
                }
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



