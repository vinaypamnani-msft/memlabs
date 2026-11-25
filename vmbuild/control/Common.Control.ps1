function Initialize-MemLabsControlTransport {
    if (-not ('MemLabs.Control.Transport' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ControlTransport.cs') -ErrorAction Stop
    }
}

function Import-MemLabsControlHyperV {
    $moduleRoot = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\Modules\Hyper-V'
    $module = Get-Module -ListAvailable -Name $moduleRoot -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $module) { throw 'The Windows Hyper-V PowerShell management module is not installed.' }
    Import-Module -Name $module.Path -ErrorAction Stop
}

function Get-MemLabsControlPaths {
    param([string]$ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)

    $null = [Security.Principal.SecurityIdentifier]::new($ClientSid)
    if ($ClientSid -notmatch '^S-1-(?:\d+-)*\d+$') { throw 'Invalid control owner SID.' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ClientSid))).ToLowerInvariant()
    $install = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'MemLabs\CopilotControl'
    $data = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'MemLabs-CopilotControl'
    $runtime = Join-Path $data $ClientSid
    return [pscustomobject]@{
        InstallRoot = $install
        DataRoot = $data
        RuntimeRoot = $runtime
        RuntimeFile = Join-Path $runtime 'runtime.json'
        PipeName = 'MemLabs-Control-' + $hash.Substring(0, 24)
        PowerShell = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell\7\pwsh.exe'
        ClientSid = $ClientSid
    }
}

function Assert-MemLabsControlNoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse points are not permitted for control files: '$current'." }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-MemLabsControlProtectedPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Boundary)

    Assert-MemLabsControlNoReparsePoint -Path $Path
    $current = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    if ($current -ne $root -and -not $current.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Control path escapes its protected boundary.' }
    $writers = @('S-1-5-18', 'S-1-5-32-544')
    $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    while ($true) {
        $acl = Get-Acl -LiteralPath $current -ErrorAction Stop
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $writers) { throw "Control path has an untrusted owner: '$current'." }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -ne 0 -and $rule.IdentityReference.Value -notin $writers) {
                throw "Control path is writable outside Administrators/SYSTEM: '$current'."
            }
        }
        if ($current -eq $root) { break }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function New-MemLabsControlProtectedDirectory {
    param([Parameter(Mandatory)][string]$Path)

    Assert-MemLabsControlNoReparsePoint -Path $Path
    if (Test-Path -LiteralPath $Path) {
        Assert-MemLabsControlProtectedPath -Path $Path -Boundary $Path
        return
    }
    $null = New-Item -Path $Path -ItemType Directory -ErrorAction Stop
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($entry in @(
            @{ Sid = 'S-1-5-18'; Rights = 'FullControl' },
            @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },
            @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }
        )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($entry.Sid),
                [Security.AccessControl.FileSystemRights]$entry.Rights,
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    Assert-MemLabsControlProtectedPath -Path $Path -Boundary $Path
}

