<#
.SYNOPSIS
    Verifies the unattended MemLabs host maintenance task definition.
.DESCRIPTION
    Loads the shipped registration function through the PowerShell AST and exercises it
    with mocked ScheduledTasks cmdlets. No task is created on the test host.
#>
[CmdletBinding()]
param (
    [string] $RootPath,
    [string] $SourceFile = 'Invoke-Maintenance.ps1'
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

function Assert-Throws {
    param ([scriptblock] $Action, [string] $What)

    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-Equal $true $threw $What
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref] $tokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wantedFunctions = @(
    'Get-WindowsAdminCenterRemovalLockPath',
    'Install-MemLabsMaintenanceScheduledTask',
    'Install-MemLabsUserWinGetScheduledTask',
    'New-MemLabsMaintenanceMutex',
    'Invoke-GitMaintenance',
    'Invoke-DailyUpgrades',
    'Invoke-DailyUpgradesCore',
    'Invoke-WithMemLabsMaintenanceMutex',
    'Invoke-WithMemLabsRuntimeUpgradeLease',
    'Start-MemLabsBackgroundUpgradeMaintenance',
    'Test-ChocoSuccessCode'
)
$loadedFunctions = @()
foreach ($functionNode in $ast.FindAll({
            param ($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)) {
    if ($wantedFunctions -notcontains $functionNode.Name) { continue }
    . ([scriptblock]::Create($functionNode.Extent.Text))
    $loadedFunctions += $functionNode.Name
}
$missingFunctions = @($wantedFunctions | Where-Object { $loadedFunctions -notcontains $_ })
if ($missingFunctions.Count -gt 0) {
    Write-Host "SETUP FAIL: functions not found in ${SourceFile}: $($missingFunctions -join ', ')" -ForegroundColor Red
    exit 2
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('MemLabs maintenance task test {0}' -f [guid]::NewGuid().ToString('N'))
$fixtureScript = Join-Path $fixtureRoot 'Invoke-Maintenance.ps1'
$savedProgramData = $env:ProgramData
$savedTemp = $env:TEMP
$script:Captured = @{}
$script:CorruptReadBack = $false
$script:ChocoCalls = @()
$script:ChocoExitCode = 0
$script:GitCalls = 0
$script:AllowDetachedUpgrade = $false
$script:StartedProcess = $null

function New-ScheduledTaskAction {
    param ([string] $Execute, [string] $Argument, [string] $WorkingDirectory)
    $script:Captured.Action = [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory }
    return $script:Captured.Action
}

function New-ScheduledTaskTrigger {
    param ([switch] $Daily, [datetime] $At, [switch] $AtLogOn, [string] $User)
    $script:Captured.Trigger = [pscustomobject]@{
        Daily = $Daily.IsPresent
        At = $At
        AtLogOn = $AtLogOn.IsPresent
        User = $User
        Delay = $null
    }
    return $script:Captured.Trigger
}

function New-ScheduledTaskPrincipal {
    param ([string] $UserId, [string] $LogonType, [string] $RunLevel)
    $script:Captured.Principal = [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    return $script:Captured.Principal
}

function New-ScheduledTaskSettingsSet {
    param ([switch] $StartWhenAvailable, [string] $MultipleInstances, [timespan] $ExecutionTimeLimit)
    $script:Captured.Settings = [pscustomobject]@{
        StartWhenAvailable = $StartWhenAvailable.IsPresent
        MultipleInstances = $MultipleInstances
        ExecutionTimeLimit = $ExecutionTimeLimit
    }
    return $script:Captured.Settings
}

function New-ScheduledTask {
    param ($Action, $Trigger, $Principal, $Settings, [string] $Description)
    $script:Captured.Definition = [pscustomobject]@{
        Action = $Action; Trigger = $Trigger; Principal = $Principal; Settings = $Settings; Description = $Description
    }
    return $script:Captured.Definition
}

function Register-ScheduledTask {
    param ([string] $TaskName, [string] $TaskPath, $InputObject, [switch] $Force, [string] $ErrorAction)
    $script:Captured.Registration = [pscustomobject]@{
        TaskName = $TaskName; TaskPath = $TaskPath; InputObject = $InputObject; Force = $Force.IsPresent; ErrorAction = $ErrorAction
    }
}

function Get-ScheduledTask {
    param ([string] $TaskName, [string] $TaskPath, [string] $ErrorAction)
    $arguments = $script:Captured.Action.Arguments
    if ($script:CorruptReadBack) { $arguments = '-NoProfile -File "wrong.ps1"' }
    return [pscustomobject]@{
        TaskName = $TaskName
        TaskPath = $TaskPath
        Actions = @([pscustomobject]@{ Execute = $script:Captured.Action.Execute; Arguments = $arguments })
    }
}

function Write-LogMessage {
    param ([string] $Message, [string] $Level = 'INFO')
    $script:Captured.LogMessage = $Message
    $script:Captured.LogLevel = $Level
}

function Test-ChocoAvailable { return $true }
function Get-InstalledPwshVersion { return [version] '7.0.0' }
function Get-ChocoAvailablePackageVersion { return [version] '8.0.0' }
function choco {
    $script:ChocoCalls += ,@($args)
    $global:LASTEXITCODE = $script:ChocoExitCode
}
function git {
    $script:GitCalls++
    $global:LASTEXITCODE = 0
}
function Get-MpPreference { return [pscustomobject]@{ ExclusionPath = @() } }
function Add-MpPreference {}
function Start-Process {
    param (
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WindowStyle
    )

    if (-not $script:AllowDetachedUpgrade) {
        throw 'The scheduled upgrade path must not detach a child process.'
    }
    $script:StartedProcess = [pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        WindowStyle = $WindowStyle
    }
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

try {
    $null = New-Item -Path $fixtureRoot -ItemType Directory -Force
    Set-Content -LiteralPath $fixtureScript -Value '# fixture' -Encoding ascii

    Install-MemLabsMaintenanceScheduledTask -MaintenanceScriptPath $fixtureScript

    $expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $expectedArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ScheduledTask' -f $fixtureScript
    Assert-Equal $expectedPowerShell $script:Captured.Action.Execute 'task uses inbox Windows PowerShell'
    Assert-Equal $expectedArguments $script:Captured.Action.Arguments 'task invokes the exact maintenance script unattended'
    Assert-Equal $fixtureRoot $script:Captured.Action.WorkingDirectory 'task working directory follows the maintenance script'
    Assert-Equal $true $script:Captured.Trigger.Daily 'task trigger is daily'
    Assert-Equal '23:00:00' $script:Captured.Trigger.At.ToString('HH:mm:ss') 'task trigger runs at 11:00 PM'
    Assert-Equal 'SYSTEM' $script:Captured.Principal.UserId 'task runs as SYSTEM'
    Assert-Equal 'ServiceAccount' $script:Captured.Principal.LogonType 'task uses service-account logon'
    Assert-Equal 'Highest' $script:Captured.Principal.RunLevel 'task runs elevated'
    Assert-Equal $true $script:Captured.Settings.StartWhenAvailable 'missed starts run when the host becomes available'
    Assert-Equal 'IgnoreNew' $script:Captured.Settings.MultipleInstances 'overlapping task starts are suppressed'
    Assert-Equal '04:00:00' $script:Captured.Settings.ExecutionTimeLimit.ToString() 'task execution is bounded'
    Assert-Equal '\' $script:Captured.Registration.TaskPath 'task uses the Task Scheduler root'
    Assert-Equal 'MemLabs Host Maintenance' $script:Captured.Registration.TaskName 'task has the stable maintenance name'
    Assert-Equal $true $script:Captured.Registration.Force 'task registration is idempotent'

    Install-MemLabsUserWinGetScheduledTask -MaintenanceScriptPath $fixtureScript -UserId 'CONTOSO\labadmin'

    $expectedUserArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -UserWinGetTask' -f $fixtureScript
    Assert-Equal $expectedPowerShell $script:Captured.Action.Execute 'user task uses inbox Windows PowerShell'
    Assert-Equal $expectedUserArguments $script:Captured.Action.Arguments 'user task runs hidden through its dedicated entry point'
    Assert-Equal $true $script:Captured.Trigger.AtLogOn 'user task is triggered at logon'
    Assert-Equal 'CONTOSO\labadmin' $script:Captured.Trigger.User 'user task trigger targets the registering user'
    Assert-Equal 'PT2M' $script:Captured.Trigger.Delay 'user task waits two minutes after logon'
    Assert-Equal 'CONTOSO\labadmin' $script:Captured.Principal.UserId 'user task runs as the registering user'
    Assert-Equal 'Interactive' $script:Captured.Principal.LogonType 'user task uses the interactive user token'
    Assert-Equal 'Highest' $script:Captured.Principal.RunLevel 'user task runs elevated'
    Assert-Equal '02:00:00' $script:Captured.Settings.ExecutionTimeLimit.ToString() 'user task execution is bounded'
    Assert-Equal 'MemLabs User WinGet Maintenance' $script:Captured.Registration.TaskName 'user task has the stable maintenance name'

    $script:CorruptReadBack = $true
    Assert-Throws { Install-MemLabsMaintenanceScheduledTask -MaintenanceScriptPath $fixtureScript } 'a corrupted registered action fails read-back verification'
    Assert-Throws { Install-MemLabsUserWinGetScheduledTask -MaintenanceScriptPath $fixtureScript -UserId 'CONTOSO\labadmin' } 'a corrupted user-task action fails read-back verification'
    Assert-Throws { Install-MemLabsMaintenanceScheduledTask -MaintenanceScriptPath (Join-Path $fixtureRoot 'missing.ps1') } 'a missing maintenance script cannot create a task'
    $script:CorruptReadBack = $false

    $sourceText = [System.IO.File]::ReadAllText($sourcePath)
    $userRoutePattern = '(?s)if \(-not \$ScheduledTask\) \{\s+try \{ Invoke-MemLabsFileAssociationMaintenance.*?Install-MemLabsMaintenanceScheduledTask'
    Assert-Equal $true $sourceText.Contains("'ScheduledMaintenance'") 'scheduled runs write distinct ScheduledMaintenance logs'
    Assert-Equal $true $sourceText.Contains("'UserWinGetMaintenance'") 'current-user task writes distinct maintenance logs'
    Assert-Equal $true $sourceText.Contains("'BackgroundMaintenance'") 'interactive upgrade worker writes distinct maintenance logs'
    Assert-Equal $true $sourceText.Contains("Invocation mode: Scheduled task '\MemLabs Host Maintenance'") 'scheduled logs identify the task and invocation mode'
    Assert-Equal $true $sourceText.Contains('Maintenance result: {0}; elapsed: {1:N1}s') 'maintenance logs end with an explicit result and elapsed time'
    Assert-Equal $true ([regex]::IsMatch($sourceText, $userRoutePattern)) 'scheduled mode bypasses file association and task self-replacement'
    Assert-Equal $true $sourceText.Contains('Invoke-GitMaintenance -SkipGarbageCollection:$ScheduledTask') 'scheduled mode bypasses repository garbage collection'
    Assert-Equal $true $sourceText.Contains('Invoke-MRemoteNGMaintenance -SkipUserConfiguration:$ScheduledTask') 'scheduled mode bypasses mRemoteNG user-profile writes'
    Assert-Equal $true $sourceText.Contains('Invoke-MemLabsOrderedPackageMaintenance -IncludeDailyUpgrades') 'scheduled maintenance keeps daily package upgrades before security verification'
    Assert-Equal $true $sourceText.Contains('Invoke-MemLabsOrderedPackageMaintenance -IncludeWinGet -UseUserWinGetCadence -IncludeDailyUpgrades:$BackgroundUpgradeWorker') 'background workers use daily package cadence and preserve security ordering'
    Assert-Equal $true $sourceText.Contains('Start-MemLabsBackgroundUpgradeMaintenance -MaintenanceScriptPath $PSCommandPath') 'interactive maintenance dispatches upgrades to the background worker'
    Assert-Equal $true $sourceText.Contains("-Name 'Global\MemLabs_ChocolateyUpgrade' -TimeoutSeconds `$mutexTimeoutSeconds") 'all package-mutating maintenance phases share the Chocolatey mutex'
    Assert-Equal 3 ([regex]::Matches($sourceText, 'Get-WindowsAdminCenterRemovalLockPath').Count) 'WAC launcher and worker use the shared lock path helper'

    $script:AllowDetachedUpgrade = $true
    $script:StartedProcess = $null
    try {
        Start-MemLabsBackgroundUpgradeMaintenance -MaintenanceScriptPath $fixtureScript
    }
    finally {
        $script:AllowDetachedUpgrade = $false
    }
    Assert-Equal 'powershell.exe' $script:StartedProcess.FilePath 'interactive maintenance launches a Windows PowerShell background worker'
    Assert-Equal 'Normal' $script:StartedProcess.WindowStyle 'interactive background maintenance remains visible'
    Assert-Equal $true (($script:StartedProcess.ArgumentList -join ' ') -like '*-BackgroundUpgradeWorker*') 'interactive worker uses its dedicated entry point'

    Set-Variable -Name scriptPath -Value $RootPath -Scope Script
    $script:GitCalls = 0
    Invoke-GitMaintenance -SkipGarbageCollection
    Assert-Equal 0 $script:GitCalls 'scheduled git maintenance never runs git gc'

    $env:ProgramData = $fixtureRoot
    $env:TEMP = $fixtureRoot
    $wacLockPath = Get-WindowsAdminCenterRemovalLockPath
    Assert-Equal (Join-Path $fixtureRoot 'memlabs\wac-removal.pid') $wacLockPath 'WAC worker lock is shared under ProgramData'
    Assert-Equal $true (Test-Path -LiteralPath (Split-Path -Parent $wacLockPath) -PathType Container) 'WAC worker lock directory is created'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $callerSid = $identity.User }
    finally { $identity.Dispose() }
    $aclMutex = New-MemLabsMaintenanceMutex -Name ('Global\MemLabs_MaintenanceAcl_Test_{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $security = if ($PSVersionTable.PSEdition -eq 'Core') {
            [Threading.ThreadingAclExtensions]::GetAccessControl($aclMutex)
        }
        else { $aclMutex.GetAccessControl() }
        $rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $allowedSids = @('S-1-5-18', 'S-1-5-32-544', $callerSid.Value)
        foreach ($sid in $allowedSids) {
            $hasAccess = @($rules | Where-Object {
                    $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' -and
                    ($_.MutexRights -band [Security.AccessControl.MutexRights]::FullControl) -eq [Security.AccessControl.MutexRights]::FullControl
                }).Count -gt 0
            Assert-Equal $true $hasAccess "new maintenance mutex grants access to administrative participant $sid"
        }
        Assert-Equal 0 @($rules | Where-Object { $allowedSids -notcontains $_.IdentityReference.Value }).Count 'maintenance mutex does not grant access to unrelated users'
    }
    finally { $aclMutex.Dispose() }

    $requiredRights = [Security.AccessControl.MutexRights]::Synchronize -bor [Security.AccessControl.MutexRights]::Modify
    foreach ($case in @(
            @{ Label = 'wait/release access'; Rights = $requiredRights; CanRun = $true },
            @{ Label = 'wait-only access'; Rights = [Security.AccessControl.MutexRights]::Synchronize; CanRun = $false }
        )) {
        $restrictedName = 'Global\MemLabs_MaintenanceAccess_Test_{0}' -f [guid]::NewGuid().ToString('N')
        $security = [Security.AccessControl.MutexSecurity]::new()
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
                $callerSid, $case.Rights, [Security.AccessControl.AccessControlType]::Allow))
        $created = $false
        $restrictedMutex = if ($PSVersionTable.PSEdition -eq 'Core') {
            [Threading.MutexAcl]::Create($false, $restrictedName, [ref]$created, $security)
        }
        else { [Threading.Mutex]::new($false, $restrictedName, [ref]$created, $security) }
        try {
            if (-not $case.CanRun) {
                Assert-Throws {
                    $opened = [Threading.Mutex]::new($false, $restrictedName)
                    $opened.Dispose()
                } 'a legacy mutex ACL reproduces the reported constructor access denial'
            }

            $script:MaintenanceHadFailure = $false
            $script:MutexBodyRan = $false
            $script:Captured.LogMessage = $null
            $mutexOutput = @(Invoke-WithMemLabsMaintenanceMutex -Name $restrictedName -TimeoutSeconds 0 -ScriptBlock {
                    $script:MutexBodyRan = $true
                    'guarded pipeline output'
                })
            Assert-Equal 1 $mutexOutput.Count "maintenance returns only one result with $($case.Label)"
            Assert-Equal $case.CanRun $mutexOutput[0] "maintenance acquisition result respects $($case.Label)"
            Assert-Equal $case.CanRun $script:MutexBodyRan "guarded maintenance respects $($case.Label)"
            Assert-Equal (-not $case.CanRun) $script:MaintenanceHadFailure "unavailable maintenance mutex fails the run with $($case.Label)"
            if (-not $case.CanRun) {
                Assert-Equal 'ERROR' $script:Captured.LogLevel 'mutex access denial is logged as an error'
                Assert-Equal $true $script:Captured.LogMessage.Contains($restrictedName) 'mutex access denial identifies the unavailable lock'
            }

            $script:MaintenanceHadFailure = $false
            $leaseState = [pscustomobject]@{ Ran = $false; Argument = $null }
            $leaseOutput = @(Invoke-WithMemLabsRuntimeUpgradeLease -Name $restrictedName -TimeoutSeconds 0 `
                    -ArgumentList 'lease argument' -ScriptBlock {
                    param ([string] $Value)
                    $leaseState.Ran = $true
                    $leaseState.Argument = $Value
                })
            Assert-Equal 1 $leaseOutput.Count "runtime lease returns only one result with $($case.Label)"
            Assert-Equal $case.CanRun $leaseOutput[0] "runtime lease acquisition respects $($case.Label)"
            Assert-Equal $case.CanRun $leaseState.Ran "runtime upgrades respect $($case.Label)"
            Assert-Equal $false $script:MaintenanceHadFailure 'an unavailable runtime lease defers upgrades without failing maintenance'
            if ($case.CanRun) {
                Assert-Equal 'lease argument' $leaseState.Argument 'runtime lease preserves script block arguments'
            }
            else {
                Assert-Equal 'WARNING' $script:Captured.LogLevel 'unavailable runtime lease is logged as a deferral'
            }
        }
        finally { $restrictedMutex.Dispose() }
    }

    $flagDirectory = Join-Path $fixtureRoot 'memlabs'
    $null = New-Item -Path $flagDirectory -ItemType Directory -Force
    $ps7Flag = Join-Path $flagDirectory 'ps7_upgrade.timestamp'
    $chocoFlag = Join-Path $flagDirectory 'choco_all_upgrade.timestamp'
    $upgradeTestMutexName = 'Global\MemLabs_ChocolateyUpgrade_Test_{0}' -f [guid]::NewGuid().ToString('N')
    $testMutationMutexName = 'Global\MemLabsTestMutationLock_Test_{0}' -f [guid]::NewGuid().ToString('N')

    (Get-Date).AddHours(-23).ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
    (Get-Date).AddHours(-23).ToString('o') | Out-File $chocoFlag -Encoding ascii -NoNewline
    $script:ChocoCalls = @()
    Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $testMutationMutexName
    Assert-Equal 0 $script:ChocoCalls.Count 'daily upgrades remain gated before 24 hours'

    (Get-Date).ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
    (Get-Date).AddHours(-25).ToString('o') | Out-File $chocoFlag -Encoding ascii -NoNewline
    $script:ChocoCalls = @()
    Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $testMutationMutexName
    Assert-Equal 1 $script:ChocoCalls.Count 'Chocolatey upgrades run after the 24-hour gate expires'
    Assert-Equal 'upgrade all -y --ignore-checksums' ($script:ChocoCalls[0] -join ' ') 'daily Chocolatey uses the expected upgrade command'
    Remove-Item -LiteralPath $chocoFlag -Force

    $mutexName = 'Global\MemLabs_HostMaintenance_Test_{0}' -f [guid]::NewGuid().ToString('N')
    $mutexReady = Join-Path $fixtureRoot 'mutex-ready'
    $mutexRelease = Join-Path $fixtureRoot 'mutex-release'
    $holderJob = $null
    try {
        $holderJob = Start-Job -ArgumentList $mutexName, $mutexReady, $mutexRelease -ScriptBlock {
            param ($Name, $ReadyPath, $ReleasePath)

            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { $callerSid = $identity.User }
            finally { $identity.Dispose() }
            $security = [Security.AccessControl.MutexSecurity]::new()
            $rights = [Security.AccessControl.MutexRights]::Synchronize -bor [Security.AccessControl.MutexRights]::Modify
            $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
                    $callerSid, $rights, [Security.AccessControl.AccessControlType]::Allow))
            $created = $false
            $mutex = if ($PSVersionTable.PSEdition -eq 'Core') {
                [Threading.MutexAcl]::Create($false, $Name, [ref]$created, $security)
            }
            else { [Threading.Mutex]::new($false, $Name, [ref]$created, $security) }
            $acquired = $false
            try {
                try { $acquired = $mutex.WaitOne(0) }
                catch [System.Threading.AbandonedMutexException] { $acquired = $true }
                if (-not $acquired) { throw "Could not acquire test mutex '$Name'." }

                Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding ascii
                $deadline = (Get-Date).AddSeconds(15)
                while (-not (Test-Path -LiteralPath $ReleasePath) -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 50
                }
            }
            finally {
                if ($acquired) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
        }

        $readyDeadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $mutexReady) -and (Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-Equal $true (Test-Path -LiteralPath $mutexReady) 'separate process acquired the maintenance mutex'

        $script:MutexBodyRan = $false
        $mutexResult = Invoke-WithMemLabsMaintenanceMutex -Name $mutexName -TimeoutSeconds 0 -ScriptBlock {
            $script:MutexBodyRan = $true
        }
        Assert-Equal $false $mutexResult 'a colliding maintenance run is skipped'
        Assert-Equal $false $script:MutexBodyRan 'a colliding maintenance run cannot enter the guarded phases'

        $script:ChocoCalls = @()
        $script:MaintenanceHadFailure = $false
        Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $mutexName -TestMutationMutexName $testMutationMutexName
        Assert-Equal 0 $script:ChocoCalls.Count 'scheduled daily maintenance skips a concurrent Chocolatey upgrade'
        Assert-Equal $false (Test-Path -LiteralPath $chocoFlag) 'a skipped scheduled upgrade does not stamp completion'
        Assert-Equal $false $script:MaintenanceHadFailure 'a concurrent Chocolatey upgrade is not reported as maintenance failure'

        $script:ChocoCalls = @()
        $script:MaintenanceHadFailure = $false
        Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $mutexName
        Assert-Equal 0 $script:ChocoCalls.Count 'scheduled daily maintenance defers while a test cycle owns the host mutation lease'
        Assert-Equal $false (Test-Path -LiteralPath $chocoFlag) 'a deferred runtime upgrade does not stamp completion'
        Assert-Equal $false $script:MaintenanceHadFailure 'an active test cycle is not reported as maintenance failure'

        Set-Content -LiteralPath $mutexRelease -Value 'release' -Encoding ascii
        $null = Wait-Job -Job $holderJob -Timeout 10
        Assert-Equal 'Completed' $holderJob.State 'maintenance mutex holder exits cleanly'
        $null = Receive-Job -Job $holderJob -ErrorAction Stop

        $script:MutexBodyRan = $false
        $mutexResult = Invoke-WithMemLabsMaintenanceMutex -Name $mutexName -TimeoutSeconds 1 -ScriptBlock {
            $script:MutexBodyRan = $true
        }
        Assert-Equal $true $mutexResult 'maintenance runs after the mutex is released'
        Assert-Equal $true $script:MutexBodyRan 'the guarded phases run only while holding the mutex'

        $nestedState = [pscustomobject]@{ InnerRan = $false; InnerResult = $false }
        $mutexResult = Invoke-WithMemLabsMaintenanceMutex -Name $mutexName -TimeoutSeconds 1 -ScriptBlock {
            $nestedState.InnerResult = Invoke-WithMemLabsMaintenanceMutex -Name $mutexName -TimeoutSeconds 0 -ScriptBlock {
                $nestedState.InnerRan = $true
            }
        }
        Assert-Equal $true $mutexResult 'outer maintenance mutex acquisition succeeds'
        Assert-Equal $true $nestedState.InnerResult 'same-thread Chocolatey mutex acquisition is reentrant'
        Assert-Equal $true $nestedState.InnerRan 'nested scheduled Chocolatey work runs under the shared mutex'
    }
    finally {
        Set-Content -LiteralPath $mutexRelease -Value 'release' -Encoding ascii -ErrorAction SilentlyContinue
        if ($holderJob) {
            if ($holderJob.State -eq 'Running') { Stop-Job -Job $holderJob }
            Remove-Job -Job $holderJob -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($successCode in @(0, 2, 1641, 3010)) {
        Remove-Item -LiteralPath $chocoFlag -Force -ErrorAction SilentlyContinue
        $script:ChocoCalls = @()
        $script:ChocoExitCode = $successCode
        $script:MaintenanceHadFailure = $false
        Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $testMutationMutexName
        Assert-Equal 1 $script:ChocoCalls.Count "scheduled daily maintenance invokes Chocolatey once for success code $successCode"
        Assert-Equal 'upgrade all -y --ignore-checksums' ($script:ChocoCalls[0] -join ' ') "scheduled daily maintenance runs upgrade all directly for success code $successCode"
        Assert-Equal $true (Test-Path -LiteralPath $chocoFlag -PathType Leaf) "success code $successCode stamps completion time"
        Assert-Equal $false $script:MaintenanceHadFailure "success code $successCode leaves maintenance successful"
    }
    Assert-Equal $true $sourceText.Contains('$LASTEXITCODE -eq 1641') 'interactive upgrade-all also accepts reboot-required success'

    Remove-Item -LiteralPath $chocoFlag -Force
    $script:ChocoCalls = @()
    $script:ChocoExitCode = 9
    $script:MaintenanceHadFailure = $false
    Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $testMutationMutexName
    Assert-Equal 1 $script:ChocoCalls.Count 'failed scheduled daily maintenance invokes Chocolatey once'
    Assert-Equal $false (Test-Path -LiteralPath $chocoFlag) 'failed scheduled upgrade does not stamp completion'
    Assert-Equal $true $script:MaintenanceHadFailure 'failed scheduled upgrade fails the maintenance result'

    (Get-Date).AddHours(-25).ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
    (Get-Date).ToString('o') | Out-File $chocoFlag -Encoding ascii -NoNewline
    $script:ChocoCalls = @()
    $script:ChocoExitCode = 9
    $script:MaintenanceHadFailure = $false
    Invoke-DailyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName -TestMutationMutexName $testMutationMutexName
    Assert-Equal 1 $script:ChocoCalls.Count 'failed scheduled PowerShell upgrade invokes Chocolatey once'
    Assert-Equal 'upgrade pwsh -y' ($script:ChocoCalls[0] -join ' ') 'scheduled PowerShell upgrade uses the expected command'
    Assert-Equal $true $script:MaintenanceHadFailure 'failed scheduled PowerShell upgrade fails the maintenance result'

    (Get-Date).ToString('o') | Out-File $ps7Flag -Encoding ascii -NoNewline
    Remove-Item -LiteralPath $chocoFlag -Force -ErrorAction SilentlyContinue
    $script:AllowDetachedUpgrade = $true
    $script:StartedProcess = $null
    try {
        Invoke-DailyUpgrades -TestMutationMutexName $testMutationMutexName
    }
    finally {
        $script:AllowDetachedUpgrade = $false
    }
    Assert-Equal 'powershell' $script:StartedProcess.FilePath 'interactive daily maintenance still launches non-blocking PowerShell'
    $generatedScriptPath = Join-Path $fixtureRoot 'memlabs_choco_upgrade.ps1'
    Assert-Equal $true (Test-Path -LiteralPath $generatedScriptPath -PathType Leaf) 'interactive daily maintenance writes its child script'
    $generatedScript = [System.IO.File]::ReadAllText($generatedScriptPath)
    Assert-Equal $true $generatedScript.Contains('Global\MemLabs_ChocolateyUpgrade') 'interactive Chocolatey child uses the cross-session upgrade mutex'
    Assert-Equal $true $generatedScript.Contains(${function:New-MemLabsMaintenanceMutex}.ToString()) 'interactive Chocolatey child embeds the shared cross-account mutex factory'
    Assert-Equal $true $generatedScript.Contains('$mutex = New-MemLabsMaintenanceMutex -Name ') 'interactive Chocolatey child uses the shared mutex policy'
    Assert-Equal $true $generatedScript.Contains('Chocolatey package maintenance could not run safely: $_') 'interactive Chocolatey child reports lock errors instead of running unlocked'
    Assert-Equal $true $generatedScript.Contains('$mutex.WaitOne([TimeSpan]::FromSeconds(120))') 'interactive Chocolatey child waits for its parent to release the mutex'
    $generatedParseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($generatedScript, [ref] $null, [ref] $generatedParseErrors)
    Assert-Equal 0 @($generatedParseErrors).Count 'generated interactive Chocolatey script parses successfully'
}
finally {
    $env:ProgramData = $savedProgramData
    $env:TEMP = $savedTemp
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0
