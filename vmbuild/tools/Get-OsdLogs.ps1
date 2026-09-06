#requires -Version 5.1
<#
.SYNOPSIS
    Collects every useful OSD/task-sequence log generation from a MemLabs VM.

.DESCRIPTION
    Uses PowerShell Direct through Get-VmSession, so collection does not depend
    on guest DNS, IP routing, SMB, or the Windows firewall. It snapshots locked
    logs with FileShare.ReadWrite/Delete, preserves each source path in a JSON
    manifest, and verifies copied byte counts. Zero-byte files are reported but
    never presented as successful evidence.

    The collector checks WinPE, transition, full-OS ConfigMgr client,
    application enforcement, content transfer, client policy, CCM setup, and
    Windows Setup/Panther locations. It also captures hostname, network state,
    and the task-sequence registry key when available.

    PowerShell Direct normally becomes available only after Windows Setup has
    produced a usable full OS. For a failure that remains entirely in WinPE,
    enable F8 command support and copy the WinPE log before reboot.

.PARAMETER VMName
    Hyper-V VM name, for example OSD1.

.PARAMETER DomainName
    Domain FQDN used by the MemLabs credential ladder. If omitted, resolves it
    from the VM inventory/note.

.PARAMETER DestinationRoot
    Host destination root. Defaults to vmbuild\logs\osd-investigation.

.PARAMETER WaitMinutes
    Retry PowerShell Direct until it becomes available for this many minutes.
    Default 0 performs one attempt.

.EXAMPLE
    .\Get-OsdLogs.ps1 -VMName OSD1

.EXAMPLE
    .\Get-OsdLogs.ps1 -VMName OSD1 -DomainName fabrikam.com -WaitMinutes 20
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VMName,

    [string] $DomainName,

    [string] $DestinationRoot,

    [ValidateRange(0, 1440)]
    [int] $WaitMinutes = 0
)

$ErrorActionPreference = 'Stop'
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw "Common.ps1 not found at $commonPath" }

$commonBytes = [IO.File]::ReadAllBytes($commonPath)
if ($commonBytes.Length -lt 3 -or $commonBytes[0] -ne 0xEF -or $commonBytes[1] -ne 0xBB -or $commonBytes[2] -ne 0xBF) {
    throw "Common.ps1 is missing its UTF-8 BOM: $commonPath"
}
. $commonPath -InJob

if (-not $Common -or -not $Common.LocalAdmin) {
    throw 'MemLabs local administrator credentials are not initialized. Run from the same elevated host account used to build the lab.'
}

$inventoryVm = @(Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VMName }) | Select-Object -First 1
if (-not $DomainName -and $inventoryVm -and $inventoryVm.domain) { $DomainName = "$($inventoryVm.domain)" }
if (-not $DomainName) {
    try {
        $note = Get-VMNote -VMName $VMName -ErrorAction Stop
        if ($note.domain) { $DomainName = "$($note.domain)" }
    }
    catch { }
}
if (-not $DomainName) { $DomainName = 'WORKGROUP' }

