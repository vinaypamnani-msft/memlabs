<#
.SYNOPSIS
    Exercises current-develop existing-domain logic against VM notes emitted by exact main.

.DESCRIPTION
    The producer functions are lifted from the pinned main Git object and run against an
    in-memory Hyper-V mock. Their serialized Notes JSON is then consumed by the functions
    in the current worktree. Known compatibility defects are reported as XFAIL; an XPASS
    fails the test so the expectation must be reviewed when a defect is fixed.
#>
[CmdletBinding()]
param(
    [string] $RootPath,
    [string] $MainRevision = '6f165b5f2d370598d65bf7091c2537f101909dcf'
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$repoRoot = Split-Path -Parent $RootPath
$script:Failures = 0
$script:ExpectedFailures = 0
$script:ProducerVm = $null
$script:VmStore = @{}
$script:Inventory = @()
$script:Common = [pscustomobject]@{ MemLabsVersion = '260829.0' }
$global:vm_List = @()

function Write-TestResult {
    param(
        [string] $State,
        [string] $What,
        [string] $Detail = ''
    )

    $color = switch ($State) {
        'PASS' { 'Green' }
        'XFAIL' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host ("{0}  {1}" -f $State, $What) -ForegroundColor $color
    if ($Detail) { Write-Host "      $Detail" -ForegroundColor DarkGray }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What)

    if ("$Expected" -eq "$Actual") {
        Write-TestResult -State PASS -What $What
        return
    }
    $script:Failures++
    Write-TestResult -State FAIL -What $What -Detail "expected=[$Expected] actual=[$Actual]"
}

function Assert-True {
    param([bool] $Condition, [string] $What, [string] $Detail = '')

    if ($Condition) {
        Write-TestResult -State PASS -What $What
        return
    }
    $script:Failures++
    Write-TestResult -State FAIL -What $What -Detail $Detail
}

function Assert-KnownFailure {
    param([bool] $Condition, [string] $What, [string] $Detail)

    if (-not $Condition) {
        $script:ExpectedFailures++
        Write-TestResult -State XFAIL -What $What -Detail $Detail
        return
    }
    $script:Failures++
    Write-TestResult -State XPASS -What $What -Detail 'The known defect no longer reproduces; convert this case to a passing assertion.'
}

function Get-GitFileText {
    param([string] $Revision, [string] $Path)

    $lines = @(& git -C $repoRoot show "$Revision`:$Path")
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
        throw "Could not read $Revision`:$Path"
    }
    return [string]::Join([Environment]::NewLine, $lines)
}

function Get-FunctionText {
    param([string] $Text, [string] $Name, [string] $Source)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "$Source has $(@($errors).Count) parse error(s)." }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Source, found $($definitions.Count)." }
    return $definitions[0].Extent.Text
}

function Get-WorktreeFunctionText {
    param([string] $RelativePath, [string] $Name)

    $path = Join-Path $RootPath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { throw "Source file not found: $path" }
    return Get-FunctionText -Text ([IO.File]::ReadAllText($path)) -Name $Name -Source $path
}

$mainCommonText = Get-GitFileText -Revision $MainRevision -Path 'vmbuild/Common.ps1'
$mainNewVmNoteText = Get-FunctionText -Text $mainCommonText -Name New-VmNote -Source "$MainRevision`:vmbuild/Common.ps1"
$mainSetVmNoteText = Get-FunctionText -Text $mainCommonText -Name Set-VMNote -Source "$MainRevision`:vmbuild/Common.ps1"

