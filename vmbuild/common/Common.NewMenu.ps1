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
        [switch] $AcceptsDelete,
        # Regex matched against $menuItem.itemName. Items whose name matches
        # are dropped entirely (not just hidden by shrink) when the rendered
        # menu would overflow the viewport. Re-evaluated on every render so
        # items reappear when the window grows. Forwarded to Show-Menu.
        [string] $DroppableItemPattern = $null,
        # When set, Get-Menu2 returns "GOBACK" (left-arrow, right-click,
        # back-button) as a distinct value instead of collapsing it into
        # "ESCAPE". Lets the caller differentiate ESC from go-back.
        [switch] $SplitEscapeFromGoBack
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
        $response = Show-Menu -menuName $MenuName -menuItems ([ref]$menuItems) -NoClear:$false -MultiSelect:$MultiSelect -DroppableItemPattern $DroppableItemPattern -SplitEscapeFromGoBack:$SplitEscapeFromGoBack
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


# Read the current console window size by opening a fresh CONOUT$ handle via
# P/Invoke and calling GetConsoleScreenBufferInfo. [System.Console]::Window* and
# $Host.UI.RawUI.WindowSize both reuse a cached stdout handle whose buffer info
# can lag behind actual resizes. A fresh CONOUT$ handle per call gets the most
# recent state conhost knows about. (Note: in ConPTY hosts -- Windows Terminal,
# VS Code -- the real terminal window lives in a separate process and conhost
# can also lag. GetClientRect on GetConsoleWindow() returns 0x0 in ConPTY
# because the console window is a hidden pseudo-console stub, so pixel-based
# detection isn't an option. CONOUT$ is the best we have, with a .NET console
# fallback so we never return $null and disable resize watching entirely.)
#
# Compiled on first use rather than at load. Add-Type runs the C# compiler, which
# measured 967ms of the ~2.9s Common.ps1 bootstrap -- a cost every Start-Job
# runspace paid to build console mouse and window-size interop it can never use,
# because a background job has no console. Only the console functions below need
# these types, and each calls this first.
function Initialize-MenuConsoleInterop {
    if ($script:_menuConsoleInteropReady) { return }

    if (-not ('MemLabsConsole.NativeV3' -as [type])) {
        Add-Type -Namespace MemLabsConsole -Name NativeV3 -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct COORD { public short X; public short Y; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct CONSOLE_SCREEN_BUFFER_INFO {
    public COORD dwSize;
    public COORD dwCursorPosition;
    public short wAttributes;
    public SMALL_RECT srWindow;
    public COORD dwMaximumWindowSize;
}

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    System.IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, System.IntPtr hTemplateFile);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleScreenBufferInfo(System.IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr hObject);

public static bool TryGetWindowSize(out int width, out int height) {
    width = 0; height = 0;
    // GENERIC_READ | GENERIC_WRITE = 0xC0000000; FILE_SHARE_READ | FILE_SHARE_WRITE = 3; OPEN_EXISTING = 3
    System.IntPtr h = CreateFile("CONOUT$", 0xC0000000u, 3u, System.IntPtr.Zero, 3u, 0u, System.IntPtr.Zero);
    if (h == System.IntPtr.Zero || h.ToInt64() == -1) return false;
    try {
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(h, out info)) return false;
        width  = info.srWindow.Right  - info.srWindow.Left + 1;
        height = info.srWindow.Bottom - info.srWindow.Top  + 1;
        return true;
    } finally {
        CloseHandle(h);
    }
}
'@
    }

    # P/Invoke for ReadConsoleInput: returns keyboard AND mouse events from the
    # console input buffer. Used by Get-KeyStroke to support mouse click-to-select
    # and hover highlighting in menus.
    if (-not ('MemLabsConsole.MouseInput' -as [type])) {
        Add-Type -Namespace MemLabsConsole -Name MouseInput -MemberDefinition @'
// INPUT_RECORD.EventType constants
public const ushort KEY_EVENT   = 0x0001;
public const ushort MOUSE_EVENT = 0x0002;

// MOUSE_EVENT_RECORD.dwButtonState flags
public const uint FROM_LEFT_1ST_BUTTON_PRESSED = 0x0001;
public const uint FROM_LEFT_2ND_BUTTON_PRESSED = 0x0004; // middle
public const uint RIGHTMOST_BUTTON_PRESSED     = 0x0002;
public const uint XBUTTON1_PRESSED              = 0x0008; // back/X1

// MOUSE_EVENT_RECORD.dwEventFlags values
public const uint MOUSE_MOVED  = 0x0001;
public const uint MOUSE_WHEELED = 0x0004;

// Console mode flags
public const uint ENABLE_PROCESSED_INPUT  = 0x0001;
public const uint ENABLE_MOUSE_INPUT      = 0x0010;
public const uint ENABLE_WINDOW_INPUT     = 0x0008;
public const uint ENABLE_EXTENDED_FLAGS   = 0x0080;
public const uint ENABLE_QUICK_EDIT_MODE  = 0x0040;

// Control key state flags (from dwControlKeyState in event records)
public const uint SHIFT_PRESSED = 0x0010;

// VK constants for Shift keys
public const ushort VK_SHIFT  = 0x10;
public const ushort VK_LSHIFT = 0xA0;
public const ushort VK_RSHIFT = 0xA1;

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr hConsole, out uint lpMode);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr hConsole, uint dwMode);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetNumberOfConsoleInputEvents(System.IntPtr hConsole, out uint lpcNumberOfEvents);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FlushConsoleInputBuffer(System.IntPtr hConsoleInput);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool PeekConsoleInput(
    System.IntPtr hConsoleInput,
    [System.Runtime.InteropServices.Out] INPUT_RECORD[] lpBuffer,
    uint nLength,
    out uint lpNumberOfEventsRead);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool ReadConsoleInput(
    System.IntPtr hConsoleInput,
    [System.Runtime.InteropServices.Out] INPUT_RECORD[] lpBuffer,
    uint nLength,
    out uint lpNumberOfEventsRead);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct COORD {
    public short X;
    public short Y;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit, Size = 20)]
