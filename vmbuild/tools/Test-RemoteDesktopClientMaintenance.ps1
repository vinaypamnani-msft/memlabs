<#
.SYNOPSIS
    Verifies installed-only Remote Desktop client maintenance.
.DESCRIPTION
    Loads the shipped maintenance function through the PowerShell AST and exercises it
    with mocked uninstall entries and WinGet. No packages are changed on the test host.
#>
[CmdletBinding()]
param (
    [string] $RootPath,
    [string] $SourceFile = 'Invoke-Maintenance.ps1'
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = ("$Expected" -eq "$Actual")
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Assert-Throws {
    param ([scriptblock] $Action, [string] $What)

    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-Equal $true $threw $What
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref] $tokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$functionNode = $ast.FindAll({
        param ($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-RemoteDesktopClientMaintenance'
    }, $true) | Select-Object -First 1
if (-not $functionNode) {
    Write-Host "SETUP FAIL: Invoke-RemoteDesktopClientMaintenance not found in $SourceFile" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($functionNode.Extent.Text))

$script:InstalledEntries = @()
$script:UpdatedEntries = @()
$script:EntryReads = 0
$script:RequestedName = ''
$script:WingetAvailable = $true
$script:WingetCalls = @()
$script:WingetExitCode = 0
$script:WingetOutput = @()
$script:CommandLookups = 0
$script:Logs = @()

function Get-InstalledEntry {
    param ([string] $NameLike)

    $script:RequestedName = $NameLike
    $script:EntryReads++
    if ($script:EntryReads -gt 1) { return $script:UpdatedEntries }
    return $script:InstalledEntries
}

function Get-Command {
    param (
        [string] $Name,
        [string] $CommandType,
        [string] $ErrorAction
    )

    $script:CommandLookups++
    if (-not $script:WingetAvailable) { return $null }

    return [pscustomobject]@{
        Source = {
            $script:WingetCalls += ,@($args)
            $global:LASTEXITCODE = $script:WingetExitCode
            $script:WingetOutput
        }
    }
}

function Write-LogMessage {
    param ([string] $Message, [string] $Level = 'INFO')
    $script:Logs += [pscustomobject]@{ Message = $Message; Level = $Level }
}

function Reset-Fixture {
    $script:InstalledEntries = @()
    $script:UpdatedEntries = @()
    $script:EntryReads = 0
    $script:RequestedName = ''
    $script:WingetAvailable = $true
    $script:WingetCalls = @()
    $script:WingetExitCode = 0
    $script:WingetOutput = @()
    $script:CommandLookups = 0
    $script:Logs = @()
}

function New-RemoteDesktopEntry {
    param ([string] $Version = '1.2.7214.0', [string] $Publisher = 'Microsoft Corporation')
    return [pscustomobject]@{
        DisplayName = 'Remote Desktop'
        DisplayVersion = $Version
        Publisher = $Publisher
    }
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

Reset-Fixture
Invoke-RemoteDesktopClientMaintenance
Assert-Equal 'Remote Desktop' $script:RequestedName 'detection asks for the exact MSI display name'
Assert-Equal 0 $script:CommandLookups 'an absent client does not invoke WinGet'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry -Publisher 'Contoso')
Invoke-RemoteDesktopClientMaintenance
Assert-Equal 0 $script:CommandLookups 'a same-name non-Microsoft package is ignored'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry)
$script:WingetAvailable = $false
Invoke-RemoteDesktopClientMaintenance
Assert-Equal 0 $script:WingetCalls.Count 'missing WinGet cannot launch an update'
Assert-Equal 'WARNING' @($script:Logs | Select-Object -Last 1)[0].Level 'missing WinGet is surfaced as a warning'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry)
$script:WingetExitCode = -1978335189
$script:WingetOutput = @('No applicable upgrade found.')
Invoke-RemoteDesktopClientMaintenance
Assert-Equal 1 $script:WingetCalls.Count 'an installed Microsoft client invokes WinGet once'
$expectedArguments = 'upgrade --id Microsoft.RemoteDesktopClient --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
Assert-Equal $expectedArguments ($script:WingetCalls[0] -join ' ') 'WinGet targets the exact per-machine package unattended'
Assert-Equal $true ($script:Logs[-1].Message -like '*already at the latest version*') 'WinGet no-update result is treated as current'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry)
$script:UpdatedEntries = @(New-RemoteDesktopEntry -Version '1.2.7391.0')
Invoke-RemoteDesktopClientMaintenance
Assert-Equal 2 $script:EntryReads 'a successful update re-reads MSI registration'
Assert-Equal $true ($script:Logs[-1].Message -like '*1.2.7391.0*') 'the post-update version is logged'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry)
$script:WingetExitCode = 42
$script:WingetOutput = @('simulated failure')
Assert-Throws { Invoke-RemoteDesktopClientMaintenance } 'an unexpected WinGet failure is surfaced'

Reset-Fixture
$script:InstalledEntries = @(New-RemoteDesktopEntry)
$script:UpdatedEntries = @()
Assert-Throws { Invoke-RemoteDesktopClientMaintenance } 'a missing post-update MSI registration is surfaced'

$sourceText = [System.IO.File]::ReadAllText($sourcePath)
Assert-Equal $true $sourceText.Contains('try { Invoke-RemoteDesktopClientMaintenance }') 'Remote Desktop maintenance is wired into the package phases'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAILED: $($script:Failures) assertion(s)" -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: Remote Desktop client maintenance checks passed.' -ForegroundColor Green
exit 0
