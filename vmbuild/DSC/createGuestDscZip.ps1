# Prepare DSC ZIP files
Set-Location $PSScriptRoot

$cb = "current-branch"
$tp = "tech-preview"

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Guests, include all so the ZIP contains all required modules to make it easier to move them to guest VMs.

Write-Host "Importing Modules.."
if (-not (Get-DscResource -Module xNetworking)) { Install-Module xNetworking -Force }
if (-not (Get-DscResource -Module xDhcpServer)) { Install-Module xDhcpServer -Force }
if (-not (Get-DscResource -Module SqlServerDsc)) { Install-Module SqlServerDsc -Force }
if (-not (Get-DscResource -Module DnsServerDsc)) { Install-Module DnsServerDsc -Force }
if (-not (Get-DscResource -Module ComputerManagementDsc )) { Install-Module ComputerManagementDsc  -Force }

# Create local compressed file
Write-Host "Creating DSC.zip for $cb.."
Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\$cb\DSC.zip -Force
Write-Host "Adding $cb TemplateHelpDSC to DSC.ZIP.."
Compress-Archive -Path .\$cb\TemplateHelpDSC -Update -DestinationPath .\$cb\DSC.zip


# Inject the appropriate TemplateHelpDSC
Write-Host "Creating DSC.zip for $tp.."
Compress-Archive -Path .\$tp\TemplateHelpDSC -Update -DestinationPath .\$tp\DSC.zip
Write-Host "Adding $tp TemplateHelpDSC to DSC.ZIP.."
Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\$tp\DSC.zip -Force
