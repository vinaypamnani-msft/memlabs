function Get-MemLabsFirstLogonGuestBlock {
    $setup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\DSC\phases\WindowsSetupReadiness.ps1') -Raw -ErrorAction Stop
    $queries = {
        param([ValidateSet('State', 'Appx')][string]$Action)
        $ErrorActionPreference = 'Stop'
        $errors = [Collections.Generic.List[string]]::new()
        $machineGuid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse($machineGuid, [ref]$parsedGuid)) { throw 'The live guest machine GUID is invalid.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $actor = [pscustomobject]@{ Name = $identity.Name; Sid = $identity.User.Value }
            $administrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        finally { $identity.Dispose() }
        if (-not $administrator) { throw 'The read-only live probe requires a guest administrator.' }
        $result = [ordered]@{
            Version = 1; Scope = 'WindowsFirstLogonProbe'; Action = $Action; ReadOnly = $true
            MachineGuid = $machineGuid; CapturedAtUtc = [DateTime]::UtcNow.ToString('o'); Actor = $actor
        }

        function Get-ProbeManifestState {
            param([string]$Location, [bool]$Bundle)
            if ([string]::IsNullOrWhiteSpace($Location)) {
                return [pscustomobject]@{ Path = $null; Status = 'NotDeclared'; Error = $null }
            }
            $path = $Location
            try {
                if ($Location -notmatch '^[A-Za-z]:\\|^\\\\\?\\Volume\{[0-9a-f-]+\}\\') {
                    throw 'A package install location is not a local absolute path.'
                }
                $relative = if ($Bundle) { 'AppxMetadata\AppxBundleManifest.xml' } else { 'AppxManifest.xml' }
                $path = Join-Path $Location $relative
                $attributes = [IO.File]::GetAttributes($path)
                if ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) {
                    throw 'The declared manifest is a directory or reparse point.'
                }
                [pscustomobject]@{ Path = $path; Status = 'Present'; Error = $null }
            }
            catch [IO.FileNotFoundException] { [pscustomobject]@{ Path = $path; Status = 'Absent'; Error = $null } }
            catch [IO.DirectoryNotFoundException] { [pscustomobject]@{ Path = $path; Status = 'Absent'; Error = $null } }
            catch {
                $errors.Add("Manifest '$path': $($_.Exception.Message)")
                [pscustomobject]@{ Path = $path; Status = 'Error'; Error = $_.Exception.Message }
            }
        }

        if ($Action -eq 'State') {
            $setupState = Get-MemLabsWindowsClientSetupState
            if ($null -eq $setupState.ProductType -and $setupState.Reason -eq 'ProbeFailed' -and
                $setupState.Ready -is [bool] -and -not $setupState.Ready -and @($setupState.Diagnostics).Count -gt 0) {
                $result['Setup'] = $setupState
                $result['Processes'] = @(); $result['DefaultUserAccount'] = @(); $result['Services'] = @()
                $result['Errors'] = @("Windows setup-state query failed: $($setupState.Detail)")
                $result['Status'] = 'Partial'
                return [pscustomobject]$result
            }
            if ($setupState.ProductType -ne 1) {
                throw "Live first-logon inspection requires a Windows client. Reported ProductType=$($setupState.ProductType); $($setupState.Detail)"
            }
            $result['Setup'] = $setupState
            $result['DefaultUserAccount'] = @(Get-CimInstance -ClassName Win32_UserAccount `
                -Filter "LocalAccount=TRUE AND Name='defaultuser0'" -OperationTimeoutSec 10 -ErrorAction Stop |
                Select-Object Name, SID, Disabled, Status)
            try {
                $services = @(Get-CimInstance -ClassName Win32_Service `
                    -Filter "Name='AppReadiness' OR Name='AppXSvc' OR Name='ClipSVC' OR Name='StateRepository' OR Name='UserManager' OR Name='ProfSvc'" `
                    -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object Name, State, StartMode, ProcessId, ExitCode)
                if ($services.Count -gt 16) { throw 'Service data exceeds the 16-record diagnostic limit.' }
                $result['Services'] = $services
            }
            catch { $result['Services'] = @(); $errors.Add("First-logon services: $($_.Exception.Message)") }
            $names = @('FirstLogonAnim.exe', 'winlogon.exe', 'LogonUI.exe', 'userinit.exe', 'explorer.exe',
                'CloudExperienceHostBroker.exe', 'CloudExperienceHost.exe', 'msoobe.exe', 'WWAHost.exe',
                'ShellExperienceHost.exe', 'StartMenuExperienceHost.exe', 'StartExperiencesApp.exe')
            $filter = ($names | ForEach-Object { "Name='$_'" }) -join ' OR '
            $processes = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -OperationTimeoutSec 10 -ErrorAction Stop)
            if ($processes.Count -gt 64) { throw 'The live process snapshot exceeds its 64-process limit.' }
            $records = [Collections.Generic.List[object]]::new()
            $ownerQueries = 0
            foreach ($process in $processes) {
                $record = [ordered]@{
                    Name = $process.Name; ProcessId = $process.ProcessId; ParentProcessId = $process.ParentProcessId
                    SessionId = $process.SessionId; CreationDate = $process.CreationDate; ExecutablePath = $process.ExecutablePath
                    OwnerSid = $null; OwnerStatus = 'NotRequested'; Threads = @(); Error = $null
                }
                if ($process.Name -in @('FirstLogonAnim.exe', 'CloudExperienceHost.exe', 'msoobe.exe', 'explorer.exe')) {
                    try {
                        if (++$ownerQueries -gt 8) { throw 'The live snapshot exceeds its eight process-owner-query limit.' }
                        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -OperationTimeoutSec 3 -ErrorAction Stop
                        if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($owner.Sid)) {
                            throw "Process owner query returned $($owner.ReturnValue) without a usable SID."
                        }
                        $record.OwnerSid = $owner.Sid; $record.OwnerStatus = 'Captured'
                    }
                    catch {
                        $record.OwnerStatus = 'Error'; $record.Error = $_.Exception.Message
                        $errors.Add("Process owner $($process.Name)/$($process.ProcessId): $($_.Exception.Message)")
                    }
                }
                if ($process.Name -eq 'FirstLogonAnim.exe') {
                    $liveProcess = $null
                    try {
                        $liveProcess = Get-Process -Id $process.ProcessId -ErrorAction Stop
                        $threads = @($liveProcess.Threads)
                        if ($threads.Count -gt 64) { throw 'FirstLogonAnim exceeds the 64-thread diagnostic limit.' }
                        $record['Responding'] = $liveProcess.Responding
                        $record['MainWindowTitle'] = $liveProcess.MainWindowTitle
                        $record.Threads = @($threads | ForEach-Object {
                                $reason = if ("$($_.ThreadState)" -eq 'Wait') { "$($_.WaitReason)" } else { $null }
                                [pscustomobject]@{ Id = $_.Id; State = "$($_.ThreadState)"; WaitReason = $reason }
                            })
                    }
                    catch {
                        $record.Error = $_.Exception.Message
                        $errors.Add("FirstLogonAnim process/thread snapshot: $($_.Exception.Message)")
                    }
                    finally { if ($liveProcess) { $liveProcess.Dispose() } }
                }
                $records.Add([pscustomobject]$record)
            }
            $result['Processes'] = $records.ToArray()
        }
        else {
            $patterns = @('Microsoft.WindowsAppRuntime.*', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml*',
                'MicrosoftWindows.Client.OOBE', 'Microsoft.Windows.CloudExperienceHost',
                'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.ShellExperienceHost',
                'MicrosoftWindows.Client.CBS', 'Microsoft.StartExperiencesApp')
            $packages = [Collections.Generic.List[object]]::new()
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($pattern in $patterns) {
                try {
                    foreach ($package in @(Get-AppxPackage -AllUsers -Name $pattern -PackageTypeFilter Main, Framework, Bundle -ErrorAction Stop)) {
                        if ([string]::IsNullOrWhiteSpace($package.PackageFullName)) { throw 'A registered package has no full identity.' }
                        if (-not $seen.Add($package.PackageFullName)) { continue }
                        if ($packages.Count -ge 128) { throw 'Registered package data exceeds the 128-package diagnostic limit.' }
                        $users = @($package.PackageUserInformation | Where-Object { $null -ne $_ })
                        $dependencies = @($package.Dependencies | Where-Object { $null -ne $_ })
                        if ($users.Count -gt 32 -or $dependencies.Count -gt 64) { throw 'Package user/dependency data exceeds its diagnostic limit.' }
                        $manifest = Get-ProbeManifestState -Location $package.InstallLocation -Bundle ([bool]$package.IsBundle)
                        $packages.Add([pscustomobject]@{
                            Name = $package.Name; PackageFullName = $package.PackageFullName; Version = "$($package.Version)"
                            Architecture = "$($package.Architecture)"; Status = "$($package.Status)"
                            IsFramework = [bool]$package.IsFramework; IsBundle = [bool]$package.IsBundle
                            InstallLocation = $package.InstallLocation; Manifest = $manifest
                            Users = @($users | ForEach-Object {
                                    $packageUser = $_
                                    $sid = $null; $sidError = $null
                                    try {
                                        $identity = $packageUser.UserSecurityId
                                        $value = if ($identity -is [string]) { $identity } else { $identity.Sid }
                                        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                                            throw 'The package user has no readable SID field.'
                                        }
                                        $sid = [Security.Principal.SecurityIdentifier]::new($value).Value
                                    }
                                    catch {
                                        $sidError = $_.Exception.Message
                                        $errors.Add("Package user SID for '$($package.PackageFullName)': $sidError")
                                    }
                                    [pscustomobject]@{ Sid = $sid; InstallState = "$($packageUser.InstallState)"; Error = $sidError }
                                })
                            Dependencies = @($dependencies | ForEach-Object {
                                    [pscustomobject]@{ Name = $_.Name; PackageFullName = $_.PackageFullName; Version = "$($_.Version)" }
                                })
                        })
                    }
                }
                catch { $errors.Add("Registered packages '$pattern': $($_.Exception.Message)") }
            }
            $provisioned = [Collections.Generic.List[object]]::new()
            try {
                foreach ($package in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)) {
                    if (@($patterns | Where-Object { $package.DisplayName -like $_ }).Count -eq 0) { continue }
                    if ($provisioned.Count -ge 128) { throw 'Provisioned package data exceeds the 128-package diagnostic limit.' }
                    $manifest = [pscustomobject]@{ Path = $null; Status = 'LocationNotInferred'; Error = $null }
                    if ($package.DisplayName -match '^Microsoft\.(WindowsAppRuntime\.|VCLibs\.|UI\.Xaml|StartExperiencesApp)') {
                        if ($package.PackageName -notmatch '^[A-Za-z0-9._~-]+$' -or
                            -not $package.PackageName.StartsWith($package.DisplayName + '_', [StringComparison]::OrdinalIgnoreCase)) {
                            throw 'A provisioned package identity cannot be safely mapped to WindowsApps.'
                        }
                        $location = Join-Path (Join-Path $env:ProgramFiles 'WindowsApps') $package.PackageName
                        $manifest = Get-ProbeManifestState -Location $location -Bundle ($package.PackageName -like '*_neutral_~_*')
                    }
                    $provisioned.Add([pscustomobject]@{
                        Name = $package.DisplayName; PackageName = $package.PackageName; Version = "$($package.Version)"
                        Architecture = "$($package.Architecture)"; Manifest = $manifest
                        RegisteredPackageMatches = @($packages | Where-Object { $_.PackageFullName -eq $package.PackageName } |
                            ForEach-Object { $_.PackageFullName })
                    })
                }
            }
            catch { $errors.Add("Provisioned packages: $($_.Exception.Message)") }
            $result['RegisteredPackages'] = $packages.ToArray()
            $result['ProvisionedPackages'] = $provisioned.ToArray()
        }
        $result['Errors'] = $errors.ToArray()
        $result['Status'] = if ($errors.Count) { 'Partial' } else { 'Complete' }
        [pscustomobject]$result
    }
    return [scriptblock]::Create("param(`$Action)`n$setup`n& {$($queries.ToString())} -Action `$Action")
}

function Invoke-MemLabsFirstLogonGuestQuery {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][scriptblock]$GuestBlock,
        [Parameter(Mandatory)][ValidateSet('State', 'Appx')][string]$Action,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 60
    )
    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    if ($live.Name -ne $VM.Name -or "$($live.State)" -ne 'Running') { throw 'The exact live probe target is no longer running.' }
    Write-Host "$($VM.Name): read-only live $Action query (${TimeoutSeconds}s limit; no authentication retry)."
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $job = Invoke-Command -VMId $VM.Id -Credential $GuestCredential -AsJob -ScriptBlock $GuestBlock `
        -ArgumentList @($Action) -ErrorAction Stop
    $results = @(Wait-MemLabsOobeRepairJob -Job $job -TimeoutSeconds $TimeoutSeconds -Operation "Read-only first-logon $Action")
    if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw [TimeoutException]::new("Read-only $Action returned after its ${TimeoutSeconds}s deadline.") }
    if ($results.Count -ne 1 -or $results[0].Version -isnot [int] -or $results[0].Version -ne 1 -or
        $results[0].Scope -ne 'WindowsFirstLogonProbe' -or $results[0].Action -ne $Action -or
        $results[0].ReadOnly -isnot [bool] -or -not $results[0].ReadOnly -or
        $results[0].Status -notin @('Complete', 'Partial') -or
        -not $results[0].PSObject.Properties['Errors']) { throw "Invalid read-only $Action result envelope." }
    $result = $results[0]
    $guid = [guid]::Empty
    $messages = @($result.Errors)
    if (-not [guid]::TryParse($result.MachineGuid, [ref]$guid) -or $guid -eq [guid]::Empty -or
        $messages.Count -gt 512 -or @($messages | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        ($result.Status -eq 'Complete' -and @($result.Errors).Count -ne 0) -or
        ($result.Status -eq 'Partial' -and @($result.Errors).Count -eq 0)) {
        throw "Inconsistent read-only $Action result."
    }
    $required = if ($Action -eq 'State') { @('Setup', 'Processes', 'DefaultUserAccount', 'Services') } else { @('RegisteredPackages', 'ProvisionedPackages') }
    foreach ($field in $required) {
        if (-not $result.PSObject.Properties[$field]) { throw "Read-only $Action result is missing $field." }
    }
    $unknownFailedState = $Action -eq 'State' -and $result.Status -eq 'Partial' -and
        $null -eq $result.Setup.ProductType -and $result.Setup.Reason -eq 'ProbeFailed' -and
        $result.Setup.Ready -is [bool] -and -not $result.Setup.Ready -and
        @($result.Setup.Diagnostics).Count -gt 0 -and $result.Errors.Count -gt 0
    if (($Action -eq 'State' -and (($result.Setup.ProductType -ne 1 -and -not $unknownFailedState) -or
                @($result.Processes).Count -gt 64 -or @($result.Services).Count -gt 16)) -or
        ($Action -eq 'Appx' -and (@($result.RegisteredPackages).Count -gt 128 -or @($result.ProvisionedPackages).Count -gt 128))) {
        throw "Read-only $Action result exceeds its scope or data limits."
    }
    return $result
}

function Wait-MemLabsFirstLogonObservation {
    param(
        [Parameter(Mandatory)]$VM,
        [ValidateRange(0, 600)][int]$ObservationSeconds = 190,
        [switch]$AllowSetupRestart
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "$($VM.Name): allowing ${ObservationSeconds}s of normal first-logon progress before read-only inspection; no completion flags will be changed."
    try {
        do {
            $live = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem `
                -Filter "Name='$($VM.Id.ToString('D'))'" -OperationTimeoutSec 10 -ErrorAction Stop)
            if ($live.Count -ne 1 -or $live[0].Name -ne $VM.Id.ToString('D') -or $live[0].ElementName -ne $VM.Name -or
                ($live[0].EnabledState -ne 2 -and
                    (-not $AllowSetupRestart -or $live[0].EnabledState -notin @(3, 32770, 32774)))) {
                throw "The live probe target changed or stopped during observation. Matches=$($live.Count); EnabledState=$($live.EnabledState -join ',')."
            }
            $remaining = $ObservationSeconds - $watch.Elapsed.TotalSeconds
            if ($remaining -le 0) {
                if ($live[0].EnabledState -ne 2) { throw "The exact observed VM did not return to Running within ${ObservationSeconds}s; EnabledState=$($live[0].EnabledState)." }
                break
            }
            Write-Progress -Activity "$($VM.Name): observing first logon" -Status "$([int][Math]::Ceiling($remaining))s remaining; no repair actions"
            Start-Sleep -Milliseconds ([int][Math]::Min(5000, [Math]::Ceiling($remaining * 1000)))
        } while ($true)
    }
    finally { Write-Progress -Activity "$($VM.Name): observing first logon" -Completed }
}

function Invoke-MemLabsWindowsFirstLogonProbe {
    param(
        [Parameter(Mandatory)]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][scriptblock]$GuestBlock,
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)]$Manifest
    )
    $report = $Manifest.LiveProbe
    $report.Status = 'Collecting'
    $live = Get-VM -Id $VM.Id -ErrorAction Stop
    if ($live.Name -ne $VM.Name -or "$($live.State)" -notin @('Off', 'Running')) { throw 'Live inspection requires the exact selected VM to be Off or Running.' }
    if ("$($live.State)" -eq 'Off') {
        $report.StartAttempted = $true
        try { Start-MemLabsOobeRepairVm -VM $live }
        catch {
            $_.Exception.Data['FirstLogonProbePowerIndeterminate'] = $true
            throw
        }
        $report.StartedVm = $true
    }
    Wait-MemLabsFirstLogonObservation -VM $VM
    $machineGuid = $null
    foreach ($stage in @(
            @{ Name = 'StateBefore'; Action = 'State' },
            @{ Name = 'Appx'; Action = 'Appx' },
            @{ Name = 'StateAfter'; Action = 'State' }
        )) {
        $result = Invoke-MemLabsFirstLogonGuestQuery -VM $VM -GuestCredential $GuestCredential -GuestBlock $GuestBlock -Action $stage.Action
        if ($machineGuid -and $result.MachineGuid -ne $machineGuid) { throw 'The guest machine GUID changed during live inspection.' }
        $machineGuid = $result.MachineGuid
        $relative = "Live-$($stage.Name).json"
        $json = $result | ConvertTo-Json -Depth 12
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 4MB) { throw 'A live snapshot exceeds its 4 MiB evidence limit.' }
        [IO.File]::WriteAllText((Join-Path $Bundle $relative), $json, [Text.UTF8Encoding]::new($false))
        $Manifest.Files.Add([ordered]@{ Path = $relative; Truncated = $false; Kind = 'LiveFirstLogonProbe' })
        $report.Stages.Add([pscustomobject]@{ Name = $stage.Name; Status = $result.Status; Path = $relative })
        foreach ($message in $result.Errors) { $Manifest.Errors.Add("Live $($stage.Name): $message") }
    }
    $report.Status = if (@($report.Stages | Where-Object Status -eq 'Partial').Count) { 'Partial' } else { 'Complete' }
}
