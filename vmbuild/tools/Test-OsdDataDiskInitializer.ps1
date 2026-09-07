# Focused, non-destructive tests for Initialize-MemLabsOsdDataDisks.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Disks = @()
$script:Partitions = @()
$script:Volumes = @()
$script:FormatCalls = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function New-TestDisk {
    param([int] $Number, [int64] $Size, [string] $Style = 'RAW', [bool] $Boot = $false, [bool] $System = $false)
    [pscustomobject]@{ Number = $Number; Size = $Size; PartitionStyle = $Style; IsBoot = $Boot; IsSystem = $System }
}
function Reset-TestStorage {
    $script:Disks = @(New-TestDisk -Number 0 -Size 64GB -Style GPT -Boot $true -System $true)
    $script:Partitions = @([pscustomobject]@{ DiskNumber = 0; PartitionNumber = 3; DriveLetter = 'C'; Size = 63GB; Type = 'Basic' })
    $script:Volumes = @([pscustomobject]@{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'; Size = 63GB })
    $script:FormatCalls = 0
}

# Storage cmdlet doubles. Functions outrank cmdlets during these tests, so no
# real host disk can be changed even when the Storage module is installed.
function Import-Module { [CmdletBinding()] param($Name) }
function Get-Disk {
    [CmdletBinding()]
    param([int] $Number)
    if ($PSBoundParameters.ContainsKey('Number')) { return @($script:Disks | Where-Object Number -eq $Number) }
    return $script:Disks
}
function Get-Partition {
    [CmdletBinding()]
    param([string] $DriveLetter, [int] $DiskNumber)
    if ($PSBoundParameters.ContainsKey('DriveLetter')) { return @($script:Partitions | Where-Object DriveLetter -eq $DriveLetter) }
    if ($PSBoundParameters.ContainsKey('DiskNumber')) { return @($script:Partitions | Where-Object DiskNumber -eq $DiskNumber) }
    return $script:Partitions
}
function Get-Volume {
    [CmdletBinding()]
    param([string] $DriveLetter)
    if ($PSBoundParameters.ContainsKey('DriveLetter')) { return @($script:Volumes | Where-Object DriveLetter -eq $DriveLetter) }
    return $script:Volumes
}
function Initialize-Disk {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [string] $PartitionStyle, [switch] $PassThru)
    process { $InputObject.PartitionStyle = $PartitionStyle; return $InputObject }
}
function New-Partition {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject, [switch] $UseMaximumSize, [string] $DriveLetter)
    process {
        $partition = [pscustomobject]@{
            DiskNumber = $InputObject.Number
            PartitionNumber = 1
            DriveLetter = $DriveLetter
            Size = [int64]$InputObject.Size - 16MB
            Type = 'Basic'
        }
        $script:Partitions += $partition
        return $partition
    }
}
function Format-Volume {
    [CmdletBinding()]
    param($Partition, [string] $FileSystem, [string] $NewFileSystemLabel, [switch] $Confirm, [switch] $Force)
    $script:FormatCalls++
    $volume = @($script:Volumes | Where-Object DriveLetter -eq $Partition.DriveLetter) | Select-Object -First 1
    if (-not $volume) {
        $volume = [pscustomobject]@{ DriveLetter = $Partition.DriveLetter; FileSystem = ''; FileSystemLabel = ''; Size = $Partition.Size }
        $script:Volumes += $volume
    }
    $volume.FileSystem = $FileSystem
    $volume.FileSystemLabel = $NewFileSystemLabel
    return $volume
}
function Set-Partition {
    [CmdletBinding()]
    param([int] $DiskNumber, [int] $PartitionNumber, [string] $NewDriveLetter)
    $partition = @($script:Partitions | Where-Object { $_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber }) | Select-Object -First 1
    $partition.DriveLetter = $NewDriveLetter
}
function Set-Volume {
    [CmdletBinding()]
    param([string] $DriveLetter, [string] $NewFileSystemLabel)
    $volume = @($script:Volumes | Where-Object DriveLetter -eq $DriveLetter) | Select-Object -First 1
    $volume.FileSystemLabel = $NewFileSystemLabel
}
function New-Item {
    [CmdletBinding()]
    param([string] $Path, [string] $ItemType, [switch] $Force)
    return [pscustomobject]@{ FullName = $Path }
}

$initializerPath = Join-Path $RootPath 'DSC\phases\Initialize-OsdDataDisks.ps1'
$initializerText = [IO.File]::ReadAllText($initializerPath).TrimStart([char]0xFEFF)
. ([scriptblock]::Create($initializerText))
Write-Host "engine : $($PSVersionTable.PSVersion)"

