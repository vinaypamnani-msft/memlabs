#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs an isolated, guided SFAP-cache comparison using two fresh Windows 11 image copies.
.DESCRIPTION
    Uses the selected lab VM only for image identity and hardware/switch settings.
    Never starts, stops, changes, or deletes that VM or the generalized source image.
    Runs an unchanged control and an SFAP-cache-cleaned copy sequentially, without DSC,
    rename, or domain-join actions. Collects diagnostics and a comparison ZIP.
    Disposable trial VMs/disks are cleaned after verified evidence collection unless
    KeepTrialVMs is specified. Unknown operation outcomes retain resources and stop.
.EXAMPLE
    .\tools\Test-WindowsFirstLogonImage.ps1 -VmName ADA-W11CLIENT1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VmName,
    [string]$SourceVhdxPath,
    [string]$Destination,
    [pscredential]$GuestCredential,
    [switch]$KeepTrialVMs
)
$ErrorActionPreference = 'Stop'

function Import-MemLabsImageComparisonHelpers {
    $comparisonHelperPath = Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'
    $comparisonHelperErrors = $null
    $comparisonHelperAst = [Management.Automation.Language.Parser]::ParseFile($comparisonHelperPath, [ref]$null, [ref]$comparisonHelperErrors)
    if ($comparisonHelperErrors.Count) { throw "Diagnostic helper parse errors: $($comparisonHelperErrors -join '; ')" }
    foreach ($comparisonHelperName in @('Initialize-MemLabsSetupDiagnosticModules', 'Resolve-MemLabsSetupDiagnosticPath',
            'New-MemLabsPrivateDiagnosticDirectory', 'Initialize-MemLabsOfflineSetupHiveType',
            'Read-MemLabsOfflineSetupRegistryValues', 'Read-MemLabsOfflineSetupRegistryMetadata', 'Read-MemLabsOfflineWindowsSetupHive',
            'Get-MemLabsOfflineSetupSourcePath')) {
        $comparisonHelperDefinitions = @($comparisonHelperAst.FindAll({
                    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $comparisonHelperName
                }, $true))
        if ($comparisonHelperDefinitions.Count -ne 1) { throw "Expected one diagnostic helper '$comparisonHelperName'." }
        . ([scriptblock]::Create($comparisonHelperDefinitions[0].Extent.Text))
    }
    . (Join-Path $PSScriptRoot 'Common.WindowsVmOobeRepair.ps1')
}

function Get-MemLabsComparisonImageCandidates {
    param($OriginalVM)
    $roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $roots.Add([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\azureFiles')))
    $commonVariable = Get-Variable -Name Common -Scope Global -ErrorAction SilentlyContinue
    if ($commonVariable -and $commonVariable.Value -and $commonVariable.Value.AzureFilesPath) {
        $null = $roots.Add([IO.Path]::GetFullPath($commonVariable.Value.AzureFilesPath))
    }
    $osId = $null
    if (-not [string]::IsNullOrWhiteSpace($OriginalVM.Notes)) {
        try { $note = $OriginalVM.Notes | ConvertFrom-Json -ErrorAction Stop; $osId = $note.operatingSystem }
        catch { Write-Warning 'The original VM note is not readable JSON; image selection will require confirmation.' }
    }
    $found = [ordered]@{}
    foreach ($root in $roots) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        foreach ($listName in @('_fileList_develop.json', '_fileList.json')) {
            $listPath = Join-Path $root $listName
            if (-not [IO.File]::Exists($listPath)) { continue }
            try { $list = Get-Content -LiteralPath $listPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "Cached image list '$listPath' could not be read: $($_.Exception.Message)" }
            foreach ($entry in @($list.OS | Where-Object { $osId -and $_.id -eq $osId })) {
                if ([string]::IsNullOrWhiteSpace($entry.filename) -or [IO.Path]::IsPathRooted($entry.filename)) { throw 'The cached image filename is not relative.' }
                $path = [IO.Path]::GetFullPath((Join-Path $root $entry.filename))
                if (-not $path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The cached image filename escapes its storage root.' }
                if ([IO.File]::Exists($path) -and [IO.Path]::GetExtension($path) -ieq '.vhdx') {
                    $found[$path] = [pscustomobject]@{ Path = $path; Matched = $true; OperatingSystem = $osId; Evidence = $listName }
                }
            }
        }
        foreach ($directory in @($root, (Join-Path $root 'os'))) {
            if (-not [IO.Directory]::Exists($directory)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.vhdx' -File -ErrorAction Stop |
                    Where-Object Name -match 'WIN11|Windows.?11' | Select-Object -First 65)) {
                if ($found.Count -ge 64 -and -not $found.Contains($file.FullName)) { throw 'Too many candidate images; supply -SourceVhdxPath explicitly.' }
                if (-not $found.Contains($file.FullName)) {
                    $found[$file.FullName] = [pscustomobject]@{ Path = $file.FullName; Matched = $false; OperatingSystem = $null; Evidence = 'Windows 11 filename; confirmation required' }
                }
            }
        }
    }
    @($found.Values | Sort-Object @{ Expression = 'Matched'; Descending = $true }, Path)
}

function Select-MemLabsComparisonImage {
    param($OriginalVM, [string]$ExplicitPath, [switch]$PreviewOnly)
    if ($ExplicitPath) { return Resolve-MemLabsSetupDiagnosticPath -Path $ExplicitPath }
    $candidates = @(Get-MemLabsComparisonImageCandidates -OriginalVM $OriginalVM)
    $matched = @($candidates | Where-Object Matched)
    if ($matched.Count -eq 1) {
        Write-Host "Matched the VM's cached base image: $($matched[0].Path)"
        return $matched[0].Path
    }
    if ($candidates.Count -eq 0) {
        throw 'No cached Windows 11 base image was found. Supply -SourceVhdxPath with the generalized downloaded image, not the failed VM OS disk. No VM or disk has been changed.'
    }
    Write-Host 'Choose the generalized Windows 11 base image. The script will verify its setup state before using it.'
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        Write-Host ("  {0}. {1} ({2})" -f ($index + 1), $candidates[$index].Path, $candidates[$index].Evidence)
    }
    if ($PreviewOnly) { Write-Host 'Preview only: use -SourceVhdxPath to select one of these images.'; return }
    $choice = Read-Host 'Image number (0 cancels)'
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 0 -or $number -gt $candidates.Count) { throw 'Invalid image selection. Nothing was changed.' }
    if ($number -eq 0) { throw 'Comparison cancelled. Nothing was changed.' }
    return $candidates[$number - 1].Path
}