if (-not $DestinationRoot) {
    $DestinationRoot = Join-Path $vmbuildRoot 'logs\osd-investigation'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destination = Join-Path (Join-Path $DestinationRoot $VMName) $stamp
New-Item -ItemType Directory -Path $destination -Force | Out-Null

Write-Host "Collecting OSD logs: VM=$VMName domain=$DomainName" -ForegroundColor Cyan
Write-Host "Destination: $destination" -ForegroundColor DarkGray

$deadline = (Get-Date).AddMinutes($WaitMinutes)
$session = $null
do {
    try { $session = Get-VmSession -VmName $VMName -VmDomainName $DomainName -MaxRetries 1 -Quiet } catch { $session = $null }
    if ($session) { break }
    if ((Get-Date) -ge $deadline) { break }
    Write-Host 'PowerShell Direct is not available yet; retrying in 15 seconds...' -ForegroundColor DarkYellow
    Start-Sleep -Seconds 15
} while ($true)

if (-not $session) {
    throw "Could not create a PowerShell Direct session to '$VMName'. If it is still in WinPE, press F8 and copy X:\Windows\Temp\SMSTSLog\smsts.log before reboot; otherwise rerun elevated with -WaitMinutes."
}

$remoteStage = "C:\Windows\Temp\MemLabs-OsdLogs-$([guid]::NewGuid().ToString('N'))"
$collectScript = {
    param([string] $StagePath)

    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path $StagePath -Force | Out-Null

    $candidates = @(
        @{ Label = 'winpe-windows-temp-smsts'; Path = 'X:\Windows\Temp\SMSTSLog\smsts.log' },
        @{ Label = 'winpe-windows-temp-smsts-old'; Path = 'X:\Windows\Temp\SMSTSLog\smsts.lo_' },
        @{ Label = 'winpe-root-smsts'; Path = 'X:\SMSTSLog\smsts.log' },
        @{ Label = 'winpe-root-smsts-old'; Path = 'X:\SMSTSLog\smsts.lo_' },
        @{ Label = 'transition-tasksequence-smsts'; Path = 'C:\_SMSTaskSequence\Logs\Smstslog\smsts.log' },
        @{ Label = 'transition-tasksequence-smsts-old'; Path = 'C:\_SMSTaskSequence\Logs\Smstslog\smsts.lo_' },
        @{ Label = 'transition-windows-temp-smsts'; Path = 'C:\Windows\Temp\SMSTSLog\smsts.log' },
        @{ Label = 'transition-windows-temp-smsts-old'; Path = 'C:\Windows\Temp\SMSTSLog\smsts.lo_' },
        @{ Label = 'fullos-client-smsts'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\smsts.log' },
        @{ Label = 'fullos-client-smsts-old'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\smsts.lo_' },
        @{ Label = 'fullos-client-root-smsts'; Path = 'C:\Windows\CCM\Logs\smsts.log' },
        @{ Label = 'fullos-loadstate'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\loadstate.log' },
        @{ Label = 'fullos-loadstate-progress'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\loadstateprogress.log' },
        @{ Label = 'fullos-scanstate'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\scanstate.log' },
        @{ Label = 'fullos-scanstate-progress'; Path = 'C:\Windows\CCM\Logs\SMSTSLog\scanstateprogress.log' },
        @{ Label = 'appenforce'; Path = 'C:\Windows\CCM\Logs\AppEnforce.log' },
        @{ Label = 'appdiscovery'; Path = 'C:\Windows\CCM\Logs\AppDiscovery.log' },
        @{ Label = 'cas'; Path = 'C:\Windows\CCM\Logs\CAS.log' },
        @{ Label = 'content-transfer-manager'; Path = 'C:\Windows\CCM\Logs\ContentTransferManager.log' },
        @{ Label = 'data-transfer-service'; Path = 'C:\Windows\CCM\Logs\DataTransferService.log' },
        @{ Label = 'location-services'; Path = 'C:\Windows\CCM\Logs\LocationServices.log' },
        @{ Label = 'client-location'; Path = 'C:\Windows\CCM\Logs\ClientLocation.log' },
        @{ Label = 'policy-agent'; Path = 'C:\Windows\CCM\Logs\PolicyAgent.log' },
        @{ Label = 'policy-evaluator'; Path = 'C:\Windows\CCM\Logs\PolicyEvaluator.log' },
        @{ Label = 'ccmexec'; Path = 'C:\Windows\CCM\Logs\CcmExec.log' },
        @{ Label = 'ccmsetup'; Path = 'C:\Windows\ccmsetup\Logs\ccmsetup.log' },
        @{ Label = 'ccmsetup-client-msi'; Path = 'C:\Windows\ccmsetup\Logs\client.msi.log' },
        @{ Label = 'panther-setupact'; Path = 'C:\Windows\Panther\setupact.log' },
        @{ Label = 'panther-setuperr'; Path = 'C:\Windows\Panther\setuperr.log' },
        @{ Label = 'panther-unattendgc-setupact'; Path = 'C:\Windows\Panther\UnattendGC\setupact.log' },
        @{ Label = 'panther-unattendgc-setuperr'; Path = 'C:\Windows\Panther\UnattendGC\setuperr.log' }
    )

    $records = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($candidate in $candidates) {
        $index++
        $sourcePath = $candidate.Path
        $record = [ordered]@{
            Label             = $candidate.Label
            SourcePath        = $sourcePath
            Status            = 'Missing'
            SourceLength      = $null
            SourceLastWriteUtc = $null
            StagedPath        = $null
            CopiedLength      = $null
            Error             = $null
        }
        try {
            if (-not (Test-Path -LiteralPath $sourcePath)) {
                $records.Add([pscustomobject]$record)
                continue
            }
            $sourceItem = Get-Item -LiteralPath $sourcePath -Force
            $record.SourceLength = [int64]$sourceItem.Length
            $record.SourceLastWriteUtc = $sourceItem.LastWriteTimeUtc.ToString('o')
            if ($sourceItem.Length -eq 0) {
                $record.Status = 'ZeroLength'
                $records.Add([pscustomobject]$record)
                continue
            }

            $safeName = ('{0:D2}-{1}{2}' -f $index, $candidate.Label, $sourceItem.Extension)
            $stagedPath = Join-Path $StagePath $safeName
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $sourceStream = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $destinationStream = [IO.File]::Open($stagedPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $sourceStream.CopyTo($destinationStream) } finally { $destinationStream.Dispose() }
            }
            finally { $sourceStream.Dispose() }

            $copiedItem = Get-Item -LiteralPath $stagedPath
            $record.StagedPath = $stagedPath
            $record.CopiedLength = [int64]$copiedItem.Length
            $record.Status = if ($copiedItem.Length -eq $sourceItem.Length -and $copiedItem.Length -gt 0) { 'Copied' } else { 'LengthMismatch' }
        }
        catch {
            $record.Status = 'CopyError'
            $record.Error = $_.Exception.Message
        }
        $records.Add([pscustomobject]$record)
    }

    $systemLines = @(
        "CapturedUtc=$([DateTime]::UtcNow.ToString('o'))"
        "ComputerName=$env:COMPUTERNAME"
        "UserDnsDomain=$env:USERDNSDOMAIN"
        "PowerShell=$($PSVersionTable.PSVersion)"
    )
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $systemLines += "Domain=$($cs.Domain)"
        $systemLines += "PartOfDomain=$($cs.PartOfDomain)"
    }
    catch { $systemLines += "ComputerSystemError=$($_.Exception.Message)" }
    [IO.File]::WriteAllLines((Join-Path $StagePath 'system.txt'), $systemLines)

    try { (& ipconfig.exe /all 2>&1) | Out-File (Join-Path $StagePath 'ipconfig-all.txt') -Encoding utf8 -Width 4096 }
    catch { "ipconfig failed: $($_.Exception.Message)" | Out-File (Join-Path $StagePath 'ipconfig-all.txt') -Encoding utf8 }

    try {
        Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop |
            Where-Object { $_.IPEnabled -or $_.MACAddress } |
            Select-Object Description, MACAddress, DHCPEnabled, IPAddress, IPSubnet, DefaultIPGateway, DNSServerSearchOrder, DNSDomain |
            Format-List | Out-File (Join-Path $StagePath 'network-cim.txt') -Encoding utf8 -Width 4096
    }
    catch { "network CIM failed: $($_.Exception.Message)" | Out-File (Join-Path $StagePath 'network-cim.txt') -Encoding utf8 }

    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\SMS\Task Sequence') {
            Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Task Sequence' |
                Format-List * | Out-File (Join-Path $StagePath 'task-sequence-registry.txt') -Encoding utf8 -Width 4096
        }
        else {
            'Task Sequence registry key is absent.' | Out-File (Join-Path $StagePath 'task-sequence-registry.txt') -Encoding utf8
        }
    }
    catch { "Task Sequence registry read failed: $($_.Exception.Message)" | Out-File (Join-Path $StagePath 'task-sequence-registry.txt') -Encoding utf8 }

    $postPxeState = New-Object System.Collections.Generic.List[string]
    $postPxeState.Add("CapturedUtc=$([DateTime]::UtcNow.ToString('o'))")
    $postPxeState.Add("ComputerName=$env:COMPUTERNAME")

    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            $protectorTypes = @($volume.KeyProtector | ForEach-Object { $_.KeyProtectorType } | Where-Object { $_ })
            $postPxeState.Add("BitLocker.VolumeStatus=$($volume.VolumeStatus)")
            $postPxeState.Add("BitLocker.ProtectionStatus=$($volume.ProtectionStatus)")
            $postPxeState.Add("BitLocker.EncryptionPercentage=$($volume.EncryptionPercentage)")
            $postPxeState.Add("BitLocker.KeyProtectors=$(if ($protectorTypes.Count) { $protectorTypes -join ',' } else { '[none]' })")
        }
        else {
            $postPxeState.Add('BitLocker=NOT_MEASURED (Get-BitLockerVolume unavailable)')
        }
    }
    catch { $postPxeState.Add("BitLocker=NOT_MEASURED ($($_.Exception.Message))") }

    try {
        $office = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
        if ($office -and $office.VersionToReport) {
            $postPxeState.Add("Office.Installed=True")
            $postPxeState.Add("Office.Version=$($office.VersionToReport)")
            $postPxeState.Add("Office.Channel=$($office.UpdateChannel)")
        }
        else {
            $postPxeState.Add('Office.Installed=False')
        }
    }
    catch { $postPxeState.Add("Office=NOT_MEASURED ($($_.Exception.Message))") }

    try {
        $appId = '55c92734-d682-4d71-983e-d6ec3f16059f'
        $license = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationId='$appId' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Select-Object -First 1
        if ($license) {
            $postPxeState.Add("Activation.LicenseStatus=$($license.LicenseStatus)")
            $postPxeState.Add("Activation.Sku=$($license.Name)")
            $postPxeState.Add("Activation.PartialProductKey=$($license.PartialProductKey)")
        }
        else {
            $postPxeState.Add('Activation=NOT_MEASURED (no active Windows licensing product)')
        }
    }
    catch { $postPxeState.Add("Activation=NOT_MEASURED ($($_.Exception.Message))") }

    $statePaths = [ordered]@{
        'Bootstrap.Version' = 'C:\ProgramData\MemLabs\OSDBootstrap\Version.txt'
        'BgInfo.Executable' = 'C:\staging\bginfo\bginfo.exe'
        'BgInfo.Template' = 'C:\staging\bginfo\CLIENT.bgi'
        'BgInfo.StartupShortcut' = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\MemLabs BGInfo.lnk'
        'LogMachine.Executable' = 'C:\tools\LogMachine\LogMachine.exe'
        'Desktop.SccmApplet' = 'C:\Users\Public\Desktop\SCCM Control Panel Applet.lnk'
        'Desktop.ClientLogs' = 'C:\Users\Public\Desktop\Client Logs.lnk'
    }
    foreach ($statePath in $statePaths.GetEnumerator()) {
        $exists = Test-Path -LiteralPath $statePath.Value
        $postPxeState.Add("$($statePath.Key).Exists=$exists")
        if ($statePath.Key -eq 'Bootstrap.Version' -and $exists) {
            try { $postPxeState.Add("Bootstrap.Version.Value=$((Get-Content -LiteralPath $statePath.Value -Raw).Trim())") }
            catch { $postPxeState.Add("Bootstrap.Version.Value=NOT_MEASURED ($($_.Exception.Message))") }
        }
    }
    try {
        $shortcutTask = Get-ScheduledTask -TaskName 'EnableLogMachine' -ErrorAction SilentlyContinue
        $postPxeState.Add("Desktop.RefreshTask.Exists=$([bool]$shortcutTask)")
        if ($shortcutTask) { $postPxeState.Add("Desktop.RefreshTask.State=$($shortcutTask.State)") }
    }
    catch { $postPxeState.Add("Desktop.RefreshTask=NOT_MEASURED ($($_.Exception.Message))") }
    [IO.File]::WriteAllLines((Join-Path $StagePath 'post-pxe-state.txt'), $postPxeState.ToArray())

    return $records.ToArray()
}

