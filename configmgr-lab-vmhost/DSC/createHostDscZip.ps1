# Prepare DSC ZIP files
Set-Location $PSScriptRoot

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Host
Write-Host "Importing Modules.."
if (-not (Get-DscResource -Module xHyper-V)) { Install-Module xHyper-V -Force }
if (-not (Get-DscResource -Module xNetworking)) { Install-Module xNetworking -Force }

# Create local compressed file
Write-Host "Creating DSC Host.zip for VM Host.."
Publish-AzVMDscConfiguration .\Host.ps1 -OutputArchivePath .\Host.zip -Force