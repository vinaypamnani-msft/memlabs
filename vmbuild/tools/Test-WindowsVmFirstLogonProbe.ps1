#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.WindowsVmFirstLogonProbe.ps1')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { $null = & $Action } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected '$Pattern', got '$message'."
}
$root = Join-Path ([IO.Path]::GetTempPath()) "memlabs-firstlogon-probe-$([guid]::NewGuid().ToString('N'))"
$originalProgramFiles = $env:ProgramFiles
$null = New-Item -Path $root -ItemType Directory
try {
    $env:ProgramFiles = Join-Path $root 'Program Files'
    $runtimeId = 'Microsoft.WindowsAppRuntime.2_2.5.1.0_x64__8wekyb3d8bbwe'
    $runtimeLocation = Join-Path $env:ProgramFiles "WindowsApps\$runtimeId"
    $bundleId = 'Microsoft.StartExperiencesApp_2021.380.0.0_neutral_~_8wekyb3d8bbwe'
    $bundleLocation = Join-Path $env:ProgramFiles "WindowsApps\$bundleId"
    $null = New-Item -Path $runtimeLocation, (Join-Path $bundleLocation 'AppxMetadata') -ItemType Directory -Force
    [IO.File]::WriteAllText((Join-Path $runtimeLocation 'AppxManifest.xml'), '<Package/>')
    [IO.File]::WriteAllText((Join-Path $bundleLocation 'AppxMetadata\AppxBundleManifest.xml'), '<Bundle/>')
    $script:MachineGuid = [guid]::NewGuid().ToString('D')
    $script:DefaultSid = 'S-1-5-21-111-222-333-1001'
    $script:Administrator = $true
    $script:ProcessCount = 1; $script:ThreadCount = 2; $script:OwnerFailure = $false
    $script:DisposedProcesses = 0; $script:QueryFamilyFailure = ''; $script:ProvisionedFailure = $false
    $script:PackageQueries = [Collections.Generic.List[string]]::new()
    function Get-FixtureSetupState { [pscustomobject]@{ Version = 1; ProductType = 1; Ready = $false; Reason = 'OobeProcessesActive' } }
    function Get-ItemProperty {
        param($LiteralPath, $Name, $ErrorAction)
        Assert-True ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Cryptography' -and $Name -eq 'MachineGuid') 'The guest probe read unexpected registry data.'
        [pscustomobject]@{ MachineGuid = $script:MachineGuid }
    }
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($OperationTimeoutSec -eq 10) 'The guest CIM query lost its operation deadline.'
        if ($ClassName -eq 'Msvm_ComputerSystem') {
            Assert-True ($Namespace -eq 'root\virtualization\v2' -and $Filter -eq "Name='$($script:VMId.ToString('D'))'") `
                'Observation lost exact VM selection or the bounded virtualization namespace.'
            return [pscustomobject]@{
                Name = $script:VMId.ToString('D'); ElementName = 'PROBE-VM'
                EnabledState = $(if ($script:VmState -eq 'Running') { 2 } else { 3 })
            }
        }
        if ($ClassName -eq 'Win32_UserAccount') {
            Assert-True ($Filter -eq "LocalAccount=TRUE AND Name='defaultuser0'") 'The account query was not scoped to the OOBE account.'
            return [pscustomobject]@{ Name = 'defaultuser0'; SID = $script:DefaultSid; Disabled = $false; Status = 'OK' }
        }
        if ($ClassName -eq 'Win32_Service') {
            Assert-True ($Filter -match "Name='AppReadiness'" -and $Filter -match "Name='ProfSvc'") 'Service inspection lost its first-logon scope.'
            return [pscustomobject]@{ Name = 'AppReadiness'; State = 'Stopped'; StartMode = 'Manual'; ProcessId = 0; ExitCode = 0 }
        }
        Assert-True ($ClassName -eq 'Win32_Process' -and $Filter -match "Name='FirstLogonAnim.exe'") 'The process query lost its scope.'
        foreach ($number in 1..$script:ProcessCount) {
            [pscustomobject]@{
                Name = 'FirstLogonAnim.exe'; ProcessId = 100 + $number; ParentProcessId = 50; SessionId = 1
                CreationDate = [DateTime]::UtcNow; ExecutablePath = 'C:\Windows\System32\oobe\FirstLogonAnim.exe'
                CommandLine = 'SYNTHETIC-SECRET-MUST-NOT-EXPORT'
            }
        }
    }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($MethodName -eq 'GetOwnerSid' -and $OperationTimeoutSec -eq 3) 'The probe invoked a mutating/unbounded CIM method.'
        if ($script:OwnerFailure) { return [pscustomobject]@{ ReturnValue = 2; Sid = $null } }
        [pscustomobject]@{ ReturnValue = 0; Sid = $script:DefaultSid }
    }
    function Get-Process {
        param($Id, $ErrorAction)
        $threads = @(foreach ($number in 1..$script:ThreadCount) {
                [pscustomobject]@{ Id = $number; ThreadState = 'Wait'; WaitReason = 'UserRequest' }
            })
        $process = [pscustomobject]@{ Id = $Id; Responding = $true; MainWindowTitle = 'Just a moment'; Threads = $threads }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:DisposedProcesses++ }
        $process
    }
    function New-PackageFixture {
        param([string]$Name = 'Microsoft.WindowsAppRuntime.2', [string]$FullName = $runtimeId, [string]$Location = $runtimeLocation, [bool]$Bundle = $false)
        [pscustomobject]@{
            Name = $Name; PackageFullName = $FullName; Version = [version]'2.5.1.0'; Architecture = 'X64'
            Status = 'Ok'; IsFramework = -not $Bundle; IsBundle = $Bundle; InstallLocation = $Location
            PackageUserInformation = @([pscustomobject]@{ UserSecurityId = $script:DefaultSid; InstallState = 'Staged' })
            Dependencies = @(); Password = 'SYNTHETIC-SECRET-MUST-NOT-EXPORT'
        }
    }
    $script:Registered = @(
        (New-PackageFixture),
        (New-PackageFixture -Name Microsoft.StartExperiencesApp -FullName $bundleId -Location $bundleLocation -Bundle $true),
        (New-PackageFixture -Name Private.CompanyApp -FullName 'Private.CompanyApp_private' -Location '\\do-not-access\private')
    )
    $script:Provisioned = @(
        [pscustomobject]@{ DisplayName = 'Microsoft.WindowsAppRuntime.2'; PackageName = 'Microsoft.WindowsAppRuntime.2_2.2.0.0_x64__8wekyb3d8bbwe'; Version = '2.2.0.0'; Architecture = 'X64' },
        [pscustomobject]@{ DisplayName = 'Microsoft.WindowsAppRuntime.2'; PackageName = $runtimeId; Version = '2.5.1.0'; Architecture = 'X64' },
        [pscustomobject]@{ DisplayName = 'Private.CompanyApp'; PackageName = 'Private.CompanyApp_private'; Version = '1.0.0.0'; Architecture = 'X64' }
    )
    function Get-AppxPackage {
        param([switch]$AllUsers, $Name, $PackageTypeFilter, $ErrorAction)
        Assert-True ($AllUsers -and ($PackageTypeFilter -join ',') -eq 'Main,Framework,Bundle') 'Registered package query lost its user/type scope.'
        $script:PackageQueries.Add($Name)
        if ($Name -eq $script:QueryFamilyFailure) { throw 'Synthetic package query failure.' }
        $script:Registered | Where-Object { $_.Name -like $Name }
    }
    function Get-AppxProvisionedPackage {
        param([switch]$Online, $ErrorAction)
        Assert-True $Online 'The probe queried an unexpected offline image.'
        if ($script:ProvisionedFailure) { throw 'Synthetic provisioning query failure.' }
        $script:Provisioned
    }
    $block = Get-MemLabsFirstLogonGuestBlock
    Assert-True ($block.ToString() -notmatch '\b(Add-AppxPackage|Remove-AppxPackage|Set-ItemProperty|New-ItemProperty|Rename-Computer|Add-Computer|Remove-Computer|Restart-Computer|Stop-Process|Start-Service|Stop-Service)\b') `
        'The guest payload contains configuration/identity/package mutation commands.'
    $fixtureText = $block.ToString().Replace('$setupState = Get-MemLabsWindowsClientSetupState', '$setupState = Get-FixtureSetupState')
    $fixtureText = $fixtureText.Replace('$administrator = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)', '$administrator = $script:Administrator')
    $guest = [scriptblock]::Create($fixtureText)
    $states = @(& $guest -Action State)
    Assert-True ($states.Count -eq 1 -and $states[0].ReadOnly -and $states[0].Status -eq 'Complete' -and
        $states[0].Processes.Count -eq 1 -and $states[0].Processes[0].SessionId -eq 1 -and
        $states[0].Processes[0].OwnerSid -eq $script:DefaultSid -and $states[0].Processes[0].Threads.Count -eq 2 -and
        $states[0].Processes[0].Threads[0].WaitReason -eq 'UserRequest' -and $states[0].Services[0].Name -eq 'AppReadiness' -and $script:DisposedProcesses -eq 1 -and
        ($states | ConvertTo-Json -Depth 12) -notmatch 'SYNTHETIC-SECRET|CommandLine') 'Read-only process/session/owner/thread data lost its shape or privacy.'
    $appx = & $guest -Action Appx
    Assert-True ($appx.Status -eq 'Complete' -and $appx.RegisteredPackages.Count -eq 2 -and
        $appx.RegisteredPackages[0].Users[0].InstallState -eq 'Staged' -and
        $appx.RegisteredPackages[1].Manifest.Status -eq 'Present' -and
        $appx.RegisteredPackages[1].Manifest.Path.EndsWith('AppxMetadata\AppxBundleManifest.xml') -and
        $appx.ProvisionedPackages.Count -eq 2 -and $appx.ProvisionedPackages[0].Manifest.Status -eq 'Absent' -and
        $appx.ProvisionedPackages[1].Manifest.Status -eq 'Present' -and
        $appx.ProvisionedPackages[1].RegisteredPackageMatches.Count -eq 1 -and
        ($appx | ConvertTo-Json -Depth 12) -notmatch 'Private.CompanyApp|SYNTHETIC-SECRET') 'Package registration/provisioning evidence inferred success or lost scope, bundle paths, or privacy.'
    $script:Administrator = $false
    Assert-Throws { & $guest -Action Appx } 'requires a guest administrator'
    $script:Administrator = $true
    $script:OwnerFailure = $true
    $partial = & $guest -Action State
    Assert-True ($partial.Status -eq 'Partial' -and $partial.Errors.Count -eq 1) 'Owner lookup failure became clean evidence.'
    $script:OwnerFailure = $false; $script:ThreadCount = 65
    $partial = & $guest -Action State
    Assert-True ($partial.Status -eq 'Partial' -and ($partial.Errors -join ' ') -match '64-thread') 'Thread enumeration exceeded its data bound.'
    $script:ThreadCount = 64
    $boundary = & $guest -Action State
    Assert-True ($boundary.Status -eq 'Complete' -and $boundary.Processes[0].Threads.Count -eq 64) 'The exact 64-thread limit was rejected.'
    $script:ThreadCount = 2; $script:ProcessCount = 65
    Assert-Throws { & $guest -Action State } '64-process'
    $script:ProcessCount = 1; $script:QueryFamilyFailure = 'Microsoft.VCLibs.*'
    $partial = & $guest -Action Appx
    Assert-True ($partial.Status -eq 'Partial' -and $partial.RegisteredPackages.Count -eq 2 -and $partial.Errors.Count -eq 1) `
        'One failed package query hid its error or discarded independent evidence.'
    $script:QueryFamilyFailure = ''; $script:ProvisionedFailure = $true
    $partial = & $guest -Action Appx
    Assert-True ($partial.Status -eq 'Partial' -and $partial.ProvisionedPackages.Count -eq 0 -and $partial.RegisteredPackages.Count -eq 2) `
        'Provisioning query failure became a successful empty result.'
    $script:ProvisionedFailure = $false
    $savedPackages = $script:Registered
    $script:Registered = @((New-PackageFixture -Location '\\do-not-access\private'))
    $partial = & $guest -Action Appx
    Assert-True ($partial.Status -eq 'Partial' -and $partial.RegisteredPackages[0].Manifest.Status -eq 'Error') `
        'The guest attempted a nonlocal package-manifest path.'
    foreach ($count in @(128, 129)) {
        $script:Registered = @(foreach ($number in 1..$count) {
                New-PackageFixture -FullName "Microsoft.WindowsAppRuntime.2_2.5.1.$number`_x64__8wekyb3d8bbwe"
            })
        $bounded = & $guest -Action Appx
        Assert-True ($bounded.RegisteredPackages.Count -eq 128 -and
            (($count -eq 128 -and $bounded.Status -eq 'Complete') -or
             ($count -eq 129 -and $bounded.Status -eq 'Partial' -and ($bounded.Errors -join ' ') -match '128-package'))) `
            'The registered-package snapshot did not enforce its exact 128/129 boundary.'
    }
    $script:Registered = $savedPackages
    foreach ($limit in @(
            @{ Field = 'PackageUserInformation'; Maximum = 32 },
            @{ Field = 'Dependencies'; Maximum = 64 }
        )) {
        foreach ($count in @($limit.Maximum, ($limit.Maximum + 1))) {
            $package = New-PackageFixture
            $package.($limit.Field) = @(foreach ($number in 1..$count) {
                    if ($limit.Field -eq 'Dependencies') {
                        [pscustomobject]@{ Name = 'Framework'; PackageFullName = "Framework_$number"; Version = '1.0.0.0' }
                    }
                    else { [pscustomobject]@{ UserSecurityId = $script:DefaultSid; InstallState = 'Installed' } }
                })
            $script:Registered = @($package)
            $bounded = & $guest -Action Appx
            Assert-True (($count -eq $limit.Maximum -and $bounded.Status -eq 'Complete') -or
                ($count -gt $limit.Maximum -and $bounded.Status -eq 'Partial' -and ($bounded.Errors -join ' ') -match 'diagnostic limit')) `
                "The exact $($limit.Field) limit was not enforced."
        }
    }
    $script:Registered = $savedPackages
    $savedProvisioned = $script:Provisioned
    foreach ($count in @(128, 129)) {
        $script:Provisioned = @(foreach ($number in 1..$count) {
                [pscustomobject]@{ DisplayName = 'Microsoft.WindowsAppRuntime.2'; PackageName = "Microsoft.WindowsAppRuntime.2_2.5.1.$number`_x64__8wekyb3d8bbwe"; Version = "2.5.1.$number"; Architecture = 'X64' }
            })
        $bounded = & $guest -Action Appx
        Assert-True ($bounded.ProvisionedPackages.Count -eq 128 -and
            (($count -eq 128 -and $bounded.Status -eq 'Complete') -or
             ($count -eq 129 -and $bounded.Status -eq 'Partial' -and ($bounded.Errors -join ' ') -match '128-package'))) `
            'The provisioned-package snapshot did not enforce its exact 128/129 boundary.'
    }
    $script:Provisioned = $savedProvisioned

    $script:VMId = [guid]::NewGuid()
    $vm = [pscustomobject]@{ Id = $script:VMId; Name = 'PROBE-VM'; State = 'Off' }
    $password = [Security.SecureString]::new(); $password.AppendChar('x')
    $credential = [pscredential]::new('fixture-admin', $password)
    $script:ExpectedCredential = $credential
    $script:VmState = 'Running'; $script:WrongVm = $false; $script:RpcCalls = 0
    $script:ReturnResult = $states[0]; $script:WaitFailure = $false; $script:LateResponse = $false
    function Get-VM {
        param($Id, $ErrorAction)
        Assert-True ($Id -eq $script:VMId) 'Host inspection targeted another VM ID.'
        [pscustomobject]@{ Id = $script:VMId; Name = $(if ($script:WrongVm) { 'OTHER-VM' } else { 'PROBE-VM' }); State = $script:VmState }
    }
    function Invoke-Command {
        param($VMId, [pscredential]$Credential, [switch]$AsJob, $ScriptBlock, $ArgumentList, $ErrorAction)
        Assert-True ($VMId -eq $script:VMId -and $AsJob -and [object]::ReferenceEquals($Credential, $script:ExpectedCredential)) 'The host lost exact-VM, credential or asynchronous invocation.'
        $script:RpcCalls++
        [pscustomobject]@{ Id = 1; State = 'Completed'; Action = $ArgumentList[0] }
    }
    function Wait-MemLabsOobeRepairJob {
        param($Job, $TimeoutSeconds, $Operation)
        Assert-True ($TimeoutSeconds -in @(1, 60) -and $Operation -like 'Read-only first-logon *') 'Live RPC lost its time bound.'
        if ($script:WaitFailure) { throw [UnauthorizedAccessException]::new('Synthetic authentication failure.') }
        if ($script:LateResponse) { Start-Sleep -Milliseconds 1100 }
        [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($script:ReturnResult))
    }
    $rpc = @{ VM = $vm; GuestCredential = $credential; GuestBlock = $block; Action = 'State' }
    $reply = Invoke-MemLabsFirstLogonGuestQuery @rpc
    Assert-True ($reply.ReadOnly -and $script:RpcCalls -eq 1) 'A valid live envelope was rejected or retried.'
    foreach ($invalid in @('Scope', 'ReadOnly', 'Version', 'Status')) {
        $script:ReturnResult = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($states[0]))
        switch ($invalid) {
            Scope { $script:ReturnResult.Scope = 'OtherScope' }
            ReadOnly { $script:ReturnResult.ReadOnly = $false }
            Version { $script:ReturnResult.Version = '1' }
            Status { $script:ReturnResult.Status = 'Partial' }
        }
        Assert-Throws { Invoke-MemLabsFirstLogonGuestQuery @rpc } 'Invalid|Inconsistent'
    }
    $script:ReturnResult = $states[0]; $script:WaitFailure = $true
    $calls = $script:RpcCalls
    Assert-Throws { Invoke-MemLabsFirstLogonGuestQuery @rpc } 'authentication failure'
    Assert-True ($script:RpcCalls -eq $calls + 1) 'Authentication failure caused a retry.'
    $script:WaitFailure = $false; $script:LateResponse = $true
    Assert-Throws { Invoke-MemLabsFirstLogonGuestQuery @rpc -TimeoutSeconds 1 } 'after its 1s deadline'
    $script:LateResponse = $false; $script:WrongVm = $true
    $calls = $script:RpcCalls
    Assert-Throws { Invoke-MemLabsFirstLogonGuestQuery @rpc } 'exact live probe target'
    Assert-True ($script:RpcCalls -eq $calls) 'A different VM received a guest query.'
    $script:WrongVm = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Wait-MemLabsFirstLogonObservation -VM $vm -ObservationSeconds 1
    Assert-True ($clock.Elapsed.TotalSeconds -ge 1) 'Observation returned before its minimum interval.'
    $script:VmState = 'Off'
    Assert-Throws { Wait-MemLabsFirstLogonObservation -VM $vm -ObservationSeconds 0 } 'changed or stopped'

    $script:Starts = 0; $script:Observations = 0; $script:StageCalls = [Collections.Generic.List[string]]::new()
    $script:StartupUnknown = $false; $script:StartupFails = $false; $script:StageFailure = $false; $script:LargePayload = $false
    function Start-MemLabsOobeRepairVm {
        param($VM)
        $script:Starts++; $script:VmState = 'Running'
        if ($script:StartupUnknown -or $script:StartupFails) {
            $exception = [TimeoutException]::new('Startup outcome is unknown.')
            if ($script:StartupUnknown) { $exception.Data['OobeRepairIndeterminate'] = $true }
            throw $exception
        }
    }
    function Wait-MemLabsFirstLogonObservation { param($VM); $script:Observations++ }
    function Invoke-MemLabsFirstLogonGuestQuery {
        param($VM, [pscredential]$GuestCredential, $GuestBlock, $Action)
        $script:StageCalls.Add($Action)
        if ($script:StageFailure -and $Action -eq 'Appx') { throw 'Synthetic second-stage authentication failure.' }
        if ($script:LargePayload) {
            $copy = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($states[0]))
            $copy | Add-Member -NotePropertyName Padding -NotePropertyValue ('X' * 4MB)
            return $copy
        }
        if ($Action -eq 'Appx') { return $appx }
        return $states[0]
    }
    $manifest = @{
        LiveProbe = [ordered]@{ Status = 'NotRequested'; StartAttempted = $false; StartedVm = $false; Stages = [Collections.Generic.List[object]]::new() }
        Files = [Collections.Generic.List[object]]::new(); Errors = [Collections.Generic.List[string]]::new()
    }
    Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $credential -GuestBlock $block -Bundle $root -Manifest $manifest
    Assert-True ($script:Starts -eq 1 -and $script:Observations -eq 1 -and ($script:StageCalls -join ',') -eq 'State,Appx,State' -and
        $manifest.LiveProbe.Status -eq 'Complete' -and $manifest.Files.Count -eq 3 -and $manifest.Errors.Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $root 'Live-StateAfter.json')) -and
        (Get-Content -LiteralPath (Join-Path $root 'Live-Appx.json') -Raw) -notmatch 'SYNTHETIC-SECRET') `
        'Live host orchestration lost startup, observation, stage order, protected artifacts, or privacy.'
    $script:StageFailure = $true
    $manifest = @{
        LiveProbe = [ordered]@{ Status = 'NotRequested'; StartAttempted = $false; StartedVm = $false; Stages = [Collections.Generic.List[object]]::new() }
        Files = [Collections.Generic.List[object]]::new(); Errors = [Collections.Generic.List[string]]::new()
    }
    $beforeStarts = $script:Starts
    $script:StageCalls.Clear()
    Assert-Throws { Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $credential -GuestBlock $block -Bundle $root -Manifest $manifest } 'second-stage authentication'
    Assert-True ($script:Starts -eq $beforeStarts -and ($script:StageCalls -join ',') -eq 'State,Appx' -and
        $manifest.Files.Count -eq 1 -and $manifest.LiveProbe.Stages.Count -eq 1) 'A later RPC failure lost earlier evidence, restarted a running VM, or continued querying.'
    $script:StageFailure = $false; $script:LargePayload = $true
    $manifest.Files.Clear(); $manifest.LiveProbe.Stages.Clear()
    Assert-Throws { Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $credential -GuestBlock $block -Bundle $root -Manifest $manifest } '4 MiB'
    Assert-True ($manifest.Files.Count -eq 0 -and $manifest.LiveProbe.Stages.Count -eq 0) 'Oversized live evidence was written or claimed complete.'
    $script:LargePayload = $false
    $script:VmState = 'Off'; $script:StartupUnknown = $true
    $beforeObservations = $script:Observations; $beforeQueries = $script:StageCalls.Count
    $failure = $null
    try { Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $credential -GuestBlock $block -Bundle $root -Manifest $manifest }
    catch { $failure = $_.Exception }
    Assert-True ($failure -and $failure.Data['FirstLogonProbePowerIndeterminate'] -and
        $script:Observations -eq $beforeObservations -and $script:StageCalls.Count -eq $beforeQueries) `
        'Unknown VM startup did not stop observation and further guest queries.'
    $script:VmState = 'Off'; $script:StartupUnknown = $false; $script:StartupFails = $true
    $failure = $null
    try { Invoke-MemLabsWindowsFirstLogonProbe -VM $vm -GuestCredential $credential -GuestBlock $block -Bundle $root -Manifest $manifest }
    catch { $failure = $_.Exception }
    Assert-True ($failure -and $failure.Data['FirstLogonProbePowerIndeterminate'] -and
        $script:Observations -eq $beforeObservations -and $script:StageCalls.Count -eq $beforeQueries) `
        'An unclassified startup exception was treated as safe for further operations.'
}
finally {
    $env:ProgramFiles = $originalProgramFiles
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
}
Write-Host 'PASS -- scoped read-only live processes/packages, staged/provisioned identities, bundle paths, privacy, data/deadline bounds, exact VM targeting, no auth retry, and protected host artifacts.'
