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
                $linecount = 3  # Update-HelpText renders 3 lines (clear or bordered box)
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


# Read the current console window size. Detection uses GetClientRect on the
# console window HWND (pixel dimensions) because both [System.Console]::Window*
# and a fresh CONOUT$ handle's GetConsoleScreenBufferInfo return cached buffer
# info that goes stale until something writes to the console (observed: size
# locks to first post-redraw value while user actively resizes). The OS window
# manager always knows the real pixel size, so any change there reliably
# signals a resize. The triggered redraw then writes to the console, which
# refreshes conhost's char-cell cache as a side effect.
if (-not ('MemLabsConsole.NativeV2' -as [type])) {
    Add-Type -Namespace MemLabsConsole -Name NativeV2 -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool GetClientRect(System.IntPtr hWnd, out RECT lpRect);

public static bool TryGetWindowPixels(out int width, out int height) {
    width = 0; height = 0;
    System.IntPtr h = GetConsoleWindow();
    if (h == System.IntPtr.Zero) return false;
    RECT r;
    if (!GetClientRect(h, out r)) return false;
    width  = r.Right  - r.Left;
    height = r.Bottom - r.Top;
    return true;
}
'@
}

function Get-LiveWindowSize {
    $w = 0; $h = 0
    try {
        if (-not [MemLabsConsole.NativeV2]::TryGetWindowPixels([ref]$w, [ref]$h)) {
            return $null
        }
    }
    catch {
        return $null
    }
    if ($w -le 0 -or $h -le 0) { return $null }
    # Width/Height are pixel dimensions of the console window's client area.
    # Used only for change detection; comparisons (-ne) trigger redraw.
    return [pscustomobject]@{ Width = $w; Height = $h }
}

function Get-RoomLeftFromCurrentPosition {
    # Reserve extra rows so post-menu content never writes past the last viewport
    # row and triggers a scroll. The 4 rows cover:
    #   1) blank line after the last menu item (Write-Host "" before indicator)
    #   2) the PgUp/PgDn indicator line ("Press [PgDn] to see more...")
    #   3) the prompt row ("Press Enter to select...")
    #   4) one row of breathing room for the cursor / wrapped prompt
    $BottomReserve = 4
    $WindowSizeY = ($host.UI.RawUI.WindowSize.Height - $BottomReserve)
    $CurrentPosition = $Host.UI.RawUI.CursorPosition
    # Use viewport-relative Y so scroll buffer history doesn't shrink available space.
    # CursorPosition.Y is absolute buffer row; WindowPosition.Y is the buffer row at
    # the top of the visible viewport. The difference is the cursor's visual row.
    $viewportTop = $Host.UI.RawUI.WindowPosition.Y
    $relativeY = $CurrentPosition.Y - $viewportTop
    $RoomLeft = ([int]$WindowSizeY - [int]$relativeY)
    return $RoomLeft
}

# Layout constants used by Show-Menu's line-counting math. Centralized so the
# same number isn't sprinkled across the file in a half-dozen places.
$script:MenuLayout = @{
    HelpBannerLines = 5    # Update-HelpText placeholder rendered above the menu
    PromptLines     = 2    # Trailing blank + prompt row
    TextWidthSlack  = 9    # Columns reserved for arrow/indent in wrap detection
}

# Classify a non-selectable menu item into a shrink tier so the same rule is
# used by both the line-count scan and the render loop. Returns one of
# 'Summary' | 'Header' | 'Blank' | 'Help', or $null when the item is selectable.
function Get-MenuItemTier {
    param([Parameter(Mandatory)] $MenuItem)
    if ($MenuItem.Selectable) { return $null }
    $name = [string]$MenuItem.itemName
    if ($name -eq '*HELP')        { return 'Help' }
    if ($name.StartsWith('*F'))   { return 'Summary' }
    if ($name.StartsWith('*C'))   { return 'Summary' }   # decorative box border around *F summary content; shrink together
    if ($name.StartsWith('*V'))   { return 'Blank' }   # decorative ruler
    if ($name.StartsWith('*B') -and -not [string]::IsNullOrWhiteSpace($MenuItem.Text)) {
        return 'Header'
    }
    return 'Blank'   # *B/*D spacer with empty text, or anything else non-selectable
}

