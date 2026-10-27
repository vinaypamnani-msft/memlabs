<#
.SYNOPSIS
    Verifies maintenance result integrity, evidence limits, and administrator retries.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
. (Join-Path $RootPath 'common\Common.Maintenance.ps1')

function Assert-Maintenance {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-maintenance-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
$savedCommon = $global:Common
try {
    $secret = 'TEST_SECRET_NOT_FOR_LOGS'
    $text = Protect-VMFixDiagnosticText "powershell -Token $secret url=https://example.invalid/a?sig=$secret&sp=r pwd=`"$secret`" https://user:$secret@example.invalid/"
    Assert-Maintenance (-not $text.Contains($secret)) 'Diagnostic redaction leaked a token, password, SAS signature, or URL credential.'
    Assert-Maintenance ((Protect-VMFixDiagnosticText ('x' * 200) 50).Length -lt 80) 'Diagnostic text truncation is not bounded.'
    Assert-Maintenance ((Get-VMFixExecutionTimeout 'Fix-ODBC18') -eq 1800) 'ODBC execution timeout changed unexpectedly.'
    Assert-Maintenance ((Get-VMFixExecutionTimeout 'Fix-Upgrade-Console') -eq 3600) 'Console execution timeout changed unexpectedly.'
    Assert-Maintenance ((Get-VMFixExecutionTimeout 'Fix-CMFullAdmin') -eq 600) 'Administrator execution timeout changed unexpectedly.'
    Assert-Maintenance ((Get-VMFixExecutionTimeout 'Fix-Unrelated') -eq 0) 'Unrelated fixes acquired an unexpected execution policy.'

    function Start-Transcript {
        param($Path, [switch]$Force, $ErrorAction)
        [void]$Force; [void]$ErrorAction
        [IO.File]::WriteAllLines($Path, @("Host Application: powershell.exe -Token $secret", "password=$secret"))
    }
    function Stop-Transcript {}
    foreach ($case in @(
            @{ Name = 'False'; Body = { 'pipeline noise'; [pscustomobject]@{ Success = $false; Message = 'not applied' } }; Expected = $false }
            @{ Name = 'True'; Body = { 'pipeline noise'; [pscustomobject]@{ Success = $true; Message = 'verified' } }; Expected = $true }
            @{ Name = 'NonBoolean'; Body = { [pscustomobject]@{ Success = 'false' } }; Expected = $false }
            @{ Name = 'Ambiguous'; Body = { [pscustomobject]@{ Success = $false }; [pscustomobject]@{ Success = $true } }; Expected = $false }
            @{ Name = 'Throw'; Body = { throw 'password=TEST_SECRET_NOT_FOR_LOGS' }; Expected = $false }
            @{ Name = 'LegacyTrue'; Body = { $true }; Expected = $true }
            @{ Name = 'LegacyFalse'; Body = { $false }; Expected = $false }
            @{ Name = 'MixedLegacyFalse'; Body = { [pscustomobject]@{ Success = $true }; $false }; Expected = $false }
        )) {
        $name = "Fix-Unit$($case.Name)"
        $wrapper = New-VMFixScriptBlock -FixName $name -Body $case.Body
        $wrapper = [scriptblock]::Create($wrapper.ToString().Replace('C:\staging\Fix', (Join-Path $testRoot 'fixes')))
        $output = @(& $wrapper 3>$null 6>$null)
        $marker = Get-Content -LiteralPath (Join-Path $testRoot "fixes\$name.result.json") -Raw | ConvertFrom-Json
        Assert-Maintenance ($marker.Success -eq $case.Expected) "Incorrect authoritative result for $($case.Name)."
        Assert-Maintenance ($marker.AttemptId -and $marker.Identity -and $output[-1].IsStructured) 'Wrapper omitted attempt identity or the structured result.'
        $raw = Get-Content -LiteralPath (Join-Path $testRoot "fixes\$name.txt") -Raw
        Assert-Maintenance (-not $raw.Contains($secret)) 'Guest transcript history retained secrets.'
        $raw = Get-Content -LiteralPath (Join-Path $testRoot "fixes\$name.result.json") -Raw
        Assert-Maintenance (-not $raw.Contains($secret)) 'The result marker retained a credential.'
        if ($case.Name -eq 'False') {
            $null = @(& $wrapper 3>$null 6>$null)
            $history = @(Get-ChildItem -LiteralPath (Join-Path $testRoot "fixes\history\$name") -Filter '*.result.json')
            Assert-Maintenance ($history.Count -eq 2) 'A retry overwrote the first attempt result.'
        }
    }
    Remove-Item Function:\Start-Transcript, Function:\Stop-Transcript

    $script:EvidenceCalls = [System.Collections.Generic.List[object]]::new()
    $script:EvidenceLogs = [System.Collections.Generic.List[string]]::new()
    $script:EvidenceFailure = $false
    function Write-Log {
        param([string]$Message, [switch]$Warning, [switch]$LogOnly)
        [void]$Warning; [void]$LogOnly
        $script:EvidenceLogs.Add($Message)
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName,
            [switch]$AsJob, [int]$TimeoutSeconds, [int]$SessionMaxRetries,
            [switch]$SuppressLog, [switch]$FailOnRemoteError, $VmDomainAccount)
        [void]$VmName; [void]$VmDomainName; [void]$ScriptBlock; [void]$ArgumentList; [void]$DisplayName; [void]$SuppressLog
        $script:EvidenceCalls.Add([pscustomobject]@{
                AsJob = $AsJob.IsPresent; Timeout = $TimeoutSeconds; Retries = $SessionMaxRetries
                FailOnRemoteError = $FailOnRemoteError.IsPresent; Account = $VmDomainAccount
            })
        [pscustomobject]@{
            ScriptBlockFailed = $script:EvidenceFailure
            ErrorDetails = if ($script:EvidenceFailure) { 'synthetic timeout' } else { $null }
            ScriptBlockOutput = if ($script:EvidenceFailure) { $null } else {
                [pscustomobject]@{ SchemaVersion = 1; FixName = 'Fix-ODBC18'; Logs = @(); CollectionErrors = @() } | ConvertTo-Json
            }
        }
    }
    $global:Common = [pscustomobject]@{ LogPath = (Join-Path $testRoot 'VMBuild.log'); MemLabsVersion = 'test'; LatestHotfixVersion = 'test' }
    Save-VMFixFailureEvidence -VMName 'LAB-PRI' -VMDomain 'lab.test' -FixName 'Fix-ODBC18' -VMDomainAccount 'admin'
    Assert-Maintenance (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.diagnostics.log').Count -eq 1) 'Evidence was not persisted in the host log directory.'
    $call = $script:EvidenceCalls[0]
    Assert-Maintenance ($call.AsJob -and $call.Timeout -eq 60 -and $call.Retries -eq 1 -and $call.FailOnRemoteError -and $call.Account -eq 'admin') 'Evidence collection lost its time limit, error contract, or requested account.'
    $script:EvidenceFailure = $true
    Save-VMFixFailureEvidence -VMName 'LAB-PRI' -VMDomain 'lab.test' -FixName 'Fix-ODBC18'
    Assert-Maintenance (($script:EvidenceLogs -join "`n") -match 'evidence collection failed.+synthetic timeout') 'Evidence timeout was silently ignored.'
    $collectorText = (Get-VMFixDiagnosticScriptBlock).ToString()
    Assert-Maintenance ($collectorText -match 'MaxEvents 10' -and $collectorText -match 'Tail 60' -and $collectorText -match '512KB') 'Evidence collection limits are missing.'
    Assert-Maintenance ($collectorText -notmatch 'Win32_Product|InstallProduct|Stop-Service|Stop-Process') 'The evidence collector can mutate guest installer/service state.'
    Remove-Item Function:\Invoke-VmCommand, Function:\Write-Log

    function Invoke-MaintenanceEngineFixture {
        param([switch]$Batch, [switch]$AlwaysFail, [switch]$MissingMarker)
        & {
            $script:Engine = @{
                Count = 0; Stamps = 0; AlwaysFail = $AlwaysFail.IsPresent
                MissingMarker = $MissingMarker.IsPresent
                Directory = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
                Calls = [System.Collections.Generic.List[object]]::new()
                Events = [System.Collections.Generic.List[string]]::new()
                Sleeps = [System.Collections.Generic.List[int]]::new()
            }
            $null = New-Item -ItemType Directory -Path $script:Engine.Directory
            function Write-Log { param($Message, [switch]$Warning, [switch]$LogOnly, [switch]$Verbose) }
            function Write-Progress2 { param([switch]$Log, $PercentComplete, $Activity, $Status, [switch]$Force) }
            function Get-VMNote {
                param($VMName)
                [pscustomobject]@{ domain = 'lab.test'; appliedFixes = [pscustomobject]@{} }
            }
            function ConvertTo-MemLabsVersion { param($Version) [version]$Version }
            function Start-VMIfNotRunning {
                param($VMName, $VMDomain, [switch]$WaitForConnect, [switch]$Quiet)
                [pscustomobject]@{ StartedVM = $false; StartFailed = $false }
            }
            function Get-VmSession {
                param($VmName, $VmDomainName, $VmDomainAccount, [switch]$ShowVMSessionError)
                [pscustomobject]@{ Availability = 'Available' }
            }
            function Start-Transcript {
                param($Path, [switch]$Force, $ErrorAction)
                [IO.File]::WriteAllText($Path, 'synthetic engine transcript')
            }
            function Stop-Transcript {}
            function Start-Sleep {
                param([int]$Seconds, [int]$Milliseconds)
                if ($Seconds -gt 0) {
                    $script:Engine.Sleeps.Add($Seconds)
                    $script:Engine.Events.Add("sleep:$Seconds")
                }
            }
            function Get-VMFixTranscript {
                param($VMName, $VMDomain, $FixName, $VMDomainAccount, [switch]$CollectDiagnostics, $Stage)
                if ($CollectDiagnostics) { $script:Engine.Events.Add('diagnostics') }
            }
            function Set-VMNoteFixBatch {
                param($VMName, $Fixes)
                $script:Engine.Stamps += @($Fixes).Count
                Get-VMNote -VMName $VMName
            }
            function Set-VMNote {
                param($VMName, $FixApplied, $FixAppliedVersion)
                $script:Engine.Stamps++
            }
            function Get-VMFixResultMarker {
                param($VMName, $VMDomain, $FixName, $VMDomainAccount)
                if ($script:Engine.MissingMarker) { return $null }
                Get-Content -LiteralPath (Join-Path $script:Engine.Directory "$FixName.result.json") -Raw | ConvertFrom-Json
            }
            function Invoke-VmCommand {
                param($VmName, $VmDomainName, $VmDomainAccount, $ScriptBlock, $ArgumentList, $DisplayName,
                    [switch]$AsJob, $TimeoutSeconds, [switch]$FailOnRemoteError, [switch]$ShowVMSessionError)
                $script:Engine.Calls.Add([pscustomobject]@{
                        AsJob = $AsJob.IsPresent; Timeout = $TimeoutSeconds; Account = $VmDomainAccount
                        FailOnRemoteError = $FailOnRemoteError.IsPresent
                    })
                $text = $ScriptBlock.ToString().Replace('C:\staging\Fix', $script:Engine.Directory)
                $arguments = @($ArgumentList)
                if ($DisplayName -like 'Maintenance batch*') {
                    $definitions = $arguments[0] | ConvertFrom-Json
                    foreach ($definition in $definitions) {
                        $definition.Script = $definition.Script.Replace('C:\staging\Fix', $script:Engine.Directory)
                    }
                    $arguments[0] = $definitions | ConvertTo-Json -Depth 6 -Compress
                }
                $value = & ([scriptblock]::Create($text)) @arguments 3>$null 6>$null
                [pscustomobject]@{ ScriptBlockFailed = $false; ScriptBlockOutput = $value; ErrorDetails = $null }
            }
            $definition = [pscustomobject]@{
                FixName = 'Fix-ODBC18'; FixVersion = '18.6.2.1'; AppliesToThisVM = $true
                RunAsAccount = 'setupadmin'; DependentVMs = @(); InjectFiles = @(); InjectTools = @()
                ScriptBlock = {
                    $script:Engine.Count++
                    'pipeline noise must not mask a failed result'
                    [pscustomobject]@{ Success = -not $script:Engine.AlwaysFail -and $script:Engine.Count -gt 1; Message = 'engine fixture' }
                }
            }
            if ($Batch) { $result = Start-VMFixesBatched -VMName 'LAB-PRI' -VMDomain 'lab.test' -VMFixes @($definition) }
            else { $result = Start-VMFix -VMName 'LAB-PRI' -VMFix $definition }
            [pscustomobject]@{ Result = $result; State = $script:Engine }
        }
    }
    foreach ($batch in @($false, $true)) {
        foreach ($fail in @($false, $true)) {
            $probe = Invoke-MaintenanceEngineFixture -Batch:$batch -AlwaysFail:$fail
            Assert-Maintenance ($probe.State.Count -eq 2 -and $probe.Result.Success -eq (-not $fail)) 'The real maintenance engine exceeded its attempt budget or lost the explicit verdict.'
            Assert-Maintenance ($probe.State.Stamps -eq $(if ($fail) { 0 } else { 1 })) 'A failed fix was stamped or a successful retry was stamped more than once.'
            Assert-Maintenance ($probe.State.Sleeps.Count -eq 1 -and $probe.State.Sleeps[0] -eq 60) 'The engine did not use exactly one 60-second retry delay.'
            Assert-Maintenance ($probe.State.Events.IndexOf('diagnostics') -lt $probe.State.Events.IndexOf('sleep:60')) 'Evidence was not collected before the retry delay.'
            Assert-Maintenance (@($probe.State.Calls | Where-Object {
                        -not $_.AsJob -or $_.Timeout -ne 1800 -or -not $_.FailOnRemoteError -or $_.Account -ne 'setupadmin'
                    }).Count -eq 0) 'A maintenance execution lost its deadline or requested account.'
        }
    }
    $missingMarker = Invoke-MaintenanceEngineFixture -MissingMarker
    Assert-Maintenance (-not $missingMarker.Result.Success -and $missingMarker.State.Stamps -eq 0 -and $missingMarker.State.Count -eq 2) `
        'A successful pipeline result bypassed a missing authoritative marker.'

    $vmNote = [pscustomobject]@{ adminName = 'setupadmin'; remoteSQLVM = 'LAB-SQL' }
    $dc = [pscustomobject]@{ vmName = 'LAB-DC' }
    $fixesToPerform = @()
    . (Join-Path $RootPath 'Fixes\Fix-CMFullAdmin.ps1')
    $fix = $fixesToPerform | Where-Object FixName -eq 'Fix-CMFullAdmin'
    Assert-Maintenance ($fix.RunAsAccount -eq 'setupadmin') 'Full Administrator assignment does not use the configured setup administrator.'
    $adminBody = [scriptblock]::Create(
        $fix.ScriptBlock.Ast.ParamBlock.Extent.Text + "`n" +
        ((@($fix.ScriptBlock.Ast.EndBlock.Statements | Where-Object {
                        $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
                    }) | ForEach-Object { $_.Extent.Text }) -join "`n")
    )
    function Invoke-AdminFixture {
        param([string]$Mode)
        & {
            $script:AdminFixture = @{
                Mode = $Mode; DriveCalls = 0; Queries = 0; Adds = 0; Removes = 0; Assigned = $false
                Sleeps = [System.Collections.Generic.List[int]]::new(); Scope = @(); Collections = @()
            }
            function Write-FixLog { param($Message, $Level) [void]$Message; [void]$Level }
            function Test-Path { param($LiteralPath, $PathType) return $true }
            function Get-ItemProperty {
                param($LiteralPath, $ErrorAction)
                [void]$ErrorAction
                if ($LiteralPath -like '*Identification') { [pscustomobject]@{ 'Site Code' = 'P01' } }
                else { [pscustomobject]@{ 'UI Installation Directory' = 'C:\Console' } }
            }
            function Get-Module { param($Name) [void]$Name; [pscustomobject]@{ Name = 'ConfigurationManager' } }
            function Get-CimInstance {
                param($Namespace, $ClassName, $OperationTimeoutSec, $ErrorAction)
                [void]$Namespace; [void]$ClassName; [void]$OperationTimeoutSec; [void]$ErrorAction
                [pscustomobject]@{ SiteCode = 'P01'; ProviderForLocalSite = $true; Machine = 'LAB-PRI.lab.test' }
            }
            function Get-PSDrive { param($Name, $PSProvider, $ErrorAction) }
            function New-PSDrive {
                param($Name, $PSProvider, $Root, $ErrorAction)
                [void]$Name; [void]$PSProvider; [void]$ErrorAction
                $script:AdminFixture.DriveCalls++
                if ($script:AdminFixture.Mode -eq 'DriveRetry' -and $script:AdminFixture.DriveCalls -eq 1) { throw 'provider warming up' }
                [pscustomobject]@{ Root = $Root }
            }
            function Push-Location { param($Path, $ErrorAction) }
            function Pop-Location {}
            function Remove-PSDrive { param($Name, [switch]$Force, $ErrorAction) $script:AdminFixture.Removes++ }
            function Get-CMAdministrativeUser {
                param($RoleName, $ErrorAction)
                [void]$RoleName; [void]$ErrorAction
                $script:AdminFixture.Queries++
                if ($script:AdminFixture.Mode -eq 'Exhausted') { throw 'provider unavailable' }
                if ($script:AdminFixture.Mode -eq 'QueryRetry' -and $script:AdminFixture.Queries -eq 1) { throw 'query warming up' }
                if ($script:AdminFixture.Assigned -or $script:AdminFixture.Mode -eq 'Already') {
                    return [pscustomobject]@{ LogonName = 'LAB\vmbuildadmin' }
                }
                if ($script:AdminFixture.Mode -eq 'WrongPrincipal') {
                    [pscustomobject]@{ LogonName = 'OTHER\vmbuildadmin' }
                    [pscustomobject]@{ LogonName = 'LAB\old-vmbuildadmin' }
                }
            }
            function New-CMAdministrativeUser {
                param($Name, $RoleName, $SecurityScopeName, $CollectionName, $ErrorAction)
                [void]$Name; [void]$RoleName; [void]$ErrorAction
                $script:AdminFixture.Adds++
                $script:AdminFixture.Scope = @($SecurityScopeName)
                $script:AdminFixture.Collections = @($CollectionName)
                $script:AdminFixture.Assigned = $true
            }
            function Start-Sleep { param([int]$Seconds) $script:AdminFixture.Sleeps.Add($Seconds) }
            function Get-CmAdminDirectoryEvidence { param($AccountName) "DIAG AD resolves $AccountName`: false" }
            $result = & $adminBody -MaximumAttempts 3 -RetrySeconds 7
            [pscustomobject]@{ Result = $result; State = $script:AdminFixture }
        }
    }
    $savedDomain = $env:USERDOMAIN
    $savedDnsDomain = $env:USERDNSDOMAIN
    try {
        $env:USERDOMAIN = 'LAB'
        $env:USERDNSDOMAIN = 'lab.test'
        foreach ($mode in @('Already', 'Add', 'WrongPrincipal', 'DriveRetry', 'QueryRetry', 'Exhausted')) {
            $probe = Invoke-AdminFixture -Mode $mode
            Assert-Maintenance ($probe.Result.Success -eq ($mode -ne 'Exhausted')) "Incorrect administrator outcome for $mode."
            if ($mode -eq 'Already') { Assert-Maintenance ($probe.State.Adds -eq 0) 'An existing exact administrator was added again.' }
            if ($mode -eq 'WrongPrincipal') { Assert-Maintenance ($probe.State.Adds -eq 1) 'A different domain or substring account satisfied the administrator check.' }
            if ($mode -in @('Add', 'WrongPrincipal', 'DriveRetry', 'QueryRetry')) {
                Assert-Maintenance (($probe.State.Scope -join ',') -eq 'All' -and $probe.State.Collections.Count -eq 2) 'Collections were passed as security scopes.'
            }
            if ($mode -in @('DriveRetry', 'QueryRetry')) {
                Assert-Maintenance ($probe.Result.Attempts -eq 2 -and $probe.State.Sleeps.Count -eq 1 -and $probe.State.Sleeps[0] -eq 7) 'Provider warm-up did not recover on the second bounded attempt.'
            }
            if ($mode -eq 'Exhausted') {
                Assert-Maintenance ($probe.Result.Attempts -eq 3 -and $probe.State.Sleeps.Count -eq 2) 'Administrator retries exceeded their budget or slept after the final attempt.'
            }
        }
    }
    finally { $env:USERDOMAIN = $savedDomain; $env:USERDNSDOMAIN = $savedDnsDomain }
}
finally {
    $global:Common = $savedCommon
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- Maintenance markers, attempt history, bounded evidence, secret redaction, and exact administrator retries.'