function Write-MemLabsControlJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-MemLabsControlPackage {
    $files = @(
        'Common.Control.ps1', 'ControlTransport.cs', 'Install-Control.ps1', 'Invoke-ControlBroker.ps1',
        'Invoke-ControlOperation.ps1', 'Invoke-ControlMcp.ps1', 'Start-Control.ps1'
    )
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($name in $files) {
        $path = Join-Path $PSScriptRoot $name
        $rows.Add([pscustomobject]@{ Name = $name; Path = $path; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash })
    }
    $coordinator = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Invoke-MemLabsLiveOperation.ps1'
    $rows.Add([pscustomobject]@{ Name = 'Invoke-MemLabsLiveOperation.ps1'; Path = $coordinator; Hash = (Get-FileHash -LiteralPath $coordinator -Algorithm SHA256 -ErrorAction Stop).Hash })
    $description = @($rows | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Hash)" }) -join "`n"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($description))).ToLowerInvariant()
    return [pscustomobject]@{ Hash = $hash; Files = $rows.ToArray() }
}

function Assert-MemLabsControlPackage {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Hash)

    if ($Hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid package fingerprint.' }
    $paths = Get-MemLabsControlPaths
    $expected = Join-Path $paths.InstallRoot "Packages\$Hash"
    if ([IO.Path]::GetFullPath($Path).TrimEnd('\') -ne $expected) { throw 'The worker must run from its protected, versioned installation.' }
    Assert-MemLabsControlProtectedPath -Path $Path -Boundary (Split-Path -Parent $paths.InstallRoot)
    $receipt = Get-Content -LiteralPath (Join-Path $Path 'package.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $names = @('Common.Control.ps1', 'ControlTransport.cs', 'Install-Control.ps1', 'Invoke-ControlBroker.ps1', 'Invoke-ControlOperation.ps1', 'Invoke-ControlMcp.ps1', 'Start-Control.ps1', 'Invoke-MemLabsLiveOperation.ps1')
    if (@($receipt.files).Count -ne $names.Count) { throw 'The installed control package has an unexpected file set.' }
    $lines = foreach ($name in $names | Sort-Object) {
        $entry = @($receipt.files | Where-Object name -CEQ $name)
        if ($entry.Count -ne 1) { throw "Control package receipt is missing '$name'." }
        $file = Join-Path $Path $name
        Assert-MemLabsControlProtectedPath -Path $file -Boundary $paths.InstallRoot
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actual -cne $entry[0].hash) { throw "Control package integrity verification failed for '$name'." }
        "${name}:$actual"
    }
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).ToLowerInvariant()
    if ($actualHash -cne $Hash -or $receipt.hash -cne $Hash) { throw 'Control package fingerprint does not match its approved bytes.' }
}

function Assert-MemLabsControlKeys {
    param([Parameter(Mandatory)][Collections.IDictionary]$Object, [string[]]$Allowed = @(), [string[]]$Required = @())

    foreach ($key in $Object.Keys) { if ($key -cnotin $Allowed) { throw "Unexpected control parameter '$key'." } }
    foreach ($key in $Required) { if (-not $Object.Contains($key)) { throw "Missing control parameter '$key'." } }
}

function Assert-MemLabsControlArguments {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][Collections.IDictionary]$Arguments)

    switch -CaseSensitive ($Method) {
        { $_ -cin @('status', 'shutdown') } { Assert-MemLabsControlKeys -Object $Arguments }
        'inventory' {
            Assert-MemLabsControlKeys -Object $Arguments -Allowed @('offset', 'limit')
            foreach ($name in $Arguments.Keys) {
                $value = $Arguments[$name]
                if ($value -isnot [int] -and $value -isnot [long]) { throw "Inventory '$name' must be an integer." }
                if ($value -lt 0 -or ($name -eq 'limit' -and ($value -lt 1 -or $value -gt 100)) -or $value -gt [int]::MaxValue) {
                    throw "Inventory '$name' is outside its permitted range."
                }
            }
        }
        { $_ -cin @('start_vm', 'stop_vm', 'operation') } {
            $field = if ($Method -eq 'operation') { 'operationId' } else { 'vmId' }
            $allowed = @($field)
            if ($Method -eq 'stop_vm') { $allowed += 'confirm' }
            Assert-MemLabsControlKeys -Object $Arguments -Allowed $allowed -Required $allowed
            $id = [guid]::Empty
            if ($Arguments[$field] -isnot [string] -or -not [guid]::TryParseExact($Arguments[$field], 'D', [ref]$id) -or $id -eq [guid]::Empty) {
                throw "'$field' must be a non-empty VM/operation GUID in canonical D format."
            }
            if ($Method -eq 'stop_vm' -and ($Arguments.confirm -isnot [bool] -or -not $Arguments.confirm)) { throw 'Graceful stop requires confirm=true.' }
        }
        default { throw "Unsupported control operation '$Method'." }
    }
}

function New-MemLabsControlOperationJob {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][guid]$VmId, [Parameter(Mandatory)][guid]$OperationId)

    $shell = [PowerShell]::Create()
    try {
        $null = $shell.AddCommand((Join-Path $State.PackagePath 'Invoke-ControlOperation.ps1')).
            AddParameter('Action', $Method).AddParameter('VmId', $VmId).
            AddParameter('RequestId', $OperationId).AddParameter('ClientSid', $State.ClientSid).
            AddParameter('PackageHash', $State.PackageHash)
        $async = $shell.BeginInvoke()
        return [pscustomobject]@{ Id = $OperationId.ToString('D'); Shell = $shell; Async = $async }
    }
    catch { $shell.Dispose(); throw }
}

function Stop-MemLabsControlWorker {
    param([Parameter(Mandatory)]$State)

    $operation = { $State.Stopping = $true }.GetNewClosure()
    $postcondition = { [bool]($State.Stopping -and $null -eq $State.Active) }.GetNewClosure()
    $diagnostics = { [pscustomobject]@{ stopping = $State.Stopping; busy = $null -ne $State.Active } }.GetNewClosure()
    $result = & (Join-Path $State.PackagePath 'Invoke-MemLabsLiveOperation.ps1') `
        -Mode Mutate -Intent 'Stop the explicitly requested idle Copilot Control worker' `
        -TargetType HostResource -Target @("CopilotControl:$PID") `
        -Operation $operation -Postcondition $postcondition -FailureDiagnostics $diagnostics
    return [pscustomobject]@{ state = 'Stopping'; journalOperationId = $result.OperationId }
}

