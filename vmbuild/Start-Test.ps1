#Start-Test.ps1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "TestName")]
    [ArgumentCompleter( {
            param ( $CommandName,
                $ParameterName,
                $WordToComplete,
                $CommandAst,
                $FakeBoundParameters
            )

            $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name }
            $Tests = @()
            foreach ($name  in $ConfigPaths.Name) {
             
            $Testname = ($name -split "-")[0]
            if ($Testname.contains("json")) {
                continue
            }
            if ($Testname.Contains("storageconfig")) {
                continue
            }
            $Tests += $Testname
            }                        
            $Tests = $Tests | Select-Object -Unique

            if ($WordToComplete) { $Tests = $Tests | Where-Object { $_.ToLowerInvariant().StartsWith($WordToComplete) } }
            return [string[]] $Tests
        })]   
        [string]$Test,
        [Parameter(Mandatory = $false, HelpMessage = "CMVersion")]
        [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false -InJob:$true
            $argument = @(Get-CMVersions)
            return $argument | Where-Object {$_ -match $WordToComplete}
        })]
        [string]$cmVersion,
        [switch]$dynamicMemory
)
Write-Host "Starting all tests for $Test"
$Test = $Test.ToLowerInvariant()
$Tests = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name } | Where-Object {$_.Name.ToLowerInvariant().StartsWith($Test)}
$history = @()
foreach ($testjson in $Tests) {
    $outputFile = Split-Path $testjson -leaf
    $ModifiedtestFile = (Join-Path "c:\temp" $outputFile)
    $config = Get-Content $testjson -Force | ConvertFrom-Json
    if ($cmVersion) {
        if ($config.cmOptions.version -ne $cmVersion) {
            $config.cmOptions.version = $cmVersion
            write-host "updating cmVersion to $cmVersion"
        }        
    }
    if ($dynamicMemory) {
        foreach ($vm in $config.virtualMachines) {
            $vm | Add-Member -MemberType NoteProperty -Name "dynamicMinRam" -Value "1GB" -Force
        }       
    }
    $domainName = $config.vmOptions.domainName
    $config | ConvertTo-Json -Depth 5 | Out-File $ModifiedtestFile -Force
    Write-Host "Starting test for $testjson"
    ./New-Lab.ps1 -Configuration $ModifiedtestFile
    if ($LASTEXITCODE -eq 55) {
        ./New-Lab.ps1 -Configuration $ModifiedtestFile
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to create lab for $testjson copied to $ModifiedtestFile"
        exit 1
    }   
    $history += "$testjson Completed Successfully"
}

foreach ($historyitem in $history) {
    Write-Host $historyitem
}
[Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory("./Remove-lab.ps1 -DomainName $domainName")
