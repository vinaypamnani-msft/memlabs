<#
.SYNOPSIS
    Proves fresh WSUS/SUP configurations receive a dedicated content disk.

.DESCRIPTION
    Exercises the allocator that GenConfig uses before any Hyper-V hardware is
    created. The negative controls matter: an existing VM or a VM with no free
    data-drive letter must be rejected without partially changing its config.

    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $color
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

$sourcePath = Join-Path $RootPath 'common\Common.GenConfig.DiskMenu.ps1'
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "SETUP FAIL: source not found at $sourcePath" -ForegroundColor Red
    exit 2
}

. $sourcePath

$modulePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$moduleParseErrors = $null
$moduleTokens = $null
$moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleParseErrors)
if (@($moduleParseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: TemplateHelpDSC.psm1 has $(@($moduleParseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}
foreach ($functionName in @('Get-MemLabsDiskLabelMap', 'Get-MemLabsWsusDiskPolicy', 'Test-MemLabsWsusDiskMetadata', 'Set-MemLabsWsusDiskMetadata')) {
    $definition = @($moduleAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true))
    if ($definition.Count -ne 1) {
        Write-Host "SETUP FAIL: expected one $functionName definition, found $($definition.Count)" -ForegroundColor Red
        exit 2
    }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

function Import-TestFunction {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Path has $(@($errors).Count) parse error(s)"
    }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $Name definition in $Path, found $($definition.Count)"
    }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Get-TestNestedScriptBlock {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $FunctionName,
        [Parameter(Mandatory = $true)]
        [string] $VariableName
    )

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "$Path has $(@($errors).Count) parse error(s)" }
    $function = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
            }, $true))
    if ($function.Count -ne 1) { throw "Expected one $FunctionName definition, found $($function.Count)" }
    $assignment = @($function[0].FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $VariableName
            }, $true))
    if ($assignment.Count -ne 1) { throw "Expected one $VariableName assignment in $FunctionName, found $($assignment.Count)" }
    return $assignment[0].Right.Expression.ScriptBlock.GetScriptBlock()
}

function Write-Log { param() }
function Add-ErrorMessage {
    param ([string] $Property, [string] $Message, [switch] $Warning)
    $script:LastGenConfigError = $Message
}
function Get-NewSiteCode { 'PS1' }
function Test-VmIsLinux { $false }
function Get-CMLatestBaselineVersion { 'current-branch' }

$addVmPath = Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1'
. (Import-TestFunction -Path $addVmPath -Name 'Add-NewVMForRole')
$genConfigValidationPath = Join-Path $RootPath 'common\Common.GenConfig.Validation.ps1'
. (Import-TestFunction -Path $genConfigValidationPath -Name 'Get-AdditionalValidations')

function Get-DiskSnapshot {
    param ([object] $VirtualMachine)

    $diskText = if ($VirtualMachine.additionalDisks) {
        @($VirtualMachine.additionalDisks.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
    }
    else {
        ''
    }
    "$diskText|$($VirtualMachine.wsusContentDir)"
}

Write-Host "engine : $($PSVersionTable.PSVersion)"
Write-Host "source : $sourcePath"
Write-Host ''

$standalone = [pscustomobject]@{ Role = 'WSUS' }
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $standalone) 'standalone WSUS allocation succeeds'
Assert-Equal 'E=250GB' (Get-DiskSnapshot $standalone).Split('|')[0] 'standalone WSUS receives E at 250GB'
Assert-Equal 'E:\WSUS' $standalone.wsusContentDir 'standalone WSUS content uses E'

$primary = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    sqlInstanceDir  = 'F:\SQL'
    additionalDisks = [pscustomobject]@{ E = '600GB'; F = '250GB' }
}
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $primary) 'local-SQL Primary allocation succeeds'
Assert-Equal 'E=600GB;F=250GB;G=250GB' (Get-DiskSnapshot $primary).Split('|')[0] 'local-SQL Primary appends G without reordering E/F'
Assert-Equal 'G:\WSUS' $primary.wsusContentDir 'local-SQL Primary content uses G'
$firstPrimarySnapshot = Get-DiskSnapshot $primary
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $primary) 'repeated allocation succeeds'
Assert-Equal $firstPrimarySnapshot (Get-DiskSnapshot $primary) 'repeated allocation is idempotent'

$historicalPrimary = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    sqlInstanceDir  = 'E:\SQL'
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $historicalPrimary) 'shared historical fresh layout is separated'
Assert-Equal 'E=250GB;F=250GB' (Get-DiskSnapshot $historicalPrimary).Split('|')[0] 'historical site server appends F'
Assert-Equal 'F:\WSUS' $historicalPrimary.wsusContentDir 'historical site server moves WSUS config to F'

