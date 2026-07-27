# TwoTierPKI Step 2 (Prepare Intermediate CA on PL-HOAGIE) -- LIVE probe (read-only-ish).
# COPY THIS WHOLE FILE and PASTE into a PowerShell window on the Hyper-V host.
# Wrapped in & { ... } so the console runs the paste as one unit.
#
# What it answers:
#   1. Is Step 2 ALIVE right now? (durable guest log LastWriteTime + advancing tail)
#   2. WHERE is it? (last attempt #, last [PROGRESS]/[PKI-DIAG] lines)
#   3. Is it the settling-token race? (would a FRESH session carry Enterprise Admins now?)
#   4. Will the Config-NC write succeed now? (same create+delete probe the install uses)
#   5. Any constraint/range DS events in the last 15 min?
#
# The ONLY non-read action is a throwaway create+delete of one empty container under
# Public Key Services -- exactly what the deployment's own readiness probe does. Safe.

& {
    $ErrorActionPreference = 'Continue'
    $VM  = 'PL-HOAGIE'      # Issuing / Subordinate CA (= the DC in this topology)
    $NB  = 'PUSHLAB'        # domain NetBIOS

    # Credential: cached vmbuildadmin password if present, else prompt ONCE.
    $pwPath = @('E:\repos\memlabs\vmbuild\cache\vmbuildadmin.txt', 'C:\memlabs\vmbuild\cache\vmbuildadmin.txt', 'E:\memlabs\vmbuild\cache\vmbuildadmin.txt') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pwPath) {
        $sec = ConvertTo-SecureString ((Get-Content $pwPath -Raw).Trim()) -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$NB\vmbuildadmin", $sec)
    }
    else {
        $cred = Get-Credential -Message "Enter $NB admin creds" -UserName "$NB\vmbuildadmin"
    }

    # --- 1+2: durable guest step2 log (the primary "alive / where" signal) ---
    $sbLog = {
        $p = 'C:\staging\MemLabs-PKI-Step2.log'
        if (-not (Test-Path $p)) { return [PSCustomObject]@{ Exists = $false } }
        $fi = Get-Item -LiteralPath $p
        $ageSec = [int]((Get-Date) - $fi.LastWriteTime).TotalSeconds
        $lines = Get-Content -LiteralPath $p -ErrorAction SilentlyContinue
        $attempts = @($lines | Select-String -Pattern 'attempt (\d+)/(\d+)' -AllMatches)
        $lastAttempt = if ($attempts) { ($attempts[-1].Matches[0].Value) } else { '(none yet)' }
        [PSCustomObject]@{
            Exists      = $true
            LastWrite   = $fi.LastWriteTime.ToString('HH:mm:ss')
            AgeSec      = $ageSec
            LineCount   = $lines.Count
            LastAttempt = $lastAttempt
            Tail        = ($lines | Select-Object -Last 30) -join "`r`n"
        }
    }

    # --- 3+4+5: CA state, EA token (fresh session), Config-NC writability, DS events ---
    $sbState = {
        $out = [ordered]@{}
        try { $svc = Get-Service -Name certsvc -EA SilentlyContinue; $out.CertSvc = if ($svc) { $svc.Status } else { 'ABSENT (not yet configured)' } } catch {}
        try {
            $ntds = Get-Service -Name NTDS -EA SilentlyContinue; $out.NTDS = if ($ntds) { $ntds.Status } else { 'ABSENT' }
        } catch {}
        # CSR (.req) presence -- the Step 2 success artifact.
        try {
            $req = Get-ChildItem -Path 'C:\temp\IntCAFiles','C:\staging' -Filter '*.req' -Recurse -EA SilentlyContinue | Select-Object -First 1
            $out.CSR = if ($req) { "$($req.FullName) ($([int]$req.Length) bytes)" } else { '(none yet)' }
        } catch {}
        # THIS fresh probe session's token EA vs what a fresh S4U logon would carry.
        try {
            $procEA = @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' }).Count -gt 0
            $out.ProbeSessionEA = $procEA
        } catch { $out.ProbeSessionEA = "err: $($_.Exception.Message)" }
        try {
            $s4u = New-Object System.Security.Principal.WindowsIdentity("$env:USERNAME@$env:USERDNSDOMAIN")
            $freshEA = @($s4u.Groups | ForEach-Object { $_.Value } | Where-Object { $_ -like '*-519' }).Count -gt 0
            $s4u.Dispose(); $out.FreshLogonEA = $freshEA
        } catch { $out.FreshLogonEA = "err: $($_.Exception.Message)" }
        try { $out.GlobalCatalogReady = ([ADSI]'LDAP://RootDSE').isGlobalCatalogReady } catch {}
        # Config-NC writability: create+delete a throwaway container (what the install needs).
        try {
            $cfg = ([ADSI]'LDAP://RootDSE').configurationNamingContext
            $pks = [ADSI]"LDAP://CN=Public Key Services,CN=Services,$cfg"
            $probeName = 'memlabs-probe-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
            $child = $pks.Create('container', "CN=$probeName"); $child.SetInfo()
            try { $pks.Delete('container', "CN=$probeName") } catch {}
            $out.ConfigNCWrite = 'WRITABLE (install publish will succeed now)'
        } catch {
            $out.ConfigNCWrite = "REFUSED: $($_.Exception.Message)"
        }
        # Recent Directory Service constraint/range events (last 15 min).
        try {
            $since = (Get-Date).AddMinutes(-15)
            $evts = Get-WinEvent -FilterHashtable @{ LogName='Directory Service'; StartTime=$since } -EA SilentlyContinue |
                Where-Object { $_.Message -match 'constraint|range|acceptable' } | Select-Object -First 5
            $out.DSEvents = if ($evts) { ($evts | ForEach-Object { "$($_.Id)@$($_.TimeCreated.ToString('HH:mm:ss')): " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(160,$_.Message.Length))) }) -join "`r`n" } else { '(none in last 15 min)' }
        } catch {}
        [PSCustomObject]$out
    }

    Write-Host "`n===== TwoTierPKI Step 2 on $VM -- LIVE probe =====" -ForegroundColor Cyan
    $log = Invoke-Command -VMName $VM -Credential $cred -ScriptBlock $sbLog
    if (-not $log.Exists) {
        Write-Host "durable guest log C:\staging\MemLabs-PKI-Step2.log NOT present -- Step 2 hasn't reached the CA install yet (or a different VM)." -ForegroundColor Yellow
    }
    else {
        $aliveColor = if ($log.AgeSec -le 20) { 'Green' } elseif ($log.AgeSec -le 60) { 'Yellow' } else { 'Red' }
        Write-Host ("Guest log last written {0} ({1}s ago) | {2} lines | last {3}" -f $log.LastWrite, $log.AgeSec, $log.LineCount, $log.LastAttempt) -ForegroundColor $aliveColor
        Write-Host "  (<=20s ago = ALIVE/heartbeating; >60s = possibly wedged)" -ForegroundColor DarkGray
        Write-Host "`n--- last 30 lines of the durable step2 log ---" -ForegroundColor Yellow
        $log.Tail
    }

    Write-Host "`n--- CA state / token / Config-NC writability ---" -ForegroundColor Yellow
    $st = Invoke-Command -VMName $VM -Credential $cred -ScriptBlock $sbState
    "CertSvc            : $($st.CertSvc)"
    "NTDS               : $($st.NTDS)"
    "CSR (.req)         : $($st.CSR)"
    "ProbeSessionEA     : $($st.ProbeSessionEA)   (a FRESH session's token has Enterprise Admins?)"
    "FreshLogonEA (S4U) : $($st.FreshLogonEA)"
    "GlobalCatalogReady : $($st.GlobalCatalogReady)"
    "ConfigNCWrite      : $($st.ConfigNCWrite)"
    Write-Host "`n--- Directory Service constraint/range events (last 15 min) ---" -ForegroundColor Yellow
    $st.DSEvents

    Write-Host "`nRead:" -ForegroundColor Cyan
    Write-Host "  * log <=20s old + advancing attempt/PROGRESS = alive." -ForegroundColor Cyan
    Write-Host "  * If the log shows ACCESS_DENIED / 'access is denied' while ProbeSessionEA=True:" -ForegroundColor Cyan
    Write-Host "      => settling-TOKEN race; a host session-refresh (Tier A) fixes it." -ForegroundColor Cyan
    Write-Host "  * If the log shows RANGE_CONSTRAINT (0x80072082) while ProbeSessionEA=True AND" -ForegroundColor Cyan
    Write-Host "    ConfigNCWrite=WRITABLE: this is the post-dcpromo SCHEMA-settling window. NOTE the" -ForegroundColor Cyan
    Write-Host "    generic container write above is NOT the CA-specific attribute that is range-" -ForegroundColor Cyan
    Write-Host "    constrained, so WRITABLE does NOT mean the CA publish will succeed. Only ELAPSED" -ForegroundColor Cyan
    Write-Host "    TIME closes it (team-proven ~boot+64min). Do NOT reboot the DC (resets the clock)." -ForegroundColor Cyan
}