# Walk the menu once and gather every number Show-Menu needs to lay it out:
# total line cost, longest breakline width, whether help is present/needed,
# and the per-tier line cost used by the progressive shrink decision.
function Get-MenuMetrics {
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$MenuItems,
        [Parameter(Mandatory)][int]$WindowWidth
    )
    $tiers = @{ Summary = 0; Header = 0; Blank = 0; Help = 0 }
    $wrapAt = $WindowWidth - $script:MenuLayout.TextWidthSlack
    $totalLineCount = 0
    $longestBreak = 0
    $helpFound = $false
    $helpNeeded = $false

    foreach ($mi in $MenuItems) {
        $totalLineCount += $mi.LineCount
        $len = $mi.Text.Length
        if ($len -gt $wrapAt) { $totalLineCount += 1 }
        $name = [string]$mi.itemName
        if ($name.StartsWith('*B') -and $len -gt $longestBreak) {
            $longestBreak = $len
        }
        if ($name -eq '*HELP') { $helpFound = $true }
        if (-not [string]::IsNullOrWhiteSpace($mi.HelpText)) { $helpNeeded = $true }
        $tier = Get-MenuItemTier -MenuItem $mi
        if ($tier) { $tiers[$tier] += $mi.LineCount }
    }
    if ($helpNeeded) { $totalLineCount += $script:MenuLayout.HelpBannerLines }
    $totalLineCount += $script:MenuLayout.PromptLines

    return [pscustomobject]@{
        TotalLineCount   = $totalLineCount
        LongestBreakLine = $longestBreak
        HelpFound        = $helpFound
        HelpNeeded       = $helpNeeded
        Tiers            = $tiers
    }
}

# Decide which tiers of non-selectable content to drop so the menu fits the
# viewport. Tiers are dropped in priority order (Summary -> Header -> Blank ->
# Help) until the running deficit reaches zero. If all four tiers still aren't
# enough, the Max flag triggers legacy "hide everything non-selectable" mode.
# Returns a hashtable keyed by tier name + 'Max'.
function Resolve-ShrinkPlan {
    param(
        [Parameter(Mandatory)][hashtable]$Tiers,
        [Parameter(Mandatory)][int]$HelpBannerCost,
        [Parameter(Mandatory)][int]$TotalLineCount,
        [Parameter(Mandatory)][int]$RoomLeft
    )
    $plan = @{ Summary = $false; Header = $false; Blank = $false; Help = $false; Max = $false }
    $deficit = $TotalLineCount - $RoomLeft
    $tierOrder = @(
        @{ Name = 'Summary'; Cost = $Tiers.Summary }
        @{ Name = 'Header';  Cost = $Tiers.Header }
        @{ Name = 'Blank';   Cost = $Tiers.Blank }
        @{ Name = 'Help';    Cost = $Tiers.Help + $HelpBannerCost }
    )
    foreach ($t in $tierOrder) {
        if ($deficit -le 0) { break }
        if ($t.Cost -le 0)  { continue }
        $plan[$t.Name] = $true
        $deficit -= $t.Cost
    }
    $plan.Max = $plan.Summary -and $plan.Header -and $plan.Blank -and $plan.Help -and ($deficit -gt 0)
    return $plan
}

# Classify a menu item into a render "kind". Distinct from Get-MenuItemTier
# (which drives shrink decisions) -- a kind determines which rendering branch
# the row takes. Selectable rows always render the same way; non-selectable
# rows depend on prefix (*F / *HELP / *B-with-text / decorative fallback).
function Get-MenuItemKind {
    param([Parameter(Mandatory)] $MenuItem)
    if ($MenuItem.Function)   { return 'Summary' }   # *F items run a scriptblock
    if ($MenuItem.Selectable) { return 'Selectable' }
    $name = [string]$MenuItem.itemName
    if ($name -eq '*HELP')    { return 'Help' }
    if ($name.StartsWith('*B') -and -not [string]::IsNullOrWhiteSpace($MenuItem.Text)) {
        return 'Header'
    }
    return 'Decorative'   # *V rulers, *C borders, *B spacers, plain text
}

