<#
.SYNOPSIS
    Verifies that BDC pre-promotion LDAP checks cannot hang on an unresponsive server.
#>
[CmdletBinding()]
param(
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Assertions = 0
$script:Failures = 0

function Assert-True {
    param([bool] $Condition, [string] $What)

    $script:Assertions++
    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Get-BdcVerificationSetScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Locals are consumed by the source-extracted DSC string expression.')]
    param([Management.Automation.Language.ConvertExpressionAst] $Expression)

    $PDCIPAddress = '192.0.2.1'
    $DomainName = 'example.test'
    $cvDomainDN = 'DC=example,DC=test'
    $cvAdminUser = 'vmbuildadmin'
    $cvAdminPassB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('not-a-real-password'))
    return & ([scriptblock]::Create($Expression.Extent.Text))
}

$sourcePath = Join-Path $RootPath 'DSC\phases\Phase2BDC.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
$structuralErrors = @($parseErrors | Where-Object {
        $_.ErrorId -notin @('ModuleNotFoundDuringParse', 'MultipleModuleEntriesFoundDuringParse')
    })
if ($structuralErrors.Count -ne 0) {
    Write-Host "SETUP FAIL: Phase2BDC.ps1 has $($structuralErrors.Count) structural parse error(s)."
    $structuralErrors | ForEach-Object { Write-Host "  $($_.Message)" }
    exit 2
}

$setScriptExpressions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.ConvertExpressionAst] -and
            $node.Type.TypeName.Name -eq 'string' -and
            $node.Extent.Text.Contains('VerifyDomainAdmin.reboot')
        }, $true))
if ($setScriptExpressions.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one BDC verification SetScript, found $($setScriptExpressions.Count)."
    exit 2
}

$generatedScript = Get-BdcVerificationSetScript -Expression $setScriptExpressions[0]

$generatedTokens = $null
$generatedErrors = $null
$generatedAst = [Management.Automation.Language.Parser]::ParseInput($generatedScript, [ref]$generatedTokens, [ref]$generatedErrors)
Assert-True (@($generatedErrors).Count -eq 0) 'generated BDC verification script parses cleanly'

$boundedFunctions = @($generatedAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-BoundedDomainAdminMembership'
        }, $true))
if ($boundedFunctions.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one Test-BoundedDomainAdminMembership definition, found $($boundedFunctions.Count)."
    exit 2
}
. ([scriptblock]::Create($boundedFunctions[0].Extent.Text))

Assert-True ($generatedScript -match "EnvironmentVariables\['MEMLABS_LDAP_PASSWORD'\]" -and
    $generatedScript -notmatch '(?m)^\s*\$startInfo\.Arguments\s*=.*AdminPass') 'LDAP worker password is passed through its private environment, not its command line'
Assert-True ($generatedScript -match '(?s)catch\s*\{\s*if \(-not \$process\.HasExited\)\s*\{\s*throw "Could not terminate LDAP verification worker') 'LDAP worker cleanup tolerates an exit racing with process termination'
$successWorkerScript = @'
if ($env:MEMLABS_LDAP_PASSWORD -eq 'probe-secret') {
    Write-Output 'VERIFIED'
    exit 0
}
exit 2
'@
$successResult = Test-BoundedDomainAdminMembership -PdcIP '127.0.0.1' -Port 389 -Domain 'invalid' `
    -DomainDN 'DC=invalid' -AdminUser 'invalid' -AdminPass 'probe-secret' -TimeoutSeconds 5 -WorkerScript $successWorkerScript
Assert-True $successResult 'LDAP worker returns verified only for its successful output contract'

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$acceptedClient = $null
$workerMarker = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-bdc-ldap-worker-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $acceptTask = $listener.AcceptTcpClientAsync()
    $escapedWorkerMarker = $workerMarker.Replace("'", "''")
    $workerScript = @"
[IO.File]::WriteAllText('$escapedWorkerMarker', [string]`$PID)
`$client = [Net.Sockets.TcpClient]::new()
try {
    `$client.Connect(`$env:MEMLABS_LDAP_HOST, [int]`$env:MEMLABS_LDAP_PORT)
    [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
}
finally {
    `$client.Dispose()
}
"@

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $verified = Test-BoundedDomainAdminMembership -PdcIP '127.0.0.1' -Port $port -Domain 'invalid' `
        -DomainDN 'DC=invalid' -AdminUser 'invalid' -AdminPass 'invalid' -TimeoutSeconds 2 -WorkerScript $workerScript
    $timer.Stop()

    $accepted = $acceptTask.Wait([TimeSpan]::FromSeconds(1))
    if ($accepted) { $acceptedClient = $acceptTask.Result }
    Assert-True $accepted 'stalled-bind fixture accepted the LDAP TCP connection'
    Assert-True (-not $verified) 'bounded LDAP helper reports an unresponsive server'
    Assert-True ($timer.Elapsed.TotalSeconds -ge 1) 'stalled LDAP fixture exercised the request timeout'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 8) 'stalled LDAP request returns within the bounded interval'
    Assert-True (Test-Path -LiteralPath $workerMarker) 'stalled-bind fixture captured the LDAP worker PID'
    if (Test-Path -LiteralPath $workerMarker) {
        $workerPid = [int][IO.File]::ReadAllText($workerMarker)
        Assert-True ($null -eq (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)) 'timed-out LDAP worker process is terminated'
    }
}
finally {
    if ($acceptedClient) { $acceptedClient.Dispose() }
    $listener.Stop()
    Remove-Item -LiteralPath $workerMarker -Force -ErrorAction SilentlyContinue
}

$orphanListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$orphanListener.Start()
$orphanAcceptedClient = $null
$outerParent = $null
$orphanWorkerPid = $null
$orphanWorkerMarker = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-bdc-orphan-worker-' + [guid]::NewGuid().ToString('N') + '.txt')
$orphanWorkerPath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-bdc-orphan-worker-' + [guid]::NewGuid().ToString('N') + '.ps1')
$outerParentPath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-bdc-orphan-parent-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    $orphanPort = ([Net.IPEndPoint]$orphanListener.LocalEndpoint).Port
    $orphanAcceptTask = $orphanListener.AcceptTcpClientAsync()
    $escapedOrphanMarker = $orphanWorkerMarker.Replace("'", "''")
    $orphanWorkerScript = @"
[IO.File]::WriteAllText('$escapedOrphanMarker', [string]`$PID)
`$client = [Net.Sockets.TcpClient]::new()
try {
    `$client.Connect(`$env:MEMLABS_LDAP_HOST, [int]`$env:MEMLABS_LDAP_PORT)
    [Threading.Thread]::Sleep([Threading.Timeout]::Infinite)
}
finally {
    `$client.Dispose()
}
"@
    [IO.File]::WriteAllText($orphanWorkerPath, $orphanWorkerScript)

    $escapedWorkerPath = $orphanWorkerPath.Replace("'", "''")
    $outerParentScript = @"
`$ErrorActionPreference = 'Stop'
$($boundedFunctions[0].Extent.Text)
`$workerScript = [IO.File]::ReadAllText('$escapedWorkerPath')
`$null = Test-BoundedDomainAdminMembership -PdcIP '127.0.0.1' -Port $orphanPort -Domain 'invalid' -DomainDN 'DC=invalid' -AdminUser 'invalid' -AdminPass 'invalid' -TimeoutSeconds 120 -WorkerScript `$workerScript
"@
    [IO.File]::WriteAllText($outerParentPath, $outerParentScript)

    $outerInfo = [Diagnostics.ProcessStartInfo]::new()
    $outerInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $outerInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$outerParentPath`""
    $outerInfo.UseShellExecute = $false
    $outerInfo.CreateNoWindow = $true
    $outerParent = [Diagnostics.Process]::Start($outerInfo)

    $orphanAccepted = $orphanAcceptTask.Wait([TimeSpan]::FromSeconds(10))
    if ($orphanAccepted) { $orphanAcceptedClient = $orphanAcceptTask.Result }
    $markerTimer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $orphanWorkerMarker) -and $markerTimer.Elapsed.TotalSeconds -lt 10) {
        [Threading.Thread]::Sleep(50)
    }
    $markerTimer.Stop()
    Assert-True $orphanAccepted 'abrupt-parent fixture accepted the LDAP worker connection'
    Assert-True (Test-Path -LiteralPath $orphanWorkerMarker) 'abrupt-parent fixture captured the LDAP worker PID'

    if (Test-Path -LiteralPath $orphanWorkerMarker) {
        $orphanWorkerPid = [int][IO.File]::ReadAllText($orphanWorkerMarker)
    }
    if (-not $outerParent.HasExited) { $outerParent.Kill() }
    Assert-True ($outerParent.WaitForExit(5000)) 'abrupt-parent fixture terminated the outer helper process'

    $reapTimer = [Diagnostics.Stopwatch]::StartNew()
    while ($orphanWorkerPid -and (Get-Process -Id $orphanWorkerPid -ErrorAction SilentlyContinue) -and $reapTimer.Elapsed.TotalSeconds -lt 10) {
        [Threading.Thread]::Sleep(50)
    }
    $reapTimer.Stop()
    Assert-True ($orphanWorkerPid -and $null -eq (Get-Process -Id $orphanWorkerPid -ErrorAction SilentlyContinue)) 'kill-on-close job reaps the LDAP worker after abrupt parent termination'
}
finally {
    if ($outerParent) {
        if (-not $outerParent.HasExited) {
            try { $outerParent.Kill() } catch {}
            [void]$outerParent.WaitForExit(5000)
        }
        $outerParent.Dispose()
    }
    if ($orphanWorkerPid -and (Get-Process -Id $orphanWorkerPid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $orphanWorkerPid -Force -ErrorAction SilentlyContinue
    }
    if ($orphanAcceptedClient) { $orphanAcceptedClient.Dispose() }
    $orphanListener.Stop()
    Remove-Item -LiteralPath $orphanWorkerMarker, $orphanWorkerPath, $outerParentPath -Force -ErrorAction SilentlyContinue
}

$utcMarker = [DateTime]::UtcNow.ToString('o')
$parsedMarker = [DateTime]::Parse($utcMarker, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
Assert-True ($parsedMarker.Kind -eq [DateTimeKind]::Utc) 'reboot marker parsing preserves UTC kind'
Assert-True ([Math]::Abs(([DateTime]::UtcNow - $parsedMarker.ToUniversalTime()).TotalSeconds) -lt 5) 'reboot marker parsing preserves the recorded instant'

Write-Host "Applicable assertions: $script:Assertions"
if ($script:Failures -ne 0) { exit 1 }
exit 0