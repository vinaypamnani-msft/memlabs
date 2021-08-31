param (
    [Parameter(Mandatory=$false, HelpMessage="Force redownloading the image, if it exists.")]
    [switch]$Force,
    [Parameter(Mandatory=$false, HelpMessage="Dry Run.")]
    [switch]$WhatIf
)

# Dot source common
. $PSScriptRoot\Common.ps1

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
    return
}

#Clear-Host
Write-Host
Write-Host 
Write-Host 
Write-Host 
Write-Host 
Write-Host 
Write-Host 

# Timer
Write-Log "### START." -Success

$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

Write-Host 
Write-Log "Main: Downloading 'golden' images to $($Common.GoldImagePath)..." -Success

foreach ($item in $Common.ImageList.Files) {
    $imageName = $item.id
    $imageUrl =  "$($StorageConfig.StorageLocation)/$($item.container)/$($item.filename)"
    $imageFileName = $item.filename

    if ($imageName -eq "vmbuildadmin") { continue }

    Write-Log "Main: Downloading '$imageName' image from $imageUrl, saving as $imageFileName" -Activity
    $localImagePath = Join-Path $Common.GoldImagePath $imageFileName

    $download = $true

    if (-not $WhatIf -and (Test-Path $localImagePath)) {
        Write-Log "Main: Found $imageFileName in $($Common.GoldImagePath)."
        if ($Force.IsPresent) {
            Write-Log "Main: Force switch present. Removing pre-existing $imageFileName file..." -Warning
            Remove-Item -Path $localImagePath -Force | Out-Null
        }
        else {
            Write-Log "Main: Force switch not present. Skip downloading '$imageFileName'." -Warning
            $download = $false
            continue
        }
    }

    if ($download) {
        Write-Log "Main: Downloading '$imageName' image..."
        Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading"
    }
}


$timer.Stop()
Write-Host 
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host 