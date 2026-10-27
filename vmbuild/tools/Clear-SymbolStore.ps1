# Symbol-store cleaner. Reports by default; -Delete is required to remove anything.
#
#   .\Clear-SymbolStore.ps1 -CreatedAfter (Get-Date).Date          # what arrived today
#   .\Clear-SymbolStore.ps1 -CreatedAfter (Get-Date).Date -Delete  # remove it
#
# Selection is by DOWNLOAD TIME, not by inspecting the PDB. Scanning for source
# paths to spot public/stripped PDBs was tried and does not work: only 24 of 72
# known-public Windows PDBs lacked source and build markers. Provenance is exact;
# content is not.
#
# For general age/size trimming of a symbol store, use the supported tool:
#   C:\debuggers\Windbg\agestore.exe <store> -date=<mm-dd-yyyy> -s -y
[CmdletBinding()]
param(
    [string]$SymbolStore = 'C:\symbols',
    [Parameter(Mandatory = $true)]
    [datetime]$CreatedAfter,
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SymbolStore)) { throw "Symbol store not found: $SymbolStore" }

$all = @(Get-ChildItem -LiteralPath $SymbolStore -Recurse -File -ErrorAction SilentlyContinue)
"store: $SymbolStore"
"  {0} file(s), {1:N1} MB total" -f $all.Count, ((($all | Measure-Object Length -Sum).Sum) / 1MB)

$candidates = @($all | Where-Object { $_.CreationTime -ge $CreatedAfter })
"  {0} created at or after {1:yyyy-MM-dd HH:mm}" -f $candidates.Count, $CreatedAfter

if ($candidates.Count -eq 0) { ''; 'Nothing matched. No action taken.'; exit 0 }

$mb = (($candidates | Measure-Object Length -Sum).Sum) / 1MB
''
"MATCHED {0} file(s), {1:N1} MB" -f $candidates.Count, $mb
$candidates | Sort-Object Length -Descending | Select-Object -First 25 | ForEach-Object {
    "  {0,8:N1} MB  {1:yyyy-MM-dd HH:mm}  {2}" -f ($_.Length / 1MB), $_.CreationTime, $_.Name
}
if ($candidates.Count -gt 25) { "  ... and {0} more" -f ($candidates.Count - 25) }

if (-not $Delete) {
    ''
    'REPORT ONLY -- nothing was removed. Re-run with -Delete to remove the files above.'
    exit 0
}

''
$removed = 0
$freed = 0
foreach ($f in $candidates) {
    $freed += $f.Length
    Remove-Item -LiteralPath $f.FullName -Force
    $removed++
}

# Store layout is <store>\<name>.pdb\<GUID+age>\<name>.pdb. Prune as a separate
# repeated sweep: walking up per-file cannot drop a <name>.pdb folder whose sibling
# GUID folder is only deleted later in the same loop, which left 26 stubs behind.
$root = (Resolve-Path $SymbolStore).Path.TrimEnd('\')
$pruned = 0
do {
    $empty = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName.TrimEnd('\') -ne $root -and
            @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0
        })
    foreach ($d in $empty) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue }
    $pruned += $empty.Count
} while ($empty.Count -gt 0)

"REMOVED {0} file(s), freed {1:N1} MB" -f $removed, ($freed / 1MB)
"PRUNED  {0} empty folder(s)" -f $pruned
