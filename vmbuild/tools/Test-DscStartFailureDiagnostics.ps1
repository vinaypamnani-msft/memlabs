#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'common\Common.ScriptBlocks.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DscFailureDetail'
        }, $true))
Assert-True ($definitions.Count -eq 1) 'Expected one shipped DSC failure-detail helper.'
. ([scriptblock]::Create($definitions[0].Extent.Text))

$script:LcmUnavailable = $false
$script:StatusUnavailable = $false
$script:EventsUnavailable = $false
$script:StatusReads = 0
function Get-CimInstance {
    param($Namespace, $ClassName, $OperationTimeoutSec, $ErrorAction)
    Assert-True ($Namespace -eq 'root\Microsoft\Windows\DesiredStateConfiguration' -and
        $ClassName -eq 'MSFT_DSCLocalConfigurationManager' -and $OperationTimeoutSec -eq 5) 'LCM evidence lost its exact namespace or bounded CIM deadline.'
    if ($script:LcmUnavailable) { throw 'Fixture LCM is unreachable.' }
    [pscustomobject]@{ LCMState = 'Busy'; LCMStateDetail = 'Fixture apply in progress.' }
}
function Get-DscConfigurationStatus {
    param($ErrorAction)
    $script:StatusReads++
    if ($script:StatusUnavailable) { throw 'Fixture status is unavailable during apply.' }
    [pscustomobject]@{
        Status = 'Failure'; StartDate = '2026-10-28T10:00:00Z'; Type = 'Initial'
        ResourcesNotInDesiredState = @([pscustomobject]@{ ResourceId = '[Script]Fixture'; Error = 'Fixture resource failure.' })
    }
}
function Get-WinEvent {
    param($LogName, $MaxEvents, $ErrorAction)
    Assert-True ($LogName -eq 'Microsoft-Windows-DSC/Operational' -and $MaxEvents -eq 40) 'DSC event capture became unbounded.'
    if ($script:EventsUnavailable) { throw 'Fixture DSC event channel is unavailable.' }
    [pscustomobject]@{
        Id = 4252; TimeCreated = [datetime]'2026-10-28T10:00:00Z'
        LevelDisplayName = 'Error'; Message = 'Fixture operational event.'
    }
}

$failure = $null
try { throw [InvalidOperationException]::new('Fixture metadata push failure.', [TimeoutException]::new('Fixture inner transport timeout.')) }
catch { $failure = $_ }
$detail = Get-DscFailureDetail -ErrorRecord $failure
Assert-True ($detail -match 'Fixture inner transport timeout' -and $detail -match 'HResult=0x' -and
    $detail -match 'FQID=' -and $detail -match 'LCMState=Busy' -and
    $detail -match 'Last DSC status=Failure; StartDate=' -and $detail -match '\[Script\]Fixture') `
    'DSC diagnostics lost the exception chain, LCM state, or dated resource evidence.'

$script:LcmUnavailable = $true
$script:StatusUnavailable = $true
$detail = Get-DscFailureDetail -ErrorRecord $failure
Assert-True ($detail -match 'LCM state unavailable' -and $detail -match 'Last DSC status unavailable' -and
    $detail -match 'DSC error event 4252 at') 'Unreachable LCM/status did not fall back to dated DSC event evidence.'
$script:EventsUnavailable = $true
Assert-True ((Get-DscFailureDetail -ErrorRecord $failure) -match 'DSC event evidence unavailable') `
    'A failed event capture silently disappeared from the diagnostic.'

$script:LcmUnavailable = $false
$script:StatusUnavailable = $false
$script:EventsUnavailable = $false
$script:StatusReads = 0
$metadataTries = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
            $node.Body.Extent.Text -match '^\{\s*"Set-DscLocalConfigurationManager for'
        }, $true))
Assert-True ($metadataTries.Count -eq 1) 'Expected one actual metadata push/recovery block.'
function Set-DscLocalConfigurationManager {
    param($Path, [switch]$Force, $ErrorAction)
    Assert-True ($Path -eq 'C:\fixture\mof' -and $Force -and $ErrorAction -eq 'Stop') `
        'Metadata push can still continue after a non-terminating failure.'
    throw 'Fixture metadata push command failed.'
}
function Out-File {
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(Position = 0)]$FilePath, [Parameter(ValueFromPipeline)]$InputObject, [switch]$Append)
    process { }
}
function Write-Error { param($Message) }
$metadataPush = [scriptblock]::Create("param(`$dscConfigPath, `$log)`n" + $metadataTries[0].Extent.Text)
$returned = & $metadataPush 'C:\fixture\mof' 'C:\fixture\unused.log'
Assert-True ("$returned" -match 'Could not run Set-DscLocalConfigurationManager' -and
    "$returned" -match 'Fixture metadata push command failed' -and "$returned" -match 'LCMState=Busy' -and
    "$returned" -match 'DSC error event 4252' -and $script:StatusReads -eq 0) `
    'Metadata push failure does not carry its diagnostic back to the host.'

Write-Host 'PASS -- DSC metadata failures stop apply and return nested, bounded LCM/status/event evidence.'
