#requires -Version 5.1
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$failures = [Collections.Generic.List[string]]::new()
function Assert-Validation {
    param([bool] $Condition, [string] $Name)
    if ($Condition) {
        Write-Host "PASS  $Name"
    }
    else {
        Write-Host "FAIL  $Name"
        $failures.Add($Name)
    }
}

Push-Location $RootPath
try {
    . .\Common.ps1 -SkipMaintenanceRefresh -SkipEnvironmentDetection -SkipHostPreparation
    $userConfig = Get-UserConfiguration -Configuration 'Locale-CM-SqlAo-HighMemory.json'
    $result = Test-Configuration -InputObject $userConfig.Config

    $failureText = @($result.Failures | ForEach-Object {
            if ($_.Message) { [string]$_.Message } else { [string]$_ }
        }) -join ' | '
    Assert-Validation ($failureText -notmatch 'different networks|Both replicas must share one network') 'authoritative validation accepts split-network SQLAO'

    $sql1 = $result.DeployConfig.virtualMachines | Where-Object vmName -eq 'LH1-SQL1' | Select-Object -First 1
    $sql2 = $result.DeployConfig.virtualMachines | Where-Object vmName -eq 'LH1-SQL2' | Select-Object -First 1
    Assert-Validation ($null -ne $sql1) 'authoritative conversion emits LH1-SQL1'
    Assert-Validation ($null -ne $sql2) 'authoritative conversion emits LH1-SQL2'
    Assert-Validation ($sql1.thisParams.vmNetwork -eq '10.221.211.0') 'primary SQLAO node retains the default subnet'
    Assert-Validation ($sql2.thisParams.vmNetwork -eq '10.221.212.0') 'secondary SQLAO node retains its explicit subnet'
    Assert-Validation ($sql1.thisParams.vmNetwork -ne $sql2.thisParams.vmNetwork) 'authoritative conversion preserves distinct SQLAO networks'
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO multi-subnet validation check(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO multi-subnet authoritative validation checks passed.'
