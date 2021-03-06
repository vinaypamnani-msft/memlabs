try {
    # Load System.Drawing (maybe needed for PS5)
    [reflection.assembly]::LoadWithPartialName( "System.Drawing") | Out-Null
}
catch {}


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
        GenConfigNewVM             = "DarkGreen"
        GenConfigNewVMNumber       = "Green"

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
        $ansi = Get-RGB $ForegroundColor | Convert-RGBtoAnsi
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
        Write-Verbose "Geting all drawing color names"
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