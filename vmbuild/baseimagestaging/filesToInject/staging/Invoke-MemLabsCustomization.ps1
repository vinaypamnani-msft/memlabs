<#
.SYNOPSIS
    Runs portable MemLabs guest customizations from C:\staging.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DefenderTuning', 'WindowsMachine', 'WindowsUserRegistration', 'WindowsUser')]
    [string[]]$Name,
    [string]$RootPath = $PSScriptRoot,
    [switch]$ContinueOnError
)

$definitions = @{
    DefenderTuning = @{
        Script = 'Optimize-Defender.ps1'
        Args   = @{}
    }
    WindowsMachine = @{
        Script = 'Set-MemLabsMachineSettings.ps1'
        Args   = @{}
    }
    WindowsUserRegistration = @{
        Script = 'Set-MemLabsUserShell.ps1'
        Args   = @{ Register = $true }
    }
    WindowsUser = @{
        Script = 'Set-MemLabsUserShell.ps1'
        Args   = @{ Apply = $true }
    }
}

$results = @()
foreach ($customizationName in $Name) {
    $definition = $definitions[$customizationName]
    $scriptPath = Join-Path $RootPath $definition.Script
    try {
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Required customization script is missing: $scriptPath"
        }
        $scriptText = [IO.File]::ReadAllText($scriptPath).TrimStart([char]0xFEFF)
        $scriptBlock = [scriptblock]::Create($scriptText)
        $invokeArgs = $definition.Args
        $result = & $scriptBlock @invokeArgs
        $structured = @($result | Where-Object {
                $_ -and $_.PSObject.Properties.Name -contains 'Success'
            } | Select-Object -Last 1)
        if ($structured.Count -ne 1) {
            throw "Customization '$customizationName' returned no structured result."
        }
        $results += [pscustomobject]@{
            Name    = $customizationName
            Success = [bool]$structured[0].Success
            Message = "$($structured[0].Message)"
            Errors  = @($structured[0].Errors)
            Blocked = @($structured[0].Blocked)
        }
    }
    catch {
        $results += [pscustomobject]@{
            Name    = $customizationName
            Success = $false
            Message = "Customization '$customizationName' failed."
            Errors  = @($_.Exception.Message)
            Blocked = @()
        }
    }

    if (-not $results[-1].Success -and -not $ContinueOnError) { break }
}

$failed = @($results | Where-Object { -not $_.Success })
[pscustomobject]@{
    Success = $failed.Count -eq 0
    Message = if ($failed.Count -eq 0) {
        "Applied $($results.Count) customization(s): $($results.Name -join ', ')"
    }
    else {
        "$($failed.Count) customization(s) failed: $($failed.Name -join ', ')"
    }
    Errors  = @($failed | ForEach-Object { $_.Errors })
    Blocked = @($results | ForEach-Object { $_.Blocked })
    Results = $results
}