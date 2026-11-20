<#
.SYNOPSIS
    Verifies idempotent repair of inherited Primary prepopulation payloads.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'AST-extracted production preflight consumes fixture variables dynamically.')]
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$downloadCachePath = Join-Path $RootPath 'common\Common.DownloadCache.ps1'
$scriptBlocksPath = Join-Path $RootPath 'common\Common.ScriptBlocks.ps1'
$phasesPath = Join-Path $RootPath 'common\Common.Phases.ps1'
$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$validationPath = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$repairDefinition = Import-TestFunction -Path $downloadCachePath -Name 'Repair-PrimaryPrepopulationPayload'
. $repairDefinition

$script:GuestState = @{ Baselines = $true; W11 = $true; W10 = $true; Application = $true }
$script:Mounted = [System.Collections.Generic.List[string]]::new()
$script:Dismounted = [System.Collections.Generic.List[string]]::new()
$script:CopiedOs = [System.Collections.Generic.List[string]]::new()
$script:BaselineCopies = 0
$script:BaselinePending = $false
$script:BaselineCopyFailures = 0
$script:BaselineStrict = $false
$script:ApplicationCopies = 0
$script:ApplicationStrict = $false
$script:ApplicationCopyMode = 'normal'
$script:ApplicationDestinations = [Collections.Generic.List[string]]::new()
$script:SitePresent = $false
$script:Warnings = [Collections.Generic.List[string]]::new()
$script:StrictCalls = 0
$script:ProbeMode = 'normal'

function Get-TestPayloadState {
    $missing = @()
    if (-not $script:GuestState.W11) { $missing += 'Windows 11 24h2' }
    if (-not $script:GuestState.W10) { $missing += 'Windows 10 22h2' }
    [pscustomobject]@{
        BaselinesPresent = $script:GuestState.Baselines -and -not $script:BaselinePending
        MissingOs        = [string[]]$missing
        MissingApplications = [string[]]@('7-Zip\7z.msi' | Where-Object {
                -not $script:GuestState.Application -or -not (Test-Path -LiteralPath (Join-Path $tempRoot 'tools\7z.msi'))
            })
        SitePresent = $script:SitePresent
    }
}

function Invoke-VmCommand {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [switch]$RequireDomainIdentity,
        [switch]$AsJob,
        [int]$TimeoutSeconds,
        [string]$DisplayName,
        [scriptblock]$ScriptBlock,
        $ArgumentList
    )
    if ($RequireDomainIdentity) { $script:StrictCalls++ }
    if ($DisplayName -eq 'Inspect Primary prepopulation payload') {
        if ($script:ProbeMode -eq 'transient') {
            return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @('Transport interrupted') }
        }
        if ($script:ProbeMode -eq 'malformed') {
            return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @([pscustomobject]@{ BaselinesPresent = 'yes'; MissingOs = @(); MissingApplications = @() }); ErrorDetails = @() }
        }
        if ($script:ProbeMode -eq 'ambiguous') {
            return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @((Get-TestPayloadState), (Get-TestPayloadState)); ErrorDetails = @() }
        }
    }
    if ($DisplayName -eq 'Prepare Primary baseline copy') {
        $script:BaselinePending = $true
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('BASELINE_COPY_PENDING'); ErrorDetails = @() }
    }
    if ($DisplayName -eq 'Verify Primary baseline copy') {
        $script:BaselinePending = $false
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('BASELINE_COPY_VERIFIED'); ErrorDetails = @() }
    }
    if ($DisplayName -like 'Prepare Primary application source*') {
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('APPLICATION_SOURCE_READY'); ErrorDetails = @() }
    }
    if ($DisplayName -like 'Verify Primary application source*') {
        if ($script:ApplicationCopyMode -eq 'partial') {
            return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @('Hash mismatch') }
        }
        $script:GuestState.Application = $true
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('APPLICATION_SOURCE_VERIFIED'); ErrorDetails = @() }
    }
    if ($DisplayName -like 'Repair Primary OSD media*') {
        if ($DisplayName -match 'Windows 11') { $script:GuestState.W11 = $true; $script:CopiedOs.Add('Windows 11 24h2') }
        elseif ($DisplayName -match 'Windows 10') { $script:GuestState.W10 = $true; $script:CopiedOs.Add('Windows 10 22h2') }
        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @('copied'); ErrorDetails = @() }
    }
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @(Get-TestPayloadState); ErrorDetails = @() }
}

function Copy-ItemSafe {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [string]$Path,
        [string]$Destination,
        [switch]$Recurse,
        [switch]$Container,
        [switch]$Force,
        [switch]$RequireDomainIdentity
    )
    if ($RequireDomainIdentity) { $script:StrictCalls++ }
    if ((Split-Path $Path -Leaf) -eq '7z.msi') {
        $script:ApplicationCopies++
        $script:ApplicationDestinations.Add($Destination)
        if ($RequireDomainIdentity) { $script:ApplicationStrict = $true }
        if ($script:ApplicationCopyMode -eq 'interrupted') { return $false }
        return $true
    }
    if ($RequireDomainIdentity) { $script:BaselineStrict = $true }
    $script:GuestState.Baselines = $true
    $script:BaselineCopies++
    if ($script:BaselineCopyFailures -gt 0) {
        $script:BaselineCopyFailures--
        return $false
    }
    return $true
}