function Invoke-MemLabsComparisonImageInspection {
    param(
        [string]$Path, [ValidateSet('Source', 'Control', 'Test')][string]$Mode,
        [string]$Workspace
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($Mode -ne 'Source') {
        $expected = [IO.Path]::GetFullPath((Join-Path $Workspace "$Mode\$Mode.vhdx"))
        if ($resolved -ine $expected) { throw 'Writable inspection is restricted to this run''s exact disposable trial disk.' }
    }
    $info = Get-VHD -Path $resolved -ErrorAction Stop
    if ($info.Attached -or $info.ParentPath) { throw 'The comparison requires an unattached, independent VHDX, not an active disk or differencing chain.' }
    $private = Join-Path $Workspace ("Private-" + [guid]::NewGuid().ToString('N'))
    New-MemLabsPrivateDiagnosticDirectory -Path $private
    $mounted = $null
    $result = $null
    try {
        $readOnly = $Mode -eq 'Source'
        $mounted = Mount-VHD -Path $resolved -ReadOnly:$readOnly -NoDriveLetter -Passthru -ErrorAction Stop
        $disk = Get-Disk -Number $mounted.DiskNumber -ErrorAction Stop
        if ($disk.Number -ne $mounted.DiskNumber -or [bool]$disk.IsReadOnly -ne $readOnly) { throw 'The mounted disk identity/access mode does not match the requested inspection.' }
        if ($disk.IsOffline) {
            $null = Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
            $disk = Get-Disk -Number $mounted.DiskNumber -ErrorAction Stop
            if ($disk.IsOffline -or [bool]$disk.IsReadOnly -ne $readOnly) { throw 'The mounted disk was not verified online in its requested access mode.' }
        }
        $windowsRoot = $null
        foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
            if (("$($partition.GptType)" -replace '[{}]', '') -ieq 'e3c9e316-0b5c-4db8-817d-f92df00215ae') { continue }
            foreach ($volume in @(Get-Volume -Partition $partition -ErrorAction Stop)) {
                if (-not $volume.Path) { continue }
                $candidate = Join-Path $volume.Path 'Windows'
                if ([IO.File]::Exists((Join-Path $candidate 'System32\config\SYSTEM'))) { $windowsRoot = $candidate; break }
            }
            if ($windowsRoot) { break }
        }
        if (-not $windowsRoot) { throw 'No readable Windows installation was found in the candidate image.' }
        foreach ($kind in @('SYSTEM', 'SOFTWARE')) {
            $source = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $windowsRoot -RelativePath "System32\config\$kind"
            if (-not $source) { throw "The source image lacks the $kind hive." }
            Copy-Item -LiteralPath $source -Destination (Join-Path $private $kind) -ErrorAction Stop
        }
        $software = Read-MemLabsOfflineWindowsSetupHive -Path (Join-Path $private 'SOFTWARE') -Kind SOFTWARE
        $system = Read-MemLabsOfflineWindowsSetupHive -Path (Join-Path $private 'SYSTEM') -Kind SYSTEM
        $build = 0
        if ($software.WindowsVersion.Values.InstallationType -ne 'Client' -or
            -not [int]::TryParse($software.WindowsVersion.Values.CurrentBuild, [ref]$build) -or $build -lt 22000 -or
            $software.ImageState.Values.ImageState -notin @('IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE', 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE') -or
            $system.Setup.Values.SetupType -ne 2) {
            throw 'This is not a generalized Windows 11 base image awaiting first boot. An already-failed/deployed OS disk cannot provide a valid fresh-boot comparison.'
        }
        $volumeRoot = [IO.DirectoryInfo]::new($windowsRoot).Parent.FullName
        $copyProfile = $false
        foreach ($relative in @('Windows\Panther\unattend.xml', 'staging\Unattend.xml')) {
            $answer = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $relative
            if (-not $answer) { continue }
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = 1MB
            $stream = [IO.File]::OpenRead($answer)
            $reader = $null
            try {
                if ($stream.Length -gt 1MB) { throw 'The image answer file exceeds the inspection limit.' }
                $reader = [Xml.XmlReader]::Create($stream, $settings)
                $document = [xml]::new(); $document.XmlResolver = $null; $document.Load($reader)
            }
            finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
            if (@($document.SelectNodes('//*[local-name()="JoinDomain" and normalize-space(.)!=""]')).Count) { throw 'The candidate answer file requests a domain join; it is not suitable for this isolated test.' }
            if (@($document.SelectNodes('//*[local-name()="CopyProfile" and normalize-space(.)="true"]')).Count) { $copyProfile = $true }
        }
        if (-not $copyProfile) { throw 'The candidate does not show CopyProfile enabled; this experiment would not test the proposed copied-profile-cache cause.' }
        $users = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath 'Users' -AllowDirectory
        $profiles = @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction Stop | Select-Object -First 33)
        if ($profiles.Count -gt 32) { throw 'The base image exceeds the 32-profile inspection limit.' }
        $caches = [Collections.Generic.List[object]]::new()
        foreach ($profile in $profiles) {
            if ($profile.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $relative = "Users\$($profile.Name)\AppData\Local\Microsoft\Windows\SFAP"
            $directory = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $relative -AllowDirectory
            if (-not $directory) { continue }
            $files = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
            if ($files.Count -gt 2 -or @($files | Where-Object { $_.PSIsContainer -or $_.Name -notmatch '^cache[01]\.bin$' }).Count) {
                throw "Unexpected SFAP contents under '$relative'; no arbitrary files will be removed."
            }
            $names = [Collections.Generic.List[string]]::new()
            foreach ($file in $files) {
                $cachePath = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath "$relative\$($file.Name)"
                if (-not $cachePath -or [IO.FileInfo]::new($cachePath).Length -gt 1MB) { throw 'An SFAP cache file is missing or exceeds its expected bound.' }
                $names.Add($file.Name)
            }
            $caches.Add([pscustomobject]@{ Directory = $relative; Files = $names.ToArray(); Removed = $false })
        }
        if ($caches.Count -eq 0) { throw 'The image contains no SFAP profile directories to compare; no trial VMs will be created.' }
        if ($Mode -eq 'Test') {
            foreach ($cache in $caches) {
                $directory = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath $cache.Directory -AllowDirectory
                foreach ($name in $cache.Files) {
                    $file = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $volumeRoot -RelativePath "$($cache.Directory)\$name"
                    [IO.File]::Delete($file)
                }
                [IO.Directory]::Delete($directory)
                if ([IO.Directory]::Exists($directory)) { throw 'The disposable test cache directory was not removed.' }
                $cache.Removed = $true
            }
        }
        $result = [pscustomobject]@{
            ImageState = $software.ImageState.Values.ImageState; Build = $build
            UBR = $software.WindowsVersion.Values.UBR; DisplayVersion = $software.WindowsVersion.Values.DisplayVersion
            CopyProfile = $copyProfile; Caches = $caches.ToArray(); Access = $(if ($readOnly) { 'ReadOnly' } else { 'ReadWriteTrialCopyOnly' })
        }
    }
    finally {
        try {
            if ($mounted) {
                $detached = $false
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    try { Dismount-VHD -Path $resolved -ErrorAction Stop; $detached = $true; break }
                    catch {
                        if ($attempt -eq 2) { throw "The owned mount '$resolved' could not be detached; stop here and inspect it before any VM startup. $($_.Exception.Message)" }
                        Write-Warning "Retrying owned image dismount: $($_.Exception.Message)"
                    }
                }
                if (-not $detached) { throw 'Image dismount was not verified.' }
            }
        }
        finally {
            foreach ($kind in @('SYSTEM', 'SOFTWARE')) {
                $file = Join-Path $private $kind
                if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
            }
            [IO.Directory]::Delete($private)
        }
    }
    return $result
}