function Invoke-MemLabsControlDispatch {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$Method, [Collections.IDictionary]$Arguments = @{})

    Assert-MemLabsControlArguments -Method $Method -Arguments $Arguments
    switch -CaseSensitive ($Method) {
        'status' {
            return [pscustomobject]@{
                state = $State.Runtime.state; version = '1.0.0'; packageHash = $State.PackageHash
                activeOperation = $State.Runtime.activeOperation
                capabilities = @('inventory', 'start_vm', 'stop_vm', 'operation'); deploymentSupported = $false
            }
        }
        'shutdown' {
            if ($null -ne $State.Active) { throw 'Control is busy; shutdown will not interrupt an active operation.' }
            return (Stop-MemLabsControlWorker -State $State)
        }
        'operation' {
            $operationId = ([guid]$Arguments.operationId).ToString('D')
            if ($null -ne $State.Active -and $State.Active.Id -eq $operationId) { return [pscustomobject]@{ operationId = $operationId; state = 'Running' } }
            if ($State.History.Contains($operationId)) { return $State.History[$operationId] }
            throw 'Operation is unknown or no longer retained; consult the protected Live Ops journal.'
        }
        'inventory' {
            if ($null -ne $State.Active) { throw 'Control is busy. Query status or the current operation before listing VMs.' }
            $offset = if ($Arguments.Contains('offset')) { [int]$Arguments.offset } else { 0 }
            $limit = if ($Arguments.Contains('limit')) { [int]$Arguments.limit } else { 50 }
            $vms = @(Get-VM -ErrorAction Stop | Sort-Object Name, Id)
            $page = @($vms | Select-Object -Skip $offset -First $limit | ForEach-Object {
                    [pscustomobject]@{ vmId = $_.Id.ToString('D'); name = $_.Name; state = "$($_.State)"; memoryAssignedBytes = $_.MemoryAssigned; cpuUsage = $_.CPUUsage }
                })
            return [pscustomobject]@{ items = $page; total = $vms.Count; nextOffset = $(if ($offset + $page.Count -lt $vms.Count) { $offset + $page.Count } else { $null }) }
        }
        { $_ -cin @('start_vm', 'stop_vm') } {
            if ($null -ne $State.Active) { throw 'Control is busy; no additional VM operation was queued.' }
            $vmId = [guid]$Arguments.vmId
            $null = Get-VM -Id $vmId -ErrorAction Stop
            $operationId = [guid]::NewGuid()
            $State.Active = New-MemLabsControlOperationJob -State $State -Method $Method -VmId $vmId -OperationId $operationId
            $State.Runtime.state = 'Busy'
            $State.Runtime.activeOperation = [pscustomobject]@{ operationId = $operationId.ToString('D'); action = $Method; vmId = $vmId.ToString('D') }
            return [pscustomobject]@{ operationId = $operationId.ToString('D'); state = 'Running' }
        }
    }
}

