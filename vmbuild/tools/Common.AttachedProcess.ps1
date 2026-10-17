. (Join-Path $PSScriptRoot '..\DSC\phases\ProcessFunctions.ps1')

function Invoke-MemLabsAttachedPowerShell {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    if ($env:OS -ne 'Windows_NT') {
        $global:LASTEXITCODE = 0
        & (Join-Path $PSHOME 'pwsh.exe') @Arguments | Out-Host
        return [int]$LASTEXITCODE
    }
    Initialize-MemLabsJobObjectType
    $jobHandle = [MemLabs.NativeJob]::CreateJobObject([IntPtr]::Zero, $null)
    if ($jobHandle -eq [IntPtr]::Zero) { throw 'CreateJobObject failed for attached PowerShell child.' }
    $process = $null
    try {
        $info = New-Object MemLabs.NativeJob+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        $limits = New-Object MemLabs.NativeJob+JOBOBJECT_BASIC_LIMIT_INFORMATION
        $limits.LimitFlags = [MemLabs.NativeJob]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        $info.BasicLimitInformation = $limits
        $size = [Runtime.InteropServices.Marshal]::SizeOf($info)
        if (-not [MemLabs.NativeJob]::SetInformationJobObject($jobHandle, 9, [ref]$info, $size)) {
            throw 'SetInformationJobObject failed for attached PowerShell child.'
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
        $startInfo.UseShellExecute = $false
        foreach ($argument in $Arguments) { $null = $startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) { throw 'Could not start attached PowerShell child.' }
        $null = $process.Handle
        if (-not [MemLabs.NativeJob]::AssignProcessToJobObject($jobHandle, $process.Handle)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "AssignProcessToJobObject failed for attached PowerShell PID $($process.Id)."
        }
        while (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
        return [int]$process.ExitCode
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            $process.Dispose()
        }
        $null = [MemLabs.NativeJob]::CloseHandle($jobHandle)
    }
}
