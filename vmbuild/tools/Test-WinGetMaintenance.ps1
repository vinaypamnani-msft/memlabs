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
$script:WingetSource = $null
$script:Logs = @()
$script:StartedProcess = $null

function Get-Command {
    param (
        [string] $Name,
        [string] $CommandType,
        [string] $ErrorAction
    )

    if (-not $script:WingetAvailable) { return $null }

    return [pscustomobject]@{
        Source = $(if ($null -ne $script:WingetSource) { $script:WingetSource } else { {
            $script:WingetCalls += ,@($args)
            $global:LASTEXITCODE = $script:WingetExitCode
            $script:WingetOutput
        } })
    }
}

function Start-Process {
    param (
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WindowStyle
    )

    $script:StartedProcess = [pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        WindowStyle = $WindowStyle
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
    $script:WingetSource = $null
    $script:Logs = @()
    $script:StartedProcess = $null
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

Reset-Fixture
$script:WingetAvailable = $false
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal 0 $script:WingetCalls.Count 'missing WinGet cannot launch an upgrade'
Assert-Equal 'WARNING' @($script:Logs | Select-Object -Last 1)[0].Level 'missing WinGet is surfaced as a warning'

Reset-Fixture
$script:WingetExitCode = -1978335189
$script:WingetOutput = @('No applicable upgrade found.')
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal 1 $script:WingetCalls.Count 'available WinGet is invoked once'
$expectedArguments = 'upgrade --all --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
Assert-Equal $expectedArguments ($script:WingetCalls[0] -join ' ') 'WinGet upgrades all matched packages from the community source unattended'
Assert-Equal $true ($script:Logs[-1].Message -like '*already current*') 'WinGet no-update result is treated as current'

Reset-Fixture
$script:WingetOutput = @('Successfully installed')
Invoke-WinGetMaintenance -WaitForCompletion
Assert-Equal $true ($script:Logs[-1].Message -like '*completed successfully*') 'successful WinGet upgrades are logged'

Reset-Fixture
$script:WingetExitCode = -1978335188
$script:WingetOutput = @('One or more package upgrades failed.')
Assert-Throws { Invoke-WinGetMaintenance -WaitForCompletion } 'a partial WinGet upgrade failure is surfaced'

Reset-Fixture
$script:WingetExitCode = 42
$script:WingetOutput = @('simulated failure')
Assert-Throws { Invoke-WinGetMaintenance -WaitForCompletion } 'an unexpected WinGet failure is surfaced'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('MemLabs WinGet maintenance test {0}' -f [guid]::NewGuid().ToString('N'))
$savedTemp = $env:TEMP
try {
    $null = New-Item -Path $fixtureRoot -ItemType Directory -Force
    $env:TEMP = $fixtureRoot

    Reset-Fixture
    $script:WingetSource = 'C:\Program Files\WindowsApps\winget.exe'
    $mutexName = 'Global\MemLabs_ChocolateyUpgrade_Test'
    Invoke-WinGetMaintenance -UpgradeMutexName $mutexName

    Assert-Equal 'powershell' $script:StartedProcess.FilePath 'interactive maintenance launches a separate PowerShell process'
    Assert-Equal 'Normal' $script:StartedProcess.WindowStyle 'interactive upgrades are visible in their own window'
    Assert-Equal $true ($script:Logs[-1].Message -like '*non-blocking*') 'interactive launch is logged as non-blocking'

    $childScriptPath = Join-Path $fixtureRoot 'memlabs_winget_upgrade.ps1'
    Assert-Equal $true (Test-Path -LiteralPath $childScriptPath) 'interactive maintenance writes its child script'
    $childScript = Get-Content -LiteralPath $childScriptPath -Raw
    Assert-Equal $true $childScript.Contains($mutexName) 'interactive child uses the package upgrade mutex'
    Assert-Equal $true $childScript.Contains('winget.exe'' upgrade --all --source winget') 'interactive child runs the same upgrade-all command'
    Assert-Equal $true $childScript.Contains('list --id Microsoft.VisualStudioCode --exact --source winget --upgrade-available') 'aggregate failure checks whether VS Code remains upgradeable'
    Assert-Equal $true $childScript.Contains('$process.CloseMainWindow()') 'VS Code receives a graceful window-close request'
    Assert-Equal $true $childScript.Contains('upgrade --id Microsoft.VisualStudioCode --exact --source winget') 'VS Code is retried after a clean exit'
    Assert-Equal $false $childScript.Contains('Stop-Process') 'generated maintenance never force-kills VS Code'
    Assert-Equal $false $childScript.Contains('.Kill(') 'generated maintenance never calls a process kill method'

    $childTokens = $null
    $childParseErrors = $null
    [void] [System.Management.Automation.Language.Parser]::ParseInput($childScript, [ref] $childTokens, [ref] $childParseErrors)
    Assert-Equal 0 @($childParseErrors).Count 'generated interactive WinGet script parses successfully'
}
finally {
    $env:TEMP = $savedTemp
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$sourceText = [System.IO.File]::ReadAllText($sourcePath)
Assert-Equal $true $sourceText.Contains('Invoke-WinGetMaintenance -WaitForCompletion:$ScheduledTask') 'only scheduled maintenance waits for WinGet completion'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAILED: $($script:Failures) assertion(s)" -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: WinGet maintenance checks passed.' -ForegroundColor Green
exit 0