function Invoke-MainNoteProducer {
    param(
        [Parameter(Mandatory)] [object] $DeployConfig,
        [Parameter(Mandatory)] [string] $VmName
    )

    $script:ProducerVm = [pscustomobject]@{ Name = $VmName; Notes = '' }
    Set-Variable -Name Common -Value ([pscustomobject]@{ MemLabsVersion = '260420.0' }) -Scope Local

    function Write-Log {
        param(
            $Message,
            [switch] $Failure,
            [switch] $LogOnly,
            [switch] $Verbose,
            [switch] $Warning
        )
    }
    function Get-VM2 {
        [CmdletBinding()]
        param([Parameter(Position = 0)][string] $Name, [switch] $Fallback)
        if ($script:ProducerVm -and $script:ProducerVm.Name -eq $Name) { return $script:ProducerVm }
        return $null
    }
    function Get-VMNote {
        param([string] $VMName)
        if ($script:ProducerVm -and $script:ProducerVm.Name -eq $VMName -and $script:ProducerVm.Notes -like '*lastUpdate*') {
            return $script:ProducerVm.Notes | ConvertFrom-Json
        }
        return $null
    }
    function Set-VM {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline = $true)] $InputObject,
            [string] $Notes
        )
        process { $script:ProducerVm.Notes = $Notes }
    }

    . ([scriptblock]::Create($mainSetVmNoteText))
    . ([scriptblock]::Create($mainNewVmNoteText))

    New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
    New-VmNote -VmName $VmName -DeployConfig $DeployConfig -Successful $true
    return [string]$script:ProducerVm.Notes
}

function Write-Log {
    param(
        $Message,
        [switch] $Failure,
        [switch] $LogOnly,
        [switch] $Verbose,
        [switch] $Warning,
        [switch] $Information
    )
}
function Get-VM2 {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string] $Name, [switch] $Fallback)
    return $script:VmStore[$Name]
}
function Get-List {
    param([string] $Type, [string] $DomainName, [switch] $SmartUpdate)
    if ($DomainName) { return @($script:Inventory | Where-Object { $_.domain -eq $DomainName }) }
    return @($script:Inventory)
}
function get-PrefixForDomain {
    param([string] $Domain)
    return [string](@($script:Inventory | Where-Object { $_.domain -eq $Domain } | Select-Object -First 1)[0].prefix)
}
function Get-MemlabsVmStorageRoot { return 'E:\VirtualMachines' }
function Get-CMLatestBaselineVersion { return '2509' }

. ([scriptblock]::Create((Get-WorktreeFunctionText -RelativePath 'Common.ps1' -Name Get-VMNote)))
. ([scriptblock]::Create((Get-WorktreeFunctionText -RelativePath 'Common.ps1' -Name Test-VmPhase1Incomplete)))
. ([scriptblock]::Create((Get-WorktreeFunctionText -RelativePath 'common\Common.Config.ps1' -Name Update-VMFromHyperV)))
. ([scriptblock]::Create((Get-WorktreeFunctionText -RelativePath 'common\Common.GenConfig.Existing.ps1' -Name New-UserConfig)))

function Convert-MainNoteToInventory {
    param([string] $RawNote)

    $note = $RawNote | ConvertFrom-Json
    $id = [guid]::NewGuid()
    $vm = [pscustomobject]@{
        Name  = [string]$note.vmName
        Id    = $id
        vmID  = $id
        State = 'Running'
        Notes = $RawNote
    }
    $projection = [pscustomobject]@{
        vmName          = $vm.Name
        vmId            = $id
        memoryGB        = 0
        memoryStartupGB = 4
        diskUsedGB      = 0
        Memory          = '4GB'
    }
    $global:vm_List = @($projection)
    Update-VMFromHyperV -vm $vm -vmObject $projection -vmNoteObject $note
    $script:VmStore[$vm.Name] = $vm
    return $projection
}

function New-DcDeployConfig {
    param(
        [string] $Domain = 'nocm.com',
        [string] $NetBios = 'nocm',
        [string] $Prefix = 'NOC-',
        [string] $DeploymentType = 'No ConfigMgr'
    )

    return [pscustomobject]@{
        vmOptions       = [pscustomobject]@{
            prefix = $Prefix; domainName = $Domain; domainNetBiosName = $NetBios
            adminName = 'admin2'; network = '10.220.201.0'
        }
        domainDefaults  = [pscustomobject]@{
            DeploymentType = $DeploymentType; CMVersion = '2403'; DomainName = $Domain
            Network = '10.220.201.0'; DefaultClientOS = 'Windows 11 Latest'
            DefaultServerOS = 'Server 2022'; DefaultSqlVersion = 'Sql Server 2022'
            UseDynamicMemory = $true; IncludeClients = $false; IncludeSSMSOnNONSQL = $false
        }
        virtualMachines = @([pscustomobject]@{
                vmName = "$Prefix`DC1"; role = 'DC'; operatingSystem = 'Server 2022'
                memory = '4GB'; virtualProcs = 2; tpmEnabled = $false; InstallCA = $true
                ForestTrust = 'NONE'; dynamicMinRam = '1GB'
                thisParams = [pscustomobject]@{ MustNotPersist = $true }
                SQLAO = [pscustomobject]@{ MustNotPersist = $true }
            })
    }
}

