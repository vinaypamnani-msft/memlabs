#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $RootPath = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath))
}

$script:Failures = [Collections.Generic.List[string]]::new()
$script:AssertionCount = 0
function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    $script:AssertionCount++
    if ("$Expected" -ne "$Actual") {
        $script:Failures.Add("$Name -- expected '$Expected', got '$Actual'")
        [Console]::WriteLine("  FAIL: $Name")
    }
    else { [Console]::WriteLine("  PASS: $Name") }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors) { throw "Could not parse ${Path}: $($errors[0].Message)" }
    $functionAst = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $functionAst) { throw "Function '$Name' not found in $Path" }
    return [scriptblock]::Create($functionAst.Extent.Text)
}

$newLabPath = Join-Path $RootPath 'vmbuild\New-Lab.ps1'
$configPath = Join-Path $RootPath 'vmbuild\common\Common.Config.ps1'
$prerequisitePath = Join-Path $RootPath 'vmbuild\common\Common.Prereqs.ps1'
$dscBuilderPath = Join-Path $RootPath 'vmbuild\DSC\createGuestDscZip.ps1'
. $prerequisitePath
. (Import-TestFunction -Path $newLabPath -Name 'Get-NewLabDesktopUser')
. (Import-TestFunction -Path $newLabPath -Name 'Initialize-NewLabHyperVAccess')
. (Import-TestFunction -Path $newLabPath -Name 'Initialize-NewLabHyperVPrerequisite')
. (Import-TestFunction -Path $newLabPath -Name 'Test-NewLabEnhancedSessionModeCache')
. (Import-TestFunction -Path $newLabPath -Name 'Invoke-NewLabEnhancedSessionModeCheck')
. (Import-TestFunction -Path $newLabPath -Name 'Invoke-NewLabDscArchiveRefresh')
. (Import-TestFunction -Path $configPath -Name 'Start-VMIPRefreshJob')
$windowsPowerShellModulePath = Get-MemLabsWindowsPowerShellModulePath -AllUsersOnly
Assert-Equal $false ($windowsPowerShellModulePath -match '(?i)\\PowerShell\\7(?:\\|;|$)') 'Windows PowerShell module path excludes PowerShell 7 roots'
Assert-Equal $true ($windowsPowerShellModulePath -match '(?i)\\WindowsPowerShell\\Modules(?:;|$)') 'Windows PowerShell module path retains WindowsPowerShell roots'
Assert-Equal $false ($windowsPowerShellModulePath -match [regex]::Escape([Environment]::GetFolderPath('MyDocuments'))) 'elevated Windows PowerShell module path excludes duplicate per-user DSC modules'
$repositoryArtifactState = Get-MemLabsDscArtifactState -DscRoot (Join-Path $RootPath 'vmbuild\DSC')
Assert-Equal $true $repositoryArtifactState.Current 'repository ships a version-bound DSC archive matching its loose TemplateHelp sources'

$observedDesktopUser = Get-NewLabDesktopUser
$currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($observedDesktopUser) {
    Assert-Equal $currentSessionId $observedDesktopUser.SessionId 'native desktop lookup targets the launching Windows session'
    Assert-Equal $true ($observedDesktopUser.SID -is [Security.Principal.SecurityIdentifier]) 'native desktop lookup resolves an account SID'
}
else {
    [Console]::WriteLine('  INFO: No desktop user in the test session; native account SID resolution was not exercised.')
}
Assert-Equal $null ([MemLabs.NewLabDesktopSession]::GetAccountName(0)) 'session zero does not select another signed-in user'
$invalidSessionError = $null
try { $null = [MemLabs.NewLabDesktopSession]::GetAccountName([int]::MaxValue) }
catch { $invalidSessionError = $_ }
Assert-Equal $true ($invalidSessionError.Exception.InnerException -is [ComponentModel.Win32Exception]) 'native session-query failures surface the Windows error'

