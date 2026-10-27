#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $PSScriptRoot 'Common.WindowsVmFirstLogonDump.ps1')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { $null = & $Action } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected '$Pattern', got '$message'."
}
$root = Join-Path ([IO.Path]::GetTempPath()) "memlabs-firstlogon-dump-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path (Join-Path $root 'ProgramData'), (Join-Path $root 'Windows') -ItemType Directory -Force
try {
    $guestBlock = Get-MemLabsFirstLogonDumpGuestBlock
    $guestAst = [Management.Automation.Language.Parser]::ParseInput($guestBlock.ToString(), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    $writerAssignment = @($guestAst.FindAll({
                param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$writerSource'
            }, $true))[0]
    $writerLiteral = @($writerAssignment.Right.FindAll({
                param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true))[0]
    $writerAst = [Management.Automation.Language.Parser]::ParseInput($writerLiteral.Value, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors -join '; ') }
    $compile = @($writerAst.FindAll({
                param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type'
            }, $true))[0]
    . ([scriptblock]::Create($compile.Extent.Text))
    Assert-True ($null -ne ('MemLabs.FirstLogonDumpNative' -as [type])) 'The exact native dump-writer payload did not compile.'
    $privilegeType = [MemLabs.FirstLogonDumpNative].GetNestedType('Privilege', [Reflection.BindingFlags]::NonPublic)
    Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([Activator]::CreateInstance($privilegeType)) -eq 16 -and
        [Runtime.InteropServices.Marshal]::OffsetOf($privilegeType, 'Luid').ToInt32() -eq 4 -and
        [Runtime.InteropServices.Marshal]::OffsetOf($privilegeType, 'Attributes').ToInt32() -eq 12) `
        'The native debug-privilege structure does not match the Windows ABI.'
    Assert-True ($writerLiteral.Value -match 'FirstLogonAnim\.exe' -and $writerLiteral.Value -match 'DateTime\.FromFileTimeUtc' -and
        $writerLiteral.Value -match 'Environment\.Exit\(124\)' -and $writerLiteral.Value -match '0x1026' -and
        $guestBlock.ToString() -notmatch '\b(Start-VM|Restart-VM|Stop-VM|Restart-Computer|Rename-Computer|Remove-AppxPackage)\b') `
        'The dump payload lost exact image/start-time guards, its native watchdog/context, or gained configuration/power actions.'
    $guest = [scriptblock]::Create($guestBlock.ToString().Replace('$env:SystemDrive', "'$($root.Replace("'", "''"))'"))
    $script:MachineGuid = [guid]::NewGuid().ToString('D')
    $script:TargetCount = 1; $script:WrongImage = $false; $script:WriterExitCode = 0
    $script:WriterTimeout = $false; $script:WriterUnknown = $false; $script:WriterStopped = $false
    $script:BadHeader = $false; $script:Starts = 0; $script:StoppedIds = [Collections.Generic.List[int]]::new()
    function Get-CimInstance {
        param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        Assert-True ($OperationTimeoutSec -eq 10) 'The dump preflight lost its bounded CIM query.'
        if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ ProductType = 1 } }
        Assert-True ($ClassName -eq 'Win32_Process' -and $Filter -ceq "Name='FirstLogonAnim.exe'") 'The dump target query broadened beyond FirstLogonAnim.'
        if ($script:TargetCount -eq 0) { return }
        foreach ($number in 1..$script:TargetCount) {
            [pscustomobject]@{
                Name = 'FirstLogonAnim.exe'; ProcessId = 2292; SessionId = 1
                ExecutablePath = $(if ($script:WrongImage) { 'C:\private\FirstLogonAnim.exe' } else { Join-Path $env:SystemRoot 'System32\oobe\FirstLogonAnim.exe' })
            }
        }
    }
    function Get-ItemProperty {
        param($LiteralPath, $Name, $ErrorAction)
        Assert-True ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\Cryptography' -and $Name -eq 'MachineGuid') 'Capture read unexpected registry data.'
        [pscustomobject]@{ MachineGuid = $script:MachineGuid }
    }
    function Get-Process {
        param($Id, $ErrorAction)
        Assert-True ($Id -eq 2292) 'Capture inspected another process.'
        $process = [pscustomobject]@{ Id = 2292; StartTime = ([DateTimeOffset]'2026-10-21T00:20:44Z').LocalDateTime }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $process
    }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, $RedirectStandardOutput, $RedirectStandardError, $ErrorAction)
        Assert-True ($FilePath -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and
            $PassThru -and $ArgumentList -match '-ProcessId 2292 ' -and $ArgumentList -match '-StartTicks \d+ ' -and
            $ArgumentList -match '-CaptureSeconds 120') 'The isolated dump writer lost its target, identity, deadline, or native engine.'
        $script:Starts++
        $match = [regex]::Match($ArgumentList, '-DumpPath "([^"]+)"')
        if (-not $match.Success) { throw 'Fixture could not identify the owned dump path.' }
        $bytes = [byte[]]::new(64)
        if (-not $script:BadHeader) { [Array]::Copy([byte[]]@(77, 68, 77, 80), $bytes, 4) }
        [IO.File]::WriteAllBytes($match.Groups[1].Value, $bytes)
        [IO.File]::WriteAllText($RedirectStandardOutput, '')
        [IO.File]::WriteAllText($RedirectStandardError, 'Synthetic native capture error.')
        $writer = [pscustomobject]@{ Id = 8800; ExitCode = $script:WriterExitCode }
        $writer | Add-Member -MemberType ScriptProperty -Name HasExited -Value { -not $script:WriterTimeout -or $script:WriterStopped }
        $writer | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            if ($Milliseconds -notin @(120000, 5000)) { throw 'Unexpected dump-writer wait budget.' }
            return (-not $script:WriterTimeout -or $script:WriterStopped)
        }
        $writer | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $writer
    }
    function Stop-Process {
        param($Id, [switch]$Force, $ErrorAction)
        Assert-True ($Id -eq 8800 -and $Force) 'Capture tried to stop the target or a process not owned by this attempt.'
        $script:StoppedIds.Add($Id)
        if ($script:WriterUnknown) { throw 'Synthetic owned writer cannot be confirmed stopped.' }
        $script:WriterStopped = $true
    }
    $token = [guid]::NewGuid().ToString('N')
    $capture = & $guest -Token $token
    Assert-True ($capture.Status -eq 'Captured' -and $capture.WriterExited -and $capture.ProcessId -eq 2292 -and
        $capture.Bytes -eq 64 -and $capture.Sha256 -match '^[A-F0-9]{64}$' -and $capture.GuestArtifactRetained -and
        $capture.CleanupErrors.Count -eq 0 -and $script:Starts -eq 1 -and
        @([IO.Directory]::EnumerateFiles((Join-Path $root $capture.GuestRelativeDirectory))).Count -eq 1) `
        'Successful capture lost its protected dump, native identity, digest, size, or writer-file cleanup.'
    foreach ($scenario in @('Absent', 'Duplicate', 'WrongImage', 'NativeFailure', 'BadHeader', 'Timeout', 'Indeterminate')) {
        $script:TargetCount = 1; $script:WrongImage = $false; $script:WriterExitCode = 0; $script:BadHeader = $false
        $script:WriterTimeout = $false; $script:WriterUnknown = $false; $script:WriterStopped = $false
        switch ($scenario) {
            Absent { $script:TargetCount = 0 }
            Duplicate { $script:TargetCount = 2 }
            WrongImage { $script:WrongImage = $true }
            NativeFailure { $script:WriterExitCode = 5 }
            BadHeader { $script:BadHeader = $true }
            Timeout { $script:WriterTimeout = $true }
            Indeterminate { $script:WriterTimeout = $true; $script:WriterUnknown = $true }
        }
        $result = & $guest -Token ([guid]::NewGuid().ToString('N'))
        $expected = if ($scenario -eq 'Absent') { 'Unavailable' } elseif ($scenario -eq 'Indeterminate') { 'Indeterminate' } else { 'Failed' }
        Assert-True ($result.Status -eq $expected -and -not [string]::IsNullOrWhiteSpace($result.Error)) "$scenario became successful/opaque dump evidence."
        if ($expected -eq 'Failed' -and $result.GuestRelativeDirectory) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $result.GuestRelativeDirectory))) 'A known failed capture leaked writer files or a partial dump.'
        }
    }
    Assert-True (@($script:StoppedIds | Where-Object { $_ -ne 8800 }).Count -eq 0) 'The dump path can terminate FirstLogonAnim or another unowned process.'

    $script:VMId = [guid]::NewGuid()
    $vm = [pscustomobject]@{ Id = $script:VMId; Name = 'HUNG-CLIENT' }
    $secret = [Security.SecureString]::new(); $secret.AppendChar('x')
    $credential = [pscredential]::new('synthetic-admin', $secret)
    $script:ExpectedCredential = $credential
    $script:RpcCalls = 0; $script:TransportFails = $false; $script:Late = $false; $script:Reply = $capture
    function Get-VM {
        param($Id, $ErrorAction)
        Assert-True ($Id -eq $script:VMId) 'Host capture targeted another VM ID.'
        [pscustomobject]@{ Id = $script:VMId; Name = 'HUNG-CLIENT'; State = 'Running' }
    }
    function Invoke-Command {
        param($VMId, [pscredential]$Credential, [switch]$AsJob, $ScriptBlock, $ArgumentList, $ErrorAction)
        Assert-True ($VMId -eq $script:VMId -and $AsJob -and [object]::ReferenceEquals($Credential,$script:ExpectedCredential)) 'Host capture lost exact VM/asynchronous credentials.'
        $script:RpcCalls++
        [pscustomobject]@{ State = 'Completed' }
    }
    function Wait-MemLabsOobeRepairJob {
        param($Job,$TimeoutSeconds,$Operation)
        Assert-True ($TimeoutSeconds -in @(1,180) -and $Operation -eq 'FirstLogonAnim hang-dump capture') 'Host dump RPC lost its deadline.'
        if ($script:TransportFails) { throw 'Synthetic transport outcome unknown.' }
        if ($script:Late) { [Threading.Thread]::Sleep(1100) }
        [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($script:Reply))
    }
    function New-DumpManifest {
        @{
            HangDump = [ordered]@{ Token = $token; Status = 'NotRequested'; Error = $null; Capture = $null }
            Files = [Collections.Generic.List[object]]::new(); Errors = [Collections.Generic.List[string]]::new()
        }
    }
    $manifest = New-DumpManifest
    Invoke-MemLabsFirstLogonHangDump -VM $vm -GuestCredential $credential -GuestBlock $guestBlock -Manifest $manifest
    $bundle = Join-Path $root 'bundle'
    $null = New-Item -Path $bundle -ItemType Directory
    Copy-MemLabsOfflineFirstLogonDump -WindowsRoot (Join-Path $root 'Windows') -Bundle $bundle -Manifest $manifest
    Assert-True ($manifest.HangDump.Status -eq 'CopiedAndVerified' -and $manifest.Files.Count -eq 1 -and
        (Get-FileHash -LiteralPath (Join-Path $bundle 'FirstLogonAnim.dmp') -Algorithm SHA256).Hash -eq $capture.Sha256) `
        'Read-only offline dump transfer did not preserve the verified guest artifact.'
    foreach ($variant in @('WrongToken', 'WrongPath', 'Oversize', 'BadDigest', 'WriterRunning', 'WrongVersion')) {
        $script:Reply = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($capture))
        switch ($variant) {
            WrongToken { $script:Reply.Token = [guid]::NewGuid().ToString('N') }
            WrongPath { $script:Reply.GuestRelativePath = '..\private.dmp' }
            Oversize { $script:Reply.Bytes = 512MB + 1 }
            BadDigest { $script:Reply.Sha256 = 'bad' }
            WriterRunning { $script:Reply.WriterExited = $false }
            WrongVersion { $script:Reply.Version = '1' }
        }
        $manifest = New-DumpManifest
        Assert-Throws { Invoke-MemLabsFirstLogonHangDump -VM $vm -GuestCredential $credential -GuestBlock $guestBlock -Manifest $manifest } 'Invalid|unverified'
        Assert-True ($manifest.HangDump.Status -eq 'Indeterminate') "$variant became safe shutdown/copy evidence."
    }
    $script:Reply = $capture; $script:TransportFails = $true
    $manifest = New-DumpManifest; $calls = $script:RpcCalls
    Assert-Throws { Invoke-MemLabsFirstLogonHangDump -VM $vm -GuestCredential $credential -GuestBlock $guestBlock -Manifest $manifest } 'transport outcome'
    Assert-True ($script:RpcCalls -eq $calls + 1 -and $manifest.HangDump.Status -eq 'Indeterminate') 'Unknown capture was retried.'
    $script:TransportFails = $false; $script:Late = $true
    $manifest = New-DumpManifest
    Assert-Throws { Invoke-MemLabsFirstLogonHangDump -VM $vm -GuestCredential $credential -GuestBlock $guestBlock -Manifest $manifest -TimeoutSeconds 1 } 'after its 1s deadline'
    $script:Late = $false
    $manifest = New-DumpManifest; $manifest.HangDump.Status = 'Captured'
    $manifest.HangDump.Capture = [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($capture))
    $manifest.HangDump.Capture.Sha256 = '0' * 64
    $badBundle = Join-Path $root 'bad-copy'
    $null = New-Item -Path $badBundle -ItemType Directory
    Assert-Throws { Copy-MemLabsOfflineFirstLogonDump -WindowsRoot (Join-Path $root 'Windows') -Bundle $badBundle -Manifest $manifest } 'does not match'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $badBundle 'FirstLogonAnim.dmp'))) 'A failed dump digest left an apparently valid host copy.'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
Write-Host 'PASS -- compiled native dump writer, exact FirstLogon target/start identity, bounded owned-child capture, no target termination, protected offline transfer/digest, explicit failures, and no boot/repair.'
