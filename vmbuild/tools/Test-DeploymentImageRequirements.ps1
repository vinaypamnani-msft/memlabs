#requires -Version 5.1
<#
.SYNOPSIS
    Verifies deployment skips base images only for VMs that already exist.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Read dynamically by the source-extracted media helper.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'runPhase1', Justification = 'Read by the source-extracted New-Lab media block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'needFiles', Justification = 'Read by the source-extracted New-Lab media block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'deployConfig', Justification = 'Read by the source-extracted New-Lab media block.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'existingVMs', Justification = 'Read by the source-extracted New-Lab media selection.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DownloadFilesOnly', Justification = 'Read by the source-extracted New-Lab media selection.')]
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RootPath 'common\Common.Config.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Common.Config.ps1 parse errors: $($errors -join '; ')" }
$definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-FilesForConfiguration'
    }, $true)
if (-not $definition) { throw 'Get-FilesForConfiguration was not found.' }
. ([scriptblock]::Create($definition.Extent.Text))

function Invoke-ImageRequirementCase {
    param(
        [object[]]$VMs,
        [string[]]$Existing = @(),
        [switch]$Force,
        [switch]$All,
        [switch]$Dhcp,
        [switch]$PrePopulate,
        [string]$FailId
    )

    $downloads = [Collections.Generic.List[object]]::new()
    $Common = [pscustomobject]@{
        AzureFilesPath = $fixtureRoot
        AzureFileList = [pscustomobject]@{
            OS = @(
                [pscustomobject]@{ id = 'Windows 11 latest' }
                [pscustomobject]@{ id = 'Server 2025' }
                [pscustomobject]@{ id = 'Ubuntu Server 24.04 LTS' }
                [pscustomobject]@{ id = 'local-only'; local = $true }
                [pscustomobject]@{ id = 'vmbuildadmin' }
            )
            ISO = @([pscustomobject]@{ id = 'SQL Server 2025' })
            CMVersions = @([pscustomobject]@{ id = 'CM media'; filename = 'cm.zip'; versions = @('2509') })
            SupportFiles = @(
                [pscustomobject]@{ id = 'Prepopulate Baselines' }
                [pscustomobject]@{ id = 'WSUS Categories Baseline' }
            )
            OSISO = @(
                [pscustomobject]@{ id = 'Windows 11 24h2'; filename = 'iso\OS\win11.iso' }
                [pscustomobject]@{ id = 'Windows 10 22h2'; filename = 'iso\OS\win10.iso' }
            )
        }
    }
    $inputConfig = [pscustomobject]@{
        virtualMachines = @($VMs)
        cmOptions = [pscustomobject]@{ version = '2509'; PrePopulateObjects = $PrePopulate.IsPresent }
    }
    function Get-ConfigCmOptions { param($Config) $Config.cmOptions }
    function Test-MemLabsUsesDhcpAppliance { $Dhcp.IsPresent }
    function Write-Log {
        [CmdletBinding()]
        param([string]$Message, [switch]$Activity, [switch]$LogOnly, [switch]$Failure)
    }
    function Get-FileFromStorage {
        [CmdletBinding()]
        param($File, [switch]$ForceDownloadFiles, [switch]$WhatIf, [switch]$UseCDN, [switch]$IgnoreHashFailure)
        if (-not $File) { throw 'A download was requested without a file definition.' }
        $downloads.Add([pscustomobject]@{
                Id = $File.id; Force = $ForceDownloadFiles.IsPresent
                WhatIf = $WhatIf.IsPresent; CDN = $UseCDN.IsPresent; IgnoreHash = $IgnoreHashFailure.IsPresent
            })
        return $File.id -ne $FailId
    }

    $parameters = @{ ExistingVMNames = $Existing; ForceDownloadFiles = $Force; WhatIf = $true; UseCDN = $true; IgnoreHashFailure = $true }
    if ($All) { $parameters.DownloadAll = $true }
    else { $parameters.InputObject = $inputConfig }
    $success = Get-FilesForConfiguration @parameters
    [pscustomobject]@{ Success = $success; Downloads = $downloads.ToArray(); Ids = @($downloads.Id) }
}

