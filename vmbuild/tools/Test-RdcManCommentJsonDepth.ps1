<#
.SYNOPSIS
    Verifies that RDCMan comments preserve nested VM metadata without JSON depth warnings.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-RdcManJson {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

$sourcePath = Join-Path $RootPath 'common\Common.RdcMan.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$commentSerializers = [regex]::Matches(
    $source,
    '\$comment\s*=\s*\$c\s*\|\s*ConvertTo-Json\s+-Depth\s+10',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
$bareCommentSerializers = [regex]::Matches(
    $source,
    '\$comment\s*=\s*\$c\s*\|\s*ConvertTo-Json(?!\s+-Depth)',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
Assert-RdcManJson ($commentSerializers.Count -eq 2) 'Known and unknown VM comments use explicit JSON depth 10'
Assert-RdcManJson ($bareCommentSerializers.Count -eq 0) 'No RDCMan VM comment uses the default JSON depth'

$vm = [pscustomobject]@{
    VmName = 'TEST-VM'
    VmNote = [pscustomobject]@{
        Network = [pscustomobject]@{
            Adapter = [pscustomobject]@{
                Metadata = [pscustomobject]@{ Marker = 'deep-marker' }
            }
        }
    }
}
$copy = [pscustomobject]@{}
foreach ($property in $vm | Get-Member -MemberType NoteProperty | Where-Object { $null -ne $vm."$($_.Name)" }) {
    $copy | Add-Member -MemberType NoteProperty -Name $property.Name -Value $vm."$($property.Name)" -Force
}

$defaultWarnings = @()
$defaultJson = $copy | ConvertTo-Json -WarningVariable defaultWarnings
$defaultRoundTrip = $defaultJson | ConvertFrom-Json
$deepWarnings = @()
$deepJson = $copy | ConvertTo-Json -Depth 10 -WarningVariable deepWarnings
$deepRoundTrip = $deepJson | ConvertFrom-Json

Assert-RdcManJson ($deepWarnings.Count -eq 0) 'Depth 10 emits no JSON truncation warning'
Assert-RdcManJson ($deepRoundTrip.VmNote.Network.Adapter.Metadata.Marker -eq 'deep-marker') 'Depth 10 preserves deeply nested VM metadata'
Assert-RdcManJson ($defaultRoundTrip.VmNote.Network.Adapter.Metadata.Marker -ne 'deep-marker') 'Default depth control loses deeply nested VM metadata'
if ($PSVersionTable.PSEdition -eq 'Core') {
    Assert-RdcManJson ($defaultWarnings.Count -gt 0 -and $defaultWarnings[0] -match 'serialization has exceeded the set depth of 2') 'PowerShell 7 control reproduces the reported warning'
}
else {
    Assert-RdcManJson ($defaultWarnings.Count -eq 0) 'Windows PowerShell 5.1 control confirms silent default-depth truncation'
}

if ($script:Failures -ne 0) { exit 1 }
exit 0
