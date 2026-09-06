# Initializes only data disks explicitly assigned to the current OSD client.
# Safe for required-policy reruns: an existing matching NTFS volume is verified,
# while an unexpected occupied letter or non-NTFS filesystem is never formatted.
function Initialize-MemLabsOsdDataDisks {
    [CmdletBinding()]
    param(
        [object[]] $Entries
    )

    $entriesToApply = @($Entries | Where-Object { $null -ne $_ } | Sort-Object DiskIndex)
    if ($entriesToApply.Count -eq 0) { return @() }
    Import-Module Storage -ErrorAction Stop

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entriesToApply) {
        $letter = "$($entry.Letter)".Trim().TrimEnd(':').ToUpperInvariant()
        $sizeBytes = [int64]$entry.SizeBytes
        $label = "$($entry.Label)"
        if ($letter -notmatch '^[E-Y]$' -or $letter -eq 'S') {
            throw "Configured OSD data-disk letter '$letter' is outside E:Y or is reserved."
        }
        if ($sizeBytes -lt 1GB) { throw "Configured OSD data disk $letter`: has invalid size $sizeBytes bytes." }
        if (-not $label) { $label = "DATA_$letter" }

        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
        $disk = $null
        if ($volume) {
            $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            if ($disk.IsBoot -or $disk.IsSystem -or [math]::Abs([int64]$disk.Size - $sizeBytes) -gt 1MB) {
                throw "Drive $letter`: is occupied by unexpected disk #$($disk.Number) ($($disk.Size) bytes, requested $sizeBytes); refusing to format it."
            }
            if ($volume.FileSystem -and $volume.FileSystem -ne 'NTFS') {
                throw "Drive $letter`: already has filesystem '$($volume.FileSystem)'; refusing to replace it with NTFS."
            }
            if (-not $volume.FileSystem) {
                Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
            }
        }
        else {
            $rawDisk = Get-Disk -ErrorAction Stop | Where-Object {
                $_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and -not $_.IsSystem -and
                [math]::Abs([int64]$_.Size - $sizeBytes) -le 1MB
            } | Sort-Object Number | Select-Object -First 1
            if ($rawDisk) {
                $disk = $rawDisk
                $partition = $rawDisk | Initialize-Disk -PartitionStyle GPT -PassThru -ErrorAction Stop |
                    New-Partition -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
                Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
            }
            else {
                # Recover a policy run interrupted after GPT/partition creation
                # but before assigning the requested letter or formatting.
                $gptDisk = Get-Disk -ErrorAction Stop | Where-Object {
                    $_.PartitionStyle -eq 'GPT' -and -not $_.IsBoot -and -not $_.IsSystem -and
                    [math]::Abs([int64]$_.Size - $sizeBytes) -le 1MB
                } | Sort-Object Number | Where-Object {
                    @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.DriveLetter -and $_.Size -gt 1GB -and $_.Type -notin @('Reserved', 'System') }).Count -gt 0
                } | Select-Object -First 1
                if (-not $gptDisk) {
                    throw "No RAW or recoverable GPT data disk matches $letter`: ($sizeBytes bytes)."
                }
                $disk = $gptDisk
                $partition = Get-Partition -DiskNumber $gptDisk.Number -ErrorAction Stop |
                    Where-Object { -not $_.DriveLetter -and $_.Size -gt 1GB -and $_.Type -notin @('Reserved', 'System') } |
                    Sort-Object Size -Descending | Select-Object -First 1
                Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
                    -NewDriveLetter $letter -ErrorAction Stop
                $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($volume -and $volume.FileSystem -and $volume.FileSystem -ne 'NTFS') {
                    throw "Recovered drive $letter`: has filesystem '$($volume.FileSystem)'; refusing to replace it."
                }
                if (-not $volume -or -not $volume.FileSystem) {
                    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
                    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
                }
            }
        }

        $finalVolume = Get-Volume -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        $finalPartition = Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        $finalDisk = Get-Disk -Number $finalPartition.DiskNumber -ErrorAction Stop
        if ($finalVolume.FileSystem -ne 'NTFS' -or
            [math]::Abs([int64]$finalDisk.Size - $sizeBytes) -gt 1MB -or
            $finalDisk.IsBoot -or $finalDisk.IsSystem) {
            throw "OSD data disk $letter`: failed verification (disk=$($finalDisk.Number), fs='$($finalVolume.FileSystem)', size=$($finalDisk.Size))."
        }
        if ($finalVolume.FileSystemLabel -ne $label) {
            Set-Volume -DriveLetter $letter -NewFileSystemLabel $label -ErrorAction Stop
            $finalVolume = Get-Volume -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1
        }
        New-Item -Path "$letter`:\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction Stop | Out-Null
        $results.Add([pscustomobject]@{
                Letter = $letter
                DiskNumber = $finalDisk.Number
                SizeBytes = [int64]$finalDisk.Size
                FileSystem = "$($finalVolume.FileSystem)"
                Label = "$($finalVolume.FileSystemLabel)"
            })
    }
    return $results.ToArray()
}