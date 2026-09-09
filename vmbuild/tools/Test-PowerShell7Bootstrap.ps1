<#
.SYNOPSIS
    Verifies that VMBuild resolves PowerShell 7.4+ and cannot launch New-Lab with PS5.
#>
[CmdletBinding()]
param (
    [string] $RootPath
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

$ensurePath = Join-Path $RootPath 'Ensure-PowerShell7.ps1'
$launcherPath = Join-Path $RootPath 'VMBuild.cmd'
$newLabPath = Join-Path $RootPath 'New-Lab.ps1'
foreach ($path in @($ensurePath, $launcherPath, $newLabPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "SETUP FAIL: missing $path" -ForegroundColor Red
        exit 2
    }
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $ensurePath).Path, [ref] $tokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: Ensure-PowerShell7.ps1 has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wantedFunctions = @('Get-PowerShell7CandidatePaths', 'Find-PowerShell7', 'Invoke-PowerShell7Install')
$loadedFunctions = @()
foreach ($functionNode in $ast.FindAll({
            param ($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    if ($wantedFunctions -contains $functionNode.Name) {
        . ([scriptblock]::Create($functionNode.Extent.Text))
        $loadedFunctions += $functionNode.Name
    }
}
$missingFunctions = @($wantedFunctions | Where-Object { $loadedFunctions -notcontains $_ })
if ($missingFunctions.Count -gt 0) {
    Write-Host "SETUP FAIL: functions not found in Ensure-PowerShell7.ps1: $($missingFunctions -join ', ')" -ForegroundColor Red
    exit 2
}

$script:Versions = @{}
function Get-PowerShellExecutableVersion {
    param ([string] $Path)
    return $script:Versions[$Path]
}

$canonicalPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$pathCandidate = 'C:\tools\pwsh.exe'
$appPathCandidate = 'C:\RegistryAppPath\pwsh.exe'
$uninstallCandidate = 'C:\RegistryInstall\pwsh.exe'
function Get-ItemProperty {
    param ([string] $LiteralPath, [string] $Path, [string] $ErrorAction)

    if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe') {
        return [pscustomobject]@{ '(default)' = $appPathCandidate }
    }
    if ($Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        return [pscustomobject]@{ DisplayName = 'PowerShell 7-x64'; InstallLocation = 'C:\RegistryInstall' }
    }
    return $null
}
$savedCandidateEnvironment = @{
    Path = $env:PATH
    ProgramFiles = $env:ProgramFiles
    ProgramW6432 = $env:ProgramW6432
}
try {
    $env:PATH = Join-Path ([System.IO.Path]::GetTempPath()) 'no-pwsh-on-path'
    $env:ProgramFiles = 'C:\Program Files (x86)'
    $env:ProgramW6432 = 'C:\Program Files'
    $candidatePaths = @(Get-PowerShell7CandidatePaths)
    Assert-Equal $true ($candidatePaths -contains 'C:\Program Files\PowerShell\7\pwsh.exe') 'candidate discovery uses the 64-bit Program Files root when PATH is stale'
    Assert-Equal $true ($candidatePaths -contains 'C:\Program Files (x86)\PowerShell\7\pwsh.exe') 'candidate discovery also considers the current process Program Files root'
    Assert-Equal $true ($candidatePaths -contains $appPathCandidate) 'candidate discovery reads the registered pwsh App Path'
    Assert-Equal $true ($candidatePaths -contains $uninstallCandidate) 'candidate discovery reads PowerShell uninstall InstallLocation'
}
finally {
    $env:PATH = $savedCandidateEnvironment.Path
    $env:ProgramFiles = $savedCandidateEnvironment.ProgramFiles
    $env:ProgramW6432 = $savedCandidateEnvironment.ProgramW6432
}

$script:Versions = @{ $canonicalPath = [version] '7.6.6' }
$found = Find-PowerShell7 -RequiredVersion ([version] '7.4') -CandidatePaths @($canonicalPath)
Assert-Equal $canonicalPath $found.Path 'canonical install is found without relying on PATH'
Assert-Equal '7.6.6' $found.Version 'resolved binary version is returned'

$script:Versions = @{ $pathCandidate = [version] '7.3.9'; $canonicalPath = [version] '7.4.1' }
$found = Find-PowerShell7 -RequiredVersion ([version] '7.4') -CandidatePaths @($pathCandidate, $canonicalPath)
Assert-Equal $canonicalPath $found.Path 'an outdated candidate is skipped for a supported binary'

$script:Versions = @{ $pathCandidate = [version] '7.3.9' }
$found = Find-PowerShell7 -RequiredVersion ([version] '7.4') -CandidatePaths @($pathCandidate)
Assert-Equal $null $found 'PowerShell below 7.4 is rejected'

$unicodeCandidate = 'C:\PowerShell-' + [char] 0x00FC + '\pwsh.exe'
$script:Versions = @{ $unicodeCandidate = [version] '7.6.6' }
$found = Find-PowerShell7 -RequiredVersion ([version] '7.4') -CandidatePaths @($unicodeCandidate)
Assert-Equal $null $found 'a path that cmd cannot transport safely is rejected instead of corrupted'

$script:PackageProvider = 'choco'
$script:PackageCalls = @()
$script:PowerShellInstalled = $false
function Get-Command {
    param ([string] $Name, [string] $CommandType, [string] $ErrorAction)

    if ($script:PackageProvider -eq 'choco' -and $Name -eq 'choco.exe') {
        return [pscustomobject]@{ Source = 'choco.exe' }
    }
    if ($script:PackageProvider -eq 'winget' -and $Name -eq 'winget.exe') {
        return [pscustomobject]@{ Source = 'winget.exe' }
    }
    return $null
}
function choco.exe {
    $script:PackageCalls += ,@($args)
    $global:LASTEXITCODE = 0
}
function winget.exe {
    $script:PackageCalls += ,@($args)
    if ($args[0] -eq 'install') { $script:PowerShellInstalled = $true }
    $global:LASTEXITCODE = 0
}

Invoke-PowerShell7Install -RequiredVersion ([version] '7.4')
Assert-Equal 2 $script:PackageCalls.Count 'Chocolatey bootstrap repairs a package record with no usable executable'
Assert-Equal 'upgrade pwsh -y' ($script:PackageCalls[0] -join ' ') 'Chocolatey installs or upgrades the pwsh package'
Assert-Equal 'install pwsh -y --force' ($script:PackageCalls[1] -join ' ') 'Chocolatey force-repairs PowerShell when upgrade leaves no usable binary'

function Find-PowerShell7 {
    param ([version] $RequiredVersion)
    if ($script:PowerShellInstalled) {
        return [pscustomobject]@{ Path = $canonicalPath; Version = [version] '7.6.6' }
    }
    return $null
}
$script:PackageProvider = 'winget'
$script:PackageCalls = @()
$script:PowerShellInstalled = $false
Invoke-PowerShell7Install -RequiredVersion ([version] '7.4')
Assert-Equal 2 $script:PackageCalls.Count 'WinGet bootstrap retries installation when upgrade did not create a usable binary'
Assert-Equal 'upgrade --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --accept-package-agreements' ($script:PackageCalls[0] -join ' ') 'WinGet first attempts an in-place upgrade'
Assert-Equal 'install --id Microsoft.PowerShell --exact --source winget --silent --force --accept-source-agreements --accept-package-agreements' ($script:PackageCalls[1] -join ' ') 'WinGet force-repairs PowerShell when an installed record has no usable binary'

$launcherText = [System.IO.File]::ReadAllText($launcherPath)
Assert-Equal $true $launcherText.Contains('-File ".\Ensure-PowerShell7.ps1"') 'VMBuild invokes the bootstrap before launch'
Assert-Equal $true $launcherText.Contains("PSVersionTable.PSVersion -lt [version]'7.4'") 'VMBuild independently verifies the resolved process version'
Assert-Equal $true ($launcherText.IndexOf('-File ".\Ensure-PowerShell7.ps1"', [System.StringComparison]::Ordinal) -lt $launcherText.IndexOf('-File ".\Invoke-Maintenance.ps1"', [System.StringComparison]::Ordinal)) 'PowerShell bootstrap completes before maintenance package work'
Assert-Equal $false ([regex]::IsMatch($launcherText, '(?im)^:PS5\s*$')) 'VMBuild has no PS5 launch label'
Assert-Equal $false $launcherText.Contains('falling back to PowerShell 5') 'VMBuild has no PowerShell 5 fallback'

$launchLines = @($launcherText -split "`r?`n" | Where-Object { $_ -match 'New-Lab\.ps1' })
Assert-Equal 5 $launchLines.Count 'all five New-Lab launch paths are measured'
Assert-Equal 0 @($launchLines | Where-Object { $_ -notmatch '"%PS7%"' }).Count 'every New-Lab launch uses the verified PowerShell 7 path'

$launcherLines = @($launcherText -split "`r?`n")
$requirementLabelIndex = [array]::IndexOf($launcherLines, ':POWERSHELL7_REQUIRED')
if ($requirementLabelIndex -lt 0) {
    Write-Host 'SETUP FAIL: VMBuild.cmd has no POWERSHELL7_REQUIRED label' -ForegroundColor Red
    exit 2
}
$cmdFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mlcmd-' + [guid]::NewGuid().ToString('N'))
$cmdFixturePath = Join-Path $cmdFixtureRoot 'VMBuild-failure.cmd'
$cmdOutputPath = Join-Path $cmdFixtureRoot 'stdout.txt'
$cmdErrorPath = Join-Path $cmdFixtureRoot 'stderr.txt'
try {
    $null = New-Item -Path $cmdFixtureRoot -ItemType Directory -Force
    $cmdFixtureLines = @('@ECHO OFF', 'SETLOCAL', 'SET "PS7_RESULT=missing-result.txt"', 'GOTO POWERSHELL7_REQUIRED') + $launcherLines[$requirementLabelIndex..($launcherLines.Count - 1)]
    [System.IO.File]::WriteAllText($cmdFixturePath, (($cmdFixtureLines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    $cmdProcess = Start-Process -FilePath $env:ComSpec -ArgumentList @('/D', '/C', 'CALL', ('"{0}"' -f $cmdFixturePath)) `
        -RedirectStandardOutput $cmdOutputPath -RedirectStandardError $cmdErrorPath -PassThru -Wait
    Assert-Equal 1 $cmdProcess.ExitCode 'PowerShell prerequisite failure returns exit 1 through CMD cleanup'
}
finally {
    Remove-Item -LiteralPath $cmdFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$newLabText = [System.IO.File]::ReadAllText($newLabPath)
$guardIndex = $newLabText.IndexOf("if (`$PSVersionTable.PSEdition -ne 'Core' -or `$PSVersionTable.PSVersion -lt [version] '7.4')", [System.StringComparison]::Ordinal)
$bannerIndex = $newLabText.IndexOf('MemLabs New-Lab starting...', [System.StringComparison]::Ordinal)
$commonIndex = $newLabText.IndexOf('. $PSScriptRoot\Common.ps1', [System.StringComparison]::Ordinal)
Assert-Equal $true ($guardIndex -ge 0) 'New-Lab contains an explicit 7.4 Core guard'
Assert-Equal $true ($guardIndex -lt $bannerIndex -and $guardIndex -lt $commonIndex) 'New-Lab rejects PS5 before startup or Common initialization'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mlps7-' + [guid]::NewGuid().ToString('N'))
$providerDirectory = Join-Path $fixtureRoot 'bin'
$providerPath = Join-Path $providerDirectory 'choco.exe'
$providerSourcePath = Join-Path $fixtureRoot 'FakePackageProvider.cs'
$providerLog = Join-Path $fixtureRoot 'provider.log'
$resultPath = Join-Path $fixtureRoot 'resolved.txt'
$standardOutputPath = Join-Path $fixtureRoot 'stdout.txt'
$standardErrorPath = Join-Path $fixtureRoot 'stderr.txt'
$savedEnvironment = @{
    Path = $env:PATH
    ProgramFiles = $env:ProgramFiles
    ProgramW6432 = $env:ProgramW6432
    ProviderLog = $env:MEMLABS_FAKE_PROVIDER_LOG
}

try {
    $null = New-Item -Path $providerDirectory -ItemType Directory -Force
    $providerSource = @'
using System;
using System.IO;

public static class FakePackageProvider
{
    public static int Main(string[] args)
    {
        File.AppendAllText(Environment.GetEnvironmentVariable("MEMLABS_FAKE_PROVIDER_LOG"), String.Join(" ", args) + Environment.NewLine);
        return 0;
    }
}
'@
    [System.IO.File]::WriteAllText($providerSourcePath, $providerSource, [System.Text.Encoding]::ASCII)
    $compilerPath = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compilerPath) { throw 'The .NET Framework C# compiler required by the isolated provider test was not found.' }
    & $compilerPath /nologo /target:exe "/out:$providerPath" $providerSourcePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $providerPath -PathType Leaf)) {
        throw "Could not compile the isolated provider fixture (csc exit $LASTEXITCODE)."
    }
    [System.IO.File]::WriteAllText($resultPath, 'stale result', [System.Text.Encoding]::ASCII)

    $env:PATH = $providerDirectory
    $env:ProgramFiles = Join-Path $fixtureRoot 'ProgramFiles'
    $env:ProgramW6432 = Join-Path $fixtureRoot 'ProgramW6432'
    $env:MEMLABS_FAKE_PROVIDER_LOG = $providerLog

    $powershell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powershell51 -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $ensurePath), '-ResultPath', ('"{0}"' -f $resultPath), '-MinimumVersion', '7.4',
        '-CandidatePaths', ('"{0}"' -f (Join-Path $fixtureRoot 'missing-pwsh.exe'))
    ) -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath -PassThru -Wait

    $providerCalls = @(if (Test-Path -LiteralPath $providerLog) { Get-Content -LiteralPath $providerLog })
    $failureOutput = @(
        Get-Content -LiteralPath $standardOutputPath -ErrorAction SilentlyContinue
        Get-Content -LiteralPath $standardErrorPath -ErrorAction SilentlyContinue
    ) -join "`n"
    Assert-Equal 1 $process.ExitCode 'bootstrap fails when a successful provider call installs no supported binary'
    Assert-Equal 2 $providerCalls.Count 'failed bootstrap attempts upgrade and forced repair'
    Assert-Equal 'upgrade pwsh -y' $providerCalls[0] 'failed bootstrap attempted the expected Chocolatey upgrade'
    Assert-Equal 'install pwsh -y --force' $providerCalls[1] 'failed bootstrap attempted the expected Chocolatey forced repair'
    Assert-Equal $true $failureOutput.Contains('Candidates:') 'failed bootstrap reports candidate evidence'
    Assert-Equal $true $failureOutput.Contains('missing-pwsh.exe [missing or unreadable]') 'failed bootstrap identifies the unusable candidate'
    Assert-Equal $false (Test-Path -LiteralPath $resultPath) 'failed bootstrap removes the stale result file'

    Remove-Item -LiteralPath $providerPath -Force
    $wingetProviderPath = Join-Path $providerDirectory 'winget.exe'
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'FakePackageProvider.exe') -Destination $wingetProviderPath -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $wingetProviderPath)) {
        & $compilerPath /nologo /target:exe "/out:$wingetProviderPath" $providerSourcePath
        if ($LASTEXITCODE -ne 0) { throw "Could not compile the isolated WinGet fixture (csc exit $LASTEXITCODE)." }
    }
    Remove-Item -LiteralPath $providerLog, $standardOutputPath, $standardErrorPath -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($resultPath, 'stale result', [System.Text.Encoding]::ASCII)

    $process = Start-Process -FilePath $powershell51 -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $ensurePath), '-ResultPath', ('"{0}"' -f $resultPath), '-MinimumVersion', '7.4',
        '-CandidatePaths', ('"{0}"' -f (Join-Path $fixtureRoot 'missing-pwsh.exe'))
    ) -RedirectStandardOutput $standardOutputPath -RedirectStandardError $standardErrorPath -PassThru -Wait

    $providerCalls = @(if (Test-Path -LiteralPath $providerLog) { Get-Content -LiteralPath $providerLog })
    Assert-Equal 1 $process.ExitCode 'WinGet bootstrap fails when forced repair creates no supported binary'
    Assert-Equal 2 $providerCalls.Count 'WinGet failure path attempts upgrade and forced repair'
    Assert-Equal 'upgrade --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --accept-package-agreements' $providerCalls[0] 'end-to-end WinGet path first attempts upgrade'
    Assert-Equal 'install --id Microsoft.PowerShell --exact --source winget --silent --force --accept-source-agreements --accept-package-agreements' $providerCalls[1] 'end-to-end WinGet path force-repairs the installed package record'
    Assert-Equal $false (Test-Path -LiteralPath $resultPath) 'failed WinGet repair removes the stale result file'
}
finally {
    $env:PATH = $savedEnvironment.Path
    $env:ProgramFiles = $savedEnvironment.ProgramFiles
    $env:ProgramW6432 = $savedEnvironment.ProgramW6432
    $env:MEMLABS_FAKE_PROVIDER_LOG = $savedEnvironment.ProviderLog
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0