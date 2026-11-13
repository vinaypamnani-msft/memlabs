#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'DSC\phases\ScriptFunctions.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-MemLabsDrsGroupSend'
})
Assert-True ($definition.Count -eq 1) 'Expected one shared DRS send helper.'
. ([scriptblock]::Create($definition[0].Extent.Text))
$script:Fixture = $null
function New-Object {
    param($TypeName, $ArgumentList)
    Assert-True ($TypeName -eq 'System.Data.SqlClient.SqlConnection') 'The send created an unexpected SQL object.'
    $parsed = [System.Data.SqlClient.SqlConnectionStringBuilder]::new("$ArgumentList")
    Assert-True ($parsed['Data Source'] -eq 'SQL-LISTENER,1435' -and $parsed['Initial Catalog'] -eq 'CM_PS1' -and
        $parsed['Integrated Security'] -and $parsed['Connect Timeout'] -eq 20) 'The send lost its resolved SQL target or connection deadline.'
    $attempt = $script:Fixture.Connections++
    $parameters = [pscustomobject]@{}
    $parameters | Add-Member ScriptMethod AddWithValue {
        param($Name, $Value)
        $script:Fixture.Parameters.Add("$Name=$Value")
        return 42
    }
    $command = [pscustomobject]@{ Attempt = $attempt; CommandText = ''; CommandTimeout = 0; Parameters = $parameters }
    $command | Add-Member ScriptMethod ExecuteNonQuery {
        Assert-True ($this.CommandText -eq 'EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup = @rg' -and
            $this.CommandTimeout -eq 120) 'The send lost its parameterized command or timeout.'
        $script:Fixture.Sends++
        if ($this.Attempt -lt $script:Fixture.Errors.Count -and $script:Fixture.Errors[$this.Attempt]) {
            throw $script:Fixture.Errors[$this.Attempt]
        }
        return 7
    }
    $command | Add-Member ScriptMethod Dispose { $script:Fixture.CommandsDisposed++ }
    $connection = [pscustomobject]@{ Command = $command }
    $connection | Add-Member ScriptMethod Open {
        if ($script:Fixture.OpenFails) { throw 'Login failed for the test identity.' }
    }
    $connection | Add-Member ScriptMethod CreateCommand { return $this.Command }
    $connection | Add-Member ScriptMethod Dispose { $script:Fixture.ConnectionsDisposed++ }
    return $connection
}
function Write-DscStatus {
    param($Message, [switch]$Warning)
    $script:Fixture.Messages.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}
