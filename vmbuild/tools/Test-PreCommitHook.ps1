<#
.SYNOPSIS
    Verifies the tracked fast pre-commit hook in an isolated Git repository.
#>
[CmdletBinding()]
param (
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

$hookSource = Join-Path $RepoRoot '.githooks\pre-commit'
$syntaxSource = Join-Path $RepoRoot 'vmbuild\tools\Test-StagedPowerShellSyntax.ps1'
$principalSource = Join-Path $RepoRoot 'vmbuild\tools\Test-LocalizedBuiltInPrincipal.ps1'
$launcherSource = Join-Path $RepoRoot 'vmbuild\VMBuild.cmd'
foreach ($path in @($hookSource, $syntaxSource, $principalSource, $launcherSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing hook test input: $path" }
}

$failures = 0
function Assert-Case {
    param ([bool] $Condition, [string] $Message)
    if ($Condition) { Write-Host "PASS  $Message" -ForegroundColor Green }
    else { Write-Host "FAIL  $Message" -ForegroundColor Red; $script:failures++ }
}

$testRoot = 'C:\mlhooktest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
function Invoke-Git {
    param ([string[]] $Arguments)
    $output = @(& git -C $testRoot @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Reset-Fixture {
    $result = Invoke-Git @('reset', '--hard', 'HEAD')
    if ($result.ExitCode -ne 0) { throw "Fixture reset failed: $($result.Output -join '; ')" }
    $result = Invoke-Git @('clean', '-fd')
    if ($result.ExitCode -ne 0) { throw "Fixture clean failed: $($result.Output -join '; ')" }
}

function Invoke-HookCase {
    param (
        [string] $Name,
        [string] $Path,
        [string] $StagedContent,
        [string] $WorktreeContent,
        [switch] $Utf8NoBom,
        [switch] $Utf8Bom,
        [switch] $ForceStage,
        [string] $RenameFrom,
        [switch] $Delete,
        [switch] $DisableRenameDetection,
        [int] $ExpectedExit,
        [string] $ExpectedText
    )

    Reset-Fixture
    if ($Path) {
        $fullPath = Join-Path $testRoot $Path
        if ($Delete) {
            $result = Invoke-Git @('rm', '--', $Path)
            if ($result.ExitCode -ne 0) { throw "Could not stage deletion ${Path}: $($result.Output -join '; ')" }
        }
        else {
            if ($RenameFrom) {
                $result = Invoke-Git @('mv', '--', $RenameFrom, $Path)
                if ($result.ExitCode -ne 0) { throw "Could not stage rename ${RenameFrom}: $($result.Output -join '; ')" }
            }
            $directory = Split-Path -Parent $fullPath
            if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -Path $directory -ItemType Directory -Force }
            $encoding = if ($Utf8Bom) { [System.Text.UTF8Encoding]::new($true) } elseif ($Utf8NoBom) { [System.Text.UTF8Encoding]::new($false) } else { [System.Text.Encoding]::ASCII }
            [System.IO.File]::WriteAllText($fullPath, $StagedContent, $encoding)
            $addArguments = if ($ForceStage) { @('add', '-f', '--', $Path) } else { @('add', '--', $Path) }
            $result = Invoke-Git $addArguments
            if ($result.ExitCode -ne 0) { throw "Could not stage ${Path}: $($result.Output -join '; ')" }
            if ($PSBoundParameters.ContainsKey('WorktreeContent')) {
                [System.IO.File]::WriteAllText($fullPath, $WorktreeContent, [System.Text.Encoding]::ASCII)
            }
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Git @('config', 'diff.renames', $(if ($DisableRenameDetection) { 'false' } else { 'true' }))
    $result = Invoke-Git @('hook', 'run', 'pre-commit')
    $stopwatch.Stop()
    $joined = $result.Output -join "`n"
    Assert-Case ($result.ExitCode -eq $ExpectedExit) "$Name returns $ExpectedExit"
    if ($ExpectedText) { Assert-Case ($joined.Contains($ExpectedText)) "$Name reports '$ExpectedText'" }
    Assert-Case ($stopwatch.ElapsedMilliseconds -lt 10000) "$Name completes in under 10 seconds ($($stopwatch.ElapsedMilliseconds) ms)"
}

try {
    $null = New-Item -Path $testRoot -ItemType Directory
    $result = Invoke-Git @('init')
    if ($result.ExitCode -ne 0) { throw "git init failed: $($result.Output -join '; ')" }
    $null = New-Item -Path (Join-Path $testRoot '.githooks') -ItemType Directory
    $null = New-Item -Path (Join-Path $testRoot 'vmbuild\tools') -ItemType Directory -Force
    Copy-Item -LiteralPath $hookSource -Destination (Join-Path $testRoot '.githooks\pre-commit')
    Copy-Item -LiteralPath $syntaxSource -Destination (Join-Path $testRoot 'vmbuild\tools\Test-StagedPowerShellSyntax.ps1')
    Copy-Item -LiteralPath $principalSource -Destination (Join-Path $testRoot 'vmbuild\tools\Test-LocalizedBuiltInPrincipal.ps1')
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'vmbuild\rename-source.ps1'), '$value = 1', [System.Text.Encoding]::ASCII)
    $null = New-Item -Path (Join-Path $testRoot 'vmbuild\azureFiles') -ItemType Directory -Force
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'vmbuild\azureFiles\tracked-secret.ps1'), '$value = 1', [System.Text.Encoding]::ASCII)
    $null = Invoke-Git @('config', 'user.email', 'memlabs-hook-test@example.invalid')
    $null = Invoke-Git @('config', 'user.name', 'MemLabs Hook Test')
    $null = Invoke-Git @('add', '--', '.githooks/pre-commit', 'vmbuild/tools/Test-StagedPowerShellSyntax.ps1', 'vmbuild/tools/Test-LocalizedBuiltInPrincipal.ps1', 'vmbuild/rename-source.ps1')
    $null = Invoke-Git @('add', '-f', '--', 'vmbuild/azureFiles/tracked-secret.ps1')
    $null = Invoke-Git @('config', 'core.hooksPath', '.disabled-hooks')
    $result = Invoke-Git @('commit', '-m', 'fixture baseline')
    if ($result.ExitCode -ne 0) { throw "Fixture commit failed: $($result.Output -join '; ')" }
    $null = Invoke-Git @('config', 'core.hooksPath', '.githooks')

    Invoke-HookCase -Name 'empty index' -ExpectedExit 0
    Invoke-HookCase -Name 'valid staged PowerShell' -Path 'vmbuild\valid.ps1' -StagedContent '$value = 1' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS (1 changed path(s), 1 PowerShell file(s)).'
    Invoke-HookCase -Name 'staged localized principal' -Path 'vmbuild\localized-principal.ps1' -StagedContent "New-SmbShare -Name Data -Path C:\Data -ReadAccess 'Everyone'" -WorktreeContent "`$world = [Security.Principal.SecurityIdentifier]'S-1-1-0'" -ExpectedExit 1 -ExpectedText "literal 'Everyone' passed to New-SmbShare"
    $indirectPrincipal = @'
$world = 'Everyone'
New-SmbShare -Name Data -Path C:\Data -ReadAccess $world
'@
    Invoke-HookCase -Name 'staged indirect localized principal' -Path 'vmbuild\indirect-principal.ps1' -StagedContent $indirectPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Everyone' reaches New-SmbShare -ReadAccess"
    $concatenatedPrincipal = @'
$prefix = 'Admin'
$suffix = 'istrators'
$group = $prefix + $suffix
Add-LocalGroupMember -Group $group -Member 'MEMLABS\user'
'@
    Invoke-HookCase -Name 'staged concatenated localized principal' -Path 'vmbuild\concatenated-principal.ps1' -StagedContent $concatenatedPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Administrators' reaches Add-LocalGroupMember -Group"
    $splattedPrincipal = @'
$shareArgs = @{ ReadAccess = 'Everyone' }
New-SmbShare -Name Data -Path C:\Data @shareArgs
'@
    Invoke-HookCase -Name 'staged splatted localized principal' -Path 'vmbuild\splatted-principal.ps1' -StagedContent $splattedPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Everyone' reaches New-SmbShare -ReadAccess through a splatted hashtable"
    Invoke-HookCase -Name 'staged qualified localized principal' -Path 'vmbuild\qualified-principal.ps1' -StagedContent "Microsoft.PowerShell.LocalAccounts\Add-LocalGroupMember -Group 'Administrators' -Member 'MEMLABS\user'" -ExpectedExit 1 -ExpectedText "literal 'Administrators' passed to Add-LocalGroupMember"
    Invoke-HookCase -Name 'staged abbreviated localized principal' -Path 'vmbuild\abbreviated-principal.ps1' -StagedContent "Add-LocalGroupMember -Gro 'Administrators' -Member 'MEMLABS\user'" -ExpectedExit 1 -ExpectedText "literal 'Administrators' passed to Add-LocalGroupMember"
    Invoke-HookCase -Name 'staged positional localized principal' -Path 'vmbuild\positional-principal.ps1' -StagedContent "Add-LocalGroupMember 'Administrators' 'MEMLABS\user'" -ExpectedExit 1 -ExpectedText "literal 'Administrators' passed to Add-LocalGroupMember"
    $orderedPrincipal = @'
$groupArgs = [ordered]@{ Group = 'Administrators'; Member = 'MEMLABS\user' }
Add-LocalGroupMember @groupArgs
'@
    Invoke-HookCase -Name 'staged ordered splat localized principal' -Path 'vmbuild\ordered-splat-principal.ps1' -StagedContent $orderedPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Administrators' reaches Add-LocalGroupMember -Group through a splatted hashtable"
    $castPrincipal = @'
$shareArgs = [hashtable]@{ ReadAccess = 'Everyone' }
SmbShare\New-SmbShare -Name Data -Path C:\Data @shareArgs
'@
    Invoke-HookCase -Name 'staged cast splat localized principal' -Path 'vmbuild\cast-splat-principal.ps1' -StagedContent $castPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Everyone' reaches New-SmbShare -ReadAccess through a splatted hashtable"
    $capturedPrincipal = @'
$world = 'Everyone'
& { SmbShare\New-SmbShare -Name Data -Path C:\Data -ReadA $world }
'@
    Invoke-HookCase -Name 'staged captured localized principal' -Path 'vmbuild\captured-principal.ps1' -StagedContent $capturedPrincipal -ExpectedExit 1 -ExpectedText "indirect literal 'Everyone' reaches New-SmbShare -ReadAccess"
    Invoke-HookCase -Name 'staged nonidentity principal-shaped name' -Path 'vmbuild\nonidentity-name.ps1' -StagedContent "New-SmbShare -Name 'Users' -Path C:\Users" -ExpectedExit 0 -ExpectedText 'OK - no localized built-in name flows into a principal-resolution boundary.'
    Invoke-HookCase -Name 'staged SID principal' -Path 'vmbuild\sid-principal.ps1' -StagedContent "`$world = [Security.Principal.SecurityIdentifier]'S-1-1-0'" -ExpectedExit 0 -ExpectedText 'OK - no localized built-in name flows into a principal-resolution boundary.'
    Invoke-HookCase -Name 'unstaged syntax defect' -Path 'vmbuild\index-valid.ps1' -StagedContent '$value = 1' -WorktreeContent 'function Broken {' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS (1 changed path(s), 1 PowerShell file(s)).'
    Invoke-HookCase -Name 'staged syntax defect' -Path 'vmbuild\index-broken.ps1' -StagedContent 'function Broken {' -WorktreeContent '$value = 1' -ExpectedExit 1 -ExpectedText 'index-broken.ps1:1'
    $parameterlessLower = '"ACTIVE".' + 'To' + 'Lower()'
    Invoke-HookCase -Name 'parameterless casing' -Path 'vmbuild\culture-unsafe.ps1' -StagedContent ("`$value = $parameterlessLower") -ExpectedExit 1 -ExpectedText 'culture-sensitive parameterless ToLower call'
    Invoke-HookCase -Name 'generated-code casing' -Path 'vmbuild\culture-generated.ps1' -StagedContent ("`$generated = '$parameterlessLower'") -ExpectedExit 1 -ExpectedText 'culture-sensitive parameterless casing in generated or partially parsed code'
    $noncanonicalCasing = '"ACTIVE".' + 'to' + 'LoWeR()'
    Invoke-HookCase -Name 'generated-code noncanonical casing' -Path 'vmbuild\culture-generated-mixed.ps1' -StagedContent ("`$generated = '$noncanonicalCasing'") -ExpectedExit 1 -ExpectedText 'culture-sensitive parameterless casing in generated or partially parsed code'
    Invoke-HookCase -Name 'invariant casing' -Path 'vmbuild\culture-invariant.ps1' -StagedContent '$value = "ACTIVE".ToLowerInvariant()' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'explicit display culture' -Path 'vmbuild\culture-display.ps1' -StagedContent '$value = "TITLE".ToLower([Globalization.CultureInfo]::CurrentCulture)' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'read-only automatic variable' -Path 'vmbuild\readonly.ps1' -StagedContent '$IsWindows = $false' -ExpectedExit 1 -ExpectedText 'PS7 read-only automatic variable'
    Invoke-HookCase -Name 'module read-only automatic variable' -Path 'vmbuild\readonly.psm1' -StagedContent '$IsLinux = $false' -ExpectedExit 1 -ExpectedText 'PS7 read-only automatic variable'
    Invoke-HookCase -Name 'scoped read-only automatic variable' -Path 'vmbuild\readonly-scoped.ps1' -StagedContent '$global:IsWindows = $false' -ExpectedExit 1 -ExpectedText 'PS7 read-only automatic variable'
    Invoke-HookCase -Name 'braced scoped read-only automatic variable' -Path 'vmbuild\readonly-braced.ps1' -StagedContent '${script:IsMacOS} = $false' -ExpectedExit 1 -ExpectedText 'PS7 read-only automatic variable'
    Invoke-HookCase -Name 'data file syntax defect' -Path 'vmbuild\broken.psd1' -StagedContent '@{ Value = ' -ExpectedExit 1 -ExpectedText 'broken.psd1:1'
    Invoke-HookCase -Name 'BOM-less non-ASCII' -Path 'vmbuild\unicode.ps1' -StagedContent ('$value = "caf' + [char] 0x00E9 + '"') -Utf8NoBom -ExpectedExit 1 -ExpectedText 'BOM-less PowerShell files must contain ASCII only'
    Invoke-HookCase -Name 'BOM non-ASCII' -Path 'vmbuild\unicode-bom.ps1' -StagedContent ('$value = "caf' + [char] 0x00E9 + '"') -Utf8Bom -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'sensitive path' -Path 'vmbuild\azureFiles\secret.ps1' -StagedContent '$value = 1' -ForceStage -ExpectedExit 1 -ExpectedText 'must never be added, modified, or renamed'
    Invoke-HookCase -Name 'sensitive deletion' -Path 'vmbuild\azureFiles\tracked-secret.ps1' -Delete -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'sensitive rename' -Path 'vmbuild\released-secret.ps1' -RenameFrom 'vmbuild\azureFiles\tracked-secret.ps1' -StagedContent '$value = 1' -ExpectedExit 1 -ExpectedText 'must never be added, modified, or renamed'
    Invoke-HookCase -Name 'sensitive rename with config disabled' -Path 'vmbuild\released-secret.ps1' -RenameFrom 'vmbuild\azureFiles\tracked-secret.ps1' -StagedContent '$value = 1' -DisableRenameDetection -ExpectedExit 1 -ExpectedText 'must never be added, modified, or renamed'
    Invoke-HookCase -Name 'path with space' -Path 'vmbuild\path with space.ps1' -StagedContent '$value = 1' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'renamed syntax defect' -Path 'vmbuild\renamed.ps1' -RenameFrom 'vmbuild\rename-source.ps1' -StagedContent 'function Broken {' -ExpectedExit 1 -ExpectedText 'renamed.ps1:1'
    Invoke-HookCase -Name 'missing module only' -Path 'vmbuild\missing-module.ps1' -StagedContent 'using module DefinitelyMissingModule' -ExpectedExit 0 -ExpectedText 'Fast staged checks: PASS'
    Invoke-HookCase -Name 'missing module and syntax defect' -Path 'vmbuild\missing-module-broken.ps1' -StagedContent "using module DefinitelyMissingModule`nfunction Broken {" -ExpectedExit 1 -ExpectedText 'missing-module-broken.ps1:2'

    $syntaxAst = [System.Management.Automation.Language.Parser]::ParseFile($syntaxSource, [ref] $null, [ref] $null)
    $parserFunction = $syntaxAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-GitNameStatus'
        }, $true)
    . ([scriptblock]::Create($parserFunction.Extent.Text))
    $newlinePath = "vmbuild/path`nnewline.ps1"
    $recordBytes = [System.Text.Encoding]::UTF8.GetBytes("A`0$newlinePath`0")
    $parsedRecord = @(ConvertFrom-GitNameStatus -Bytes $recordBytes)
    Assert-Case ($parsedRecord.Count -eq 1 -and $parsedRecord[0].DestinationPath -ceq $newlinePath) 'NUL parser preserves a newline-bearing Git path'

    $launcherLines = [System.IO.File]::ReadAllLines($launcherSource)
    $activationStart = [array]::IndexOf($launcherLines, 'IF NOT EXIST "%MEMLABS_VMBUILD_ROOT%..\.githooks\pre-commit" GOTO HookActivationFailed')
    $activationEnd = [array]::IndexOf($launcherLines, ':HookActivationComplete')
    Assert-Case ($activationStart -ge 0 -and $activationEnd -gt $activationStart) 'VMBuild contains a bounded hook activation block'
    if ($activationStart -ge 0 -and $activationEnd -gt $activationStart) {
        $activationFixture = Join-Path $testRoot 'vmbuild\activate-hooks.cmd'
        $activationContent = @('@ECHO OFF', 'SET "MEMLABS_VMBUILD_ROOT=%~dp0"', 'pushd "%MEMLABS_VMBUILD_ROOT%"') + @($launcherLines[$activationStart..$activationEnd]) + @('popd', 'EXIT /B 0')
        [System.IO.File]::WriteAllText($activationFixture, (($activationContent -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
        $null = Invoke-Git @('config', 'core.hooksPath', '.disabled-hooks')
        $activationProcess = Start-Process -FilePath $env:ComSpec -ArgumentList @('/D', '/C', 'CALL', ('"{0}"' -f $activationFixture)) -PassThru -Wait
        Assert-Case ($activationProcess.ExitCode -eq 0) 'VMBuild activates the tracked hook in a clean clone'
        $configuredPath = (Invoke-Git @('config', '--get', 'core.hooksPath')).Output -join ''
        Assert-Case ($configuredPath -eq '.githooks') 'VMBuild records core.hooksPath=.githooks'

        Move-Item -LiteralPath (Join-Path $testRoot '.githooks\pre-commit') -Destination (Join-Path $testRoot '.githooks\pre-commit.disabled')
        $missingHookProcess = Start-Process -FilePath $env:ComSpec -ArgumentList @('/D', '/C', 'CALL', ('"{0}"' -f $activationFixture)) -PassThru -Wait
        Assert-Case ($missingHookProcess.ExitCode -eq 1) 'VMBuild fails closed when the tracked hook is missing'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) { Write-Host "FAILURES: $failures" -ForegroundColor Red; exit 1 }
Write-Host 'OK - fast pre-commit hook checks passed.' -ForegroundColor Green