function Complete-MemLabsControlOperation {
    param([Parameter(Mandatory)]$State)

    if ($null -eq $State.Active -or -not $State.Active.Async.IsCompleted) { throw 'No completed control operation is available.' }
    $active = $State.Active
    try {
        $output = @($active.Shell.EndInvoke($active.Async))
        if ($active.Shell.HadErrors -or $output.Count -ne 1 -or $output[0].success -isnot [bool]) {
            $errorText = @($active.Shell.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '; '
            throw "Worker returned an invalid completion envelope. $errorText"
        }
        $completion = $output[0]
    }
    catch { $completion = [pscustomobject]@{ success = $false; operationId = $active.Id; error = $_.Exception.Message } }
    finally { $active.Shell.Dispose() }
    $State.History[$active.Id] = [pscustomobject]@{
        operationId = $active.Id; state = $(if ($completion.success) { 'Succeeded' } else { 'Failed' }); result = $completion
    }
    while ($State.History.Count -gt 32) { $State.History.Remove(@($State.History.Keys)[0]) }
    $State.Active = $null
    $State.Runtime.activeOperation = $null
    $State.Runtime.state = 'Ready'
    return $State.History[$active.Id]
}

function Get-MemLabsControlRuntime {
    param([string]$ClientSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)

    $paths = Get-MemLabsControlPaths -ClientSid $ClientSid
    if (-not (Test-Path -LiteralPath $paths.RuntimeFile)) { return $null }
    Assert-MemLabsControlProtectedPath -Path $paths.RuntimeFile -Boundary $paths.DataRoot
    $runtime = Get-Content -LiteralPath $paths.RuntimeFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($runtime.ownerSid -cne $ClientSid -or $runtime.pipeName -cne $paths.PipeName) { throw 'The protected runtime record belongs to a different endpoint.' }
    if ($runtime.state -eq 'Stopped') { return $null }
    Assert-MemLabsControlPackage -Path $runtime.packagePath -Hash $runtime.packageHash
    return $runtime
}

function Invoke-MemLabsControlRequest {
    param([Parameter(Mandatory)][string]$Method, [Collections.IDictionary]$Arguments = @{}, [ValidateRange(100, 15000)][int]$TimeoutMilliseconds = 5000)

    Assert-MemLabsControlArguments -Method $Method -Arguments $Arguments
    $paths = Get-MemLabsControlPaths
    $runtime = Get-MemLabsControlRuntime
    if ($null -eq $runtime) {
        if ($Method -eq 'status') { return [pscustomobject]@{ state = 'Stopped'; message = 'Start Copilot/MCP Control from MemLabs Tools or Start-Control.ps1.' } }
        throw 'MemLabs Copilot Control is stopped. Start it explicitly; this client never elevates itself.'
    }
    Initialize-MemLabsControlTransport
    $id = [guid]::NewGuid().ToString('D')
    $request = @{ version = 1; id = $id; method = $Method; arguments = $Arguments } | ConvertTo-Json -Depth 8 -Compress
    $text = [MemLabs.Control.Transport]::Exchange($paths.PipeName, $request, $runtime.pid, [long]$runtime.startFileTime, $paths.PowerShell, $TimeoutMilliseconds)
    $response = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($response.id -cne $id -or $response.version -ne 1) { throw 'Control response does not match the request.' }
    if ($response.ok -isnot [bool] -or -not $response.ok) { throw "MemLabs control request failed: $($response.error)" }
    return [pscustomobject]$response.result
}

function New-MemLabsControlBootstrap {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$ClientSid, [Parameter(Mandatory)][guid]$AttemptId)

    $common = @($Package.Files | Where-Object Name -eq 'Common.Control.ps1')[0]
    $installer = @($Package.Files | Where-Object Name -eq 'Install-Control.ps1')[0]
    $commonBytes = [IO.File]::ReadAllBytes($common.Path)
    $installerBytes = [IO.File]::ReadAllBytes($installer.Path)
    foreach ($entry in @(
            @{ Bytes = $commonBytes; Hash = $common.Hash },
            @{ Bytes = $installerBytes; Hash = $installer.Hash }
        )) {
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.Bytes)) -cne $entry.Hash) {
            throw 'Bootstrap source changed before elevation was requested.'
        }
    }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString($commonBytes), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw $errors[0] }
    $helperNames = @(
        'Get-MemLabsControlPaths', 'Assert-MemLabsControlNoReparsePoint', 'Assert-MemLabsControlProtectedPath',
        'New-MemLabsControlProtectedDirectory', 'Write-MemLabsControlJson', 'Assert-MemLabsControlPackage'
    )
    $helpers = foreach ($name in $helperNames) {
        $node = $ast.Find({
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $name
            }, $true)
        if ($null -eq $node) { throw "Required bootstrap helper is missing: $name" }
        $node.Extent.Text
    }
    $bundle = @{
        helpers = $helpers -join "`n"
        installer = [Text.Encoding]::UTF8.GetString($installerBytes)
        payload = @{
            clientSid = $ClientSid; hash = $Package.Hash; attemptId = $AttemptId.ToString('D')
            files = @($Package.Files | Select-Object Name, Path, Hash)
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($bundle)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $stream = [IO.MemoryStream]::new()
    try {
        $zip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionLevel]::SmallestSize, $true)
        try { $zip.Write($bytes, 0, $bytes.Length) }
        finally { $zip.Dispose() }
        $compressed = [Convert]::ToBase64String($stream.ToArray())
    }
    finally { $stream.Dispose() }
    $loader = @'
