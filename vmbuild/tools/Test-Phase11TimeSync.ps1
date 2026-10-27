<#
.SYNOPSIS
    Verifies Phase 11 Windows Time diagnostics, bounded recovery, and warning-only failures.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}
$timeFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-WindowsTimeSync'
        }, $true))
if ($timeFunctions.Count -ne 1) { throw "Expected one Test-WindowsTimeSync function; found $($timeFunctions.Count)." }
Invoke-Expression $timeFunctions[0].Extent.Text

$memberFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-DomainMemberFunctionality'
        }, $true))
$guestBlocks = @($memberFunctions[0].Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$scriptBlock'
        }, $true))
if ($guestBlocks.Count -ne 1 -or
    @($guestBlocks[0].Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Test-WindowsTimeSync'
            }, $true)).Count -ne 1 -or
    $guestBlocks[0].Right.Extent.Text -notmatch 'Test-WindowsTimeSync -Details \$results\.Details -Activity \$progressActivity') {
    throw 'DomainMember guest validation does not invoke the dynamically tested Windows Time helper.'
}
if ($timeFunctions[0].Extent.Text -match '\.Passed\s*=') {
    throw 'Windows Time warning-only validation must not change the overall Passed verdict.'
}

$script:Clock = [datetime]'2026-10-25T04:26:50'
$script:State = $null
function New-StatusResponse {
    param([string]$Text, [int]$ExitCode = 0, [string]$Failure = '')
    [pscustomobject]@{ Text = $Text; ExitCode = $ExitCode; Failure = $Failure }
}
function w32tm.exe {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Mocks the native command without invoking Windows Time.')]
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $command = $Arguments -join ' '
    $script:State.Commands.Add($command)
    if ($command -eq '/query /status /verbose') {
        $index = [math]::Min($script:State.StatusCalls, $script:State.Responses.Count - 1)
        $script:State.StatusCalls++
        $response = $script:State.Responses[$index]
    }
    elseif ($command -eq '/resync /rediscover /nowait') {
        $response = New-StatusResponse -Text 'Resync request result' -ExitCode $script:State.ResyncExitCode
    }
    elseif ($command -in @('/query /source', '/query /configuration', '/query /peers')) {
        $response = New-StatusResponse -Text "Captured $command"
    }
    else { throw "Unexpected or configuration-changing w32tm command: $command" }
    if ($response.Failure) { throw $response.Failure }
    Set-Variable -Name LASTEXITCODE -Value $response.ExitCode -Scope 1
    $response.Text
}
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -ne 'W32Time') { throw "Unexpected service query: $Name" }
    $script:State.ServiceQueries++
    if ($script:State.ServiceFailure) { throw $script:State.ServiceFailure }
    [pscustomobject]@{ Status = $script:State.ServiceStatus; StartType = $script:State.StartType }
}
function Start-Service {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -ne 'W32Time') { throw "Unexpected service start: $Name" }
    $script:State.Starts++
    $script:State.Commands.Add("Start-Service $Name")
    if ($script:State.StartFailure) { throw $script:State.StartFailure }
    $script:State.ServiceStatus = 'Running'
}
function Set-Service {
    [CmdletBinding()]
    param([string]$Name, [string]$StartupType)
    throw "Windows Time must not reconfigure service '$Name' to '$StartupType'."
}
function Get-WinEvent {
    [CmdletBinding()]
    param([hashtable]$FilterHashtable, [int]$MaxEvents)
    $script:State.EventQueries++
    $script:State.Commands.Add('Get-WinEvent')
    if ($MaxEvents -ne 5 -or $FilterHashtable.LogName -ne 'System' -or
        $FilterHashtable.ProviderName -ne 'Microsoft-Windows-Time-Service' -or
        $FilterHashtable.StartTime -ne $script:Clock.AddHours(-1)) {
        throw 'Windows Time events must be bounded to five provider events from the last hour.'
    }
    if ($script:State.EventFailure) { throw $script:State.EventFailure }
    if ($script:State.NoMatchingEvents) {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('No events found.'), 'NoMatchingEventsFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    if (-not $script:State.NoEvents) {
        [pscustomobject]@{ Id = 37; TimeCreated = $script:Clock; LevelDisplayName = 'Information'; Message = 'Time provider received valid data.' }
    }
}
function Get-Date {
    [CmdletBinding()]
    param()
    $script:Clock
}
function Start-Sleep {
    param([int]$Seconds)
    if ($Seconds -ne 5) { throw "Unexpected time-sync polling delay: ${Seconds}s" }
    $script:State.SleepSeconds += $Seconds
    $script:State.SleepCalls++
}
function Write-Progress {
    param([string]$Activity, [string]$Status)
    if ($Activity -ne 'Time-sync regression' -or $Status -notmatch 'attempt \d/6') {
        throw "Missing time-sync progress heartbeat: $Activity / $Status"
    }
}