$sparsePrimary = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    sqlInstanceDir  = 'H:\SQL'
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '600GB'; H = '250GB' }
}
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $sparsePrimary) 'sparse-letter Primary allocation succeeds'
Assert-Equal 'E=600GB;H=250GB;F=250GB' (Get-DiskSnapshot $sparsePrimary).Split('|')[0] 'next-free F appends after E/H without reordering existing VHD identities'
Assert-Equal 'F:\WSUS' $sparsePrimary.wsusContentDir 'sparse-letter Primary content uses F'

$dpSup = [pscustomobject]@{
    Role            = 'SiteSystem'
    InstallDP       = $true
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $dpSup) 'DP/SUP allocation succeeds'
Assert-Equal 'E=250GB;F=250GB' (Get-DiskSnapshot $dpSup).Split('|')[0] 'DP/SUP retains an alternate ConfigMgr disk'
Assert-Equal 'F:\WSUS' $dpSup.wsusContentDir 'DP/SUP content uses F'

$custom = [pscustomobject]@{
    Role            = 'WSUS'
    wsusContentDir  = 'H:\WsusStore'
    additionalDisks = [pscustomobject]@{ H = '500GB' }
}
$customBefore = Get-DiskSnapshot $custom
Assert-Equal $true (Set-WsusDedicatedContentDisk -VirtualMachine $custom) 'custom dedicated WSUS layout is accepted'
Assert-Equal $customBefore (Get-DiskSnapshot $custom) 'custom dedicated WSUS layout is preserved'

$existing = [pscustomobject]@{
    Role            = 'Primary'
    ExistingVM      = $true
    cmInstallDir    = 'E:\ConfigMgr'
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '600GB' }
}
$existingBefore = Get-DiskSnapshot $existing
Assert-Equal $false (Set-WsusDedicatedContentDisk -VirtualMachine $existing) 'existing VM is rejected'
Assert-Equal $existingBefore (Get-DiskSnapshot $existing) 'existing VM remains unchanged'

$allLetters = [ordered]@{}
foreach ($code in 69..89) {
    $letter = [string][char]$code
    if ($letter -ne 'S') { $allLetters[$letter] = '10GB' }
}
$exhausted = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    additionalDisks = [pscustomobject]$allLetters
}
$exhaustedBefore = Get-DiskSnapshot $exhausted
Assert-Equal $false (Set-WsusDedicatedContentDisk -VirtualMachine $exhausted) 'exhausted drive letters are rejected'
Assert-Equal $exhaustedBefore (Get-DiskSnapshot $exhausted) 'exhausted allocation has no partial mutation'

$generatedConfig = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ domainName = 'example.test' }
    domainDefaults  = [pscustomobject]@{
        IncludeSSMSOnNONSQL       = $false
        DefaultSqlVersion         = 'SQL Server 2022'
        EnableSUPOnSiteServers    = $true
        UseDynamicMemory          = $false
        PushCMClientToSiteSystems = $false
        UseProxyForCM             = $false
    }
    cmOptions       = [pscustomobject]@{ EnableBLM = $false }
    virtualMachines = @([pscustomobject]@{ vmName = 'EXISTINGDP'; role = 'SiteSystem'; installDP = $true })
}
Add-NewVMForRole -Role 'Primary' -Domain 'example.test' -ConfigToModify $generatedConfig -Name 'PS1SITE' -OperatingSystem 'Server 2022' -Quiet:$true -Test:$true
$generatedPrimary = $generatedConfig.virtualMachines | Where-Object { $_.vmName -eq 'PS1SITE' } | Select-Object -First 1
Assert-Equal $true ([bool]$generatedPrimary) 'production Add-NewVMForRole creates the Primary'
Assert-Equal 'E=600GB;F=250GB;G=250GB' (Get-DiskSnapshot $generatedPrimary).Split('|')[0] 'production Primary creation allocates a third WSUS disk'
Assert-Equal 'G:\WSUS' $generatedPrimary.wsusContentDir 'production Primary creation binds WSUS to G'

$existingSupTarget = [pscustomobject]@{
    vmName     = 'EXISTING'
    Role       = 'SiteSystem'
    ExistingVM = $true
    InstallSUP = $true
}
$script:LastGenConfigError = ''
Get-AdditionalValidations -Property $existingSupTarget -Name 'InstallSUP' -CurrentValue $false
Assert-Equal $false $existingSupTarget.InstallSUP 'GenConfig rolls back SUP enablement on an existing VM'
Assert-Equal $true ($script:LastGenConfigError -match 'fresh VM') 'existing-VM rejection explains the fresh-build boundary'

