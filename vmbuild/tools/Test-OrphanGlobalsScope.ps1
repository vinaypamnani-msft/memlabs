<#
.SYNOPSIS
    Verifies that the orphan-variable gate respects Git exclusions without missing owned source.
#>
#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$gatePath = Join-Path $PSScriptRoot 'Test-OrphanGlobals.ps1'
$engine = (Get-Process -Id $PID).Path
$workDir = Join-Path ([IO.Path]::GetTempPath()) "MemLabs-OrphanScope-$([guid]::NewGuid().ToString('N'))"
$toolsDir = Join-Path $workDir 'vmbuild\tools'
$ownedDir = Join-Path $workDir 'vmbuild\baseimagestaging\filesToInject\staging'
$downloadDir = Join-Path $workDir 'vmbuild\baseimagestaging\filesToInject\tools'
$fixtureGate = Join-Path $toolsDir 'Test-OrphanGlobals.ps1'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-FixtureGate {
    param([string[]] $Arguments = @())

    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixtureGate @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $preference }
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
}

try {
    $null = New-Item -ItemType Directory -Path $toolsDir, $ownedDir, $downloadDir -Force
    Copy-Item -LiteralPath $gatePath -Destination $fixtureGate
    '/vmbuild/baseimagestaging/filesToInject/tools/' |
        Set-Content -LiteralPath (Join-Path $workDir '.gitignore') -Encoding ASCII
    $ownedPath = Join-Path $ownedDir 'Owned.ps1'
    $valid = '$ownedFixtureDescription = "owned"; "Scan $ownedFixtureDescription"'
    $invalid = '$ownedFixtureDescription = "owned"; "Scan $ownedFixtureDescripton"'
    $valid | Set-Content -LiteralPath $ownedPath -Encoding ASCII
    '$downloadFixtureDescription = "download"; "Scan $downloadFixtureDescripton"' |
        Set-Content -LiteralPath (Join-Path $downloadDir 'Downloaded.ps1') -Encoding ASCII
    & git -C $workDir init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the isolated scope fixture.' }
    & git -C $workDir add -- .gitignore vmbuild\tools\Test-OrphanGlobals.ps1 vmbuild\baseimagestaging\filesToInject\staging\Owned.ps1
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage owned fixture files.' }

    $result = Invoke-FixtureGate
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Scanned 2 source') "Ignored downloads polluted the repository scan: $($result.Output)"

    $invalid | Set-Content -LiteralPath $ownedPath -Encoding ASCII
    $result = Invoke-FixtureGate
    Assert-True ($result.ExitCode -eq 1 -and $result.Output -match 'ownedFixtureDescripton' -and
        $result.Output -match 'Owned\.ps1' -and $result.Output -notmatch 'Downloaded\.ps1') "Owned injection-staging typos were missed or ignored downloads leaked into the scan: $($result.Output)"

    $valid | Set-Content -LiteralPath $ownedPath -Encoding ASCII
    $invalid | Set-Content -LiteralPath (Join-Path $toolsDir 'NewOwned.ps1') -Encoding ASCII
    $result = Invoke-FixtureGate
    Assert-True ($result.ExitCode -eq 1 -and $result.Output -match 'NewOwned\.ps1') "Untracked non-ignored source was not audited: $($result.Output)"

    $result = Invoke-FixtureGate -Arguments @('-Path', $downloadDir)
    Assert-True ($result.ExitCode -eq 1 -and $result.Output -match 'Downloaded\.ps1') "Explicit path scans no longer audit ignored scripts: $($result.Output)"
    Write-Host "PASS -- orphan-variable scans respect Git exclusions and retain tracked, untracked, injection-staging, and explicit-path coverage (PowerShell $($PSVersionTable.PSVersion))."
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
}