$script:VmmsPresent = $true
$script:HyperVCmdletsPresent = $true
$script:PromptResponse = 'y'
$script:PromptCount = 0
$script:InstallCount = 0
$script:StartJobCount = 0
$script:InstallFailure = $null
$script:LogMessages = @()
$script:MembershipElevated = $true
$script:DesktopUser = [pscustomobject]@{
    Name = 'MEMLABS\desktop-user'
    SID = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-1234')
    SessionId = 9
}
$script:DesktopLookupCount = 0
$script:DesktopLookupFailure = $null
$script:HyperVGroupMembers = @($script:DesktopUser)
$script:GroupReadFailure = $null
$script:GroupAddFailure = $null
$script:PostAddReadFailure = $null
$script:ApplyGroupAddition = $true
$script:ConcurrentGroupAddition = $false
$script:GroupReadCount = 0
$script:GroupAddCount = 0
$script:AddedGroupSids = @()
$script:StartupEvents = @()

function Get-Service {
    param([string] $Name)
    if ($Name -eq 'vmms' -and $script:VmmsPresent) { return [pscustomobject]@{ Name = 'vmms' } }
    return $null
}
function Get-Command {
    param([string] $Name, [string] $Module)
    if ($Name -eq 'Start-ThreadJob') { return [pscustomobject]@{ Name = $Name } }
    if ($Name -in @('Get-VM', 'Get-VMNetworkAdapter') -and $script:HyperVCmdletsPresent) {
        return [pscustomobject]@{ Name = $Name; ModuleName = $Module }
    }
    return $null
}
function Read-YesOrNoWithTimeout {
    $script:PromptCount++
    return $script:PromptResponse
}
function Install-HyperV {
    $script:InstallCount++
    $script:StartupEvents += 'Install'
    if ($script:InstallFailure) { throw $script:InstallFailure }
}
function Test-MemLabsElevated { return $script:MembershipElevated }
function Get-NewLabDesktopUser {
    $script:DesktopLookupCount++
    $script:StartupEvents += 'Desktop'
    if ($script:DesktopLookupFailure) { throw $script:DesktopLookupFailure }
    return $script:DesktopUser
}
function Get-LocalGroupMember {
    [CmdletBinding()]
    param([Security.Principal.SecurityIdentifier]$SID)
    if ($SID.Value -ne 'S-1-5-32-578') { throw "Unexpected group SID: $SID" }
    $script:GroupReadCount++
    if ($script:GroupReadFailure) { Write-Error -Message $script:GroupReadFailure }
    return $script:HyperVGroupMembers
}
function Add-LocalGroupMember {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Security.Principal.SecurityIdentifier]$SID, [string[]]$Member)
    if ($SID.Value -ne 'S-1-5-32-578' -or $Member.Count -ne 1) { throw 'Unexpected membership target.' }
    $script:GroupAddCount++
    $script:AddedGroupSids += $Member[0]
    if ($script:GroupAddFailure) { Write-Error -Message $script:GroupAddFailure }
    if ($script:ApplyGroupAddition) {
        $script:HyperVGroupMembers += [pscustomobject]@{ SID = [Security.Principal.SecurityIdentifier]::new($Member[0]) }
    }
    if ($script:ConcurrentGroupAddition) {
        Write-Error -Message 'Another startup added the member.' -ErrorId 'MemberExists' -Category ResourceExists
    }
    if ($script:PostAddReadFailure) { $script:GroupReadFailure = $script:PostAddReadFailure }
}
function Write-Log {
    param($Message, [switch] $LogOnly, [switch] $Failure, [switch] $Warning, [switch] $Success)
    $script:LogMessages += [pscustomobject]@{
        Message = "$Message"; Failure = $Failure.IsPresent; Warning = $Warning.IsPresent; Success = $Success.IsPresent
    }
}
function Flush-LogBuffer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Test double must match the production helper name.')]
    param([switch] $All)
}
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)] $Remaining) }
function Start-ThreadJob { $script:StartJobCount++; throw 'Start-ThreadJob must not run when Hyper-V cmdlets are missing.' }

$readyResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $readyResult 'ready host passes prerequisite check'
Assert-Equal 0 $script:PromptCount 'ready host is not prompted'
Assert-Equal 1 $script:InstallCount 'ready host still verifies Hyper-V service readiness'
Assert-Equal 'Desktop,Install' ($script:StartupEvents -join ',') 'installed hosts check desktop membership before Hyper-V readiness'
Assert-Equal 0 $script:GroupAddCount 'existing membership is matched by SID without another add'

$script:VmmsPresent = $false
$script:HyperVCmdletsPresent = $false
$script:PromptResponse = 'y'
$script:StartupEvents = @()
$acceptedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $acceptedResult 'accepted missing prerequisite runs installer'
Assert-Equal 1 $script:PromptCount 'missing prerequisite prompts once'
Assert-Equal 2 $script:InstallCount 'accepted prompt invokes installer'
Assert-Equal 'Install,Desktop' ($script:StartupEvents -join ',') 'new installations establish Hyper-V before checking desktop membership'

$script:PromptResponse = 'n'
$declinedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $declinedResult 'declined prerequisite stops startup'
Assert-Equal 2 $script:PromptCount 'declined prerequisite prompts once more'
Assert-Equal 2 $script:InstallCount 'declined prerequisite does not invoke installer'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*installation was declined*' })) 'decline is logged as failure'

$script:PromptResponse = 'y'
$script:InstallFailure = 'simulated install failure'
$desktopReadsBefore = $script:DesktopLookupCount
$failedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $failedResult 'installer failure stops startup'
Assert-Equal 3 $script:InstallCount 'installer failure was exercised'
Assert-Equal $desktopReadsBefore $script:DesktopLookupCount 'failed new installation does not attempt desktop membership'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*simulated install failure*' })) 'installer failure is logged'

$script:MembershipElevated = $false
$desktopReadsBefore = $script:DesktopLookupCount
$membershipError = $null
try { Initialize-NewLabHyperVAccess -Confirm:$false }
catch { $membershipError = $_ }
Assert-Equal $true ($membershipError.Exception.Message -like '*requires an elevated host session*') 'non-elevated membership calls fail explicitly'
Assert-Equal $desktopReadsBefore $script:DesktopLookupCount 'non-elevated calls do not resolve or grant another account'
$script:MembershipElevated = $true

$script:HyperVGroupMembers = @()
Initialize-NewLabHyperVAccess -WhatIf -Confirm:$false
Assert-Equal 0 $script:GroupAddCount 'WhatIf does not add the desktop account'
Initialize-NewLabHyperVAccess -Confirm:$false
Assert-Equal 1 $script:GroupAddCount 'missing desktop membership is added once'
Assert-Equal $script:DesktopUser.SID.Value $script:AddedGroupSids[0] 'alternate-account elevation grants the desktop SID, not the elevated identity'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Success -and $_.Message -like '*Sign out and back in*' })) 'verified membership reports how to refresh the user token'
Initialize-NewLabHyperVAccess -Confirm:$false
Assert-Equal 1 $script:GroupAddCount 'repeated startup does not add an existing member again'

$savedDesktopUser = $script:DesktopUser
$script:DesktopUser = $null
$groupReadsBefore = $script:GroupReadCount
Initialize-NewLabHyperVAccess -Confirm:$false
Assert-Equal $groupReadsBefore $script:GroupReadCount 'no desktop user skips group access rather than falling back to the elevated account'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Warning -and $_.Message -like '*No signed-in desktop user*' })) 'noninteractive membership skip is visible'
$script:DesktopUser = $savedDesktopUser
$script:InstallFailure = $null

