<#
.SYNOPSIS
    Flag a dropped `$` -- `$(vm.vmName)` parses as a CALL to a command named vm.vmName,
    not as a property read, and says nothing when it fails.

.DESCRIPTION
    Leaving the `$` off a property access does not produce a syntax error. PowerShell
    parses the bareword in command position:

        Write-RedX "Could not acquire mutex for $(vm.vmName)."

    At run time that looks for a command literally named `vm.vmName`, throws
    CommandNotFoundException, and under default preferences the error is written to the
    error stream and discarded -- the string simply renders with a blank where the value
    should be. Neither the parser nor PSScriptAnalyzer reports it.

    Both instances found in this repo sat in ERROR paths, which is why they survived for
    so long: the line only runs when something has already gone wrong, and then it quietly
    says less than it was written to say. In each case a correct sibling was within three
    lines (`$($vm.vmName)`), so the intent was never in doubt.

    Same family as Test-BarewordAssignment.ps1 (`x = 1` is a command call too).

    Only a name shaped identifier.identifier is reported. Names that are genuinely
    invoked that way -- setup.exe, .\deploy.ps1, foo.cmd -- are excluded, and a dotted
    ARGUMENT (Get-Item report.txt) is not a command name and never matches.

.PARAMETER Path
    File or directory to scan. Defaults to the vmbuild tree.

.PARAMETER Quiet
    Suppress the "Scanned N source(s)" banner.

.PARAMETER SelfTest
    Run against a built-in fixture with known answers and exit non-zero if the detector
    misses a planted defect or invents one. Validates the instrument.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path = (Split-Path $PSScriptRoot -Parent),

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$SelfTest
)

# Extensions that are legitimately run by a dotted name.
$runnable = '\.(exe|ps1|psm1|cmd|bat|com|msi|msc|vbs|js|py|sql|dll|lnk|url)$'

$sources = @()
if ($SelfTest.IsPresent) {
    $fixture = @'
$vm = Get-VM
$ok1 = "$($vm.vmName)"
$bad1 = "$(vm.vmName)"
Write-Log "$(thisVM.vmName) contains invalid data"
& setup.exe /silent
.\deploy.ps1 -Force
$ok2 = $vm.Name.Length
notepad.exe
Get-Item report.txt
foo.bar
'@
    $fixtureAst = [System.Management.Automation.Language.Parser]::ParseInput($fixture, [ref]$null, [ref]$null)
    $sources = @([pscustomobject]@{ Name = '<self-test>'; Ast = $fixtureAst })
}
else {
    $target = Get-Item -LiteralPath $Path -ErrorAction Stop
    $files = if ($target.PSIsContainer) {
        # Anchored to the scan root on purpose: an unanchored '\temp\' also matches
        # C:\Users\<u>\AppData\Local\Temp, which silently excludes every file when a
        # baseline is extracted there to test this gate.
        $root = $target.FullName.TrimEnd('\')
        @(Get-ChildItem $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Substring($root.Length).TrimStart('\') -notmatch '^(logs|logs2|azureFiles|temp)\\' })
    }
    else {
        @($target)
    }
    foreach ($file in $files) {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { continue }
        $sources += [pscustomobject]@{ Name = $file.FullName; Ast = $ast }
    }
    # A scan of nothing is not a clean bill of health.
    if ($sources.Count -eq 0) {
        Write-Host "ERROR: no parsable PowerShell found under '$Path' -- NOTHING WAS SCANNED." -ForegroundColor Red
        exit 1
    }
}

$findings = @()
foreach ($source in $sources) {
    foreach ($cmd in $source.Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $cmd.GetCommandName()
        if (-not $name) { continue }
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$') { continue }
        if ($name -match $runnable) { continue }
        $findings += [pscustomobject]@{
            Source = $source.Name
            Line   = $cmd.Extent.StartLineNumber
            Name   = $name
            Text   = ($cmd.Extent.Text -split "`n")[0].Trim()
        }
    }
}

if (-not $Quiet) {
    Write-Host "Scanned $($sources.Count) source(s) for dropped-`$ property accesses."
}

if ($SelfTest.IsPresent) {
    $expectedLines = @(3, 4, 10)
    $gotLines = @($findings | ForEach-Object { $_.Line } | Sort-Object)
    $missed = @($expectedLines | Where-Object { $gotLines -notcontains $_ })
    $extra = @($gotLines | Where-Object { $expectedLines -notcontains $_ })
    if ($missed.Count -or $extra.Count) {
        Write-Host "SELF-TEST FAILED. missed lines=[$($missed -join ', ')] unexpected lines=[$($extra -join ', ')]" -ForegroundColor Red
        exit 1
    }
    Write-Host "SELF-TEST PASSED - caught the 3 planted dropped-`$ reads and left the correct form, an exe, a .ps1 and a dotted argument alone." -ForegroundColor Green
    exit 0
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) { Write-Host "OK - no dropped-`$ property accesses." }
    exit 0
}

Write-Host ""
Write-Host "ERROR: bareword in command position that looks like a dropped '`$':" -ForegroundColor Red
Write-Host ""
foreach ($f in ($findings | Sort-Object Source, Line)) {
    Write-Host ("  {0}:{1}" -f $f.Source, $f.Line) -ForegroundColor Yellow
    Write-Host ("      {0}" -f $f.Text) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "'$($findings[0].Name)' is parsed as a COMMAND, throws CommandNotFoundException at" -ForegroundColor Red
Write-Host "run time, and is swallowed under default preferences -- the value renders blank." -ForegroundColor Red
Write-Host "Write it as `$$($findings[0].Name) (usually inside `"`$( ... )`")." -ForegroundColor Red
exit 1