function Invoke-MemLabsComparisonWorker {
    param([scriptblock]$Block, [object[]]$Arguments, [int]$TimeoutSeconds, [string]$Operation)
    Write-Host "$Operation (limit ${TimeoutSeconds}s)..."
    $job = Start-Job -ScriptBlock $Block -ArgumentList $Arguments -ErrorAction Stop
    $items = @(Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds $TimeoutSeconds -Operation $Operation)
    if ($items.Count -ne 1) { throw "$Operation did not return exactly one result." }
    return $items[0]
}

function Copy-MemLabsComparisonDisk {
    param([string]$Source, [string]$Destination, [string]$ExpectedHash)
    $result = Invoke-MemLabsComparisonWorker -TimeoutSeconds 1200 -Operation 'Copying and verifying a disposable base-image copy' `
        -Arguments @($Source, $Destination) -Block {
            param($Source, $Destination)
            $ErrorActionPreference = 'Stop'
            [IO.File]::Copy($Source, $Destination, $false)
            [pscustomobject]@{ Hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash }
        }
    if ($result.Hash -ine $ExpectedHash) { throw 'A trial copy does not match the generalized source hash.' }
    [IO.File]::SetAttributes($Destination, ([IO.File]::GetAttributes($Destination) -band (-bnot [IO.FileAttributes]::ReadOnly)))
}

function New-MemLabsComparisonVm {
    param($Spec, $Hardware, [string]$Token)
    $result = Invoke-MemLabsComparisonWorker -TimeoutSeconds 120 -Operation "Creating disposable $($Spec.Label) VM" `
        -Arguments @($Spec, $Hardware, $Token) -Block {
            param($Spec, $Hardware, $Token)
            $ErrorActionPreference = 'Stop'
            Import-Module Hyper-V -ErrorAction Stop
            if (@(Get-VM -ErrorAction Stop | Where-Object Name -eq $Spec.Name).Count) { throw 'The planned trial VM name already exists.' }
            $vm = New-VM -Name $Spec.Name -Path $Spec.Root -Generation 2 -VHDPath $Spec.Disk `
                -MemoryStartupBytes ([long]$Hardware.Startup) -SwitchName $Hardware.Switch -ErrorAction Stop
            Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
                -Notes (@{ Purpose = 'MemLabsFirstLogonComparison'; Token = $Token; Label = $Spec.Label } | ConvertTo-Json -Compress) -ErrorAction Stop
            Set-VMProcessor -VM $vm -Count $Hardware.Processors -ErrorAction Stop
            if ($Hardware.Dynamic) {
                Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes ([long]$Hardware.Minimum) `
                    -MaximumBytes ([long]$Hardware.Maximum) -StartupBytes ([long]$Hardware.Startup) -ErrorAction Stop
            }
            else { Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ([long]$Hardware.Startup) -ErrorAction Stop }
            if ($Hardware.SecureBoot -eq 'On') { Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $Hardware.Template -ErrorAction Stop }
            else { Set-VMFirmware -VM $vm -EnableSecureBoot Off -ErrorAction Stop }
            if ($Hardware.Tpm) { Set-VMKeyProtector -VM $vm -NewLocalKeyProtector -ErrorAction Stop; Enable-VMTPM -VM $vm -ErrorAction Stop }
            [pscustomobject]@{ Id = $vm.Id; Name = $vm.Name }
        }
    $live = Get-VM -Id $result.Id -ErrorAction Stop
    if ($live.Name -ne $Spec.Name -or "$($live.State)" -ne 'Off' -or
        -not $live.Path.StartsWith($Spec.Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The created VM does not match its disposable identity/path/state.'
    }
    return $live
}