# Render a single menu row. Switch-dispatches on item kind. Returns a hashtable
# with side-effect outputs the foreach loop needs:
#   Drawn        - whether $menuItem.Displayed should be set $true
#   HelpPosition - non-null only when this row was the *HELP placeholder
# All shrink/Max checks live here so the caller's loop body is just the
# per-item bookkeeping (PGDN paging, RoomLeft guard, Displayed flag).
function Write-MenuItem {
    param(
        [Parameter(Mandatory)] $MenuItem,
        [Parameter(Mandatory)][hashtable]$Shrink,
        [Parameter(Mandatory)][bool]$MaxShrink,
        [Parameter(Mandatory)][int]$LongestBreakLine,
        [switch]$MultiSelect
    )
    $result = @{ Drawn = $false; HelpPosition = $null }
    $kind = Get-MenuItemKind -MenuItem $MenuItem

    switch ($kind) {
        'Summary' {
            if ($Shrink.Summary) { return $result }
            Invoke-Expression -Command $MenuItem.Function
            $result.Drawn = $true
        }
        'Selectable' {
            if ($MenuItem.Selected) {
                Write-Host '━➤ ' -ForegroundColor Yellow -NoNewline
            } else {
                Write-Host '   ' -ForegroundColor Cyan -NoNewline
            }
            $CurrentPosition = Get-CursorPosition
            $MenuItem | Add-Member -MemberType NoteProperty -Name 'CurrentPosition' -Value $CurrentPosition.Y -Force
            Set-CursorPosition -x 3 -y $CurrentPosition.Y
            Write-Option $MenuItem.itemName $MenuItem.Text -color $MenuItem.Color1 -Color2 $MenuItem.Color1 -MultiSelect:$MultiSelect -MultiSelected:$MenuItem.MultiSelected
            $result.Drawn = $true
        }
        'Help' {
            if ($MaxShrink -or $Shrink.Help) { return $result }
            $result.HelpPosition = Get-CursorPosition
            Update-HelpText -HelpPosition $result.HelpPosition -CurrentHelpText '' -Color None -wait:$false
        }
        'Header' {
            if ($MaxShrink -or $Shrink.Header) { return $result }
            Write-MenuHeader -MenuItem $MenuItem -LongestBreakLine $LongestBreakLine
            $result.Drawn = $true
        }
        'Decorative' {
            if ($MaxShrink) { return $result }
            $tier = Get-MenuItemTier -MenuItem $MenuItem
            if ($tier -and $Shrink[$tier]) { return $result }
            write-host2 -ForeGroundColor $MenuItem.Color1 $MenuItem.Text
            $result.Drawn = $true
        }
    }
    return $result
}

# Compute the actual on-screen line count this item will consume after the
# shrink plan is applied. Mirrors the kind/tier rules used by Write-MenuItem:
# items dropped by shrink contribute 0; Selectable rows account for text wrap.
function Get-MenuItemLineCost {
    param(
        [Parameter(Mandatory)] $MenuItem,
        [Parameter(Mandatory)][hashtable]$Shrink,
        [Parameter(Mandatory)][bool]$MaxShrink,
        [Parameter(Mandatory)][int]$WrapAt
    )
    $kind = Get-MenuItemKind -MenuItem $MenuItem
    switch ($kind) {
        'Selectable' {
            $cost = 1
            if ($MenuItem.Text -and $MenuItem.Text.Length -gt $WrapAt) { $cost += 1 }
            return $cost
        }
        'Summary' {
            if ($Shrink.Summary) { return 0 }
            return [int]$MenuItem.LineCount
        }
        'Help' {
            if ($MaxShrink -or $Shrink.Help) { return 0 }
            return [int]$MenuItem.LineCount
        }
        'Header' {
            if ($MaxShrink -or $Shrink.Header) { return 0 }
            return [int]$MenuItem.LineCount
        }
        'Decorative' {
            if ($MaxShrink) { return 0 }
            $tier = Get-MenuItemTier -MenuItem $MenuItem
            if ($tier -and $Shrink[$tier]) { return 0 }
            return [int]$MenuItem.LineCount
        }
    }
    return 0
}