public struct INPUT_RECORD {
    [System.Runtime.InteropServices.FieldOffset(0)] public ushort EventType;
    [System.Runtime.InteropServices.FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    [System.Runtime.InteropServices.FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public struct KEY_EVENT_RECORD {
    public int bKeyDown;
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public char UnicodeChar;
    public uint dwControlKeyState;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct MOUSE_EVENT_RECORD {
    public COORD dwMousePosition;
    public uint dwButtonState;
    public uint dwControlKeyState;
    public uint dwEventFlags;
}
'@
    }

    # Detect whether the current (possibly cached) MemLabsConsole.MouseInput type
    # includes the newer P/Invoke methods. When the type was compiled in an earlier
    # session run (before these methods were added), the guard above skips
    # recompilation and the methods are missing. The polling loop falls back to
    # GetNumberOfConsoleInputEvents in that case (original behavior).
    $script:_hasPeekConsoleInput = $null -ne [MemLabsConsole.MouseInput].GetMethod('PeekConsoleInput')
    $script:_hasFlushConsoleInput = $null -ne [MemLabsConsole.MouseInput].GetMethod('FlushConsoleInputBuffer')

    $script:_menuConsoleInteropReady = $true
}

# The saved console mode before mouse input was enabled. Used by
# Disable-MouseInput to restore the original state.
$script:_savedConsoleMode = $null
# The exact mode we set when mouse input is active. Used by Suspend/Resume
# to avoid read-modify-write (GetConsoleMode can return values modified by
# ConPTY, progressively corrupting the mode across Suspend/Resume cycles).
$script:_mouseActiveMode = $null
$script:_consoleInputHandle = $null
# Tracks whether Shift is held for the text-selection toggle.
# Reset by Enable-MouseInput at the start of each menu session.
$script:_mouseShiftHeld = $false
# Last reported mouse button bitmask (dwButtonState). Used for edge-triggered
# (up->down) button detection so a left click is never misread as a right click
# when a prior right-button-up record was missed/swallowed (e.g. GOBACK
# navigated away before the up-event was read, or a ConPTY Suspend/Resume cycle
# dropped it) and the console keeps reporting the right-button bit as "stuck".
$script:_lastMouseButtonState = [uint32]0

function Enable-MouseInput {
    if ($Global:Common -and -not $Global:Common.MouseEnabled) {
        return
    }
    Initialize-MenuConsoleInterop
    if ($null -eq $script:_consoleInputHandle -or $script:_consoleInputHandle -eq [IntPtr]::Zero) {
        # STD_INPUT_HANDLE = -10
        $script:_consoleInputHandle = [MemLabsConsole.MouseInput]::GetStdHandle(-10)
    }
    $mode = [uint32]0
    [void][MemLabsConsole.MouseInput]::GetConsoleMode($script:_consoleInputHandle, [ref]$mode)
    $script:_savedConsoleMode = $mode
    $script:_mouseShiftHeld = $false
    $script:_lastMouseButtonState = [uint32]0

    # Enable mouse input and disable Quick Edit Mode (which swallows mouse
    # events for text selection). Preserve processed input so Ctrl+C works.
    $newMode = ($mode -bor [MemLabsConsole.MouseInput]::ENABLE_MOUSE_INPUT `
                       -bor [MemLabsConsole.MouseInput]::ENABLE_EXTENDED_FLAGS `
                       -bor [MemLabsConsole.MouseInput]::ENABLE_WINDOW_INPUT) `
                       -band (-bnot [MemLabsConsole.MouseInput]::ENABLE_QUICK_EDIT_MODE)
    [void][MemLabsConsole.MouseInput]::SetConsoleMode($script:_consoleInputHandle, $newMode)
    $script:_mouseActiveMode = $newMode

    # Flush stale events that may linger from a previous Shift-toggle
    # (Suspend/Resume cycle). When Quick Edit text selection was active and
    # the mode was switched back, ConPTY can leave phantom events in the
    # input buffer. ReadConsoleInput blocks if it finds the buffer empty
    # after GetNumberOfConsoleInputEvents reported stale counts, causing
    # the polling loop to hang.
    if ($script:_hasFlushConsoleInput) {
        [void][MemLabsConsole.MouseInput]::FlushConsoleInputBuffer($script:_consoleInputHandle)
    }
}

function Disable-MouseInput {
    if ($null -ne $script:_savedConsoleMode -and $null -ne $script:_consoleInputHandle) {
        [void][MemLabsConsole.MouseInput]::SetConsoleMode($script:_consoleInputHandle, $script:_savedConsoleMode)
        $script:_savedConsoleMode = $null
    }
    $script:_mouseActiveMode = $null
    $script:_mouseShiftHeld = $false
    $script:_lastMouseButtonState = [uint32]0
}

# Suspend mouse handling while Shift is held for text selection.
#
# Does NOT change console mode. Toggling MOUSE_INPUT via SetConsoleMode causes
# ConPTY to emit VT mouse-tracking enable/disable sequences (\e[?1000h/l) to
# Windows Terminal. Those sequences interleave with our app's own VT output
# (e.g. \e[2J\e[H clear-screen). After a Suspend/Resume cycle, the next VT
# output write corrupts ConPTY's tracking state: clear-screen stops working and
# subsequent mouse reads hang.
#
# Instead, we leave MOUSE_INPUT on and set _mouseShiftHeld. The polling loop
# in Get-KeyStroke discards all mouse events while the flag is set. Windows
# Terminal's built-in Shift-override already handles text selection when the
# app has mouse tracking active (user holds Shift → terminal intercepts clicks
# for selection instead of forwarding them as mouse events).
function Suspend-MouseInput {
    if ($null -ne $script:_consoleInputHandle -and $script:_hasFlushConsoleInput) {
        [void][MemLabsConsole.MouseInput]::FlushConsoleInputBuffer($script:_consoleInputHandle)
    }
}

# Resume mouse handling after Shift is released.
# Flushes any events that accumulated during the suspend.
function Resume-MouseInput {
    if ($null -ne $script:_consoleInputHandle -and $script:_hasFlushConsoleInput) {
        [void][MemLabsConsole.MouseInput]::FlushConsoleInputBuffer($script:_consoleInputHandle)
    }
}

function Get-LiveWindowSize {
    Initialize-MenuConsoleInterop
    $w = 0; $h = 0
    $gotIt = $false
    try {
        $gotIt = [MemLabsConsole.NativeV3]::TryGetWindowSize([ref]$w, [ref]$h)
    }
    catch {
        $gotIt = $false
    }
    if (-not $gotIt -or $w -le 0 -or $h -le 0) {
        # Fallback to the .NET console API. Returning $null here would disable
        # resize watching entirely (Start-Navigation falls through to blocking
        # ReadKey with no polling).
        try {
            $w = [System.Console]::WindowWidth
            $h = [System.Console]::WindowHeight
        }
        catch {
            return $null
        }
    }
    if ($w -le 0 -or $h -le 0) { return $null }
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
    # Use Get-LiveWindowSize for the height: $host.UI.RawUI.WindowSize.Height
    # returns a stale cached value in ConPTY hosts (Windows Terminal, VS Code
    # terminal) after a resize, just like [Console]::WindowWidth did for
    # progress bars. A stale-large height over-estimates RoomLeft, so the
    # layout under-paginates, the menu overflows the real (smaller) viewport
    # and scrolls -- pushing the overflowed rows into the scrollback. Maximizing
    # later reveals that stale scrollback as duplicated menu lines. Falls back
    # to the cached API only if the live query fails.
    $live = Get-LiveWindowSize
    $winHeight = if ($live) { [int]$live.Height } else { $host.UI.RawUI.WindowSize.Height }
    $WindowSizeY = ($winHeight - $BottomReserve)
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
# $global: for the same reason Get-AnsiCsiPattern below uses a getter: $script: resolves
# to $null when these are read on another script scope's call chain.
$global:MenuLayout = @{
    HelpBannerLines = 5    # Update-HelpText placeholder rendered above the menu
    PromptLines     = 2    # Trailing blank + prompt row
    TextWidthSlack  = 9    # Columns reserved for arrow/indent in wrap detection
}

# Regex matching ANSI CSI escape sequences (\e[...m, \e[...K, etc.). Used by
# the wrap-aware line-count helpers below to measure *visible* text length
# rather than raw .Length (which over-counts ANSI-colored rows).
# Module-level constant accessed through a function getter so callers don't
# depend on `$script:` scope resolution (which can return $null when this file
# is dot-sourced into a non-script scope, e.g. inside Start-Job blocks).
function Get-AnsiCsiPattern {
    if (-not $script:_AnsiCsiPatternCache) {
        $script:_AnsiCsiPatternCache = [regex]'\x1b\[[0-9;?]*[A-Za-z]'
    }
    return $script:_AnsiCsiPatternCache
}

# Visible character count for a string that may contain ANSI escapes.
function Get-MenuVisibleLength {
    param($Text)
    if ($null -eq $Text) { return 0 }
    $s = [string]$Text
    if ($s.Length -eq 0) { return 0 }
    if ($s.IndexOf([char]27) -lt 0) { return $s.Length }
    return (Get-AnsiCsiPattern).Replace($s, '').Length
}

# Number of extra rows a row of $VisibleLen visible chars consumes when the
# usable width is $WrapAt. Returns 0 when it fits on one row, 1 when it wraps
# once, 2 when twice, etc.
function Get-MenuWrapExtraLines {
    param([int]$VisibleLen, [int]$WrapAt)
    if ($WrapAt -le 0 -or $VisibleLen -le $WrapAt) { return 0 }
    return [int]([Math]::Ceiling($VisibleLen / [double]$WrapAt)) - 1
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
    $wrapAt = $WindowWidth - $global:MenuLayout.TextWidthSlack
    $totalLineCount = 0
    $longestBreak = 0
    $helpFound = $false
    $helpNeeded = $false

    foreach ($mi in $MenuItems) {
        $totalLineCount += $mi.LineCount
        $len = Get-MenuVisibleLength -Text $mi.Text
        $totalLineCount += (Get-MenuWrapExtraLines -VisibleLen $len -WrapAt $wrapAt)
        $name = [string]$mi.itemName
        if ($name.StartsWith('*B') -and $len -gt $longestBreak) {
            $longestBreak = $len
        }
        if ($name -eq '*HELP') { $helpFound = $true }
        if (-not [string]::IsNullOrWhiteSpace($mi.HelpText)) { $helpNeeded = $true }
        $tier = Get-MenuItemTier -MenuItem $mi
        if ($tier) { $tiers[$tier] += $mi.LineCount }
    }
    if ($helpNeeded) { $totalLineCount += $global:MenuLayout.HelpBannerLines }
    $totalLineCount += $global:MenuLayout.PromptLines

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
            # Track the *BG banner position for live elapsed-time updates.
            # Always track regardless of completion state so the completion
            # signal isn't lost if the ThreadJob finishes between a 'refresh'
            # return and the Show-Menu redraw. The _bgCompletionHandled flag
            # in Update-BgBannerInPlace prevents the infinite redraw loop.
            if ([string]$MenuItem.itemName -eq '*BG') {
                if ($global:PendingVMOperations -and $global:PendingVMOperations.Count -gt 0) {
                    $bgPos = Get-CursorPosition
                    $script:_bgBannerInfo = @{
                        Y                = $bgPos.Y
                        LongestBreakLine = $LongestBreakLine
                        MenuItem         = $MenuItem
                    }
                }
            }
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
            if ($MenuItem.Text) {
                $vis = Get-MenuVisibleLength -Text $MenuItem.Text
                $cost += (Get-MenuWrapExtraLines -VisibleLen $vis -WrapAt $WrapAt)
            }
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

# Render the bottom-of-menu pagination hint ("Press [PgUp] or [PgDn] to see more"
# etc). Caller passes Operation and whether PgUp is available; the helper
# writes the hint to the console. Returns nothing.
function Write-MenuPgIndicator {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Operation,
        [Parameter(Mandatory)][bool]$PgUpAvailable
    )
    if ($PgUpAvailable -and $Operation -eq 'PGDNNeeded') {
        Write-Host2
        Write-Host2 'Press [PgUp] or [PgDn] to see more' -ForegroundColor Yellow
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
        [Switch]$MultiSelect = $false,
        # Regex matched against $menuItem.itemName. Items whose name matches
        # are eligible to be DROPPED ENTIRELY (not just hidden by shrink) when
        # the rendered menu would otherwise overflow the viewport. Re-evaluated
        # on every render iteration so items reappear when the window grows.
        [string]$DroppableItemPattern = $null,
        # When set, "GOBACK" is returned as-is instead of collapsed to "ESCAPE".
        [switch]$SplitEscapeFromGoBack
    )
    # Suppress verbose console output during interactive menu display so it
    # doesn't corrupt the cursor-positioned rendering. Verbose messages still
    # go to the log file. Restored in the finally block below.
    $savedVerboseToLogOnly = $Common.VerboseToLogOnly
    $Common.VerboseToLogOnly = $true
    try {

    $LongestBreakLine = 0
    $Operation = ""
    $pageStartIndex = 0
    $pageEndIndex   = -1
    $script:_lastHelpText = $null  # Reset help-text cache for new menu display

    # Snapshot the original menu so the per-iteration drop pass can restore the
    # full set before re-deciding what to drop. Without this, droppable items
    # removed on a shrink would never come back when the window grows.
    $_originalItems = $null
    if ($DroppableItemPattern) {
        $_originalItems = New-Object System.Collections.ArrayList
        foreach ($mi in $menuItems) { [void]$_originalItems.Add($mi) }
    }

    # When the rendered menu causes the viewport to scroll (content taller
    # than expected), stored item positions become wrong. This counter
    # accumulates the detected scroll amount so the next render reserves
    # fewer rows and avoids the overflow. Reset on window resize.
    $scrollCorrection = 0

    # Per-page selection memory: maps pageStartIndex to the menuItems index
    # that was selected on that page. When the user PgDn/PgUp away and comes
    # back, the arrow returns to wherever they left it instead of snapping to
    # the first item.
    $pageSelections = @{}

    While ($true) {
        # Reset per-iteration state. HelpPosition must be cleared each loop:
        # the shrink plan may drop the help banner this iteration even though
        # it was drawn previously, and a stale position would cause Update-Prompt
        # to paint the help box over wherever that old coordinate points.
        $HelpPosition = $null
        $script:_bgBannerInfo = $null
        $script:_lastBgUpdate = $null
        $script:_lastBgRefresh = $null
        $script:_lastActiveOpsCount = $null

        # Restore the full menu, then drop droppable items if they won't fit.
        # Runs every iteration so resize events (which return us to this loop
        # via Start-Navigation -> null) recompute the drop decision against
        # the current window size. The shrink plan below handles dropping
        # *cosmetic* rows (headers/blanks/help); this pass drops *content*
        # rows that the caller marked as expendable.
        if ($DroppableItemPattern -and $_originalItems) {
            $menuItems.Clear()
            foreach ($mi in $_originalItems) { [void]$menuItems.Add($mi) }
            # Measure against the post-clear viewport: Show-Menu will clear+home
            # before drawing, then emit 1 line for the activity title and 1
            # blank, leaving WindowHeight - 2 - BottomReserve (4) usable rows.
            $live = Get-LiveWindowSize
            $winW = if ($live) { $live.Width }  else { $host.UI.RawUI.WindowSize.Width }
            $winH = if ($live) { $live.Height } else { $host.UI.RawUI.WindowSize.Height }
            $room = $winH - 6
            $dropMetrics = Get-MenuMetrics -MenuItems $menuItems -WindowWidth $winW
            if ($dropMetrics.TotalLineCount -gt $room) {
                $droppable = @($menuItems | Where-Object { [string]$_.itemName -match $DroppableItemPattern })
                foreach ($d in $droppable) {
                    $null = $menuItems.Remove($d)
                    $dropMetrics = Get-MenuMetrics -MenuItems $menuItems -WindowWidth $winW
                    if ($dropMetrics.TotalLineCount -le $room) { break }
                }
            }
        }

        # PGUP/PGDN bookkeeping: advance the page start index based on the
        # previous render's EndIndex (saved in $pageEndIndex). PgUp always
        # snaps back to the first page (preserves prior behavior).
        if ($operation -eq 'PGUP' -or $operation -eq 'PGDN') {
            # Save which item was selected on the page we're leaving.
            $leavingSelected = $menuItems | Where-Object { $_.Selected -and $_.Selectable }
            if ($leavingSelected) {
                $pageSelections[$pageStartIndex] = [array]::IndexOf($menuItems.ToArray(), $leavingSelected)
            }

            if ($operation -eq 'PGUP') {
                $pageStartIndex = 0
            }
            else {
                $pageStartIndex = $pageEndIndex + 1
                if ($pageStartIndex -ge $menuItems.Count) { $pageStartIndex = 0 }
            }

            # Clear .Selected on ALL items so only one arrow renders. The
            # correct item will be re-selected by Start-Navigation using
            # the remembered selection (restored below) or its first-item
            # fallback.
            foreach ($mi in $menuItems) { $mi.Selected = $false }

            # Restore remembered selection for the page we're switching to.
            if ($pageSelections.ContainsKey($pageStartIndex)) {
                $rememberedIdx = $pageSelections[$pageStartIndex]
                if ($rememberedIdx -ge 0 -and $rememberedIdx -lt $menuItems.Count) {
                    $menuItems[$rememberedIdx].Selected = $true
                }
            }
        }

        # Single pass over the menu collects every layout number we need.
        # Use Get-LiveWindowSize so wrap accounting reflects the post-resize
        # width (the .NET console cache can lag a few hundred ms in ConPTY).
        $liveSize = Get-LiveWindowSize
        $liveWidth = if ($liveSize) { [int]$liveSize.Width } else { $host.UI.RawUI.WindowSize.Width }
        # Snapshot the dimensions this render iteration is laying out against.
        # We re-read just before blocking on input and restart the loop if the
        # window changed mid-draw -- otherwise the user sees a layout sized for
        # the old window until they press a key.
        $drawWidth  = $liveWidth
        $drawHeight = if ($liveSize) { [int]$liveSize.Height } else { $host.UI.RawUI.WindowSize.Height }
        $metrics          = Get-MenuMetrics -MenuItems $menuItems -WindowWidth $liveWidth
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

        # Begin synchronized output so the terminal buffers the entire
        # clear+redraw and paints it as a single frame (no flicker).
        [Console]::Write("`e[?2026h")

        if (-not $NoClear) {
            Write-Host "`e[3J`e[2J`e[H"
            # `e[3J also clears the scrollback buffer (not just the visible
            # screen). If a prior render overflowed the viewport, the extra
            # rows scroll into the scrollback; a plain `e[2J leaves them there
            # so maximizing the window later reveals them as duplicated menu
            # lines. Wiping the scrollback on each redraw guarantees stale
            # overflowed rows can never reappear.
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

        # Snapshot the viewport top before drawing content. If the viewport
        # scrolls during rendering (content taller than expected), we detect
        # it afterward and redraw with fewer lines.
        $preRenderViewportTop = $Host.UI.RawUI.WindowPosition.Y

        # Apply scroll correction from a previous iteration that overflowed.
        if ($scrollCorrection -gt 0) {
            $RoomLeft = [Math]::Max(1, $RoomLeft - $scrollCorrection)
        }

        # Decide which tiers of non-selectable content to drop so the menu fits.
        # Tiers (dropped first to last): Summary -> Header -> Blank -> Help.
        # PgDn is a LAST resort -- if a layout pass still wouldn't fit, we
        # escalate the shrink plan one tier at a time and re-layout before
        # giving up and paginating.
        $helpBannerCost = if ($HelpNeeded) { $global:MenuLayout.HelpBannerLines } else { 0 }
        $shrink    = Resolve-ShrinkPlan -Tiers $metrics.Tiers -HelpBannerCost $helpBannerCost -TotalLineCount $TotalLineCount -RoomLeft $RoomLeft
        $Maxshrink = $shrink.Max

        # Compute the rows actually available for menu items. The help banner
        # (when drawn) advances the cursor by HelpBannerLines BEFORE rendering
        # starts, so we model that here instead of sampling cursor position
        # after the banner draws. This keeps shrink and layout consistent so
        # the same numbers drive both decisions.
        $wrapAt = $liveWidth - $global:MenuLayout.TextWidthSlack
        $bannerWillDraw = (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help)
        $availableRows  = [Math]::Max(1, $RoomLeft - $(if ($bannerWillDraw) { $helpBannerCost } else { 0 }))
        $layout = Get-PageLayout -MenuItems $menuItems -Shrink $shrink -MaxShrink $Maxshrink `
                        -WrapAt $wrapAt -AvailableRows $availableRows -StartIndex $pageStartIndex

        # If pagination would still be needed but we haven't exhausted the
        # shrink tiers, drop the next tier and re-layout. Only escalate when
        # starting from the first page -- mid-pagination, the user has already
        # committed to scrolling.
        $tierOrder = @('Summary','Header','Blank','Help')
        while ($layout.PgDnNeeded -and -not $Maxshrink -and $pageStartIndex -eq 0) {
            $advanced = $false
            foreach ($tier in $tierOrder) {
                if (-not $shrink[$tier]) {
                    $shrink[$tier] = $true
                    $advanced = $true
                    break
                }
            }
            if (-not $advanced) {
                # All four tiers already dropped -- escalate to Max (hide every
                # non-selectable row) as the final non-paginating attempt.
                $shrink.Max = $true
                $Maxshrink = $true
            }
            $bannerWillDraw = (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help)
            $availableRows  = [Math]::Max(1, $RoomLeft - $(if ($bannerWillDraw) { $helpBannerCost } else { 0 }))
            $layout = Get-PageLayout -MenuItems $menuItems -Shrink $shrink -MaxShrink $Maxshrink `
                            -WrapAt $wrapAt -AvailableRows $availableRows -StartIndex $pageStartIndex
        }

        # Final chicken-and-egg check: BottomReserve in Get-RoomLeftFromCurrentPosition
        # holds 1 row for the PgDn indicator. If we'd still paginate after
        # exhausting shrink, retry with that row reclaimed -- if the remaining
        # items fit in the indicator's slot, we don't need the indicator at all.
        if ($layout.PgDnNeeded -and $pageStartIndex -eq 0) {
            $bannerWillDraw = (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help)
            $reclaimRows    = [Math]::Max(1, $RoomLeft - $(if ($bannerWillDraw) { $helpBannerCost } else { 0 }) + 1)
            $retryLayout    = Get-PageLayout -MenuItems $menuItems -Shrink $shrink -MaxShrink $Maxshrink `
                                -WrapAt $wrapAt -AvailableRows $reclaimRows -StartIndex $pageStartIndex
            if (-not $retryLayout.PgDnNeeded) {
                $layout = $retryLayout
            }
        }

        # Now that the shrink plan is final, draw the help banner if it survived.
        if (-not $HelpFound -and $HelpNeeded -and -not $shrink.Help) {
            $HelpPosition = Get-CursorPosition
            Update-HelpText -HelpPosition $HelpPosition -CurrentHelpText "" -Color None -wait:$false
        }

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

        # Enforce exactly one selection arrow before drawing. A plain resize
        # (e.g. maximizing the window) merges previously-separate pages onto
        # one without going through the PGUP/PGDN bookkeeping that clears stale
        # .Selected flags. Set-PointerDisplayAsPerMenu only ever updates
        # .Selected on *displayed* items, so an item selected on a page that
        # wasn't visible keeps its flag. When the resize makes it visible
        # again, two arrows render (and the extra selected row looks like a
        # duplicated line). Keep .Selected on only the first selectable item in
        # the visible page range; clear it on every other item. If none in the
        # visible range is selected, all flags are cleared and Start-Navigation's
        # fallback picks the first displayed item.
        $keptSelected = $false
        for ($si = 0; $si -lt $menuItems.Count; $si++) {
            $smi = $menuItems[$si]
            if (-not $smi.Selectable -or -not $smi.Selected) { continue }
            if (-not $keptSelected -and $si -ge $pageStartIndex -and $si -le $pageEndIndex) {
                $keptSelected = $true
            }
            else {
                $smi.Selected = $false
            }
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
        # Truncate the prompt so it leaves room on the same row for Update-Prompt's
        # " [<currentItem>]: <buffer>" suffix. If the prompt wraps, PromptPosition
        # lands on the wrapped row and the "[X]:" appears on its own line.
        $promptLive = Get-LiveWindowSize
        $promptWidth = if ($promptLive) { [int]$promptLive.Width } else { $host.UI.RawUI.WindowSize.Width }
        $promptTailReserve = 20  # " [<item>]: " plus a small safety margin
        $promptMax = $promptWidth - $promptTailReserve
        if ($promptMax -lt 10) { $promptMax = 10 }
        if ($prompt.Length -gt $promptMax) {
            if ($promptMax -ge 4) {
                $prompt = $prompt.Substring(0, $promptMax - 3) + '...'
            } else {
                $prompt = $prompt.Substring(0, $promptMax)
            }
        }
        #$currentValue = "T"
        if (-not $Maxshrink) {
            Write-Host ""
        }
        $pgIndicatorY = -1
        $pgClickUp    = $false
        $pgClickDn    = $false
        if ($PgUpAvailable -and $Operation -eq 'PGDNNEEDED') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNNEEDED' -PgUpAvailable $true
            $pgIndicatorY = (Get-CursorPosition).Y - 1
            $pgClickUp = $true
            $pgClickDn = $true
        }
        elseif ($Operation -eq 'PGDNDONE') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNDONE' -PgUpAvailable $false
            $pgIndicatorY = (Get-CursorPosition).Y - 1
            $pgClickUp = $true
        }
        elseif ($Operation -eq 'PGDNNEEDED') {
            $Operation = ""
            Write-MenuPgIndicator -Operation 'PGDNNEEDED' -PgUpAvailable $false
            $pgIndicatorY = (Get-CursorPosition).Y - 1
            $pgClickDn = $true
        }
        Write-Host2 -ForegroundColor $Global:Common.Colors.GenConfigPrompt $prompt -NoNewline
        $PromptPosition = Get-CursorPosition

        # End synchronized output — terminal paints the entire menu as one frame.
        [Console]::Write("`e[?2026l")

        # Detect if the viewport scrolled during rendering. This happens on
        # small screens when text wrapping or summary functions produce more
        # lines than the layout predicted. Scroll shifts all stored
        # CurrentPosition values so the arrow and mouse point at the wrong
        # rows. Reduce available room by the scroll amount and redraw.
        $postRenderViewportTop = $Host.UI.RawUI.WindowPosition.Y
        if ($postRenderViewportTop -gt $preRenderViewportTop) {
            $scrollShift = $postRenderViewportTop - $preRenderViewportTop
            $scrollCorrection += $scrollShift
            Write-Log -Verbose "Show-Menu: viewport scrolled $scrollShift rows during render (total correction: $scrollCorrection); redrawing with fewer lines"
            continue
        }

        # Re-check the window size. If it changed while we were drawing this
        # frame, the layout we just painted is stale (text truncated for the
        # old width, items positioned for the old height, etc). Restart the
        # loop to redraw against the new size instead of blocking on input
        # against a layout the user can no longer trust.
        $postDrawSize = Get-LiveWindowSize
        if ($postDrawSize) {
            if ([int]$postDrawSize.Width -ne $drawWidth -or [int]$postDrawSize.Height -ne $drawHeight) {
                $scrollCorrection = 0
                Write-Log -Verbose "Show-Menu: window resized during draw ($drawWidth x $drawHeight -> $($postDrawSize.Width) x $($postDrawSize.Height)); redrawing"
                continue
            }
        }
        $return = Start-Navigation -menuItems $MenuItems -startOfmenu $MenuStart -PromptPosition $PromptPosition -HelpPosition $HelpPosition -MultiSelect:$MultiSelect -PgIndicatorY $pgIndicatorY -PgClickUp:$pgClickUp -PgClickDn:$pgClickDn
        Set-CursorPosition -x $PromptPosition.X -y $PromptPosition.Y
        write-host
        # Collapse GOBACK into ESCAPE unless caller opted into split mode.
        if ($return -eq "GOBACK" -and -not $SplitEscapeFromGoBack) {
            $return = "ESCAPE"
        }
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

    } finally {
        $Common.VerboseToLogOnly = $savedVerboseToLogOnly
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

# Track the last hovered menu item index so we can un-highlight it when the
# mouse moves to a different row.
$script:_lastHoveredIndex = -1
# Track which PgIndicator word is currently hover-highlighted: 'PgUp', 'PgDn', or $null.
$script:_lastHoveredPgWord = $null

# Highlight [PgUp] or [PgDn] on the pagination indicator line when the mouse
# hovers over the corresponding word. Restores Yellow on the previously
# highlighted word when the mouse moves away.
function Set-PgIndicatorHoverHighlight {
    param(
        [int]$MouseX,
        [int]$MouseY,
        [int]$PgIndicatorY,
        [switch]$PgClickUp,
        [switch]$PgClickDn
    )
    if ($PgIndicatorY -lt 0 -or $MouseY -ne $PgIndicatorY) {
        # Mouse is not on the indicator line; clear any existing highlight
        if ($script:_lastHoveredPgWord) {
            Set-CursorPosition -x 0 -y $PgIndicatorY
            Write-Host "`e[K" -NoNewline
            Set-CursorPosition -x 0 -y $PgIndicatorY
            if ($PgClickUp -and $PgClickDn) {
                Write-Host2 'Press [PgUp] or [PgDn] to see more' -ForegroundColor Yellow
            } elseif ($PgClickUp) {
                Write-Host2 'Press [PgUp] to see more' -ForegroundColor Yellow
            } else {
                Write-Host2 'Press [PgDn] to see more' -ForegroundColor Yellow
            }
            $script:_lastHoveredPgWord = $null
        }
        return
    }

    # Determine which word the mouse is over based on column positions.
    # Both:    'Press [PgUp] or [PgDn] to see more'
    #           0     6    11   16   21
    # PgUp only: 'Press [PgUp] to see more'  → [PgUp] at 6-11
    # PgDn only: 'Press [PgDn] to see more'  → [PgDn] at 6-11
    $hoveredWord = $null
    if ($PgClickUp -and $PgClickDn) {
        if ($MouseX -ge 6 -and $MouseX -le 11) { $hoveredWord = 'PgUp' }
        elseif ($MouseX -ge 16 -and $MouseX -le 21) { $hoveredWord = 'PgDn' }
    }
    elseif ($PgClickUp) {
        if ($MouseX -ge 6 -and $MouseX -le 11) { $hoveredWord = 'PgUp' }
    }
    elseif ($PgClickDn) {
        if ($MouseX -ge 6 -and $MouseX -le 11) { $hoveredWord = 'PgDn' }
    }

    if ($hoveredWord -eq $script:_lastHoveredPgWord) { return }

    # Redraw the indicator line with the hovered word in SkyBlue
    Set-CursorPosition -x 0 -y $PgIndicatorY
    Write-Host "`e[K" -NoNewline
    Set-CursorPosition -x 0 -y $PgIndicatorY
    if ($PgClickUp -and $PgClickDn) {
        $pgUpColor = if ($hoveredWord -eq 'PgUp') { 'SkyBlue' } else { 'Yellow' }
        $pgDnColor = if ($hoveredWord -eq 'PgDn') { 'SkyBlue' } else { 'Yellow' }
        Write-Host2 'Press ' -ForegroundColor Yellow -NoNewline
        Write-Host2 '[PgUp]' -ForegroundColor $pgUpColor -NoNewline
        Write-Host2 ' or ' -ForegroundColor Yellow -NoNewline
        Write-Host2 '[PgDn]' -ForegroundColor $pgDnColor -NoNewline
        Write-Host2 ' to see more' -ForegroundColor Yellow
    }
    elseif ($PgClickUp) {
        $pgUpColor = if ($hoveredWord -eq 'PgUp') { 'SkyBlue' } else { 'Yellow' }
        Write-Host2 'Press ' -ForegroundColor Yellow -NoNewline
        Write-Host2 '[PgUp]' -ForegroundColor $pgUpColor -NoNewline
        Write-Host2 ' to see more' -ForegroundColor Yellow
    }
    else {
        $pgDnColor = if ($hoveredWord -eq 'PgDn') { 'SkyBlue' } else { 'Yellow' }
        Write-Host2 'Press ' -ForegroundColor Yellow -NoNewline
        Write-Host2 '[PgDn]' -ForegroundColor $pgDnColor -NoNewline
        Write-Host2 ' to see more' -ForegroundColor Yellow
    }
    $script:_lastHoveredPgWord = $hoveredWord
}

# Update hover highlighting: when the mouse is over a selectable menu item,
# re-render that item's row with an underline (ANSI SGR 4). When the mouse
# moves off, restore the original rendering. Only touches the text portion
# (columns 3+) to avoid interfering with the selection arrow.
function Set-MouseHoverHighlight {
    param(
        [Parameter(Mandatory)]
        [System.Collections.ArrayList]$menuItems,
        [Parameter(Mandatory)]
        [int]$mouseY,
        [switch]$MultiSelect
    )
    [System.Console]::CursorVisible = $false

    # Find which menu item (if any) the mouse is over
    $hoveredIndex = -1
    for ($i = 0; $i -lt $menuItems.Count; $i++) {
        if ($menuItems[$i].Displayed -and $menuItems[$i].Selectable -and $menuItems[$i].CurrentPosition -eq $mouseY) {
            $hoveredIndex = $i
            break
        }
    }

    # Nothing changed
    if ($hoveredIndex -eq $script:_lastHoveredIndex) { return }

    # Un-highlight the old hovered item (re-render with original colors).
    # Columns 0-2 are left untouched so the keyboard selection arrow is preserved.
    if ($script:_lastHoveredIndex -ge 0 -and $script:_lastHoveredIndex -lt $menuItems.Count) {
        $old = $menuItems[$script:_lastHoveredIndex]
        if ($old.Displayed -and $old.Selectable) {
            Set-CursorPosition -x 3 -y $old.CurrentPosition
            Write-Host "`e[K" -NoNewline
            Set-CursorPosition -x 3 -y $old.CurrentPosition
            Write-Option $old.ItemName $old.Text -color $old.Color1 -Color2 $old.Color1 -MultiSelect:$MultiSelect -MultiSelected:$old.MultiSelected
        }
    }

    # Highlight the new hovered item with a blue foreground + dark background.
    # Renders the line as a single Write-Host call to avoid Write-Host2's
    # per-segment $PSStyle.Reset (ESC[0m) which kills background color.
    # Only the text from column 3 onward is redrawn; columns 0-2 are never touched.
    if ($hoveredIndex -ge 0) {
        $item = $menuItems[$hoveredIndex]
        $fgAnsi = Get-AnsiColorCached $Global:Common.Colors.GenConfigHover
        $bgAnsi = "`e[48;5;236m"  # dark gray background (xterm-256 #236)
        Set-CursorPosition -x 3 -y $item.CurrentPosition
        Write-Host "`e[K" -NoNewline
        Set-CursorPosition -x 3 -y $item.CurrentPosition

        # Strip embedded ANSI so hover color applies uniformly
        $hoverText = if ($item.Text -and $item.Text.Contains([char]27)) {
            (Get-AnsiCsiPattern).Replace($item.Text, '')
        } else { $item.Text }

        # Build multiselect prefix
        $msPrefix = ""
        if ($MultiSelect) {
            $optionInt = $item.ItemName -as [int]
            if ($optionInt) {
                $check = if ($item.MultiSelected) { [char]8730 } else { " " }
                $msPrefix = "[$check] "
            } else {
                $msPrefix = "    "
            }
        }

        # Build line: [key]  text  (same layout as Write-Option)
        $bracketSuffix = "] ".PadRight([Math]::Max(0, 4 - $item.ItemName.Length))
        $line = "${msPrefix}[$($item.ItemName)${bracketSuffix}${hoverText}"

        # Truncate to fit terminal width (mirror Write-Option's truncation)
        $termWidth = 0
        try {
            $live = Get-LiveWindowSize
            if ($live) { $termWidth = [int]$live.Width }
        } catch { }
        if (-not $termWidth) { $termWidth = [Console]::WindowWidth }
        $available = $termWidth - 3 - 2  # col 3 start, 2 margin
        if ($available -gt 0 -and $line.Length -gt $available) {
            $line = $line.Substring(0, [Math]::Max(0, $available - 3)) + "..."
        }

        # Pad background to the width of the longest menu item so all hover
        # highlights are the same width regardless of text length.
        $maxLineLen = 0
        foreach ($mi in $menuItems) {
            if ($mi.Displayed -and $mi.Selectable -and $mi.Text) {
                $plainText = if ($mi.Text.Contains([char]27)) {
                    (Get-AnsiCsiPattern).Replace($mi.Text, '')
                } else { $mi.Text }
                $msBracketLen = 1 + $mi.ItemName.Length + [Math]::Max(0, 4 - $mi.ItemName.Length)
                if ($MultiSelect -and ($mi.ItemName -as [int])) { $msBracketLen += 4 }
                elseif ($MultiSelect) { $msBracketLen += 4 }
                $thisLen = $msBracketLen + $plainText.Length
                if ($thisLen -gt $maxLineLen) { $maxLineLen = $thisLen }
            }
        }
        if ($maxLineLen -gt 0 -and $line.Length -lt $maxLineLen) {
            $line = $line.PadRight($maxLineLen)
        }

        # Single Write-Host: fg + bg + content + reset. No intermediate resets.
        Write-Host "${fgAnsi}${bgAnsi}${line}`e[0m" -NoNewline
    }

    $script:_lastHoveredIndex = $hoveredIndex
}

# ---------------------------------------------------------------------------
# Live background-operation banner update
# ---------------------------------------------------------------------------
# Called from Get-KeyStroke's idle polling loop every ~50-75ms. Throttles to
# once per second so the cursor save/restore doesn't flicker. Returns:
#   'completed' - operation finished; caller should invalidate cache & redraw
#   'refresh'   - a VM changed state; caller should invalidate cache & redraw
#   $null       - no action needed
function Update-BgBannerInPlace {
    $info = $script:_bgBannerInfo
    if (-not $info) {
        # Clear stale completion flag when there's no banner to track
        if (-not $global:PendingVMOperations -or $global:PendingVMOperations.Count -eq 0) {
            $script:_bgCompletionHandled = $false
        }
        return $null
    }

    if (-not $global:PendingVMOperations -or $global:PendingVMOperations.Count -eq 0) {
        $script:_bgBannerInfo = $null
        $script:_bgCompletionHandled = $false
        return $null
    }

    # Gather active (not-completed) ops
    $activeOps = @()
    $allCompleted = $true
    foreach ($d in @($global:PendingVMOperations.Keys)) {
        $o = $global:PendingVMOperations[$d]
        if ($o -and -not $o.Completed) {
            $activeOps += $o
            $allCompleted = $false
        }
    }

    # All ops completed — handle settle delay then signal rebuild
    if ($allCompleted) {
        if ($script:_bgCompletionHandled) { return $null }
        $now = [DateTime]::UtcNow
        if (-not $script:_bgCompletionDetectedAt) {
            $script:_bgCompletionDetectedAt = $now
            # Set dirty flag immediately so the rebuild after settle gets fresh data
            $global:vm_List_Dirty = $true
            $global:HealthStatsCache = $null
            # Update banner to green "complete" immediately
            $totalVMs = ($global:PendingVMOperations.Values | Measure-Object -Property VMCount -Sum).Sum
            $totalFail = ($global:PendingVMOperations.Values | Measure-Object -Property Failures -Sum).Sum
            $oldest = $global:PendingVMOperations.Values | Sort-Object StartTime | Select-Object -First 1
            $elapsedSec = [math]::Round(((Get-Date) - $oldest.StartTime).TotalSeconds)
            if ($totalFail -eq 0) {
                $info.MenuItem.Text = "All $totalVMs VM(s) complete ($($elapsedSec)s)"
                $info.MenuItem.Color1 = "Chartreuse"
            } else {
                $info.MenuItem.Text = "$totalFail/$totalVMs VM(s) had issues ($($elapsedSec)s)"
                $info.MenuItem.Color1 = "Red"
            }
            # Redraw the completion banner in-place
            $savedPos = Get-CursorPosition
            [System.Console]::CursorVisible = $false
            try {
                Set-CursorPosition -X 0 -Y $info.Y
                Write-Host "`e[2K" -NoNewline
                Set-CursorPosition -X 0 -Y $info.Y
                Write-MenuHeader -MenuItem $info.MenuItem -LongestBreakLine $info.LongestBreakLine
                Set-CursorPosition -X $savedPos.X -Y $savedPos.Y
            } catch {}
            finally { [System.Console]::CursorVisible = $false }
            return $null
        }
        if (($now - $script:_bgCompletionDetectedAt).TotalSeconds -ge 5) {
            $script:_bgCompletionHandled = $true
            $script:_bgCompletionDetectedAt = $null
            return 'completed'
        }
        return $null
    }

    # Reset completion tracking when ops are still active
    $script:_bgCompletionDetectedAt = $null

    # Throttle to once per second
    $now = [DateTime]::UtcNow
    if ($script:_lastBgUpdate -and ($now - $script:_lastBgUpdate).TotalMilliseconds -lt 1000) {
        return $null
    }
    $script:_lastBgUpdate = $now

    # Detect state changes: either a VM transitioned within an active op
    # (StateChanged flag) or an op itself completed since last check
    # (active count decreased). Both should trigger a refresh.
    $anyChanged = $false
    foreach ($aop in $activeOps) {
        if ($aop.StateChanged) {
            $aop.StateChanged = $false
            $anyChanged = $true
        }
    }
    $currentActiveCount = $activeOps.Count
    if ($null -eq $script:_lastActiveOpsCount) {
        $script:_lastActiveOpsCount = $currentActiveCount
    }
    elseif ($currentActiveCount -ne $script:_lastActiveOpsCount) {
        # An op completed (or a new one started) — treat as state change
        $script:_lastActiveOpsCount = $currentActiveCount
        $anyChanged = $true
    }
    if ($anyChanged) {
        if (-not $script:_lastBgRefresh) { $script:_lastBgRefresh = $now }
        if (($now - $script:_lastBgRefresh).TotalSeconds -ge 5) {
            $script:_lastBgRefresh = $now
            return 'refresh'
        }
    }

    # Build combined banner text from all ops (active + completed)
    $parts = @()
    # Show completed ops with checkmark
    foreach ($d in @($global:PendingVMOperations.Keys)) {
        $cop = $global:PendingVMOperations[$d]
        if ($cop.Completed) {
            $shortDomain = $cop.Domain.Split('.')[0]
            $marker = if ($cop.Failures -eq 0) { [char]0x2713 } else { '!' }
            $parts += "$marker $shortDomain`: $($cop.VMCount)/$($cop.VMCount)"
        }
    }
    # Show active ops with progress
    foreach ($aop in $activeOps) {
        $doneCount = $aop.VMCount - $aop.StillActive
        $shortDomain = $aop.Domain.Split('.')[0]
        $parts += "$($aop.Type) $shortDomain`: $doneCount/$($aop.VMCount)"
    }
    $oldest = $activeOps | Sort-Object StartTime | Select-Object -First 1
    $elapsedSec = [math]::Round(((Get-Date) - $oldest.StartTime).TotalSeconds)
    $newText = ($parts -join ' | ') + " ($($elapsedSec)s)"

    # Skip redraw if text hasn't changed
    if ($info.MenuItem.Text -eq $newText) { return $null }
    $info.MenuItem.Text = $newText

    # Save cursor, redraw the banner line in-place, restore cursor
    $savedPos = Get-CursorPosition
    $savedVisible = [System.Console]::CursorVisible
    [System.Console]::CursorVisible = $false
    try {
        Set-CursorPosition -X 0 -Y $info.Y
        Write-Host "`e[2K" -NoNewline
        Set-CursorPosition -X 0 -Y $info.Y
        Write-MenuHeader -MenuItem $info.MenuItem -LongestBreakLine $info.LongestBreakLine
        Set-CursorPosition -X $savedPos.X -Y $savedPos.Y
    }
    catch {}
    finally {
        [System.Console]::CursorVisible = $savedVisible
    }

    return $null
}

# Get the key stroke from the user. If $WatchSize is supplied, polls every
# ~100ms and returns $null if the window size changes before a key is pressed.
# Otherwise blocks until a key is pressed (original behavior).
#
# When mouse input is enabled ($script:_savedConsoleMode is set), uses
# ReadConsoleInput to receive both keyboard and mouse events. Returns either:
#   - A standard KeyInfo object (keyboard), or
#   - A [pscustomobject] with .IsMouseEvent=$true, .MouseX, .MouseY,
#     .MouseButton (0=move, 1=left-click), .MouseFlags (from dwEventFlags)
function Get-KeyStroke {
    param(
        # Accepts the {Width;Height} pscustomobject returned by Get-LiveWindowSize.
        # Untyped so a $null baseline (captured while window was minimized) is OK.
        $WatchSize
    )

    $mouseActive = ($null -ne $script:_savedConsoleMode -and $null -ne $script:_consoleInputHandle)

    if (-not $WatchSize -and -not $mouseActive) {
        return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    Initialize-MenuConsoleInterop

    # When mouse input is active, use ReadConsoleInput for unified key+mouse reading.
    if ($mouseActive) {
        $buf = New-Object 'MemLabsConsole.MouseInput+INPUT_RECORD[]' 1
        while ($true) {
            # Non-blocking peek: verify an event is truly readable before calling
            # ReadConsoleInput (which blocks when the buffer is empty).
            # GetNumberOfConsoleInputEvents can report phantom counts after
            # ConPTY mode toggles (Shift-suspend/resume Quick Edit), causing
            # ReadConsoleInput to block indefinitely on events that ConPTY
            # consumed internally.
            # Falls back to GetNumberOfConsoleInputEvents when PeekConsoleInput
            # is unavailable (type compiled in a stale session).
            $hasEvents = $false
            if ($script:_hasPeekConsoleInput) {
                $peekRead = [uint32]0
                [void][MemLabsConsole.MouseInput]::PeekConsoleInput($script:_consoleInputHandle, $buf, 1, [ref]$peekRead)
                $hasEvents = $peekRead -gt 0
            }
            else {
                $eventCount = [uint32]0
                [void][MemLabsConsole.MouseInput]::GetNumberOfConsoleInputEvents($script:_consoleInputHandle, [ref]$eventCount)
                $hasEvents = $eventCount -gt 0
            }
            if ($hasEvents) {
                $read = [uint32]0
                [void][MemLabsConsole.MouseInput]::ReadConsoleInput($script:_consoleInputHandle, $buf, 1, [ref]$read)
                if ($read -eq 0) {
                    # Peek said events exist but Read got nothing — phantom event
                    # from a ConPTY mode transition. Flush to clear the ghost.
                    if ($script:_hasFlushConsoleInput) {
                        [void][MemLabsConsole.MouseInput]::FlushConsoleInputBuffer($script:_consoleInputHandle)
                    }
                    continue
                }
                if ($read -gt 0) {
                    $rec = $buf[0]

                    if ($rec.EventType -eq [MemLabsConsole.MouseInput]::KEY_EVENT) {
                        $ke = $rec.KeyEvent
                        $vk = $ke.wVirtualKeyCode

                        # Shift toggle: hold Shift to enable native text selection
                        $isShiftKey = ($vk -eq [MemLabsConsole.MouseInput]::VK_SHIFT -or `
                                       $vk -eq [MemLabsConsole.MouseInput]::VK_LSHIFT -or `
                                       $vk -eq [MemLabsConsole.MouseInput]::VK_RSHIFT)
                        if ($isShiftKey) {
                            if ($ke.bKeyDown -and -not $script:_mouseShiftHeld) {
                                $script:_mouseShiftHeld = $true
                                Suspend-MouseInput
                            }
                            elseif (-not $ke.bKeyDown -and $script:_mouseShiftHeld) {
                                $script:_mouseShiftHeld = $false
                                Resume-MouseInput
                            }
                            # Consume bare Shift events — don't pass to caller
                            continue
                        }

                        if ($ke.bKeyDown) {
                            # Non-Shift key while Shift was held (e.g. user pressed
                            # Shift+Letter): resume mouse before returning the key
                            if ($script:_mouseShiftHeld) {
                                $script:_mouseShiftHeld = $false
                                Resume-MouseInput
                            }
                            # Synthesize a KeyInfo object matching what ReadKey returns
                            return [System.Management.Automation.Host.KeyInfo]::new(
                                [int]$ke.wVirtualKeyCode,
                                $ke.UnicodeChar,
                                [System.Management.Automation.Host.ControlKeyStates]$ke.dwControlKeyState,
                                $true
                            )
                        }
                        continue
                    }

                    if ($rec.EventType -eq [MemLabsConsole.MouseInput]::MOUSE_EVENT) {
                        # Ignore mouse events while Shift is held (text selection mode).
                        # MOUSE_INPUT stays enabled so ConPTY's VT state is untouched.
                        if ($script:_mouseShiftHeld) { continue }
                        $me = $rec.MouseEvent
                        $isWheel = ($me.dwEventFlags -band [MemLabsConsole.MouseInput]::MOUSE_WHEELED) -ne 0
                        $isMove  = ($me.dwEventFlags -band [MemLabsConsole.MouseInput]::MOUSE_MOVED) -ne 0
                        # Edge-triggered button detection. We act on the button
                        # that NEWLY transitioned from up->down in this record,
                        # not on whatever bits happen to be set in the snapshot.
                        # This is what makes clicks reliable: if a prior
                        # right-button-up record was missed/swallowed (GOBACK
                        # navigated away before it was read, or a ConPTY
                        # Suspend/Resume cycle dropped it), the console keeps
                        # reporting the right bit as "stuck". A snapshot test
                        # (dwButtonState -band RIGHTMOST) would then misread
                        # every subsequent LEFT click as a right click (GOBACK).
                        # Masking against the previous state ignores already-held
                        # bits and only reacts to the genuine new press.
                        $isBack  = $false
                        $isClick = $false
                        if ($me.dwEventFlags -eq 0) {
                            # Button press/release record (not move/wheel/double-click).
                            $prevBtn = $script:_lastMouseButtonState
                            $newlyPressed = $me.dwButtonState -band (-bnot $prevBtn)
                            $script:_lastMouseButtonState = $me.dwButtonState
                            # Left takes priority over right on a simultaneous
                            # both-buttons-down so an ambiguous press activates
                            # rather than navigating away.
                            if ($newlyPressed -band [MemLabsConsole.MouseInput]::FROM_LEFT_1ST_BUTTON_PRESSED) {
                                $isClick = $true
                            }
                            elseif ($newlyPressed -band [MemLabsConsole.MouseInput]::RIGHTMOST_BUTTON_PRESSED) {
                                $isBack = $true
                            }
                        }
                        if ($isClick -or $isBack -or $isMove -or $isWheel) {
                            # Wheel direction: dwButtonState high word is the signed delta.
                            # Bit 31 indicates negative (down). Avoids [int] cast overflow
                            # on uint values like 0xFF880000 (4286578688).
                            $wheelBtn = 0
                            if ($isWheel) {
                                $wheelBtn = if ($me.dwButtonState -band 0x80000000) { 4 } else { 3 }  # 3=up, 4=down
                            }
                            if ($isClick -or $isBack) {
                                Write-Log -Verbose -LogOnly "Mouse btn: btnState=0x$($me.dwButtonState.ToString('X8')) prev=0x$($prevBtn.ToString('X8')) new=0x$($newlyPressed.ToString('X8')) flags=0x$($me.dwEventFlags.ToString('X8')) -> $(if ($isBack) {'BACK'} else {'CLICK'}) at ($($me.dwMousePosition.X),$($me.dwMousePosition.Y))"
                            }
                            return [pscustomobject]@{
                                IsMouseEvent = $true
                                MouseX       = [int]$me.dwMousePosition.X
                                MouseY       = [int]$me.dwMousePosition.Y
                                MouseButton  = $(if ($isBack) { 2 } elseif ($isClick) { 1 } elseif ($isWheel) { $wheelBtn } else { 0 })
                                MouseFlags   = [int]$me.dwEventFlags
                            }
                        }
                        # Ignore other mouse events (X buttons, horizontal wheel, etc.)
                        continue
                    }
                    # WINDOW_BUFFER_SIZE_EVENT or FOCUS_EVENT — skip
                    continue
                }
            }

            # No events pending — check for resize
            if ($WatchSize) {
                $live = Get-LiveWindowSize
                if ($live -and ($live.Width -ne $WatchSize.Width -or $live.Height -ne $WatchSize.Height)) {
                    return $null
                }
            }

            # Live-update the background operation banner (elapsed time counter)
            $bgResult = Update-BgBannerInPlace
            if ($bgResult -in @('completed', 'refresh')) {
                $global:vm_List_Dirty = $true        # signal Get-List to call Get-VM on next SmartUpdate
                $global:HealthStatsCache = $null      # invalidate Quick Stats cache
                return $null
            }

            # Fallback Shift detection: if the console's mark mode (text
            # selection) swallowed the Shift key-up event, we'd stay in
            # suspended mode forever. Poll the physical key state to catch
            # the release even when no events arrive.
            if ($script:_mouseShiftHeld) {
                $shiftState = [MemLabsConsole.MouseInput]::GetAsyncKeyState([int][MemLabsConsole.MouseInput]::VK_SHIFT)
                if (($shiftState -band 0x8000) -eq 0) {
                    $script:_mouseShiftHeld = $false
                    Resume-MouseInput
                }
            }

            Start-Sleep -Milliseconds 50
        }
    }

    # Non-mouse fallback: original keyboard-only poll loop
    while ($true) {
        try {
            $ka = [System.Console]::KeyAvailable
        }
        catch {
            Start-Sleep -Milliseconds 75
            continue
        }
        if ($ka) {
            return $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        $live = Get-LiveWindowSize
        if ($live -and ($live.Width -ne $WatchSize.Width -or $live.Height -ne $WatchSize.Height)) {
            return $null
        }

        # Live-update the background operation banner (elapsed time counter)
        $bgResult = Update-BgBannerInPlace
        if ($bgResult -in @('completed', 'refresh')) {
            $global:vm_List_Dirty = $true        # signal Get-List to call Get-VM on next SmartUpdate
            $global:HealthStatsCache = $null      # invalidate Quick Stats cache
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
        [switch]$MultiSelect = $false,
        [int]$PgIndicatorY = -1,
        [switch]$PgClickUp = $false,
        [switch]$PgClickDn = $false
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
        # No item on this page has .Selected — pick the first selectable
        # displayed item and clear any stale .Selected on off-page items
        # so only one arrow ever renders.
        foreach ($mi in $menuItems) { $mi.Selected = $false }
        foreach ($menuItem in $menuItems) {
            if ($menuItem.Selectable -and $menuItem.Displayed) {
                $selectedIndex = $i
                $menuItem.Selected = $true
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

    # Enable mouse input so Get-KeyStroke can return click/move events.
    # Wrapped in try/finally to guarantee Disable-MouseInput runs on every
    # exit path (Enter, Escape, resize, PgUp/PgDn, etc.).
    Enable-MouseInput
    $script:_lastHoveredIndex = -1
    $script:_lastHoveredPgWord = $null
    try {
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
            # If a background op triggered this null return (refresh or
            # completion), propagate through Show-Menu → Get-Menu2 to the
            # outer menu loop so it rebuilds all menu items — including
            # static text like domain stats lines.
            if ($script:_bgCompletionHandled -or ($global:PendingVMOperations -and $global:PendingVMOperations.Count -gt 0)) {
                $script:_bgCompletionHandled = $false  # one-shot: clear after consuming
                return "BGCOMPLETE"
            }
            return
        }
        write-log -Verbose -HostOnly "key: $key"

        # --- Mouse event handling ---
        if ($key.IsMouseEvent) {
            if ($key.MouseButton -eq 2) {
                # Back/X1 button: go back
                if ($script:_lastHoveredIndex -ge 0) {
                    Set-MouseHoverHighlight -menuItems $menuItems -mouseY -1 -MultiSelect:$MultiSelect
                }
                Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -Wait -MultiSelect:$MultiSelect
                Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                Set-CursorPosition -X $CPosition.x -Y $CPosition.y
                return "GOBACK"
            }
            elseif ($key.MouseButton -eq 1) {
                # Left click: find the menu item at the clicked Y position
                $clickedIndex = -1
                for ($mi = 0; $mi -lt $menuItems.Count; $mi++) {
                    if ($menuItems[$mi].Displayed -and $menuItems[$mi].Selectable -and $menuItems[$mi].CurrentPosition -eq $key.MouseY) {
                        $clickedIndex = $mi
                        break
                    }
                }
                if ($clickedIndex -ge 0) {
                    # Require the item to be hover-highlighted before activating.
                    # This prevents a focus-click (clicking the window to give it
                    # focus) from accidentally activating whatever item is under
                    # the cursor. First click just highlights; second click activates.
                    if ($clickedIndex -ne $script:_lastHoveredIndex) {
                        Set-MouseHoverHighlight -menuItems $menuItems -mouseY $key.MouseY -MultiSelect:$MultiSelect
                        continue
                    }
                    # Clear hover highlight before acting on the click
                    if ($script:_lastHoveredIndex -ge 0) {
                        Set-MouseHoverHighlight -menuItems $menuItems -mouseY -1 -MultiSelect:$MultiSelect
                    }
                    $selectedIndex = $clickedIndex
                    $buffer = $null

                    if ($MultiSelect) {
                        # In multiselect, clicking a numbered item toggles its
                        # check mark; clicking A/N toggles all/none; clicking D
                        # confirms. This mirrors the keyboard handler exactly.
                        $itemName = $menuItems[$selectedIndex].ItemName
                        $optionInt = ($itemName -as [int])
                        if ($optionInt) {
                            $menuItems[$selectedIndex].MultiSelected = -not $menuItems[$selectedIndex].MultiSelected
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
                            continue
                        }
                        elseif ($itemName -eq 'A') {
                            foreach ($mi2 in $menuItems) {
                                if ($mi2.Selectable -and ($mi2.ItemName -as [int])) {
                                    $mi2.MultiSelected = $true
                                }
                            }
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
                            continue
                        }
                        elseif ($itemName -eq 'N') {
                            foreach ($mi2 in $menuItems) {
                                if ($mi2.Selectable -and ($mi2.ItemName -as [int])) {
                                    $mi2.MultiSelected = $false
                                }
                            }
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect
                            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -buffer $buffer -MenuItems $menuItems -SelectedIndex $selectedIndex
                            continue
                        }
                        elseif ($itemName -eq 'D') {
                            # Done: collect selected items (same as keyboard D handler)
                            Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -MultiSelect:$MultiSelect -Wait
                            Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                            $return = [array]($menuItems | Where-Object { $_.MultiSelected -eq $true })
                            if (-not $return) {
                                return "NOITEMS"
                            }
                            return $return
                        }
                        # Other letter items: fall through to confirm
                    }

                    # Single-select (or non-numeric multiselect item): confirm
                    Set-PointerDisplayAsPerMenu -menuItems $menuItems -selectedIndex $selectedIndex -Wait -MultiSelect:$MultiSelect
                    Update-Prompt -HelpPosition $HelpPosition -PromptPosition $PromptPosition -wait
                    Set-CursorPosition -X $CPosition.x -Y $CPosition.y
                    return $menuItems[$selectedIndex]
                }
                elseif ($PgIndicatorY -ge 0 -and $key.MouseY -eq $PgIndicatorY) {
                    # Click on the PgUp/PgDn indicator line.
                    # Use the same column ranges as the hover highlight so the
                    # clickable zone matches the visual feedback exactly.
                    if ($PgClickUp -and $PgClickDn) {
                        # Both: [PgUp] at cols 6-11, [PgDn] at cols 16-21
                        if ($key.MouseX -ge 6 -and $key.MouseX -le 11) {
                            return [PSCustomObject]@{ Action = 'PGUP'; CurrentMenu = $menuItems }
                        }
                        elseif ($key.MouseX -ge 16 -and $key.MouseX -le 21) {
                            return [PSCustomObject]@{ Action = 'PGDN'; CurrentMenu = $menuItems }
                        }
                    }
                    elseif ($PgClickDn -and $key.MouseX -ge 6 -and $key.MouseX -le 11) {
                        return [PSCustomObject]@{ Action = 'PGDN'; CurrentMenu = $menuItems }
                    }
                    elseif ($PgClickUp -and $key.MouseX -ge 6 -and $key.MouseX -le 11) {
                        return [PSCustomObject]@{ Action = 'PGUP'; CurrentMenu = $menuItems }
                    }
                }
            }
            elseif ($key.MouseButton -eq 3 -or $key.MouseButton -eq 4) {
                # Mouse wheel: 3=up (PgUp), 4=down (PgDn)
                $wheelAction = if ($key.MouseButton -eq 3) { 'PGUP' } else { 'PGDN' }
                return [PSCustomObject]@{ Action = $wheelAction; CurrentMenu = $menuItems }
            }
            elseif ($key.MouseButton -eq 0) {
                # Mouse move: update hover highlight on menu items and PgIndicator
                Set-MouseHoverHighlight -menuItems $menuItems -mouseY $key.MouseY -MultiSelect:$MultiSelect
                if ($PgIndicatorY -ge 0) {
                    Set-PgIndicatorHoverHighlight -MouseX $key.MouseX -MouseY $key.MouseY -PgIndicatorY $PgIndicatorY -PgClickUp:$PgClickUp -PgClickDn:$PgClickDn
                }
            }
            continue
        }

        # Keyboard event: clear any active hover highlight so arrow/type
        # navigation doesn't leave a stale hover color on a different row.
        if ($script:_lastHoveredIndex -ge 0) {
            Set-MouseHoverHighlight -menuItems $menuItems -mouseY -1 -MultiSelect:$MultiSelect
        }
        if ($script:_lastHoveredPgWord -and $PgIndicatorY -ge 0) {
            Set-PgIndicatorHoverHighlight -MouseX -1 -MouseY -1 -PgIndicatorY $PgIndicatorY -PgClickUp:$PgClickUp -PgClickDn:$PgClickDn
        }

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
            # 27 = Escape, 37 = Left arrow
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
            Set-CursorPosition -X $CPosition.x -Y $CPosition.y # Set the cursor position to the current position
            # ESC = hard escape, Left arrow = go back
            if ($key.VirtualKeyCode -eq 27) { return "ESCAPE" } else { return "GOBACK" }
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
    } # end while
    } # end try
    finally {
        Disable-MouseInput
        $script:_lastHoveredIndex = -1
        # Move cursor below the prompt so Ctrl+C / exit output doesn't
        # overwrite rendered menu text. PromptPosition is the row where
        # the input prompt was drawn; +1 puts us on the first clean line.
        if ($PromptPosition) {
            Set-CursorPosition -X 0 -Y ($PromptPosition.Y + 1)
        }
        [System.Console]::CursorVisible = $true
    }
}



