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
Write-Log "Main: Downloading required files to $($Common.AzureFilesPath)..." -Activity

foreach ($item in $Common.AzureFileList.OS) {
    $imageName = $item.id
    $imageUrl =  "$($StorageConfig.StorageLocation)/$($item.filename)"
    $imageFileRelative = $item.filename
    $imageFileName = Split-Path $item.filename -Leaf

    if ($imageName -eq "vmbuildadmin") { continue }

    Write-Log "Main: Downloading '$imageName' file from Azure storage, saving as $imageFileName" -SubActivity
    $localImagePath = Join-Path $Common.AzureFilesPath $imageFileRelative

    $download = $true

    if (Test-Path $localImagePath) {
        Write-Log "Main: Found $imageFileRelative in $($Common.AzureFilesPath)."
        if ($Force.IsPresent) {
            Write-Log "Main: Force switch present. Removing pre-existing $imageFileName file..." -Warning
            Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
        }
        else {
            Write-Log "Main: Force switch not present. Skip downloading '$imageFileName'." -Warning
            $download = $false
            continue
        }
    }

    if ($download) {
        Write-Log "Main: Downloading '$imageName' image..."
        Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading" -WhatIf:$WhatIf
    }
}

foreach ($item in $Common.AzureFileList.ISO) {
    $imageName = $item.id
    $imageUrl =  "$($StorageConfig.StorageLocation)/$($item.filename)"
    $imageFileRelative = $item.filename
    $imageFileName = Split-Path $item.filename -Leaf

    Write-Log "Main: Downloading '$imageName' file from Azure storage, saving as $imageFileName" -Activity
    $localImagePath = Join-Path $Common.AzureFilesPath $imageFileRelative

    $download = $true

    if (Test-Path $localImagePath) {
        Write-Log "Main: Found $imageFileRelative in $($Common.AzureFilesPath)."
        if ($Force.IsPresent) {
            Write-Log "Main: Force switch present. Removing pre-existing $imageFileName file..." -Warning
            Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf | Out-Null
        }
        else {
            Write-Log "Main: Force switch not present. Skip downloading '$imageFileName'." -Warning
            $download = $false
            continue
        }
    }

    if ($download) {
        Write-Log "Main: Downloading '$imageName' image..."
        Get-File -Source $imageUrl -Destination $localImagePath -DisplayName "Downloading '$imageName' to $localImagePath..." -Action "Downloading" -WhatIf:$WhatIf
    }
}


$timer.Stop()
Write-Host
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host