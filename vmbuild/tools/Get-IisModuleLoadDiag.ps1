<#
    Pin down why w3wp cannot load an IIS module on an MP.

    Symptom this is for: 'SMS Management Point Pool' keeps getting disabled by WAS
    (System 5002 preceded by 5x 5139 with hresult 0x8007007E = ERROR_MOD_NOT_FOUND),
    the MP returns HTTP 503, and every client's ccmsetup parks on 0x87d0027e.
    Application event 2280 names the module:

        The Module DLL C:\Windows\System32\inetsrv\validcfg.dll failed to load.

    ERROR_MOD_NOT_FOUND does not say whether that DLL is absent or is present with a
    dependency that will not resolve -- opposite fixes. This answers that, and if the
    module is present it walks its PE import table and reports which imported DLL
    cannot be found.

    Read-only. It does NOT LoadLibrary anything (that runs DllMain in-process).

    Run ELEVATED on the Hyper-V host (needs Hyper-V PSDirect):

        pwsh -File vmbuild\tools\Get-IisModuleLoadDiag.ps1 -VMName PL-PATTYDP
#>
param(
    [string]$VMName = 'PL-PATTYDP',
    [pscredential]$Credential,
    [string]$ModulePath = 'C:\Windows\System32\inetsrv\validcfg.dll',
    [string]$PoolName = 'SMS Management Point Pool'
)

if (-not $Credential) {
    $Credential = Get-Credential -Message "Local/domain admin for $VMName"
}

