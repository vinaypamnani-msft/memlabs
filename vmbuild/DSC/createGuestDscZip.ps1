param(
    $role = "PS",
    $version = "current-branch",
    [switch]$force
)


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

# Config Arguments
$HashArguments = @{
    DomainName       = "contoso.com"
    DCName           = "CM-DC1"
    DPMPName         = "CM-MP1"
    CSName           = "CM-CS1"
    PSName           = "CM-PS1"
    ClientName       = "CM-CL1"
    Configuration    = "Standalone"
    DNSIPAddress     = "192.168.1.1"
    AdminCreds       = $adminCreds
    DefaultGateway   = "192.168.1.100"
    DHCPScopeId      = "192.168.1.0"
    DHCPScopeStart   = "192.168.1.20"
    DHCPScopeEnd     = "192.168.1.199"
    InstallConfigMgr = $true
    UpdateToLatest   = $true
    PushClients      = $true
}

& "$($role)Configuration" @HashArguments -ConfigurationData $cd -OutputPath "C:\Temp\$($role)-Config"