function Read-MemLabsComparisonDiagnostics {
    param([string]$Archive, [guid]$ExpectedVmId)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $values = @{}
        foreach ($name in @('Manifest.json', 'Live-StateBefore.json', 'Live-StateAfter.json')) {
            $entries = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -eq $name })
            if ($entries.Count -ne 1 -or $entries[0].Length -gt 4MB) { throw "Missing/ambiguous/oversized trial evidence '$name'." }
            $reader = [IO.StreamReader]::new($entries[0].Open())
            try { $values[$name] = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
        }
        $manifest = $values['Manifest.json']
        if ($manifest.VMId -ine $ExpectedVmId.ToString('D') -or $manifest.FinalState -ne 'Off' -or
            $manifest.Status -notin @('Complete', 'Partial') -or $manifest.LiveProbe.Status -notin @('Complete', 'Partial')) {
            throw 'Trial evidence belongs to another VM or did not verify live inspection/final shutdown.'
        }
        $before = $values['Live-StateBefore.json']; $after = $values['Live-StateAfter.json']
        if (-not $before.MachineGuid -or $before.MachineGuid -ne $after.MachineGuid) { throw 'The trial guest identity changed between snapshots.' }
        foreach ($snapshot in @($before, $after)) {
            if ($snapshot.Scope -ne 'WindowsFirstLogonProbe' -or $snapshot.Setup.ProductType -ne 1 -or
                $snapshot.Setup.Ready -isnot [bool] -or $snapshot.Setup.NativeOobeComplete -isnot [bool] -or
                @($snapshot.Setup.Diagnostics).Count -ne 0) { throw 'Malformed/unreadable trial Windows-client setup evidence.' }
            if ($snapshot.Setup.Ready -and $snapshot.Setup.Reason -notin @('Complete', 'MachineCompleteAwaitingFirstLogon')) { throw 'Unexpected ready-state classification.' }
            if ($snapshot.Setup.Ready) {
                $setup = $snapshot.Setup
                if ($setup.ImageState -ne 'IMAGE_STATE_COMPLETE' -or $setup.SetupType -ne 0 -or
                    $setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0 -or
                    ($setup.Reason -eq 'Complete' -and -not $setup.NativeOobeComplete) -or
                    ($setup.Reason -eq 'MachineCompleteAwaitingFirstLogon' -and
                        ($setup.NativeOobeComplete -or $setup.WinRtOobeState -ne 'NotStarted' -or
                         $setup.SetupExeCompletion -ne 3 -or $setup.OobeBlockingProcessCount -ne 0 -or
                         @($setup.OobeProcesses | Where-Object { $_ -ine 'CloudExperienceHostBroker.exe' }).Count))) {
                    throw 'Inconsistent ready-state evidence.'
                }
            }
        }
        $ready = [bool]($before.Setup.Ready -and $after.Setup.Ready)
        $stalled = $true
        foreach ($snapshot in @($before, $after)) {
            $setup = $snapshot.Setup
            if ($setup.Ready -or $setup.Reason -ne 'WindowsWelcomeIncomplete' -or $setup.ImageState -ne 'IMAGE_STATE_COMPLETE' -or
                $setup.SetupType -ne 0 -or $setup.OOBEInProgress -ne 0 -or $setup.SystemSetupInProgress -ne 0 -or
                $setup.NativeOobeComplete -or $setup.WinRtOobeState -ne 'NotStarted' -or $setup.SetupExeCompletion -ne 3 -or
                'FirstLogonAnim.exe' -notin @($setup.OobeProcesses) -or
                @($setup.OobeProcesses | Where-Object { $_ -notin @('FirstLogonAnim.exe', 'CloudExperienceHostBroker.exe') }).Count) { $stalled = $false }
        }
        [pscustomobject]@{
            EvidenceStatus = $manifest.Status; Ready = $ready
            Observation = $(if ($ready) { 'Ready' } elseif ($stalled) { 'FirstLogonStall' } else { 'OtherOrTransitioning' })
            Before = $before.Setup; After = $after.Setup; MachineGuid = $before.MachineGuid
        }
    }
    finally { $zip.Dispose() }
}