# Pre-compute which slice of $MenuItems fits in $AvailableRows starting at
# $StartIndex, given the already-decided shrink plan. Replaces the legacy
# reactive "Get-RoomLeftFromCurrentPosition -le 2" mid-render check with a
# deterministic up-front calculation. Returns:
#   StartIndex - echo of input
#   EndIndex   - last item index that fits (inclusive); $StartIndex - 1 if none
#   PgDnNeeded - $true when items remain after EndIndex
function Get-PageLayout {
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$MenuItems,
        [Parameter(Mandatory)][hashtable]$Shrink,
        [Parameter(Mandatory)][bool]$MaxShrink,
        [Parameter(Mandatory)][int]$WrapAt,
        [Parameter(Mandatory)][int]$AvailableRows,
        [Parameter(Mandatory)][int]$StartIndex
    )
    $items = @($MenuItems)
    $count = $items.Count
    if ($StartIndex -ge $count) { $StartIndex = 0 }
    $used = 0
    $endIndex = $StartIndex - 1
    for ($i = $StartIndex; $i -lt $count; $i++) {
        $cost = Get-MenuItemLineCost -MenuItem $items[$i] -Shrink $Shrink -MaxShrink $MaxShrink -WrapAt $WrapAt
        if (($used + $cost) -gt $AvailableRows) { break }
        $used += $cost
        $endIndex = $i
    }
    $pgDnNeeded = ($endIndex -lt ($count - 1))
    return @{
        StartIndex = $StartIndex
        EndIndex   = $endIndex
        PgDnNeeded = $pgDnNeeded
    }
}

# Render the bottom-of-menu pagination hint ("Press [PgUp/PgDn] to see more"
# etc). Caller passes Operation and whether PgUp is available; the helper
# writes the hint to the console. Returns nothing.
function Write-MenuPgIndicator {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Operation,
        [Parameter(Mandatory)][bool]$PgUpAvailable
    )
    if ($PgUpAvailable -and $Operation -eq 'PGDNNeeded') {
        Write-Host2
        Write-Host2 'Press [PgUp/PgDn] to see more' -ForegroundColor Yellow
    }
    elseif ($Operation -eq 'PGDNDone') {
        Write-Host2
        Write-Host2 'Press [PgUp] to see more' -ForegroundColor Yellow
    }
    elseif ($Operation -eq 'PGDNNeeded') {
        Write-Host2
        Write-Host2 'Press [PgDn] to see more' -ForegroundColor Yellow
    }
}

