#Start-Test.ps1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Prefix of tests to perform", ParameterSetName = 'TestName')]
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

            if ($WordToComplete) { $Tests = $Tests | Where-Object { $_.ToLowerInvariant().StartsWith($WordToComplete.ToLowerInvariant()) } }
            return [string[]] $Tests
        })]   
    [string]$Test,

    [Parameter(Mandatory = $true, HelpMessage = "Prefix of tests to perform", ParameterSetName = 'ALL')]
    [switch]$All,

    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "CMVersion", ParameterSetName = 'TestName')]
    [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false -InJob:$true
            $argument = @(Get-CMVersions)
            return $argument | Where-Object { $_ -match $WordToComplete }
        })]        
    [string]$cmVersion,

    [Parameter(Mandatory = $false, HelpMessage = "Override Dynamic Memory", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Dynamic Memory", ParameterSetName = 'TestName')]
    [switch]$dynamicMemory,

    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'ALL')]
    [Parameter(Mandatory = $false, HelpMessage = "Override Server Version", ParameterSetName = 'TestName')]
    [ArgumentCompleter({
            param ($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)
            . $PSScriptRoot\Common.ps1 -VerboseEnabled:$false -InJob:$true
            $argument = @(Get-SupportedOperatingSystemsForRole "DC")
            $newArgument = @()
            foreach ($arg in $argument) {
                if ($arg -like "* *") {
                    $newArgument += "'$arg'"
                }
                else {
                    $newArgument += $arg
                }
            }
            return $newArgument | Where-Object { $_ -match $WordToComplete }
        })]        
    [string]$serverVersion
)


function Run-Test {
    param(
        [string]$Test
    )
    Write-Host "Starting all tests for $Test"
    $Test = $Test.ToLowerInvariant()
    $Tests = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name } | Where-Object { $_.Name.ToLowerInvariant().StartsWith($Test) }

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
        if ($serverVersion) {
            foreach ($vm in $config.virtualMachines) {
                if ($vm.operatingSystem -like "*server*") {
                    $vm.operatingSystem = $serverVersion
                }
            }    
        }
        $domainName = $config.vmOptions.domainName
        $global:removedomains += $domainName
        $global:removedomains = @($global:removedomains | Select-Object -Unique)

        $config | ConvertTo-Json -Depth 5 | Out-File $ModifiedtestFile -Force
        Write-Host "Starting test for $testjson"
        try {
            & ./New-Lab.ps1 -Configuration $ModifiedtestFile -NoSnapshot
            if ($LASTEXITCODE -eq 55) {
                & ./New-Lab.ps1 -Configuration $ModifiedtestFile -NoSnapshot
            }
            Write-Host "$LASTEXITCODE was returned from $testjson"
            if ($LASTEXITCODE -ne 0) {
                return $false
            }            
        }
        finally {
            if ($LASTEXITCODE -ne 0) {
                write-host "$testjson Failed"
                $global:history += "$testjson Failed"
                Write-Host "Failed to create lab for $testjson copied to $ModifiedtestFile"
            
            }   
            else {
                write-host "$testjson Completed Successfully"
                $global:history += "$testjson Completed Successfully"
            }
        
        }
    }
    
    [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory("./Remove-lab.ps1 -DomainName $domainName")
    return $true
}

. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

try {
    $global:history = @()
    $global:removedomains = @()
    if ($test) {
        $result = Run-Test -Test $Test
    }

    if ($all) {
        $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name }
        $Tests = @()
        foreach ($name in $ConfigPaths.Name) {
     
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

        foreach ($Test in $Tests) {
            if (Get-Content "c:\temp\CompletedTests.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -eq $Test }) {
                write-host "$Test already ran skipping"
                continue
            }
            $result = Run-Test -Test $Test
            Write-Host "$Test returned $result"
            if (-not $result) {
                break
            }
            if ($global:removedomains.Count -gt 0) {
                foreach ($domain in $global:removedomains) {
                    ./Remove-lab.ps1 -DomainName $domain
                    $global:history += "$domain Removed"
                }
                $global:removedomains = @()
            }
            $Test | Out-File "c:\temp\CompletedTests.txt" -Force -Append
        }
    }
}
finally {
    Write-Host
    Write-Host "History of tests ran"
    Write-Host "----------------------"
    foreach ($historyitem in $global:history) {
        if ($historyitem -like "*Failed*") {
            Write-RedX $historyitem 
        }
        else {
            Write-GreenCheck $historyitem
        }
    }
}