$dateText = $script:Clock.AddSeconds(-30).ToString('G', [System.Globalization.CultureInfo]::CurrentCulture)
$healthyText = @"
Leap Indicator: 0(no warning)
Stratum: 3 (secondary reference)
ReferenceId: 0x0A080801
Last Successful Sync Time: $dateText
Source: CSB-DC1.cstest8b.com
"@
$healthy = New-StatusResponse -Text $healthyText
$unsynchronized = New-StatusResponse -Text ($healthyText.Replace('0(no warning)', '3(not synchronized)').Replace('Stratum: 3', 'Stratum: 0').Replace($dateText, 'unspecified'))
$nativeError = New-StatusResponse -Text 'The service has not been started. (0x80070426)' -ExitCode 5
$stale = New-StatusResponse -Text ($healthyText.Replace($dateText, $script:Clock.AddSeconds(-86401).ToString('G')))
$cases = @(
    @{ Name = 'healthy'; Responses = @($healthy); Outcome = 'OK'; Checks = 1 },
    @{ Name = 'stopped service recovers'; Responses = @($nativeError, $healthy); ServiceStatus = 'Stopped'; Outcome = 'RECOVERED'; Checks = 2; Starts = 1; Resyncs = 1; Evidence = @('0x80070426', 'service status=Stopped', 'started W32Time') },
    @{ Name = 'unsynchronized recovers'; Responses = @($unsynchronized, $unsynchronized, $healthy); Outcome = 'RECOVERED'; Checks = 3; Resyncs = 1; Evidence = @('unspecified', 'leap indicator 3', 'event id=37') },
    @{ Name = 'resync request alone is not success'; Responses = @($unsynchronized); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('after 6 attempts', 'exit=0') },
    @{ Name = 'native nonzero rejects healthy-looking output'; Responses = @((New-StatusResponse -Text $healthyText -ExitCode 5)); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('exit=5', 'status query failed') },
    @{ Name = 'native invocation exception'; Responses = @((New-StatusResponse -Failure 'w32tm invocation unavailable')); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('invocation failed', 'w32tm invocation unavailable') },
    @{ Name = 'disabled service preserved'; Responses = @($nativeError); ServiceStatus = 'Stopped'; StartType = 'Disabled'; Outcome = 'WARN'; Checks = 1; Evidence = @('disabled and was not reconfigured') },
    @{ Name = 'unavailable service state'; Responses = @($nativeError); ServiceFailure = 'service access denied'; Outcome = 'WARN'; Checks = 1; Evidence = @('service access denied', 'recovery was not attempted') },
    @{ Name = 'service start failure'; Responses = @($nativeError); ServiceStatus = 'Stopped'; StartFailure = 'start access denied'; Outcome = 'WARN'; Checks = 1; Starts = 1; Evidence = @('could not start W32Time', 'start access denied') },
    @{ Name = 'resync error retained'; Responses = @($unsynchronized); ResyncExitCode = 5; Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('/resync /rediscover /nowait exit=5') },
    @{ Name = 'verification can recover after resync request error'; Responses = @($unsynchronized, $healthy); ResyncExitCode = 5; Outcome = 'RECOVERED'; Checks = 2; Resyncs = 1; Evidence = @('/resync /rediscover /nowait exit=5') },
    @{ Name = 'missing fields do not trigger speculative repair'; Responses = @((New-StatusResponse -Text "Last Successful Sync Time: $dateText")); Outcome = 'WARN'; Checks = 1; Evidence = @('unrecognized or missing status fields', 'no speculative recovery') },
    @{ Name = 'localized labels retained without repair'; Responses = @((New-StatusResponse -Text 'Derniere synchronisation reussie: 25/10/2026 04:26:20')); Outcome = 'WARN'; Checks = 1; Evidence = @('Derniere synchronisation reussie', 'possibly localized output') },
    @{ Name = 'case and whitespace accepted'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('Last Successful Sync Time:', '  last successful sync time:  ')))); Outcome = 'OK'; Checks = 1 },
    @{ Name = 'unspecified timestamp rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, 'unspecified')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('unavailable or invalid') },
    @{ Name = 'invalid timestamp rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, 'not a timestamp')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('not a timestamp') },
    @{ Name = 'stale timestamp rejected'; Responses = @($stale); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('older than 24 hours') },
    @{ Name = '24-hour freshness boundary accepted'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, $script:Clock.AddSeconds(-86400).ToString('G'))))); Outcome = 'OK'; Checks = 1; Evidence = @('age=86400s') },
    @{ Name = 'future timestamp rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, $script:Clock.AddSeconds(301).ToString('G'))))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('more than 5 minutes in the future') },
    @{ Name = 'five-minute future tolerance accepted'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, $script:Clock.AddSeconds(300).ToString('G'))))); Outcome = 'OK'; Checks = 1; Evidence = @('age=-300s') },
    @{ Name = 'unsynchronized leap rejected despite valid timestamp'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('0(no warning)', '3(not synchronized)')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('leap indicator 3') },
    @{ Name = 'zero stratum rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('Stratum: 3', 'Stratum: 0')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('stratum 0') },
    @{ Name = 'unsynchronized stratum rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('Stratum: 3', 'Stratum: 16')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('stratum 16') },
    @{ Name = 'local clock rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('CSB-DC1.cstest8b.com', 'Local CMOS Clock')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('local clock') },
    @{ Name = 'locale-independent local reference rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('0x0A080801', '0x4C4F434C')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('local clock') },
    @{ Name = 'empty source rejected'; Responses = @((New-StatusResponse -Text ($healthyText.Replace('CSB-DC1.cstest8b.com', '')))); Outcome = 'WARN'; Checks = 6; Resyncs = 1; Evidence = @('source') },
    @{ Name = 'empty status retained'; Responses = @((New-StatusResponse -Text '')); Outcome = 'WARN'; Checks = 1; Evidence = @('<no output>', 'unrecognized') },
    @{ Name = 'no recent events reported explicitly'; Responses = @($unsynchronized, $healthy); NoEvents = $true; Outcome = 'RECOVERED'; Checks = 2; Resyncs = 1; Evidence = @('no System events in the last hour') },
    @{ Name = 'native no-matching-events error reported explicitly'; Responses = @($unsynchronized, $healthy); NoMatchingEvents = $true; Outcome = 'RECOVERED'; Checks = 2; Resyncs = 1; Evidence = @('no System events in the last hour') },
    @{ Name = 'event access failure retained'; Responses = @($unsynchronized, $healthy); EventFailure = 'event access denied'; Outcome = 'RECOVERED'; Checks = 2; Resyncs = 1; Evidence = @('event query failed: event access denied') },
    @{ Name = 'current-culture timestamp accepted'; Responses = @((New-StatusResponse -Text ($healthyText.Replace($dateText, $script:Clock.AddSeconds(-30).ToString('G', [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')))))); Culture = 'fr-FR'; Outcome = 'OK'; Checks = 1 }
)

$originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    foreach ($case in $cases) {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        if ($case.Culture) { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($case.Culture) }
        $script:State = @{
            Responses = $case.Responses; Commands = [System.Collections.Generic.List[string]]::new()
            StatusCalls = 0; ServiceQueries = 0; EventQueries = 0; Starts = 0; SleepCalls = 0; SleepSeconds = 0
            ServiceStatus = 'Running'; StartType = 'Manual'; ServiceFailure = ''; StartFailure = ''; EventFailure = ''
            ResyncExitCode = 0; NoEvents = $false; NoMatchingEvents = $false
        }
        foreach ($key in @('ServiceStatus', 'StartType', 'ServiceFailure', 'StartFailure', 'EventFailure', 'ResyncExitCode', 'NoEvents', 'NoMatchingEvents')) {
            if ($case.ContainsKey($key)) { $script:State[$key] = $case[$key] }
        }
        $details = [System.Collections.Generic.List[string]]::new()
        $unexpectedOutput = @(Test-WindowsTimeSync -Details $details -Activity 'Time-sync regression')
        $outcomes = @($details | Where-Object { $_ -match '^(OK|RECOVERED|WARN):' })
        $resyncs = @($script:State.Commands | Where-Object { $_ -eq '/resync /rediscover /nowait' }).Count
        if ($unexpectedOutput.Count -ne 0 -or $outcomes.Count -ne 1 -or $outcomes[0] -notmatch "^$($case.Outcome):") {
            throw "$($case.Name): wrong output/verdict: pipeline=$($unexpectedOutput.Count); details=$($details -join '; ')"
        }
        if ($script:State.StatusCalls -ne $case.Checks -or
            $script:State.Starts -ne [int]$case.Starts -or $resyncs -ne [int]$case.Resyncs -or
            $script:State.SleepCalls -ne ($case.Checks - 1) -or $script:State.SleepSeconds -ne (($case.Checks - 1) * 5)) {
            throw "$($case.Name): unbounded/unexpected recovery: checks=$($script:State.StatusCalls), starts=$($script:State.Starts), resyncs=$resyncs, sleeps=$($script:State.SleepCalls)/$($script:State.SleepSeconds)s."
        }
        if ($case.Outcome -eq 'OK') {
            if ($script:State.ServiceQueries -ne 0 -or $script:State.EventQueries -ne 0 -or $script:State.Commands.Count -ne 1) {
                throw "$($case.Name): healthy checks performed unnecessary diagnostics or mutations."
            }
        }
        else {
            if ($script:State.ServiceQueries -ne 1 -or $script:State.EventQueries -ne 1) {
                throw "$($case.Name): initial service/event diagnostics were not captured exactly once."
            }
            foreach ($query in @('source', 'configuration', 'peers')) {
                if (-not $script:State.Commands.Contains("/query /$query") -or
                    -not ($details -match "/query /$query exit=")) {
                    throw "$($case.Name): missing command result for $query."
                }
            }
            foreach ($mutation in @('Start-Service W32Time', '/resync /rediscover /nowait')) {
                $mutationIndex = $script:State.Commands.IndexOf($mutation)
                if ($mutationIndex -ge 0 -and
                    ($mutationIndex -lt $script:State.Commands.IndexOf('/query /peers') -or
                        $mutationIndex -lt $script:State.Commands.IndexOf('Get-WinEvent'))) {
                    throw "$($case.Name): recovery ran before diagnostic capture."
                }
            }
        }
        foreach ($evidence in $case.Evidence) {
            if (-not ($details -match [regex]::Escape($evidence))) { throw "$($case.Name): missing evidence '$evidence'." }
        }
    }
}
finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
}

$nativeAssignments = @($timeFunctions[0].Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$invokeW32tm'
        }, $true))
if ($nativeAssignments.Count -ne 1) { throw 'Expected one Windows Time native command capture block.' }
$nativeInvoker = Invoke-Expression $nativeAssignments[0].Right.Extent.Text
$originalNativePreference = $PSNativeCommandUseErrorActionPreference
try {
    # Exercise real native streams without querying or changing the host's clock.
    Set-Alias -Name w32tm.exe -Value $env:ComSpec
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($expectedExitCode in @(0, 37)) {
        $nativeOutput = @(& $nativeInvoker -Arguments @('/d', '/c',
                "echo memlabs-native-stdout & echo memlabs-native-stderr 1>&2 & exit /b $expectedExitCode") 2>&1)
        if ($nativeOutput.Count -ne 1 -or $nativeOutput[0].ExitCode -ne $expectedExitCode -or
            $nativeOutput[0].Text -notmatch 'memlabs-native-stdout' -or
            $nativeOutput[0].Text -notmatch 'memlabs-native-stderr') {
            throw "Native stdout/stderr or exit code leaked or was lost: $($nativeOutput | Out-String)"
        }
    }
}
finally {
    Remove-Item -LiteralPath 'Alias:\w32tm.exe' -ErrorAction Stop
    $PSNativeCommandUseErrorActionPreference = $originalNativePreference
}

Write-Host "PASS -- $($cases.Count) Phase 11 time-sync cases and 2 native-stream checks preserve diagnostics, verify bounded recovery, and retain warning-only failures."