function Add-PrimaryToDeployConfig {
    param([object] $Config)
    $Config.domainDefaults.DeploymentType = 'Primary Site only'
    $Config.virtualMachines += [pscustomobject]@{
        vmName = "$($Config.vmOptions.prefix)PS1SITE"; role = 'Primary'; siteCode = 'PS1'
        operatingSystem = 'Server 2022'; memory = '12GB'; virtualProcs = 8
        sqlVersion = 'SQL Server 2019'; sqlInstanceName = 'MSSQLSERVER'; sqlPort = '1433'
        cmInstallDir = 'E:\ConfigMgr'; additionalDisks = [pscustomobject]@{ E = '250GB' }
    }
    $Config | Add-Member -NotePropertyName cmOptions -NotePropertyValue ([pscustomobject]@{
            Version = '2403'; Install = $true; PrePopulateObjects = $true; UsePKI = $true
        }) -Force
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "main    : $MainRevision"
Write-Host "develop : $((git -C $repoRoot rev-parse HEAD).Trim())"
Write-Host ''

$nocmDeploy = New-DcDeployConfig
$nocmDcName = [string]$nocmDeploy.virtualMachines[0].vmName
$nocmRaw = Invoke-MainNoteProducer -DeployConfig $nocmDeploy -VmName $nocmDcName
$nocmNote = $nocmRaw | ConvertFrom-Json

Assert-True ($nocmRaw -like '*lastUpdate*') 'main writer emits the lastUpdate recognition marker'
Assert-Equal '260420.0' $nocmNote.memLabsDeployVersion 'main writer emits its deployment version'
Assert-Equal $false ([bool]$nocmNote.inProgress) 'successful main note clears inProgress'
Assert-Equal $true ([bool]$nocmNote.success) 'successful main note records success'
Assert-Equal 'DC' $nocmNote.role 'main note preserves role'
Assert-Equal 'nocm.com' $nocmNote.domain 'main note preserves domain'
Assert-Equal '10.220.201.0' $nocmNote.network 'main note preserves deployed network'
Assert-Equal 'No ConfigMgr' $nocmNote.domainDefaults.DeploymentType 'main DC note preserves domain defaults'
Assert-Equal $false ($null -ne $nocmNote.PSObject.Properties['domainNetBiosName']) 'main note omits modern domainNetBiosName metadata'
Assert-Equal $false ($null -ne $nocmNote.PSObject.Properties['lastPhaseComplete']) 'main note omits modern phase-completion metadata'
Assert-Equal $false ($null -ne $nocmNote.PSObject.Properties['thisParams']) 'main writer excludes generated thisParams'
Assert-Equal $false ($null -ne $nocmNote.PSObject.Properties['SQLAO']) 'main writer excludes generated SQLAO metadata'

$nocmProjection = Convert-MainNoteToInventory -RawNote $nocmRaw
Assert-Equal 'DC' $nocmProjection.role 'develop hydrates the main role'
Assert-Equal 'nocm.com' $nocmProjection.domain 'develop hydrates the main domain'
Assert-Equal 'Server 2022' $nocmProjection.OperatingSystem 'develop maps deployedOS to OperatingSystem'
Assert-Equal $true ([bool]$nocmProjection.vmBuild) 'develop recognizes the main note as MemLabs-managed'

$readBack = Get-VMNote -VMName $nocmDcName
Assert-True ($null -ne $readBack) 'develop Get-VMNote admits the exact-main note'

$withoutMarker = $nocmRaw | ConvertFrom-Json
$withoutMarker.PSObject.Properties.Remove('lastUpdate')
$script:VmStore[$nocmDcName].Notes = $withoutMarker | ConvertTo-Json -Compress
Assert-Equal $false ([bool](Get-VMNote -VMName $nocmDcName)) 'missing lastUpdate control is rejected'
$script:VmStore[$nocmDcName].Notes = $nocmRaw

$legacyState = Test-VmPhase1Incomplete -VmName $nocmDcName
Assert-Equal $false ([bool]$legacyState.Incomplete) 'older main note without phase stamp is never destructively rebuilt'
Assert-True ($legacyState.Reason -like 'built by older build*') 'legacy safety decision reports its version basis' $legacyState.Reason

$script:Inventory = @($nocmProjection)
$nocmExisting = New-UserConfig -Domain 'nocm.com' -Subnet '10.220.202.0'
Assert-Equal 'nocm' $nocmExisting.vmOptions.domainNetBiosName 'ordinary DNS label reconstructs the expected NetBIOS name'
Assert-Equal 'NOC-' $nocmExisting.vmOptions.prefix 'existing-domain config preserves prefix'
Assert-Equal 'admin2' $nocmExisting.vmOptions.adminName 'existing-domain config preserves admin account'
Assert-Equal '10.220.202.0' $nocmExisting.vmOptions.network 'new VM may target a second subnet'
Assert-Equal 'No ConfigMgr' $nocmExisting.domainDefaults.DeploymentType 'existing-domain config preserves No ConfigMgr defaults'
Assert-Equal $false ($null -ne $nocmExisting.PSObject.Properties['cmOptions']) 'No ConfigMgr domain does not synthesize cmOptions'
Assert-Equal $true ([bool]$nocmExisting.pkiOptions.EnablePKI) 'NOCM CA is recovered from legacy InstallCA metadata'

$disjointDeploy = New-DcDeployConfig -Domain 'sandwich.lab' -NetBios 'TACO' -Prefix 'TAC-'
$disjointRaw = Invoke-MainNoteProducer -DeployConfig $disjointDeploy -VmName 'TAC-DC1'
$disjointProjection = Convert-MainNoteToInventory -RawNote $disjointRaw
$script:Inventory = @($disjointProjection)
$disjointExisting = New-UserConfig -Domain 'sandwich.lab' -Subnet '10.220.202.0'
Assert-KnownFailure ($disjointExisting.vmOptions.domainNetBiosName -eq 'TACO') `
    'legacy disjoint NetBIOS name survives reconstruction' `
    "main note omitted TACO; develop reconstructed '$($disjointExisting.vmOptions.domainNetBiosName)' from the DNS label"

$legacyPkiDeploy = New-DcDeployConfig -Domain 'legacypki.lab' -NetBios 'LEGACY' -Prefix 'LPK-'
Add-PrimaryToDeployConfig -Config $legacyPkiDeploy
$legacyDcRaw = Invoke-MainNoteProducer -DeployConfig $legacyPkiDeploy -VmName 'LPK-DC1'
$legacyPrimaryRaw = Invoke-MainNoteProducer -DeployConfig $legacyPkiDeploy -VmName 'LPK-PS1SITE'
$legacyDcProjection = Convert-MainNoteToInventory -RawNote $legacyDcRaw
$legacyPrimaryProjection = Convert-MainNoteToInventory -RawNote $legacyPrimaryRaw
$script:Inventory = @($legacyDcProjection, $legacyPrimaryProjection)
$legacyPkiExisting = New-UserConfig -Domain 'legacypki.lab' -Subnet '10.220.202.0'
Assert-Equal $true ([bool]$legacyPkiExisting.pkiOptions.EnablePKI) 'legacy CA metadata reconstructs pkiOptions'
Assert-KnownFailure `
    ([bool]$legacyPkiExisting.cmOptions.UsePKI -eq [bool]$legacyPkiExisting.pkiOptions.EnablePKI) `
    'legacy ConfigMgr PKI reconstruction is internally consistent before deployment recovery' `
    "pkiOptions.EnablePKI=$($legacyPkiExisting.pkiOptions.EnablePKI), cmOptions.UsePKI=$($legacyPkiExisting.cmOptions.UsePKI)"

Write-Host ''
Write-Host "expected failures : $script:ExpectedFailures" -ForegroundColor Yellow
if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures unexpected result(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'PASS: exact-main notes satisfy current-develop compatibility expectations.' -ForegroundColor Green
exit 0