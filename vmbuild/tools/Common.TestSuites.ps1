function Get-MemLabsOrdinaryTestFamilies {
    param([Parameter(Mandatory = $true)][string] $VmbuildRoot)

    $testsPath = Join-Path $VmbuildRoot 'config\tests'
    @(
        Get-ChildItem -LiteralPath $testsPath -Filter '*.json' -File |
            ForEach-Object { ($_.Name -split '-')[0] } |
            Where-Object { $_ -and $_ -notlike '*storageconfig*' } |
            Select-Object -Unique |
            Sort-Object
    )
}

function Resolve-MemLabsTestSuite {
    param(
        [Parameter(Mandatory = $true)][string] $VmbuildRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $suitePath = Join-Path $VmbuildRoot 'tools\test-suites.json'
    if (-not (Test-Path -LiteralPath $suitePath -PathType Leaf)) {
        throw "Test suite manifest not found: $suitePath"
    }
    $manifest = Get-Content -LiteralPath $suitePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported test suite schema version '$($manifest.schemaVersion)'."
    }
    $suiteProperty = $manifest.suites.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $suiteProperty) {
        $available = @($manifest.suites.PSObject.Properties.Name) -join ', '
        throw "Unknown test suite '$Name'. Available suites: $available."
    }

    $allFamilies = @(Get-MemLabsOrdinaryTestFamilies -VmbuildRoot $VmbuildRoot)
    $suite = $suiteProperty.Value
    $families = if ($suite.includeAll -eq $true) {
        @($allFamilies)
    }
    else {
        @($suite.families)
    }
    $families = @($families | Where-Object { $_ } | Select-Object -Unique)
    $missing = @($families | Where-Object { $_ -notin $allFamilies })
    if ($missing.Count -gt 0) {
        throw "Test suite '$($suiteProperty.Name)' references missing family/families: $($missing -join ', ')."
    }
    [pscustomobject]@{
        Name        = $suiteProperty.Name
        Mode        = "$($suite.mode)"
        Description = "$($suite.description)"
        IncludeAll  = [bool]$suite.includeAll
        Families    = @($families)
    }
}
