[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:ReadResponse = ''
$script:LastWritePath = $null
$script:InjectCollisionOnNextWrite = $false

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host "$status  $What" -ForegroundColor $color
    if (-not $passed) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count) { throw "Could not parse $Path" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($functions.Count)" }
    return [scriptblock]::Create($functions[0].Extent.Text)
}

function Read-Single { return $script:ReadResponse }
function Write-Log { param ($Message) }
function Write-ConfigJsonFile {
    param ($Config, [string] $Path, [switch] $NoClobber)

    $script:LastWritePath = [System.IO.Path]::GetFullPath($Path)
    if ($NoClobber -and $script:InjectCollisionOnNextWrite) {
        'late collision' | Set-Content -LiteralPath $Path
        $script:InjectCollisionOnNextWrite = $false
    }
    if ($NoClobber -and [System.IO.File]::Exists($Path)) {
        throw [System.IO.IOException]::new("Config file already exists: $Path")
    }
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path
}

$sourcePath = Join-Path $RootPath 'genconfig.ps1'
. (Import-TestFunction -Path $sourcePath -Name 'Get-AvailableConfigFilePath')
. (Import-TestFunction -Path $sourcePath -Name 'Save-Config')
. (Import-TestFunction -Path $sourcePath -Name 'Save-CurrentConfigState')
. (Import-TestFunction -Path $sourcePath -Name 'Restore-SavedConfigState')

$configDir = Join-Path ([System.IO.Path]::GetTempPath()) ('genconfig-save-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $configDir

function New-TestConfig {
    param ([string] $DomainName, [string[]] $Roles, [int] $Serial)

    $virtualMachines = @($Roles | ForEach-Object {
            [pscustomobject]@{ vmName = "VM$Serial$_"; role = $_ }
        })
    return [pscustomobject]@{
        vmOptions       = [pscustomobject]@{ domainName = $DomainName }
        virtualMachines = $virtualMachines
        serial          = $Serial
    }
}

try {
    $global:configfile = $null
    $newDomain = New-TestConfig -DomainName 'fabrikam.com' -Roles @('DC') -Serial 1
    $firstNewDomainPath = Join-Path $configDir 'fabrikam-newdomain-1vm.json'
    'original' | Set-Content -LiteralPath $firstNewDomainPath
    Save-Config -Config $newDomain | Out-Null
    Assert-Equal (Join-Path $configDir 'fabrikam-newdomain-1vm-2.json') $script:LastWritePath 'a new-domain config uses an intent name and avoids an existing file'
    Assert-Equal 'original' (Get-Content -LiteralPath $firstNewDomainPath -Raw).Trim() 'a fresh save preserves the colliding config'

    $global:configfile = $null
    $expansion = New-TestConfig -DomainName 'fabrikam.com' -Roles @('Primary', 'SiteSystem') -Serial 2
    Save-Config -Config $expansion | Out-Null
    Assert-Equal (Join-Path $configDir 'fabrikam-expand-2vm.json') $script:LastWritePath 'an existing-domain expansion uses an expand name'

    $global:configfile = $null
    $emptyConfig = New-TestConfig -DomainName 'fabrikam.com' -Roles @() -Serial 3
    Save-Config -Config $emptyConfig | Out-Null
    Assert-Equal (Join-Path $configDir 'fabrikam-expand-0vm.json') $script:LastWritePath 'an empty VM list is counted as zero rather than one'

    $loadedPath = Join-Path $configDir 'established-name.json'
    New-TestConfig -DomainName 'fabrikam.com' -Roles @('DC') -Serial 3 | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $loadedPath
    $global:configfile = $loadedPath
    $edited = New-TestConfig -DomainName 'fabrikam.com' -Roles @('DC') -Serial 4
    $script:LastWritePath = $null
    Save-Config -Config $edited | Out-Null
    Assert-Equal $loadedPath $script:LastWritePath 'a loaded config overwrites its established path by default'
    Assert-Equal 4 (Get-Content -LiteralPath $loadedPath -Raw | ConvertFrom-Json).serial 'the loaded config receives the edited content'

    $corruptedLoadedPath = Join-Path $configDir 'externally-corrupted.json'
    '{broken' | Set-Content -LiteralPath $corruptedLoadedPath
    $global:configfile = $corruptedLoadedPath
    $script:LastWritePath = $null
    $corruptedSaveError = $null
    try { Save-Config -Config $edited | Out-Null } catch { $corruptedSaveError = $_ }
    Assert-Equal $null $corruptedSaveError 'an externally corrupted loaded config remains recoverable through save'
    Assert-Equal $corruptedLoadedPath $script:LastWritePath 'recovery replaces the established loaded path'
    Assert-Equal 4 (Get-Content -LiteralPath $corruptedLoadedPath -Raw | ConvertFrom-Json).serial 'recovery writes valid edited content'

    $global:configfile = $null
    $manualPath = Join-Path $configDir 'manual.json'
    'manual-original' | Set-Content -LiteralPath $manualPath
    $script:ReadResponse = 'manual'
    Save-Config -Config $expansion | Out-Null
    Assert-Equal (Join-Path $configDir 'manual-2.json') $script:LastWritePath 'a fresh custom filename also avoids an existing file'
    Assert-Equal 'manual-original' (Get-Content -LiteralPath $manualPath -Raw).Trim() 'a custom-name collision preserves the existing config'

    $global:configfile = $null
    $script:ReadResponse = ''
    $script:InjectCollisionOnNextWrite = $true
    $racedConfig = New-TestConfig -DomainName 'contoso.com' -Roles @('DC') -Serial 5
    $racedPath = Join-Path $configDir 'contoso-newdomain-1vm.json'
    'first collision' | Set-Content -LiteralPath $racedPath
    Save-Config -Config $racedConfig | Out-Null
    Assert-Equal 'first collision' (Get-Content -LiteralPath $racedPath -Raw).Trim() 'the original colliding config is preserved'
    Assert-Equal 'late collision' (Get-Content -LiteralPath (Join-Path $configDir 'contoso-newdomain-1vm-2.json') -Raw).Trim() 'a config created during the save race is preserved'
    Assert-Equal (Join-Path $configDir 'contoso-newdomain-1vm-3.json') $script:LastWritePath 'a late collision retries with the next numeric suffix'

    $loadedStatePath = Join-Path $configDir 'loaded-state.json'
    $global:Config = $edited
    $global:configfile = $loadedStatePath
    Save-CurrentConfigState
    $global:Config = $null
    $global:configfile = $null
    $restoredConfig = Restore-SavedConfigState
    Assert-Equal $edited.serial $restoredConfig.serial 'restoring an in-progress config preserves its object'
    Assert-Equal $loadedStatePath $global:configfile 'restoring an in-progress config preserves its loaded path'
}
finally {
    $global:configfile = $null
    $global:SavedConfig = $null
    $global:SavedConfigFile = $null
    Remove-Item -LiteralPath $configDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}

Write-Host 'OK - GenConfig save naming checks passed.' -ForegroundColor Green
exit 0