function Invoke-MemLabsComparisonDiagnostics {
    param($VM, [pscredential]$GuestCredential, [string]$Destination)
    $items = @(& (Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1') -VmName $VM.Name `
        -Destination $Destination -GuestCredential $GuestCredential -IncludeLiveProbe -AllowTurnOff -Confirm:$false)
    if ($items.Count -ne 1 -or $items[0].FinalState -ne 'Off' -or -not [IO.File]::Exists($items[0].ArchivePath)) { throw 'Trial diagnostics did not return one verified archive/final Off result.' }
    return $items[0]
}

function Remove-MemLabsComparisonVm {
    param($VM, $Spec, [string]$Token)
    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    $note = $live.Notes | ConvertFrom-Json -ErrorAction Stop
    $disks = @(Get-VMHardDiskDrive -VM $live -ErrorAction Stop)
    if ($live.Name -ne $Spec.Name -or "$($live.State)" -ne 'Off' -or $note.Purpose -ne 'MemLabsFirstLogonComparison' -or
        $note.Token -cne $Token -or $disks.Count -ne 1 -or $disks[0].Path -ine $Spec.Disk -or
        -not $live.Path.StartsWith($Spec.Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        @(Get-VMSnapshot -VM $live -ErrorAction Stop).Count -gt 0) { throw 'Trial cleanup ownership/state/disk/checkpoint checks failed; resources were retained.' }
    $job = Remove-VM -VM $live -Force -AsJob -ErrorAction Stop
    $null = Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds 60 -Operation 'Removing the owned Off trial VM'
    if (@(Get-VM -ErrorAction Stop | Where-Object Id -eq $VM.Id).Count) { throw 'The trial VM still exists; its disk was retained.' }
    if ((Get-VHD -Path $Spec.Disk -ErrorAction Stop).Attached) { throw 'The trial disk remains attached; it was retained.' }
    [IO.File]::Delete($Spec.Disk)
}

function Invoke-MemLabsFirstLogonImageComparison {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$VmName, [string]$SourceVhdxPath, [string]$Destination, [pscredential]$GuestCredential, [switch]$KeepTrialVMs)
    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VmName)) { throw 'Specify one exact original VM name.' }
    $originals = @(Get-VM -Name $VmName -ErrorAction Stop)
    if ($originals.Count -ne 1 -or $originals[0].Name -ine $VmName -or $originals[0].Generation -ne 2) { throw 'Exactly one existing Generation 2 reference VM is required.' }
    $original = $originals[0]
    $source = Select-MemLabsComparisonImage -OriginalVM $original -ExplicitPath $SourceVhdxPath -PreviewOnly:$WhatIfPreference
    if (-not $source -and $WhatIfPreference) { return }
    if (-not [IO.File]::Exists($source) -or [IO.Path]::GetExtension($source) -ine '.vhdx') { throw 'The selected generalized VHDX file does not exist.' }
    if (-not $PSCmdlet.ShouldProcess($original.Name, "Compare two disposable fresh copies of '$source'; no change to this VM or source image")) { return }
    Initialize-MemLabsSetupDiagnosticModules -IncludeLiveProbe
    foreach ($command in @('New-VM', 'Set-VM', 'Set-VMMemory', 'Get-VMMemory', 'Set-VMProcessor', 'Get-VMFirmware',
            'Set-VMFirmware', 'Get-VMSecurity', 'Get-VMNetworkAdapter', 'Get-VMNetworkAdapterVlan',
            'Set-VMKeyProtector', 'Enable-VMTPM', 'Remove-VM', 'Get-VMSnapshot')) {
        Get-Command -Name "Hyper-V\$command" -ErrorAction Stop | Out-Null
    }
    $GuestCredential = Resolve-MemLabsOobeRepairCredential -GuestCredential $GuestCredential
    $adapters = @(Get-VMNetworkAdapter -VM $original -ErrorAction Stop)
    if ($adapters.Count -ne 1 -or -not $adapters[0].SwitchName) { throw 'The reference VM must identify one connected virtual switch for a matched comparison.' }
    $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapters[0] -ErrorAction Stop
    if ("$($vlan.OperationMode)" -ne 'Untagged') { throw 'This guided test does not guess VLAN settings; the reference adapter must use an untagged switch connection.' }
    $memory = Get-VMMemory -VM $original -ErrorAction Stop
    $firmware = Get-VMFirmware -VM $original -ErrorAction Stop
    $security = Get-VMSecurity -VM $original -ErrorAction Stop
    if ("$($firmware.SecureBoot)" -notin @('On', 'Off') -or
        ("$($firmware.SecureBoot)" -eq 'On' -and $firmware.SecureBootTemplate -notin @('MicrosoftWindows', 'MicrosoftUEFICertificateAuthority'))) {
        throw 'The reference secure-boot settings could not be matched safely.'
    }
    if ($memory.DynamicMemoryEnabled -isnot [bool] -or $security.TpmEnabled -isnot [bool] -or
        $memory.Startup -lt 512MB -or $memory.Minimum -le 0 -or $memory.Maximum -lt $memory.Startup -or
        $original.ProcessorCount -lt 1) { throw 'The reference memory/CPU/TPM settings are incomplete or unsupported.' }
    $hardware = [pscustomobject]@{
        Startup = $memory.Startup; Minimum = $memory.Minimum; Maximum = $memory.Maximum; Dynamic = [bool]$memory.DynamicMemoryEnabled
        Processors = $original.ProcessorCount; Switch = $adapters[0].SwitchName
        SecureBoot = "$($firmware.SecureBoot)"; Template = $firmware.SecureBootTemplate; Tpm = [bool]$security.TpmEnabled
    }
    if (-not $Destination) { $Destination = Join-Path (Split-Path $original.Path -Parent) 'FirstLogonComparisons' }
    $destinationPath = Resolve-MemLabsSetupDiagnosticPath -Path $Destination
    $driveRoot = [IO.Path]::GetPathRoot($destinationPath)
    if ($driveRoot -notmatch '^[A-Za-z]:\\$') { throw 'Use a local drive for the comparison workspace.' }
    $required = 2L * [IO.FileInfo]::new($source).Length + 2GB
    if ([IO.DriveInfo]::new($driveRoot).AvailableFreeSpace -lt $required) { throw "The comparison needs at least $([math]::Ceiling($required / 1GB)) GiB free for two disposable copies and diagnostics." }
    $token = [guid]::NewGuid().ToString('N')
    $workspace = Join-Path $destinationPath ("Compare-" + $token)
    New-MemLabsPrivateDiagnosticDirectory -Path $workspace
    $reportRoot = Join-Path $workspace 'Report'
    $null = New-Item -Path $reportRoot -ItemType Directory
    $reportPath = Join-Path $reportRoot 'Comparison.json'
    $report = [ordered]@{
        Version = 1; Token = $token; Status = 'InspectingSource'; OriginalVM = $original.Name; OriginalVMId = "$($original.Id)"
        OriginalState = "$($original.State)"; Source = $source; SourceHash = $null; SourceInspection = $null
        SourceBytes = [IO.FileInfo]::new($source).Length; SourceLastWriteUtc = [IO.File]::GetLastWriteTimeUtc($source).ToString('o')
        Hardware = $hardware; ProductionBehaviorChanged = $false; Verdict = 'Inconclusive'; Trials = [Collections.Generic.List[object]]::new()
        Errors = [Collections.Generic.List[string]]::new()
    }
    $failure = $null
    try {
        Write-Host 'Step 1/4: verifying the generalized source read-only. The original VM is untouched.'
        $report.SourceInspection = Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source -Workspace $workspace
        $hashResult = Invoke-MemLabsComparisonWorker -TimeoutSeconds 600 -Operation 'Hashing the generalized source image' -Arguments @($source) -Block {
            param($Source)
            [pscustomobject]@{ Hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash }
        }
        $report.SourceHash = $hashResult.Hash
        if ($report.SourceHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'The generalized source hash was not returned correctly.' }
        $specs = @()
        Write-Host 'Step 2/4: creating and checking the two independent copies.'
        foreach ($label in @('Control', 'Test')) {
            $root = Join-Path $workspace $label
            $null = New-Item -Path $root -ItemType Directory
            $spec = [pscustomobject]@{ Label = $label; Root = $root; Disk = (Join-Path $root "$label.vhdx"); Name = "ML-OOBE-$($label.Substring(0,1))-$($token.Substring(0,8))" }
            Copy-MemLabsComparisonDisk -Source $source -Destination $spec.Disk -ExpectedHash $report.SourceHash
            $inspection = Invoke-MemLabsComparisonImageInspection -Path $spec.Disk -Mode $label -Workspace $workspace
            $specs += $spec
            $report.Trials.Add([ordered]@{ Label = $label; Name = $spec.Name; VMId = $null; Disk = $spec.Disk; Inspection = $inspection; Status = 'Prepared'; Evidence = $null; Cleaned = $false })
            $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
        }
        Write-Host 'Step 3/4: running the control and cleaned test sequentially. No DSC, rename, or domain join will run.'
        foreach ($spec in $specs) {
            $trial = @($report.Trials | Where-Object Label -eq $spec.Label)[0]
            $trial.Status = 'Creating'
            $vm = New-MemLabsComparisonVm -Spec $spec -Hardware $hardware -Token $token
            $trial.VMId = "$($vm.Id)"; $trial.Status = 'Starting'
            $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
            Start-MemLabsOobeRepairVm -VM $vm
            $trial.Status = 'Collecting'
            $trial['DiagnosticDestination'] = Join-Path $spec.Root 'Evidence'
            $diagnostic = Invoke-MemLabsComparisonDiagnostics -VM $vm -GuestCredential $GuestCredential -Destination $trial.DiagnosticDestination
            Copy-Item -LiteralPath $diagnostic.ArchivePath -Destination (Join-Path $reportRoot "$($spec.Label)-Diagnostics.zip") -ErrorAction Stop
            $trial['Archive'] = "$($spec.Label)-Diagnostics.zip"
            $trial.Evidence = Read-MemLabsComparisonDiagnostics -Archive $diagnostic.ArchivePath -ExpectedVmId $vm.Id
            $trial.Status = 'Collected'
            if (-not $KeepTrialVMs) { Remove-MemLabsComparisonVm -VM $vm -Spec $spec -Token $token; $trial.Cleaned = $true }
            $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
        }
        Write-Host 'Step 4/4: comparing the observed readiness results and verifying source preservation.'
        $finalHash = Invoke-MemLabsComparisonWorker -TimeoutSeconds 600 -Operation 'Rechecking the unchanged source hash' -Arguments @($source) -Block {
            param($Source)
            [pscustomobject]@{ Hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash }
        }
        if ($finalHash.Hash -ine $report.SourceHash) { throw 'The source image changed during the test; the comparison is invalid.' }
        $control = $report.Trials[0].Evidence.Observation; $test = $report.Trials[1].Evidence.Observation
        $report.Verdict = if ($control -eq 'FirstLogonStall' -and $test -eq 'Ready') { 'CleanedCopyReadyControlBlocked: supports the cache hypothesis in this trial, not proof of a general fix' }
        elseif ($control -eq 'Ready' -and $test -eq 'Ready') { 'BothReady: the original failure was not reproduced' }
        elseif ($control -eq 'FirstLogonStall' -and $test -eq 'FirstLogonStall') { 'BothBlocked: cache removal alone did not resolve the observed condition' }
        elseif ($control -eq 'Ready' -and $test -eq 'FirstLogonStall') { 'ControlReadyCleanedCopyBlocked: do not adopt this cache change' }
        else { 'Inconclusive: at least one guest had other/transitioning setup state at observation; inspect the collected evidence' }
        $report.Status = 'Completed'
    }
    catch {
        $failure = $_; $report.Status = 'Failed'; $report.Errors.Add($_.Exception.Message)
        foreach ($trial in $report.Trials) {
            if (-not $trial.Contains('DiagnosticDestination') -or -not [IO.Directory]::Exists($trial.DiagnosticDestination) -or $trial.Contains('Archive')) { continue }
            try {
                $directories = @(Get-ChildItem -LiteralPath $trial.DiagnosticDestination -Directory -ErrorAction Stop |
                    Where-Object Name -match ('^' + [regex]::Escape($trial.Name) + '-SetupFailure-\d{8}-\d{6}-[a-f0-9]{8}$'))
                if ($directories.Count -ne 1) { throw 'No unique owned partial diagnostic directory was found.' }
                $partial = Get-MemLabsOfflineSetupSourcePath -WindowsRoot $trial.DiagnosticDestination `
                    -RelativePath "$($directories[0].Name)\$($directories[0].Name).zip"
                if (-not $partial) { throw 'The owned partial diagnostic archive is absent.' }
                Copy-Item -LiteralPath $partial -Destination (Join-Path $reportRoot "$($trial.Label)-Diagnostics.zip") -ErrorAction Stop
                $trial['Archive'] = "$($trial.Label)-Diagnostics.zip"
            }
            catch { $report.Errors.Add("Preserve partial $($trial.Label) diagnostics: $($_.Exception.Message)") }
        }
        Write-Warning 'The comparison stopped. Any unverified resources are retained at the reported paths; the original VM was not changed.'
    }
    $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
    $archive = Join-Path $workspace 'FirstLogonComparison.zip'
    Compress-Archive -Path (Join-Path $reportRoot '*') -DestinationPath $archive -ErrorAction Stop
    Write-Host "Comparison archive: $archive"
    Write-Host "Result: $($report.Verdict)"
    if ($failure) { throw "Image comparison failed: $($failure.Exception.Message). Report: $archive" }
    [pscustomobject]@{ Status = $report.Status; Verdict = $report.Verdict; ArchivePath = $archive; Workspace = $workspace }
}

$imageComparisonParameters = @{} + $PSBoundParameters
. Import-MemLabsImageComparisonHelpers
if ($WhatIfPreference) { Invoke-MemLabsFirstLogonImageComparison @imageComparisonParameters; return }
$mutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $held = $true; Write-Warning 'Acquiring the abandoned MemLabs host mutation lease.' }
    if (-not $held) { throw 'Stop the active MemLabs deployment/test loop before running this comparison; no experiment was started.' }
    Invoke-MemLabsFirstLogonImageComparison @imageComparisonParameters
}
finally {
    try { if ($held) { $mutex.ReleaseMutex() } }
    finally { $mutex.Dispose() }
}
