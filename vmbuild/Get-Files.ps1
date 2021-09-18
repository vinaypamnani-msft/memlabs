param (
    [Parameter(Mandatory = $false, ParameterSetName = "ConfigFile", HelpMessage = "Configuration Name for which to download the files.")]
    [string]$Configuration,
    [Parameter(Mandatory = $false, ParameterSetName = "GetAll", HelpMessage = "Get all files.")]
    [switch]$DownloadAll,
    [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the image, if it exists.")]
    [switch]$Force,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
    [switch]$WhatIf
)

# Dot source common
. $PSScriptRoot\Common.ps1

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
    return
}

Write-Host

Write-Log "### START." -Success

if ($Configuration) {
    Get-FilesForConfiguration -Configuration $Configuration -Force:$Force -WhatIf:$WhatIf
}

if ($DownloadAll) {
    Get-FilesForConfiguration -DownloadAll -Force:$Force -WhatIf:$WhatIf
}

Write-Host
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host