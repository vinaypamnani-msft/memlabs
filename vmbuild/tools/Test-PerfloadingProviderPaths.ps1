<#
.SYNOPSIS
    Verifies that perfloading's OSD share probe is provider-safe.

.DESCRIPTION
    Extracts and executes the production probe with filesystem and status stubs.
    The success control proves a reachable qualified UNC does not produce a
    warning; the failure control proves a genuinely unreadable share still does.

    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:ProbeResult = $true
$script:Paths = New-Object System.Collections.Generic.List[string]
$script:Statuses = New-Object System.Collections.Generic.List[object]

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "$Path has $(@($errors).Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function Test-Path {
    param ([string] $LiteralPath, [string] $ErrorAction)

    $script:Paths.Add($LiteralPath)
    return $script:ProbeResult
}

function Write-DscStatus {
    param ([string] $Status, [switch] $Warning)

    $script:Statuses.Add([pscustomobject]@{ Status = $Status; Warning = [bool]$Warning })
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-PerfloadingOsdShareAccess')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$success = Test-PerfloadingOsdShareAccess -ComputerName 'SITE1' -ShareName 'OSD' -StatusTag '[perfloading]'
Assert-Equal $true $success 'qualified reachable share succeeds'
Assert-Equal 'FileSystem::\\SITE1\OSD' ($script:Paths -join ',') 'probe names the FileSystem provider'
Assert-Equal 0 @($script:Statuses | Where-Object Warning).Count 'reachable share emits no warning'
Assert-Equal $true ($script:Statuses[0].Status -like '*filesystem probe succeeded*') 'reachable share logs positive evidence'

$script:ProbeResult = $false
$script:Paths.Clear()
$script:Statuses.Clear()
$failure = Test-PerfloadingOsdShareAccess -ComputerName 'SITE1' -ShareName 'OSD' -StatusTag '[perfloading]'
Assert-Equal $false $failure 'qualified unreadable share fails'
Assert-Equal 'FileSystem::\\SITE1\OSD' ($script:Paths -join ',') 'failure probe still names the FileSystem provider'
Assert-Equal 1 @($script:Statuses | Where-Object Warning).Count 'unreadable share emits one warning'

$source = Get-Content -LiteralPath $perfloadingPath -Raw
Assert-Equal $false $source.Contains('$bareCanary') 'production script has no deliberate bare UNC probe'
Assert-Equal 1 ([regex]::Matches($source, 'Test-PerfloadingOsdShareAccess -ComputerName').Count) 'production script invokes the safe probe once'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All perfloading provider-path checks passed.'