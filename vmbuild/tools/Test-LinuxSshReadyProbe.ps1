<#
.SYNOPSIS
    Regression test for the Linux SSH probe's null-stdin argument contract.

.DESCRIPTION
    AST-extracts Invoke-LinuxSshReadyProbe from common\Common.Linux.ps1 and
    executes it in Start-Job against a deterministic local fake executable.
    The fake records argv and exits only when -n is present. A planted pre-fix
    copy with only -n removed must return ExitCode 124 and TimedOut true. This
    enforces the OpenSSH argument contract and watchdog cleanup; it does not
    emulate OpenSSH's own stdin handling.
#>
[CmdletBinding()]
param(
    [string] $RootPath,
    [ValidateRange(5, 120)]
    [int] $JobTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:ControlsExecuted = 0
$script:JobIds = New-Object System.Collections.Generic.List[int]
$tempDirectory = $null
$fakeProcessName = $null

function Add-Failure {
    param([string] $Message)
    $script:Failures++
    Write-Host "FAIL  $Message" -ForegroundColor Red
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    if ("$Expected" -ceq "$Actual") {
        Write-Host "PASS  $What" -ForegroundColor Green
    }
    else {
        Add-Failure "$What (expected '$Expected', actual '$Actual')"
    }
}

function Assert-SequenceEqual {
    param([string[]] $Expected, [string[]] $Actual, [string] $What)
    if ($Expected.Count -ne $Actual.Count) {
        Add-Failure "$What (expected $($Expected.Count) arguments, actual $($Actual.Count): $($Actual -join ' | '))"
        return
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if (-not [string]::Equals($Expected[$index], $Actual[$index], [StringComparison]::Ordinal)) {
            Add-Failure "$What (argument $index expected '$($Expected[$index])', actual '$($Actual[$index])')"
            return
        }
    }
    Write-Host "PASS  $What" -ForegroundColor Green
}

function ConvertFrom-FakeOutput {
    param([string] $Output)
    foreach ($line in @($Output -split '\r?\n' | Where-Object { $_ })) {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    }
}

function Get-FakeProcessCount {
    if (-not $fakeProcessName) { return 0 }
    return @(Get-Process -Name $fakeProcessName -ErrorAction SilentlyContinue).Count
}

function Stop-FakeProcesses {
    if (-not $fakeProcessName) { return }
    foreach ($process in @(Get-Process -Name $fakeProcessName -ErrorAction SilentlyContinue)) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void] $process.WaitForExit(5000)
            }
        }
        catch { }
        finally { $process.Dispose() }
    }
}

