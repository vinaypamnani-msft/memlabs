<#
.SYNOPSIS
    Produces a compact timeline from Phase 8 host or client-package JSONL diagnostics.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]]$Path,

    [switch]$AsJson
)

begin {
    $records = [System.Collections.Generic.List[object]]::new()
}

process {
    foreach ($inputPath in $Path) {
        foreach ($file in @(Get-Item -Path $inputPath -ErrorAction Stop)) {
            $lineNumber = 0
            foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $record = $line | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    throw "Invalid JSON in '$($file.FullName)' at line $lineNumber`: $($_.Exception.Message)"
                }

                if ($record.PackageId) {
                    $summaries = @($record.Summarizer | ForEach-Object {
                            "$($_.Server)=$($_.StateName)(v$($_.SourceVersion))"
                        })
                    $targets = @($record.Targeting | ForEach-Object {
                            $targetState = [System.Collections.Generic.List[string]]::new()
                            if ($_.PSObject.Properties['StoredPkgVersion'] -and
                                -not [string]::IsNullOrWhiteSpace("$($_.StoredPkgVersion)")) {
                                $targetState.Add("stored:$($_.StoredPkgVersion)")
                            }
                            $targetState.Add("source:$($_.SourceVersion)")
                            $targetState.Add("refresh:$($_.RefreshNow)")
                            "$($_.Server)=$($targetState -join '/')"
                        })
                    $nodes = @($record.Nodes | ForEach-Object {
                            if ($_.Error) {
                                "$($_.DistributionPoint)=ERROR:$($_.Error)"
                            }
                            else {
                                $pkgFiles = @($_.State.PkgLibFiles)
                                "$($_.DistributionPoint)=PkgLib:$($pkgFiles.Count)/SMS_EXEC:$($_.State.SmsExecutive.State)"
                            }
                        })
                    $source = if ($record.SourceNode -and $record.SourceNode.Error) {
                        "$($record.SourceNode.Server)=ERROR:$($record.SourceNode.Error)"
                    }
                    elseif ($record.SourceNode) {
                        "$($record.SourceNode.Server)=stored:$($record.SourceNode.State.SiteProvider.StoredPkgVersion)/source:$($record.SourceNode.State.SiteProvider.SourceVersion)"
                    }
                    else { '' }
                    $records.Add([pscustomobject]@{
                            TimeUtc       = [datetime]::Parse(
                                "$($record.CapturedAtUtc)",
                                [Globalization.CultureInfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::RoundtripKind
                            ).ToUniversalTime()
                            Type          = 'ClientPackage'
                            Trigger       = "$($record.Trigger)"
                            Classification = "$($record.Classification)"
                            Site          = "$($record.SiteCode)"
                            Package       = "$($record.PackageId)"
                            PhaseElapsed  = $null
                            ActiveJobs    = $null
                            OldestHoldSec = $null
                            AvailableMB   = $null
                            CpuPercent    = $null
                            Source        = $source
                            Summary       = $summaries -join '; '
                            Targeting     = $targets -join '; '
                            Nodes         = $nodes -join '; '
                            Errors        = @($record.Errors) -join '; '
                            File          = $file.FullName
                            Line          = $lineNumber
                        })
                }
                else {
                    $activeJobs = @($record.Jobs | Where-Object { "$($_.State)" -notin @('Completed', 'Failed', 'Stopped') })
                    $oldest = $activeJobs | Sort-Object StatusHeldSec -Descending | Select-Object -First 1
                    $records.Add([pscustomobject]@{
                            TimeUtc       = [datetime]::Parse(
                                "$($record.CapturedAtUtc)",
                                [Globalization.CultureInfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::RoundtripKind
                            ).ToUniversalTime()
                            Type          = 'Phase8'
                            Trigger       = "$($record.Trigger)"
                            Classification = ''
                            Site          = ''
                            Package       = ''
                            PhaseElapsed  = $record.PhaseElapsedSeconds
                            ActiveJobs    = $activeJobs.Count
                            OldestHoldSec = if ($oldest) { $oldest.StatusHeldSec } else { $null }
                            AvailableMB   = if ($record.Host -and $record.Host.Memory) { $record.Host.Memory.AvailableMB } else { $null }
                            CpuPercent    = if ($record.Host) { $record.Host.CpuLoadPercent } else { $null }
                            Source        = ''
                            Summary       = @($activeJobs | ForEach-Object {
                                    "$($_.VMName)[$($_.Role)] $($_.Activity): $($_.Status) (held $($_.StatusHeldSec)s)"
                                }) -join '; '
                            Targeting     = ''
                            Nodes         = ''
                            Errors        = ''
                            File          = $file.FullName
                            Line          = $lineNumber
                        })
                }
            }
        }
    }
}

end {
    $ordered = @($records | Sort-Object TimeUtc, File, Line)
    if ($AsJson) {
        $ordered | ConvertTo-Json -Depth 8
    }
    else {
        $ordered
    }
}
