#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $root 'Common.ps1'
$newLabPath = Join-Path $root 'New-Lab.ps1'
$startTestPath = Join-Path $root 'Start-Test.ps1'
$phasesPath = Join-Path $root 'common\Common.Phases.ps1'
$expansionRunnerPath = Join-Path $root 'tools\Invoke-MainToDevelopExpansionTest.ps1'

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s): $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $commonPath -Name 'Get-MemLabsSourceIdentity')

$script:Failures = 0
function Assert-True {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What)

    Assert-True ("$Expected" -eq "$Actual") $What
}

function Invoke-TestGit {
    param([string]$Repository, [string[]]$Arguments)

    & git -C $Repository @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') exited $LASTEXITCODE" }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-source-id-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'repo'
$noRepo = Join-Path $tempRoot 'not-a-repo'
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $repo 'DSC') -Force
    $null = New-Item -ItemType Directory -Path $noRepo -Force
    [IO.File]::WriteAllText((Join-Path $repo 'tracked.ps1'), "'clean'")
    [IO.File]::WriteAllText((Join-Path $repo 'version.json'), '{"memLabsVersion":"test.1"}')
    [IO.File]::WriteAllBytes((Join-Path $repo 'DSC\DSC.zip'), [byte[]](1, 2, 3, 4))

    Invoke-TestGit $repo @('init')
    Invoke-TestGit $repo @('config', 'user.email', 'memlabs-test@example.invalid')
    Invoke-TestGit $repo @('config', 'user.name', 'MemLabs Test')
    Invoke-TestGit $repo @('add', '.')
    Invoke-TestGit $repo @('commit', '-m', 'test source')

    $versionPath = Join-Path $repo 'version.json'
    $archivePath = Join-Path $repo 'DSC\DSC.zip'
    $clean = Get-MemLabsSourceIdentity -RepositoryRoot $repo -VersionPath $versionPath -DscArchivePath $archivePath
    Assert-Equal $true $clean.GitAvailable 'clean source resolves Git identity'
    Assert-Equal $false $clean.IsDirty 'clean source is not dirty'
    Assert-Equal $true $clean.Reproducible 'clean current source is reproducible'
    Assert-True ($clean.Commit -match '^[0-9a-f]{40}$') 'source identity records the full commit'
    Assert-Equal 'test.1' $clean.MemLabsVersion 'source identity records version.json value'
    Assert-True ($clean.DscArchiveSha256 -match '^[0-9A-F]{64}$') 'source identity hashes DSC.zip'
    Assert-True ($clean.VersionFileSha256 -match '^[0-9A-F]{64}$') 'source identity hashes version.json'

    [IO.File]::WriteAllText((Join-Path $repo 'tracked.ps1'), "'dirty'")
    $dirty = Get-MemLabsSourceIdentity -RepositoryRoot $repo -VersionPath $versionPath -DscArchivePath $archivePath
    Assert-Equal $true $dirty.IsDirty 'tracked edit marks source dirty'
    Assert-Equal 1 $dirty.DirtyTrackedCount 'tracked edit count is recorded'
    Assert-Equal $false $dirty.Reproducible 'dirty source is not reproducible'
    Assert-True ((@($dirty.DirtyPaths) -join "`n") -match 'tracked\.ps1') 'dirty path is recorded'

    [IO.File]::WriteAllText((Join-Path $repo 'untracked.txt'), 'untracked')
    $untracked = Get-MemLabsSourceIdentity -RepositoryRoot $repo -VersionPath $versionPath -DscArchivePath $archivePath
    Assert-Equal 1 $untracked.UntrackedCount 'untracked file count is recorded'
    Assert-True ((@($untracked.DirtyPaths) -join "`n") -match 'untracked\.txt') 'untracked path is recorded'

    [IO.File]::WriteAllText((Join-Path $repo 'tracked.ps1'), "'clean'")
    Remove-Item -LiteralPath (Join-Path $repo 'untracked.txt') -Force
    $global:MemLabsCodeLoadStamp = [pscustomobject]@{ LoadedUtc = [DateTime]::UtcNow.AddMinutes(-5); ProcessId = $PID }
    function Get-MemLabsStaleSourceFile {
        [pscustomobject]@{ FullName = (Join-Path $repo 'tracked.ps1'); Name = 'tracked.ps1' }
    }
    $stale = Get-MemLabsSourceIdentity -RepositoryRoot $repo -VersionPath $versionPath -DscArchivePath $archivePath
    Assert-Equal 1 $stale.StaleSourceCount 'stale loaded source count is recorded'
    Assert-Equal $false $stale.Reproducible 'stale loaded code is not reproducible'

    function Get-MemLabsStaleSourceFile { throw 'synthetic stale check failure' }
    $staleCheckFailed = Get-MemLabsSourceIdentity -RepositoryRoot $repo -VersionPath $versionPath -DscArchivePath $archivePath
    Assert-Equal $false $staleCheckFailed.Reproducible 'stale-source check errors fail closed'
    Assert-True ((@($staleCheckFailed.Errors) -join "`n") -match 'synthetic stale check failure') 'stale-source check error is recorded'
    $global:MemLabsCodeLoadStamp = $null

    [IO.File]::WriteAllText((Join-Path $noRepo 'version.json'), '{"memLabsVersion":"test.2"}')
    [IO.File]::WriteAllBytes((Join-Path $noRepo 'DSC.zip'), [byte[]](5, 6))
    $missingGit = Get-MemLabsSourceIdentity -RepositoryRoot $noRepo `
        -VersionPath (Join-Path $noRepo 'version.json') -DscArchivePath (Join-Path $noRepo 'DSC.zip')
    Assert-Equal $false $missingGit.GitAvailable 'non-repository source reports Git unavailable'
    Assert-Equal $false $missingGit.Reproducible 'non-repository source is not reproducible'
    Assert-True ($missingGit.Errors.Count -gt 0) 'non-repository source records an actionable error'

    $newLabText = [IO.File]::ReadAllText($newLabPath)
    $startTestText = [IO.File]::ReadAllText($startTestPath)
    $phasesText = [IO.File]::ReadAllText($phasesPath)
    Assert-True ($newLabText.Contains('.source.json')) 'New-Lab writes and rotates a source sidecar'
    Assert-True ($newLabText.Contains('$global:CurrentDeploymentSourceIdentity')) 'New-Lab retains the run-start identity for stats'
    Assert-True ($newLabText.Contains('$RequireCleanSource')) 'New-Lab exposes the clean-source release gate'
    $newLabSplatCarriesGate = $startTestText -match
        '(?s)\$newLabParameters\s*=\s*\[ordered\]@\{.+?RequireCleanSource\s*=\s*\$RequireCleanSource.+?\}'
    $isolatedChildCarriesParameters =
        $startTestText.Contains('Invoke-PinnedChildScript.ps1') -and
        $startTestText -match '\$newLabParameters\s*\|\s*Export-Clixml' -and
        $startTestText -match '-ParameterPath \$parameterPath'
    $newLabChildInvocationCount = [regex]::Matches(
        $startTestText, '\$result\s*=\s*&\s*\$invokeChild').Count
    Assert-True ($newLabSplatCarriesGate -and $isolatedChildCarriesParameters -and
        $newLabChildInvocationCount -eq 2) `
        'Start-Test forwards the gate on both deployment paths'
    if ($startTestText.Contains('Invoke-MainToDevelopExpansionCycle')) {
        $expansionRunnerText = [IO.File]::ReadAllText($expansionRunnerPath)
        Assert-True ($startTestText -match 'Invoke-MainToDevelopExpansionCycle[\s\S]+-RequireCleanSource:\$RequireCleanSource') 'Start-Test forwards the gate to cross-revision qualification'
        Assert-True ($expansionRunnerText -match 'RequireCleanSource[\s\S]+untrackedMode = if \(\$RequireCleanSource\) \{ ''all'' \}') 'cross-revision qualification rejects untracked source when required'
    }
    Assert-True ($phasesText -match 'Source\s+=\s+\$global:CurrentDeploymentSourceIdentity') 'build stats embed source identity'
    Assert-True ($phasesText -match 'ConvertTo-Json -Depth 8') 'build stats preserve nested source identity fields'
}
finally {
    $global:MemLabsCodeLoadStamp = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    throw "$script:Failures source provenance test(s) failed."
}

Write-Host 'ALL SOURCE PROVENANCE TESTS PASSED'