$script:VmmsPresent = $true
$script:HyperVCmdletsPresent = $true
$script:HyperVGroupMembers = @()
$groupAddsBefore = $script:GroupAddCount
$wrapperWhatIfResult = Initialize-NewLabHyperVPrerequisite -WhatIf
Assert-Equal $true $wrapperWhatIfResult 'startup prerequisite forwards WhatIf without failing readiness'
Assert-Equal $groupAddsBefore $script:GroupAddCount 'startup prerequisite WhatIf does not grant membership'

$membershipErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    foreach ($failureCase in @(
            @{ Variable = 'DesktopLookupFailure'; Message = 'simulated desktop SID lookup failure' },
            @{ Variable = 'GroupReadFailure'; Message = 'simulated membership read failure' },
            @{ Variable = 'GroupAddFailure'; Message = 'simulated membership add failure' }
        )) {
        $script:HyperVGroupMembers = @()
        Set-Variable -Name $failureCase.Variable -Value $failureCase.Message -Scope Script
        $membershipResult = Initialize-NewLabHyperVPrerequisite
        Assert-Equal $false $membershipResult "$($failureCase.Variable) stops startup under Continue"
        Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like "*$($failureCase.Message)*" })) "$($failureCase.Variable) retains the failure detail"
        Set-Variable -Name $failureCase.Variable -Value $null -Scope Script
    }
}
finally {
    $ErrorActionPreference = $membershipErrorPreference
    $script:DesktopLookupFailure = $null
    $script:GroupReadFailure = $null
    $script:GroupAddFailure = $null
}

$script:ApplyGroupAddition = $false
$script:LogMessages = @()
$unverifiedResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $unverifiedResult 'an add that does not persist membership stops startup'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*membership could not be verified*' })) 'failed membership verification is reported'
Assert-Equal $false ([bool]($script:LogMessages | Where-Object Success)) 'unverified membership never reports success'

$script:ConcurrentGroupAddition = $true
$script:LogMessages = @()
$unverifiedRaceResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $unverifiedRaceResult 'member-exists without persisted membership still stops startup'
Assert-Equal $false ([bool]($script:LogMessages | Where-Object Success)) 'an unverified concurrent addition does not report success'
$script:ApplyGroupAddition = $true
$concurrentResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $concurrentResult 'a concurrent member-exists error succeeds only after membership verification'
$script:ConcurrentGroupAddition = $false

$unrelatedMember = [pscustomobject]@{
    SID = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-100-200-300-2345')
}
$script:HyperVGroupMembers = @($unrelatedMember)
$script:PostAddReadFailure = 'simulated post-add membership read failure'
$script:LogMessages = @()
try {
    $ErrorActionPreference = 'Continue'
    $postAddReadResult = Initialize-NewLabHyperVPrerequisite
    Assert-Equal $false $postAddReadResult 'a post-add read error stops startup even after the membership persisted'
    Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*simulated post-add membership read failure*' })) 'post-add read failure preserves its error detail'
    Assert-Equal $false ([bool]($script:LogMessages | Where-Object Success)) 'failed post-add read never reports verified success'
}
finally {
    $ErrorActionPreference = $membershipErrorPreference
    $script:GroupReadFailure = $null
    $script:PostAddReadFailure = $null
}
$groupAddsBefore = $script:GroupAddCount
$recoveredMembershipResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $true $recoveredMembershipResult 'startup recovers by reading the previously persisted membership'
Assert-Equal $groupAddsBefore $script:GroupAddCount 'recovery does not add the desktop user twice'
Assert-Equal 1 @($script:HyperVGroupMembers | Where-Object { $_.SID.Value -eq $unrelatedMember.SID.Value }).Count 'membership changes preserve unrelated group members'