$ErrorActionPreference = 'Stop'
$oldPath = $env:PATH
$oldModules = $env:PSModulePath
try {
    $system = [Environment]::GetFolderPath('System')
    $env:PATH = $system + ';' + [Environment]::GetFolderPath('Windows')
    $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') + ';' +
        [IO.Path]::Combine($system, 'WindowsPowerShell\v1.0\Modules') + ';' +
        [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'WindowsPowerShell\Modules')
    $source = [IO.MemoryStream]::new([Convert]::FromBase64String('__COMPRESSED__'))
    $target = [IO.MemoryStream]::new()
    try {
        $zip = [IO.Compression.GZipStream]::new($source, [IO.Compression.CompressionMode]::Decompress)
        try { $zip.CopyTo($target) } finally { $zip.Dispose() }
        $bytes = $target.ToArray()
    }
    finally { $source.Dispose(); $target.Dispose() }
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne '__HASH__') {
        throw 'The frozen bootstrap payload failed integrity verification.'
    }
    $bundle = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 16 -ErrorAction Stop
    . ([scriptblock]::Create($bundle.helpers))
    $paths = Get-MemLabsControlPaths -ClientSid $bundle.payload.clientSid
    New-MemLabsControlProtectedDirectory -Path $paths.DataRoot
    New-MemLabsControlProtectedDirectory -Path $paths.RuntimeRoot
    $attempt = ([guid]$bundle.payload.attemptId).ToString('D')
    $resultPath = [IO.Path]::Combine($paths.RuntimeRoot, "install-$attempt.json")
    Write-MemLabsControlJson -Path $resultPath -Value @{ attemptId = $attempt; success = $false; state = 'Installing' }
    try {
        & ([scriptblock]::Create($bundle.installer)) -Payload ($bundle.payload | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        Write-MemLabsControlJson -Path $resultPath -Value @{
            attemptId = $attempt; success = $false; state = 'Failed'; error = $_.Exception.Message
        }
        throw
    }
}
finally { $env:PATH = $oldPath; $env:PSModulePath = $oldModules }
'@
    return $loader.Replace('__COMPRESSED__', $compressed).Replace('__HASH__', $hash)
}