function Start-Sleep {
    param($Seconds)
    $script:Fixture.Sleeps.Add([int]$Seconds)
}
function Invoke-SendFixture {
    param([object[]]$Errors = @(), [switch]$OpenFails)
    $script:Fixture = [pscustomobject]@{
        Errors = $Errors; OpenFails = $OpenFails.IsPresent; Connections = 0; Sends = 0
        CommandsDisposed = 0; ConnectionsDisposed = 0
        Messages = [Collections.Generic.List[object]]::new()
        Parameters = [Collections.Generic.List[string]]::new()
        Sleeps = [Collections.Generic.List[int]]::new()
    }
    $result = @(Invoke-MemLabsDrsGroupSend -SqlServer 'SQL-LISTENER,1435' -DatabaseName 'CM_PS1' `
        -ReplicationGroup 'Configuration Data' -StatusTag 'Client pkg coverage: [drs-push]')
    Assert-True ($result.Count -eq 1 -and $result[0] -is [bool]) 'Logging or SQL results polluted the boolean return.'
    [pscustomobject]@{ Success = $result[0]; Fixture = $script:Fixture }
}
$snapshot = [Exception]::new('ERROR 3961, Level 16, State 1: Snapshot isolation transaction failed because metadata changed.')
$wrapped = [Reflection.TargetInvocationException]::new('SQL wrapper failed.', $snapshot)
$deadlock = [Exception]::new('SQLStatus 1205: transaction was deadlocked.')
$healthy = Invoke-SendFixture
Assert-True ($healthy.Success -and $healthy.Fixture.Connections -eq 1 -and $healthy.Fixture.Sleeps.Count -eq 0) 'A healthy nudge retried unnecessarily.'
Assert-True ($healthy.Fixture.CommandsDisposed -eq 1 -and $healthy.Fixture.ConnectionsDisposed -eq 1) 'Successful SQL resources were not disposed.'

$recovered = Invoke-SendFixture -Errors @($wrapped, $deadlock, $null)
Assert-True ($recovered.Success -and $recovered.Fixture.Connections -eq 3 -and $recovered.Fixture.Sends -eq 3) 'Wrapped snapshot/deadlock failures did not retry with fresh connections.'
Assert-True ($recovered.Fixture.CommandsDisposed -eq 3 -and $recovered.Fixture.ConnectionsDisposed -eq 3) 'Failed SQL attempts retained resources.'
Assert-True ($recovered.Fixture.Sleeps.Count -eq 2 -and @($recovered.Fixture.Sleeps | Where-Object { $_ -ne 5 }).Count -eq 0) 'Retry backoff is not exactly two five-second delays.'
Assert-True (@($recovered.Fixture.Messages | Where-Object Warning).Count -eq 2) 'A failed DRS attempt was hidden as INFO.'
Assert-True (($recovered.Fixture.Messages.Message -join ' ') -match 'attempt 3/3') 'Recovery lost its attempt evidence.'
Assert-True (@($recovered.Fixture.Parameters | Where-Object { $_ -ne '@rg=Configuration Data' }).Count -eq 0) 'Retries changed replication scope.'

foreach ($number in @(1222, 3960, 3961)) {
    $transientFailure = [Exception]::new("ERROR $number, Level 16: transient SQL conflict.")
    $recovery = Invoke-SendFixture -Errors @($transientFailure, $null)
    Assert-True ($recovery.Success -and $recovery.Fixture.Connections -eq 2) "Transient SQL error $number was not recognized."
}
$exhausted = Invoke-SendFixture -Errors @($snapshot, $snapshot, $snapshot)
Assert-True (-not $exhausted.Success -and $exhausted.Fixture.Connections -eq 3 -and $exhausted.Fixture.Sleeps.Count -eq 2) 'Exhausted sends escaped the retry limit or slept after the last attempt.'
Assert-True (@($exhausted.Fixture.Messages | Where-Object Warning).Count -eq 3 -and
    ($exhausted.Fixture.Messages.Message -join ' ') -match 'Normal DRS scheduling.+remain authoritative') 'Exhaustion lost its warning or scheduler/coverage fallback.'
$permanent = Invoke-SendFixture -Errors @([Exception]::new('Object 3961 does not exist; SQL error 208.'))
Assert-True (-not $permanent.Success -and $permanent.Fixture.Connections -eq 1 -and $permanent.Fixture.Sleeps.Count -eq 0) 'An unrelated number or permanent SQL failure was retried.'
$login = Invoke-SendFixture -OpenFails
Assert-True (-not $login.Success -and $login.Fixture.Connections -eq 1 -and $login.Fixture.ConnectionsDisposed -eq 1) 'Login failure was retried or leaked its connection.'
$before = $script:Fixture.Connections
$invalid = Invoke-MemLabsDrsGroupSend -SqlServer ' ' -DatabaseName 'CM_PS1' `
    -ReplicationGroup 'Configuration Data' -StatusTag 'Client pkg coverage: [drs-push]'
Assert-True (-not $invalid -and $script:Fixture.Connections -eq $before -and
    ($script:Fixture.Messages.Message -join ' ') -match 'could not initialize its SQL target') 'An invalid SQL target was silently ignored or opened a connection.'

foreach ($file in @('InstallBoundaryGroups.ps1', 'InstallDPMPClient.ps1')) {
    $source = Get-Content -LiteralPath (Join-Path $root "DSC\phases\$file") -Raw
    Assert-True ($source.Contains('Invoke-MemLabsDrsGroupSend -SqlServer')) "$file does not use the shared nudge helper."
}
Write-Host 'PASS -- bounded DRS retry, wrapped SQL conflicts, warning visibility, resource cleanup, and both client-package nudge paths.'