$script:HyperVGroupMembers = @($unrelatedMember)
$script:InstallFailure = 'simulated Get-VM readiness failure'
$script:StartupEvents = @()
$groupAddsBefore = $script:GroupAddCount
$unhealthyHostResult = Initialize-NewLabHyperVPrerequisite
Assert-Equal $false $unhealthyHostResult 'an installed host still fails startup when Get-VM readiness fails'
Assert-Equal 'Desktop,Install' ($script:StartupEvents -join ',') 'provider failure occurs only after desktop membership initialization'
Assert-Equal ($groupAddsBefore + 1) $script:GroupAddCount 'installed-host membership is added even when the provider subsequently fails'
Assert-Equal 1 @($script:HyperVGroupMembers | Where-Object { $_.SID.Value -eq $script:DesktopUser.SID.Value }).Count 'verified membership persists after provider failure'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Failure -and $_.Message -like '*simulated Get-VM readiness failure*' })) 'the provider readiness failure remains visible'
$script:InstallFailure = $null

$script:HyperVGroupMembers = @()
$script:GroupAddFailure = 'simulated installed-host membership failure'
$installCountBefore = $script:InstallCount
try {
    $membershipFirstFailure = Initialize-NewLabHyperVPrerequisite
    Assert-Equal $false $membershipFirstFailure 'installed-host membership failure stops startup before readiness'
    Assert-Equal $installCountBefore $script:InstallCount 'failed membership does not enter the provider readiness retry loop'
}
finally {
    $script:GroupAddFailure = $null
}

$esmCacheFixture = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-vmhost-esm-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    Assert-Equal $false (Test-NewLabEnhancedSessionModeCache -Path $esmCacheFixture) 'missing enhanced session cache requires a check'
    @{ Enabled = $true; CheckedUtc = '2000-01-01T00:00:00.0000000Z' } | ConvertTo-Json | Set-Content -LiteralPath $esmCacheFixture
    Assert-Equal $true (Test-NewLabEnhancedSessionModeCache -Path $esmCacheFixture) 'successful enhanced session cache never expires'
    @{ Enabled = $false; CheckedUtc = '2000-01-01T00:00:00.0000000Z' } | ConvertTo-Json | Set-Content -LiteralPath $esmCacheFixture
    Assert-Equal $false (Test-NewLabEnhancedSessionModeCache -Path $esmCacheFixture) 'disabled enhanced session cache requires a check'
    '{invalid json' | Set-Content -LiteralPath $esmCacheFixture
    Assert-Equal $false (Test-NewLabEnhancedSessionModeCache -Path $esmCacheFixture) 'malformed enhanced session cache requires a check'
}
finally {
    Remove-Item -LiteralPath $esmCacheFixture -Force -ErrorAction SilentlyContinue
}

$esmSuccess = Invoke-NewLabEnhancedSessionModeCheck -TimeoutSeconds 5 -Operation {
    [pscustomobject]@{
        ResultType = 'MemLabsEnhancedSessionMode'
        Enabled    = $true
        Changed    = $false
    }
}
Assert-Equal $true $esmSuccess.Succeeded 'enhanced session worker returns a verified result'
Assert-Equal $false $esmSuccess.TimedOut 'enhanced session success is not reported as a timeout'
Assert-Equal $true $esmSuccess.Enabled 'enhanced session success preserves enabled state'

$esmFailure = Invoke-NewLabEnhancedSessionModeCheck -TimeoutSeconds 5 -Operation { throw 'simulated VMHost failure' }
Assert-Equal $false $esmFailure.Succeeded 'enhanced session worker failure does not report success'
Assert-Equal $false $esmFailure.TimedOut 'enhanced session worker failure is distinct from timeout'
Assert-Equal $true ($esmFailure.Error -like '*simulated VMHost failure*') 'enhanced session worker preserves failure detail'