function Invoke-ImageCallerCase {
    param([scriptblock]$Block, [switch]$Retry)
    $calls = [Collections.Generic.List[object]]::new()
    $runPhase1 = $false
    $needFiles = $true
    $DownloadFilesOnly = [switch]$false
    $WhatIf = [switch]$false
    $UseCDN = [switch]$false
    $ForceDownloadFiles = [switch]$false
    $deployConfig = [pscustomobject]@{}
    $existingVMs = @([pscustomobject]@{ vmName = 'LAB-W11' })
    function Get-FilesForConfiguration {
        param($InputObject, [string[]]$ExistingVMNames, [switch]$WhatIf, [switch]$UseCDN, [switch]$ForceDownloadFiles)
        $calls.Add(@($ExistingVMNames))
        return -not ($Retry -and $calls.Count -eq 1)
    }
    function Write-Log { param([string]$Message, [switch]$Warning) }
    function Start-Sleep { param([int]$Seconds) }
    . $Block
    return ,$calls
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-image-requirements-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'ISO\OS') -Force
    $client = [pscustomobject]@{ vmName = 'LAB-W11'; operatingSystem = 'Windows 11 latest'; role = 'DomainMember' }
    $server = [pscustomobject]@{ vmName = 'LAB-PRI'; operatingSystem = 'Server 2025'; sqlVersion = 'SQL Server 2025'; role = 'Primary' }
    $result = Invoke-ImageRequirementCase -VMs @($client, $server) -Existing @('LAB-W11', 'LAB-PRI')
    Assert-True ($result.Success -and $result.Ids -notcontains 'Windows 11 latest' -and
        $result.Ids -notcontains 'Server 2025') 'An existing-only update downloaded an OS base image.'
    Assert-True ($result.Ids -contains 'SQL Server 2025' -and $result.Ids -contains 'CM media') 'Skipping existing base images also skipped rerun installation media.'

    $result = Invoke-ImageRequirementCase -VMs @($client, $server) -Existing @('LAB-W11')
    Assert-True ($result.Ids -notcontains 'Windows 11 latest' -and $result.Ids -contains 'Server 2025') 'Mixed deployment did not select only the new VM base image.'
    $secondClient = [pscustomobject]@{ vmName = 'LAB-W12'; operatingSystem = 'Windows 11 latest'; role = 'DomainMember' }
    $result = Invoke-ImageRequirementCase -VMs @($client, $secondClient) -Existing @('lab-w11')
    Assert-True (@($result.Ids | Where-Object { $_ -eq 'Windows 11 latest' }).Count -eq 1) 'A new VM sharing an existing VM OS did not acquire exactly one base image.'

    $result = Invoke-ImageRequirementCase -VMs @($client)
    Assert-True ($result.Ids -contains 'Windows 11 latest') 'Explicit prefetch without an existing-VM exclusion lost its base image.'
    $result = Invoke-ImageRequirementCase -VMs @($client) -Existing @('LAB-W11') -Force
    Assert-True ($result.Ids -contains 'Windows 11 latest' -and
        @($result.Downloads | Where-Object { -not $_.Force -or -not $_.WhatIf -or -not $_.CDN -or -not $_.IgnoreHash }).Count -eq 0) 'Forced acquisition or download switches changed behavior.'
    $result = Invoke-ImageRequirementCase -VMs @($client) -Existing @('LAB-W11') -All
    Assert-True ($result.Ids -contains 'Windows 11 latest' -and $result.Ids -contains 'Server 2025' -and
        $result.Ids -notcontains 'local-only' -and $result.Ids -notcontains 'vmbuildadmin') 'DownloadAll or local-image exclusions regressed.'
    $result = Invoke-ImageRequirementCase -VMs @($client) -Existing @('LAB-W11') -Dhcp
    Assert-True ($result.Ids -contains 'Ubuntu Server 24.04 LTS') 'DHCP appliance image acquisition was skipped.'
    $result = Invoke-ImageRequirementCase -VMs @($client, $server) -Existing @('LAB-W11', 'LAB-PRI') -PrePopulate
    Assert-True ($result.Ids -contains 'Windows 11 24h2' -and $result.Ids -contains 'Prepopulate Baselines') 'Prepopulate OS ISO requirements were confused with deployed VM base images.'
    $result = Invoke-ImageRequirementCase -VMs @($server) -Existing @('LAB-PRI') -FailId 'SQL Server 2025'
    Assert-True (-not $result.Success) 'Required rerun media download failure was hidden.'

    $newLabAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RootPath 'New-Lab.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "New-Lab.ps1 parse errors: $($errors -join '; ')" }
    $assignment = $newLabAst.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Extent.Text -eq '$existingVMNamesForImages = @($existingVMs.vmName)'
        }, $true)
    $prefetch = $newLabAst.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -eq 'if ($DownloadFilesOnly) { $existingVMNamesForImages = @() }'
        }, $true)
    $downloadBlock = $newLabAst.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -like 'if ($DownloadFilesOnly -or $runPhase1 -or $needFiles)*'
        }, $true)
    Assert-True ($null -ne $assignment -and $null -ne $prefetch -and $null -ne $downloadBlock) 'Deployment media-selection wiring was not found.'
    $caller = [scriptblock]::Create($assignment.Extent.Text + "`n" + $prefetch.Extent.Text + "`n" + $downloadBlock.Extent.Text)
    foreach ($retry in @($false, $true)) {
        $calls = Invoke-ImageCallerCase -Block $caller -Retry:$retry
        $expected = 1
        if ($retry) { $expected = 2 }
        Assert-True ($calls.Count -eq $expected) 'The deployment download retry path was not exercised.'
        foreach ($call in $calls) {
            Assert-True (@($call).Count -eq 1 -and $call[0] -eq 'LAB-W11') 'A deployment download attempt lost the existing-VM exclusion.'
        }
    }
    $existingVMs = @([pscustomobject]@{ vmName = 'LAB-W11' })
    $DownloadFilesOnly = [switch]$true
    . ([scriptblock]::Create($assignment.Extent.Text + "`n" + $prefetch.Extent.Text))
    Assert-True ($existingVMNamesForImages.Count -eq 0) 'DownloadFilesOnly still excludes deployed VM base images.'
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions deployment image-requirement assertions."
