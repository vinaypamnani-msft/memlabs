[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath,

    [Parameter(Mandatory = $true)]
    [string] $ParameterPath
)

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Child script not found: $ScriptPath"
}
if (-not (Test-Path -LiteralPath $ParameterPath -PathType Leaf)) {
    throw "Child parameter file not found: $ParameterPath"
}

$parameters = Import-Clixml -LiteralPath $ParameterPath -ErrorAction Stop
if ($parameters -isnot [Collections.IDictionary]) {
    throw "Child parameter payload must be a dictionary: $ParameterPath"
}

$global:LASTEXITCODE = 0
& $ScriptPath @parameters
exit [int]$LASTEXITCODE
