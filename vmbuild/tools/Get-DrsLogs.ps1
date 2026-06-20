<#
.SYNOPSIS
    Pulls ConfigMgr DRS / replication logs from the cstest7 CAS + Primary (+MP) into
    vmbuild\logs\drs-investigation\<VMName>\ via PowerShell Direct (no SMB/network needed).

.DESCRIPTION
    For each target site server it:
      - opens a PowerShell Direct session (Invoke-Command/New-PSSession -VMName),
      - resolves the real CM log dir from HKLM:\SOFTWARE\Microsoft\SMS\Setup\"Installation Directory"\Logs,
      - copies the replication-relevant logs (rcmctrl, smsexec, hman, sender, despool, replmgr, dataldr)
        plus C:\ConfigMgrSetup.log, INCLUDING the rolled-over .lo_ files,
      - also captures a live SQL snapshot of ServerData.SiteStatus + vReplicationData init status
        (so we can see what state each site is in right now).

    Safe / read-only: only reads logs and runs SELECTs. Nothing is modified on the guests.

.PARAMETER Credential
    Domain admin (or local admin) credential for the guests. If omitted you are prompted.
    Default user is cstest7\admin.

.PARAMETER VMNames
    Site servers to collect from. Default: the cstest7 CAS, Primary, and MP/DP.

.EXAMPLE
    .\Get-DrsLogs.ps1
    # prompts for the cstest7\admin password, pulls logs for CS1SITE/PS1SITE/PS1DPMP1
#>
[CmdletBinding()]
param(
    [pscredential]$Credential,
    [string[]]$VMNames = @('CT7-PS1SITE', 'CT7-CS1SITE', 'CT7-PS1DPMP1')
)

$ErrorActionPreference = 'Stop'

# Destination under the workspace logs folder so VS Code / the agent can read them.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$destRoot = Join-Path $scriptRoot 'logs\drs-investigation'
New-Item -ItemType Directory -Path $destRoot -Force | Out-Null

if (-not $Credential) {
    $Credential = Get-Credential -UserName 'cstest7\admin' -Message 'Domain admin for the cstest7 guests (PowerShell Direct)'
}

# Log basenames to collect from the CM Logs dir. The *.lo_ rollover is captured by the wildcard.
$cmLogNames = @(
    'rcmctrl',   # DRS replication config monitor  <-- the key one
    'smsexec',   # SMS Executive
    'hman',      # Hierarchy Manager (site attach / parent-child)
    'sender',    # inter-site sender
    'despool',   # inbound inter-site despooler
    'replmgr',   # replication manager
    'dataldr'    # inventory data loader (primary)
)

foreach ($vm in $VMNames) {
    Write-Host "==== $vm ====" -ForegroundColor Cyan
    $vmDest = Join-Path $destRoot $vm
    New-Item -ItemType Directory -Path $vmDest -Force | Out-Null

    $session = $null
    try {
        $session = New-PSSession -VMName $vm -Credential $Credential -ErrorAction Stop
    }
    catch {
        Write-Warning "[$vm] Could not open PowerShell Direct session: $($_.Exception.Message)"
        continue
    }

    try {
        # Resolve the CM Logs directory from the guest registry (most reliable across installs).
        $logDir = Invoke-Command -Session $session -ScriptBlock {
            $candidates = @()
            try {
                $instDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop).'Installation Directory'
                if ($instDir) { $candidates += (Join-Path $instDir 'Logs') }
            }
            catch {}
            $candidates += @('E:\ConfigMgr\Logs', 'D:\Program Files\Microsoft Configuration Manager\Logs', 'C:\Program Files\Microsoft Configuration Manager\Logs')
            foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
            return $null
        }

        if (-not $logDir) {
            Write-Warning "[$vm] Could not locate CM Logs directory (is this a site server?)."
        }
        else {
            Write-Host "[$vm] CM Logs dir: $logDir"
            foreach ($name in $cmLogNames) {
                # match name.log, name.lo_, and any name-<timestamp>.log rollovers
                $remoteGlob = Join-Path $logDir ("$name*.lo*")
                $files = Invoke-Command -Session $session -ScriptBlock {
                    param($g) Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                } -ArgumentList $remoteGlob
                foreach ($f in $files) {
                    try {
                        Copy-Item -FromSession $session -Path $f -Destination $vmDest -Force
                        Write-Host "  pulled $(Split-Path $f -Leaf)"
                    }
                    catch { Write-Warning "  [$vm] failed to copy $f : $($_.Exception.Message)" }
                }
            }
        }

        # ConfigMgrSetup.log (+rollover) lives at the system-drive root, not the Logs dir.
        $setupFiles = Invoke-Command -Session $session -ScriptBlock {
            Get-ChildItem -Path 'C:\ConfigMgrSetup.lo*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        }
        foreach ($f in $setupFiles) {
            try {
                Copy-Item -FromSession $session -Path $f -Destination $vmDest -Force
                Write-Host "  pulled $(Split-Path $f -Leaf)"
            }
            catch { Write-Warning "  [$vm] failed to copy $f : $($_.Exception.Message)" }
        }

        # Live SQL snapshot of replication state (read-only). Best-effort.
        $sqlSnap = Invoke-Command -Session $session -ScriptBlock {
            try {
                $cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
                $cn.Open()
                $dbCmd = $cn.CreateCommand()
                $dbCmd.CommandText = "SELECT TOP 1 name FROM sys.databases WHERE name LIKE 'CM[_]%' ORDER BY name"
                $db = $dbCmd.ExecuteScalar()
                if (-not $db) { return "No CM_ database found on localhost." }
                $cn.ChangeDatabase($db)
                $out = @("DB: $db", "")
                $q1 = $cn.CreateCommand()
                $q1.CommandText = "SELECT SiteCode, SiteStatus FROM ServerData"
                $r = $q1.ExecuteReader()
                $out += "ServerData (SiteStatus: 115=ReplInitializing 120=ReplMaintenance 125=ReplActive):"
                while ($r.Read()) { $out += ("  {0} = {1}" -f $r['SiteCode'], $r['SiteStatus']) }
                $r.Close()
                $q2 = $cn.CreateCommand()
                $q2.CommandText = "SELECT ReplicationGroup, ReplicationPattern, InitializationStatus, SyncStatus FROM vReplicationData ORDER BY InitializationStatus, ReplicationGroup"
                $r2 = $q2.ExecuteReader()
                $out += "", "vReplicationData (InitializationStatus: lower = not yet active):"
                while ($r2.Read()) { $out += ("  {0,-32} {1,-8} init={2} sync={3}" -f $r2['ReplicationGroup'], $r2['ReplicationPattern'], $r2['InitializationStatus'], $r2['SyncStatus']) }
                $r2.Close()
                $cn.Close()
                return ($out -join "`r`n")
            }
            catch { return "SQL snapshot failed: $($_.Exception.Message)" }
        }
        $sqlSnap | Out-File -FilePath (Join-Path $vmDest 'replication-state-snapshot.txt') -Encoding utf8
        Write-Host "  wrote replication-state-snapshot.txt"
    }
    finally {
        if ($session) { Remove-PSSession $session }
    }
}

Write-Host ""
Write-Host "Done. Logs are under: $destRoot" -ForegroundColor Green
Write-Host "Tell the agent to read vmbuild\logs\drs-investigation\CT7-PS1SITE\rcmctrl.log" -ForegroundColor Green
