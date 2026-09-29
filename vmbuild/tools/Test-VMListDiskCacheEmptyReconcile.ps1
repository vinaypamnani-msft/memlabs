<#
.SYNOPSIS
    Verifies that an empty live VM list cannot leave a stale disk cache behind.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Config.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Config.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$saveFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Save-VMListDiskCache'
        }, $true))
if ($saveFunctions.Count -ne 1) {
    throw "Expected one Save-VMListDiskCache function; found $($saveFunctions.Count)."
}
Invoke-Expression $saveFunctions[0].Extent.Text

$script:CacheLogs = [System.Collections.Generic.List[string]]::new()
function Write-Log {
    param([Parameter(Position = 0)] [string] $Message, [switch] $LogOnly)
    $script:CacheLogs.Add($Message)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-vm-cache-test-$([guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    $Common = [pscustomobject]@{ InJob = $false; CachePath = $tempRoot }
    $cachePath = Join-Path $tempRoot 'vm-list-cache.clixml'

    @([pscustomobject]@{ vmName = 'STALE-VM'; vmID = [guid]::NewGuid() }) |
        Export-Clixml -LiteralPath $cachePath -Force -Depth 10
    $global:vm_List = @()
    Save-VMListDiskCache

    if (Test-Path -LiteralPath $cachePath) {
        throw 'An empty reconciled VM list left the stale disk cache on disk.'
    }
    if (@($script:CacheLogs | Where-Object { $_ -like '*Removed disk cache because the live VM list is empty*' }).Count -ne 1) {
        throw 'Empty-cache removal was not logged.'
    }

    $script:CacheLogs.Clear()
    $global:vm_List = @([pscustomobject]@{ vmName = 'LIVE-VM'; vmID = [guid]::NewGuid() })
    Save-VMListDiskCache
    $cached = @(Import-Clixml -LiteralPath $cachePath)
    if ($cached.Count -ne 1 -or $cached[0].vmName -ne 'LIVE-VM') {
        throw 'A non-empty live VM list was not persisted normally.'
    }
}
finally {
    $global:vm_List = $null
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- empty reconciliation removes stale VM disk cache; non-empty save remains intact.'
