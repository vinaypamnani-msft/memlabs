[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:Failures = 0
$script:CaptureFailures = [Collections.Generic.List[string]]::new()

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
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Pattern
    )

    try {
        & $Operation
        Write-Host "FAIL: $Message. Expected an exception." -ForegroundColor Red
        $script:Failures++
    }
    catch {
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            Write-Host "FAIL: $Message. Unexpected exception: $($_.Exception.Message)" -ForegroundColor Red
            $script:Failures++
        }
    }
}

function Write-Log {
    param(
        [Parameter(Position = 0)]$Message,
        [switch]$Warning,
        [switch]$Success,
        [switch]$Failure,
        [switch]$LogOnly,
        [switch]$SubActivity,
        [switch]$Activity
    )
    if ($Failure) { $script:CaptureFailures.Add("$Message") }
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
    Assert-True -Condition ($newBaseImageText -match 'FirstBootQualification' -and
        $newBaseImageText.IndexOf('FirstBootQualification') -lt $newBaseImageText.IndexOf('$partialGoldImagePath =')) `
        -Message "Windows client capture must qualify a disposable first boot before creating/promoting the golden-image copy"
    Assert-True -Condition ($newBaseImageText -match 'qualification\.json' -and $newBaseImageText -match 'qualifiedHash') `
        -Message "Qualified image bytes should have a SHA-256 receipt tied to the diagnostic evidence"
    Assert-True -Condition ($newBaseImageText -match '\$sysprepValidation\.InstallationType -eq ''Client''' -and
        $newBaseImageText -notmatch 'if \(\$WimFileName -match ''\^WIN\(10\|11\)-''\)') `
        -Message "The installed OS type, not the WIM filename, must control client qualification"
    Assert-True -Condition ($newBaseImageText -match '\[string\]\$OutputDirectory' -and $newBaseImageText -match '\[switch\]\$SkipHostPreparation') `
        -Message "An isolated candidate build must not require overwriting the published cache or running unrelated host preparation"
    Assert-True -Condition ($newBaseImageText -match 'sysprep\.exe /audit /shutdown') -Message "The Audit-mode transition should stop before its controlled host restart"
    Assert-True -Condition ($newBaseImageText -match '(?s)Customize-WindowsSettings\.ps1.+Start-Process -FilePath \$powerShellPath') -Message "The host should launch customization explicitly through PowerShell Direct"
    Assert-True -Condition ($newBaseImageText -match '\[switch\]\$ResumeAuditVm') -Message "The staging command should support resuming a retained Audit-mode diagnostic VM"
    Assert-True -Condition ($newBaseImageText -match 'Skipping OOBE and Audit-mode transition for resumed VM') -Message "Audit-mode resume should not boot the generalized path through OOBE again"
    Assert-True -Condition ($newBaseImageText -match '\[switch\]\$CaptureSyspreppedVm') -Message "The staging command should support verified capture of a retained stopped VM"
    Assert-True -Condition ($newBaseImageText -notmatch 'Start-VM2 -Name \$vmName(?! -Passthru)') `
        -Message "Every staging startup used as a boolean must request the wrapper's explicit success return"
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

    Remove-Item -LiteralPath Function:\Get-FileHash
    & {
        $mountPath = Join-Path $testRoot 'synthetic-mount.vhdx'
        [IO.File]::WriteAllText($mountPath, 'SYNTHETIC-DISK')
        function Test-Path {
            param($LiteralPath, $PathType)
            if ($LiteralPath -eq $mountPath) { return [IO.File]::Exists($mountPath) }
            if ($LiteralPath -eq 'C:\Windows\System32\Sysprep') { return $true }
            throw "Unexpected offline test path '$LiteralPath'."
        }
        $script:MountAttached = $false; $script:MountMismatch = $false
        $script:MountDismountFails = $false; $script:MountRemoveFails = $false
        $script:MountAssigned = $false; $script:MountDismounts = 0; $script:MountRemovals = 0
        function Get-VHD { param($Path, $ErrorAction); [pscustomobject]@{ Attached = $script:MountAttached } }
        function Mount-DiskImage {
            param($ImagePath, $Access, [switch]$PassThru, $ErrorAction)
            Assert-Equal -Expected $mountPath -Actual $ImagePath -Message "Mounting must target only the selected image"
            Assert-True -Condition ([bool]$PassThru) -Message "The mount must return its owned identity"
            $script:MountAccess = $Access; $script:MountAssigned = $false
            [pscustomobject]@{ Owned = $true }
        }
        function Start-Sleep { param($Seconds); Assert-Equal -Expected 2 -Actual $Seconds -Message "Offline mount initialization delay should remain bounded" }
        function Get-Disk {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject)
            process {
                Assert-True -Condition ([bool]$InputObject.Owned) -Message "Disk discovery must use the returned mount identity"
                [pscustomobject]@{ Number = 42; IsReadOnly = ($script:MountAccess -eq 'ReadOnly' -and -not $script:MountMismatch) }
            }
        }
        function Get-Partition {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, $DiskNumber, $PartitionNumber)
            process {
                if ($InputObject) { Assert-Equal -Expected 42 -Actual $InputObject.Number -Message "Partition discovery must remain on the owned disk" }
                else { Assert-Equal -Expected 42 -Actual $DiskNumber -Message "Access-path refresh must remain on the owned disk" }
                [pscustomobject]@{ Size = 40GB; PartitionNumber = 3; DriveLetter = $(if ($script:MountAssigned) { 'C' } else { $null }) }
            }
        }
        function Add-PartitionAccessPath {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [switch]$AssignDriveLetter)
            process { $script:MountAssigned = $true }
        }
        function Remove-PartitionAccessPath {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, $AccessPath)
            process {
                Assert-Equal -Expected 'C:\' -Actual $AccessPath -Message "Only the owned assigned path may be removed"
                $script:MountRemovals++
                if ($script:MountRemoveFails) { throw 'Synthetic access-path removal failure' }
            }
        }
        function Dismount-DiskImage {
            param($ImagePath, $ErrorAction)
            Assert-Equal -Expected $mountPath -Actual $ImagePath -Message "Only the owned image may be dismounted"
            $script:MountDismounts++
            if ($script:MountDismountFails) { throw 'Synthetic dismount failure' }
        }
        foreach ($write in @($false, $true)) {
            $mounted = @(Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ReadWrite:$write -ScriptBlock { param($WindowsRoot); [pscustomobject]@{ Root = $WindowsRoot } })
            Assert-True -Condition ($mounted.Count -eq 1 -and $mounted[0].Root -eq 'C:\' -and
                $script:MountAccess -eq $(if ($write) { 'ReadWrite' } else { 'ReadOnly' })) -Message "Offline callbacks must use only the requested access mode and one result"
        }
        $script:MountAttached = $true
        Assert-Throws -Operation { Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ScriptBlock { throw 'Unexpected callback' } } `
            -Message "A pre-existing mount must not be borrowed" -Pattern 'already attached'
        $script:MountAttached = $false; $script:MountMismatch = $true
        Assert-Throws -Operation { Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ScriptBlock { throw 'Unexpected callback' } } `
            -Message "A mount access-mode mismatch must fail" -Pattern 'requested access mode'
        $script:MountMismatch = $false
        $dismounts = $script:MountDismounts
        Assert-Throws -Operation { Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ScriptBlock { throw 'Synthetic callback failure' } } `
            -Message "Callback failures must clean owned mounts" -Pattern 'Synthetic callback failure'
        Assert-Equal -Expected ($dismounts + 1) -Actual $script:MountDismounts -Message "A failed callback must still dismount"
        $script:MountDismountFails = $true
        $script:LeakedMountResults = [Collections.Generic.List[object]]::new()
        Assert-Throws -Operation {
            Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ScriptBlock { return $true } |
                ForEach-Object { $script:LeakedMountResults.Add($_) }
        } -Message "Failed cleanup must not emit a success result" -Pattern 'Failed to dismount'
        Assert-Equal -Expected 0 -Actual $script:LeakedMountResults.Count -Message "Mount results must be withheld until cleanup succeeds"
        $script:MountDismountFails = $false; $script:MountRemoveFails = $true
        $dismounts = $script:MountDismounts
        Assert-Throws -Operation { Invoke-BaseImageOfflineWindows -VhdxPath $mountPath -ScriptBlock {} } `
            -Message "Access-path cleanup failures must remain explicit" -Pattern 'Failed to remove owned access path'
        Assert-Equal -Expected ($dismounts + 1) -Actual $script:MountDismounts -Message "Access-path cleanup failure must not prevent owned image dismount"
    }
    & {
        $answerRoot = Join-Path $testRoot 'bounded-answers'
        $null = New-Item -Path $answerRoot -ItemType Directory
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('SYNTHETIC-NOT-A-REAL-PASSWORDPassword'))
        $xml = '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><OOBE><HideEULAPage>true</HideEULAPage></OOBE><UserAccounts><LocalAccounts><LocalAccount><Name>fixture-admin</Name><Group>Administrators</Group><Password><Value>' +
            $encoded + '</Value><PlainText>false</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts><FirstLogonCommands><SynchronousCommand><Order>7</Order><Description>Preserved command</Description><CommandLine>cmd.exe /c exit /b 0</CommandLine></SynchronousCommand></FirstLogonCommands></component></settings></unattend>'
        $path = Join-Path $answerRoot 'Unattend.xml'
        [IO.File]::WriteAllText($path, $xml)
        function Read-AnswerFixture {
            $document = [xml]::new(); $document.XmlResolver = $null
            $document.Load($path)
            [pscustomobject]@{ Document = $document; Path = $path; RelativePath = 'staging\Unattend.xml' }
        }
        $plan = New-BaseImageAutoLogonPlan -AnswerDocuments @(Read-AnswerFixture) -UserName 'fixture-admin' -DisableAfterFirstLogon
        $configured = @(Write-BaseImageAutoLogonPlan -Plan $plan)
        Assert-True -Condition ($configured.Count -eq 1 -and $configured[0].Configured -and $configured[0].DisableAfterFirstLogon -and
            ($configured[0] | ConvertTo-Json -Depth 4) -notmatch [regex]::Escape($encoded)) -Message "Bounded autologon configuration must return one non-secret result"
        $answer = (Read-AnswerFixture).Document
        $auto = $answer.SelectSingleNode('//*[local-name()="AutoLogon"]')
        Assert-True -Condition ($auto.SelectSingleNode('*[local-name()="Password"]/*[local-name()="Value"]').InnerText -ceq $encoded -and
            $auto.SelectSingleNode('*[local-name()="LogonCount"]').InnerText -eq '1') -Message "The existing password encoding and documented initial count must be preserved"
        $commands = @($answer.SelectNodes('//*[local-name()="FirstLogonCommands"]/*[local-name()="SynchronousCommand"]'))
        $cleanup = @($commands | Where-Object { $_.SelectSingleNode('*[local-name()="Description"]').InnerText -eq $plan.CleanupDescription })
        Assert-True -Condition ($commands.Count -eq 2 -and $cleanup.Count -eq 1 -and
            $cleanup[0].SelectSingleNode('*[local-name()="Order"]').InnerText -eq '8' -and
            $cleanup[0].SelectSingleNode('*[local-name()="CommandLine"]').InnerText -match 'AutoLogonCount.*REG_DWORD.*0.*&&.*AutoAdminLogon.*REG_SZ.*0' -and
            $cleanup[0].SelectSingleNode('*[local-name()="CommandLine"]').InnerText -notmatch 'OOBEInProgress|SystemSetupInProgress|Skip.*OOBE|DefaultPassword') `
            -Message "Cleanup must preserve existing commands and disable only autologon, never setup/credential state"
        $again = New-BaseImageAutoLogonPlan -AnswerDocuments @(Read-AnswerFixture) -UserName 'fixture-admin' -AllowExisting -DisableAfterFirstLogon
        $null = Write-BaseImageAutoLogonPlan -Plan $again
        $answer = (Read-AnswerFixture).Document
        Assert-Equal -Expected 1 -Actual @($answer.SelectNodes('//*[local-name()="AutoLogon"]')).Count -Message "Resumed configuration must not duplicate AutoLogon"
        Assert-Equal -Expected 2 -Actual @($answer.SelectNodes('//*[local-name()="SynchronousCommand"]')).Count -Message "Resumed configuration must not duplicate cleanup"
        Assert-Throws -Operation { New-BaseImageAutoLogonPlan -AnswerDocuments @(Read-AnswerFixture) -UserName 'fixture-admin' } `
            -Message "Diagnostic comparisons must still reject preconfigured autologon" -Pattern 'already configures'
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Assert-Throws -Operation { New-BaseImageAutoLogonPlan -AnswerDocuments @(Read-AnswerFixture) -UserName 'other-admin' -AllowExisting -DisableAfterFirstLogon } `
            -Message "Bounded sign-in must not invent another account" -Pattern 'does not uniquely match'
        Assert-Equal -Expected $before -Actual (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -Message "Rejected sign-in plans must not mutate answer files"
    }
    $builderAst = [Management.Automation.Language.Parser]::ParseFile($newBaseImagePath, [ref]$null, [ref]$null)
    & {
        $launchBlocks = @($builderAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                    $node.Extent.Text.Contains('A previous Sysprep failure marker')
                }, $true))
        Assert-Equal -Expected 1 -Actual $launchBlocks.Count -Message "Audit launcher tests must execute the shipped guest command"
        $guestRoot = Join-Path $testRoot 'audit-guest'
        $null = New-Item -Path $guestRoot -ItemType Directory
        $launchText = $launchBlocks[0].Extent.Text.Replace('C:\staging', $guestRoot)
        $launch = [scriptblock]::Create($launchText.Substring(1, $launchText.Length - 2))
        $guestScript = Join-Path $guestRoot 'Customize-WindowsSettings.ps1'
        function Get-CimInstance {
            param($ClassName, $ErrorAction)
            if ($script:AuditScenario -eq 'QueryFailed') { throw 'Synthetic process query failure' }
            if ($script:AuditScenario -eq 'Active') { [pscustomobject]@{ CommandLine = "$guestScript -RunSysprep" } }
        }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$PassThru, $ErrorAction)
            $script:AuditStarts++
            [pscustomobject]@{ Id = 42 }
        }
        foreach ($scenario in @('Active', 'Complete', 'Clean', 'Failed', 'Stale', 'IncompleteMarker', 'QueryFailed')) {
            $script:AuditScenario = $scenario; $script:AuditStarts = 0
            foreach ($name in @('Customization.txt', 'SysprepComplete.txt', 'SysprepFailed.txt')) {
                [IO.File]::Delete((Join-Path $guestRoot $name))
            }
            [IO.File]::WriteAllText($guestScript, 'PREVIOUS-CUSTOMIZER')
            if ($scenario -in @('Active', 'Complete', 'Stale')) {
                [IO.File]::WriteAllText((Join-Path $guestRoot 'Customization.txt'), 'PRESERVE-CUSTOMIZATION')
            }
            if ($scenario -in @('Complete', 'IncompleteMarker')) {
                [IO.File]::WriteAllText((Join-Path $guestRoot 'SysprepComplete.txt'), 'PRESERVE-SYSPREP')
            }
            if ($scenario -eq 'Failed') {
                [IO.File]::WriteAllText((Join-Path $guestRoot 'SysprepFailed.txt'), 'PRESERVE-FAILURE')
            }
            $existingMarkers = @(Get-ChildItem -LiteralPath $guestRoot -Filter '*.txt')
            if ($scenario -in @('Active', 'Complete', 'Clean')) {
                $launched = @(& $launch -Source 'CURRENT-CUSTOMIZER')
                Assert-True -Condition ($launched.Count -eq 1 -and $launched[0] -is [bool] -and $launched[0]) `
                    -Message "$scenario Audit launch must return one Boolean acknowledgement"
            }
            else {
                Assert-Throws -Operation { & $launch -Source 'CURRENT-CUSTOMIZER' } -Message "$scenario Audit state must be reported, not overwritten"
            }
            $expectedScript = if ($scenario -eq 'Clean') { 'CURRENT-CUSTOMIZER' } else { 'PREVIOUS-CUSTOMIZER' }
            Assert-Equal -Expected $expectedScript -Actual ([IO.File]::ReadAllText($guestScript)) -Message "$scenario must preserve an existing or completed customizer"
            Assert-Equal -Expected ([int]($scenario -eq 'Clean')) -Actual $script:AuditStarts -Message "$scenario must not start duplicate customization"
            foreach ($marker in $existingMarkers) {
                Assert-True -Condition ([IO.File]::Exists($marker.FullName) -and
                    [IO.File]::ReadAllText($marker.FullName).StartsWith('PRESERVE-')) `
                    -Message "$scenario must preserve existing diagnostic/completion markers"
            }
        }
    }
    $captureBranches = @($builderAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and $node.ElseClause -and
                $node.Clauses[0].Item1.Extent.Text -eq '$WhatIf' -and
                $node.ElseClause.Extent.Text.Contains('Obtaining OS disk path')
            }, $true))
    Assert-Equal -Expected 1 -Actual $captureBranches.Count -Message "Capture behavior tests must execute the shipped publication branch"
    $captureText = $captureBranches[0].ElseClause.Extent.Text
    $capture = [scriptblock]::Create($captureText.Substring(1, $captureText.Length - 2))
    $captureRoot = Join-Path $testRoot 'capture'
    $RootPath = Join-Path $captureRoot 'repository'
    $goldOutputDirectory = Join-Path $captureRoot 'output'
    $null = New-Item -Path (Join-Path $RootPath 'tools'), $goldOutputDirectory -ItemType Directory -Force
    $qualificationFixture = @'