function Invoke-ProbeCase {
    param(
        [string] $Name,
        [string] $FunctionText,
        [string] $Executable,
        [string] $KeyPath,
        [string] $IPAddress
    )

    $job = Start-Job -Name "LinuxSshReadyProbe-$Name-$([guid]::NewGuid().ToString('N'))" `
        -ArgumentList $FunctionText, $Executable, $KeyPath, $IPAddress -ScriptBlock {
            param($FunctionText, $Executable, $KeyPath, $IPAddress)
            $ErrorActionPreference = 'Stop'
            . ([scriptblock]::Create($FunctionText))
            Invoke-LinuxSshReadyProbe -SshExe $Executable -PrivateKeyPath $KeyPath `
                -IPAddress $IPAddress -TimeoutSeconds 1
        }
    $script:JobIds.Add($job.Id)

    try {
        $completed = Wait-Job -Job $job -Timeout $JobTimeoutSeconds
        $hostTimedOut = $null -eq $completed
        $received = @()
        $jobErrors = @()
        if (-not $hostTimedOut) {
            $received = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
        }
        [pscustomobject]@{
            JobId        = $job.Id
            State        = "$($job.State)"
            HostTimedOut = $hostTimedOut
            Received     = $received
            ErrorCount   = @($jobErrors).Count
        }
    }
    finally {
        if ($job.State -in @('NotStarted', 'Running', 'Stopping')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

try {
    $sourcePath = Join-Path $RootPath 'common\Common.Linux.ps1'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "source file not found: $sourcePath"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $sourcePath).Path,
        [ref] $tokens,
        [ref] $parseErrors
    )
    if (@($parseErrors).Count) { throw "$sourcePath has parse errors" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-LinuxSshReadyProbe'
            }, $true))
    if ($definitions.Count -ne 1) {
        throw "expected one Invoke-LinuxSshReadyProbe definition, found $($definitions.Count)"
    }
    $shippedFunction = $definitions[0].Extent.Text

    [regex] $removeDetachedInput = "(?m)^[ \t]*'-n',[ \t]*\r?\n"
    if ($removeDetachedInput.Matches($shippedFunction).Count -ne 1) {
        throw "expected exactly one standalone '-n' argument in Invoke-LinuxSshReadyProbe"
    }
    $preFixFunction = $removeDetachedInput.Replace($shippedFunction, '', 1)
    if ($removeDetachedInput.IsMatch($preFixFunction)) {
        throw "planted pre-fix control still contains '-n'"
    }

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'memlabs-linux-ssh-ready-' + [guid]::NewGuid().ToString('N')
    )
    [void] (New-Item -ItemType Directory -Path $tempDirectory)
    $fakeProcessName = 'mlssh' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fakeSourcePath = Join-Path $tempDirectory "$fakeProcessName.cs"
    $fakeExecutable = Join-Path $tempDirectory "$fakeProcessName.exe"
    $privateKeyPath = Join-Path $tempDirectory 'private key fixture.pem'
    [IO.File]::WriteAllText(
        $privateKeyPath,
        'fixture',
        (New-Object Text.UTF8Encoding($false))
    )

    $fakeSource = @(
        'using System;',
        'using System.Text;',
        'using System.Threading;',
        'public static class MemLabsFakeSsh {',
        '    public static int Main(string[] args) {',
        '        foreach (string argument in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(argument)));',
        '        Console.Out.Flush();',
        '        if (Array.IndexOf(args, "-n") < 0) Thread.Sleep(Timeout.Infinite);',
        '        return 0;',
        '    }',
        '}'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText(
        $fakeSourcePath,
        $fakeSource,
        (New-Object Text.UTF8Encoding($false))
    )

    $compiler = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if (-not $compiler) {
        throw 'inbox .NET Framework C# compiler was not found'
    }

    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $compilerOutput = @(
            & $compiler /nologo /target:exe "/out:$fakeExecutable" $fakeSourcePath 2>&1 |
                ForEach-Object { "$_" }
        )
        $compilerExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($compilerExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $fakeExecutable -PathType Leaf)) {
        throw "fake executable compilation failed (${compilerExitCode}): $($compilerOutput -join [Environment]::NewLine)"
    }

    $ipAddress = '192.0.2.10'
    $shippedArguments = @(
        '-n', '-i', $privateKeyPath,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=1',
        '-o', 'LogLevel=ERROR',
        "vmbuildadmin@$ipAddress", 'true'
    )
    $cases = @(
        [pscustomobject]@{
            Name          = 'shipped'
            FunctionText  = $shippedFunction
            ExitCode      = 0
            TimedOut      = $false
            Arguments     = $shippedArguments
            DetachedCount = 1
        },
        [pscustomobject]@{
            Name          = 'pre-fix'
            FunctionText  = $preFixFunction
            ExitCode      = 124
            TimedOut      = $true
            Arguments     = @($shippedArguments | Where-Object { $_ -cne '-n' })
            DetachedCount = 0
        }
    )

    Write-Host "engine : $($PSVersionTable.PSVersion)"
    Write-Host "source : $sourcePath"
    foreach ($case in $cases) {
        try {
            $run = Invoke-ProbeCase -Name $case.Name -FunctionText $case.FunctionText `
                -Executable $fakeExecutable -KeyPath $privateKeyPath -IPAddress $ipAddress
            Assert-Equal $false $run.HostTimedOut "$($case.Name) job exits within the host timeout"
            Assert-Equal 'Completed' $run.State "$($case.Name) job completes normally"
            Assert-Equal 0 $run.ErrorCount "$($case.Name) job emits no error records"
            Assert-Equal 1 $run.Received.Count "$($case.Name) probe returns one result"
            if ($run.Received.Count -eq 1) {
                $script:ControlsExecuted++
                $result = $run.Received[0]
                Assert-Equal $case.ExitCode $result.ExitCode `
                    "$($case.Name) probe returns the expected exit code"
                Assert-Equal $case.TimedOut $result.TimedOut `
                    "$($case.Name) probe returns the expected timeout state"
                $actualArguments = @(ConvertFrom-FakeOutput -Output $result.Output)
                Assert-SequenceEqual $case.Arguments $actualArguments `
                    "$($case.Name) probe passes the exact argument vector"
                Assert-Equal $case.DetachedCount @(
                    $actualArguments | Where-Object { $_ -ceq '-n' }
                ).Count "$($case.Name) argument vector has the expected -n count"
            }
            Assert-Equal 0 @(
                Get-Job -Id $run.JobId -ErrorAction SilentlyContinue
            ).Count "$($case.Name) leaves no job"
            $processCount = Get-FakeProcessCount
            Assert-Equal 0 $processCount "$($case.Name) leaves no fake process"
            if ($processCount) { Stop-FakeProcesses }
        }
        catch {
            Add-Failure "$($case.Name) control error: $($_.Exception.Message)"
            Stop-FakeProcesses
        }
    }
}
catch {
    Add-Failure "setup error: $($_.Exception.Message)"
}
finally {
    foreach ($jobId in @($script:JobIds)) {
        $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
        if ($job) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    Stop-FakeProcesses
    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
        try {
            Remove-Item -LiteralPath $tempDirectory -Recurse -Force
        }
        catch {
            Add-Failure "temporary-directory cleanup failed: $($_.Exception.Message)"
        }
    }
}

foreach ($jobId in @($script:JobIds)) {
    Assert-Equal 0 @(
        Get-Job -Id $jobId -ErrorAction SilentlyContinue
    ).Count "cleanup removed test job $jobId"
}
Assert-Equal 0 (Get-FakeProcessCount) 'cleanup removed every fake process'
if ($tempDirectory) {
    Assert-Equal $false (Test-Path -LiteralPath $tempDirectory) `
        'cleanup removed the temporary directory'
}
Assert-Equal $true ($script:ControlsExecuted -gt 0) `
    'at least one applicable control executed'
Assert-Equal 2 $script:ControlsExecuted `
    'both applicable controls executed'

if ($script:Failures) {
    Write-Host "$script:Failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All Linux SSH readiness probe checks passed.' -ForegroundColor Green