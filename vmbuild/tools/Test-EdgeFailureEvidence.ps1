<#
.SYNOPSIS
    Verifies automatic Edge failure logs, version evidence, redaction and export bounds.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'common\Common.Maintenance.ps1')

function Assert-EdgeEvidence {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($prefix in @('https', '9https', '-https', '_https', 'foo+https')) {
    $redacted = Protect-VMFixDiagnosticText "${prefix}://TEST_SECRET@example.invalid/file"
    Assert-EdgeEvidence ($redacted -eq "${prefix}://[REDACTED]@example.invalid/file") `
        "URL-credential redaction changed for prefix '$prefix'."
}
$redactionWatch = [Diagnostics.Stopwatch]::StartNew()
$longText = Protect-VMFixDiagnosticText ('x' * 128KB) ([int]::MaxValue)
Assert-EdgeEvidence ($longText.Length -eq 128KB -and $redactionWatch.Elapsed.TotalSeconds -lt 5) `
    'Redacting a long MSI line exceeded its five-second budget or silently truncated it.'

$collector = Get-VMFixDiagnosticScriptBlock
Assert-EdgeEvidence ($collector.ToString() -notmatch 'Win32_Product|InstallProduct|Start-Process|Start-Service|Set-Service|Stop-Service|Stop-Process') `
    'The evidence collector can mutate guest software or services.'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-edge-evidence-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($testRoot)
$savedEnvironment = @{}
$savedCommon = $global:Common
foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramData', 'TEMP', 'TMP')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    function Invoke-EdgeEvidenceFixture {
        param([string]$Mode, [string]$FixName = 'Fix-EdgeServicing')
        & {
            param($Mode, $FixName, $Collector)
            $fixture = @{
                Mode = $Mode; EdgeLogReads = 0; Secret = 'TEST_EDGE_SECRET_NOT_FOR_LOGS'
                Directory = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
                Registry = @{}
            }
            $programs = Join-Path $fixture.Directory 'Programs'
            $data = Join-Path $fixture.Directory 'Data'
            $temporary = Join-Path $fixture.Directory 'Temp'
            $windows = Join-Path $fixture.Directory 'Windows'
            $systemTemporary = Join-Path $windows 'SystemTemp'
            $fixture.SystemTemporary = $systemTemporary
            $application = Join-Path $programs 'Microsoft\Edge\Application'
            $payloadDirectory = Join-Path $application '156.0.4314.58'
            $updaterRoot = Join-Path $data 'Microsoft\EdgeUpdate\Log'
            $staging = Join-Path $fixture.Directory 'Staging'
            foreach ($directory in @($payloadDirectory, $updaterRoot, $temporary, $systemTemporary, $staging)) {
                $null = [IO.Directory]::CreateDirectory($directory)
            }
            foreach ($path in @((Join-Path $application 'msedge.exe'), (Join-Path $application 'new_msedge.exe'),
                    (Join-Path $payloadDirectory 'msedge.dll'))) {
                [IO.File]::WriteAllText($path, 'fixture binary')
            }
            $fixture.MsiLog = Join-Path $staging 'EdgeServicing-MSI.log'
            $fixture.ResultLog = Join-Path $staging 'Fix-EdgeServicing.result.json'
            [IO.File]::WriteAllText($fixture.ResultLog, '{"Success":false,"Message":"browser version unchanged"}')
            $content = "MSI-BEGIN`r`npassword=$($fixture.Secret); url=https://example.invalid/a?sig=$($fixture.Secret)&sp=r`r`nMSI-END"
            if ($Mode -eq 'Oversized') { $content = (("payload " + ('x' * 100) + "`r`n") * 2400) + 'MSI-END' }
            if ($Mode -eq 'RedactionBoundary') {
                $content = "password=$($fixture.Secret)`r`n" + ('x' * (64KB - $fixture.Secret.Length - 2))
            }
            if ($Mode -eq 'Budget') { $content = (([string][char]0) * 65500) + 'MSI-END' }
            if ($Mode -ne 'Missing') { [IO.File]::WriteAllText($fixture.MsiLog, $content) }
            if ($Mode -eq 'Utf16') { [IO.File]::WriteAllText($fixture.MsiLog, $content, [Text.Encoding]::Unicode) }
            if ($Mode -ne 'Missing') {
                [IO.File]::WriteAllText((Join-Path $updaterRoot 'MicrosoftEdgeUpdate.log'), $content)
                [IO.File]::WriteAllText((Join-Path $updaterRoot 'MicrosoftEdgeUpdate.log.bak'), $content)
                [IO.File]::WriteAllText((Join-Path $temporary 'msedge_installer.log'), $content)
                [IO.File]::WriteAllText((Join-Path $systemTemporary 'msedge_installer-system.log'), $content)
            }
            if ($Mode -eq 'ManyLogs') {
                for ($index = 0; $index -lt 12; $index++) {
                    $path = Join-Path $temporary "msedge_installer-$index.log"
                    [IO.File]::WriteAllText($path, 'setup fixture')
                    [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddMinutes(-$index))
                }
            }
            [Environment]::SetEnvironmentVariable('ProgramFiles', $programs, 'Process')
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $programs, 'Process')
            [Environment]::SetEnvironmentVariable('ProgramData', $data, 'Process')
            [Environment]::SetEnvironmentVariable('TEMP', $temporary, 'Process')
            [Environment]::SetEnvironmentVariable('TMP', $temporary, 'Process')
            $fixture.Registry['HKLM:\SOFTWARE\Microsoft\Edge\BLBeacon'] = [pscustomobject]@{ version = '156.0.4314.58' }
            $fixture.Registry['HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'] =
                [pscustomobject]@{ pv = '156.0.4314.58'; name = 'Microsoft Edge' }
            $fixture.Registry['HKLM:\SYSTEM\CurrentControlSet\Services\edgeupdate'] =
                [pscustomobject]@{ ImagePath = 'C:\fixture\MicrosoftEdgeUpdate.exe /svc'; Start = 2 }

            function Convert-EdgeFixturePath {
                param([string]$Path)
                if ($Path -eq 'C:\staging\Fix\EdgeServicing-MSI.log') { return $fixture.MsiLog }
                if ($Path -eq 'C:\staging\Fix\Fix-EdgeServicing.result.json') { return $fixture.ResultLog }
                if ($Path -eq (Join-Path $env:SystemRoot 'SystemTemp')) { return $fixture.SystemTemporary }
                return $Path
            }
            function Test-Path {
                param($LiteralPath, $PathType, $ErrorAction)
                if ($LiteralPath -like 'HKLM:*') { return $fixture.Registry.ContainsKey($LiteralPath) }
                $mapped = Convert-EdgeFixturePath $LiteralPath
                if (-not $mapped.StartsWith($fixture.Directory, [StringComparison]::OrdinalIgnoreCase)) { return $false }
                if ($PathType -eq 'Container') { return [IO.Directory]::Exists($mapped) }
                if ($PathType -eq 'Leaf') { return [IO.File]::Exists($mapped) }
                return [IO.File]::Exists($mapped) -or [IO.Directory]::Exists($mapped)
            }
            function Get-Item {
                param($LiteralPath, $ErrorAction)
                $mapped = Convert-EdgeFixturePath $LiteralPath
                $file = Microsoft.PowerShell.Management\Get-Item -LiteralPath $mapped -ErrorAction Stop
                if ($file.Name -in @('msedge.exe', 'new_msedge.exe', 'msedge.dll')) {
                    $version = if ($file.Name -eq 'msedge.exe') { '156.0.4314.56' } else { '156.0.4314.58' }
                    return [pscustomobject]@{
                        FullName = $file.FullName; Length = $file.Length; LastWriteTimeUtc = $file.LastWriteTimeUtc
                        VersionInfo = [pscustomobject]@{ ProductVersion = $version; FileVersion = $version }
                    }
                }
                return $file
            }
            function Get-Content {
                param($LiteralPath, [switch]$Raw, $Tail, $ErrorAction)
                if ($LiteralPath -eq 'C:\staging\Fix\EdgeServicing-MSI.log') {
                    $fixture.EdgeLogReads++
                    if ($fixture.Mode -eq 'Unreadable') { throw [UnauthorizedAccessException]::new('synthetic MSI log access denied') }
                }
                $mapped = Convert-EdgeFixturePath $LiteralPath
                if ($Raw) { return Microsoft.PowerShell.Management\Get-Content -LiteralPath $mapped -Raw -ErrorAction Stop }
                return Microsoft.PowerShell.Management\Get-Content -LiteralPath $mapped -Tail $Tail -ErrorAction Stop
            }
            function Get-ChildItem {
                param($LiteralPath, [switch]$Directory, [switch]$File, $Filter, $ErrorAction)
                $mapped = Convert-EdgeFixturePath $LiteralPath
                if (-not $mapped.StartsWith($fixture.Directory, [StringComparison]::OrdinalIgnoreCase)) { return }
                $arguments = @{ LiteralPath = $mapped; ErrorAction = 'Stop' }
                if ($Directory) { $arguments.Directory = $true }
                if ($File) { $arguments.File = $true }
                if ($Filter) { $arguments.Filter = $Filter }
                Microsoft.PowerShell.Management\Get-ChildItem @arguments
            }
            function Get-ItemProperty { param($LiteralPath, $ErrorAction) $fixture.Registry[$LiteralPath] }
            function Get-Service {
                param($ErrorAction)
                [pscustomobject]@{ Name = 'edgeupdate'; Status = 'Stopped'; StartType = 'Automatic' }
                [pscustomobject]@{ Name = 'edgeupdatem'; Status = 'Stopped'; StartType = 'Manual' }
                [pscustomobject]@{ Name = 'Winmgmt'; Status = 'Running'; StartType = 'Automatic' }
            }
            function Get-Process {
                param($ErrorAction)
                [pscustomobject]@{ Id = 101; ProcessName = 'msedge'; Path = 'C:\fixture\msedge.exe'; CPU = 1 }
                [pscustomobject]@{ Id = 102; ProcessName = 'MicrosoftEdgeUpdate'; Path = 'C:\fixture\MicrosoftEdgeUpdate.exe'; CPU = 1 }
            }
            function Get-ScheduledTask {
                param($ErrorAction)
                [pscustomobject]@{ TaskName = 'MicrosoftEdgeUpdateTaskMachineUA'; TaskPath = '\'; State = 'Ready' }
            }
            function Get-PSDrive { param($PSProvider) [pscustomobject]@{ Name = 'C'; Free = 1GB; Used = 1GB } }
            function Get-Module { param([switch]$ListAvailable, $Name) }
            function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) }
            function New-Object { param($ComObject) throw 'Fixture Windows Installer inventory unavailable.' }

            $raw = & $Collector $FixName 'fixture-failure'
            [pscustomobject]@{ Raw = $raw; Snapshot = ($raw | ConvertFrom-Json); State = $fixture }
        } $Mode $FixName $collector
    }

    foreach ($mode in @('Complete', 'Utf16', 'Missing', 'Unreadable', 'Oversized', 'RedactionBoundary', 'Budget', 'ManyLogs')) {
        $probe = Invoke-EdgeEvidenceFixture -Mode $mode
        $snapshot = $probe.Snapshot
        Assert-EdgeEvidence ($probe.Raw.Length -le 512KB) "$mode exceeded the shared transfer budget."
        Assert-EdgeEvidence (-not $probe.Raw.Contains($probe.State.Secret)) "$mode leaked a product-log credential."
        $native = @($snapshot.Logs | Where-Object { $_.PSObject.Properties['Content'] })
        Assert-EdgeEvidence ($native.Count -le 6) "$mode exceeded the product-log count limit."
        foreach ($log in $native) {
            Assert-EdgeEvidence ($log.Content.Length -le $log.CaptureCharacterLimit) "$mode exceeded a product-log text limit."
        }
        $msi = @($native | Where-Object Path -eq 'C:\staging\Fix\EdgeServicing-MSI.log')
        $inventory = @($snapshot.Edge.LogInventory | Where-Object Path -eq 'C:\staging\Fix\EdgeServicing-MSI.log')
        Assert-EdgeEvidence ($inventory.Count -eq 1) "$mode omitted the expected MSI log from the inventory."
        if ($mode -eq 'Missing') {
            Assert-EdgeEvidence ($msi.Count -eq 0 -and -not $inventory[0].Exists -and
                -not $inventory[0].Collected -and $inventory[0].Error) 'Missing Edge logs were silently omitted.'
        }
        elseif ($mode -eq 'Unreadable') {
            Assert-EdgeEvidence ($msi.Count -eq 0 -and $inventory[0].Exists -and -not $inventory[0].Collected -and
                ($snapshot.CollectionErrors -join "`n") -match 'MSI log access denied') 'Unreadable Edge logs were silently omitted.'
        }
        else {
            Assert-EdgeEvidence ($msi.Count -eq 1 -and $inventory[0].Collected) "$mode failed to capture the Edge MSI log."
            Assert-EdgeEvidence ($native.Count -ge 4) "$mode omitted updater or browser setup logs."
        }
        if ($mode -in @('Complete', 'Utf16')) {
            Assert-EdgeEvidence ($msi[0].Content.Contains('MSI-BEGIN') -and $msi[0].Content.Contains('MSI-END') -and
                -not $msi[0].ContentTruncated) 'A small MSI log was not captured in full.'
            Assert-EdgeEvidence (@($native | Where-Object Path -Like '*\SystemTemp\msedge_installer-system.log').Count -eq 1) `
                'The SYSTEM installer log was not collected.'
        }
        if ($mode -eq 'Oversized') {
            Assert-EdgeEvidence ($msi[0].ContentTruncated -and $msi[0].Content.EndsWith('MSI-END') -and
                $inventory[0].Truncated) 'An oversized MSI log lost its useful tail or truncation metadata.'
        }
        if ($mode -eq 'Budget') {
            Assert-EdgeEvidence ($snapshot.TransferTruncated -and $msi[0].ContentTruncated -and
                $msi[0].CaptureCharacterLimit -eq 8KB -and $inventory[0].Truncated) `
                'Shared-budget reduction omitted its truncation evidence.'
        }
        Assert-EdgeEvidence (@($snapshot.Edge.BrowserFiles | Where-Object {
                    $_.Path -like '*\Application\msedge.exe' -and $_.ProductVersion -eq '156.0.4314.56'
                }).Count -eq 1) "$mode omitted the older browser launcher version."
        Assert-EdgeEvidence (@($snapshot.Edge.BrowserFiles | Where-Object {
                    $_.Path -like '*\156.0.4314.58\msedge.dll' -and $_.ProductVersion -eq '156.0.4314.58'
                }).Count -eq 1) "$mode omitted the versioned browser payload."
        Assert-EdgeEvidence (@($snapshot.Registry | Where-Object {
                    $_.Path -like '*\EdgeUpdate\Clients\*' -and $_.Values.pv -eq '156.0.4314.58'
                }).Count -eq 1) "$mode omitted independently registered Edge version evidence."
        Assert-EdgeEvidence ($snapshot.Edge.Services.Count -eq 2 -and $snapshot.Edge.Tasks.Count -eq 1 -and
            $snapshot.Edge.Processes.Count -eq 2) "$mode omitted updater or running-browser state."
    }
    foreach ($fixName in @('Fix-ODBC18', 'Fix-Upgrade-Console')) {
        $other = Invoke-EdgeEvidenceFixture -Mode 'Complete' -FixName $fixName
        Assert-EdgeEvidence (-not $other.Snapshot.PSObject.Properties['Edge'] -and $other.State.EdgeLogReads -eq 0) `
            "$fixName unexpectedly collected Edge-specific evidence."
    }

    $exportProbe = Invoke-EdgeEvidenceFixture -Mode 'Complete'
    function Write-Log { param($Message, [switch]$Warning, [switch]$LogOnly) }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$AsJob,
            $TimeoutSeconds, $SessionMaxRetries, [switch]$SuppressLog, [switch]$FailOnRemoteError, $VmDomainAccount)
        Assert-EdgeEvidence ($AsJob -and $TimeoutSeconds -eq 60 -and $SessionMaxRetries -eq 1 -and
            $FailOnRemoteError -and $VmDomainAccount -eq 'setupadmin') 'Evidence export lost its deadline or identity.'
        [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $exportProbe.Raw; ErrorDetails = $null }
    }
    $global:Common = [pscustomobject]@{
        LogPath = (Join-Path $testRoot 'VMBuild.log'); MemLabsVersion = 'fixture'; LatestHotfixVersion = 'fixture'
    }
    Save-VMFixFailureEvidence -VMName 'LAB-CLIENT' -VMDomain 'lab.test' -FixName 'Fix-EdgeServicing' -VMDomainAccount 'setupadmin'
    $saved = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.diagnostics.log' -File)
    Assert-EdgeEvidence ($saved.Count -eq 1) 'Edge evidence did not reach the existing host bundle sidecar.'
    $savedRaw = Get-Content -LiteralPath $saved[0].FullName -Raw
    $savedSnapshot = $savedRaw | ConvertFrom-Json
    Assert-EdgeEvidence (@($savedSnapshot.Logs | Where-Object {
                $_.Path -eq 'C:\staging\Fix\EdgeServicing-MSI.log' -and
                $_.Content.Contains('MSI-BEGIN') -and $_.Content.Contains('MSI-END')
            }).Count -eq 1 -and $savedSnapshot.HostSource) 'Product log content was dropped before bundle export.'
    Assert-EdgeEvidence (-not $savedRaw.Contains($exportProbe.State.Secret)) 'Exported product logs retained a credential.'
}
finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    $global:Common = $savedCommon
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- Automatic Edge failure logs, browser/updater state, redaction, explicit omissions, transfer bounds and host bundle export.'
