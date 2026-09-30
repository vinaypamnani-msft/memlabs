#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-AlwaysOnHealth {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

function Get-DscScriptProperty {
    param(
        [Management.Automation.Language.DynamicKeywordStatementAst]$Resource,
        [string]$PropertyName
    )
    $resourceHashtable = @($Resource.FindAll({
                param($node)
                $node -is [Management.Automation.Language.HashtableAst]
            }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)[0]
    $pair = @($resourceHashtable.KeyValuePairs | Where-Object { $_.Item1.Value -eq $PropertyName })
    if ($pair.Count -ne 1) { throw "Expected one $PropertyName property, found $($pair.Count)" }
    $expression = @($pair[0].Item2.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true) | Sort-Object { $_.Extent.Text.Length } -Descending)[0]
    $text = $expression.ScriptBlock.Extent.Text.Trim()
    $body = $text.Substring(1, $text.Length - 2)
    $body = $body.Replace('$using:_alwaysOnHealthTarget', '$script:SqlTarget')
    return [scriptblock]::Create($body)
}

$phase5Path = Join-Path $RootPath 'DSC\phases\Phase5.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($phase5Path, [ref]$tokens, [ref]$errors)
$parseErrors = @($errors | Where-Object {
        $_.ErrorId -notin 'ModuleNotFoundDuringParse', 'MultipleModuleEntriesFoundDuringParse'
    })
if ($parseErrors.Count -ne 0) { throw "$phase5Path has parse errors: $($parseErrors.Message -join '; ')" }

$resources = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.DynamicKeywordStatementAst] -and
            $node.Extent.Text -match '^\s*Script\s+EnsureAlwaysOnHealth\s*\{'
        }, $true))
Assert-AlwaysOnHealth ($resources.Count -eq 2) 'Phase 5 contains two AlwaysOn_health resources'
if ($resources.Count -ne 2) { throw 'Cannot execute AlwaysOn_health behavior tests without both resources.' }

$getScript = Get-DscScriptProperty -Resource $resources[0] -PropertyName GetScript
$testScript = Get-DscScriptProperty -Resource $resources[0] -PropertyName TestScript
$setScript = Get-DscScriptProperty -Resource $resources[0] -PropertyName SetScript
$secondaryGetScript = Get-DscScriptProperty -Resource $resources[1] -PropertyName GetScript
$secondaryTestScript = Get-DscScriptProperty -Resource $resources[1] -PropertyName TestScript
$secondarySetScript = Get-DscScriptProperty -Resource $resources[1] -PropertyName SetScript
Assert-AlwaysOnHealth ($getScript.ToString() -eq $secondaryGetScript.ToString() -and
    $testScript.ToString() -eq $secondaryTestScript.ToString() -and
    $setScript.ToString() -eq $secondarySetScript.ToString()) 'both SQLAO nodes use identical AlwaysOn_health resource logic'

$script:SqlTarget = 'localhost'
$script:XeState = $null
$script:FakeCommand = $null
$script:RequiredReadPatterns = @(
    'sys\.server_event_sessions',
    'configured\.startup_state\s*=\s*1',
    'sys\.dm_xe_sessions',
    'running\.name\s*=\s*configured\.name'
)
$script:RequiredWritePatterns = @(
    "IF NOT EXISTS \(SELECT 1 FROM sys\.server_event_sessions WHERE name = N'AlwaysOn_health'\)",
    'THROW 51000',
    'WITH \(STARTUP_STATE = ON\)',
    "IF NOT EXISTS \(SELECT 1 FROM sys\.dm_xe_sessions WHERE name = N'AlwaysOn_health'\)",
    'STATE = START'
)

function New-XeState {
    param(
        [bool]$Configured,
        [bool]$Startup,
        [bool]$Running,
        [bool]$OpenThrows = $false
    )
    return [pscustomobject]@{
        Configured = $Configured
        Startup = $Startup
        Running = $Running
        OpenThrows = $OpenThrows
        OpenCalls = 0
        ScalarCalls = 0
        NonQueryCalls = 0
        DisposeCalls = 0
        ReadSql = [Collections.Generic.List[string]]::new()
        WriteSql = [Collections.Generic.List[string]]::new()
    }
}

