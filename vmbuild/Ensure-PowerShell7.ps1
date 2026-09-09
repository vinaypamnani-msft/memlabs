[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $ResultPath,
    [version] $MinimumVersion = [version] '7.4'
)

$ErrorActionPreference = 'Stop'

function Get-PowerShell7CandidatePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($programFilesRoot in @($env:ProgramW6432, $env:ProgramFiles)) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot)) { continue }
        $paths.Add((Join-Path $programFilesRoot 'PowerShell\7\pwsh.exe'))
    }

    foreach ($command in @(Get-Command pwsh.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace($command.Source)) { $paths.Add($command.Source) }
    }

    return @($paths | Select-Object -Unique)
}

function Get-PowerShellExecutableVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($versionInfo.FileMajorPart -le 0) { return $null }
    return [version] ('{0}.{1}.{2}' -f $versionInfo.FileMajorPart, $versionInfo.FileMinorPart, $versionInfo.FileBuildPart)
}

function Find-PowerShell7 {
    param (
        [version] $RequiredVersion = [version] '7.4',
        [string[]] $CandidatePaths = @(Get-PowerShell7CandidatePaths)
    )

    foreach ($candidatePath in $CandidatePaths) {
        # VMBuild.cmd consumes this through SET /P. Reject paths that the active cmd
        # code page could corrupt rather than returning a path that cannot be launched.
        if ($candidatePath -match '[^\x00-\x7F]') { continue }
        $version = Get-PowerShellExecutableVersion -Path $candidatePath
        if ($null -ne $version -and $version -ge $RequiredVersion) {
            return [pscustomobject]@{
                Path    = [System.IO.Path]::GetFullPath($candidatePath)
                Version = $version
            }
        }
    }

    return $null
}

function Invoke-PowerShell7Install {
    param (
        [version] $RequiredVersion = [version] '7.4'
    )

    $choco = Get-Command choco.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Host 'PowerShell 7.4 or newer was not found. Installing the current PowerShell release with Chocolatey...'
        & $choco.Source upgrade pwsh -y
        return
    }

    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host 'PowerShell 7.4 or newer was not found. Installing the current PowerShell release with WinGet...'
        & $winget.Source upgrade --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --accept-package-agreements
        if ($null -eq (Find-PowerShell7 -RequiredVersion $RequiredVersion)) {
            & $winget.Source install --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --accept-package-agreements
        }
        return
    }

    throw 'PowerShell 7.4 or newer is required, but neither Chocolatey nor WinGet is available to install it.'
}

Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue

$powerShell = Find-PowerShell7 -RequiredVersion $MinimumVersion
if ($null -eq $powerShell) {
    Invoke-PowerShell7Install -RequiredVersion $MinimumVersion
    $powerShell = Find-PowerShell7 -RequiredVersion $MinimumVersion
}

if ($null -eq $powerShell) {
    throw "PowerShell $MinimumVersion or newer was not found after the installation attempt."
}

$resultDirectory = Split-Path -Parent $ResultPath
if ($resultDirectory -and -not (Test-Path -LiteralPath $resultDirectory)) {
    New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null
}
[System.IO.File]::WriteAllText($ResultPath, $powerShell.Path, [System.Text.Encoding]::ASCII)
Write-Host "Using PowerShell $($powerShell.Version) at '$($powerShell.Path)'."