param(
    $role = "PS",
    $vmName,
    [switch]$force
)

if (-not $vmName) {
    Write-Host "Specify VMName param. "
    return
}

# To remove later
$version = "current-branch"

# Prepare DSC ZIP files
Set-Location $PSScriptRoot

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Guests, include all so the ZIP contains all required modules to make it easier to move them to guest VMs.

Write-Host "Importing Modules.."
$modules = @(
    'ActiveDirectoryDsc',
    'xDscDiagnostics',
    'ComputerManagementDsc',
    'DnsServerDsc',
    'SqlServerDsc',
    'xDhcpServer',
    'NetworkingDsc'
)
foreach ($module in $modules) {
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

# Create local compressed file and inject appropriate appropriate TemplateHelpDSC
Write-Host "Creating DSC.zip for $version.."
Publish-AzVMDscConfiguration .\DummyConfig.ps1 -OutputArchivePath .\$version\DSC.zip -Force
Write-Host "Adding $version TemplateHelpDSC to DSC.ZIP.."
Compress-Archive -Path .\$version\TemplateHelpDSC -Update -DestinationPath .\$version\DSC.zip

# install templatehelpdsc module on this machine for specified version
Write-Host "Installing $version TemlateHelpDSC on this machine.."
Copy-Item .\$version\TemplateHelpDSC "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force

# Create test config, for testing if the config definition is good.
$role = if ($role -eq "DPMP") { "DomainMember" } else { $role }
Write-Host "Creating a test config for $role in C:\Temp"
$adminCreds = Get-Credential
. ".\$version\$($role)Configuration.ps1"

# Configuration Data
$cd = @{
    AllNodes = @(
        @{
            NodeName                    = 'LOCALHOST'
            PSDscAllowPlainTextPassword = $true
            PSDscAllowDomainUser        = $true
        }
    )
}

# Create dummy file so config doesn't fail
. "..\Common.ps1"
$result = Test-Configuration -FilePath "E:\repos\memlabs\vmbuild\config\samples\Standalone.json"
$filePath = "C:\temp\deployConfig.json"
$result.DeployConfig.parameters.ThisMachineName = $vmName
$result.DeployConfig | ConvertTo-Json | Set-Clipboard
$result.DeployConfig | ConvertTo-Json -Depth 3| Out-File $filePath -Force

& "$($role)Configuration" -ConfigFilePath $filePath -AdminCreds $adminCreds -ConfigurationData $cd -OutputPath "C:\Temp\$($role)-Config"