function Mount-IsoOnVm {
    param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase)
    $script:Mounted.Add($IsoPath)
    return $true
}

function Confirm-IsoVisibleInGuest {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [string]$MarkerRelativePath,
        [string]$Context,
        [int]$TimeoutSeconds,
        [int]$Phase
    )
    return $true
}

function Dismount-IsoFromVm {
    param([string]$VmName, [string]$IsoPath, [string]$Context, [int]$Phase)
    $script:Dismounted.Add($IsoPath)
}

function Write-Log {
    param(
        [Parameter(Position = 0)][string]$Message,
        [switch]$Failure,
        [switch]$Warning,
        [switch]$Success,
        [switch]$OutputStream,
        [switch]$LogOnly
    )
    if ($Warning) { $script:Warnings.Add($Message) }
}

function Write-Progress2 {
    param(
        [string]$Activity,
        [string]$Status,
        [switch]$Force,
        [switch]$Completed
    )
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-prepopulation-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'support') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'tools') -Force
Set-Content -LiteralPath (Join-Path $tempRoot 'tools\7z.msi') -Value 'expected-msi' -Encoding ASCII
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'support\baselines.zip') -Force
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'w11.iso') -Force
$null = New-Item -ItemType File -Path (Join-Path $tempRoot 'w10.iso') -Force

