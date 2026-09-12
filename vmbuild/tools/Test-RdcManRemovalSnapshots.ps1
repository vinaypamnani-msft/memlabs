<#
.SYNOPSIS
    Verifies byte-exact RDCMan snapshots and correlated remove-domain metadata.
#>
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "PASS  $Message" }
    else { $script:Failures++; Write-Host "FAIL  $Message" }
}
function Write-Log { param([string]$Message, [switch]$Warning, [switch]$LogOnly) }

$sourcePath = Join-Path $RootPath 'common\Common.Remove.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw "$sourcePath has $($errors.Count) parse error(s)." }
foreach ($name in 'Initialize-RdcManRemovalSnapshotDirectory', 'Save-RdcManRemovalSnapshot', 'Save-RdcManRemovalSnapshotManifest') {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $name definition, found $($definition.Count)." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-rdcman-removal-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
try {
    $snapshotDirectory = Join-Path $testRoot 'protected'
    $oldFile = Join-Path $snapshotDirectory 'expired.rdg'
    Assert-True (Initialize-RdcManRemovalSnapshotDirectory -Path $snapshotDirectory -RetentionDays 14) 'protected snapshot directory initializes'
    Set-Content -LiteralPath $oldFile -Value old
    (Get-Item -LiteralPath $oldFile).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-15)
    Assert-True (Initialize-RdcManRemovalSnapshotDirectory -Path $snapshotDirectory -RetentionDays 14) 'protected snapshot directory reinitializes'
    Assert-True (-not (Test-Path -LiteralPath $oldFile)) 'expired snapshots are removed by bounded retention'
    $acl = Get-Acl -LiteralPath $snapshotDirectory
    $allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    $unexpectedRules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowedSids })
    Assert-True ($acl.AreAccessRulesProtected -and $unexpectedRules.Count -eq 0) 'snapshot directory allows only current user, SYSTEM, and Administrators'

    $source = Join-Path $testRoot 'memlabs.rdg'
    $beforePath = Join-Path $snapshotDirectory 'before.rdg'
    $afterPath = Join-Path $snapshotDirectory 'after.rdg'
    $manifestPath = Join-Path $snapshotDirectory 'manifest.json'
    $beforeBytes = [Text.Encoding]::UTF8.GetBytes("<?xml version=`"1.0`"?><RDCMan><file><group><properties><name>remove.example</name></properties><server><properties><name>old</name></properties><logonCredentials><password>encrypted-value</password></logonCredentials></server></group></file></RDCMan>")
    [IO.File]::WriteAllBytes($source, $beforeBytes)
    $before = Save-RdcManRemovalSnapshot -SourcePath $source -SnapshotPath $beforePath -Stage before -RemovedDomainName 'remove.example'

    $afterBytes = [Text.Encoding]::Unicode.GetBytes("<?xml version=`"1.0`" encoding=`"utf-16`"?><RDCMan><file><group><properties><name>keep.example</name></properties></group></file></RDCMan>")
    [IO.File]::WriteAllBytes($source, $afterBytes)
    $after = Save-RdcManRemovalSnapshot -SourcePath $source -SnapshotPath $afterPath -Stage after -RemovedDomainName 'remove.example'
    $published = Save-RdcManRemovalSnapshotManifest -Path $manifestPath -DomainName 'remove.example' -CorrelationId 'correlation' -Snapshots @($before, $after) -RegenerationError ''
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    Assert-True ([Convert]::ToBase64String($beforeBytes) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($beforePath))) 'before snapshot preserves exact bytes'
    Assert-True ([Convert]::ToBase64String($afterBytes) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($afterPath))) 'after snapshot preserves exact bytes and encoding'
    Assert-True ($before.XmlValid -and $before.GroupCount -eq 1 -and $before.ServerCount -eq 1) 'before snapshot records XML structure'
    Assert-True ($after.XmlValid -and $after.GroupCount -eq 1 -and $after.ServerCount -eq 0) 'after snapshot records removed server structure'
    Assert-True ($before.RemovedDomainGroupCount -eq 1 -and $after.RemovedDomainGroupCount -eq 0) 'snapshots discriminate removal of the target domain group'
    Assert-True ($before.Sha256 -match '^[A-F0-9]{64}$' -and $after.Sha256 -match '^[A-F0-9]{64}$' -and $before.Sha256 -ne $after.Sha256) 'snapshots record distinct SHA-256 identities'
    Assert-True ($published -and $manifest.SchemaVersion -eq 1 -and $manifest.DomainName -eq 'remove.example' -and $manifest.CorrelationId -eq 'correlation') 'manifest publishes correlation metadata'
    Assert-True (@($manifest.Snapshots).Count -eq 2 -and $manifest.Snapshots[0].Stage -eq 'before' -and $manifest.Snapshots[1].Stage -eq 'after') 'manifest orders both snapshots'
    Assert-True (@(Get-ChildItem -LiteralPath $snapshotDirectory -Filter '*.tmp' -File).Count -eq 0) 'atomic publication leaves no temporary files'

    $missing = Save-RdcManRemovalSnapshot -SourcePath (Join-Path $testRoot 'missing.rdg') -SnapshotPath (Join-Path $testRoot 'missing-copy.rdg') -Stage before
    Assert-True (-not $missing.SourceExists -and -not (Test-Path -LiteralPath $missing.SnapshotPath)) 'missing source is reported without a phantom snapshot'

    $inspectionOnly = Save-RdcManRemovalSnapshot -SourcePath $source -Stage after -RemovedDomainName 'remove.example'
    Assert-True ($inspectionOnly.XmlValid -and -not $inspectionOnly.SnapshotPath -and -not $inspectionOnly.CaptureError) 'source inspection remains available when protected archival is disabled'

    $blockedParent = Join-Path $testRoot 'blocked-parent'
    Set-Content -LiteralPath $blockedParent -Value blocked
    $blockedCapture = Save-RdcManRemovalSnapshot -SourcePath $source -SnapshotPath (Join-Path $blockedParent 'after.rdg') -Stage after -RemovedDomainName 'remove.example'
    Assert-True ($blockedCapture.XmlValid -and $blockedCapture.CaptureError -and -not $blockedCapture.XmlError) 'snapshot persistence failure remains separate from XML validation'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) { throw "$script:Failures RDCMan removal snapshot assertion(s) failed." }
Write-Host 'PASS  RDCMan removal snapshot tests completed'