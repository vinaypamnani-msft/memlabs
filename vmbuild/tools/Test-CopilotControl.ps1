#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $PSScriptRoot),
    [switch]$PipeWorker,
    [string]$PipeName,
    [string]$PipeOwnerSid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$controlRoot = Join-Path $RootPath 'control'
. (Join-Path $controlRoot 'Common.Control.ps1')
Initialize-MemLabsControlTransport

if ($PipeWorker) {
    $sid = if ($PipeOwnerSid) { $PipeOwnerSid } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $listener = [MemLabs.Control.Listener]::new($PipeName, $sid)
    try {
        $self = Get-Process -Id $PID -ErrorAction Stop
        [Console]::Out.WriteLine((@{ pid = $PID; started = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() } | ConvertTo-Json -Compress))
        [Console]::Out.Flush()
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        while (-not $listener.Ready -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
        if (-not $listener.Ready) { throw 'The test pipe did not receive a connection.' }
        $request = $listener.ReadRequest()
        $listener.Respond('{"echo":' + ($request | ConvertTo-Json -Compress) + '}')
    }
    finally { $listener.Dispose() }
    exit 0
}

$script:Assertions = 0
function Assert-Control {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw "FAIL: $Message" }
    [Console]::WriteLine("PASS: $Message")
}
function Assert-ControlThrows {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    Assert-Control -Condition ($null -ne $caught -and $caught.Exception.Message -match $Pattern) -Message $Message
}
function New-TestProcessInfo {
    param([string]$Script)
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Script)) { $info.ArgumentList.Add($argument) }
    return $info
}
function Import-ControlTestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0] }
    $node = $ast.Find({
            param($candidate)
            $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
        }, $true)
    if ($null -eq $node) { throw "Required test function not found: $Name" }
    return [scriptblock]::Create($node.Extent.Text)
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-control-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $fixture -ItemType Directory -ErrorAction Stop
try {
    $id = [guid]::NewGuid().ToString('D')
    foreach ($method in @('status', 'shutdown')) {
        Assert-MemLabsControlArguments -Method $method -Arguments @{}
    }
    Assert-MemLabsControlArguments -Method inventory -Arguments @{ limit = 100; offset = 0 }
    Assert-MemLabsControlArguments -Method start_vm -Arguments @{ vmId = $id }
    Assert-MemLabsControlArguments -Method stop_vm -Arguments @{ vmId = $id; confirm = $true }
    Assert-MemLabsControlArguments -Method operation -Arguments @{ operationId = $id }
    Assert-Control -Condition $true -Message 'The fixed valid request shapes are accepted'
    foreach ($case in @(
            @{ Method = 'run'; Arguments = @{ script = 'Get-Process' }; Pattern = 'Unsupported' },
            @{ Method = 'STATUS'; Arguments = @{}; Pattern = 'Unsupported' },
            @{ Method = 'start_vm'; Arguments = @{ vmId = '*' }; Pattern = 'GUID' },
            @{ Method = 'start_vm'; Arguments = @{ vmId = [guid]::Empty.ToString('D') }; Pattern = 'GUID' },
            @{ Method = 'start_vm'; Arguments = @{ vmId = $id; script = 'anything' }; Pattern = 'Unexpected' },
            @{ Method = 'stop_vm'; Arguments = @{ vmId = $id; confirm = $false }; Pattern = 'confirm=true' },
            @{ Method = 'stop_vm'; Arguments = @{ vmId = $id; confirm = 'true' }; Pattern = 'confirm=true' },
            @{ Method = 'stop_vm'; Arguments = @{ vmId = $id; confirm = $true; force = $true }; Pattern = 'Unexpected' },
            @{ Method = 'inventory'; Arguments = @{ limit = 101 }; Pattern = 'range' },
            @{ Method = 'inventory'; Arguments = @{ offset = -1 }; Pattern = 'range' },
            @{ Method = 'inventory'; Arguments = @{ limit = '10' }; Pattern = 'integer' }
        )) {
        Assert-ControlThrows -Action { Assert-MemLabsControlArguments -Method $case.Method -Arguments $case.Arguments } `
            -Pattern $case.Pattern -Message "Rejected unsafe $($case.Method) parameters: $($case.Arguments.Keys -join ',')"
    }

    $self = Get-Process -Id $PID -ErrorAction Stop
    $currentIdentity = @{ pid = $PID; startFileTime = $self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() }
    Assert-Control -Condition (Test-MemLabsControlWorkerAlive -Runtime $currentIdentity) -Message 'Worker liveness matches both the current PID and its creation time'
    Assert-Control -Condition (-not (Test-MemLabsControlWorkerAlive -Runtime @{ pid = $PID; startFileTime = '1' })) -Message 'A reused PID does not keep a stale worker record alive'
    Assert-Control -Condition (-not (Test-MemLabsControlWorkerAlive -Runtime @{ pid = [int]::MaxValue; startFileTime = '1' })) -Message 'A proven absent worker is recoverable without deleting protected state'
    Assert-ControlThrows -Action { Test-MemLabsControlWorkerAlive -Runtime @{ pid = 'not-a-pid'; startFileTime = '1' } } `
        -Pattern 'invalid process identity' -Message 'Invalid worker metadata is not silently treated as a stopped process'
    $cancelled = Get-MemLabsControlFailure -Exception ([InvalidOperationException]::new('Outer fixture', [ComponentModel.Win32Exception]::new(1223)))
    Assert-Control -Condition ($cancelled.code -eq 'ElevationCancelled' -and -not $cancelled.automaticRetry -and
        $cancelled.message -like '*no new control worker*' -and $cancelled.remediation -like '*Back*stopped*') `
        -Message 'Canceled elevation is explained clearly and never triggers an automatic retry'

    & {
        $pipeProbe = [pscustomobject]@{ Calls = 0; Sleeps = 0; Mode = 'timeout-then-ready' }
        function Get-MemLabsControlPaths { [pscustomobject]@{ PipeName = 'fixture' } }
        function Get-MemLabsControlRuntime { @{ pid = 123; startFileTime = '1' } }
        function Initialize-MemLabsControlTransport {}
        function Start-Sleep {
            param([int]$Milliseconds)
            if ($Milliseconds -notin @(100, 200)) { throw 'Unexpected connection retry delay.' }
            $pipeProbe.Sleeps++
        }
        function Invoke-MemLabsControlPipeExchange {
            param($Paths, $Runtime, [string]$Request, [int]$TimeoutMilliseconds)
            if ($Paths.PipeName -ne 'fixture' -or $Runtime.pid -ne 123 -or $TimeoutMilliseconds -ne 5000) { throw 'Unexpected transport fixture arguments.' }
            $pipeProbe.Calls++
            if ($pipeProbe.Mode -eq 'denied') { throw [UnauthorizedAccessException]::new('Synthetic access denied') }
            if ($pipeProbe.Mode -eq 'bad-frame') { throw [IO.InvalidDataException]::new('Synthetic invalid frame') }
            if ($pipeProbe.Mode -eq 'always-timeout' -or $pipeProbe.Calls -lt 3) { throw [TimeoutException]::new('Synthetic pipe readiness delay') }
            $requestObject = $Request | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            return (@{ version = 1; id = $requestObject.id; ok = $true; result = @{ state = 'Ready' } } | ConvertTo-Json -Depth 5 -Compress)
        }
        $ready = Invoke-MemLabsControlRequest -Method status
        Assert-Control -Condition ($ready.state -eq 'Ready' -and $pipeProbe.Calls -eq 3 -and $pipeProbe.Sleeps -eq 2) -Message 'Read-only readiness checks recover from bounded transient pipe failures'
        foreach ($mode in @('denied', 'bad-frame', 'always-timeout')) {
            $pipeProbe.Mode = $mode; $pipeProbe.Calls = 0; $pipeProbe.Sleeps = 0
            Assert-ControlThrows -Action { Invoke-MemLabsControlRequest -Method status } `
                -Pattern 'Synthetic' -Message "$mode status failure remains visible"
            $expectedCalls = if ($mode -eq 'always-timeout') { 3 } else { 1 }
            Assert-Control -Condition ($pipeProbe.Calls -eq $expectedCalls) -Message "$mode retries remain bounded and never retry permission or integrity failures"
        }
        foreach ($method in @('start_vm', 'stop_vm', 'shutdown')) {
            $pipeProbe.Mode = 'always-timeout'; $pipeProbe.Calls = 0; $pipeProbe.Sleeps = 0
            $arguments = if ($method -eq 'start_vm') { @{ vmId = $id } } elseif ($method -eq 'stop_vm') { @{ vmId = $id; confirm = $true } } else { @{} }
            Assert-ControlThrows -Action { Invoke-MemLabsControlRequest -Method $method -Arguments $arguments } `
                -Pattern 'Synthetic pipe' -Message "An uncertain $method response is reported instead of replaying the mutation"
            Assert-Control -Condition ($pipeProbe.Calls -eq 1 -and $pipeProbe.Sleeps -eq 0) -Message "$method is never automatically retried"
        }
    }

    $adapter = Join-Path $controlRoot 'Invoke-ControlMcp.ps1'
    $workspace = Join-Path $fixture 'workspace'
    $vscodeDirectory = Join-Path $workspace '.vscode'
    $null = New-Item -Path $vscodeDirectory -ItemType Directory -ErrorAction Stop
    $vscode = Join-Path $vscodeDirectory 'mcp.json'
    $rootMcp = Join-Path $workspace '.mcp.json'
    $originalCode = @'
{
  // preserve this VS Code comment and input
  "inputs": [{ "id": "test-key", "type": "promptString", "description": "Fixture only" }],
  "servers": {
    "wiremcp": { "type": "stdio", "command": "node", "args": ["C:\\fixture\\wire.js"] }, // trailing comma
  },
}
'@
    $originalRoot = '{"mcpServers":{"wiremcp":{"command":"node","args":["wire.js"]}},"custom":{"keep":true}}'
    [IO.File]::WriteAllText($vscode, $originalCode)
    [IO.File]::WriteAllText($rootMcp, $originalRoot)
    $registration = @(Add-MemLabsControlMcpConfiguration -RepositoryRoot $workspace -AdapterPath $adapter)
    Assert-Control -Condition ($registration.Count -eq 2 -and @($registration | Where-Object Added).Count -eq 2) -Message 'Start registers both VS Code and Copilot configuration shapes'
    $updatedCode = [IO.File]::ReadAllText($vscode)
    $parsedCode = $updatedCode | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $parsedRoot = Get-Content -LiteralPath $rootMcp -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Assert-Control -Condition ($updatedCode.Contains('// preserve this VS Code comment and input') -and $updatedCode.Contains('// trailing comma')) -Message 'JSONC comments and trailing-comma syntax survive insertion'
    Assert-Control -Condition ($parsedCode.inputs[0].id -eq 'test-key' -and $parsedCode.servers.wiremcp.args[0] -eq 'C:\fixture\wire.js') -Message 'Existing inputs, WireMCP command and arguments are preserved'
    Assert-Control -Condition ($parsedRoot.custom.keep -and $parsedRoot.mcpServers.wiremcp.command -eq 'node') -Message 'Root MCP custom fields and other servers are preserved'
    Assert-Control -Condition ([IO.File]::ReadAllText($vscode + '.memlabs-control.bak') -ceq $originalCode) -Message 'The original editor configuration is backed up exactly'
    $before = @((Get-FileHash -LiteralPath $vscode -Algorithm SHA256).Hash, (Get-FileHash -LiteralPath $rootMcp -Algorithm SHA256).Hash)
    $repeat = @(Add-MemLabsControlMcpConfiguration -RepositoryRoot $workspace -AdapterPath $adapter)
    Assert-Control -Condition (@($repeat | Where-Object Added).Count -eq 0 -and
        (Get-FileHash -LiteralPath $vscode -Algorithm SHA256).Hash -ceq $before[0] -and
        (Get-FileHash -LiteralPath $rootMcp -Algorithm SHA256).Hash -ceq $before[1]) -Message 'Repeated Start leaves identical MCP files byte-for-byte unchanged'
    Assert-ControlThrows -Action { Add-MemLabsControlMcpConfiguration -RepositoryRoot $workspace -AdapterPath 'C:\different\adapter.ps1' } `
        -Pattern 'not overwritten' -Message 'Conflicting MemLabs registrations are not overwritten'
    Assert-Control -Condition ((Get-FileHash -LiteralPath $vscode -Algorithm SHA256).Hash -ceq $before[0]) -Message 'Registration failure preserves the existing editor file'

    foreach ($text in @('{}', '{ /* retained */ "servers": {} }', '{"inputs":[]}', '{"servers":{"one":{"command":"x"},"two":[1,2],},"other":42}')) {
        $merged = [MemLabs.Control.Transport]::AddJsonEntry($text, 'servers', 'memlabs', '{"command":"pwsh"}')
        $parsed = $merged | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        Assert-Control -Condition ($parsed.servers.memlabs.command -eq 'pwsh') -Message 'JSONC insertion handles empty, absent, nested and trailing-comma objects'
    }
    Assert-ControlThrows -Action { [MemLabs.Control.Transport]::AddJsonEntry('{"servers":[]}', 'servers', 'memlabs', '{}') } `
        -Pattern 'must be an object' -Message 'Malformed server-map types are rejected'
    $invalidWorkspace = Join-Path $fixture 'invalid'
    $null = New-Item -Path (Join-Path $invalidWorkspace '.vscode') -ItemType Directory -ErrorAction Stop
    $invalidPath = Join-Path $invalidWorkspace '.vscode\mcp.json'
    [IO.File]::WriteAllText($invalidPath, '{"servers":not-json}')
    Assert-ControlThrows -Action { Add-MemLabsControlMcpConfiguration -RepositoryRoot $invalidWorkspace -AdapterPath $adapter } `
        -Pattern 'JSON|json' -Message 'Malformed existing JSON is reported, not reset'
    Assert-Control -Condition ([IO.File]::ReadAllText($invalidPath) -ceq '{"servers":not-json}') -Message 'Malformed configuration remains untouched'

    $lockedWorkspace = Join-Path $fixture 'locked'
    $null = New-Item -Path (Join-Path $lockedWorkspace '.vscode') -ItemType Directory -ErrorAction Stop
    $lockedPath = Join-Path $lockedWorkspace '.vscode\mcp.json'
    [IO.File]::WriteAllText($lockedPath, $originalCode)
    $competingEditor = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-ControlThrows -Action { Add-MemLabsControlMcpConfiguration -RepositoryRoot $lockedWorkspace -AdapterPath $adapter } `
            -Pattern 'being used|another process|sharing' -Message 'A competing editor writer is rejected instead of losing its configuration'
    }
    finally { $competingEditor.Dispose() }
    Assert-Control -Condition ([IO.File]::ReadAllText($lockedPath) -ceq $originalCode) -Message 'Writer contention leaves the original bytes intact'
    $null = Add-MemLabsControlMcpConfiguration -RepositoryRoot $lockedWorkspace -AdapterPath $adapter
    Assert-Control -Condition ((Get-Content -LiteralPath $lockedPath -Raw | ConvertFrom-Json -AsHashtable).servers.Contains('memlabs')) -Message 'Registration recovers after the competing editor releases its handle'

    $package = Get-MemLabsControlPackage
    $payload = @{ hash = $package.Hash; files = $package.Files; clientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; attemptId = [guid]::NewGuid().ToString('D') }
    $verified = & (Join-Path $controlRoot 'Install-Control.ps1') -Payload ($payload | ConvertTo-Json -Depth 8 -Compress) -VerifyOnly
    Assert-Control -Condition ($verified.verified -and $verified.fileCount -eq 8) -Message 'The bootstrap verifies all eight approved files before installation or script execution'
    $loader = New-MemLabsControlBootstrap -Package $package -ClientSid $payload.clientSid -AttemptId ([guid]$payload.attemptId)
    Assert-Control -Condition ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loader)).Length -le 30000) -Message 'The frozen in-memory UAC bootstrap fits the Windows command-line limit'
    foreach ($targetName in @('Start-Control.ps1', 'Common.Control.ps1', 'Invoke-MemLabsLiveOperation.ps1')) {
        $changed = Join-Path $fixture $targetName
        $sourceEntry = @($package.Files | Where-Object Name -eq $targetName)[0]
        [IO.File]::WriteAllBytes($changed, [IO.File]::ReadAllBytes($sourceEntry.Path))
        $marker = Join-Path $fixture ($targetName + '.executed')
        [IO.File]::AppendAllText($changed, ("`n[IO.File]::WriteAllText('" + $marker.Replace("'", "''") + "','unexpected')"))
        $badFiles = @($package.Files | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Hash = $_.Hash; Path = $(if ($_.Name -eq $targetName) { $changed } else { $_.Path }) }
            })
        $badPayload = @{ hash = $package.Hash; files = $badFiles }
        Assert-ControlThrows -Action {
            & (Join-Path $controlRoot 'Install-Control.ps1') -Payload ($badPayload | ConvertTo-Json -Depth 8 -Compress) -VerifyOnly
        } -Pattern 'Approved source changed' -Message "Changed $targetName is rejected before its marker executes"
        Assert-Control -Condition (-not (Test-Path -LiteralPath $marker)) -Message 'The unapproved script was never executed'
    }

    & {
        $tokens = $null
        $errors = $null
        $installerAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $controlRoot 'Install-Control.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw $errors[0] }
        $callbackDefinitions = foreach ($name in @('operation', 'postcondition', 'diagnostics')) {
            $assignment = $installerAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq $name
                }, $true)
            if ($null -eq $assignment) { throw "The shipped installer callback '$name' was not found." }
            [scriptblock]::Create($assignment.Extent.Text)
        }
        function Invoke-UiInstallerScopeFixture {
            param([bool]$FailPublication)

            $caseRoot = Join-Path $fixture ('ui-installer-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -Path $caseRoot -ItemType Directory -ErrorAction Stop
            $paths = [pscustomobject]@{
                InstallRoot = Join-Path $caseRoot 'installed'
                RuntimeRoot = $caseRoot
                RuntimeFile = Join-Path $caseRoot 'runtime.json'
                PowerShell = 'C:\fixture\pwsh.exe'
            }
            $data = @{ clientSid = 'S-1-5-21-1-2-3-1234'; hash = 'a' * 64 }
            $fingerprint = $data.hash
            $approved = @{}
            $context = [pscustomobject]@{ PackagePath = Join-Path $paths.InstallRoot 'package'; Broker = $null; Failure = $null }
            $scopeState = [pscustomobject]@{ DirectoryCalls = 0; PackageChecks = 0; WorkerStarts = 0 }
            function New-MemLabsControlProtectedDirectory {
                param([string]$Path)
                if (-not $Path.StartsWith($caseRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and $Path -ne $caseRoot) {
                    throw 'The installer fixture escaped its isolated path.'
                }
                $scopeState.DirectoryCalls++
            }
            function Assert-MemLabsControlPackage {
                param([string]$Path, [string]$Hash)
                if ($Path -ne $context.PackagePath -or $Hash -cne $fingerprint) { throw 'Unexpected publication identity.' }
                $scopeState.PackageChecks++
            }
            function Publish-MemLabsControlPackage {
                param($Paths, $Context, $Approved, $Data)
                if ($Paths.RuntimeFile -ne $paths.RuntimeFile -or $Approved.Count -ne 0) { throw 'Unexpected publication arguments.' }
                Assert-MemLabsControlPackage -Path $Context.PackagePath -Hash $Data.hash
                if ($FailPublication) { throw 'Synthetic locally scoped publication failure' }
            }
            function Get-AuthenticodeSignature {
                [CmdletBinding()]
                param([string]$LiteralPath)
                if ($LiteralPath -ne $paths.PowerShell) { throw 'Unexpected executable lookup.' }
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'O=Microsoft Corporation' } }
            }
            function Start-Process {
                [CmdletBinding()]
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError,
                    $WindowStyle, [switch]$PassThru)
                if ($FilePath -ne $paths.PowerShell -or $WorkingDirectory -ne $context.PackagePath -or -not $PassThru -or
                    $WindowStyle -ne 'Hidden' -or $ArgumentList -notcontains '-ClientSid' -or
                    $RedirectStandardOutput -ne (Join-Path $paths.RuntimeRoot 'worker.stdout.log') -or
                    $RedirectStandardError -ne (Join-Path $paths.RuntimeRoot 'worker.stderr.log')) { throw 'Unexpected worker launch arguments.' }
                $scopeState.WorkerStarts++
                [IO.File]::WriteAllText($paths.RuntimeFile,
                    (@{ pid = 987654; state = 'Ready'; packageHash = $fingerprint } | ConvertTo-Json -Compress))
                $process = [pscustomobject]@{ Id = 987654; HasExited = $false }
                $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
                return $process
            }
            $publish = ${function:Publish-MemLabsControlPackage}
            if ($publish -isnot [scriptblock]) { throw 'The local publication helper was not captured for the shipped callback.' }
            foreach ($definition in $callbackDefinitions) { . $definition }
            $caught = $null
            try { & $operation }
            catch { $caught = $_ }
            if ($FailPublication) {
                $failure = & $diagnostics
                Assert-Control -Condition ($null -ne $caught -and $failure.failure -eq 'Synthetic locally scoped publication failure' -and
                    $scopeState.WorkerStarts -eq 0) -Message 'Nested elevated-UI callbacks retain the actual publication failure without starting a worker'
            }
            else {
                if ($caught) { throw $caught }
                $observed = @(& $postcondition)
                Assert-Control -Condition ($scopeState.DirectoryCalls -eq 3 -and $scopeState.PackageChecks -eq 1 -and
                    $scopeState.WorkerStarts -eq 1 -and $observed.Count -eq 1 -and $observed[0] -is [bool] -and $observed[0]) `
                    -Message 'Nested elevated-UI installer callbacks can resolve local bootstrap helpers and verify worker readiness'
            }
        }
        Invoke-UiInstallerScopeFixture -FailPublication $false
        Invoke-UiInstallerScopeFixture -FailPublication $true
    }

    & {
        $probe = [pscustomobject]@{ VmReads = 0; JobsStarted = 0 }
        $vmFixtureId = [guid]$id
        function Get-VM {
            [CmdletBinding()]
            param([guid]$Id)
            $probe.VmReads++
            $hasId = $PSBoundParameters.ContainsKey('Id')
            @(
                [pscustomobject]@{ Id = $vmFixtureId; Name = 'VM [test]'; State = 'Off'; MemoryAssigned = 0; CPUUsage = 0 },
                [pscustomobject]@{ Id = [guid]::NewGuid(); Name = 'VM [test]'; State = 'Off'; MemoryAssigned = 0; CPUUsage = 0 }
            ) | Where-Object { -not $hasId -or $_.Id -eq $Id }
        }
        function New-MemLabsControlOperationJob {
            param($State, $Method, [guid]$VmId, [guid]$OperationId)
            if ($VmId -ne [guid]$id -or $Method -notin @('start_vm', 'stop_vm')) { throw 'Unexpected operation arguments.' }
            $probe.JobsStarted++
            [pscustomobject]@{ Id = $OperationId.ToString('D'); Shell = $null; Async = [pscustomobject]@{ IsCompleted = $false } }
        }
        $workerState = [pscustomobject]@{
            Active = $null; Stopping = $false; History = [ordered]@{}
            Runtime = [ordered]@{ state = 'Ready'; activeOperation = $null }
            ClientSid = $payload.clientSid; PackagePath = $controlRoot; PackageHash = $package.Hash
        }
        $inventory = Invoke-MemLabsControlDispatch -State $workerState -Method inventory -Arguments @{ limit = 1 }
        Assert-Control -Condition ($inventory.items.Count -eq 1 -and $inventory.total -eq 2 -and $inventory.nextOffset -eq 1) -Message 'Inventory paging retains duplicate/bracketed names without treating them as VM identity'
        $accepted = Invoke-MemLabsControlDispatch -State $workerState -Method start_vm -Arguments @{ vmId = $id }
        Assert-Control -Condition ($accepted.state -eq 'Running' -and $probe.JobsStarted -eq 1 -and $workerState.Runtime.state -eq 'Busy') -Message 'Exact-GUID dispatch starts one tracked asynchronous operation'
        $reads = $probe.VmReads
        foreach ($method in @('inventory', 'shutdown', 'start_vm', 'stop_vm')) {
            $arguments = if ($method -eq 'start_vm') { @{ vmId = $id } } elseif ($method -eq 'stop_vm') { @{ vmId = $id; confirm = $true } } else { @{} }
            Assert-ControlThrows -Action { Invoke-MemLabsControlDispatch -State $workerState -Method $method -Arguments $arguments } `
                -Pattern 'busy' -Message "Busy worker rejects $method without disturbing its active job"
        }
        Assert-Control -Condition ($probe.VmReads -eq $reads -and $probe.JobsStarted -eq 1 -and -not $workerState.Stopping) -Message 'Busy rejections execute no VM commands and do not request shutdown'
        Assert-Control -Condition ((Invoke-MemLabsControlDispatch -State $workerState -Method status).state -eq 'Busy' -and
            (Invoke-MemLabsControlDispatch -State $workerState -Method operation -Arguments @{ operationId = $accepted.operationId }).state -eq 'Running') -Message 'Status and operation results remain responsive while Busy'
        foreach ($failure in @('unsuccessful', 'throwing', 'malformed')) {
            $shell = [pscustomobject]@{
                HadErrors = $false; Streams = [pscustomobject]@{ Error = @() }; Disposed = $false
                Failure = $failure; Value = [pscustomobject]@{ success = $false; error = 'Synthetic failed postcondition' }
            }
            $shell | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {
                param($Handle)
                if ($this.Failure -eq 'throwing') { throw 'Synthetic worker failure' }
                if ($this.Failure -eq 'malformed') { return @('not', 'one-envelope') }
                return $this.Value
            }
            $shell | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
            $workerState.Active = [pscustomobject]@{ Id = [guid]::NewGuid().ToString('D'); Shell = $shell; Async = [pscustomobject]@{ IsCompleted = $true } }
            $completion = Complete-MemLabsControlOperation -State $workerState
            Assert-Control -Condition ($completion.state -eq 'Failed' -and -not $completion.result.success -and $shell.Disposed -and
                $null -eq $workerState.Active -and $workerState.Runtime.state -eq 'Ready') -Message "$failure completion remains a failure, releases its runspace, and restores Ready"
        }
        $retry = Invoke-MemLabsControlDispatch -State $workerState -Method stop_vm -Arguments @{ vmId = $id; confirm = $true }
        Assert-Control -Condition ($retry.state -eq 'Running' -and $probe.JobsStarted -eq 2) -Message 'A new operation can be accepted after the failed operation is cleaned up'
    }

    & {
        . (Import-ControlTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsLiveOperation.ps1') -Name 'Test-LiveOpsConflictingCommandLine')
        . (Import-ControlTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsLiveOperation.ps1') -Name 'Get-LiveOpsConflictingProcesses')
        $mockProcesses = @(
            [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 400001; Name = 'pwsh.exe'; CommandLine = '-File Invoke-ControlBroker.ps1'; CreationDate = Get-Date },
            [pscustomobject]@{ ProcessId = 400001; ParentProcessId = 0; Name = 'pwsh.exe'; CommandLine = 'pwsh -NoExit -Command ./New-Lab.ps1'; CreationDate = Get-Date }
        )
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            $mockProcesses
        }
        Assert-Control -Condition (@(Get-LiveOpsConflictingProcesses).Count -eq 0) -Message 'A worker launched directly by the persistent idle UI remains coordinated after installation returns'
        $mockProcesses += [pscustomobject]@{ ProcessId = 400002; ParentProcessId = 0; Name = 'pwsh.exe'; CommandLine = 'pwsh -File C:\memlabs\vmbuild\New-Lab.ps1'; CreationDate = Get-Date }
        Assert-Control -Condition (@(Get-LiveOpsConflictingProcesses).Count -eq 1) -Message 'A genuinely separate deployment still blocks mutations; no process-check bypass is used'
    }

    & {
        $policy = [pscustomobject]@{ Owner = 'S-1-5-21-1-2-3-1234'; Writer = 'S-1-5-18' }
        function Get-Acl {
            [CmdletBinding()]
            param([string]$LiteralPath)
            if (-not (Test-Path -LiteralPath $LiteralPath)) { throw 'Unexpected ACL fixture path.' }
            $security = [Security.AccessControl.FileSecurity]::new()
            $security.SetOwner([Security.Principal.SecurityIdentifier]::new($policy.Owner))
            $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new($policy.Writer),
                    [Security.AccessControl.FileSystemRights]::Write, [Security.AccessControl.AccessControlType]::Allow))
            return $security
        }
        Assert-ControlThrows -Action { Assert-MemLabsControlProtectedPath -Path $fixture -Boundary $fixture } `
            -Pattern 'untrusted owner' -Message 'Worker trust rejects an operator-owned installation boundary'
        $policy.Owner = 'S-1-5-32-544'
        $policy.Writer = 'S-1-5-32-545'
        Assert-ControlThrows -Action { Assert-MemLabsControlProtectedPath -Path $fixture -Boundary $fixture } `
            -Pattern 'writable outside' -Message 'Worker trust rejects write access granted to ordinary users'
        $policy.Writer = 'S-1-5-18'
        Assert-MemLabsControlProtectedPath -Path $fixture -Boundary $fixture
        Assert-Control -Condition $true -Message 'Trusted owner and SYSTEM-only write policy is accepted'
    }
    $junction = Join-Path $fixture 'junction'
    $junctionTarget = Join-Path $fixture 'junction-target'
    $null = New-Item -Path $junctionTarget -ItemType Directory -ErrorAction Stop
    $null = New-Item -Path $junction -ItemType Junction -Target $junctionTarget -ErrorAction Stop
    try {
        Assert-ControlThrows -Action { Assert-MemLabsControlNoReparsePoint -Path (Join-Path $junction 'child') } `
            -Pattern 'Reparse points' -Message 'Worker trust rejects a reparse point in an installation ancestor'
    }
    finally { Remove-Item -LiteralPath $junction -Force -ErrorAction Stop }

    & {
        . (Import-ControlTestFunction -Path (Join-Path $controlRoot 'Install-Control.ps1') -Name 'Publish-MemLabsControlPackage')
        $fault = [pscustomobject]@{ At = 1; Seen = 0 }
        function New-MemLabsControlProtectedDirectory { param([string]$Path) $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop }
        function Assert-MemLabsControlProtectedPath { param([string]$Path, [string]$Boundary) if (-not $Path.StartsWith($Boundary)) { throw 'Fixture escaped its root.' } }
        function Assert-MemLabsControlPackage {
            param([string]$Path, [string]$Hash)
            $receipt = Get-Content -LiteralPath (Join-Path $Path 'package.json') -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($receipt.hash -cne $Hash -or $receipt.files.Count -ne 8) { throw 'Invalid fixture receipt.' }
        }
        function Get-Acl { [CmdletBinding()]param([string]$LiteralPath) [Security.AccessControl.FileSecurity]::new() }
        function Set-Acl { [CmdletBinding()]param([string]$LiteralPath, $AclObject) }
        function Get-FileHash {
            [CmdletBinding()]
            param([string]$LiteralPath, [string]$Algorithm)
            $fault.Seen++
            if ($fault.At -gt 0 -and $fault.Seen -eq $fault.At) { throw 'Synthetic interrupted package copy' }
            Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm -ErrorAction Stop
        }
        foreach ($position in @(1, 3)) {
            $installRoot = Join-Path $fixture "package-$position"
            $null = New-Item -Path (Join-Path $installRoot 'Packages') -ItemType Directory -ErrorAction Stop
            $fixturePaths = [pscustomobject]@{ InstallRoot = $installRoot }
            $fixtureContext = [pscustomobject]@{ PackagePath = Join-Path $installRoot "Packages\$($package.Hash)" }
            $approved = @{}
            foreach ($file in $package.Files) { $approved[$file.Name] = [IO.File]::ReadAllBytes($file.Path) }
            $fault.At = $position; $fault.Seen = 0
            Assert-ControlThrows -Action { Publish-MemLabsControlPackage -Paths $fixturePaths -Context $fixtureContext -Approved $approved -Data $payload } `
                -Pattern 'interrupted package copy' -Message "Interrupted copy at file $position is reported"
            Assert-Control -Condition (-not (Test-Path -LiteralPath $fixtureContext.PackagePath) -and
                @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'Packages') -Force).Count -eq 0) -Message 'Failure publishes no incomplete hash directory and removes its staging data'
            $fault.At = 0; $fault.Seen = 0
            Publish-MemLabsControlPackage -Paths $fixturePaths -Context $fixtureContext -Approved $approved -Data $payload
            Assert-Control -Condition (Test-Path -LiteralPath (Join-Path $fixtureContext.PackagePath 'package.json')) -Message 'Retry of the same version succeeds after the copy fault is removed'
        }
    }

    & {
        . (Import-ControlTestFunction -Path (Join-Path $RootPath 'genconfig.ps1') -Name 'Select-ToolsMenu')
        $global:Common = [pscustomobject]@{ Colors = [pscustomobject]@{ GenConfigNonDefault = 'White'; GenConfigNonDefaultNumber = 'White' } }
        $menu = [pscustomobject]@{ Index = 0; Choices = @('m', 's', 'x', '1', '2', 'ESCAPE'); Actions = @(); ToolModes = @() }
        function Get-Menu2 {
            param($MenuName, $Prompt, $AdditionalOptions, [switch]$NoNewLine, [bool]$test, [switch]$return)
            if ($MenuName -ne 'Tools Menu' -or -not $Prompt -or -not $AdditionalOptions.Contains('M') -or -not $AdditionalOptions.Contains('X')) {
                throw 'Expected existing Tools menu and Copilot controls.'
            }
            $choice = $menu.Choices[$menu.Index]
            $menu.Index++
            return $choice
        }
        function Invoke-CopilotControlMenuAction { param([string]$Action) $menu.Actions += $Action }
        function Invoke-ToolDeployment { param([switch]$Optional) $menu.ToolModes += $Optional.IsPresent }
        try {
            Select-ToolsMenu
            Assert-Control -Condition (($menu.Actions -join ',') -eq 'Start,Status,Stop' -and ($menu.ToolModes -join ',') -eq 'False,True') `
                -Message 'Tools M/S/X invoke Start/Status/Stop without changing existing tool deployment actions'
        }
        finally { Remove-Variable -Name Common -Scope Global -ErrorAction Stop }
    }

    foreach ($scenario in @('registration', 'rendering', 'status', 'pre-worker', 'retry', 'diagnostics')) {
        & {
            . (Import-ControlTestFunction -Path (Join-Path $RootPath 'genconfig.ps1') -Name 'Invoke-CopilotControlMenuAction')
            . (Import-ControlTestFunction -Path (Join-Path $RootPath 'genconfig.ps1') -Name 'Show-CopilotControlFailure')
            . (Import-ControlTestFunction -Path (Join-Path $RootPath 'genconfig.ps1') -Name 'Show-CopilotControlSession')
            $ui = [pscustomobject]@{
                State = 'Stopped'; MenuCalls = 0; StatusCalls = 0; StopCalls = 0; RetryCalls = 0; Acknowledgements = 0
                StartCalls = 0; DiagnosticsCalls = 0
                Messages = [Collections.Generic.List[object]]::new()
            }
            function Invoke-CopilotControlCommand {
                param([string]$Action)
                switch ($Action) {
                    'Start' {
                        $ui.StartCalls++
                        if ($scenario -eq 'pre-worker') { throw 'Synthetic UAC cancellation before worker startup' }
                        if ($scenario -in @('retry', 'diagnostics') -and $ui.StartCalls -eq 1) { throw 'Synthetic coordination conflict; finish the operation and retry' }
                        $ui.State = 'Ready'
                        if ($scenario -eq 'registration') { throw 'Synthetic registration failure after worker startup' }
                        return [pscustomobject]@{ state = 'Ready'; mcpConfiguration = @(); activeOperation = $null }
                    }
                    'Status' {
                        $ui.StatusCalls++
                        if ($scenario -eq 'status' -and $ui.StatusCalls -eq 1) { throw 'Synthetic status connection failure' }
                        return [pscustomobject]@{ state = $ui.State; activeOperation = $null }
                    }
                    'Stop' {
                        $ui.StopCalls++
                        if ($ui.State -eq 'Busy') { throw 'Synthetic Busy operation cannot be interrupted' }
                        $ui.State = 'Stopped'
                        return [pscustomobject]@{ state = 'Stopped'; activeOperation = $null }
                    }
                    'Diagnostics' {
                        $ui.DiagnosticsCalls++
                        return [pscustomobject]@{
                            latestAttempt = [pscustomobject]@{ attemptId = 'fixture'; state = 'Failed'; error = 'Synthetic coordination conflict' }
                            attemptPath = 'C:\fixture\install.json'; runtimePath = 'C:\fixture\runtime.json'
                            workerErrorLog = 'C:\fixture\stderr.log'; journalPath = 'C:\fixture\operations.jsonl'
                        }
                    }
                    default { throw 'Unexpected UI command.' }
                }
            }
            function Write-Log {
                param([string]$Message, [switch]$Failure, [switch]$Warning)
                $ui.Messages.Add([pscustomobject]@{ Message = $Message; Failure = $Failure.IsPresent; Warning = $Warning.IsPresent })
            }
            function Start-Sleep {
                param([int]$Seconds)
                if ($Seconds -ne 1) { throw 'Unexpected interlock retry interval.' }
                $ui.RetryCalls++
            }
            function Read-Host2 {
                param([string]$Prompt, [switch]$HideHelp)
                if ($Prompt -notlike '*Retry*Diagnostics*Back*' -or -not $HideHelp -or
                    @($ui.Messages | Where-Object Failure).Count -eq 0) { throw 'The failure was not displayed before requesting acknowledgement.' }
                $ui.Acknowledgements++
                if ($scenario -eq 'retry' -and $ui.Acknowledgements -eq 1) { return 'r' }
                if ($scenario -eq 'diagnostics') {
                    if ($ui.Acknowledgements -eq 1) { return 'l' }
                    if ($ui.Acknowledgements -eq 2) { return 'r' }
                }
            }
            function Get-Menu2 {
                param($MenuName, $Prompt, $AdditionalOptions, [switch]$NoNewLine, [bool]$test, [switch]$return)
                if (-not $MenuName -or -not $Prompt -or $AdditionalOptions.Contains('1') -or -not $AdditionalOptions.Contains('X')) {
                    throw 'A deployment menu became reachable while control was not stopped.'
                }
                $ui.MenuCalls++
                if ($ui.MenuCalls -gt 6) { throw 'The interlock fixture failed to make progress.' }
                if ($scenario -eq 'rendering' -and $ui.MenuCalls -eq 1) { throw 'Synthetic escaped menu-render failure' }
                if ($scenario -eq 'registration') {
                    if ($ui.MenuCalls -eq 1) { return 'ESCAPE' }
                    if ($ui.MenuCalls -eq 2) { $ui.State = 'Busy'; return 'x' }
                    $ui.State = 'Ready'
                }
                return 'x'
            }
            Invoke-CopilotControlMenuAction -Action Start
            Assert-Control -Condition ($ui.State -eq 'Stopped' -and $ui.StatusCalls -ge 2) -Message "$scenario failure cannot return to deployment menus until a fresh status verifies Stopped"
            if ($scenario -eq 'registration') {
                Assert-Control -Condition ($ui.StopCalls -eq 2 -and @($ui.Messages | Where-Object { $_.Failure -and $_.Message -match 'registration failure|Busy operation' }).Count -eq 2) `
                    -Message 'Registration failure and Busy shutdown refusal stay visible without escaping the control interlock'
                Assert-Control -Condition ($ui.Acknowledgements -eq 2) -Message 'Start and Busy-stop errors each wait for acknowledgement before the UI redraws'
            }
            if ($scenario -eq 'rendering') {
                Assert-Control -Condition ($ui.RetryCalls -eq 1 -and @($ui.Messages | Where-Object { $_.Failure -and $_.Message -like '*Deployment menus remain locked*' }).Count -eq 1) `
                    -Message 'An exception escaping modal rendering retries the lifecycle interlock instead of returning to Tools'
            }
            if ($scenario -eq 'pre-worker') {
                Assert-Control -Condition ($ui.MenuCalls -eq 0 -and $ui.StopCalls -eq 0) -Message 'A pre-worker cancellation returns safely without inventing a running worker'
                Assert-Control -Condition ($ui.Acknowledgements -eq 1) -Message 'A startup failure stays visible until acknowledged even when no worker was created'
            }
            if ($scenario -eq 'retry') {
                Assert-Control -Condition ($ui.StartCalls -eq 2 -and $ui.Acknowledgements -eq 1) -Message 'Explicit Retry rechecks startup without returning to deployment menus'
            }
            if ($scenario -eq 'diagnostics') {
                Assert-Control -Condition ($ui.StartCalls -eq 2 -and $ui.DiagnosticsCalls -eq 1 -and
                    @($ui.Messages | Where-Object { $_.Message -like '*Startup details: C:\fixture\install.json*' }).Count -eq 1) `
                    -Message 'Diagnostics shows the saved attempt location and allows a deliberate retry in the same recovery screen'
            }
        }
    }

    $selfScript = $PSCommandPath
    foreach ($mismatch in @('none', 'pid', 'start-time', 'image')) {
        $pipe = 'MemLabs-Control-Test-' + [guid]::NewGuid().ToString('N')
        $info = New-TestProcessInfo -Script $selfScript
        foreach ($argument in @('-RootPath', $RootPath, '-PipeWorker', '-PipeName', $pipe)) { $info.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::Start($info)
        try {
            $ready = $child.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(20)).GetAwaiter().GetResult()
            if (-not $ready) { throw ('Pipe fixture did not start: ' + $child.StandardError.ReadToEnd()) }
            $peer = $ready | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($mismatch -ne 'none') {
                Assert-ControlThrows -Action {
                    $serverId = if ($mismatch -eq 'pid') { [int]$peer.pid + 1 } else { $peer.pid }
                    $started = if ($mismatch -eq 'start-time') { [long]$peer.started + 1 } else { [long]$peer.started }
                    $image = if ($mismatch -eq 'image') { 'C:\not-the-server.exe' } else { (Get-Process -Id $PID).Path }
                    [MemLabs.Control.Transport]::Exchange($pipe, 'test', $serverId, $started, $image, 3000)
                } -Pattern 'protected runtime record|server identity changed' -Message "The client rejects a pipe with a different server $mismatch"
            }
            else {
                $response = [MemLabs.Control.Transport]::Exchange($pipe, 'fixture-request', $peer.pid, [long]$peer.started, (Get-Process -Id $PID).Path, 3000) |
                    ConvertFrom-Json -AsHashtable -ErrorAction Stop
                Assert-Control -Condition ($response.echo -eq 'fixture-request') -Message 'Real SID-authenticated, PID/start-time/image-bound pipe framing round-trips'
            }
            if (-not $child.WaitForExit(10000)) { throw 'The pipe fixture did not exit after its one request.' }
        }
        finally {
            if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction Stop; $child.WaitForExit() }
            $child.Dispose()
        }
    }
    $pipe = 'MemLabs-Control-Test-' + [guid]::NewGuid().ToString('N')
    $info = New-TestProcessInfo -Script $selfScript
    foreach ($argument in @('-RootPath', $RootPath, '-PipeWorker', '-PipeName', $pipe, '-PipeOwnerSid', 'S-1-5-21-1-2-3-1234')) { $info.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($info)
    try {
        $ready = $child.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(20)).GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        Assert-ControlThrows -Action {
            [MemLabs.Control.Transport]::Exchange($pipe, 'test', $ready.pid, [long]$ready.started, (Get-Process -Id $PID).Path, 3000)
        } -Pattern 'denied|authorized|end of|pipe' -Message 'A pipe restricted to another SID does not authorize the current ordinary caller'
    }
    finally {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction Stop; $child.WaitForExit() }
        $child.Dispose()
    }
    Assert-ControlThrows -Action { [MemLabs.Control.Transport]::ReadLine([IO.StringReader]::new(('x' * 65537) + "`n")) } `
        -Pattern '64 KiB' -Message 'MCP framing bounds oversized input'

    $info = New-TestProcessInfo -Script $adapter
    $client = [Diagnostics.Process]::Start($info)
    try {
        $requests = @(
            @{ jsonrpc = '2.0'; id = 0; method = 'server/discover' },
            @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-11-25'; capabilities = @{}; clientInfo = @{ name = 'memlabs-test'; version = '1' } } },
            @{ jsonrpc = '2.0'; method = 'notifications/initialized' },
            @{ jsonrpc = '2.0'; id = 2; method = 'tools/list' },
            @{ jsonrpc = '2.0'; id = 3; method = 'tools/call'; params = @{ name = 'memlabs_stop_vm'; arguments = @{ vmId = $id; confirm = $false } } },
            @{ jsonrpc = '2.0'; id = 4; method = 'tools/call'; params = @{ name = 'run_powershell'; arguments = @{} } },
            @{ jsonrpc = '2.0'; id = 5; method = 'ping' }
        )
        foreach ($request in $requests) { $client.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress)) }
        $client.StandardInput.Close()
        $stdout = $client.StandardOutput.ReadToEndAsync()
        $stderr = $client.StandardError.ReadToEndAsync()
        if (-not $client.WaitForExit(30000)) { throw 'The MCP adapter did not exit after stdin EOF.' }
        $lines = @($stdout.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ })
        $responses = @($lines | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -ErrorAction Stop })
        $null = $stderr.GetAwaiter().GetResult()
        Assert-Control -Condition ($client.ExitCode -eq 0 -and $responses.Count -eq 6) -Message 'MCP stdout contains exactly one response per request and notifications produce no response'
        Assert-Control -Condition ($responses[0].id -eq 0 -and $responses[0].error.code -eq -32601 -and
            $responses[1].id -eq 1 -and $responses[1].result.protocolVersion -eq '2025-11-25') `
            -Message 'An unsupported discovery probe produces only one error, so the real client can fall back to initialize'
        $tools = $responses[2].result.tools
        Assert-Control -Condition ($tools.Count -eq 5 -and @($tools.name | Where-Object { $_ -match 'delete|deploy|script|shell' }).Count -eq 0) -Message 'Only the five bounded control tools are exposed'
        Assert-Control -Condition ($responses[3].error.code -eq -32602 -and $responses[4].error.code -eq -32602) -Message 'Unconfirmed stops and arbitrary-shell tools are rejected before reaching the broker'
        Assert-Control -Condition ($responses[5].id -eq 5 -and $responses[5].Contains('result')) -Message 'The adapter remains responsive after rejected tool requests'
    }
    finally {
        if (-not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction Stop; $client.WaitForExit() }
        $client.Dispose()
    }
    Assert-ControlThrows -Action {
        & (Join-Path $controlRoot 'Invoke-ControlOperation.ps1') -Action start_vm -VmId $id -RequestId $id -ClientSid 'S-1-5-18' -PackageHash ('0' * 64)
    } -Pattern 'protected, versioned installation' -Message 'Direct operation execution from a writable checkout is refused'

    [Console]::WriteLine("PASS: Test-CopilotControl ($script:Assertions assertions; no live VM changes)")
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
}