# Render a centered "───  Heading Text  ───" break line for a *B-prefixed
# header item. Extracted verbatim from Show-Menu's inline render so callers
# can read declaratively. Same colors, widths, and rounding as before.
function Write-MenuHeader {
    param(
        [Parameter(Mandatory)] $MenuItem,
        [Parameter(Mandatory)][int]$LongestBreakLine
    )
    $StartDashColor    = 'SlateGray'
    $EndDashColor      = 'SlateGray'
    $indentSpaces      = 3
    $SpacesAroundWords = 4

    $NumOfDash = [math]::Round((($LongestBreakLine - $MenuItem.Text.Length) + ($SpacesAroundWords * 2) + 2 ) / 2)
    $breakPrefix = '─' * $NumOfDash
    if ([bool](($LongestBreakLine - $MenuItem.Text.Length) % 2)) {
        $NumOfDash += 1
    }
    $breakPostfix = '─' * $NumOfDash
    $WordSpace    = ' ' * $SpacesAroundWords

    Write-Host2 $(' ' * $indentSpaces) -NoNewline
    Write-Host2 -ForegroundColor $StartDashColor $($breakPrefix + $WordSpace) -NoNewline
    Write-Host2 -ForeGroundColor $MenuItem.Color1 $MenuItem.Text -NoNewline
    Write-Host2 -ForegroundColor $EndDashColor $($WordSpace + $breakPostfix)
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
    $pageStartIndex = 0
    $pageEndIndex   = -1
    $script:_lastHelpText = $null  # Reset help-text cache for new menu display
    While ($true) {
        # Reset per-iteration state. HelpPosition must be cleared each loop:
        # the shrink plan may drop the help banner this iteration even though
        # it was drawn previously, and a stale position would cause Update-Prompt
        # to paint the help box over wherever that old coordinate points.
        $HelpPosition = $null
        # PGUP/PGDN bookkeeping: advance the page start index based on the
        # previous render's EndIndex (saved in $pageEndIndex). PgUp always
        # snaps back to the first page (preserves prior behavior).
        if ($operation -eq 'PGUP') {
            $pageStartIndex = 0
        }
        elseif ($operation -eq 'PGDN') {
            $pageStartIndex = $pageEndIndex + 1
            if ($pageStartIndex -ge $menuItems.Count) { $pageStartIndex = 0 }
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
            # Clearing the screen wipes the help-box pixels too; invalidate the
            # cached help text so the next Update-HelpText actually redraws it
            # instead of short-circuiting on a stale "text unchanged" match.
            $script:_lastHelpText = $null
            #$NoClear = $true
        }
        
        Write-Log -Activity $menuName -NoNewLine
        Write-Host

        $RoomLeft = Get-RoomLeftFromCurrentPosition
        if ($RoomLeft -lt $TotalLineCount) {
            Write-Host "`e[2J`e[H" #Try Clearing the screen again.  Maybe this gives us enough room.
            $RoomLeft = Get-RoomLeftFromCurrentPosition
        }

        # Decide which tiers of non-selectable content to drop so the menu fits.
        # Tiers (dropped first to last): Summary -> Header -> Blank -> Help.
        $helpBannerCost = if ($HelpNeeded) { $script:MenuLayout.HelpBannerLines } else { 0 }
        $shrink    = Resolve-ShrinkPlan -Tiers $metrics.Tiers -HelpBannerCost $helpBannerCost -TotalLineCount $TotalLineCount -RoomLeft $RoomLeft
        $Maxshrink = $shrink.Max

        if (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help) {
            $HelpPosition = Get-CursorPosition
            Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText "" -Color None -wait:$false
        }

        # Lookahead: pre-compute which slice of $menuItems fits this page given
        # the active shrink plan. Replaces the legacy "render until RoomLeft -le 2"
        # reactive bailout with a deterministic up-front layout decision.
        # AvailableRows uses Get-RoomLeftFromCurrentPosition directly: its
        # BottomReserve=4 already covers the trailing blank, PgDn indicator,
        # prompt, and a cursor breathing row. Using the same value Resolve-ShrinkPlan
        # sees prevents the "shrink says fits / layout says paginate" mismatch
        # that left a 2-row gap above the indicator.
        $wrapAt        = $host.UI.RawUI.WindowSize.Width - $script:MenuLayout.TextWidthSlack
        $availableRows = [Math]::Max(1, (Get-RoomLeftFromCurrentPosition))
        $layout        = Get-PageLayout -MenuItems $menuItems -Shrink $shrink -MaxShrink $Maxshrink `
                            -WrapAt $wrapAt -AvailableRows $availableRows -StartIndex $pageStartIndex
        $pageStartIndex = $layout.StartIndex
        $pageEndIndex   = $layout.EndIndex
        $PgUpAvailable  = ($pageStartIndex -gt 0)
        if ($layout.PgDnNeeded) {
            $Operation = 'PGDNNEEDED'
        }
        elseif ($PgUpAvailable) {
            $Operation = 'PGDNDONE'
        }
        else {
            $Operation = ''
        }

        # Reset Displayed for every item, then mark the ones we actually render.
        # Downstream selection / keystroke code still consults .Displayed.
        foreach ($mi in $menuItems) { $mi.Displayed = $false }

        $CurrentPosition = Get-CursorPosition
        $MenuStart = $CurrentPosition.Y
        if ($pageEndIndex -ge $pageStartIndex) {
            for ($i = $pageStartIndex; $i -le $pageEndIndex; $i++) {
                $menuItem = $menuItems[$i]
                $CurrentPosition = Get-CursorPosition
                Set-CursorPosition -x 0 -y $CurrentPosition.Y

                # Per-item render dispatched in Write-MenuItem (kind-based switch).
                $itemResult = Write-MenuItem -MenuItem $menuItem -Shrink $shrink -MaxShrink $Maxshrink -LongestBreakLine $LongestBreakLine -MultiSelect:$MultiSelect
                if ($itemResult.Drawn)        { $menuItem.Displayed = $true }
                if ($itemResult.HelpPosition) { $HelpPosition = $itemResult.HelpPosition }
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
        if ($PgUpAvailable -and $Operation -eq 'PGDNNEEDED') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNNEEDED' -PgUpAvailable $true
        }
        elseif ($Operation -eq 'PGDNDONE') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNDONE' -PgUpAvailable $false
        }
        elseif ($Operation -eq 'PGDNNEEDED') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNNEEDED' -PgUpAvailable $false
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

# Get the key stroke from the user. If $WatchSize is supplied, polls every
# ~100ms and returns $null if the window size changes before a key is pressed.
# Otherwise blocks until a key is pressed (original behavior).
function Get-KeyStroke {
    param(
        # Accepts the {Width;Height} pscustomobject returned by Get-LiveWindowSize.
        # Untyped so a $null baseline (captured while window was minimized) is OK.
        $WatchSize
    )
    if (-not $WatchSize) {
        return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    $diagPath = Join-Path $PSScriptRoot '..\logs\ResizeDiag.log'
    $iter = 0
    $lastLogged = "$($WatchSize.Width)x$($WatchSize.Height)"
    Add-Content -Path $diagPath -Value ("[{0}] ENTER watch={1} HostWin={2}x{3}" -f (Get-Date -Format 'HH:mm:ss.fff'), $lastLogged, $Host.UI.RawUI.WindowSize.Width, $Host.UI.RawUI.WindowSize.Height) -ErrorAction SilentlyContinue
    while ($true) {
        $iter++
        try {
            $ka = $Host.UI.RawUI.KeyAvailable
        } catch {
            Add-Content -Path $diagPath -Value ("[{0}] KA-THROW iter={1} ex={2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $iter, $_.Exception.Message) -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 75
            continue
        }
        if ($ka) {
            Add-Content -Path $diagPath -Value ("[{0}] KEY iter={1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $iter) -ErrorAction SilentlyContinue
            return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        try {
            $live = Get-LiveWindowSize
            $hostWin = $Host.UI.RawUI.WindowSize
        } catch {
            Add-Content -Path $diagPath -Value ("[{0}] SIZE-THROW iter={1} ex={2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $iter, $_.Exception.Message) -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 75
            continue
        }
        $liveStr = if ($live) { "$($live.Width)x$($live.Height)" } else { "NULL" }
        $hostStr = "$($hostWin.Width)x$($hostWin.Height)"
        $curStr = "$($liveStr)/Host=$hostStr"
        # Heartbeat every ~1.1s (15 iters * 75ms) so we can tell if the poll is alive
        if ($curStr -ne $lastLogged -or ($iter % 15 -eq 0)) {
            Add-Content -Path $diagPath -Value ("[{0}] iter={1} ka=False live={2} host={3} watch={4}x{5}" -f (Get-Date -Format 'HH:mm:ss.fff'), $iter, $liveStr, $hostStr, $WatchSize.Width, $WatchSize.Height) -ErrorAction SilentlyContinue
            $lastLogged = $curStr
        }
        if ($live -and ($live.Width -ne $WatchSize.Width -or $live.Height -ne $WatchSize.Height)) {
            Add-Content -Path $diagPath -Value ("[{0}] RESIZE-EXIT live={1} watch={2}x{3}" -f (Get-Date -Format 'HH:mm:ss.fff'), $liveStr, $WatchSize.Width, $WatchSize.Height) -ErrorAction SilentlyContinue
            return $null
        }
        Start-Sleep -Milliseconds 75
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
    Write-Host "`e[2K"
    Write-Host "`e[2K"
    Write-Host "`e[2K"  
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
        [Parameter(Mandatory = $false)] # Optional: $null when shrink plan dropped help banner
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

    if ($AnyHelpText -and $HelpPosition) {
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
    # Note: $HelpPosition may legitimately be $null if Show-Menu's shrink plan
    # dropped the help banner for this render pass. Update-Prompt null-checks
    # before drawing, so we do NOT default it to $CPosition here -- that would
    # paint the help box on top of menu content.
    [System.Console]::CursorVisible = $false # Hide the cursor
    # Capture the live (kernel32-backed) size, retrying briefly if the window is
    # currently minimized so we don't latch a $null baseline that disables resize
    # detection for the rest of this Start-Navigation call.
    $startSize = Get-LiveWindowSize
    for ($i = 0; $i -lt 10 -and -not $startSize; $i++) {
        Start-Sleep -Milliseconds 50
        $startSize = Get-LiveWindowSize
    }
    # Loop until the user presses the Escape key
    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
    #Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText $menuItems[$selectedIndex].HelpText -Color $menuItems[$selectedIndex].Color1 -wait:$false
    while ($true) {
        $currentsize = Get-LiveWindowSize
        if ($currentsize -and $startSize -and ($currentsize.Width -ne $startSize.Width -or $currentsize.Height -ne $startSize.Height)) {
            return
        }

        #Update-Prompt -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex

        # Poll-mode keystroke wait: returns $null if window is resized while idle.
        # Show-Menu's outer loop treats a null return as "redraw" because $return
        # falsiness skips the action-dispatch branch and re-enters the render path.
        $key = Get-KeyStroke -WatchSize $startSize
        if ($null -eq $key) {
            return
        }
        write-log -Verbose -HostOnly "key: $key"

        $currentsize = Get-LiveWindowSize
        if ($currentsize -and $startSize -and ($currentsize.Width -ne $startSize.Width -or $currentsize.Height -ne $startSize.Height)) {
            return
        }
        # Handle the key stroke

        if ($key.VirtualKeyCode -eq 34 -or $key.VirtualKeyCode -eq 33) {
            # PGDN = 34, PGUP = 33
            # Determine direction separately: items before the first Displayed
            # selectable mean PgUp is valid; items after the last Displayed
            # selectable mean PgDn is valid. Using a single "any non-displayed"
            # check wraps around to page 1 from the last page.
            $firstDisplayed = -1
            $lastDisplayed = -1
            for ($idx = 0; $idx -lt $menuItems.Count; $idx++) {
                if ($menuItems[$idx].Selectable -and $menuItems[$idx].Displayed) {
                    if ($firstDisplayed -eq -1) { $firstDisplayed = $idx }
                    $lastDisplayed = $idx
                }
            }
            $hasMoreAfter  = $false
            $hasMoreBefore = $false
            for ($idx = $lastDisplayed + 1; $idx -lt $menuItems.Count; $idx++) {
                if ($menuItems[$idx].Selectable) { $hasMoreAfter = $true; break }
            }
            for ($idx = 0; $idx -lt $firstDisplayed; $idx++) {
                if ($menuItems[$idx].Selectable) { $hasMoreBefore = $true; break }
            }
            if ($key.VirtualKeyCode -eq 34 -and $hasMoreAfter) {
                $return = [PSCustomObject]@{
                    Action      = 'PGDN'
                    CurrentMenu = $MenuItems
                }
                return $return
            }
            if ($key.VirtualKeyCode -eq 33 -and $hasMoreBefore) {
                $return = [PSCustomObject]@{
                    Action      = 'PGUP'
                    CurrentMenu = $MenuItems
                }
                return $return
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



