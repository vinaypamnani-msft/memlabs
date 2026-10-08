[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Message. Expected '$Expected', got '$Actual'." -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        Write-Host "FAIL: $Message." -ForegroundColor Red
        $script:Failures++
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        & $Operation
        Write-Host "FAIL: $Message. Expected an exception." -ForegroundColor Red
        $script:Failures++
    }
    catch {}
}

function Write-Log {
    param(
        [Parameter(Position = 0)]$Message,
        [switch]$Warning,
        [switch]$Success,
        [switch]$Failure,
        [switch]$LogOnly,
        [switch]$SubActivity
    )
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$baseImageFunctionsPath = Join-Path $repoRoot "common\Common.BaseImage.ps1"
$newBaseImagePath = Join-Path $repoRoot "baseimagestaging\New-BaseImage.ps1"
$customizeWindowsPath = Join-Path $repoRoot "baseimagestaging\filesToInject\staging\Customize-WindowsSettings.ps1"
$commonPath = Join-Path $repoRoot "Common.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("MemLabs.BaseImageTest." + [guid]::NewGuid().ToString("N"))

try {
    $azureFilesPath = Join-Path $testRoot "azureFiles"
    $answerFilePath = Join-Path $testRoot "unattend"
    New-Item -Path $azureFilesPath -ItemType Directory -Force | Out-Null
    New-Item -Path $answerFilePath -ItemType Directory -Force | Out-Null

    $global:Common = [pscustomobject]@{
        AzureFilesPath        = $azureFilesPath
        StagingAnswerFilePath = $answerFilePath
    }
    $global:StorageConfig = [pscustomobject]@{
        StorageLocation = "https://example.invalid/memlabs"
    }

    . $baseImageFunctionsPath

    $genericWin11Unattend = Join-Path $answerFilePath "WIN11-RTM.xml"
    Set-Content -LiteralPath $genericWin11Unattend -Value "<unattend />" -Encoding UTF8
    $resolved = Resolve-BaseImageUnattendFile -WimName "WIN11-26H2.wim"
    Assert-Equal -Expected $genericWin11Unattend -Actual $resolved -Message "A new Windows 11 release should use the generic Windows 11 unattend fallback"

    $exactWin11Unattend = Join-Path $answerFilePath "WIN11-26H2.xml"
    Set-Content -LiteralPath $exactWin11Unattend -Value "<unattend />" -Encoding UTF8
    $resolved = Resolve-BaseImageUnattendFile -WimName "WIN11-26H2.wim"
    Assert-Equal -Expected $exactWin11Unattend -Actual $resolved -Message "An exact Windows 11 unattend should take precedence"
    Assert-Throws -Operation { Resolve-BaseImageUnattendFile -WimName "WIN11-26H2.wim" -UnattendFileName "missing.xml" } -Message "An explicitly requested missing unattend must fail"

    $relativeIso = "iso\OS\windows11_26h2.iso"
    $whatIfPath = Get-BaseImageIsoFromStorage -FileName $relativeIso -WhatIf
    Assert-Equal -Expected (Join-Path $azureFilesPath $relativeIso) -Actual $whatIfPath -Message "WhatIf should resolve the local ISO cache path"
    Assert-Throws -Operation { Get-BaseImageIsoFromStorage -FileName "C:\outside.iso" -WhatIf } -Message "A rooted Azure file name must be rejected"
    Assert-Throws -Operation { Get-BaseImageIsoFromStorage -FileName "iso\..\outside.iso" -WhatIf } -Message "Azure file traversal must be rejected"
    Assert-Throws -Operation { Get-BaseImageIsoFromStorage -FileName "iso\OS\not-an-iso.zip" -WhatIf } -Message "A non-ISO Azure file must be rejected"

    $script:DownloadCall = $null
    $script:MockHash = ("A" * 32) -join ""
    function Get-FileWithHash {
        param(
            [string]$FileName,
            [string]$FileDisplayName,
            [string]$FileUrl,
            [string]$ExpectedHash,
            [string]$HashAlg,
            [switch]$ForceDownload,
            [switch]$UseCDN
        )

        $script:DownloadCall = [pscustomobject]@{
            FileName     = $FileName
            FileUrl      = $FileUrl
            ExpectedHash = $ExpectedHash
            HashAlg      = $HashAlg
        }
        $destination = Join-Path $global:Common.AzureFilesPath $FileName
        New-Item -Path (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $destination -Value "mock iso" -Encoding ASCII
        return [pscustomobject]@{ success = $true; download = $true }
    }
    function Get-FileHash {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$LiteralPath,
            [Parameter(Mandatory = $true)][string]$Algorithm
        )
        return [pscustomobject]@{ Hash = $script:MockHash }
    }

    $downloadedPath = Get-BaseImageIsoFromStorage -FileName $relativeIso -ExpectedHash "NONE" -HashAlgorithm MD5
    Assert-True -Condition (Test-Path $downloadedPath -PathType Leaf) -Message "The storage helper should return a downloaded ISO"
    Assert-Equal -Expected "https://example.invalid/memlabs/iso/OS/windows11_26h2.iso" -Actual $script:DownloadCall.FileUrl -Message "The storage URL should use forward slashes"
    Assert-Equal -Expected "NONE" -Actual $script:DownloadCall.ExpectedHash -Message "A new blob should bootstrap without an independent hash"
    $hashMarkerPath = "$downloadedPath.MD5"
    Assert-Equal -Expected $script:MockHash -Actual "$(Get-Content -LiteralPath $hashMarkerPath | Select-Object -First 1)".Trim() -Message "The bootstrapped hash should be persisted"

    $null = Get-BaseImageIsoFromStorage -FileName $relativeIso -ExpectedHash "NONE" -HashAlgorithm MD5
    Assert-Equal -Expected $script:MockHash -Actual $script:DownloadCall.ExpectedHash -Message "A later run should verify against the cached hash"

    $script:DismountCalled = $false
    function Get-DiskImage {
        param([string]$ImagePath)
        return [pscustomobject]@{ ImagePath = $ImagePath; Attached = $true }
    }
    function Dismount-DiskImage {
        param([object]$InputObject)
        $script:DismountCalled = $true
        return $InputObject
    }
    $dismountOutput = @(Invoke-RemoveISOMount -InputObject ([pscustomobject]@{ ImagePath = "C:\mock.iso"; Attached = $true }))
    Assert-True -Condition $script:DismountCalled -Message "ISO cleanup should dismount an attached image"
    Assert-Equal -Expected 0 -Actual $dismountOutput.Count -Message "ISO cleanup should not pollute its caller's success output"

    foreach ($path in @($baseImageFunctionsPath, $newBaseImagePath, $customizeWindowsPath, $commonPath)) {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal -Expected 0 -Actual @($parseErrors).Count -Message "$path should parse"
    }

    $newBaseImageText = Get-Content -LiteralPath $newBaseImagePath -Raw
    Assert-True -Condition ($newBaseImageText -match '-DisableAutomaticCheckpoints') -Message "The staging VM should disable automatic checkpoints before first boot"
    Assert-True -Condition ($newBaseImageText -match '-tpmEnabled:\$enableTpm') -Message "Windows 11 staging should request a virtual TPM"
    Assert-True -Condition ($newBaseImageText -match 'Get-VMSnapshot') -Message "Capture should reject differencing-disk checkpoints"
    Assert-True -Condition ($newBaseImageText -match 'Get-FileHash.+-Algorithm MD5') -Message "Golden-image publication should calculate an MD5 marker"
    Assert-True -Condition ($newBaseImageText -match '\$newGoldMoved') -Message "Golden-image rollback should distinguish the old image from a newly published image"
    Assert-True -Condition ($newBaseImageText -match '-NoForceStateOnTimeout') -Message "Sysprep waits must not force-stop a timed-out VM"
    Assert-True -Condition ($newBaseImageText -match 'Test-BaseImageSysprepComplete') -Message "Golden-image capture should require offline Sysprep verification"
    Assert-True -Condition ($newBaseImageText -match 'sysprep\.exe /audit /shutdown') -Message "The Audit-mode transition should stop before its controlled host restart"
    Assert-True -Condition ($newBaseImageText -match '(?s)Customize-WindowsSettings\.ps1.+Start-Process -FilePath \$powerShellPath') -Message "The host should launch customization explicitly through PowerShell Direct"
    Assert-True -Condition ($newBaseImageText -match '\[switch\]\$ResumeAuditVm') -Message "The staging command should support resuming a retained Audit-mode diagnostic VM"
    Assert-True -Condition ($newBaseImageText -match 'Skipping OOBE and Audit-mode transition for resumed VM') -Message "Audit-mode resume should not boot the generalized path through OOBE again"
    Assert-True -Condition ($newBaseImageText -match '\[switch\]\$CaptureSyspreppedVm') -Message "The staging command should support verified capture of a retained stopped VM"
    Assert-True -Condition ($newBaseImageText -match 'Skipping customization because CaptureSyspreppedVm') -Message "Sysprepped capture should not boot or customize the generalized VM again"

    $commonText = Get-Content -LiteralPath $commonPath -Raw
    Assert-True -Condition ($commonText -match '\[switch\]\$DisableAutomaticCheckpoints') -Message "New-VirtualMachine should expose checkpoint suppression"
    Assert-True -Condition ($commonText -match 'AutomaticCheckpointsEnabled \$false') -Message "New-VirtualMachine should disable checkpoints before starting the VM"
    Assert-True -Condition ($commonText -match 'Get-VM2 -Name \$VmName -Fallback -ErrorAction SilentlyContinue') -Message "PowerShell Direct should resolve fresh staging VMs outside the deployment cache"
    Assert-True -Condition ($commonText -match '\[switch\]\$NoForceStateOnTimeout') -Message "Wait-ForVm should expose a no-force timeout mode"
    Assert-True -Condition ($commonText -match '-not \$NoForceStateOnTimeout\.IsPresent') -Message "Wait-ForVm should honor no-force timeout mode"
    $waitForVmStart = $commonText.IndexOf("function Wait-ForVm")
    $waitForVmEnd = $commonText.IndexOf("function Get-VmHostSideDiag", $waitForVmStart)
    $waitForVmText = $commonText.Substring($waitForVmStart, $waitForVmEnd - $waitForVmStart)
    Assert-True -Condition ($waitForVmText -notmatch 'Get-VM2 -Name \$VmName -ErrorAction') -Message "Every Wait-ForVm lookup should support fresh uncached VMs"

    $baseImageFunctionsText = Get-Content -LiteralPath $baseImageFunctionsPath -Raw
    Assert-True -Condition ($baseImageFunctionsText -notmatch 'Mount-DiskImage.+-NoDriveLetter') -Message "ISO import should mount an accessible volume"
    Assert-True -Condition ($baseImageFunctionsText -notmatch '-ProgressAction') -Message "Base-image helpers should remain compatible with PowerShell 5.1"
    Assert-True -Condition ($baseImageFunctionsText -match 'Add-PartitionAccessPath.+Out-Null') -Message "Partition access-path helpers should not pollute Boolean results"
    Assert-True -Condition ($baseImageFunctionsText -match 'Sysprep_succeeded\.tag') -Message "Offline verification should require the Windows Sysprep success tag"
    Assert-True -Condition ($baseImageFunctionsText -match 'SysprepComplete\.txt') -Message "Offline verification should require the MemLabs completion marker"
    Assert-True -Condition ($baseImageFunctionsText -match "command line option 'QUIT'") -Message "Offline verification should validate the final deterministic Sysprep mode"
    Assert-True -Condition ($baseImageFunctionsText -match 'staging\\Unattend\.xml') -Message "VHD creation should stage a dedicated final-Sysprep answer file"
    Assert-True -Condition ($baseImageFunctionsText -match '\$result\.Warnings = @\(\$terminalErrors\)') -Message "Non-fatal provider errors should remain visible without overriding Windows' Sysprep success tag"
    Assert-True -Condition ($baseImageFunctionsText -notmatch 'throw "Final Sysprep run contains error records') -Message "Provider errors should not override authoritative Sysprep completion evidence"

    $customizeWindowsText = Get-Content -LiteralPath $customizeWindowsPath -Raw
    Assert-True -Condition ($customizeWindowsText -match '/generalize /oobe /quit') -Message "Guest customization should wait for Sysprep before shutting down"
    Assert-True -Condition ($customizeWindowsText -match 'Sysprep_succeeded\.tag') -Message "Guest customization should verify Sysprep's success tag"
    Assert-True -Condition ($customizeWindowsText -match 'SysprepFailed\.txt') -Message "Guest customization should persist a Sysprep failure marker"
    Assert-True -Condition ($customizeWindowsText -match 'SysprepComplete\.txt') -Message "Guest customization should persist a Sysprep completion marker"
    Assert-True -Condition ($customizeWindowsText -match 'Stop-Computer -Force') -Message "The guest should shut down only after Sysprep succeeds"
    Assert-True -Condition ($customizeWindowsText -match 'Global\\MemLabsBaseImageCustomization') -Message "Guest customization should prevent duplicate audit-mode launches"
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -gt 0) {
    throw "$($script:Failures) base-image staging test(s) failed."
}

Write-Host "Base-image staging tests passed." -ForegroundColor Green
