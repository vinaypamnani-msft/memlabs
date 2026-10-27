param(
    [switch]$force,
    # Mark this host as the DSC build server and exit.
    [switch]$DesignateBuildServer
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

if ($DesignateBuildServer) {
    Set-MemLabsBuildServer
    return
}

if (-not (Test-MemLabsBuildServer)) {
    Deny-MemLabsNonBuildServer -ScriptName 'createHostDscZip.ps1'
    return
}

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
    throw "These modules could not be installed: $($moduleResult.Failed -join ', '). Install-Module, a package-cache purge and a direct PSGallery nupkg download all failed - see the warnings above for which one failed and why."
}

# Create local compressed file
Write-Host "Creating DSC Host.zip for VM Host.."
Publish-AzVMDscConfiguration .\Host.ps1 -OutputArchivePath .\Host.zip -Force