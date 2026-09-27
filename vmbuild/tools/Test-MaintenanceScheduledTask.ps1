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
    'Invoke-GitMaintenance',
    'Invoke-WeeklyUpgrades',
    'Invoke-WithMemLabsMaintenanceMutex',
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
    param ([switch] $Daily, [datetime] $At)
    $script:Captured.Trigger = [pscustomobject]@{ Daily = $Daily.IsPresent; At = $At }
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

    $script:CorruptReadBack = $true
    Assert-Throws { Install-MemLabsMaintenanceScheduledTask -MaintenanceScriptPath $fixtureScript } 'a corrupted registered action fails read-back verification'
    Assert-Throws { Install-MemLabsMaintenanceScheduledTask -MaintenanceScriptPath (Join-Path $fixtureRoot 'missing.ps1') } 'a missing maintenance script cannot create a task'

    $sourceText = [System.IO.File]::ReadAllText($sourcePath)
    $userRoutePattern = '(?s)if \(-not \$ScheduledTask\) \{\s+try \{ Invoke-MemLabsFileAssociationMaintenance.*?Install-MemLabsMaintenanceScheduledTask'
    Assert-Equal $true $sourceText.Contains("elseif (`$ScheduledTask) { 'ScheduledMaintenance' }") 'scheduled runs write distinct ScheduledMaintenance logs'
    Assert-Equal $true $sourceText.Contains("Invocation mode: Scheduled task '\MemLabs Host Maintenance'") 'scheduled logs identify the task and invocation mode'
    Assert-Equal $true $sourceText.Contains('Maintenance result: {0}; elapsed: {1:N1}s') 'maintenance logs end with an explicit result and elapsed time'
    Assert-Equal $true ([regex]::IsMatch($sourceText, $userRoutePattern)) 'scheduled mode bypasses file association and task self-replacement'
    Assert-Equal $true $sourceText.Contains('Invoke-GitMaintenance -SkipGarbageCollection:$ScheduledTask') 'scheduled mode bypasses repository garbage collection'
    Assert-Equal $true $sourceText.Contains('Invoke-MRemoteNGMaintenance -SkipUserConfiguration:$ScheduledTask') 'scheduled mode bypasses mRemoteNG user-profile writes'
    Assert-Equal $true $sourceText.Contains('Invoke-WeeklyUpgrades -WaitForCompletion:$ScheduledTask') 'scheduled mode waits for weekly upgrades'
    Assert-Equal $true $sourceText.Contains("-Name 'Global\MemLabs_ChocolateyUpgrade' -TimeoutSeconds `$mutexTimeoutSeconds") 'all package-mutating maintenance phases share the Chocolatey mutex'
    Assert-Equal 3 ([regex]::Matches($sourceText, 'Get-WindowsAdminCenterRemovalLockPath').Count) 'WAC launcher and worker use the shared lock path helper'

    Set-Variable -Name scriptPath -Value $RootPath -Scope Script
    $script:GitCalls = 0
    Invoke-GitMaintenance -SkipGarbageCollection
    Assert-Equal 0 $script:GitCalls 'scheduled git maintenance never runs git gc'

    $env:ProgramData = $fixtureRoot
    $env:TEMP = $fixtureRoot
    $wacLockPath = Get-WindowsAdminCenterRemovalLockPath
    Assert-Equal (Join-Path $fixtureRoot 'memlabs\wac-removal.pid') $wacLockPath 'WAC worker lock is shared under ProgramData'
    Assert-Equal $true (Test-Path -LiteralPath (Split-Path -Parent $wacLockPath) -PathType Container) 'WAC worker lock directory is created'

    $flagDirectory = Join-Path $fixtureRoot 'memlabs'
    $null = New-Item -Path $flagDirectory -ItemType Directory -Force
    (Get-Date).ToString('o') | Out-File (Join-Path $flagDirectory 'ps7_upgrade.timestamp') -Encoding ascii -NoNewline
    $chocoFlag = Join-Path $flagDirectory 'choco_all_upgrade.timestamp'
    $upgradeTestMutexName = 'Global\MemLabs_ChocolateyUpgrade_Test_{0}' -f [guid]::NewGuid().ToString('N')

    $mutexName = 'Global\MemLabs_HostMaintenance_Test_{0}' -f [guid]::NewGuid().ToString('N')
    $mutexReady = Join-Path $fixtureRoot 'mutex-ready'
    $mutexRelease = Join-Path $fixtureRoot 'mutex-release'
    $holderJob = $null
    try {
        $holderJob = Start-Job -ArgumentList $mutexName, $mutexReady, $mutexRelease -ScriptBlock {
            param ($Name, $ReadyPath, $ReleasePath)

            $mutex = [System.Threading.Mutex]::new($false, $Name)
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
        Invoke-WeeklyUpgrades -WaitForCompletion -UpgradeMutexName $mutexName
        Assert-Equal 0 $script:ChocoCalls.Count 'scheduled weekly maintenance skips a concurrent Chocolatey upgrade'
        Assert-Equal $false (Test-Path -LiteralPath $chocoFlag) 'a skipped scheduled upgrade does not stamp completion'
        Assert-Equal $false $script:MaintenanceHadFailure 'a concurrent Chocolatey upgrade is not reported as maintenance failure'

        Set-Content -LiteralPath $mutexRelease -Value 'release' -Encoding ascii
        $null = Wait-Job -Job $holderJob -Timeout 10
        Assert-Equal 'Completed' $holderJob.State 'maintenance mutex holder exits cleanly'

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
        Invoke-WeeklyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName
        Assert-Equal 1 $script:ChocoCalls.Count "scheduled weekly maintenance invokes Chocolatey once for success code $successCode"
        Assert-Equal 'upgrade all -y --ignore-checksums' ($script:ChocoCalls[0] -join ' ') "scheduled weekly maintenance runs upgrade all directly for success code $successCode"
        Assert-Equal $true (Test-Path -LiteralPath $chocoFlag -PathType Leaf) "success code $successCode stamps completion time"
        Assert-Equal $false $script:MaintenanceHadFailure "success code $successCode leaves maintenance successful"
    }
    Assert-Equal $true $sourceText.Contains('$LASTEXITCODE -eq 1641') 'interactive upgrade-all also accepts reboot-required success'

    Remove-Item -LiteralPath $chocoFlag -Force
    $script:ChocoCalls = @()
    $script:ChocoExitCode = 9
    $script:MaintenanceHadFailure = $false
    Invoke-WeeklyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName
    Assert-Equal 1 $script:ChocoCalls.Count 'failed scheduled weekly maintenance invokes Chocolatey once'
    Assert-Equal $false (Test-Path -LiteralPath $chocoFlag) 'failed scheduled upgrade does not stamp completion'
    Assert-Equal $true $script:MaintenanceHadFailure 'failed scheduled upgrade fails the maintenance result'

    (Get-Date).AddDays(-8).ToString('o') | Out-File (Join-Path $flagDirectory 'ps7_upgrade.timestamp') -Encoding ascii -NoNewline
    (Get-Date).ToString('o') | Out-File $chocoFlag -Encoding ascii -NoNewline
    $script:ChocoCalls = @()
    $script:ChocoExitCode = 9
    $script:MaintenanceHadFailure = $false
    Invoke-WeeklyUpgrades -WaitForCompletion -UpgradeMutexName $upgradeTestMutexName
    Assert-Equal 1 $script:ChocoCalls.Count 'failed scheduled PowerShell upgrade invokes Chocolatey once'
    Assert-Equal 'upgrade pwsh -y' ($script:ChocoCalls[0] -join ' ') 'scheduled PowerShell upgrade uses the expected command'
    Assert-Equal $true $script:MaintenanceHadFailure 'failed scheduled PowerShell upgrade fails the maintenance result'

    (Get-Date).ToString('o') | Out-File (Join-Path $flagDirectory 'ps7_upgrade.timestamp') -Encoding ascii -NoNewline
    Remove-Item -LiteralPath $chocoFlag -Force -ErrorAction SilentlyContinue
    $script:AllowDetachedUpgrade = $true
    $script:StartedProcess = $null
    try {
        Invoke-WeeklyUpgrades
    }
    finally {
        $script:AllowDetachedUpgrade = $false
    }
    Assert-Equal 'powershell' $script:StartedProcess.FilePath 'interactive weekly maintenance still launches non-blocking PowerShell'
    $generatedScriptPath = Join-Path $fixtureRoot 'memlabs_choco_upgrade.ps1'
    Assert-Equal $true (Test-Path -LiteralPath $generatedScriptPath -PathType Leaf) 'interactive weekly maintenance writes its child script'
    $generatedScript = [System.IO.File]::ReadAllText($generatedScriptPath)
    Assert-Equal $true $generatedScript.Contains('Global\MemLabs_ChocolateyUpgrade') 'interactive Chocolatey child uses the cross-session upgrade mutex'
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
