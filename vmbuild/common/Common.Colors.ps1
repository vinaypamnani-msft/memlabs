try {
    # Load System.Drawing (maybe needed for PS5)
    [reflection.assembly]::LoadWithPartialName( "System.Drawing") | Out-Null
}
catch {}


function Set-BackgroundImage {

    param (
        [Parameter(Mandatory = $true, HelpMessage = "Enter the path to the image file")]
        [string] $file,        
        [Parameter(Mandatory = $true, HelpMessage = "Enter the alignment of the image")]
        [ValidateSet("center", "left", "right", "top", "bottom", "topLeft", "topRight", "bottomLeft", "bottomRight")]
        [string] $alignment,
        [Parameter(Mandatory = $true, HelpMessage = "Enter the opacity of the image as a percentage (5-100)")]
        [int] $opacityPercent,
        [Parameter(Mandatory = $true, HelpMessage = "Enter the stretch mode of the image")]
        [ValidateSet("none", "fill", "uniform", "uniformToFill")]
        [string] $stretchMode,
        [bool] $InJob = $false
    )
    
    if ($InJob) {
        return
    }
    if (-not (Test-Path $file)) {
        return 
    }
    
    try {
        $LocalAppData = $env:LOCALAPPDATA
        $SettingsJson = (Join-Path $LocalAppData "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json")
        if (-not (Test-Path $SettingsJson)) {
            return 
        }

        if ($opacityPercent -lt 5) {
            $opacityPercent = 5        
        }

        if ($opacityPercent -gt 100) {
            $opacityPercent = 100
        }

    

        $a = Get-Content $SettingsJson | ConvertFrom-Json   
        $a | Add-Member -MemberType NoteProperty -Name "tabWidthMode" -Value "titleLength" -Force
    
        if (-not $a.profiles.defaults) {
            $defaults = [PSCustomObject]@{
                backgroundImage            = $file
                backgroundImageAlignment   = $alignment
                backgroundImageOpacity     = ($opacityPercent / 100)
                backgroundImageStretchMode = $stretchMode
                antialiasingMode           = "cleartype"
            }
            $a.profiles | Add-Member -MemberType NoteProperty -Name "defaults" -Value $defaults -Force
        }
        else {
            $a.profiles.defaults | Add-Member -MemberType NoteProperty -Name "backgroundImage" -Value $file -Force
            $a.profiles.defaults | Add-Member -MemberType NoteProperty -Name "backgroundImageAlignment" -Value $alignment -Force
            $a.profiles.defaults | Add-Member -MemberType NoteProperty -Name "backgroundImageOpacity" -Value ($opacityPercent / 100) -Force
            $a.profiles.defaults | Add-Member -MemberType NoteProperty -Name "backgroundImageStretchMode" -Value $stretchMode -Force
            $a.profiles.defaults | Add-Member -MemberType NoteProperty -Name "antialiasingMode" -Value "cleartype" -Force
    
        }
    
        $a | ConvertTo-Json -Depth 100 | Out-File -encoding utf8 $SettingsJson
    }
    catch {}
}
function Get-Animate {
    # Clear the screen
    Write-Host "`e[2J`e[H"
    
    # Define the Unicode text art for "MemLabs"
    $textArt = @"
     ███    ███ ███████ ███    ███     ██       █████  ██████  ███████ 
     ████  ████ ██      ████  ████     ██      ██   ██ ██   ██ ██      
     ██ ████ ██ █████   ██ ████ ██     ██      ███████ ██████  ███████ 
     ██  ██  ██ ██      ██  ██  ██     ██      ██   ██ ██   ██      ██ 
     ██      ██ ███████ ██      ██     ███████ ██   ██ ██████  ███████ 
"@
    
    # Convert the text art into an array of lines
    $lines = $textArt -split "`n"
    
    # Get the dimensions of the console
    $rows, $columns = $Host.UI.RawUI.WindowSize.Height, $Host.UI.RawUI.WindowSize.Width
    
    # Calculate the start position for centering the text
    $startRow = [math]::Max(0, [math]::Floor(($rows - $lines.Length) / 2))
    $startCol = [math]::Max(0, [math]::Floor(($columns - $lines[0].Length) / 2))

    # Show red if local branch is behind remote (unpulled changes) or has uncommitted edits
    $hasPendingChanges = $false
    try {
        $repoDir = Split-Path $Global:Common.CachePath
        # Check for commits on remote not yet pulled
        $behind = & git -C $repoDir rev-list HEAD..@{u} --count 2>$null
        if ($behind -and [int]$behind -gt 0) { $hasPendingChanges = $true }
        # Check for uncommitted local changes
        if (-not $hasPendingChanges) {
            $gitStatus = & git -C $repoDir status --porcelain 2>$null
            if ($gitStatus) { $hasPendingChanges = $true }
        }
    }
    catch {}

    if ($hasPendingChanges) {
        $colorCode = "`e[38;2;255;50;50m"  # RGB 255, 50, 50 (Red - pending git changes)
    }
    else {
        $colorCode = "`e[38;2;0;127;255m"  # RGB 0, 127, 255 (Azure Blue)
    }
    $resetCode = "`e[0m"               # Reset ANSI formatting
    # Animation function to reveal characters one at a time
    
    # Loop through each line and character
    for ($lineIndex = 0; $lineIndex -lt $lines.Length; $lineIndex++) {
        for ($charIndex = 0; $charIndex -lt $lines[$lineIndex].Length; $charIndex++) {
            # Set cursor position and write the character
            $char = $lines[$lineIndex][$charIndex]
            if ($char -ne ' ') {
                $row = $startRow + $lineIndex
                $col = $startCol + $charIndex
                Write-Host "`e[${row};${col}H$colorCode$char$resetCode" -NoNewline                    
                Start-Sleep -Milliseconds 0 # Faster reveal
            }
            Start-Sleep -Milliseconds 0 # Faster reveal
        }
        Start-Sleep -Milliseconds 100 # Faster reveal    
    }
    
}

