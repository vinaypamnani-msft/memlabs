<#
.SYNOPSIS
    Verify the cached password cannot leak through shared MemLabs log writers.
.DESCRIPTION
    Loads shipped functions without initializing MemLabs. Uses a scratch password
    cache, real log files, and a synthetic encryption provider in real 32-bit
    Windows PowerShell to exercise the mRemoteNG fallback's success and failure.
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$script:Failures = 0
$script:Displayed = New-Object 'System.Collections.Generic.List[string]'
$script:Notifications = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Read-TestAst {
    param([string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count) { throw "Parse errors in $Path." }
    return $ast
}

function Import-TestFunction {
    param($Ast, [string]$Name)

    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one definition of $Name." }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

function Write-Host2 {
    param([string]$Text, [string]$ForegroundColor)

    $script:Displayed.Add($Text)
}

function Show-Notification {
    param([string]$ToastText)

    $script:Notifications.Add($ToastText)
}

function Out-Host {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process { $script:Displayed.Add("$InputObject") }
}

function Invoke-LogFallback {
    param([string]$Text)

    function Add-LogBufferText { param($Entry, $Text) throw 'Synthetic buffer failure.' }
    Write-Log -Text $Text -LogOnly
}

function Invoke-MRemoteNGFallback {
    function New-MRemoteNGCryptoProvider {
        param([string]$BouncyCastleDll, [string]$AssemblyPath)
        throw 'Synthetic inline assembly load failure; exercise the real 32-bit fallback.'
    }
    Get-MRemoteNGPassword
}

$commonAst = Read-TestAst (Join-Path $root 'Common.ps1')
foreach ($name in @(
        'Protect-MemLabsLogText', 'Get-JsonLogEscaped', 'Get-LogBufferEntry',
        'Add-LogBufferText', 'Add-LogTextToFile', 'Invoke-LogRotateIfNeeded',
        'Flush-LogBuffer', 'Register-LogBufferExitFlush', 'Write-Log',
        'Write-Exception', 'Write-ProgressDiagLog'
    )) {
    . (Import-TestFunction $commonAst $name)
}
$storageAst = Read-TestAst (Join-Path $root 'common\Common.StorageToken.ps1')
. (Import-TestFunction $storageAst 'Get-LocalAdminCredential')
$prereqAst = Read-TestAst (Join-Path $root 'common\Common.Prereqs.ps1')
. (Import-TestFunction $prereqAst 'Get-MemLabsWindowsPowerShellModulePath')
$mRemoteAst = Read-TestAst (Join-Path $root 'common\Common.mRemoteNG.ps1')
. (Import-TestFunction $mRemoteAst 'New-MRemoteNGCryptoProvider')
. (Import-TestFunction $mRemoteAst 'Get-MRemoteNGPassword32Bit')
. (Import-TestFunction $mRemoteAst 'Get-MRemoteNGPassword')
$configAst = Read-TestAst (Join-Path $root 'common\Common.Config.ps1')
. (Import-TestFunction $configAst 'ConvertTo-ConfigDiagnosticJson')
$maintenanceAst = Read-TestAst (Join-Path $root 'common\Common.Maintenance.ps1')
. (Import-TestFunction $maintenanceAst 'Protect-VMFixDiagnosticText')

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-log-secret-' + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $workDir 'cache'
$crash = Join-Path $workDir 'crash'
$null = New-Item -ItemType Directory -Path $cache, $crash -Force -ErrorAction Stop
$oldProgramData = $env:ProgramData
$global:Common = [pscustomobject]@{
    CachePath           = $cache
    CrashLogsPath       = $crash
    LogPath             = Join-Path $workDir 'VMBuild.example.test.log'
    LocalAdmin          = $null
    PS7                 = $PSVersionTable.PSVersion.Major -ge 7
    VerboseEnabled      = $true
    VerboseToLogOnly    = $false
    VerboseTailProcess  = $null
    OfflineMode         = $true
}
$global:LogBuffers = @{}
$global:LogBufferMaxBytes = 1MB
$global:LogBufferMaxAgeSeconds = 600
$global:LogRotateMaxBytes = 2MB
$global:LogRotateKeep = 3
$global:LogRotateCheckEverySec = 5
$global:LogBufferHardCapBytes = 8MB
$global:JsonLogEnabled = $true
$global:MemLabsRunId = 'synthetic-redaction-test'
$global:ProgressDiag = $true
$global:ProgressDiagPath = Join-Path $workDir 'progressdiag.log'
$passwordPath = Join-Path $cache 'vmbuildadmin.txt'
$secret = 'synthetic-' + [guid]::NewGuid().ToString('N') + '-[''"\].*$<&%' + [char]0x00e9
$secrets = @($secret, ('reject_' + $secret))

try {
    Write-Host "Engine: $($PSVersionTable.PSVersion)"
    Assert-True ((Protect-MemLabsLogText 'startup before credentials') -eq 'startup before credentials') 'logging before credential initialization is unchanged'
    [IO.File]::WriteAllText($passwordPath, $secret, [Text.Encoding]::UTF8)
    Assert-True (Get-LocalAdminCredential) 'shipped loader reads the password from the scratch text file'
    $jsonSecret = ConvertTo-Json -InputObject $secret -Compress
    $representations = @(
        $secret,
        $secret.Replace("'", "''"),
        (Get-JsonLogEscaped $secret),
        $jsonSecret.Substring(1, $jsonSecret.Length - 2),
        [Security.SecurityElement]::Escape($secret),
        [Uri]::EscapeDataString($secret)
    )
    foreach ($representation in $representations) {
        $message = "Native assembly failed at Encrypt('$representation', key)."
        Assert-True ((Protect-MemLabsLogText $message) -eq "Native assembly failed at Encrypt('[REDACTED]', key).") 'literal and escaped password values are redacted without losing the error'
        Write-Log -Text $message -Warning -ShowNotification
    }
    $streamResult = Write-Log -Text "returned $secret" -OutputStream -Warning
    Assert-True ($streamResult.Text -eq 'returned [REDACTED]' -and $streamResult.LogLevel -eq 2) 'output-stream records retain their shape and severity without the password'
    $failureOutput = @(Write-Log -Text "failed $secret" -OutputStream -Failure -ErrorAction Continue 2>&1)
    $errorRecords = @($failureOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    Assert-True ($errorRecords.Count -eq 1 -and $errorRecords[0].Exception.Message -eq 'failed [REDACTED]') 'failure error-stream output is redacted before emission'
    Assert-True (@($script:Displayed | Where-Object { $_.Contains($secret) }).Count -eq 0) 'console output is redacted'
    Assert-True (@($script:Notifications | Where-Object { $_.Contains($secret) }).Count -eq 0) 'notification output is redacted'

    $unlabelled = [pscustomobject]@{ notes = "arbitrary failure: $secret"; vmName = 'SAMPLE' }
    $unlabelled | Add-Member -NotePropertyName $secret -NotePropertyValue 'dynamic field name'
    $diagnostic = ConvertTo-ConfigDiagnosticJson -Config $unlabelled -Compress
    $safeDiagnostic = $diagnostic | ConvertFrom-Json -ErrorAction Stop
    Assert-True ($safeDiagnostic.notes -eq 'arbitrary failure: [REDACTED]' -and
        $safeDiagnostic.vmName -eq 'SAMPLE' -and $safeDiagnostic.PSObject.Properties.Name -notcontains $secret) 'configuration diagnostics redact ordinary field values and dynamic field names'
    Assert-True ($unlabelled.notes.Contains($secret)) 'runtime configuration retains the original password value'

    $directPath = Join-Path $workDir 'direct.log'
    Add-LogTextToFile -Path $directPath -Text "unlabelled $secret"
    Assert-True ((Get-Content -LiteralPath $directPath -Raw) -eq 'unlabelled [REDACTED]') 'direct file appends are redacted'
    Invoke-LogFallback "fallback native error $secret"
    Write-ProgressDiagLog "progress error $secret"
    try { throw "synthetic native exception $secret" }
    catch { Write-Exception -ExceptionInfo $_ -AdditionalInfo ("source Encrypt('" + $secret.Replace("'", "''") + "', key)") }

    $longMessage = 'AUDIT_ROOT_BEGIN ' + ('long diagnostic context ' * 100) + $secret + ' AUDIT_ROOT_END'
    $longException = [InvalidOperationException]::new($longMessage)
    $longRecord = [Management.Automation.ErrorRecord]::new(
        $longException, "Audit.LongError.$secret", [Management.Automation.ErrorCategory]::ResourceUnavailable, 'fixture')
    Write-Exception -ExceptionInfo $longRecord
    Flush-LogBuffer -All
    $exceptionRecords = @(Get-Content -LiteralPath ([IO.Path]::ChangeExtension($Common.LogPath, '.jsonl')) |
        ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop } |
        Where-Object { $_.comp -eq 'Write-Exception' })
    $completeMessage = @($exceptionRecords | Where-Object {
        $_.lvl -eq 'ERROR' -and $_.msg.Contains('AUDIT_ROOT_BEGIN') -and $_.msg.Contains('AUDIT_ROOT_END')
    })
    Assert-True ($completeMessage.Count -eq 1 -and $completeMessage[0].msg.Contains('[REDACTED]') -and
        -not $completeMessage[0].msg.Contains($secret)) 'normal structured logs retain the entire redacted exception message, not truncated call-stack arguments'
    $cmTraceText = [IO.File]::ReadAllText($Common.LogPath)
    Assert-True ($cmTraceText.Contains('AUDIT_ROOT_BEGIN') -and $cmTraceText.Contains('AUDIT_ROOT_END')) 'CMTrace logs also retain the complete root exception message'
    $exceptionIdentity = @($exceptionRecords | Where-Object {
        $_.msg.Contains('ExceptionType=System.InvalidOperationException') -and
        $_.msg.Contains('HResult=0x80131509') -and $_.msg.Contains('FullyQualifiedErrorId=Audit.LongError.[REDACTED]')
    })
    Assert-True ($exceptionIdentity.Count -eq 1 -and $exceptionIdentity[0].lvl -eq 'ERROR') 'normal logs retain redacted error identity and exception HRESULT'
    $reports = @(Get-ChildItem -LiteralPath $crash -File | Where-Object {
        [IO.File]::ReadAllText($_.FullName).Contains('AUDIT_ROOT_END')
    })
    Assert-True ($reports.Count -eq 1) 'the long exception remains complete in its crash report'
    if ($reports.Count -eq 1) {
        Assert-True (@($exceptionRecords | Where-Object { $_.msg.Contains($reports[0].FullName) }).Count -eq 1) 'the normal log identifies the crash report even without AdditionalInfo'
    }
    $detailRecord = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new("NATIVE_CAUSE_BEGIN $secret NATIVE_CAUSE_END"),
        'Audit.ErrorDetails', [Management.Automation.ErrorCategory]::InvalidOperation, 'fixture')
    $detailRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new("Friendly explanation $secret")
    Write-Exception -ExceptionInfo $detailRecord
    Flush-LogBuffer -All
    $detailMessages = @(Get-Content -LiteralPath ([IO.Path]::ChangeExtension($Common.LogPath, '.jsonl')) |
        ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop } |
        Where-Object { $_.comp -eq 'Write-Exception' -and $_.lvl -eq 'ERROR' })
    Assert-True (@($detailMessages | Where-Object {
        $_.msg.Contains('NATIVE_CAUSE_BEGIN [REDACTED] NATIVE_CAUSE_END')
    }).Count -eq 1) 'custom ErrorDetails cannot replace the native exception message in normal logs'
    Assert-True (@($detailMessages | Where-Object {
        $_.msg -eq 'ErrorDetails=Friendly explanation [REDACTED]'
    }).Count -eq 1) 'custom ErrorDetails are retained separately and redacted'

    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps32)) { throw '32-bit Windows PowerShell is required for the native fallback regression.' }
    $env:ProgramData = Join-Path $workDir "provider's data"
    $providerDir = Join-Path $env:ProgramData 'memlabs\mRemoteNG'
    $null = New-Item -ItemType Directory -Path $providerDir -Force -ErrorAction Stop
    $providerPath = Join-Path $providerDir 'BouncyCastle.Crypto.dll'
    $providerSource = @'
