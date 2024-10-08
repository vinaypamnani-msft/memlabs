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
        [string]$Test
)
Write-Host "Starting all tests for $Test"
$Test = $Test.ToLowerInvariant()
$Tests = Get-ChildItem -Path "$PSScriptRoot\config\tests" -Filter *.json | Sort-Object -Property { $_.Name } | Where-Object {$_.Name.ToLowerInvariant().StartsWith($Test)}

foreach ($testjson in $Tests) {
    ./New-Lab.ps1 -Configuration $testjson
}