$esmStopwatch = [Diagnostics.Stopwatch]::StartNew()
$esmTimeout = Invoke-NewLabEnhancedSessionModeCheck -TimeoutSeconds 1 -Operation {
    Start-Sleep -Seconds 30
    [pscustomobject]@{
        ResultType = 'MemLabsEnhancedSessionMode'
        Enabled    = $true
        Changed    = $false
    }
}
$esmStopwatch.Stop()
Assert-Equal $false $esmTimeout.Succeeded 'blocked enhanced session worker does not report success'
Assert-Equal $true $esmTimeout.TimedOut 'blocked enhanced session worker reports timeout'
Assert-Equal $true ($esmStopwatch.Elapsed.TotalSeconds -lt 10) 'blocked enhanced session worker returns within its cleanup budget'
Assert-Equal 0 @(Get-Job -Name "MemLabs-VMHostESM-$PID-*" -ErrorAction SilentlyContinue).Count 'enhanced session worker leaves no PowerShell jobs'

$global:Common = [pscustomobject]@{ InJob = $false; CachePath = $env:TEMP }
$script:InstallFailure = $null
$script:HyperVCmdletsPresent = $false
Start-VMIPRefreshJob
Assert-Equal 0 $script:StartJobCount 'VM IP refresh stays dormant without Hyper-V cmdlets'
Assert-Equal $true ([bool]($script:LogMessages | Where-Object { $_.Message -like '*Hyper-V cmdlets are unavailable*' })) 'VM IP refresh explains why it was skipped'