function Add-MemLabsControlMcpConfiguration {
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$AdapterPath)

    Initialize-MemLabsControlTransport
    $paths = Get-MemLabsControlPaths
    $entry = [ordered]@{
        type = 'stdio'
        command = $paths.PowerShell
        args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $AdapterPath)
    }
    $results = @()
    foreach ($configuration in @(
            @{ Path = Join-Path $RepositoryRoot '.vscode\mcp.json'; Map = 'servers' },
            @{ Path = Join-Path $RepositoryRoot '.mcp.json'; Map = 'mcpServers' }
        )) {
        $path = $configuration.Path
        Assert-MemLabsControlNoReparsePoint -Path $path
        $directory = Split-Path -Parent $path
        $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        $exists = Test-Path -LiteralPath $path
        $mode = if ($exists) { [IO.FileMode]::Open } else { [IO.FileMode]::CreateNew }
        $stream = [IO.File]::Open($path, $mode, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $originalBytes = $null
        $writeStarted = $false
        $completed = $false
        try {
            if ($stream.Length -gt 2MB) { throw "MCP configuration exceeds the 2 MiB registration limit: '$path'." }
            $originalBytes = [byte[]]::new($stream.Length)
            $stream.ReadExactly($originalBytes)
            $memory = [IO.MemoryStream]::new($originalBytes)
            $reader = [IO.StreamReader]::new($memory, [Text.UTF8Encoding]::new($false, $true), $true)
            try {
                $original = if ($exists) { $reader.ReadToEnd() } else { '{}' }
                $encoding = $reader.CurrentEncoding
            }
            finally { $reader.Dispose(); $memory.Dispose() }
            $json = $original | ConvertFrom-Json -AsHashtable -Depth 40 -ErrorAction Stop
            if ($json -isnot [Collections.IDictionary]) { throw "MCP configuration is not an object: '$path'." }
            if ($json.Contains($configuration.Map)) {
                $servers = $json[$configuration.Map]
                if ($servers -isnot [Collections.IDictionary]) { throw "MCP server collection is not an object: '$path'." }
                if ($servers.Contains('memlabs')) {
                    $existing = $servers.memlabs
                    if ($existing -isnot [Collections.IDictionary] -or $existing.command -cne $entry.command -or
                        ($existing.args | ConvertTo-Json -Compress) -cne ($entry.args | ConvertTo-Json -Compress) -or $existing.type -cne 'stdio') {
                        throw "An existing 'memlabs' MCP entry differs in '$path'; it was not overwritten. Update it explicitly to the newly installed adapter."
                    }
                    $results += [pscustomobject]@{ Path = $path; Added = $false }
                    $completed = $true
                    continue
                }
            }
            $updated = [MemLabs.Control.Transport]::AddJsonEntry($original, $configuration.Map, 'memlabs', ($entry | ConvertTo-Json -Depth 6 -Compress))
            if ($exists) {
                $backup = $path + '.memlabs-control.bak'
                if (Test-Path -LiteralPath $backup) { $backup = $path + '.memlabs-control-' + [guid]::NewGuid().ToString('N') + '.bak' }
                $security = [IO.FileSystemAclExtensions]::GetAccessControl($stream)
                $backupStream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($backup), [IO.FileMode]::CreateNew,
                    [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
                try { $backupStream.Write($originalBytes, 0, $originalBytes.Length); $backupStream.Flush($true) }
                finally { $backupStream.Dispose() }
            }
            $preamble = $encoding.GetPreamble()
            $updatedBytes = $encoding.GetBytes($updated)
            $writeStarted = $true
            $stream.Position = 0
            $stream.SetLength(0)
            $stream.Write($preamble, 0, $preamble.Length)
            $stream.Write($updatedBytes, 0, $updatedBytes.Length)
            $stream.Flush($true)
            $completed = $true
            $results += [pscustomobject]@{ Path = $path; Added = $true }
        }
        catch {
            if ($exists -and $writeStarted) {
                $updateError = $_
                try {
                    $stream.Position = 0
                    $stream.SetLength(0)
                    $stream.Write($originalBytes, 0, $originalBytes.Length)
                    $stream.Flush($true)
                }
                catch { throw [AggregateException]::new("MCP update and restoration both failed for '$path'. Its backup must be restored.", @($updateError.Exception, $_.Exception)) }
            }
            throw
        }
        finally {
            $stream.Dispose()
            if (-not $exists -and -not $completed -and [IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
    }
    return $results
}