using System;
using System.Security;
using System.Security.Cryptography;
using System.Text;
namespace mRemoteNG.Security.SymmetricEncryption {
    public class AeadCryptographyProvider {
        public string Encrypt(string plaintext, SecureString key) {
            string[] args = Environment.GetCommandLineArgs();
            bool checkedScript = false;
            for (int i = 0; i + 1 < args.Length; i++) {
                if (String.Equals(args[i], "-EncodedCommand", StringComparison.OrdinalIgnoreCase)) {
                    string script = Encoding.Unicode.GetString(Convert.FromBase64String(args[i + 1]));
                    if (script.Contains(plaintext)) throw new InvalidOperationException("Password embedded in child script.");
                    checkedScript = true;
                }
            }
            if (!checkedScript) throw new InvalidOperationException("Expected an encoded child script.");
            if (plaintext.StartsWith("reject_", StringComparison.Ordinal)) {
                throw new InvalidOperationException("Synthetic provider rejection: " + plaintext);
            }
            using (SHA256 hash = SHA256.Create()) {
                return Convert.ToBase64String(hash.ComputeHash(Encoding.UTF8.GetBytes(plaintext)));
            }
        }
    }
}
'@
    $compileScript = "`$ProgressPreference = 'SilentlyContinue'`nAdd-Type -TypeDefinition @'`n$providerSource`n'@ -OutputAssembly '" +
        $providerPath.Replace("'", "''") + "' -ErrorAction Stop"
    $encodedCompile = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compileScript))
    & $ps32 -NoProfile -NonInteractive -EncodedCommand $encodedCompile
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the synthetic .NET Framework provider.' }
    Copy-Item -LiteralPath $providerPath -Destination (Join-Path $providerDir 'mRemoteNG.exe') -ErrorAction Stop

    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expected = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret))) }
    finally { $sha.Dispose() }
    $parentModulePath = $env:PSModulePath
    $result = Invoke-MRemoteNGFallback
    if ($result -ne $expected) {
        Flush-LogBuffer -All
        $jsonPath = [IO.Path]::ChangeExtension($Common.LogPath, '.jsonl')
        foreach ($record in @(Get-Content -LiteralPath $jsonPath | ForEach-Object { $_ | ConvertFrom-Json } |
                    Where-Object { $_.lvl -eq 'WARN' } | Select-Object -Last 2)) {
            Write-Host ("DETAIL: " + (Protect-MemLabsLogText $record.msg))
        }
    }
    Assert-True ($result -eq $expected) 'real 32-bit fallback receives the exact Unicode password through stdin, not script or command arguments'
    Assert-True ($env:PSModulePath -eq $parentModulePath) 'Windows PowerShell module isolation does not change the parent module path'

    [IO.File]::WriteAllText($passwordPath, $secrets[1], [Text.Encoding]::UTF8)
    Assert-True (Get-LocalAdminCredential) 'changing the password file loads the new value'
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $rejected = Invoke-MRemoteNGFallback
    }
    finally { $ErrorActionPreference = $savedPreference }
    Assert-True ($null -eq $rejected) 'provider failure under Stop returns no success-shaped encryption result'
    Flush-LogBuffer -All
    $rejections = @(Get-Content -LiteralPath ([IO.Path]::ChangeExtension($Common.LogPath, '.jsonl')) |
        ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.msg.Contains('Synthetic provider rejection') })
    Assert-True ($rejections.Count -eq 1 -and $rejections[0].msg.Contains('[REDACTED]') -and
        -not $rejections[0].msg.Contains($secrets[1].Substring(0, $secrets[1].Length - 1))) 'native failure details remain visible while even the ASCII password prefix is hidden'

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Register-LogBufferExitFlush
        $timerPath = Join-Path $workDir 'timer.log'
        $entry = Get-LogBufferEntry -Path $timerPath
        Add-LogBufferText -Entry $entry -Text "timer $($secrets[1])"
        Assert-True (-not $entry.Builder.ToString().Contains($secrets[1])) 'buffer text is safe before the runspace-free timer can access it'
        $entry.LastFlushUtc = [DateTime]::UtcNow.AddMinutes(-1)
        [MemLabs.LogFlusher]::Flush($global:LogBuffers)
        Assert-True ((Get-Content -LiteralPath $timerPath -Raw) -eq 'timer [REDACTED]') 'shipped C# timer writer persists only redacted buffer text'
    }
    Flush-LogBuffer -All
    foreach ($file in @(Get-ChildItem -LiteralPath $workDir -Recurse -File |
                Where-Object { $_.Extension -in @('.log', '.jsonl', '.txt') -and $_.FullName -ne $passwordPath })) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        foreach ($value in $secrets) {
            $jsonValue = ConvertTo-Json -InputObject $value -Compress
            $escaped = $jsonValue.Substring(1, $jsonValue.Length - 2)
            Assert-True (-not $content.Contains($value) -and -not $content.Contains($value.Replace("'", "''")) -and
                -not $content.Contains($escaped)) "persisted $($file.Extension) output contains no password value or escaped password"
        }
    }
    foreach ($line in @(Get-Content -LiteralPath ([IO.Path]::ChangeExtension($Common.LogPath, '.jsonl')))) {
        $null = $line | ConvertFrom-Json -ErrorAction Stop
    }
    Assert-True $true 'structured log records remain valid JSON'
}
finally {
    if ($global:LogFlushTimer) {
        $global:LogFlushTimer.Dispose()
        $global:LogFlushTimer = $null
    }
    $global:LogBuffers.Clear()
    if ($Common.LocalAdmin) { $Common.LocalAdmin.Password.Dispose() }
    $env:ProgramData = $oldProgramData
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop
}

if ($script:Failures) { throw "$script:Failures password log redaction check(s) failed." }
Write-Host 'OK - cached password log redaction checks passed.'