$archiveFixtureParent = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-dsc-refresh-' + [guid]::NewGuid().ToString('N'))
$archiveFixtureRoot = Join-Path $archiveFixtureParent 'DSC'
$moduleFixtureRoot = Join-Path $archiveFixtureRoot 'TemplateHelpDSC'
$null = New-Item -Path $moduleFixtureRoot -ItemType Directory -Force
$archiveFixturePath = Join-Path $archiveFixtureRoot 'DSC.zip'
$manifestFixturePath = Join-Path $moduleFixtureRoot 'TemplateHelpDSC.psd1'
$moduleFixturePath = Join-Path $moduleFixtureRoot 'TemplateHelpDSC.psm1'
$versionFixturePath = Join-Path $archiveFixtureParent 'version.json'
function Write-ArchiveFixture {
    Remove-Item -LiteralPath $archiveFixturePath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $moduleFixtureRoot -DestinationPath $archiveFixturePath -Force
}
try {
    'manifest' | Set-Content -LiteralPath $manifestFixturePath
    'module' | Set-Content -LiteralPath $moduleFixturePath
    @{ memLabsVersion = 'test.1'; latestHotfixVersion = 'test.1' } | ConvertTo-Json | Set-Content -LiteralPath $versionFixturePath
    Write-ArchiveFixture
    Write-MemLabsDscArtifactReceipt -DscRoot $archiveFixtureRoot
    $versionBytesBeforeFailure = [IO.File]::ReadAllBytes($versionFixturePath)
    $versionWriteError = $null
    try { Set-MemLabsVersionFileAtomic -Path $versionFixturePath -MemLabsVersion '' -LatestHotfixVersion 'test.2' }
    catch { $versionWriteError = $_ }
    Assert-Equal $true ([bool]$versionWriteError) 'invalid version update fails before canonical replacement'
    Assert-Equal ([Convert]::ToBase64String($versionBytesBeforeFailure)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($versionFixturePath))) 'failed pre-replacement version update preserves canonical bytes'

    Set-MemLabsVersionFileAtomic -Path $versionFixturePath -MemLabsVersion 'test.2' -LatestHotfixVersion 'test.2'
    $versionWithoutReceipt = Get-MemLabsDscArtifactState -DscRoot $archiveFixtureRoot
    Assert-Equal $false $versionWithoutReceipt.Current 'version replacement without receipt publication remains stale'
    Assert-Equal 'DSC build receipt does not match MemLabsVersion' $versionWithoutReceipt.Reason 'post-version pre-receipt interruption names the mismatched version'
    Set-MemLabsVersionFileAtomic -Path $versionFixturePath -MemLabsVersion 'test.1' -LatestHotfixVersion 'test.1'
    $script:ArchiveBuildCount = 0
    $freshResult = Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $true } -BuildArchive { $script:ArchiveBuildCount++ }
    Assert-Equal $false $freshResult 'current DSC archive requires no restart'
    Assert-Equal 0 $script:ArchiveBuildCount 'current DSC archive does not invoke the builder'

    'module changed' | Set-Content -LiteralPath $moduleFixturePath
    $deniedError = $null
    try { Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $false } -BuildArchive { $script:ArchiveBuildCount++ } }
    catch { $deniedError = $_ }
    Assert-Equal $true ($deniedError.Exception.Message -like '*not a designated MemLabs DSC build server*') 'stale archive on a lab host fails with designation guidance'
    Assert-Equal 0 $script:ArchiveBuildCount 'non-build host cannot invoke the archive builder'

    $buildError = $null
    try {
        Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $true } -BuildArchive {
            $script:ArchiveBuildCount++
            'embedded old module' | Set-Content -LiteralPath $moduleFixturePath
            Write-ArchiveFixture
            'module changed' | Set-Content -LiteralPath $moduleFixturePath
            throw 'fixture build failure'
        }
    }
    catch { $buildError = $_ }
    Assert-Equal $true ($buildError.Exception.Message -like '*fixture build failure*') 'archive builder failure remains actionable'
    Assert-Equal 1 $script:ArchiveBuildCount 'failing archive builder was exercised once'
    $partialPublishError = $null
    try { Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $false } -BuildArchive { $script:ArchiveBuildCount++ } }
    catch { $partialPublishError = $_ }
    Assert-Equal $true ($partialPublishError.Exception.Message -like '*embedded TemplateHelpDSC.psm1 does not match*') 'partial archive publication remains invalid on the next invocation'
    Assert-Equal 1 $script:ArchiveBuildCount 'partial archive cannot bypass the build-server gate on retry'

    Write-ArchiveFixture
    Write-MemLabsDscArtifactReceipt -DscRoot $archiveFixtureRoot
    'module changed again' | Set-Content -LiteralPath $moduleFixturePath
    $unchangedError = $null
    try { Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $true } -BuildArchive { $script:ArchiveBuildCount++ } }
    catch { $unchangedError = $_ }
    Assert-Equal $true ($unchangedError.Exception.Message -like '*without producing current, version-bound artifacts*') 'successful no-op builder cannot request a restart'
    Assert-Equal 2 $script:ArchiveBuildCount 'unchanged archive builder was exercised once'

    $refreshedResult = Invoke-NewLabDscArchiveRefresh -DscRoot $archiveFixtureRoot -TestBuildServer { $true } -BuildArchive {
        $script:ArchiveBuildCount++
        Write-ArchiveFixture
        Write-MemLabsDscArtifactReceipt -DscRoot $archiveFixtureRoot
    }
    Assert-Equal $true $refreshedResult 'verified archive refresh requests one restart'
    Assert-Equal 3 $script:ArchiveBuildCount 'successful archive builder was exercised once'
}
finally {
    Remove-Item -LiteralPath $archiveFixtureParent -Recurse -Force -ErrorAction SilentlyContinue
}

$newLabTokens = $null
$newLabErrors = $null
$newLabAst = [Management.Automation.Language.Parser]::ParseFile($newLabPath, [ref] $newLabTokens, [ref] $newLabErrors)
if ($newLabErrors) { throw "Could not parse ${newLabPath}: $($newLabErrors[0].Message)" }
$topLevelCommands = @($newLabAst.EndBlock.Statements | ForEach-Object {
        $_.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
    })
