param(
    [switch]$force
)

# Prepare DSC ZIP files
Set-Location $PSScriptRoot

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Host
Write-Host "Importing Modules.."
$modules = @(
    'xHyper-V',
    'xDscDiagnostics',
    'xNetworking'
)

foreach($module in $modules)
{
    if (Get-Module -ListAvailable -Name $module) {        
        if ($force) {
            Write-Host "Module exists: $module. Updating..."
            Update-Module $module -Force    
        }
        else {
            Write-Host "Module exists: $module "
        }
    }
    else {
        Install-Module $module -Force
    }
}

# Create local compressed file
Write-Host "Creating DSC Host.zip for VM Host.."
Publish-AzVMDscConfiguration .\Host.ps1 -OutputArchivePath .\Host.zip -Force