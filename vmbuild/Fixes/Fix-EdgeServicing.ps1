$Fix_EdgeServicing = {
    $ErrorActionPreference = 'Stop'
    function Get-LabEdgeVersion {
        $versions = @(
            foreach ($directory in @(${env:ProgramFiles(x86)},$env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique) {
                $path = Join-Path $directory 'Microsoft\Edge\Application\msedge.exe'
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $text = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo.ProductVersion
                    [version]$parsed = $null
                    if (-not [version]::TryParse("$text",[ref]$parsed)) { throw "Installed Edge has an unreadable version at '$path': '$text'." }
                    $parsed
                }
            }
        )
        $versions | Sort-Object -Descending | Select-Object -First 1
    }
    function Get-LabEdgePayload {
        param([Parameter(Mandatory)]$Products,[Parameter(Mandatory)][string]$Architecture)
        $stable = @($Products | Where-Object Product -eq 'Stable')
        if ($stable.Count -ne 1) { throw 'Official Edge metadata did not contain exactly one Stable product.' }
        $releases = @($stable[0].Releases | Where-Object { $_.Platform -eq 'Windows' -and $_.Architecture -eq $Architecture })
        foreach ($release in $releases) {
            [version]$version = $null
            if (-not [version]::TryParse("$($release.ProductVersion)",[ref]$version)) { throw 'Official Edge metadata contains an invalid Stable version.' }
        }
        $release = $releases | Sort-Object {[version]$_.ProductVersion} -Descending | Select-Object -First 1
        if (-not $release) { throw "No Windows/$Architecture Stable Edge release was returned." }
        $artifacts = @($release.Artifacts | Where-Object ArtifactName -eq 'msi')
        if ($artifacts.Count -ne 1) { throw 'Stable Edge metadata did not contain exactly one MSI artifact.' }
        $artifact = $artifacts[0]
        [uri]$uri = $null
        if (-not [uri]::TryCreate("$($artifact.Location)",[UriKind]::Absolute,[ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or
            $uri.DnsSafeHost -notmatch '(^|\.)dl\.delivery\.mp\.microsoft\.com$' -or
            $artifact.HashAlgorithm -ne 'SHA256' -or "$($artifact.Hash)" -notmatch '^[A-Fa-f0-9]{64}$' -or
            [long]$artifact.SizeInBytes -le 0 -or [long]$artifact.SizeInBytes -gt 1GB) {
            throw 'Stable Edge MSI metadata failed origin, integrity, or size validation.'
        }
        [pscustomobject]@{
            Version = [version]$release.ProductVersion; Uri = $uri.AbsoluteUri
            Hash = "$($artifact.Hash)"; Bytes = [long]$artifact.SizeInBytes
        }
    }
    function Restore-LabEdgeUpdates {
        param([switch]$AllowMissing)
        $services = @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService') })
        foreach ($service in $services) {
            $startup = if ($service.Name -eq 'edgeupdate') { 'Automatic' } else { 'Manual' }
            Set-Service -Name $service.Name -StartupType $startup -ErrorAction Stop
        }
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -Like 'MicrosoftEdgeUpdate*')
        foreach ($task in $tasks) { $null = Enable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop }
        if (-not $AllowMissing) {
            $core = @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -in @('edgeupdate','edgeupdatem') })
            if ($core.Count -eq 0 -or @($core | Where-Object StartType -eq 'Disabled').Count) { throw 'Edge updater services are missing or remain disabled.' }
            $verified = @(Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -Like 'MicrosoftEdgeUpdate*')
            if ($verified.Count -eq 0 -or @($verified | Where-Object State -eq 'Disabled').Count) { throw 'Edge updater tasks are missing or remain disabled.' }
            Write-FixLog 'Edge updater startup types and scheduled tasks restored; updater services may remain stopped while idle.'
        }
    }
    $temporary = $null
    $savedProtocol = [Net.ServicePointManager]::SecurityProtocol
    $savedProgress = $ProgressPreference
    $restored = $false
    $repairRequested = $false
    $repairAttempted = $false
    $exitCode = $null
    try {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
        if (Test-Path -LiteralPath $policyPath) {
            $policy = Get-ItemProperty -LiteralPath $policyPath -ErrorAction Stop
            foreach ($name in @('Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}','UpdateDefault')) {
                $entry = $policy.PSObject.Properties[$name]
                if (-not $entry) { continue }
                if ($entry.Value -in @(0,2)) { throw "Automatic Edge updates are disabled by policy '$name'; the policy was not changed." }
                break
            }
            foreach ($name in @('TargetVersionPrefix{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}','TargetChannel{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}')) {
                $entry = $policy.PSObject.Properties[$name]
                if ($entry -and -not [string]::IsNullOrWhiteSpace("$($entry.Value)") -and
                    -not ($name -like 'TargetChannel*' -and $entry.Value -eq 'stable')) {
                    throw "Edge update target is managed by policy '$name'; it was not overridden."
                }
            }
        }
        [Net.ServicePointManager]::SecurityProtocol = $savedProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' }
        elseif ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        $products = Invoke-RestMethod -Uri 'https://edgeupdates.microsoft.com/api/products?view=enterprise' -TimeoutSec 30 -ErrorAction Stop
        $payload = Get-LabEdgePayload -Products $products -Architecture $architecture
        $before = Get-LabEdgeVersion
        Write-FixLog "Edge Stable required=$($payload.Version); installed=$before; architecture=$architecture."
        if (-not $before -or $before -lt $payload.Version) {
            $temporary = Join-Path $env:TEMP "MemLabs-Edge-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -Path $temporary -ItemType Directory -ErrorAction Stop
            $installer = Join-Path $temporary 'MicrosoftEdgeEnterprise.msi'
            $null = Invoke-WebRequest -Uri $payload.Uri -OutFile $installer -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
            $item = Get-Item -LiteralPath $installer -ErrorAction Stop
            if ($item.Length -ne $payload.Bytes -or (Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop).Hash -ine $payload.Hash) {
                throw 'Downloaded Edge MSI does not match the official size/SHA-256 metadata; it was not installed.'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $installer -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
                throw 'Downloaded Edge MSI has no valid Microsoft signature; it was not installed.'
            }
            $logPath = 'C:\staging\Fix\EdgeServicing-MSI.log'
            $null = New-Item -Path (Split-Path $logPath -Parent) -ItemType Directory -Force -ErrorAction Stop
            $installClock = [Diagnostics.Stopwatch]::StartNew()
            for ($attempt=1; $attempt -le 3; $attempt++) {
                $observed = Get-LabEdgeVersion
                if ($observed -and $observed -ge $payload.Version) { break }
                $remainingMilliseconds = 600000 - [int]$installClock.Elapsed.TotalMilliseconds
                if ($remainingMilliseconds -le 0) { throw "Edge MSI exceeded its 600-second limit; see $logPath." }
                $logOption = if ($attempt -eq 1) { '/L*v' } else { '/L*v+' }
                $arguments = @('/i',"`"$installer`"",'/qn','/norestart',$logOption,"`"$logPath`"")
                if ($repairRequested) {
                    $arguments += @('REINSTALL=ALL', 'REINSTALLMODE=vomus')
                    $repairAttempted = $true
                }
                $mode = if ($repairRequested) { 'repair' } else { 'install' }
                Write-FixLog "Edge MSI attempt $attempt/3; mode=$mode; remaining budget=$remainingMilliseconds ms."
                $process = $null
                try {
                    $process = Start-Process -FilePath "$env:WINDIR\System32\msiexec.exe" `
                        -ArgumentList $arguments -PassThru -ErrorAction Stop
                    $null = $process.Handle
                    if (-not $process.WaitForExit($remainingMilliseconds)) {
                        Stop-Process -Id $process.Id -Force -ErrorAction Stop
                        $null = $process.WaitForExit(5000)
                        throw "Edge MSI exceeded its 600-second limit; see $logPath."
                    }
                    $process.WaitForExit()
                    $process.Refresh()
                    $exitCode = $process.ExitCode
                    if ($null -eq $exitCode) { throw "Edge MSI returned no exit code; see $logPath." }
                }
                finally { if ($process) { $process.Dispose() } }
                Write-FixLog "Edge MSI attempt $attempt/3 completed; mode=$mode; exit=$exitCode."
                if ($exitCode -in @(0,3010)) {
                    for ($verification=1; $verification -le 7; $verification++) {
                        $observed = Get-LabEdgeVersion
                        if ($observed -and $observed -ge $payload.Version) { break }
                        if ($verification -ge 7) { break }
                        $remainingMilliseconds = 600000 - [int]$installClock.Elapsed.TotalMilliseconds
                        if ($remainingMilliseconds -le 0) { break }
                        Start-Sleep -Milliseconds ([int][math]::Min(5000, $remainingMilliseconds))
                    }
                    if ($observed -and $observed -ge $payload.Version) { break }
                    if ($exitCode -eq 0 -and -not $repairAttempted -and $attempt -lt 3) {
                        $repairRequested = $true
                        Write-FixLog "Edge MSI returned success but browser '$observed' is below '$($payload.Version)'; retrying the verified package in repair mode so an already-registered MSI cannot skip browser installation." -Level Warning
                        continue
                    }
                    break
                }
                if ($exitCode -eq 1618 -and $attempt -lt 3) {
                    if ($installClock.Elapsed.TotalMilliseconds -gt 585000) { throw "Edge MSI has insufficient retry time remaining in its 600-second budget; see $logPath." }
                    Write-FixLog 'Another MSI is active; retrying Edge installation in 15 seconds.'
                    Start-Sleep -Seconds 15
                    continue
                }
                throw "Edge MSI failed with exit code $exitCode; see $logPath."
            }
        }
        $after = Get-LabEdgeVersion
        if (-not $after -or $after -lt $payload.Version) {
            $detail = if ($exitCode -eq 3010) { 'MSI returned 3010; a reboot is required before browser convergence can be verified.' }
            elseif ($repairAttempted) { 'The explicit MSI repair did not converge; MSI registration alone is not browser verification.' }
            else { 'The bounded MSI attempts did not converge; no additional repair attempt was permitted.' }
            throw "Edge is not at the required Stable release after maintenance (required=$($payload.Version), installed=$after). $detail See C:\staging\Fix\EdgeServicing-MSI.log."
        }
        Restore-LabEdgeUpdates
        $restored = $true
        [pscustomobject]@{ Success=$true; Message="Edge $after verified; automatic update services/tasks restored. Reopen any existing Edge windows."; Errors=@() }
    }
    catch {
        Write-FixLog "Edge servicing failed: $($_.Exception.Message)" -Level Failure
        [pscustomobject]@{ Success=$false; Message=$_.Exception.Message; Errors=@($_.Exception.ToString()) }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $savedProtocol
        $ProgressPreference = $savedProgress
        if (-not $restored) {
            try { Restore-LabEdgeUpdates -AllowMissing }
            catch { Write-FixLog "Edge updater restoration also failed: $($_.Exception.Message)" -Level Failure }
        }
        if ($temporary -and [IO.Directory]::Exists($temporary)) {
            try { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop }
            catch { Write-FixLog "Edge installer cleanup failed at '$temporary': $($_.Exception.Message)" -Level Warning }
        }
    }
}

$fixesToPerform += [pscustomobject]@{
    FixName='Fix-EdgeServicing'; FixVersion='261102.0'; NeededOnFreshDeploy=$true; AppliesToExisting=$true
    DoNotSeedFromWatermark=$true; AppliesToRoles=@()
    NotAppliesToRoles=@('OSDClient','AADClient','Proxy','LinuxClient','LinuxServer','StandaloneRootCA')
    DependentVMs=@(); ScriptBlock=$Fix_EdgeServicing
}
