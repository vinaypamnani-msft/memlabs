<#
.SYNOPSIS
    Exercises bounded read-only replication SQL evidence and partial query failures.
#>
#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Get-ManagementPointDiagnostics.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$source parse errors: $($errors -join '; ')" }
$definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsReplicationSqlDiagnostics'
        }, $true))
if ($definitions.Count -ne 1) { throw 'Expected one replication SQL diagnostic function.' }
. ([scriptblock]::Create($definitions[0].Extent.Text))
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$state = [pscustomobject]@{
    ManyRows = $true; QueryFails = $false; OpenFails = $false
    Disposals = 0; Connections = [Collections.Generic.List[string]]::new()
    Commands = [Collections.Generic.List[object]]::new()
}
function Get-ItemProperty {
    param($LiteralPath, $ErrorAction)
    if ($LiteralPath -like '*Site System SQL Account') { return [pscustomobject]@{ Port = 51433 } }
    [pscustomobject]@{ Server = 'SQL_AO'; 'Database Name' = 'INSTANCE\CM_NOM' }
}
function Test-Path { param($LiteralPath, $ErrorAction) return $true }
function New-Object {
    param($TypeName, $ArgumentList)
    Assert-True ($TypeName -eq 'System.Data.SqlClient.SqlConnection' -and
        "$ArgumentList" -match 'Connect Timeout=10') 'SQL diagnostics lost their bounded connection.'
    $state.Connections.Add("$ArgumentList")
    $connection = [pscustomobject]@{}
    $connection | Add-Member ScriptMethod Open {
        if ($state.OpenFails) { throw 'fixture connection failure' }
    }
    $connection | Add-Member ScriptMethod Dispose { $state.Disposals++ }
    $connection | Add-Member ScriptMethod CreateCommand {
        $command = [pscustomobject]@{
            CommandText = ''; CommandTimeout = 0
            Parameters = [Data.SqlClient.SqlCommand]::new().Parameters
        }
        $command | Add-Member ScriptMethod Dispose { }
        $command | Add-Member ScriptMethod ExecuteReader {
            $state.Commands.Add($this)
            Assert-True ($this.CommandTimeout -eq 15 -and $this.CommandText -match '^SELECT TOP 201 ' -and
                $this.CommandText -notmatch '\b(UPDATE|DELETE|INSERT|EXEC)\b') 'A replication diagnostic query is unbounded or mutating.'
            Assert-True ($this.Parameters['@site'].Value -eq 'NOM' -and
                $this.Parameters['@group'].Value -eq '%Replication Configuration%') 'Diagnostic SQL parameters lost the measured site/group scope.'
            if ($state.QueryFails -and $this.CommandText -match 'RCM_DrsInitializationTracking') {
                throw 'fixture initialization query failure'
            }
            $table = [Data.DataTable]::new()
            $null = $table.Columns.Add('LogText', [string])
            $count = if ($state.ManyRows) { 201 } else { 1 }
            for ($index = 0; $index -lt $count; $index++) {
                $null = $table.Rows.Add([object[]]@("fixture SQL initialization reason $index"))
            }
            return ,($table.CreateDataReader())
        }
        return $command
    }
    return $connection
}

$snapshot = Get-MemLabsReplicationSqlDiagnostics -SiteCode NOM
Assert-True ($snapshot.DataSource -eq 'SQL_AO\INSTANCE,51433' -and
    $snapshot.Database -eq 'CM_NOM' -and $snapshot.SiteCode -eq 'NOM') 'SQLAO/named-instance/nondefault-port discovery changed.'
Assert-True ($snapshot.Sections.Count -eq 4 -and
    @($snapshot.Sections | Where-Object { $_.Rows.Count -ne 200 -or -not $_.Truncated }).Count -eq 0) 'The 200-row bound or explicit truncation flag is wrong.'
$logSection = $snapshot.Sections | Where-Object Name -eq 'InitializationErrors'
Assert-True ($logSection.Rows[0].LogText -match 'fixture SQL initialization reason') 'Stored-procedure failure text was not retained.'
Assert-True (@($state.Commands | Where-Object { $_.CommandText -match 'dbo.Logs' }).Count -eq 1) 'Diagnostics never queried the database Logs table.'

$state.ManyRows = $false
$state.QueryFails = $true
$snapshot = Get-MemLabsReplicationSqlDiagnostics -SiteCode NOM
$failed = $snapshot.Sections | Where-Object Name -eq 'Initialization'
$logs = $snapshot.Sections | Where-Object Name -eq 'InitializationErrors'
Assert-True ($failed.Error -match 'fixture initialization query failure' -and
    $logs.Rows.Count -eq 1 -and -not $logs.Error) 'A failed SQL section hid its error or suppressed independent SQL log evidence.'
$state.OpenFails = $true
$caught = $null
try { Get-MemLabsReplicationSqlDiagnostics -SiteCode NOM } catch { $caught = $_ }
Assert-True ($caught -and $caught.Exception.Message -match 'fixture connection failure' -and
    $state.Disposals -eq 3) 'A connection failure became success-shaped data or leaked the connection.'
$state.OpenFails = $false
$before = $state.Connections.Count
$caught = $null
try { Get-MemLabsReplicationSqlDiagnostics -SiteCode BAD } catch { $caught = $_ }
Assert-True ($caught -and $caught.Exception.Message -match 'does not match' -and
    $state.Connections.Count -eq $before) 'Mismatched site metadata connected to an unverified database.'

$calls = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-MemLabsReplicationSqlDiagnostics'
        }, $true))
Assert-True ($calls.Count -eq 1) 'The SQL diagnostic function is not wired into the site-server capture.'
$siteServerGuard = $false
for ($parent = $calls[0].Parent; $parent; $parent = $parent.Parent) {
    if ($parent -is [Management.Automation.Language.IfStatementAst] -and
        $parent.Clauses[0].Item1.Extent.Text -eq '$SiteServerOnly') { $siteServerGuard = $true }
}
Assert-True $siteServerGuard 'Ordinary MP probes unexpectedly query replication databases.'

Write-Host 'PASS -- replication SQL diagnostics are read-only, bounded, correctly targeted, and preserve partial failure evidence.'