function Get-Colors {
    $colors = [PSCustomObject]@{
        #--- Create Config"
        GenConfigHeader            = "Turquoise"
        # "D" = "Delete this VM"
        GenConfigDangerous         = "Red"
        # ---------
        #[1]  Create New Domain
        #Green  White
        GenConfigNormal            = "Gainsboro"
        GenConfigNormalNumber      = "Snow"
        # [P]  Show Passwords
        # DarkSeaGreen     ForestGreen
        GenConfigDefault           = "ForestGreen"
        GenConfigDefaultNumber     = "ForestGreen"
        # [4] Load TEST config from File
        # Yellow   DimGray
        GenConfigHidden            = "RosyBrown"
        GenConfigHiddenNumber      = "RosyBrown"
        # [3] Load saved config from File%
        GenConfigNonDefault        = "LightSteelBlue"
        GenConfigNonDefaultNumber  = "LightSteelBlue"

        # [N] New Virtual Machine
        GenConfigNewVM             = "Chartreuse"
        GenConfigNewVMNumber       = "Chartreuse"

        # [D] Deploy Config
        GenConfigDeploy            = "Green"
        GenConfigDeployNumber      = "Green"

        # [3] TechPreview (NO CAS)
        GenConfigTechPreview       = "Tomato"
        # [4] No ConfigMgr
        GenConfigNoCM              = "Tan"

        # ----- Load JSON
        GenConfigJsonGood          = "LightGreen"
        GenConfigJsonBad           = "Tomato"

        #Invalid Response 'response' Valid Responses are:'
        GenConfigInvalidResponse   = "IndianRed"
        GenConfigValidResponses    = "LimeGreen"

        # ---- VM Properties
        GenConfigVMName            = "Gold"
        GenConfigVMRole            = "Gold"

        GenConfigVMRemoteServer    = "DodgerBlue"

        GenConfigSQLProp           = "LightSeaGreen"
        GenConfigSiteCode          = "LightCoral"
        GenConfigTrue              = "LightGreen"
        GenConfigFalse             = "FireBrick"

        # ---- Errors
        #Configuration is not valid. Saving is not advised. Proceed with caution. Hit CTRL-C to exit
        GenConfigError1            = "FireBrick"
        #Please fix the problem(s), or hit CTRL-C to exit.
        GenConfigError2            = "Red"
        # Please save and exit any RDCMan sessions you have open, as deployment will make modifications to the memlabs.rdg file on the desktop
        GenConfigNotice            = "MediumPurple"

        #Failed VMS
        #[F] Delete ($($pendingCount)) Failed/In-Progress VMs (These may have been orphaned by a cancelled deployment)%Yellow%Yellow

        GenConfigFailedVM          = "DarkGoldenRod"
        GenConfigFailedVMNumber    = "DarkGoldenRod"

        # --- Write-Help
        GenConfigHelp              = "DarkGray"
        GenConfigHelpHighlight     = "Yellow"

        #Tips
        #"Tip: You can enable Configuration Manager High Availability by editing the properties of a CAS or Primary VM, and selecting ""H"""
        GenConfigTip               = "Violet"

        # Prompt
        GenConfigPrompt            = "SkyBlue"
        GenConfigPromptCurrentItem = "PaleGoldenRod"

        # Bracket Color
        GenConfigBrackets          = "DimGray"
    }
    return $colors
}