[CmdletBinding(SupportsShouldProcess)]
param($VmName, $SourceVhdxPath, $Destination, $GuestCredential, $TestVariant)
$global:MemLabsBaseImageQualificationReads++
$global:MemLabsBaseImageQualificationFixture
'@
    [IO.File]::WriteAllText((Join-Path $RootPath 'tools\Test-WindowsFirstLogonImage.ps1'), $qualificationFixture)
    $script:CaptureStagingPath = Join-Path $captureRoot 'vm'
    $script:CaptureVmPath = Join-Path $script:CaptureStagingPath 'owned'
    $null = New-Item -Path $script:CaptureVmPath -ItemType Directory -Force
    $script:CaptureSourcePath = Join-Path $script:CaptureVmPath 'source.vhdx'
    [IO.File]::WriteAllText($script:CaptureSourcePath, 'SYNTHETIC-QUALIFIED-IMAGE-BYTES')
    $qualifiedSourceHash = (Get-FileHash -LiteralPath $script:CaptureSourcePath -Algorithm SHA256).Hash
    $evidenceArchive = Join-Path $captureRoot 'evidence.zip'
    [IO.File]::WriteAllText($evidenceArchive, 'SYNTHETIC-EVIDENCE')
    $vhdxFile = 'custom-reference.vhdx'
    $goldImagePath = Join-Path $goldOutputDirectory $vhdxFile
    $script:CaptureReceiptPath = "$goldImagePath.qualification.json"
    $script:PublicationFailure = ''
    $global:Common = [pscustomobject]@{
        TempPath = $captureRoot; AzureImagePath = $goldOutputDirectory; StagingVMPath = $script:CaptureStagingPath
        LocalAdmin = [pscredential]::new('fixture-admin', [Security.SecureString]::new())
    }
    $vmName = 'owned-stopped-capture-fixture'
    function Get-VM2 { param($Name, [switch]$Fallback, $ErrorAction); [pscustomobject]@{ State = 'Off'; Path = $script:CaptureVmPath } }
    function Get-VMSnapshot { param($VMName, $ErrorAction) }
    function Get-VMHardDiskDrive { param($VMName, $ErrorAction); [pscustomobject]@{ Path = $script:CaptureSourcePath } }
    function Get-VHD { param($Path, $ErrorAction); [pscustomobject]@{ VhdFormat = 'VHDX' } }
    function Test-BaseImageSysprepComplete {
        param($VhdxPath)
        [pscustomobject]@{ Success = $true; Message = 'Synthetic offline verification'; Warnings = @(); InstallationType = $script:CaptureInstallationType }
    }
    function Set-BaseImageFirstBootAutoLogon {
        param($VhdxPath, $UserName)
        $script:AutoConfigureCalls++
        Assert-True -Condition ($VhdxPath -eq $script:CaptureSourcePath -and $UserName -eq 'fixture-admin') -Message "Only the owned staging image and existing local administrator may be configured"
        if ($script:PublicationFailure -eq 'AutoLogonSetupFailed') { throw 'Synthetic first-boot configuration failure' }
        [pscustomobject]@{ Configured = $true; DisableAfterFirstLogon = $true }
    }
    function Get-File {
        param($Source, $Destination, $DisplayName, $Action)
        $script:CaptureCopyCount++
        Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
        if ($script:PublicationFailure -eq 'CorruptCopy') { [IO.File]::AppendAllText($Destination, 'CORRUPTION') }
        return $true
    }
    function Move-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination)
        if ($script:PublicationFailure -eq 'ReceiptMove' -and $Destination -eq $script:CaptureReceiptPath -and
            [IO.Path]::GetFileName($LiteralPath).StartsWith('_partial_')) {
            throw 'Synthetic receipt promotion failure'
        }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    function Set-Content {
        [CmdletBinding()]
        param([string]$LiteralPath, [Parameter(ValueFromPipeline)]$Value, [string]$Encoding, [switch]$Force)
        process {
            if ($script:PublicationFailure -eq 'ReceiptWrite' -and $LiteralPath.EndsWith('.qualification.json')) {
                throw 'Synthetic receipt staging failure'
            }
            Microsoft.PowerShell.Management\Set-Content @PSBoundParameters
        }
    }

    foreach ($scenario in @('Blocked', 'Partial', 'StringReady', 'WrongHash', 'MissingEvidence', 'UnknownType',
            'CorruptCopy', 'ReceiptWrite', 'ReceiptMove', 'Qualified', 'Server',
            'BoundedAutoLogon', 'AutoLogonStillEnabled', 'AutoLogonOobeIncomplete', 'AutoLogonNoDesktop', 'AutoLogonSetupFailed', 'ServerAutoLogon')) {
        $script:CaptureFailures.Clear()
        $script:CaptureCopyCount = 0
        $script:AutoConfigureCalls = 0
        $EnableFirstBootAutoLogon = [switch]($scenario -match 'AutoLogon')
        $script:CaptureInstallationType = if ($scenario -in @('Server', 'ServerAutoLogon')) { 'Server' } elseif ($scenario -eq 'UnknownType') { 'Unknown' } else { 'Client' }
        $script:PublicationFailure = $scenario
        $global:MemLabsBaseImageQualificationReads = 0
        $global:MemLabsBaseImageQualificationFixture = [pscustomobject]@{
            Status = 'Completed'; Qualified = $true; SourceHash = $qualifiedSourceHash; ArchivePath = $evidenceArchive
            AutoLogonDisabled = $true; OobeComplete = $true; InteractiveLabAccountObserved = $true
        }
        switch ($scenario) {
            Blocked { $global:MemLabsBaseImageQualificationFixture.Qualified = $false }
            Partial { $global:MemLabsBaseImageQualificationFixture.Status = 'Partial' }
            StringReady { $global:MemLabsBaseImageQualificationFixture.Qualified = 'True' }
            WrongHash { $global:MemLabsBaseImageQualificationFixture.SourceHash = 'B' * 64 }
            MissingEvidence { $global:MemLabsBaseImageQualificationFixture.ArchivePath = Join-Path $captureRoot 'missing.zip' }
            AutoLogonStillEnabled { $global:MemLabsBaseImageQualificationFixture.AutoLogonDisabled = $false }
            AutoLogonOobeIncomplete { $global:MemLabsBaseImageQualificationFixture.OobeComplete = $false }
            AutoLogonNoDesktop { $global:MemLabsBaseImageQualificationFixture.InteractiveLabAccountObserved = $false }
        }
        [IO.File]::WriteAllText($goldImagePath, 'PREVIOUS-IMAGE')
        [IO.File]::WriteAllText("$goldImagePath.MD5", 'PREVIOUS-MD5')
        [IO.File]::WriteAllText($script:CaptureReceiptPath, 'PREVIOUS-RECEIPT')
        & $capture

        if ($scenario -in @('Qualified', 'Server', 'BoundedAutoLogon')) {
            Assert-Equal -Expected 0 -Actual $script:CaptureFailures.Count -Message "$scenario publication should succeed"
            Assert-Equal -Expected $qualifiedSourceHash -Actual (Get-FileHash -LiteralPath $goldImagePath -Algorithm SHA256).Hash -Message "$scenario must publish the verified bytes"
            Assert-Equal -Expected (Get-FileHash -LiteralPath $goldImagePath -Algorithm MD5).Hash -Actual (Get-Content -LiteralPath "$goldImagePath.MD5" -Raw).Trim() -Message "$scenario must publish the matching MD5 marker"
            if ($scenario -in @('Qualified', 'BoundedAutoLogon')) {
                $receipt = Get-Content -LiteralPath $script:CaptureReceiptPath -Raw | ConvertFrom-Json
                Assert-True -Condition ($receipt.Qualified -is [bool] -and $receipt.Qualified -and
                    $receipt.SHA256 -eq $qualifiedSourceHash -and $receipt.EvidenceArchive -eq $evidenceArchive) `
                    -Message "The published receipt must qualify the exact image and persistent evidence"
                Assert-Equal -Expected ([bool]$EnableFirstBootAutoLogon) -Actual $receipt.FirstBootAutoLogon.EnabledInImage -Message "The receipt must disclose intentional first-boot sign-in configuration"
                Assert-Equal -Expected ([bool]$EnableFirstBootAutoLogon) -Actual $receipt.FirstBootAutoLogon.DisabledAfterSignInVerified -Message "Bounded sign-in capture must verify automatic-login cleanup"
            }
            else {
                Assert-Equal -Expected 0 -Actual $global:MemLabsBaseImageQualificationReads -Message "Installed server metadata must preserve server capture behavior"
                Assert-True -Condition (-not (Test-Path -LiteralPath $script:CaptureReceiptPath)) -Message "A server replacement must not retain a stale client qualification receipt"
            }
        }
        else {
            Assert-True -Condition ($script:CaptureFailures.Count -gt 0) -Message "$scenario must explicitly report failure"
            Assert-Equal -Expected 'PREVIOUS-IMAGE' -Actual (Get-Content -LiteralPath $goldImagePath -Raw) -Message "$scenario must preserve the prior image"
            Assert-Equal -Expected 'PREVIOUS-MD5' -Actual (Get-Content -LiteralPath "$goldImagePath.MD5" -Raw) -Message "$scenario must preserve the prior hash marker"
            Assert-Equal -Expected 'PREVIOUS-RECEIPT' -Actual (Get-Content -LiteralPath $script:CaptureReceiptPath -Raw) -Message "$scenario must preserve the prior qualification receipt"
            if ($scenario -in @('Blocked', 'Partial', 'StringReady', 'WrongHash', 'MissingEvidence', 'UnknownType',
                    'AutoLogonStillEnabled', 'AutoLogonOobeIncomplete', 'AutoLogonNoDesktop', 'AutoLogonSetupFailed', 'ServerAutoLogon')) {
                Assert-Equal -Expected 0 -Actual $script:CaptureCopyCount -Message "$scenario must fail before making a candidate copy"
            }
            if (-not $EnableFirstBootAutoLogon -or $scenario -eq 'ServerAutoLogon') {
                Assert-Equal -Expected 0 -Actual $script:AutoConfigureCalls -Message "$scenario must not silently enable first-boot sign-in"
            }
            else { Assert-Equal -Expected 1 -Actual $script:AutoConfigureCalls -Message "$scenario must explicitly configure the owned candidate" }
        }
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $goldOutputDirectory -Filter '*.backup.*').Count -Message "$scenario must not lose a prior artifact during rollback"
        Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $goldOutputDirectory -Filter '_partial_*').Count -Message "$scenario must clean its partial artifact and metadata"
    }
}
finally {
    Remove-Variable -Name MemLabsBaseImageQualificationFixture, MemLabsBaseImageQualificationReads -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:Failures -gt 0) {
    throw "$($script:Failures) base-image staging test(s) failed."
}

Write-Host "Base-image staging tests passed." -ForegroundColor Green