$sharedPathEdit = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '600GB'; F = '250GB' }
}
$script:LastGenConfigError = ''
Get-AdditionalValidations -Property $sharedPathEdit -Name 'wsusContentDir' -CurrentValue 'F:\WSUS'
Assert-Equal 'F:\WSUS' $sharedPathEdit.wsusContentDir 'GenConfig rolls back a WSUS path that shares the ConfigMgr disk'
Assert-Equal $true ($script:LastGenConfigError -match 'already used') 'shared-path rejection identifies the conflicting owner'

$sharedPolicy = Get-MemLabsWsusDiskPolicy -VM $historicalPrimary
Assert-Equal $true $sharedPolicy.Dedicated 'separated historical fresh layout is classified as dedicated'
Assert-Equal 'F' $sharedPolicy.Letter 'separated historical fresh layout identifies F as WSUS'
Assert-Equal $true $sharedPolicy.RequiresSmsExclusion 'site-server WSUS disk requires ConfigMgr exclusion'
Assert-Equal 'CM_SQL' $sharedPolicy.ExpectedLabels['E'] 'former shared disk label drops WSUS ownership'
Assert-Equal 'WSUS' $sharedPolicy.ExpectedLabels['F'] 'new content disk label is WSUS'

$legacyShared = [pscustomobject]@{
    Role            = 'Primary'
    cmInstallDir    = 'E:\ConfigMgr'
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '600GB' }
}
Assert-Equal $false (Get-MemLabsWsusDiskPolicy -VM $legacyShared).Dedicated 'legacy shared site-server layout is grandfathered'

$legacyOneDiskDp = [pscustomobject]@{
    Role            = 'SiteSystem'
    InstallDP       = $true
    wsusContentDir  = 'E:\WSUS'
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Assert-Equal $false (Get-MemLabsWsusDiskPolicy -VM $legacyOneDiskDp).Dedicated 'legacy one-disk DP/SUP layout is grandfathered'

$fixtureFiles = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'config\tests') -Filter '*.json' -File)
$fixtureParseFailures = [System.Collections.Generic.List[string]]::new()
$fixtureWsusVms = [System.Collections.Generic.List[object]]::new()
foreach ($fixtureFile in $fixtureFiles) {
    try {
        $fixtureConfig = Get-Content -LiteralPath $fixtureFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($fixtureVm in @($fixtureConfig.virtualMachines | Where-Object { $_.Role -eq 'WSUS' -or $_.InstallSUP -eq $true })) {
            $fixtureWsusVms.Add([pscustomobject]@{ File = $fixtureFile.Name; VM = $fixtureVm })
        }
    }
    catch {
        $fixtureParseFailures.Add("$($fixtureFile.Name): $($_.Exception.Message)")
    }
}
$nonDedicatedFixtures = @($fixtureWsusVms | Where-Object { -not (Get-MemLabsWsusDiskPolicy -VM $_.VM).Dedicated })
Assert-Equal $true ($fixtureFiles.Count -gt 0) 'fixture corpus scans at least one JSON file'
Assert-Equal 0 $fixtureParseFailures.Count 'every fixture JSON file parses'
Assert-Equal $true ($fixtureWsusVms.Count -gt 0) 'fixture corpus measures at least one WSUS/SUP VM'
Assert-Equal '' (($nonDedicatedFixtures | ForEach-Object { "$($_.File):$($_.VM.vmName)" }) -join ',') 'every repository WSUS/SUP fixture has dedicated content storage'

$script:MockVolumes = @{
    E = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'CM_SQL' }
    F = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'DATA_0' }
}
$script:MockMarkers = @{}
function Get-Volume {
    param ([string] $DriveLetter, $ErrorAction)
    $script:MockVolumes[$DriveLetter]
}
function Set-Volume {
    param ([string] $DriveLetter, [string] $NewFileSystemLabel, $ErrorAction)
    $script:MockVolumes[$DriveLetter].FileSystemLabel = $NewFileSystemLabel
}
function New-Item {
    param ([string] $Path, [string] $ItemType, [switch] $Force, $ErrorAction)
    $script:MockMarkers[$Path] = $true
}
function Test-Path {
    param ([string] $LiteralPath, [string] $PathType)
    $script:MockMarkers.ContainsKey($LiteralPath)
}
Assert-Equal $false (Test-MemLabsWsusDiskMetadata -Policy $sharedPolicy) 'stale label and missing marker are not desired state'
Set-MemLabsWsusDiskMetadata -Policy $sharedPolicy
Assert-Equal 'WSUS' $script:MockVolumes['F'].FileSystemLabel 'metadata repair relabels the WSUS disk without formatting'
Assert-Equal 'CM_SQL' $script:MockVolumes['E'].FileSystemLabel 'metadata repair preserves the corrected CM/SQL label'
Assert-Equal $true (Test-MemLabsWsusDiskMetadata -Policy $sharedPolicy) 'correct labels and marker reach desired state'

