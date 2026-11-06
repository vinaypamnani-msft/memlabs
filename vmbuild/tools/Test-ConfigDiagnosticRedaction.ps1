<#
.SYNOPSIS
    Verify diagnostic config exports omit secrets without changing runtime settings.
.DESCRIPTION
    Executes the shipped serializer, sidecar-write block, and configuration error
    handlers without initializing MemLabs or connecting to a VM.
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$script:Failures = 0
$script:Logs = New-Object 'System.Collections.Generic.List[object]'
$script:ExceptionContexts = New-Object 'System.Collections.Generic.List[object]'

function Assert-True {
    param ([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Read-TestAst {
    param ([string]$Path)

    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -ne 0) { throw "Parse errors in $Path." }
    return $ast
}

function Get-TestFunction {
    param ($Ast, [string]$Name)

    $definitions = @($Ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one definition of $Name." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Write-Log {
    param ([string]$Message, [switch]$LogOnly, [switch]$Warning)

    $script:Logs.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}

function Write-Exception {
    param ($ExceptionInfo, $AdditionalInfo)

    $script:ExceptionContexts.Add([pscustomobject]@{ Error = $ExceptionInfo; Context = $AdditionalInfo })
}

$configAst = Read-TestAst (Join-Path $root 'common\Common.Config.ps1')
$maintenanceAst = Read-TestAst (Join-Path $root 'common\Common.Maintenance.ps1')
$newLabAst = Read-TestAst (Join-Path $root 'New-Lab.ps1')
. (Get-TestFunction $maintenanceAst 'Protect-VMFixDiagnosticText')
. (Get-TestFunction $configAst 'ConvertTo-ConfigDiagnosticJson')

$sidecarBlocks = @($newLabAst.FindAll({
            param ($node)
            $node -is [System.Management.Automation.Language.TryStatementAst] -and
            @($node.Body.Statements | Where-Object {
                    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $_.Left.Extent.Text -eq '$configSidecarWritten' -and $_.Right.Extent.Text -eq '$true'
                }).Count -eq 1
        }, $true))
if ($sidecarBlocks.Count -ne 1) { throw 'Expected one sidecar-write block.' }
$sidecarBlock = [scriptblock]::Create($sidecarBlocks[0].Extent.Text)

$secretMarker = 'diagnostic-test-' + [guid]::NewGuid().ToString('N')
$secureValue = New-Object System.Security.SecureString
foreach ($character in $secretMarker.ToCharArray()) { $secureValue.AppendChar($character) }
$credential = New-Object System.Management.Automation.PSCredential('diagnostic-user', $secureValue)
$config = [pscustomobject]@{
    vmOptions       = [pscustomobject]@{ domainName = 'example.test'; timeZone = 'UTC'; adminPassword = $secretMarker }
    parameters      = [pscustomobject]@{
        DCName      = 'DC1'
        productID   = $secretMarker
        SysCenterId = $secretMarker
    }
    virtualMachines = @([pscustomobject]@{ vmName = 'SAMPLE'; role = 'DC'; credential = $credential })
    nested          = [ordered]@{
        PASSWORD         = $secretMarker
        api_key          = $secretMarker
        clientSecret     = $secretMarker
        accessToken      = $secretMarker
        connectionString = $secretMarker
        productKey       = $secretMarker
        licenseKey       = $secretMarker
        items            = @(@{ vmName = 'NESTED'; pwd = $secretMarker })
        account          = $credential
        protectedValue   = $secureValue
        nullValue        = $null
        enabled          = $false
        count            = 0
        empty            = @()
        singleton        = @('one')
        arrays           = @(@('one', 'two'), @('three'))
    }
    URLS            = [pscustomobject]@{
        VCredist = 'https://example.test/installer.exe'
        signed   = "https://example.test/installer.exe?sig=$secretMarker&version=1"
        userInfo = "https://user:${secretMarker}@example.test/installer.exe"
    }
    notes           = "password='$secretMarker'"
    longText        = 'x' * 3000
}
$originalJson = ConvertTo-Json -InputObject $config -Depth 20 -Compress
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('config-diagnostic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir -ErrorAction Stop

try {
    Write-Host "Engine: $($PSVersionTable.PSVersion)"
    $json = ConvertTo-ConfigDiagnosticJson -Config $config
    $safe = $json | ConvertFrom-Json -ErrorAction Stop
    Assert-True (-not $json.Contains($secretMarker)) 'serialized diagnostics contain no synthetic secret'
    Assert-True ($safe.parameters.PSObject.Properties.Name -notcontains 'productID') 'activation key field is omitted'
    Assert-True ($safe.parameters.PSObject.Properties.Name -notcontains 'SysCenterId') 'ConfigMgr key field is omitted'
    Assert-True ($safe.vmOptions.PSObject.Properties.Name -notcontains 'adminPassword') 'password field is omitted'
    Assert-True ($safe.virtualMachines[0].PSObject.Properties.Name -notcontains 'credential') 'nested credential field is omitted'
    Assert-True ($safe.nested.account -eq '[REDACTED]' -and $safe.nested.protectedValue -eq '[REDACTED]') 'credential objects under other names are redacted'
    Assert-True ($safe.vmOptions.domainName -eq 'example.test' -and $safe.virtualMachines[0].vmName -eq 'SAMPLE') 'ordinary diagnostic settings are preserved'
    Assert-True ($safe.URLS.VCredist -eq $config.URLS.VCredist) 'VCredist is not mistaken for a credential field'
    Assert-True ($safe.URLS.signed -eq 'https://example.test/installer.exe?sig=[REDACTED]&version=1') 'signed URL credentials are redacted'
    Assert-True ($safe.URLS.userInfo -eq 'https://[REDACTED]@example.test/installer.exe') 'URL user info is redacted'
    Assert-True ($safe.longText.Length -eq 3000) 'ordinary strings are not truncated'
    Assert-True ($safe.nested.PSObject.Properties.Name -contains 'nullValue' -and $null -eq $safe.nested.nullValue) 'null properties are preserved'
    Assert-True ($safe.nested.enabled -eq $false -and $safe.nested.count -eq 0) 'false and zero values are preserved'
    Assert-True ($safe.nested.empty -is [array] -and $safe.nested.empty.Count -eq 0) 'empty arrays are preserved'
    Assert-True ($safe.nested.singleton -is [array] -and $safe.nested.singleton.Count -eq 1) 'singleton arrays are preserved'
    Assert-True ($safe.nested.arrays[0].Count -eq 2 -and $safe.nested.arrays[1].Count -eq 1) 'nested arrays are preserved'
    Assert-True ((ConvertTo-ConfigDiagnosticJson -Config @() -Compress) -eq '[]') 'empty root arrays remain arrays'
    Assert-True ((ConvertTo-ConfigDiagnosticJson -Config @('one') -Compress) -eq '["one"]') 'singleton root arrays remain arrays'
    Assert-True ((ConvertTo-ConfigDiagnosticJson -Config $null -Compress) -eq 'null') 'null error context is supported'
    Assert-True ($originalJson -eq (ConvertTo-Json -InputObject $config -Depth 20 -Compress)) 'runtime config is not mutated'

    $deep = @{ child = @{ child = @{ child = @{ password = $secretMarker; name = 'deep' } } } }
    $deepJson = ConvertTo-ConfigDiagnosticJson -Config $deep -Depth 2
    Assert-True (-not $deepJson.Contains($secretMarker)) 'secrets are removed before serialization depth truncation'
    $cycle = @{}
    $cycle.child = $cycle
    $cycleThrew = $false
    try { $null = ConvertTo-ConfigDiagnosticJson -Config $cycle } catch { $cycleThrew = $true }
    Assert-True $cycleThrew 'cyclic input fails explicitly instead of exporting raw values'

    $deployConfig = $config
    $configSidecar = Join-Path $workDir 'VMBuild.example.test.config.json'
    $configSidecarWritten = $false
    $diagnosticConfigJson = $null
    . $sidecarBlock
    $written = Get-Content -LiteralPath $configSidecar -Raw -ErrorAction Stop
    Assert-True ($configSidecarWritten -and -not $written.Contains($secretMarker)) 'shipped sidecar-write block writes only redacted JSON'
    $null = $written | ConvertFrom-Json -ErrorAction Stop

    $script:Logs.Clear()
    $configSidecarWritten = $false
    $diagnosticConfigJson = $null
    $lock = [IO.File]::Open($configSidecar, 'Open', 'ReadWrite', 'None')
    try { . $sidecarBlock } finally { $lock.Dispose() }
    $fallback = @($script:Logs | Where-Object { $_.Message.StartsWith('{') })
    Assert-True (-not $configSidecarWritten -and $fallback.Count -eq 1) 'blocked sidecar write retains an inline diagnostic fallback'
    $fallbackJson = $fallback[0].Message
    $null = $fallbackJson | ConvertFrom-Json -ErrorAction Stop
    Assert-True (-not $fallbackJson.Contains($secretMarker) -and $fallbackJson.Contains('"vmName":"SAMPLE"')) 'inline fallback is compact and redacted'
    Assert-True ($written -eq (Get-Content -LiteralPath $configSidecar -Raw -ErrorAction Stop)) 'blocked write preserves the previous sidecar'

    $script:Logs.Clear()
    $deployConfig = New-Object object
    $configSidecarWritten = $false
    $diagnosticConfigJson = $null
    . $sidecarBlock
    Assert-True (-not $configSidecarWritten -and $null -eq $diagnosticConfigJson) 'redaction failure never reports sidecar success'
    Assert-True (@($script:Logs | Where-Object { $_.Warning -and $_.Message -match 'redaction failed' }).Count -eq 1) 'redaction failure is reported explicitly'
    Assert-True (@($script:Logs | Where-Object { $_.Message.StartsWith('{') }).Count -eq 0) 'redaction failure never falls back to raw JSON'

    foreach ($case in @(
            @{ Ast = $newLabAst; ErrorVariable = '$deploymentError'; Rethrows = $false },
            @{ Ast = $configAst; ErrorVariable = '$configError'; Rethrows = $true }
        )) {
        $handlers = @($case.Ast.FindAll({
                    param ($node)
                    $node -is [System.Management.Automation.Language.CatchClauseAst] -and
                    $node.Body.Extent.Text.Contains('Write-Exception -ExceptionInfo ' + $case.ErrorVariable)
                }, $true))
        if ($handlers.Count -ne 1) { throw 'Expected one configuration error handler.' }
        $handler = [scriptblock]::Create($handlers[0].Body.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
        foreach ($unsupported in @($false, $true)) {
            $script:ExceptionContexts.Clear()
            $script:Logs.Clear()
            $deployConfig = $config
            $configObject = $config
            if ($unsupported) {
                $deployConfig = New-Object object
                $configObject = $deployConfig
            }
            $originalError = $null
            $rethrown = $null
            try {
                try { throw 'synthetic deployment failure' }
                catch {
                    $originalError = $_
                    . $handler
                }
            }
            catch { $rethrown = $_ }
            Assert-True ($script:ExceptionContexts.Count -eq 1) 'configuration error handler still reports the original error'
            Assert-True ([object]::ReferenceEquals($originalError, $script:ExceptionContexts[0].Error)) 'redaction does not replace the original error record'
            if ($unsupported) {
                Assert-True ($null -eq $script:ExceptionContexts[0].Context -and $script:Logs[0].Warning) 'unredactable error context is omitted with a warning'
            }
            else {
                Assert-True (-not $script:ExceptionContexts[0].Context.Contains($secretMarker) -and
                    $configObject.parameters.productID -eq $secretMarker -and $deployConfig.parameters.productID -eq $secretMarker) 'configuration error context is redacted without changing activation keys'
            }
            Assert-True (($null -ne $rethrown) -eq $case.Rethrows) 'existing rethrow behavior is preserved'
        }
    }
    Assert-True ($originalJson -eq (ConvertTo-Json -InputObject $config -Depth 20 -Compress)) 'all diagnostic paths leave runtime credentials unchanged'
}
finally {
    $secureValue.Dispose()
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop
}

if ($script:Failures) { throw "$script:Failures diagnostic redaction check(s) failed." }
Write-Host 'OK - diagnostic config redaction checks passed.'