function New-FakeSqlConnection {
    $command = [pscustomobject]@{ CommandTimeout = 0; CommandText = '' }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteScalar -Value {
        $script:XeState.ScalarCalls++
        $script:XeState.ReadSql.Add([string]$this.CommandText)
        foreach ($pattern in $script:RequiredReadPatterns) {
            if ($this.CommandText -notmatch $pattern) {
                throw "Read query is missing required clause '$pattern'."
            }
        }
        if ($script:XeState.Configured -and $script:XeState.Startup -and $script:XeState.Running) { return 1 }
        return 0
    }
    $command | Add-Member -MemberType ScriptMethod -Name ExecuteNonQuery -Value {
        $script:XeState.NonQueryCalls++
        $script:XeState.WriteSql.Add([string]$this.CommandText)
        foreach ($pattern in $script:RequiredWritePatterns) {
            if ($this.CommandText -notmatch $pattern) {
                throw "Write query is missing required clause '$pattern'."
            }
        }
        if (-not $script:XeState.Configured) {
            throw 'AlwaysOn_health extended-event session is not defined.'
        }
        if ($this.CommandText -match 'WITH \(STARTUP_STATE = ON\)') {
            $script:XeState.Startup = $true
        }
        if (-not $script:XeState.Running -and $this.CommandText -match 'STATE = START') {
            $script:XeState.Running = $true
        }
        return -1
    }
    $script:FakeCommand = $command

    $connection = [pscustomobject]@{}
    $connection | Add-Member -MemberType ScriptMethod -Name Open -Value {
        $script:XeState.OpenCalls++
        if ($script:XeState.OpenThrows) { throw 'injected SQL connection failure' }
    }
    $connection | Add-Member -MemberType ScriptMethod -Name CreateCommand -Value { return $script:FakeCommand }
    $connection | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:XeState.DisposeCalls++ }
    return $connection
}

function New-Object {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$TypeName,
        [Parameter(Position = 1)]$ArgumentList
    )
    if ([string]$TypeName -eq 'System.Data.SqlClient.SqlConnection') {
        return New-FakeSqlConnection
    }
    throw "Unexpected New-Object request for '$TypeName'."
}

try {
    $script:XeState = New-XeState -Configured $true -Startup $false -Running $false
    $instrumentConnection = New-FakeSqlConnection
    $instrumentCommand = $instrumentConnection.CreateCommand()
    $instrumentCommand.CommandText = 'SELECT COUNT(*) FROM sys.server_event_sessions'
    $badReadRejected = $false
    try { $null = $instrumentCommand.ExecuteScalar() } catch { $badReadRejected = $_.Exception.Message -match 'missing required clause' }
    Assert-AlwaysOnHealth $badReadRejected 'fake SQL reader rejects planted query-clause removal'
    $instrumentCommand.CommandText = 'ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;'
    $badWriteRejected = $false
    try { $null = $instrumentCommand.ExecuteNonQuery() } catch { $badWriteRejected = $_.Exception.Message -match 'missing required clause' }
    Assert-AlwaysOnHealth $badWriteRejected 'fake SQL writer rejects planted convergence-clause removal'

    $script:XeState = New-XeState -Configured $true -Startup $true -Running $true
    $getResult = & $getScript
    Assert-AlwaysOnHealth ($getResult.Result -eq 1 -and $script:XeState.DisposeCalls -eq 1 -and
        $script:XeState.ReadSql.Count -eq 1) 'GetScript executes the shipped read query and disposes compliant state'
    Assert-AlwaysOnHealth (& $testScript) 'TestScript accepts configured startup and running state'

    foreach ($state in @(
            (New-XeState -Configured $true -Startup $false -Running $false),
            (New-XeState -Configured $true -Startup $false -Running $true),
            (New-XeState -Configured $true -Startup $true -Running $false)
        )) {
        $script:XeState = $state
        Assert-AlwaysOnHealth (-not (& $testScript)) 'TestScript rejects an incomplete AlwaysOn_health state'
        & $setScript
        Assert-AlwaysOnHealth ($state.Startup -and $state.Running -and
            $state.NonQueryCalls -eq 1 -and $state.WriteSql.Count -eq 1 -and
            $state.DisposeCalls -eq 2) 'SetScript executes shipped convergence SQL and disposes every connection'
        Assert-AlwaysOnHealth (& $testScript) 'converged AlwaysOn_health state passes the next idempotent evaluation'
    }

    $script:XeState = New-XeState -Configured $false -Startup $false -Running $false
    Assert-AlwaysOnHealth (-not (& $testScript)) 'TestScript rejects an absent session'
    $missingThrows = $false
    try { & $setScript } catch { $missingThrows = $_.Exception.Message -match 'not defined' }
    Assert-AlwaysOnHealth ($missingThrows -and $script:XeState.DisposeCalls -eq 2) 'SetScript surfaces an absent built-in session and disposes the connection'

    $script:XeState = New-XeState -Configured $true -Startup $true -Running $true -OpenThrows $true
    Assert-AlwaysOnHealth (-not (& $testScript)) 'TestScript treats SQL connection failure as noncompliant'
    Assert-AlwaysOnHealth ($script:XeState.DisposeCalls -eq 1) 'TestScript disposes after SQL connection failure'
    $setThrows = $false
    try { & $setScript } catch { $setThrows = $_.Exception.Message -match 'injected SQL connection failure' }
    Assert-AlwaysOnHealth ($setThrows -and $script:XeState.DisposeCalls -eq 2) 'SetScript propagates connection failure and disposes'
}
finally {
    Remove-Item -LiteralPath Function:\New-Object -Force
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) AlwaysOn_health assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO AlwaysOn_health tests passed.'
