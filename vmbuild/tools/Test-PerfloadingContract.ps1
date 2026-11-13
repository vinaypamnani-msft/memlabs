#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path parse errors: $($errors -join '; ')" }
    return $ast
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-DscStatus {
    param([string]$Message, [switch]$NoStatus, [switch]$Failure)
    $script:Messages += $Message
    if ($Failure) { $script:Failures++ }
}
$functions = Read-TestAst (Join-Path $root 'DSC\phases\ScriptFunctions.ps1')
$guard = $functions.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $_.Name -eq 'Assert-MemLabsPerfloadingContract'
}
Assert-True ($null -ne $guard) 'The contract guard is not at script scope.'
. ([scriptblock]::Create($guard.Extent.Text))
$perfPath = Join-Path $root 'DSC\phases\perfloading.ps1'
$perf = Read-TestAst $perfPath
$script:Messages = @()
$script:Failures = 0
Assert-MemLabsPerfloadingContract -Script $perfPath
$expectedHash = (Get-FileHash -LiteralPath $perfPath -Algorithm SHA256).Hash
Assert-True (($script:Messages -join ' ') -match $expectedHash) 'Preflight did not log the actual guest script hash.'
Assert-True (($script:Messages -join ' ') -match 'PowerShell=.*helpers=.*Confirm-MemLabsWsusSyncHealth') 'Preflight diagnostics lost engine/helper evidence.'

$workflow = Read-TestAst (Join-Path $root 'DSC\phases\ScriptWorkFlow.ps1')
$preflightCall = $workflow.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Assert-MemLabsPerfloadingContract'
    }, $true)
Assert-True ($null -ne $preflightCall) 'The workflow does not invoke the contract guard.'
$preflightTry = $preflightCall.Parent
while ($preflightTry -and $preflightTry -isnot [Management.Automation.Language.TryStatementAst]) {
    $preflightTry = $preflightTry.Parent
}
Assert-True ($null -ne $preflightTry) 'Preflight has no failure boundary.'
$statements = @($preflightTry.Parent.Statements)
$retry = $statements | Where-Object { $_ -is [Management.Automation.Language.ForStatementAst] }
Assert-True ($retry.Count -eq 1 -and $preflightTry.Extent.EndOffset -lt $retry.Extent.StartOffset) 'Contract validation must run before perfloading retries.'
$preflight = [scriptblock]::Create("param([string]`$ScriptFile)`n" +
    $preflightTry.Extent.Text + "`nthrow 'Preflight incorrectly advanced.'")
$helperNames = @($perf.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -match 'Wsus|FullSync'
    } | Select-Object -ExpandProperty Name)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-perf-contract-" + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    foreach ($name in $helperNames) {
        foreach ($mutation in @('missing', 'nested', 'duplicate', 'conditional')) {
            $definitions = foreach ($helper in $helperNames) {
                if ($helper -ne $name) { "function $helper {}"; continue }
                switch ($mutation) {
                    'missing' { }
                    'nested' { "function ParentFixture { function $helper {} }" }
                    'duplicate' { "function $helper {}`nfunction $helper {}" }
                    'conditional' { "if (`$false) { function $helper {} }" }
                }
            }
            [IO.File]::WriteAllText($fixture, ($definitions -join "`r`n"))
            $errorText = $null
            try { Assert-MemLabsPerfloadingContract -Script $fixture }
            catch { $errorText = $_.Exception.Message }
            Assert-True ($errorText -match [regex]::Escape($name)) "$mutation $name was not rejected with a named diagnostic."
            $fixtureHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
            Assert-True ($errorText -match $fixtureHash -and $errorText.Contains($fixture)) 'Failed contract lost source identity.'
            $before = $script:Failures
            & $preflight $fixture
            Assert-True ($script:Failures -eq ($before + 1)) 'Invalid preflight did not publish JOBFAILURE and return.'
        }
    }
    [IO.File]::WriteAllText($fixture, 'function Broken {')
    $errorText = $null
    try { Assert-MemLabsPerfloadingContract -Script $fixture }
    catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText -match 'parse errors=') 'Malformed source passed preflight.'
    Remove-Item -LiteralPath $fixture -Force
    $errorText = $null
    try { Assert-MemLabsPerfloadingContract -Script $fixture }
    catch { $errorText = $_.Exception.Message }
    Assert-True ($null -ne $errorText) 'Missing source passed preflight.'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Force }
}
Write-Host 'PASS -- real source passes; missing/nested/duplicate/conditional helpers fail before retries with source identity; malformed/missing files fail closed.'