$prerequisiteCall = @($topLevelCommands | Where-Object { $_.GetCommandName() -eq 'Initialize-NewLabHyperVPrerequisite' })
$networkCall = @($topLevelCommands | Where-Object { $_.GetCommandName() -eq 'Test-NoRRAS' })
Assert-Equal 1 $prerequisiteCall.Count 'New-Lab has one prerequisite call'
Assert-Equal 1 $networkCall.Count 'New-Lab has one NAT validation call'
if ($prerequisiteCall.Count -eq 1 -and $networkCall.Count -eq 1) {
    Assert-Equal $true ($prerequisiteCall[0].Extent.StartOffset -lt $networkCall[0].Extent.StartOffset) 'prerequisite check precedes NAT validation'
}
$newLabSource = Get-Content -LiteralPath $newLabPath -Raw
$dscBuilderSource = Get-Content -LiteralPath $dscBuilderPath -Raw
Assert-Equal $true ($newLabSource -match '(?s)\$archiveRefreshed\s*=\s*Invoke-NewLabDscArchiveRefresh.+?if \(\$archiveRefreshed\) \{\s*\$exitcode\s*=\s*55\s*\r?\n\s*exit \$exitcode\s*\}') 'production startup preserves exit 55 through final cleanup after a verified refresh'
$archiveRestartIf = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match '^if \(\$archiveRefreshed\)'
        }, $true))
$finalExitIf = @($newLabAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text -match '^if \(\$NewLabsuccess -ne \$true\)' -and
            $node.Extent.Text -match 'exit \$exitcode'
        }, $true))
Assert-Equal 1 $archiveRestartIf.Count 'New-Lab has one archive-refresh restart branch'
Assert-Equal 1 $finalExitIf.Count 'New-Lab has one final cleanup exit branch'
if ($archiveRestartIf.Count -eq 1 -and $finalExitIf.Count -eq 1) {
    $exitFixturePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-newlab-exit-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        @"
`$exitcode = 1
`$NewLabsuccess = `$false
try {
    `$archiveRefreshed = `$true
    $($archiveRestartIf[0].Extent.Text)
}
finally {
    function Set-TitleBar {}
    $($finalExitIf[0].Extent.Text)
}
"@ | Set-Content -LiteralPath $exitFixturePath -Encoding UTF8
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $exitFixturePath
        Assert-Equal 55 $LASTEXITCODE 'real New-Lab restart and cleanup branches preserve exit code 55'
    }
    finally { Remove-Item -LiteralPath $exitFixturePath -Force -ErrorAction SilentlyContinue }
}
Assert-Equal $true ($newLabSource -match '(?s)createGuestDscZip\.ps1.+?if \(\$LASTEXITCODE -ne 0\) \{ throw') 'production startup promotes native archive-builder failure'
Assert-Equal $true ($newLabSource -match '(?s)if \(\$NewLabsuccess -ne \$true\).+?exit \$exitcode.+?else \{.+?Script exited\. SUCCESS.+?\$global:LASTEXITCODE = 0') 'production success resets stale native status after explicit failure exits'
Assert-Equal $false ($dscBuilderSource -match 'Common\.ps1" -StartupProfile Fast') 'DSC builder does not suppress the catalogs required by Test-Configuration'
Assert-Equal $true ($dscBuilderSource -match 'Common\.ps1" -SkipMaintenanceRefresh -SkipEnvironmentDetection -SkipHostPreparation') 'DSC builder requests storage catalogs while skipping unrelated host probes'
Assert-Equal $true ($dscBuilderSource -match "(?s)matchingVm\.Count -ne 1.+?full deployed VM name") 'DSC builder rejects unresolved compile VM names before invoking a configuration'

if ($script:Failures.Count -gt 0) {
    [Console]::WriteLine("FAIL: Test-NewLabHostPrerequisites ($($script:Failures.Count) failure(s), $script:AssertionCount assertions)")
    $script:Failures | ForEach-Object { [Console]::WriteLine("  $_") }
    exit 1
}

[Console]::WriteLine("PASS: Test-NewLabHostPrerequisites ($script:AssertionCount assertions)")
exit 0