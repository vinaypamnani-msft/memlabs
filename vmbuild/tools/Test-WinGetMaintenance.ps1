<#
.SYNOPSIS
    Verifies unattended WinGet upgrades for matched host applications.
.DESCRIPTION
    Loads the shipped maintenance function through the PowerShell AST and exercises it
    with a mocked WinGet command. No packages are changed on the test host.
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
        $node.Name -eq 'Invoke-WinGetMaintenance'
    }, $true) | Select-Object -First 1
if (-not $functionNode) {
    Write-Host "SETUP FAIL: Invoke-WinGetMaintenance not found in $SourceFile" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($functionNode.Extent.Text))

$script:WingetAvailable = $true
$script:WingetCalls = @()
$script:WingetExitCode = 0
$script:WingetOutput = @()
$script:Logs = @()

function Get-Command {
    param (
        [string] $Name,
        [string] $CommandType,
        [string] $ErrorAction
    )

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
    $script:WingetAvailable = $true
    $script:WingetCalls = @()
    $script:WingetExitCode = 0
    $script:WingetOutput = @()
    $script:Logs = @()
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

Reset-Fixture
$script:WingetAvailable = $false
Invoke-WinGetMaintenance
Assert-Equal 0 $script:WingetCalls.Count 'missing WinGet cannot launch an upgrade'
Assert-Equal 'WARNING' @($script:Logs | Select-Object -Last 1)[0].Level 'missing WinGet is surfaced as a warning'

Reset-Fixture
$script:WingetExitCode = -1978335189
$script:WingetOutput = @('No applicable upgrade found.')
Invoke-WinGetMaintenance
Assert-Equal 1 $script:WingetCalls.Count 'available WinGet is invoked once'
$expectedArguments = 'upgrade --all --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
Assert-Equal $expectedArguments ($script:WingetCalls[0] -join ' ') 'WinGet upgrades all matched packages from the community source unattended'
Assert-Equal $true ($script:Logs[-1].Message -like '*already current*') 'WinGet no-update result is treated as current'

Reset-Fixture
$script:WingetOutput = @('Successfully installed')
Invoke-WinGetMaintenance
Assert-Equal $true ($script:Logs[-1].Message -like '*completed successfully*') 'successful WinGet upgrades are logged'

Reset-Fixture
$script:WingetExitCode = -1978335188
$script:WingetOutput = @('One or more package upgrades failed.')
Assert-Throws { Invoke-WinGetMaintenance } 'a partial WinGet upgrade failure is surfaced'

Reset-Fixture
$script:WingetExitCode = 42
$script:WingetOutput = @('simulated failure')
Assert-Throws { Invoke-WinGetMaintenance } 'an unexpected WinGet failure is surfaced'

$sourceText = [System.IO.File]::ReadAllText($sourcePath)
Assert-Equal $true $sourceText.Contains('try { Invoke-WinGetMaintenance }') 'WinGet maintenance is wired into the package phases'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAILED: $($script:Failures) assertion(s)" -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: WinGet maintenance checks passed.' -ForegroundColor Green
exit 0
