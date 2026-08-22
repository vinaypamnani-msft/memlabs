param(
    [switch]$force
)

# Prepare DSC ZIP files
Set-Location $PSScriptRoot

# Self-installing prerequisite helpers (PSGallery bootstrap), shared with the guest DSC build.
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$prereqScript = Join-Path $repoRoot 'vmbuild\common\Common.Prereqs.ps1'
if (-not (Test-Path $prereqScript -PathType Leaf)) {
    throw "Cannot find $prereqScript. Run this from a full memlabs clone."
}
. $prereqScript

if (-not (Test-MemLabsElevated)) {
    Write-Host
    Write-Host "This script must run as Administrator (it installs modules machine-wide)." -ForegroundColor Red
    Write-Host
    return
}

#####################
### Install modules
#####################
# Az.Compute module, install once to use Publish-AzVMDscConfiguration
# Install-Module Az.Compute -Force

# Modules used by VM Host. Az.Compute provides Publish-AzVMDscConfiguration below.
Write-Host "Importing Modules.."
$modules = @(
    'Az.Compute',
    'xHyper-V',
    'xDhcpServer',
    'xDscDiagnostics'
)

$moduleResult = Install-MemLabsModule -Name $modules -Update:$force
foreach ($module in $moduleResult.Present) { Write-Host "Module exists: $module " }
if ($moduleResult.Failed.Count -gt 0) {
    throw "These modules could not be installed from PSGallery: $($moduleResult.Failed -join ', '). Fix connectivity to https://www.powershellgallery.com and re-run."
}

# Create local compressed file
Write-Host "Creating DSC Host.zip for VM Host.."
Publish-AzVMDscConfiguration .\Host.ps1 -OutputArchivePath .\Host.zip -Force