$probe = {
    param($TargetModule, $Pool)

    function Show($t) { "`n=== $t ===" }

    # Minimal PE import-table reader. Returns the DLL names $Path imports.
    function Get-ImportedDll {
        param([string]$Path)
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            $fs.Position = $peOff
            if ($br.ReadUInt32() -ne 0x00004550) { throw 'not a PE file' }   # 'PE\0\0'
            # COFF header: +4 Machine, +6 NumberOfSections, +20 SizeOfOptionalHeader, +24 optional header
            $fs.Position = $peOff + 6
            $numSections = $br.ReadUInt16()
            $fs.Position = $peOff + 20
            $sizeOfOptional = $br.ReadUInt16()
            $optStart = $peOff + 24
            $fs.Position = $optStart
            $magic = $br.ReadUInt16()
            $dirOff = if ($magic -eq 0x20B) { 112 } else { 96 }               # PE32+ vs PE32
            $fs.Position = $optStart + $dirOff + 8                            # data dir [1] = Import
            $importRva = $br.ReadUInt32()
            if ($importRva -eq 0) { return @() }

            $secStart = $optStart + $sizeOfOptional
            $sections = @()
            for ($i = 0; $i -lt $numSections; $i++) {
                $fs.Position = $secStart + ($i * 40)
                $null = $br.ReadBytes(8)                                      # Name
                $null = $br.ReadUInt32()                                      # VirtualSize
                $va = $br.ReadUInt32()
                $rawSize = $br.ReadUInt32()
                $rawPtr = $br.ReadUInt32()
                $sections += [pscustomobject]@{ VA = $va; RawSize = $rawSize; RawPtr = $rawPtr }
            }
            function RvaToOffset($rva) {
                foreach ($s in $sections) {
                    if ($rva -ge $s.VA -and $rva -lt ($s.VA + $s.RawSize)) { return $s.RawPtr + ($rva - $s.VA) }
                }
                return 0
            }
            $names = New-Object System.Collections.Generic.List[string]
            $descOff = RvaToOffset $importRva
            if ($descOff -eq 0) { return @() }
            for ($k = 0; $k -lt 256; $k++) {
                $fs.Position = $descOff + ($k * 20)
                $origThunk = $br.ReadUInt32()
                $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
                $nameRva = $br.ReadUInt32()
                $firstThunk = $br.ReadUInt32()
                if ($origThunk -eq 0 -and $nameRva -eq 0 -and $firstThunk -eq 0) { break }
                $nOff = RvaToOffset $nameRva
                if ($nOff -eq 0) { continue }
                $fs.Position = $nOff
                $sb = New-Object System.Text.StringBuilder
                while ($true) { $b = $br.ReadByte(); if ($b -eq 0) { break }; [void]$sb.Append([char]$b) }
                if ($sb.Length) { $names.Add($sb.ToString()) }
            }
            return $names
        }
        finally { $fs.Dispose() }
    }

    Show "target module: $TargetModule"
    if (Test-Path -LiteralPath $TargetModule) {
        $fi = Get-Item -LiteralPath $TargetModule
        "  EXISTS  size=$($fi.Length)  ver=$($fi.VersionInfo.FileVersion)  modified=$($fi.LastWriteTime)"
        "  => the module itself is present, so a DEPENDENCY of it is what cannot be found"
        Show 'its imports (MISSING ones are the answer)'
        try {
            $searchDirs = @(
                (Split-Path $TargetModule -Parent)
                "$env:windir\System32"
                "$env:windir\System32\inetsrv"
                "$env:windir"
            ) + ($env:PATH -split ';' | Where-Object { $_ })
            $apiSets = 0
            $missingDeps = New-Object System.Collections.Generic.List[string]
            foreach ($dep in (Get-ImportedDll -Path $TargetModule | Sort-Object -Unique)) {
                # api-ms-win-* / ext-ms-win-* are virtual API sets resolved by the loader's
                # apiset schema, never files on disk. Testing for them is a false positive.
                if ($dep -match '^(api|ext)-ms-win-') { $apiSets++; continue }
                $hit = $null
                foreach ($d in $searchDirs) {
                    $c = Join-Path $d $dep
                    if (Test-Path -LiteralPath $c) { $hit = $c; break }
                }
                if ($hit) { "  ok      $dep  ->  $hit" }
                else { "  MISSING $dep"; $missingDeps.Add($dep) }
            }
            "  ($apiSets api-set import(s) skipped -- virtual, resolved by the loader)"
            if ($missingDeps.Count) {
                "  ==> THIS IS THE FAULT: $($missingDeps -join ', ') not found on disk"
            }
            else {
                "  ==> every real import resolves; the failure is deeper (side-by-side/activation"
                "      context, a load-time COM/registration failure, or a dependency OF a dependency)"
            }
        }
        catch { "  import walk failed: $($_.Exception.Message)" }
    }
    else {
        "  MISSING FROM DISK"
        # Windows source (Os.2020 br_current) says which component owns each module, which
        # decides the fix. inetsrv/iis/setup/manifests/IIS-NetFxExtensibility.man ships
        # validcfg.dll to $(runtime.system32)\inetsrv\, and IIS-NetFxExtensibilityCommon-GC.man
        # is what registers/unregisters it via appcmd.
        $owner = switch -Regex ($TargetModule) {
            'validcfg\.dll$' { @{ Module = 'ConfigurationValidationModule'; Component = 'Microsoft-Windows-IIS-NetFxExtensibility'; Feature = 'Web-Net-Ext45'; Optional = 'IIS-NetFxExtensibility45' } }
            default { $null }
        }
        if ($owner) {
            "  owning component : $($owner.Component)  (feature $($owner.Feature) / optional-feature $($owner.Optional))"
            $featureInstalled = $null
            try {
                if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                    $featureInstalled = [bool]((Get-WindowsFeature -Name $owner.Feature -ErrorAction SilentlyContinue).Installed)
                }
            }
            catch { }
            "  feature installed: $featureInstalled"
            if ($featureInstalled -eq $false) {
                "  ==> THE REGISTRATION IS STALE. applicationHost.config still registers"
                "      '$($owner.Module)' but the component that ships the DLL is NOT installed."
                "      sfc/DISM CANNOT restore it -- CBS considers the system correct, because"
                "      the owning component was never/no longer installed. Two supported fixes:"
                "        1. Install the owner:  Install-WindowsFeature $($owner.Feature)"
                "        2. Drop the registration, which is verbatim the uninstall action from"
                "           IIS-NetFxExtensibilityCommon-GC.man:"
                "           %windir%\system32\inetsrv\appcmd.exe uninstall module $($owner.Module)"
            }
            else {
                "  ==> the owning component IS installed but its file is gone: genuine file loss,"
                "      so 'DISM /Online /Cleanup-Image /RestoreHealth' then 'sfc /scannow' applies."
            }
        }
        else {
            "  => identify the component that ships this DLL; if that component is not installed,"
            "     sfc/DISM will NOT restore it and the registration must be dropped instead"
        }

        Show 'IIS setup / servicing log evidence for this module'
        foreach ($log in "$env:windir\iis7.log", "$env:windir\iis.log", "$env:windir\iis_gather.log") {
            if (-not (Test-Path -LiteralPath $log)) { "  (absent) $log"; continue }
            $moduleName = if ($owner) { $owner.Module } else { [IO.Path]::GetFileNameWithoutExtension($TargetModule) }
            $hits = @(Select-String -LiteralPath $log -Pattern $moduleName -ErrorAction SilentlyContinue | Select-Object -Last 6)
            "  $log ($(( Get-Item $log).Length) bytes, modified $((Get-Item $log).LastWriteTime))"
            if ($hits.Count) { $hits | ForEach-Object { "      L$($_.LineNumber): $($_.Line.Trim())" } }
            else { "      (no '$moduleName' lines)" }
        }
    }

    Show 'every globalModule image in applicationHost.config'
    try {
        $ahc = [xml](Get-Content "$env:windir\system32\inetsrv\config\applicationHost.config" -Raw)
        $missing = 0
        foreach ($gm in $ahc.configuration.'system.webServer'.globalModules.add) {
            $img = [Environment]::ExpandEnvironmentVariables("$($gm.image)")
            if ($img -and -not (Test-Path -LiteralPath $img)) { "  MISSING  $($gm.name)  ->  $img"; $missing++ }
        }
        "  $missing of $(@($ahc.configuration.'system.webServer'.globalModules.add).Count) globalModule image(s) missing"
        "  (several missing => servicing/feature damage; only one => targeted)"
    }
    catch { "  applicationHost.config read failed: $($_.Exception.Message)" }

    Show 'app pool state'
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Get-ChildItem IIS:\AppPools | Select-Object Name, State, managedRuntimeVersion, enable32BitAppOnWin64 | Format-Table -AutoSize | Out-String
    }
    catch { "  WebAdministration failed: $($_.Exception.Message)" }

    Show 'IIS + VC++ runtime servicing state'
    Get-WindowsFeature -Name Web-* -ErrorAction SilentlyContinue |
        Where-Object Installed | Select-Object -ExpandProperty Name | Sort-Object |
        ForEach-Object { "  feature $_" }
    foreach ($ucrt in 'ucrtbase.dll', 'vcruntime140.dll', 'msvcp140.dll', 'vcruntime140_1.dll') {
        $p = Join-Path "$env:windir\System32" $ucrt
        if (Test-Path -LiteralPath $p) { "  ok      $ucrt  ($((Get-Item $p).VersionInfo.FileVersion))" } else { "  MISSING $ucrt" }
    }
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Visual C\+\+|Universal CRT' } |
        Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName |
        ForEach-Object { "  installed $($_.DisplayName) $($_.DisplayVersion)" }

    Show "recent WAS/2280 events for '$Pool'"
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddHours(-6) } -MaxEvents 400 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -in 2280, 2282, 2214 } |
        Select-Object -First 3 |
        ForEach-Object { "  $($_.TimeCreated.ToString('HH:mm:ss')) id=$($_.Id): $((($_.Message -replace '\s+',' ').Trim()))" }
}

Write-Host "Probing $VMName ..." -ForegroundColor Cyan
Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $probe -ArgumentList $ModulePath, $PoolName