function Get-RGB {
    [cmdletbinding()]
    [OutputType("RGB")]
    Param(
        [Parameter(Mandatory, HelpMessage = "Enter the name of a system color like Tomato")]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    Try {
        $Color = [System.Drawing.Color]::FromName($Name)
        [PSCustomObject]@{
            PSTypeName = "RGB"
            Name       = $Name
            Red        = $color.R
            Green      = $color.G
            Blue       = $color.B
        }
    }
    Catch {
        Throw $_
    }
}

function Convert-RGBtoAnsi {
    #This will write an opening ANSI escape sequence to the pipeline
    [cmdletbinding()]
    [OutputType("String")]
    Param(
        [parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [int]$Red,
        [parameter(Position = 1, ValueFromPipelineByPropertyName)]
        [int]$Green,
        [parameter(Position = 2, ValueFromPipelineByPropertyName)]
        [int]$Blue
    )
    Process {
        if ($Global:Common.PS7) {
            $psstyle.Foreground.FromRgb($Red, $Green, $Blue)
        }
        else {
            "$([char]27)[38;2;{0};{1};{2}m" -f $red, $green, $blue
        }
        <#
        For legacy powershell session you could create a string like this:
        "$([char]27)[38;2;{0};{1};{2}m" -f $red,$green,$blue
        #>
        #$psstyle.Foreground.FromRgb($Red, $Green, $Blue)
    }
}

function Write-Host2 {
    param(
        [Alias('Msg', 'Message')]
        [string] ${Object},
        [switch] ${NoNewline},
        [string] ${ForegroundColor}
    )

    #if ($Global:Common.PS7) {
    if ($ForegroundColor) {
        $ansi = Get-AnsiColorCached $ForegroundColor
        if ($ansi) {
            $Object = "$($ansi)$Object$($PSStyle.Reset)"
        }
    }
    #}
    if ($NoNewLine) {
        Write-Host $Object -NoNewline
    }
    else {
        Write-Host $Object
    }

}

# -- Color Sample
Function Get-DrawingColor {
    [cmdletbinding()]
    [alias("gdc")]
    [OutputType("PSColorSample")]
    Param(
        [Parameter(Position = 0, HelpMessage = "Specify a color by name. Wildcards are allowed.")]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    Try {
        Add-Type -AssemblyName system.drawing -ErrorAction Stop
    }
    Catch {
        Throw "These functions require the [System.Drawing.Color] .NET Class"
    }

    Write-Verbose "Starting $($MyInvocation.MyCommand)"

    if ($PSBoundParameters.ContainsKey("Name")) {
        if ($Name[0] -match "\*") {
            Write-Verbose "Finding drawing color names that match $name"
            $colors = [system.drawing.color].GetProperties().name | Where-Object { $_ -like $name[0] }
        }
        else {
            $colors = @()
            foreach ($n in $name) {
                if ($n -as [system.drawing.color]) {
                    $colors += $n
                }
                else {
                    Write-Warning "The name $n does not appear to be a valid System.Drawing.Color value. Skipping this name."
                }
                Write-Verbose "Using parameter values: $($colors -join ',')"

            } #foreach name
        } #else
    } #if PSBoundParameters contains Name
    else {
        Write-Verbose "Getting all drawing color names"
        $colors = [system.drawing.color].GetProperties().name | Where-Object { $_ -notmatch "^\bIs|Name|[RGBA]\b" }
    }
    Write-Verbose "Processing $($colors.count) colors"
    if ($colors.count -gt 0) {
        foreach ($c in $colors) {
            Write-Verbose "...$c"
            $ansi = Get-RGB $c -OutVariable rgb | Convert-RGBtoAnsi
            #display an ANSI formatted sample string
            $sample = "$ansi$c$($psstyle.reset)"

            #write a custom object to the pipeline
            [PSCustomObject]@{
                PSTypeName = "PSColorSample"
                Name       = $c
                RGB        = $rgb
                ANSIString = $ansi.replace("`e", "``e")
                ANSI       = $ansi
                Sample     = $sample
            }
        }
    } #if colors.count > 0
    else {
        Write-Warning "No valid colors found."
    }
    Write-Verbose "Ending $($MyInvocation.MyCommand)"
}
# --- Helpers for color-coded, truncatable single-line option summaries ---
function Get-AnsiColorCached {
    param([string]$ColorName)
    if (-not $script:_ansiColorCache) { $script:_ansiColorCache = @{} }
    if (-not $script:_ansiColorCache.ContainsKey($ColorName)) {
        try {
            $script:_ansiColorCache[$ColorName] = (Get-RGB $ColorName | Convert-RGBtoAnsi)
        }
        catch {
            $script:_ansiColorCache[$ColorName] = ""
        }
    }
    return $script:_ansiColorCache[$ColorName]
}

function Format-OptionToken {
    # Returns "<ANSI><text>" — no trailing reset, since the next token will set its own color
    # (or Write-Host2 will append PSStyle.Reset at the end).
    param(
        [Parameter(Mandatory)]
        [string]$Color,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    return "$(Get-AnsiColorCached $Color)$Text"
}

function Get-VisibleLengthAnsi {
    param([string]$Text)
    if (-not $Text) { return 0 }
    return ($Text -replace "`e\[[0-9;]*m", "").Length
}

function Limit-AnsiString {
    # Truncate an ANSI-tagged string to a max VISIBLE length, preserving embedded color codes.
    param(
        [string]$Text,
        [int]$MaxVisible
    )
    if (-not $Text -or $MaxVisible -le 0) { return $Text }
    $visibleLen = Get-VisibleLengthAnsi $Text
    if ($visibleLen -le $MaxVisible) { return $Text }

    $reset = if ($Global:Common.PS7) { $PSStyle.Reset } else { "$([char]27)[0m" }
    $sb = New-Object System.Text.StringBuilder
    $visible = 0
    $i = 0
    $limit = [Math]::Max(1, $MaxVisible - 3)   # leave room for "..."
    while ($i -lt $Text.Length -and $visible -lt $limit) {
        $ch = $Text[$i]
        if ($ch -eq [char]27) {
            $end = $Text.IndexOf('m', $i)
            if ($end -lt 0) { break }
            [void]$sb.Append($Text.Substring($i, $end - $i + 1))
            $i = $end + 1
        }
        else {
            [void]$sb.Append($ch)
            $visible++
            $i++
        }
    }
    [void]$sb.Append("$reset...")
    return $sb.ToString()
}