#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans aged CIM proxy folders during explicit, quiescent-host maintenance.
.DESCRIPTION
    Close other PowerShell-hosting applications and stop deployments first.
    Start a fresh elevated powershell.exe -NoProfile window directly, not as a
    child of another PowerShell session. Known PowerShell hosts, remoting sessions,
    and loaded proxy modules block deletion. The MemLabs mutation lease is required.
    Only direct, non-reparse proxy directories older than one hour are eligible,
    and only when a temp directory contains more than 200 proxy directories.
.EXAMPLE
    .\Clear-CimProxyTempFolders.ps1 -WhatIf
.EXAMPLE
    .\Clear-CimProxyTempFolders.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'

function Assert-MemLabsCimProxyCleanupIdle {
    $otherHosts = @(Get-Process -ErrorAction Stop | Where-Object {
            $_.Id -ne $PID -and $_.ProcessName -match '^(pwsh|powershell|powershell_ise|wsmprovhost)$'
        })
    if ($otherHosts.Count) {
        $identities = @($otherHosts | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
        throw "CIM proxy cleanup requires a quiet host. Close other PowerShell/ISE/remoting hosts first: $identities"
    }
    $proxies = @(Get-Module -All | Where-Object {
            $_.Name -in @('DhcpServer', 'ServerManager', 'Storage', 'NetTCPIP', 'DnsClient', 'CimCmdlets') -or
            $_.Name -like 'remoteIpMoProxy_*' -or ($_.Path -and $_.Path -like '*remoteIpMoProxy_*')
        })
    if ($proxies.Count) { throw 'Loaded CIM proxy or CIM-producing modules block cleanup. Use a fresh elevated powershell.exe -NoProfile window.' }
    if (@(Get-PSSession -ErrorAction Stop).Count) { throw 'Existing remoting sessions block CIM proxy cleanup.' }
}

function Clear-MemLabsCimProxyTempFolders {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()

    if (-not $WhatIfPreference) { Assert-MemLabsCimProxyCleanupIdle }
    $tempPaths = @(
        @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP) |
            Where-Object { $_ } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } |
            Sort-Object -Unique
    )
    $cutoff = (Get-Date).AddHours(-1)
    $eligible = 0; $removed = 0; $failed = 0; $skipped = 0; $declined = 0
    foreach ($root in $tempPaths) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            Write-Warning "Skipping missing temp directory '$root'."
            continue
        }
        $proxies = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'remoteIpMoProxy_*' -ErrorAction Stop)
        if ($proxies.Count -le 200) { continue }
        $candidates = @(foreach ($directory in $proxies) {
                if ($directory.Name -notlike 'remoteIpMoProxy_*' -or
                    $directory.Parent.FullName.TrimEnd('\') -ine $root -or
                    ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $skipped++
                    Write-Warning "Skipping unverified or reparse proxy directory '$($directory.FullName)'."
                    continue
                }
                if ($directory.CreationTime -lt $cutoff -and $directory.LastWriteTime -lt $cutoff) { $directory }
            })
        $eligible += $candidates.Count
        if (-not $candidates.Count) { continue }
        if (-not $PSCmdlet.ShouldProcess($root, "Delete $($candidates.Count) aged CIM proxy folders; all other PowerShell-hosting applications must be stopped")) {
            $declined += $candidates.Count
            continue
        }
        foreach ($directory in $candidates) {
            Assert-MemLabsCimProxyCleanupIdle
            try {
                $live = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                if (-not $live.PSIsContainer -or $live.FullName -ine $directory.FullName -or $live.Name -notlike 'remoteIpMoProxy_*' -or
                    $live.Parent.FullName.TrimEnd('\') -ine $root -or
                    ($live.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    $live.CreationTime -ge $cutoff -or $live.LastWriteTime -ge $cutoff) {
                    throw 'The proxy directory changed or is no longer eligible.'
                }
                $unsafeContents = @(Get-ChildItem -LiteralPath $live.FullName -Force -ErrorAction Stop |
                    Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
                if ($unsafeContents.Count) { throw 'Nested directories or reparse contents require manual inspection.' }
                Remove-Item -LiteralPath $live.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            }
            catch {
                $failed++
                Write-Warning "Could not remove proxy directory '$($directory.FullName)': $($_.Exception.Message)"
            }
        }
    }
    if ($failed) { throw "CIM proxy cleanup removed $removed folder(s), but $failed folder(s) could not be removed. Review the warnings." }
    $status = if ($WhatIfPreference) { 'Planned' } elseif ($declined -or $skipped) { 'Partial' } else { 'Complete' }
    [pscustomobject]@{ Status = $status; Eligible = $eligible; Removed = $removed; SkippedUnsafe = $skipped; Declined = $declined }
}

if ($WhatIfPreference) { Clear-MemLabsCimProxyTempFolders @PSBoundParameters; return }
$mutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] {
        $held = $true
        Write-Warning 'The previous MemLabs mutation lease owner exited unexpectedly; acquiring the abandoned maintenance lease.'
    }
    if (-not $held) { throw 'Another MemLabs operation owns the host mutation lease. Stop it before CIM proxy maintenance.' }
    Clear-MemLabsCimProxyTempFolders @PSBoundParameters
}
finally {
    try { if ($held) { $mutex.ReleaseMutex() } }
    finally { $mutex.Dispose() }
}
