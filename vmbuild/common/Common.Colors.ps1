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
        <#
        For legacy powershell session you could create a string like this:
        "$([char]27)[38;2;{0};{1};{2}m" -f $red,$green,$blue
        #>
        $psstyle.Foreground.FromRgb($Red, $Green, $Blue)
    }
}

function Write-Host2 {
    param(
        [Alias('Msg', 'Message')]
        [string] ${Object},
        [switch] ${NoNewline},
        [string] ${ForegroundColor}
    )

    if ($ForegroundColor) {
        $ansi = Get-RGB $ForegroundColor | Convert-RGBtoAnsi
        if ($ansi) {
            $Object = "$($ansi)$Object$($PSStyle.Reset)"
        }
    }
    if ($NoNewLine) {
        Write-Host $Object -NoNewline
    }
    else {
        Write-Host $Object
    }

}