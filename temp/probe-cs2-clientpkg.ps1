# CSTEST2 (CS2-*) CAS -> child-Primary PS2 CLIENT PACKAGE content probe -- READ ONLY.
#
# Run on the Hyper-V lab host (elevated PowerShell):
#     & 'C:\memlabs\temp\probe-cs2-clientpkg.ps1'
# ...or copy/paste the whole file into the PS prompt.
#
# Why: Phase 8 InstallBoundaryGroups "$ensureClientPkgCoverage" is sitting at
#   "waiting for client package on: CS2-PS2SITESYS1.CSTEST2.COM [80/90]".
# The /90 denominator ONLY appears when SMS_Package.StoredPkgVersion = 0 at PS2,
# i.e. the CAS-owned client package content has NOT replicated down to PS2 yet.
# This probe answers whether that is (a) genuinely slow inter-site content transfer
# or (b) the known "PS2 DP was never targeted, so the CAS never sends it" wedge.
#
# EVERYTHING BELOW IS READ-ONLY: Get-*, Select-String, WMI queries. No changes made.
# Output goes to the console AND to $env:TEMP\probe-cs2-clientpkg.txt

& {
    $ErrorActionPreference = 'Continue'

    # ---- knobs (only change if your lab names differ) ------------------------
    $VmPrefix = 'CS2-'
    $DomainNb = 'CSTEST2'
    $AdminUser = 'vmbuildadmin'
    $ClientPkgName = 'Configuration Manager Client Package'
    $OutFile = Join-Path $env:TEMP 'probe-cs2-clientpkg.txt'
    # -------------------------------------------------------------------------

    $script:Lines = New-Object System.Collections.Generic.List[string]
    function Say {
        param([string]$Text, [string]$Color = 'Gray')
        Write-Host $Text -ForegroundColor $Color
        $script:Lines.Add($Text)
    }
    function Head {
        param([string]$Text)
        Say ""
        Say ("#" * 100) 'Cyan'
        Say ("## $Text") 'Cyan'
        Say ("#" * 100) 'Cyan'
    }

    # ---------------------------------------------------------------- creds ---
    $pwPath = @(
        'E:\repos\memlabs\vmbuild\cache\vmbuildadmin.txt',
        'C:\memlabs\vmbuild\cache\vmbuildadmin.txt',
        'D:\memlabs\vmbuild\cache\vmbuildadmin.txt',
        'E:\memlabs\vmbuild\cache\vmbuildadmin.txt'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pwPath) {
        Say "Using cached admin password from: $pwPath"
        $sec = ConvertTo-SecureString ((Get-Content $pwPath -Raw).Trim()) -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("$DomainNb\$AdminUser", $sec)
    }
    else {
        $cred = Get-Credential -Message "Enter $DomainNb admin creds" -UserName "$DomainNb\$AdminUser"
    }

    function Invoke-OnVm {
        param([string]$VmName, [scriptblock]$Script, [object[]]$ArgList)
        $s = $null
        try {
            $s = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop
            Invoke-Command -Session $s -ScriptBlock $Script -ArgumentList $ArgList -ErrorAction Stop
        }
        catch { Say "  [$VmName] session/invoke FAILED: $($_.Exception.Message)" 'Red' }
        finally { if ($s) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
    }

    # Shared remote helper source: CMTrace-aware tail reader + log dir resolver.
    $remoteHelpers = @'
        $script:GetLogDir = {
            $cand = @()
            foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification','HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
                try { $d = (Get-ItemProperty -Path $k -Name 'Installation Directory' -EA Stop).'Installation Directory'; if ($d) { $cand += (Join-Path $d 'Logs') } } catch {}
            }
            $cand += @("$env:SMS_LOG_PATH", 'E:\ConfigMgr\Logs','D:\ConfigMgr\Logs','F:\ConfigMgr\Logs','C:\ConfigMgr\Logs','E:\SMS\Logs','D:\SMS\Logs','C:\SMS\Logs')
            foreach ($c in $cand) { if ($c -and (Test-Path $c)) { return $c } }
            return $null
        }
        $script:Tail = {
            param($Path, $Pattern, $Count)
            if (-not (Test-Path $Path)) { return @("  (missing: $Path)") }
            $hits = @(Get-Content $Path -Tail 8000 -EA SilentlyContinue | Where-Object { $_ -match $Pattern } | Select-Object -Last $Count)
            if (-not $hits.Count) { return @("  (no lines matching '$Pattern')") }
            @($hits | ForEach-Object {
                $m = [regex]::Match($_, '<!\[LOG\[(.*?)\]LOG\]!>')
                $t = [regex]::Match($_, 'time="([^"]+)".*?date="([^"]+)"')
                $stamp = if ($t.Success) { "$($t.Groups[2].Value) $(($t.Groups[1].Value -split '\.')[0])" } else { '' }
                if ($m.Success) { "  [$stamp] $($m.Groups[1].Value)" } else { "  $_" }
            })
        }
'@

    # =========================================================== DISCOVERY ====
    Head "DISCOVERY -- $VmPrefix* VMs and their ConfigMgr identity"
    $vms = @(Get-VM -Name "$VmPrefix*" -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' })
    if (-not $vms.Count) { Say "No running VMs matching '$VmPrefix*'. Adjust `$VmPrefix at the top of the script." 'Red'; return }
    Say ("Running VMs: " + (($vms | ForEach-Object { $_.Name }) -join ', '))

    $identity = @{}
    foreach ($v in $vms) {
        $info = Invoke-OnVm -VmName $v.Name -Script {
            $o = [ordered]@{
                Host = $env:COMPUTERNAME; SiteCode = ''; ParentSiteCode = ''; InstallDir = ''
                IsSiteServer = $false; SiteNamespaces = ''; IsDP = $false; ContentLibPath = ''; IsMP = $false
            }
            try {
                $id = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -EA Stop
                if ($id.'Site Code') { $o.SiteCode = "$($id.'Site Code')" }
                if ($id.'Parent Site Code') { $o.ParentSiteCode = "$($id.'Parent Site Code')" }
                if ($id.'Installation Directory') { $o.InstallDir = "$($id.'Installation Directory')" }
            } catch {}
            try {
                $ns = @(Get-WmiObject -Namespace 'root\SMS' -Class __NAMESPACE -EA Stop | ForEach-Object { $_.Name } | Where-Object { $_ -like 'site_*' })
                if ($ns.Count) { $o.IsSiteServer = $true; $o.SiteNamespaces = ($ns -join ',') }
            } catch {}
            try { $clp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -Name ContentLibraryPath -EA Stop).ContentLibraryPath; if ($clp) { $o.IsDP = $true; $o.ContentLibPath = "$clp" } } catch {}
            try { if (Get-Service -Name CcmExec -EA SilentlyContinue) { } ; if (Test-Path 'HKLM:\SOFTWARE\Microsoft\SMS\MP') { $o.IsMP = $true } } catch {}
            [pscustomobject]$o
        }
        if ($info) {
            $identity[$v.Name] = $info
            Say ("  {0,-22} Site={1,-4} Parent={2,-4} SiteServer={3,-5} NS={4,-14} DP={5,-5} CL={6} MP={7}" -f `
                    $v.Name, $info.SiteCode, $info.ParentSiteCode, $info.IsSiteServer, $info.SiteNamespaces, $info.IsDP, $info.ContentLibPath, $info.IsMP)
        }
    }

    $priVm = @($identity.GetEnumerator() | Where-Object { $_.Value.IsSiteServer -and $_.Value.SiteCode -eq 'PS2' } | ForEach-Object { $_.Key }) | Select-Object -First 1
    if (-not $priVm) {
        $priVm = @($identity.GetEnumerator() | Where-Object { $_.Value.IsSiteServer -and $_.Value.ParentSiteCode } | ForEach-Object { $_.Key }) | Select-Object -First 1
    }
    if (-not $priVm) { Say "Could not identify the child Primary site server. Aborting." 'Red'; return }
    $priSite = $identity[$priVm].SiteCode
    $casSite = $identity[$priVm].ParentSiteCode
    $casVm = @($identity.GetEnumerator() | Where-Object { $_.Value.IsSiteServer -and $_.Value.SiteCode -eq $casSite } | ForEach-Object { $_.Key }) | Select-Object -First 1
    $dpVms = @($identity.GetEnumerator() | Where-Object { $_.Value.IsDP } | ForEach-Object { $_.Key })
    Say ""
    Say "Resolved: Primary=$priVm (site $priSite)   Parent/CAS=$casVm (site $casSite)   DP(s)=$($dpVms -join ', ')" 'Yellow'

    # ===================================== PRIMARY: package / targeting / logs =
    Head "PRIMARY $priVm (site $priSite) -- client package state, targeting rows, logs"
    $priOut = Invoke-OnVm -VmName $priVm -ArgList @($priSite, $ClientPkgName, $remoteHelpers) -Script {
        param($site, $pkgName, $helpers)
        . ([scriptblock]::Create($helpers))
        $o = New-Object System.Collections.Generic.List[string]
        $ns = "root\SMS\site_$site"
        $fqdnOf = { param($nal) if ("$nal" -match '\\([^\\"\]]+)') { $Matches[1] } else { $null } }
        $stateName = @{ '0' = 'Installed'; '1' = 'InstallPending'; '2' = 'InstallRetrying'; '3' = 'InstallFailed'; '6' = 'RemovalFailed'; '7' = 'ContentValidating'; '8' = 'ContentValidationFailed' }

        $o.Add("== SMS_Package rows named '$pkgName' at $ns ==")
        $pkgs = @()
        try {
            $pkgs = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "Name='$pkgName'" -EA Stop)
            if (-not $pkgs.Count) { $o.Add("  (NONE)") }
            foreach ($p in $pkgs) {
                $o.Add(("  PackageID={0}  SourceSite={1}  SourceVersion={2}  StoredPkgVersion={3}  PkgFlags=0x{4:X}  PkgSourcePath='{5}'" -f `
                            $p.PackageID, $p.SourceSite, $p.SourceVersion, $p.StoredPkgVersion, [int]$p.PkgFlags, $p.PkgSourcePath))
                if ([int]$p.StoredPkgVersion -lt 1) { $o.Add("     ^^ StoredPkgVersion=0 -> NO LOCAL CONTENT at $site; must replicate down from $($p.SourceSite)") }
            }
        }
        catch { $o.Add("  query failed: $($_.Exception.Message)") }

        foreach ($p in $pkgs) {
            $pid2 = $p.PackageID
            $o.Add("")
            $o.Add("== SMS_DistributionPoint (TARGETING) rows for $pid2 at $ns ==")
            try {
                $rows = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$pid2'" -EA Stop)
                if (-not $rows.Count) { $o.Add("  (NONE -- package is not targeted at ANY DP from this site's view)") }
                foreach ($r in $rows) { $o.Add(("  DP={0,-32} SiteCode={1,-4} RefreshNow={2} SourceSite={3}" -f (& $fqdnOf $r.ServerNALPath), $r.SiteCode, $r.RefreshNow, $r.SourceSite)) }
            }
            catch { $o.Add("  query failed: $($_.Exception.Message)") }

            $o.Add("== SMS_PackageStatusDistPointsSummarizer rows for $pid2 at $ns ==")
            try {
                $rows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$pid2'" -EA Stop)
                if (-not $rows.Count) { $o.Add("  (NONE -- no DP has reported any status)") }
                foreach ($r in $rows) {
                    $sn = if ($stateName.ContainsKey("$([int]$r.State)")) { $stateName["$([int]$r.State)"] } else { "State$($r.State)" }
                    $o.Add(("  DP={0,-32} State={1,-22} SourceVersion={2} LastCopied={3} SiteCode={4}" -f (& $fqdnOf $r.ServerNALPath), $sn, $r.SourceVersion, $r.LastCopiedTime, $r.SiteCode))
                }
            }
            catch { $o.Add("  query failed: $($_.Exception.Message)") }
        }

        $o.Add("")
        $o.Add("== SMS_DistributionPointInfo (registered DPs) at $ns ==")
        try { foreach ($d in @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPointInfo -EA Stop)) { $o.Add(("  {0,-34} SiteCode={1,-4} IsPullDP={2} Version={3}" -f $d.ServerName, $d.SiteCode, $d.IsPullDP, $d.Version)) } }
        catch { $o.Add("  query failed: $($_.Exception.Message)") }

        $o.Add("")
        $o.Add("== Boundary groups + their site systems at $ns ==")
        try {
            $bgById = @{}
            foreach ($bg in @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -EA Stop)) { $bgById["$($bg.GroupID)"] = $bg.Name }
            foreach ($l in @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -EA Stop)) {
                $n = if ($bgById.ContainsKey("$($l.GroupID)")) { $bgById["$($l.GroupID)"] } else { "GroupID $($l.GroupID)" }
                $o.Add(("  BG '{0}' -> {1}" -f $n, (& $fqdnOf $l.ServerNALPath)))
            }
        }
        catch { $o.Add("  query failed: $($_.Exception.Message)") }

        $o.Add("")
        $o.Add("== Replication link status (SMS_ReplicationLink / SMS_ReplicationData) ==")
        foreach ($cls in @('SMS_ReplicationLink', 'SMS_ReplicationData')) {
            try {
                foreach ($r in @(Get-WmiObject -Namespace $ns -Class $cls -EA Stop)) {
                    $o.Add("  [$cls] " + (($r.Properties | Where-Object { $_.Name -match 'Site|Status|State|Link|Type' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))
                }
            }
            catch { $o.Add("  [$cls] not available: $($_.Exception.Message)") }
        }

        $logDir = & $script:GetLogDir
        $o.Add("")
        $o.Add("== Logs on $env:COMPUTERNAME (dir: $logDir) ==")
        if ($logDir) {
            $pat = ($pkgs | ForEach-Object { $_.PackageID }) -join '|'
            if (-not $pat) { $pat = 'CLIENT' }
            foreach ($lg in @('distmgr.log', 'PkgXferMgr.log', 'despool.log', 'sender.log', 'rcmctrl.log')) {
                $o.Add("`n-- $lg (last 25 matching '$pat|Client Package|instruction') --")
                $o.AddRange([string[]](& $script:Tail (Join-Path $logDir $lg) "$pat|Client Package|instruction" 25))
            }
        }
        , $o.ToArray()
    }
    if ($priOut) { foreach ($l in $priOut) { Say $l } }

    # ================================================ CAS: does it target PS2? =
    if ($casVm) {
        Head "CAS $casVm (site $casSite) -- does the CAS see a PS2-side DP for the client package?"
        $casOut = Invoke-OnVm -VmName $casVm -ArgList @($casSite, $priSite, $ClientPkgName, $remoteHelpers) -Script {
            param($site, $childSite, $pkgName, $helpers)
            . ([scriptblock]::Create($helpers))
            $o = New-Object System.Collections.Generic.List[string]
            $ns = "root\SMS\site_$site"
            $fqdnOf = { param($nal) if ("$nal" -match '\\([^\\"\]]+)') { $Matches[1] } else { $null } }

            $o.Add("== SMS_Package rows named '$pkgName' at $ns ==")
            $pkgs = @()
            try {
                $pkgs = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "Name='$pkgName'" -EA Stop)
                foreach ($p in $pkgs) { $o.Add(("  PackageID={0} SourceSite={1} SourceVersion={2} StoredPkgVersion={3}" -f $p.PackageID, $p.SourceSite, $p.SourceVersion, $p.StoredPkgVersion)) }
                if (-not $pkgs.Count) { $o.Add("  (NONE)") }
            }
            catch { $o.Add("  query failed: $($_.Exception.Message)") }

            foreach ($p in $pkgs) {
                $pid2 = $p.PackageID
                $o.Add("")
                $o.Add("== CAS view: SMS_DistributionPoint targeting rows for $pid2 (GLOBAL data) ==")
                try {
                    $rows = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$pid2'" -EA Stop)
                    if (-not $rows.Count) { $o.Add("  (NONE)") }
                    $sawChild = $false
                    foreach ($r in $rows) {
                        $o.Add(("  DP={0,-32} SiteCode={1,-4}" -f (& $fqdnOf $r.ServerNALPath), $r.SiteCode))
                        if ("$($r.SiteCode)" -eq $childSite) { $sawChild = $true }
                    }
                    if ($sawChild) { $o.Add("  ==> CAS DOES see a $childSite DP for $pid2 -- targeting replicated UP; content transfer should be scheduled.") }
                    else { $o.Add("  ==> CAS does NOT see any $childSite DP for $pid2 -- THIS IS THE WEDGE: the CAS will never send content down.") }
                }
                catch { $o.Add("  query failed: $($_.Exception.Message)") }
            }

            $logDir = & $script:GetLogDir
            $o.Add("")
            $o.Add("== CAS logs (dir: $logDir) ==")
            if ($logDir) {
                $pat = (($pkgs | ForEach-Object { $_.PackageID }) -join '|')
                if ($pat) { $pat = "$pat|$childSite" } else { $pat = $childSite }
                foreach ($lg in @('distmgr.log', 'PkgXferMgr.log', 'sender.log', 'replmgr.log')) {
                    $o.Add("`n-- $lg (last 25 matching '$pat') --")
                    $o.AddRange([string[]](& $script:Tail (Join-Path $logDir $lg) $pat 25))
                }
            }
            , $o.ToArray()
        }
        if ($casOut) { foreach ($l in $casOut) { Say $l } }
    }
    else { Say "No CAS VM resolved (parent site code '$casSite') -- skipping CAS section." 'Yellow' }

    # ============================================ DP: content library reality ==
    foreach ($d in $dpVms) {
        Head "DP $d -- content library / PkgLib / smsdpprov"
        $dpOut = Invoke-OnVm -VmName $d -ArgList @($remoteHelpers) -Script {
            param($helpers)
            . ([scriptblock]::Create($helpers))
            $o = New-Object System.Collections.Generic.List[string]
            $clRoot = $null
            try { $clRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -Name ContentLibraryPath -EA Stop).ContentLibraryPath } catch {}
            if (-not $clRoot) { foreach ($c in @('E:\SCCMContentLib', 'D:\SCCMContentLib', 'F:\SCCMContentLib', 'C:\SCCMContentLib')) { if (Test-Path (Join-Path $c 'PkgLib')) { $clRoot = $c; break } } }
            $o.Add("ContentLibraryPath: $clRoot")
            if ($clRoot) {
                $pl = Join-Path $clRoot 'PkgLib'
                $o.Add("PkgLib reachable: $(Test-Path $pl)")
                if (Test-Path $pl) {
                    $inis = @(Get-ChildItem $pl -Filter '*.INI' -EA SilentlyContinue | Select-Object -ExpandProperty Name)
                    $o.Add("PkgLib entries ($($inis.Count)): $($inis -join ', ')")
                }
                if ($clRoot -notlike '\\*') {
                    try { $drv = Get-PSDrive -Name $clRoot.Substring(0, 1) -EA Stop; $o.Add("Drive $($clRoot.Substring(0,1)): free $([math]::Round($drv.Free/1GB,1))GB") } catch {}
                }
            }
            foreach ($p in @("$env:SystemDrive\SMS_DP$\sms\logs\smsdpprov.log", 'E:\SMS_DP$\sms\logs\smsdpprov.log', 'D:\SMS_DP$\sms\logs\smsdpprov.log', 'F:\SMS_DP$\sms\logs\smsdpprov.log')) {
                if (Test-Path $p) {
                    $o.Add("`n-- smsdpprov.log ($p) last 25 matching 'CS1|PS2|package|content' --")
                    $o.AddRange([string[]](& $script:Tail $p 'CS1|PS2|package|content' 25))
                    break
                }
            }
            , $o.ToArray()
        }
        if ($dpOut) { foreach ($l in $dpOut) { Say $l } }
    }

    # ------------------------------------------------------------------ save --
    Head "DONE"
    try {
        $script:Lines | Set-Content -Path $OutFile -Encoding UTF8
        Say "Full output saved to: $OutFile" 'Green'
        Write-Host "`nPaste that file back into chat." -ForegroundColor Green
    }
    catch { Write-Host "Could not write $OutFile : $($_.Exception.Message)" -ForegroundColor Red }
}