Reset-TestStorage
$result = @(Initialize-MemLabsOsdDataDisks -Entries @())
Assert-Equal 0 $result.Count 'zero configured disks is an explicit no-op'
Assert-Equal 0 $script:FormatCalls 'zero-disk plan formats nothing'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB
$script:Disks += New-TestDisk -Number 2 -Size 20GB
$entries = @(
    [pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }
    [pscustomobject]@{ DiskIndex = 1; Letter = 'F'; SizeBytes = [int64](20GB); Label = 'DATA_1' }
)
$result = @(Initialize-MemLabsOsdDataDisks -Entries $entries)
Assert-Equal 'E:1,F:2' (($result | ForEach-Object { "$($_.Letter):$($_.DiskNumber)" }) -join ',') 'same-size RAW disks map by attachment order'
Assert-Equal 'GPT,GPT' (($script:Disks | Where-Object Number -in 1, 2).PartitionStyle -join ',') 'RAW data disks become GPT'
Assert-Equal 'DATA_0,DATA_1' (($script:Volumes | Where-Object DriveLetter -in 'E', 'F').FileSystemLabel -join ',') 'data volumes receive deterministic labels'
Assert-Equal 'GPT' ($script:Disks | Where-Object Number -eq 0).PartitionStyle 'system disk remains untouched'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB -Style GPT
$script:Partitions += [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'E'; Size = 19GB; Type = 'Basic' }
$script:Volumes += [pscustomobject]@{ DriveLetter = 'E'; FileSystem = 'NTFS'; FileSystemLabel = 'DATA_0'; Size = 19GB }
$result = @(Initialize-MemLabsOsdDataDisks -Entries @([pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }))
Assert-Equal 1 $result.Count 'existing compliant volume is accepted'
Assert-Equal 0 $script:FormatCalls 'existing compliant volume is not reformatted'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB -Style GPT
$script:Partitions += [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = 'E'; Size = 19GB; Type = 'Basic' }
$script:Volumes += [pscustomobject]@{ DriveLetter = 'E'; FileSystem = 'ReFS'; FileSystemLabel = 'Existing'; Size = 19GB }
$refused = $false
try { Initialize-MemLabsOsdDataDisks -Entries @([pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }) | Out-Null }
catch { $refused = $_.Exception.Message -like "*filesystem 'ReFS'*refusing*" }
Assert-Equal $true $refused 'existing non-NTFS volume is refused'
Assert-Equal 0 $script:FormatCalls 'non-NTFS refusal never formats the occupied volume'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB -Style GPT
$script:Partitions += [pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; DriveLetter = $null; Size = 19GB; Type = 'Basic' }
$result = @(Initialize-MemLabsOsdDataDisks -Entries @([pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }))
Assert-Equal 'E' $result[0].Letter 'half-initialized GPT partition is recovered'
Assert-Equal 'NTFS' ($script:Volumes | Where-Object DriveLetter -eq 'E').FileSystem 'recovered partition is formatted NTFS'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB
$script:Disks += New-TestDisk -Number 9 -Size 30GB -Style GPT
$script:Partitions += [pscustomobject]@{ DiskNumber = 9; PartitionNumber = 1; DriveLetter = 'E'; Size = 29GB; Type = 'Basic' }
$script:Volumes += [pscustomobject]@{ DriveLetter = 'E'; FileSystem = 'NTFS'; FileSystemLabel = 'Other'; Size = 29GB }
$refused = $false
try { Initialize-MemLabsOsdDataDisks -Entries @([pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }) | Out-Null }
catch { $refused = $_.Exception.Message -like '*occupied by unexpected disk*' }
Assert-Equal $true $refused 'occupied requested letter is refused'
Assert-Equal 'RAW' ($script:Disks | Where-Object Number -eq 1).PartitionStyle 'occupied-letter refusal does not mutate matching RAW disk'

Reset-TestStorage
$script:Disks += New-TestDisk -Number 1 -Size 20GB -Style RAW -System $true
$refused = $false
try { Initialize-MemLabsOsdDataDisks -Entries @([pscustomobject]@{ DiskIndex = 0; Letter = 'E'; SizeBytes = [int64](20GB); Label = 'DATA_0' }) | Out-Null }
catch { $refused = $_.Exception.Message -like '*No RAW or recoverable GPT*' }
Assert-Equal $true $refused 'system disk is excluded from initialization candidates'
Assert-Equal 'RAW' ($script:Disks | Where-Object Number -eq 1).PartitionStyle 'excluded system disk remains RAW'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD data-disk initializer checks passed.'