try {
    $vm = [pscustomobject]@{ vmName = 'LAB-PRI'; role = 'Primary'; cmInstallDir = 'E:\ConfigMgr' }
    $fileList = [pscustomobject]@{
        Tools = @(
            [pscustomobject]@{ Name = '7-Zip'; Appinstall = $true; AppMsi = '7z.msi' },
            [pscustomobject]@{ Appinstall = $false; AppMsi = 'disabled.msi' }
        )
        OSISO = @(
            [pscustomobject]@{ id = 'Windows 11 24h2'; filename = 'w11.iso' },
            [pscustomobject]@{ id = 'Windows 10 22h2'; filename = 'w10.iso' }
        )
    }

    $healthy = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True $healthy 'Complete payload should pass.'
    Assert-True ($script:Mounted.Count -eq 0 -and $script:BaselineCopies -eq 0) 'Complete payload should be a no-op.'
    Assert-True ($script:ApplicationCopies -eq 0) 'Current application installers should not be copied.'

    $script:GuestState.Application = $false
    $repairedApplication = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True ($repairedApplication -and $script:ApplicationCopies -eq 1 -and $script:GuestState.Application) `
        'A retained Primary with complete OS media and baselines must still repair its missing application installer.'
    Assert-True $script:ApplicationStrict 'Application installer repair should require the selected domain identity.'
    Assert-True ($script:ApplicationDestinations[0] -eq 'C:\Apps\7-Zip\.7z.msi.memlabs-pending') `
        'Installer copies must stage under the durable application directory, not the tools folder or live source filename.'
    foreach ($copyMode in 'interrupted', 'partial') {
        $script:GuestState.Application = $false
        $script:ApplicationCopies = 0
        $script:ApplicationCopyMode = $copyMode
        $repairDiagnostics = @{}
        $incompleteApplication = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
            -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
        Assert-True (-not $incompleteApplication -and $repairDiagnostics.Retryable) `
            "An $copyMode application copy must fail with retryable state."
        $script:ApplicationCopyMode = 'normal'
        $retriedApplication = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
            -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
        Assert-True ($retriedApplication -and $script:ApplicationCopies -eq 2) `
            'An incomplete installer must be copied and verified again on retry.'
    }
    Remove-Item -LiteralPath (Join-Path $tempRoot 'tools\7z.msi') -Force
    $repairDiagnostics = @{}
    $missingHostApplication = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
    Assert-True (-not $missingHostApplication -and -not $repairDiagnostics.Retryable) `
        'A missing host installer must fail permanently instead of claiming preflight success.'
    $script:SitePresent = $true
    $script:Warnings.Clear()
    $retainedMissingSource = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
    Assert-True ($retainedMissingSource -and $repairDiagnostics.RetainedSite -and $script:Warnings.Count -gt 0) `
        'An unavailable optional host installer on a verified retained site must warn without blocking core preparation.'
    Set-Content -LiteralPath (Join-Path $tempRoot 'tools\7z.msi') -Value 'expected-msi' -Encoding ASCII
    $script:GuestState.Application = $false
    $script:ApplicationCopyMode = 'interrupted'
    $retainedCopyFailure = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
    Assert-True $retainedCopyFailure 'An optional installer transfer failure on a retained site should not abort required setup.'
    $script:ApplicationCopyMode = 'normal'
    $script:SitePresent = $false

    $script:GuestState = @{ Baselines = $false; W11 = $false; W10 = $true; Application = $true }
    $script:Mounted.Clear()
    $script:Dismounted.Clear()
    $script:CopiedOs.Clear()
    $script:BaselineCopies = 0
    $script:BaselineStrict = $false
    $repaired = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity
    Assert-True $repaired 'Missing inherited payload should be repaired.'
    Assert-True ($script:BaselineCopies -eq 1) 'Missing baselines.zip should be copied once.'
    Assert-True $script:BaselineStrict 'Phase 8 baselines.zip copy should require domain identity.'
    Assert-True ($script:CopiedOs.Count -eq 1 -and $script:CopiedOs[0] -eq 'Windows 11 24h2') 'Only the missing OS media should be copied.'
    Assert-True ($script:Mounted.Count -eq 1 -and $script:Dismounted -contains $script:Mounted[0]) 'Repair ISO should be mounted and ejected.'
    Assert-True ($script:StrictCalls -gt 0) 'Phase 8 repair should require the domain identity.'

    $script:GuestState = @{ Baselines = $false; W11 = $true; W10 = $true; Application = $true }
    $script:BaselineCopyFailures = 1
    $script:BaselineCopies = 0
    $repairDiagnostics = @{}
    $interruptedBaseline = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
    Assert-True (-not $interruptedBaseline -and $repairDiagnostics.Retryable -and $script:BaselinePending) 'An interrupted baseline copy lost its retryable incomplete state.'
    $retriedBaseline = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
    Assert-True ($retriedBaseline -and $script:BaselineCopies -eq 2 -and -not $script:BaselinePending) 'A partial baseline was accepted without copying and verifying it again.'

    $script:GuestState = @{ Baselines = $true; W11 = $true; W10 = $false; Application = $true }
    Remove-Item -LiteralPath (Join-Path $tempRoot 'w10.iso') -Force
    $repairDiagnostics = @{}
    $script:SitePresent = $true
    $missingHostMedia = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
        -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -RequireDomainIdentity -Diagnostics $repairDiagnostics
    Assert-True (-not $missingHostMedia -and $repairDiagnostics.Retryable -eq $false) 'Missing host ISO should fail permanently.'
    $script:SitePresent = $false
    foreach ($probeMode in 'transient', 'malformed', 'ambiguous') {
        $script:ProbeMode = $probeMode
        $repairDiagnostics = @{}
        $probeResult = Repair-PrimaryPrepopulationPayload -VirtualMachine $vm -VmDomainName 'example.test' `
            -AzureFileList $fileList -AzureFilesPath $tempRoot -Phase 8 -Diagnostics $repairDiagnostics
        Assert-True (-not $probeResult -and $repairDiagnostics.Retryable -is [bool] -and
            $repairDiagnostics.Retryable -eq ($probeMode -eq 'transient')) 'Probe failure classification allowed malformed state or rejected transient transport recovery.'
    }
    $script:ProbeMode = 'normal'

    & {
        $copyAssignment = $repairDefinition.Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$copyResult'
            }, $true)
        $copyArgument = $copyAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        $copyMedia = $copyArgument.ScriptBlock.GetScriptBlock()
        $probeAssignment = $repairDefinition.Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$probeScript'
            }, $true)
        $probeArgument = $probeAssignment.Right.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)
        $probeMedia = $probeArgument.ScriptBlock.GetScriptBlock()
        $mediaRoot = Join-Path $tempRoot 'media'
        $guestRoot = Join-Path $tempRoot 'guest-osd'
        $guestApplicationPath = Join-Path $tempRoot 'guest-7z.msi'
        $script:ApplicationProbeFailure = ''
        $script:ProbeRetainedSite = $false
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $tempRoot 'tools\7z.msi') -Destination $guestApplicationPath
        $applicationPayloads = @([pscustomobject]@{
                DirectoryName = '7-Zip'
                FileName = '7z.msi'
                Sha256 = (Get-FileHash -LiteralPath $guestApplicationPath -Algorithm SHA256).Hash
            })
        $null = New-Item -ItemType Directory -Path (Join-Path $mediaRoot 'sources') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Windows 10 22h2\sources') -Force
        Set-Content -LiteralPath (Join-Path $mediaRoot 'sources\install.wim') -Value 'complete-media-content' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $guestRoot 'Windows 10 22h2\sources\install.wim') -Value 'complete' -Encoding ASCII
        $script:MediaDrive = 'Phase8Media' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $null = New-PSDrive -Name $script:MediaDrive -PSProvider FileSystem -Root $mediaRoot
        function Get-Volume {
            [CmdletBinding()]
            param()
            [pscustomobject]@{ DriveType = 'CD-ROM'; DriveLetter = $script:MediaDrive }
        }
        function Test-Path {
            [CmdletBinding()]
            param($LiteralPath, $PathType = 'Any')
            if ($LiteralPath -eq 'C:\tools\baselines.zip') { return $true }
            if ($LiteralPath -eq 'C:\tools\.memlabs-baselines.pending') { return $false }
            if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\SMS\Identification') { return $script:ProbeRetainedSite }
            if ($LiteralPath -eq 'C:\Apps\7-Zip\7z.msi') {
                if ($script:ApplicationProbeFailure -eq 'path') { throw [IO.IOException]::new('Synthetic optional MSI path error.') }
                $LiteralPath = $guestApplicationPath
            }
            Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
        }
        function Get-FileHash {
            [CmdletBinding()]
            param($LiteralPath, $Algorithm)
            if ($LiteralPath -eq 'C:\Apps\7-Zip\7z.msi') {
                if ($script:ApplicationProbeFailure -eq 'hash') { throw [IO.IOException]::new('Synthetic optional MSI hash error.') }
                $LiteralPath = $guestApplicationPath
            }
            Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm -ErrorAction Stop
        }
        function Get-Item {
            [CmdletBinding()]
            param($LiteralPath)
            if ($LiteralPath -eq 'C:\Apps\7-Zip\7z.msi') {
                if ($script:ApplicationProbeFailure -eq 'metadata') { throw [IO.IOException]::new('Synthetic optional MSI metadata error.') }
                $LiteralPath = $guestApplicationPath
            }
            Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
        }
        function Get-ItemPropertyValue {
            [CmdletBinding()]
            param($LiteralPath, $Name)
            if ($script:ApplicationProbeFailure -eq 'registry') { throw 'Synthetic unreadable site identification.' }
            if ($script:ApplicationProbeFailure -eq 'registry-empty') { return '' }
            return 'PS1'
        }
        function Copy-Item {
            param($Path, $Destination, [switch]$Recurse, [switch]$Force, [switch]$Confirm, $ErrorAction)
            if ($script:MediaCopyMode -eq 'interrupt') {
                $null = New-Item -Path (Join-Path $Destination 'sources') -ItemType Directory -Force
                Set-Content -LiteralPath (Join-Path $Destination 'sources\install.wim') -Value 'partial' -Encoding ASCII
                throw [IO.IOException]::new('Synthetic interrupted media copy.')
            }
            Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Recurse -Force -Confirm:$false -ErrorAction Stop
            if ($script:MediaCopyMode -eq 'truncate') {
                Set-Content -LiteralPath (Join-Path $Destination 'sources\install.wim') -Value 'short' -Encoding ASCII
            }
        }
        try {
            $destination = Join-Path $guestRoot 'Windows 11 24h2'
            foreach ($mode in 'interrupt', 'truncate') {
                $script:MediaCopyMode = $mode
                $failed = $false
                try { $null = & $copyMedia $destination } catch { $failed = $true }
                $stateAfterFailure = & $probeMedia $guestRoot $applicationPayloads
                Assert-True ($failed -and
                    (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $destination 'sources\install.wim') -PathType Leaf) -and
                    (Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $destination '.memlabs-copy.pending') -PathType Leaf) -and
                    $stateAfterFailure.MissingOs -contains 'Windows 11 24h2') 'A partial install.wim was accepted as completed media.'
            }
            $script:MediaCopyMode = 'success'
            $null = & $copyMedia $destination
            $stateAfterRetry = & $probeMedia $guestRoot $applicationPayloads
            Assert-True ($stateAfterRetry.MissingOs.Count -eq 0) 'A verified retry did not clear the incomplete-copy marker.'
            Set-Content -LiteralPath $guestApplicationPath -Value 'modified-msi' -Encoding ASCII
            $corruptApplication = & $probeMedia $guestRoot $applicationPayloads
            Assert-True ((Get-Item -LiteralPath $guestApplicationPath).Length -eq
                (Get-Item -LiteralPath (Join-Path $tempRoot 'tools\7z.msi')).Length -and
                $corruptApplication.MissingApplications -contains '7-Zip\7z.msi') `
                'The guest probe must reject a same-length installer whose SHA-256 differs.'
            Remove-Item -LiteralPath $guestApplicationPath -Force
            $missingApplication = & $probeMedia $guestRoot $applicationPayloads
            Assert-True ($missingApplication.MissingApplications.Count -eq 1 -and
                $missingApplication.MissingApplications -contains '7-Zip\7z.msi') 'The guest probe must report an absent configured installer.'
            $noApplications = & $probeMedia $guestRoot @()
            Assert-True ($noApplications.MissingApplications.Count -eq 0) 'An empty application list must not require installers.'
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $tempRoot 'tools\7z.msi') -Destination $guestApplicationPath -Force
            $currentApplication = & $probeMedia $guestRoot $applicationPayloads
            Assert-True ($currentApplication.MissingApplications.Count -eq 0) 'The guest probe rejected a verified current installer.'
            $sharedFilePayloads = @($applicationPayloads[0], [pscustomobject]@{
                    DirectoryName = 'OtherDemoApp'; FileName = '7z.msi'; Sha256 = $applicationPayloads[0].Sha256
                })
            foreach ($orderedPayloads in @(@($sharedFilePayloads), @($sharedFilePayloads[1], $sharedFilePayloads[0]))) {
                $sharedFileState = & $probeMedia $guestRoot $orderedPayloads
                Assert-True ($sharedFileState.MissingApplications.Count -eq 1 -and
                    $sharedFileState.MissingApplications -contains 'OtherDemoApp\7z.msi') `
                    'The guest protocol must retain directory identity when MSI filenames are shared.'
            }
            $verificationAssignment = $repairDefinition.Ast.Find({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$applicationVerified'
                }, $true)
            $verificationArgument = $verificationAssignment.Right.Find({
                    param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
                }, $true)
            $publishApplication = $verificationArgument.ScriptBlock.GetScriptBlock()
            $toolPath = Join-Path $tempRoot 'legacy-tool.msi'
            $publishedPath = Join-Path $tempRoot 'published-source.msi'
            $pendingPath = Join-Path $tempRoot '.pending-source.msi'
            Set-Content -LiteralPath $toolPath -Value 'previous-source' -Encoding ASCII
            $null = New-Item -ItemType HardLink -Path $publishedPath -Value $toolPath
            Set-Content -LiteralPath $pendingPath -Value 'corrupt-copy' -Encoding ASCII
            $publicationFailed = $false
            try { $null = & $publishApplication $pendingPath $publishedPath $applicationPayloads[0].Sha256 }
            catch { $publicationFailed = $true }
            Assert-True ($publicationFailed -and (Get-Content -LiteralPath $publishedPath -Raw).Trim() -eq 'previous-source') `
                'A failed source verification overwrote the previous application source.'
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $guestApplicationPath -Destination $pendingPath -Force
            $null = & $publishApplication $pendingPath $publishedPath $applicationPayloads[0].Sha256
            Assert-True ((Get-Content -LiteralPath $toolPath -Raw).Trim() -eq 'previous-source') `
                'Publishing an independent source changed a legacy hardlinked tool.'
            Remove-Item -LiteralPath $toolPath -Force
            Assert-True ((Get-FileHash -LiteralPath $publishedPath -Algorithm SHA256).Hash -eq $applicationPayloads[0].Sha256) `
                'Removing the old tool must not invalidate the durable ConfigMgr source.'
            $probeToolPath = Join-Path $tempRoot 'probe-tool.msi'
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $guestApplicationPath -Destination $probeToolPath
            Remove-Item -LiteralPath $guestApplicationPath -Force
            $null = New-Item -ItemType HardLink -Path $guestApplicationPath -Value $probeToolPath
            $legacyLink = & $probeMedia $guestRoot $applicationPayloads
            Assert-True ($legacyLink.MissingApplications -contains '7-Zip\7z.msi') 'A hash-current legacy hardlink must still be migrated to an independent application source.'

            function Invoke-VmCommand {
                param($VmName, $VmDomainName, [switch]$RequireDomainIdentity, [switch]$AsJob, $TimeoutSeconds, $DisplayName, $ScriptBlock, $ArgumentList)
                if ($DisplayName -in @('Inspect Primary prepopulation payload', 'Verify Primary prepopulation payload')) {
                    try {
                        $snapshot = & $ScriptBlock $guestRoot $ArgumentList[1]
                        return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = @($snapshot); ErrorDetails = @() }
                    }
                    catch {
                        return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @("$($_.Exception.Message)") }
                    }
                }
                return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @('Synthetic unavailable optional source directory') }
            }
            $probeVm = [pscustomobject]@{ vmName = 'PROBE-PRI'; role = 'Primary'; cmInstallDir = 'C:\ConfigMgr' }
            foreach ($retained in @($false, $true)) {
                $script:ProbeRetainedSite = $retained
                foreach ($inspection in 'path', 'hash', 'metadata') {
                    $script:ApplicationProbeFailure = $inspection
                    $inspectionState = & $probeMedia $guestRoot $applicationPayloads
                    Assert-True ($inspectionState.ApplicationReadErrors.Count -eq 1 -and $inspectionState.MissingApplications -contains '7-Zip\7z.msi') `
                        "Optional $inspection errors must be explicit unavailable-source state, not failed site identification."
                    $inspectionResult = Repair-PrimaryPrepopulationPayload -VirtualMachine $probeVm -VmDomainName 'example.test' `
                        -AzureFileList $fileList -AzureFilesPath $tempRoot -Diagnostics @{}
                    Assert-True ($inspectionResult -eq $retained) "Optional $inspection failures must warn only on verified retained sites."
                }
            }
            foreach ($registryFailure in 'registry', 'registry-empty') {
                $script:ApplicationProbeFailure = $registryFailure
                $registryResult = Repair-PrimaryPrepopulationPayload -VirtualMachine $probeVm -VmDomainName 'example.test' `
                    -AzureFileList $fileList -AzureFilesPath $tempRoot -Diagnostics @{}
                Assert-True (-not $registryResult) 'An unreadable or empty site identity must never enable warning-only mode.'
            }
        }
        finally {
            Remove-PSDrive -Name $script:MediaDrive -Force -ErrorAction Stop
        }
    }

    & {
        $identityRoot = Join-Path $tempRoot 'shared-msi'
        $identityCache = Join-Path $identityRoot 'cache'
        $identityApps = Join-Path $identityRoot 'Apps'
        $identityOsd = Join-Path $identityRoot 'OSD'
        $null = New-Item -ItemType Directory -Path (Join-Path $identityCache 'tools') -Force
        foreach ($os in 'Windows 11 24h2', 'Windows 10 22h2') {
            $null = New-Item -ItemType Directory -Path (Join-Path $identityOsd "$os\sources") -Force
            Set-Content -LiteralPath (Join-Path $identityOsd "$os\sources\install.wim") -Value 'complete' -Encoding ASCII
        }
        $sharedMsi = Join-Path $identityCache 'tools\shared.msi'
        Set-Content -LiteralPath $sharedMsi -Value 'shared-installer-bytes' -Encoding ASCII
        $expectedHash = (Get-FileHash -LiteralPath $sharedMsi -Algorithm SHA256).Hash
        $identityCopies = [Collections.Generic.List[string]]::new()
        $identityRetained = $false
        function Test-Path {
            [CmdletBinding()]
            param($LiteralPath, $PathType = 'Any')
            if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\SMS\Identification') { return $identityRetained }
            if ($LiteralPath -eq 'C:\tools\baselines.zip') { return $true }
            if ($LiteralPath -eq 'C:\tools\.memlabs-baselines.pending') { return $false }
            Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
        }
        function Get-ItemPropertyValue {
            [CmdletBinding()]
            param($LiteralPath, $Name)
            return 'PS1'
        }
        function Invoke-VmCommand {
            param($VmName, $VmDomainName, [switch]$RequireDomainIdentity, [switch]$AsJob, $TimeoutSeconds, $DisplayName, $ScriptBlock, $ArgumentList)
            $mappedArguments = @($ArgumentList)
            for ($index = 0; $index -lt $mappedArguments.Count; $index++) {
                if ($mappedArguments[$index] -is [string] -and $mappedArguments[$index].StartsWith('C:\Apps\')) {
                    $mappedArguments[$index] = $mappedArguments[$index].Replace('C:\Apps\', "$identityApps\")
                }
            }
            if ($DisplayName -in @('Inspect Primary prepopulation payload', 'Verify Primary prepopulation payload')) {
                $mappedArguments[0] = $identityOsd
            }
            $translated = [scriptblock]::Create($ScriptBlock.ToString().Replace('C:\Apps\', "$identityApps\"))
            try {
                $output = @(& $translated @mappedArguments)
                return [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $output; ErrorDetails = @() }
            }
            catch {
                return [pscustomobject]@{ ScriptBlockFailed = $true; ScriptBlockOutput = @(); ErrorDetails = @("$($_.Exception.Message)") }
            }
        }
        function Copy-ItemSafe {
            param($VmName, $VmDomainName, $Path, $Destination, [switch]$Force, [switch]$RequireDomainIdentity)
            $mapped = $Destination.Replace('C:\Apps\', "$identityApps\")
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $Path -Destination $mapped -Force -ErrorAction Stop
            $identityCopies.Add($mapped)
            return $true
        }
        $identityVm = [pscustomobject]@{ vmName = 'IDENTITY-PRI'; role = 'Primary'; cmInstallDir = 'C:\ConfigMgr' }
        foreach ($identityRetained in @($false, $true)) {
            foreach ($names in @(@('AppA', 'AppB'), @('AppB', 'AppA'))) {
                $identityCatalog = [pscustomobject]@{
                    Tools = @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Appinstall = $true; AppMsi = 'shared.msi' } })
                    OSISO = @()
                }
                foreach ($missingNames in @(@('AppA', 'AppB'), @('AppA'), @('AppB'))) {
                    foreach ($name in @('AppA', 'AppB')) {
                        $directory = Join-Path $identityApps $name
                        $null = New-Item -ItemType Directory -Path $directory -Force
                        $path = Join-Path $directory 'shared.msi'
                        if ($name -in $missingNames) {
                            if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                        }
                        else { Microsoft.PowerShell.Management\Copy-Item -LiteralPath $sharedMsi -Destination $path -Force }
                    }
                    $identityCopies.Clear()
                    $ready = Repair-PrimaryPrepopulationPayload -VirtualMachine $identityVm -VmDomainName 'example.test' `
                        -AzureFileList $identityCatalog -AzureFilesPath $identityCache -Diagnostics @{}
                    Assert-True ($ready -and $identityCopies.Count -eq $missingNames.Count) 'Shared installer filenames must repair each independently missing tool directory exactly once.'
                    foreach ($name in @('AppA', 'AppB')) {
                        Assert-True ((Get-FileHash -LiteralPath (Join-Path $identityApps "$name\shared.msi") -Algorithm SHA256).Hash -eq $expectedHash) `
                            'Each application must retain the shared installer under its own durable source directory.'
                    }
                    $identityCopies.Clear()
                    $again = Repair-PrimaryPrepopulationPayload -VirtualMachine $identityVm -VmDomainName 'example.test' `
                        -AzureFileList $identityCatalog -AzureFilesPath $identityCache -Diagnostics @{}
                    Assert-True ($again -and $identityCopies.Count -eq 0) 'A repaired shared-filename catalog must be a no-op on its next preflight.'
                }
            }
        }
    }

    $source = Get-Content -LiteralPath $scriptBlocksPath -Raw
    Assert-True (($source | Select-String -Pattern 'Repair-PrimaryPrepopulationPayload' -AllMatches).Matches.Count -eq 1) `
        'VM creation should retain repair, but Phase 8 workers must not copy payloads after DC recovery starts.'
    Assert-True ($repairDefinition.ToString() -notmatch '-OutputStream') `
        'Prepopulation helper must not pollute its Boolean return with log output.'
    $failureSignals = @([regex]::Matches(
            $source,
            '(?s)if \(-not \$payloadReady\)\s*\{\s*Write-Log.+?-Failure -OutputStream\s*return'
        ))
    Assert-True ($failureSignals.Count -eq 1) `
        'VM creation must surface helper failure through its job output stream.'
    $diagnostics = (Get-Content -LiteralPath $perfloadingPath -Raw) + "`n" +
        (Get-Content -LiteralPath $validationPath -Raw)
    Assert-True ($diagnostics -notmatch 'rerun will NOT restore') `
        'OSD diagnostics should not claim Phase 8 reruns cannot repair inherited media.'
    Assert-True ($diagnostics -match 'Phase 8 host preflight') `
        'OSD diagnostics should direct operators to the Phase 8 host repair.'

    & {
        $phaseDefinition = Import-TestFunction -Path $phasesPath -Name 'Start-PhaseJobs'
        $preparationGates = @($phaseDefinition.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.TryStatementAst] -and
                    $node.Body.Extent.Text -match '\bRepair-PrimaryPrepopulationPayload\b' -and
                    $node.CatchClauses.Extent.Text -match 'PreflightFailed'
                }, $true))
        Assert-True ($preparationGates.Count -eq 1) 'Expected one Primary preparation preflight.'
        $dispatchCommands = @($phaseDefinition.Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')
                }, $true))
        Assert-True ($dispatchCommands.Count -gt 0 -and
            -not @($dispatchCommands | Where-Object { $_.Extent.StartOffset -lt $preparationGates[0].Extent.EndOffset }).Count) `
            'Primary preparation must finish before any Phase 8 worker can be dispatched.'
        $preparationGate = [scriptblock]::Create(
            $preparationGates[0].Extent.Text + "`n`$script:PreflightDispatches++; return `$null")
        function Wait-ForVM {
            param($VmName, $PathToVerify, $VmDomainName, $TimeoutMinutes)
            $script:PreflightConnections.Add([pscustomobject]@{ Name = $VmName; Domain = $VmDomainName })
            Assert-True ($TimeoutMinutes -eq 5) 'Preparation connectivity recovery lost its bounded wait.'
            $script:PreflightConnectable
        }
        function Repair-PrimaryPrepopulationPayload {
            param($VirtualMachine, $VmDomainName, $AzureFileList, $AzureFilesPath, $Phase, [switch]$RequireDomainIdentity, $Diagnostics)
            Assert-True ($script:PreflightDispatches -eq 0) 'DSC dispatch raced Primary preparation.'
            $script:PreparationSeconds += 11 * 60
            Assert-True ($script:PreflightDispatches -eq 0) 'A preparation exceeding ten minutes exposed a DC recovery worker.'
            Assert-True ($RequireDomainIdentity -and $Phase -eq 8) 'Phase 8 preparation lost its domain-identity requirement.'
            $Diagnostics.RetainedSite = $true
            $script:PreflightCopies.Add([pscustomobject]@{ Name = $VirtualMachine.vmName; Domain = $VmDomainName })
            $attemptsForVm = @($script:PreflightCopies | Where-Object { $_.Name -eq $VirtualMachine.vmName }).Count
            if ($VirtualMachine.vmName -eq $script:RetryTarget -and $attemptsForVm -le $script:TransientFailures) {
                $Diagnostics.Retryable = $true
                if ($script:PreparationMode -eq 'transient-throw') { throw [IO.IOException]::new('Synthetic interrupted copy.') }
                return $false
            }
            if ($script:PreparationMode -eq 'throw') { throw 'Synthetic payload copy failure.' }
            $script:PreparationMode -ne 'false'
        }
        function Start-Sleep { param($Seconds) }
        function Write-Log {
            param($Message, [switch]$Failure)
            if ($Failure) { $script:PreflightFailures.Add([string]$Message) }
        }
        $Phase = 8
        $Common = [pscustomobject]@{ AzureFileList = $fileList; AzureFilesPath = $tempRoot }
        $deployConfig = [pscustomobject]@{
            parameters = [pscustomobject]@{ DomainName = 'example.test' }
            cmOptions = [pscustomobject]@{ PrePopulateObjects = $true }
            virtualMachines = @(
                [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; hidden = $true; domain = 'child.example.test'; cmOptions = [pscustomobject]@{ PrePopulateObjects = $true } }
                [pscustomobject]@{ vmName = 'PRI2'; role = 'Primary'; cmOptions = [pscustomobject]@{ PrePopulateObjects = $false } }
                [pscustomobject]@{ vmName = 'PRI3'; role = 'Primary' }
                [pscustomobject]@{ vmName = 'OUTSIDE'; role = 'Primary' }
                [pscustomobject]@{ vmName = 'SQL1'; role = 'DomainMember' }
            )
        }
        $ConfigurationData = [pscustomobject]@{
            AllNodes = @(
                [pscustomobject]@{ NodeName = '*'; Role = '' }
                [pscustomobject]@{ NodeName = 'PRI1'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'PRI2'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'PRI3'; Role = 'Primary' }
                [pscustomobject]@{ NodeName = 'SQL1'; Role = 'SqlServer' }
            )
        }
        foreach ($case in @(
                @{ Mode = 'success'; Connected = $true; Expected = 'PRI1,PRI3'; Failed = $false },
                @{ Mode = 'false'; Connected = $true; Expected = 'PRI1'; Failed = $true },
                @{ Mode = 'throw'; Connected = $true; Expected = 'PRI1'; Failed = $true },
                @{ Mode = 'success'; Connected = $false; Expected = ''; Failed = $true },
                @{ Mode = 'success'; Connected = $true; Only = @('PRI3'); Expected = 'PRI3'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; Only = @('SQL1'); Expected = ''; Failed = $false },
                @{ Mode = 'success'; Connected = $true; RootDisabled = $true; Expected = 'PRI1'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; TransientFailures = 1; Expected = 'PRI1,PRI1,PRI3'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; TransientFailures = 2; Expected = 'PRI1,PRI1,PRI1,PRI3'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; TransientFailures = 3; Expected = 'PRI1,PRI1,PRI1'; Failed = $true },
                @{ Mode = 'transient-throw'; Connected = $true; TransientFailures = 2; Expected = 'PRI1,PRI1,PRI1,PRI3'; Failed = $false },
                @{ Mode = 'success'; Connected = $true; TransientFailures = 2; RetryTarget = 'PRI3'; Expected = 'PRI1,PRI3,PRI3,PRI3'; Failed = $false }
            )) {
            $script:PreflightDispatches = 0
            $script:PreparationSeconds = 0
            $script:PreparationMode = $case.Mode
            $script:TransientFailures = [int]$case.TransientFailures
            $script:RetryTarget = if ($case.RetryTarget) { $case.RetryTarget } else { 'PRI1' }
            $script:PreflightConnectable = $case.Connected
            $script:PreflightConnections = [Collections.Generic.List[object]]::new()
            $script:PreflightCopies = [Collections.Generic.List[object]]::new()
            $script:PreflightFailures = [Collections.Generic.List[string]]::new()
            $OnlyVMs = $case.Only
            $deployConfig.cmOptions.PrePopulateObjects = -not $case.RootDisabled
            $result = & $preparationGate
            Assert-True (($script:PreflightCopies.Name -join ',') -eq $case.Expected) 'Preparation ignored phase applicability, effective hierarchy options, or OnlyVMs.'
            if ($case.Failed) {
                Assert-True ($result.PreflightFailed -and $result.Failed -eq 1 -and $result.Jobs -eq 0 -and
                    $script:PreflightDispatches -eq 0 -and $script:PreflightFailures.Count -gt 0) `
                    'Failed preparation did not stop dispatch with an explicit phase failure.'
            }
            else {
                Assert-True ($null -eq $result -and $script:PreflightDispatches -eq 1) 'Successful preparation did not permit subsequent dispatch.'
            }
            foreach ($copy in $script:PreflightCopies) {
                $expectedDomain = if ($copy.Name -eq 'PRI1') { 'child.example.test' } else { 'example.test' }
                Assert-True ($copy.Domain -eq $expectedDomain) 'Preparation lost the Primary domain selection.'
                Assert-True ($script:PreparationSeconds -gt 10 * 60) 'The regression did not exercise a copy beyond the recovery threshold.'
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- inherited Primary prepopulation payloads are repaired and verified.'
