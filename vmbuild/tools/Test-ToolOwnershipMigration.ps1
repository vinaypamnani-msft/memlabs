<#
.SYNOPSIS
    Verifies host ownership migration when old and new tool bundle bytes match.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'This host-only test requires PowerShell 7.' }
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RootPath 'Common.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-ToolSetFingerprint', 'Copy-ToolToVM')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
    if (-not $definition) { throw "Missing $name." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$copyDefinition = $ast.Find({
        param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ToolToVM'
    }, $true)
$builder = $copyDefinition.Find({
        param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$buildZip'
    }, $true)
$builderArgument = $builder.Right.Find({
        param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
$buildZip = $builderArgument.ScriptBlock.GetScriptBlock()
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-tool-ownership-' + [guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path $tempRoot 'stage'
$cacheRoot = Join-Path $tempRoot 'cache'
$null = New-Item -ItemType Directory -Path (Join-Path $stageRoot 'tools'), $cacheRoot -Force
$Common = [pscustomobject]@{ StagingInjectPath = $stageRoot; TempPath = $cacheRoot }
$script:GuestHashPath = Join-Path $tempRoot 'Tools.MD5'
$script:VmNoteFingerprint = 'pre-ownership-fingerprint'
$script:Expansions = 0
$script:FailExpansion = $false
$script:Copies = 0
$script:Checks = 0
$vmName = 'FIXTURE'
$previousIsoSetting = $env:MEMLABS_NO_TOOLS_ISO
$env:MEMLABS_NO_TOOLS_ISO = '1'

function Assert-Migration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Checks++
    Write-Host "PASS -- $Message"
}
function Get-VMListEntryWithLiveState {
    param($VmName, $Caller)
    [pscustomobject]@{ vmName = $VmName; State = 'Running'; domain = 'example.test' }
}
function Get-VmSession { param($VmName, $VmDomainName); return 'fixture-session' }
function Get-MaintenanceInjectPaths { [pscustomobject]@{ Files = @(); Tools = @() } }
function Get-VMNote { param($VMName); [pscustomobject]@{ ToolsFingerprint = $script:VmNoteFingerprint } }
function Update-VMNoteProperty {
    param($VmName, $PropertyName, $PropertyValue)
    $script:VmNoteFingerprint = $PropertyValue
}
function Write-Log {
    param($Message, [switch]$LogOnly, [switch]$Verbose, [switch]$Success, [switch]$Warning, [switch]$Failure)
    if ($Warning -or $Failure) { Write-Host $Message }
}
function Write-Progress2 { param($Activity, $Status, [switch]$Log, [switch]$Force) }
function Copy-Item {
    param($Path, $Destination, $ToSession, [switch]$Recurse, [switch]$Force, [switch]$WhatIf, $ErrorAction)
    if ($ToSession) { $script:Copies++; return }
    Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Recurse:$Recurse -Force:$Force -ErrorAction Stop
}
function Invoke-VmCommand {
    param($VmName, $VmDomainName, [switch]$SuppressLog, $ScriptBlock, $ArgumentList, $DisplayName)
    if ($DisplayName -eq 'Tools: Expand directly transferred bundle') {
        $script:Expansions++
        return [pscustomobject]@{
            ScriptBlockFailed = $script:FailExpansion
            ScriptBlockOutput = [pscustomobject]@{ Ok = -not $script:FailExpansion; RemovedToolFiles = @(); CleanupWarnings = @() }
        }
    }
    $text = $ScriptBlock.ToString().Replace('$using:vmHashPath', '$script:GuestHashPath').Replace('$using:bundleHash', "'$bundleHash'")
    $result = & ([scriptblock]::Create($text))
    [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $result }
}

try {
    $fileName = 'widget-' + [guid]::NewGuid().ToString('N') + '.exe'
    $sourcePath = Join-Path $stageRoot "tools\$fileName"
    Set-Content -LiteralPath $sourcePath -Value 'unchanged tool bytes' -Encoding ASCII
    $tool = [pscustomobject]@{ Name = 'Widget'; url = "https://example.test/$fileName"; Target = 'tools'; Optional = $false }
    $entries = @([pscustomobject]@{ Name = 'Widget'; SourcePath = $sourcePath; TargetRelative = "tools\$fileName" })
    $fingerprint = Get-ToolSetFingerprint -Entries $entries
    $zip = & $buildZip $entries $fingerprint 'fixture'
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm MD5).Hash
    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($zipHash))
    try { $bundleHash = (Get-FileHash -InputStream $stream -Algorithm MD5).Hash }
    finally { $stream.Dispose() }
    Set-Content -LiteralPath $script:GuestHashPath -Value $bundleHash -Encoding ASCII
    $outcome = $null
    $worked = Copy-ToolToVM -Tool @($tool) -VMName FIXTURE -Fast -Outcome ([ref]$outcome)
    Assert-Migration ($worked -and $outcome -eq 'Copied' -and $script:Expansions -eq 1) "A legacy matching bundle hash cannot skip ownership initialization (worked=$worked, outcome=$outcome, expansions=$script:Expansions)."
    Assert-Migration ($script:VmNoteFingerprint -eq $fingerprint -and (Get-Content -LiteralPath $script:GuestHashPath)[1] -eq 'OwnershipSchema=1') `
        'The new fingerprint is published only after ownership-aware delivery.'
    $outcome = $null
    $worked = Copy-ToolToVM -Tool @($tool) -VMName FIXTURE -Fast -Outcome ([ref]$outcome)
    Assert-Migration ($worked -and $outcome -eq 'Skipped' -and $script:Expansions -eq 1) 'A successfully migrated VM retains its legitimate fingerprint fast skip.'

    $script:VmNoteFingerprint = 'legacy-again'
    $outcome = $null
    $worked = Copy-ToolToVM -Tool @($tool) -VMName FIXTURE -Fast -Outcome ([ref]$outcome)
    Assert-Migration ($worked -and $outcome -eq 'Skipped' -and $script:Expansions -eq 1) 'A schema-qualified cached guest hash can skip without reporting a failed outcome.'

    $script:VmNoteFingerprint = 'legacy-before-failure'
    $script:FailExpansion = $true
    Set-Content -LiteralPath $script:GuestHashPath -Value $bundleHash -Encoding ASCII
    $outcome = $null
    $worked = Copy-ToolToVM -Tool @($tool) -VMName FIXTURE -Fast -Outcome ([ref]$outcome)
    Assert-Migration (-not $worked -and $outcome -eq 'Failed' -and $script:VmNoteFingerprint -eq 'legacy-before-failure' -and
        @(Get-Content -LiteralPath $script:GuestHashPath).Count -eq 1) 'Failed ownership delivery does not certify the fingerprint or receipt.'
    $outcome = $null
    $worked = Copy-ToolToVM -Tool @() -VMName FIXTURE -Outcome ([ref]$outcome)
    Assert-Migration ($worked -and $outcome -eq 'NothingToDo') 'No applicable tool entries remain an explicit no-op.'
}
finally {
    if ($null -eq $previousIsoSetting) { Remove-Item -LiteralPath Env:\MEMLABS_NO_TOOLS_ISO -ErrorAction Stop }
    else { $env:MEMLABS_NO_TOOLS_ISO = $previousIsoSetting }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Checks ownership migration checks."
