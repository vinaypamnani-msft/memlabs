[CmdletBinding()]
param([Parameter(Mandatory)][string]$Payload, [switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
$data = $Payload | ConvertFrom-Json -AsHashtable -Depth 12 -ErrorAction Stop
$names = @('Common.Control.ps1', 'ControlTransport.cs', 'Install-Control.ps1', 'Invoke-ControlBroker.ps1',
    'Invoke-ControlOperation.ps1', 'Invoke-ControlMcp.ps1', 'Start-Control.ps1', 'Invoke-MemLabsLiveOperation.ps1')
if ($data.hash -cnotmatch '^[a-f0-9]{64}$' -or @($data.files).Count -ne $names.Count) { throw 'Invalid frozen installation manifest.' }
$approved = @{}
$lines = foreach ($name in $names | Sort-Object) {
    $entries = @($data.files | Where-Object Name -CEQ $name)
    if ($entries.Count -ne 1 -or $entries[0].Hash -cnotmatch '^[A-F0-9]{64}$') { throw "Invalid package entry '$name'." }
    $bytes = [IO.File]::ReadAllBytes($entries[0].Path)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $entries[0].Hash) { throw "Approved source changed: '$name'." }
    $approved[$name] = $bytes
    "${name}:$($entries[0].Hash)"
}
$fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).ToLowerInvariant()
if ($fingerprint -cne $data.hash) { throw 'The approved installation fingerprint changed.' }
if ($VerifyOnly) { return [pscustomobject]@{ verified = $true; fileCount = $approved.Count; hash = $fingerprint } }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Installation requires explicit administrator approval.'
    }
}
finally { $identity.Dispose() }
$paths = Get-MemLabsControlPaths -ClientSid $data.clientSid
$attempt = ([guid]$data.attemptId).ToString('D')
$resultPath = Join-Path $paths.RuntimeRoot "install-$attempt.json"
$context = [pscustomobject]@{
    PackagePath = Join-Path $paths.InstallRoot "Packages\$fingerprint"
    StagingPath = $null
    Broker = $null
    Failure = $null
}
function Publish-MemLabsControlPackage {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Approved, [Parameter(Mandatory)][Collections.IDictionary]$Data)

    if (Test-Path -LiteralPath $Context.PackagePath) {
        Assert-MemLabsControlPackage -Path $Context.PackagePath -Hash $Data.hash
        return
    }
    $staging = Join-Path $Paths.InstallRoot ('Packages\.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        New-MemLabsControlProtectedDirectory -Path $staging
        foreach ($name in $Approved.Keys) {
            $target = Join-Path $staging $name
            [IO.File]::WriteAllBytes($target, $Approved[$name])
            $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            Set-Acl -LiteralPath $target -AclObject $acl -ErrorAction Stop
            Assert-MemLabsControlProtectedPath -Path $target -Boundary $Paths.InstallRoot
            $expected = @($Data.files | Where-Object Name -CEQ $name)[0].Hash
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -cne $expected) { throw "Staged file failed verification: '$name'." }
        }
        Write-MemLabsControlJson -Path (Join-Path $staging 'package.json') -Value @{
            hash = $Data.hash; files = @($Data.files | ForEach-Object { @{ name = $_.Name; hash = $_.Hash } })
        }
        [IO.Directory]::Move($staging, $Context.PackagePath)
        $staging = $null
        Assert-MemLabsControlPackage -Path $Context.PackagePath -Hash $Data.hash
    }
    finally {
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            if ([IO.Path]::GetFileName($staging) -cnotmatch '^\.staging-[a-f0-9]{32}$') { throw 'Unexpected staging cleanup identity.' }
            Assert-MemLabsControlProtectedPath -Path $staging -Boundary $Paths.InstallRoot
            [IO.Directory]::Delete($staging, $true)
        }
    }
}

$publish = ${function:Publish-MemLabsControlPackage}
$operation = {
    try {
        foreach ($directory in @((Split-Path -Parent $paths.InstallRoot), $paths.InstallRoot, (Join-Path $paths.InstallRoot 'Packages'))) {
            New-MemLabsControlProtectedDirectory -Path $directory
        }
        & $publish -Paths $paths -Context $context -Approved $approved -Data $data
        $runtimeFileExists = Test-Path -LiteralPath $paths.RuntimeFile
        if ($runtimeFileExists) {
            $old = Get-Content -LiteralPath $paths.RuntimeFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $existing = Get-Process -Id $old.pid -ErrorAction SilentlyContinue
            if ($existing -and $existing.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $old.startFileTime -and $old.state -ne 'Stopped') {
                throw 'A worker is already running. Stop it explicitly before replacing it.'
            }
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $paths.PowerShell -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') { throw 'PowerShell must have a valid Microsoft signature.' }
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + (Join-Path $context.PackagePath 'Invoke-ControlBroker.ps1') + '"'),
            '-ClientSid', $data.clientSid, '-PackageHash', $fingerprint)
        $context.Broker = Start-Process -FilePath $paths.PowerShell -ArgumentList $arguments -WorkingDirectory $context.PackagePath `
            -RedirectStandardOutput (Join-Path $paths.RuntimeRoot 'worker.stdout.log') `
            -RedirectStandardError (Join-Path $paths.RuntimeRoot 'worker.stderr.log') -WindowStyle Hidden -PassThru -ErrorAction Stop
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        do {
            $context.Broker.Refresh()
            if ($context.Broker.HasExited) { throw "Worker startup failed. Inspect '$($paths.RuntimeRoot)\worker.stderr.log'." }
            if (Test-Path -LiteralPath $paths.RuntimeFile) {
                $runtime = Get-Content -LiteralPath $paths.RuntimeFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($runtime.pid -eq $context.Broker.Id -and $runtime.state -eq 'Ready' -and $runtime.packageHash -ceq $fingerprint) { return }
            }
            Start-Sleep -Milliseconds 100
        } while ([datetime]::UtcNow -lt $deadline)
        throw 'Worker readiness was not verified within 30 seconds; inspect its protected logs.'
    }
    catch { $context.Failure = $_.Exception.Message; throw }
}.GetNewClosure()
$postcondition = {
    $runtime = Get-Content -LiteralPath $paths.RuntimeFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    return [bool]($context.Broker -and $runtime.pid -eq $context.Broker.Id -and $runtime.state -eq 'Ready' -and $runtime.packageHash -ceq $fingerprint)
}.GetNewClosure()
$diagnostics = { [pscustomobject]@{ failure = $context.Failure; packagePath = $context.PackagePath; runtimeDirectory = $paths.RuntimeRoot } }.GetNewClosure()
try {
    $coordinator = [scriptblock]::Create([Text.Encoding]::UTF8.GetString($approved['Invoke-MemLabsLiveOperation.ps1']))
    $result = & $coordinator -Mode Mutate -Intent 'Install the frozen Copilot Control package and verify readiness' `
        -TargetType HostResource -Target @('MemLabs:CopilotControl', "Owner:$($data.clientSid)") `
        -Operation $operation -Postcondition $postcondition -FailureDiagnostics $diagnostics
    $answer = @{ attemptId = $attempt; success = $true; state = 'Ready'; pid = $context.Broker.Id; packageHash = $fingerprint; journalOperationId = $result.OperationId }
    Write-MemLabsControlJson -Path $resultPath -Value $answer
    [pscustomobject]$answer
}
catch {
    $message = if ($context.Failure) { $context.Failure } else { $_.Exception.Message }
    throw "Copilot Control installation failed: $message"
}