$phase11Path = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
. (Import-TestFunction -Path $phase11Path -Name 'Get-Phase11WsusDiskPolicy')
. (Import-TestFunction -Path $phase11Path -Name 'Test-AdditionalDisks')
$phase11GuestBlock = Get-TestNestedScriptBlock -Path $phase11Path -FunctionName 'Test-AdditionalDisks' -VariableName '$scriptBlock'

$script:MockDpRegistryAvailable = $true
$script:MockDpContentPath = 'E:\SCCMContentLib'
$script:LastPhase11Result = $null
function Get-Partition { @() }
function Get-ItemProperty {
    param ([string] $LiteralPath, [string] $Name, $ErrorAction)
    if (-not $script:MockDpRegistryAvailable) { throw 'mock DP registry unavailable' }
    [pscustomobject]@{ ContentLibraryPath = $script:MockDpContentPath }
}
function Invoke-VmCommand {
    param (
        [string] $VmName,
        [string] $VmDomainName,
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList,
        [string] $DisplayName,
        [switch] $SuppressLog,
        [switch] $AsJob,
        [int] $TimeoutSeconds
    )
    $output = & $ScriptBlock @ArgumentList
    [pscustomobject]@{ ScriptBlockOutput = $output; ScriptBlockFailed = $false }
}
function Format-TestResult {
    param ([string] $VMName, [string] $RoleLabel, [object] $Result)
    $script:LastPhase11Result = $Result.ScriptBlockOutput
    return [bool]$Result.ScriptBlockOutput.Passed
}

$phase11Config = [pscustomobject]@{ vmOptions = [pscustomobject]@{ domainName = 'example.test' } }
$script:MockVolumes = @{
    E = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'DATA_0'; Size = 250GB }
    F = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'WSUS'; Size = 250GB }
}
$script:MockMarkers = @{ 'F:\NO_SMS_ON_DRIVE.SMS' = $true }
$badJsonResult = & $phase11GuestBlock 'E' '{not-json}'
Assert-Equal $false $badJsonResult.Passed 'Phase 11 rejects an unreadable WSUS policy payload'
$emptyPolicyResult = & $phase11GuestBlock 'E' '{"Dedicated":true,"ContentPath":"F:\\WSUS","ExpectedLabels":{}}'
Assert-Equal $false $emptyPolicyResult.Passed 'Phase 11 rejects a dedicated policy with zero expected labels'
Assert-Equal 1 @($emptyPolicyResult.Details | Where-Object { $_ -match 'metadata was not measured' }).Count 'empty policy reports that metadata was not measured'
Assert-Equal $true (Test-AdditionalDisks -VMName 'DPSUP' -CurrentItem $dpSup -DeployConfig $phase11Config) 'Phase 11 accepts separated DP and WSUS placement'

$script:MockVolumes['F'].FileSystemLabel = 'DATA_0'
Assert-Equal $false (Test-AdditionalDisks -VMName 'DPSUP' -CurrentItem $dpSup -DeployConfig $phase11Config) 'Phase 11 rejects a stale WSUS volume label'
$script:MockVolumes['F'].FileSystemLabel = 'WSUS'

$script:MockMarkers.Clear()
Assert-Equal $false (Test-AdditionalDisks -VMName 'DPSUP' -CurrentItem $dpSup -DeployConfig $phase11Config) 'Phase 11 rejects a missing ConfigMgr exclusion marker'
$script:MockMarkers['F:\NO_SMS_ON_DRIVE.SMS'] = $true

$script:MockDpContentPath = 'F:\SCCMContentLib'
Assert-Equal $false (Test-AdditionalDisks -VMName 'DPSUP' -CurrentItem $dpSup -DeployConfig $phase11Config) 'Phase 11 rejects DP content on the WSUS drive'

$script:MockDpRegistryAvailable = $false
Assert-Equal $true (Test-AdditionalDisks -VMName 'DPSUP' -CurrentItem $dpSup -DeployConfig $phase11Config) 'Phase 11 does not invent a DP path when registry measurement fails'
$notMeasured = @($script:LastPhase11Result.Details | Where-Object { $_ -match 'DP ContentLibraryPath not measured' }).Count
Assert-Equal 1 $notMeasured 'Phase 11 reports the unavailable DP path as not measured'

$script:MockVolumes = @{ E = [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'CM_WSUS'; Size = 600GB } }
$script:MockMarkers.Clear()
Assert-Equal $true (Test-AdditionalDisks -VMName 'LEGACY' -CurrentItem $legacyShared -DeployConfig $phase11Config) 'Phase 11 grandfathers a legacy shared layout'

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0