$records = @()
$copyFailures = New-Object System.Collections.Generic.List[string]
try {
    $records = @(Invoke-Command -Session $session -ScriptBlock $collectScript -ArgumentList $remoteStage)
    foreach ($record in @($records | Where-Object { $_.Status -eq 'Copied' })) {
        $hostPath = Join-Path $destination (Split-Path $record.StagedPath -Leaf)
        try {
            Copy-Item -FromSession $session -LiteralPath $record.StagedPath -Destination $hostPath -Force -ErrorAction Stop
            $hostItem = Get-Item -LiteralPath $hostPath
            if ($hostItem.Length -ne [int64]$record.CopiedLength -or $hostItem.Length -eq 0) {
                throw "host copy length $($hostItem.Length) does not match guest snapshot $($record.CopiedLength)"
            }
        }
        catch { $copyFailures.Add("$($record.SourcePath): $($_.Exception.Message)") }
    }

    foreach ($diagnosticName in @('system.txt', 'ipconfig-all.txt', 'network-cim.txt', 'task-sequence-registry.txt', 'post-pxe-state.txt')) {
        $remotePath = Join-Path $remoteStage $diagnosticName
        try { Copy-Item -FromSession $session -LiteralPath $remotePath -Destination (Join-Path $destination $diagnosticName) -Force -ErrorAction Stop }
        catch { $copyFailures.Add("${remotePath}: $($_.Exception.Message)") }
    }
}
finally {
    try { Invoke-Command -Session $session -ScriptBlock { param($Path); Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $remoteStage | Out-Null } catch { }
}

$manifest = [ordered]@{
    SchemaVersion = 1
    CollectedUtc  = [DateTime]::UtcNow.ToString('o')
    VMName        = $VMName
    DomainName    = $DomainName
    Destination   = $destination
    Files         = $records
    HostCopyErrors = $copyFailures.ToArray()
}
$manifestPath = Join-Path $destination 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$copied = @($records | Where-Object Status -eq 'Copied')
$zero = @($records | Where-Object Status -eq 'ZeroLength')
$errors = @($records | Where-Object Status -in @('CopyError', 'LengthMismatch'))
Write-Host "Copied $($copied.Count) non-empty source log(s); zero-byte=$($zero.Count); guest-copy-errors=$($errors.Count); host-copy-errors=$($copyFailures.Count)." -ForegroundColor $(if ($copyFailures.Count -or $errors.Count) { 'DarkYellow' } else { 'Green' })
foreach ($record in $copied) { Write-Host "  $($record.Label): $($record.SourceLength) bytes <- $($record.SourcePath)" -ForegroundColor Gray }
foreach ($record in $zero) { Write-Host "  ZERO-BYTE (not evidence): $($record.SourcePath)" -ForegroundColor DarkYellow }
foreach ($record in $errors) { Write-Host "  $($record.Status): $($record.SourcePath) -- $($record.Error)" -ForegroundColor Red }
foreach ($copyError in $copyFailures) { Write-Host "  HOST COPY ERROR: $copyError" -ForegroundColor Red }
Write-Host "Manifest: $manifestPath" -ForegroundColor Cyan

if ($copied.Count -eq 0 -or $copyFailures.Count -gt 0 -or $errors.Count -gt 0) { exit 1 }
