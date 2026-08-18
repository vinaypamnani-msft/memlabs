#New-Lab.ps1
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Lab Configuration: Standalone, Hierarchy, etc.")]
    [ArgumentCompleter( {
            param ( $CommandName,
                $ParameterName,
                $WordToComplete,
                $CommandAst,
                $FakeBoundParameters
            )
            $ConfigPaths = Get-ChildItem -Path "$PSScriptRoot\config" -Filter *.json | Sort-Object -Property { $_.LastWriteTime -as [Datetime] } -Descending
            if ($WordToComplete) { $ConfigPaths = $ConfigPaths | Where-Object { $_.Name.ToLowerInvariant().StartsWith($WordToComplete.ToLowerInvariant()) } }
            $ConfigNames = ForEach ($Path in $ConfigPaths) {
                if ($Path.Name -eq "_storageConfig.json") { continue }
                if ($Path.Name -eq "_storageConfig2022.json") { continue }
                if ($Path.Name -eq "_storageConfig2024.json") { continue }
                If (Test-Path $Path) {
                    (Get-ChildItem $Path).BaseName
                }
            }
            return [string[]] $ConfigNames
        })]
    [string]$Configuration,
    [Parameter(Mandatory = $false, HelpMessage = "Download all files required by the specified config without deploying any VMs.")]
    [switch]$DownloadFilesOnly,
    [Parameter(Mandatory = $false, HelpMessage = "Force redownload of required files, if already present.")]
    [switch]$ForceDownloadFiles,
    [Parameter(Mandatory = $false, HelpMessage = "Timeout in minutes for VM Configuration.")]
    [int]$RoleConfigTimeoutMinutes = 300,
    [Parameter(Mandatory = $false, HelpMessage = "Do not resize PS window.")]
    [switch]$NoWindowResize,
    [Parameter(Mandatory = $false, HelpMessage = "Use Azure CDN for download.")]
    [switch]$UseCDN,
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase only. Applies to Phase > 1.")]
    [int[]]$Phase,
    [Parameter(Mandatory = $false, HelpMessage = "Skip specified Phase! Applies to Phase > 1.")]
    [int[]]$SkipPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Run specified Phase and above. Applies to Phase > 1.")]
    [ValidateRange(2, 11)]
    [int]$StartPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Stop at specified Phase!")]
    [ValidateRange(2, 11)]
    [int]$StopPhase,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run. Do not use. Deprecated.")]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false, HelpMessage = "Best not to use this. Skips configuration validation.")]
    [switch]$SkipValidation,
    [Parameter(Mandatory = $false, HelpMessage = "Migrate old VMs")]
    [switch]$Migrate,
    [Parameter(Mandatory = $false, HelpMessage = "Activate restore menu before deployment")]
    [switch]$Restore,
    [Parameter(Mandatory = $false, HelpMessage = "No prompt for domain snapshot")]
    [switch]$NoSnapshot,
    [Parameter(Mandatory = $false, HelpMessage = "Do not auto-remove Phase 1 VMs on failure (keep them around for forensics).")]
    [switch]$KeepFailedVMs,
    [Parameter(Mandatory = $false, HelpMessage = "Disable mouse support in menus.")]
    [switch]$DisableMouse,
    [Parameter(Mandatory = $false, HelpMessage = "Open a secondary window showing verbose log output in real time.")]
    [switch]$VerboseWindow

)

$global:NoSnapshot = $NoSnapshot
$global:NewLabResumeCommand = $null

function Write-NewLabResumeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Configuration,
        [Parameter(Mandatory = $true)]
        [int]$Phase,
        [switch]$Restore
    )

    $resumeCommand = "./New-Lab.ps1 -Configuration `"$Configuration`" -startPhase $Phase"
    if ($Restore.IsPresent) { $resumeCommand += " -restore" }
    $global:NewLabResumeCommand = $resumeCommand
    Write-Log $resumeCommand
    Add-CmdHistory $resumeCommand
}

# Give the user immediate visible feedback. Everything below this point (the
# shortcut creation, dot-sourcing Common.ps1, and Initialize-Common) can take
# several seconds on a cold start - especially if vmms / WMI / Hyper-V module
# autoload is slow - and until Write-Progress kicks in the host can otherwise
# look completely hung.
Write-Host ""
Write-Host "MemLabs New-Lab starting..." -ForegroundColor Cyan
Write-Host "  PID            : $PID"
Write-Host "  PowerShell     : $($PSVersionTable.PSVersion)"
Write-Host "  Script root    : $PSScriptRoot"
Write-Host "  Started (local): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Loading Common.ps1 and initializing... (this can take a few seconds on a cold start)"
Write-Host ""

try {
    $desktopPath = [Environment]::GetFolderPath("CommonDesktop")
    $shortcutLocation = "$desktopPath\MEMLABS - VMBuild.lnk"
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutLocation)
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition

    $shortcut.TargetPath = Join-Path $scriptDirectory "VmBuild.cmd"
    $shortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,208"
    $shortcut.Save()
    $exitcode = 1
    $bytes = [System.IO.File]::ReadAllBytes($shortcutLocation)
    # Set byte 21 (0x15) bit 6 (0x20) ON
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($shortcutLocation, $bytes)
}
catch {
    # Common.ps1 isn't dot-sourced yet, so Write-Log doesn't exist here.
    Write-Host "  Could not set desktop shortcut: $_"
}

# Tell common to re-init
if ($Common.Initialized) {
    $Common.Initialized = $false
}

if ($Migrate) {
    $StopPhase = 2
}

$NewLabsuccess = $false

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };

# Validate Common.ps1 has UTF-8 BOM before dot-sourcing (PS5.1 needs BOM for non-ASCII chars)
$commonPath = Join-Path $PSScriptRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. PS5.1 will fail to parse non-ASCII characters." -ForegroundColor Red
    Write-Host "Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Yellow
    Write-Host "Or restore BOM: `$c = [IO.File]::ReadAllText('$commonPath'); [IO.File]::WriteAllText('$commonPath', `$c, [Text.UTF8Encoding]::new(`$true))" -ForegroundColor Yellow
    exit 1
}

# Dot source common
. $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose -InJob:$false

if ($global:init_failed) {
    Write-Log "Failed to initialize common. Exiting." -Failure
    exit 1
}

if ($DisableMouse) {
    $Global:Common.MouseEnabled = $false
}

if ($VerboseWindow -and $enableVerbose) {
    Start-VerboseTailWindow
}


Write-Log "Post-init: Testing NoRRAS..." -LogOnly
Flush-LogBuffer -All
Test-NoRRAS

Write-Log "Post-init: Checking VMHost enhanced session mode..." -LogOnly
Flush-LogBuffer -All
# Cache the enhanced session mode check — Get-VMHost is a CIM call that can
# stall for minutes when vmms.exe is busy. The setting persists across reboots
# once enabled; only re-check once per 24 hours.
$esmCacheFile = Join-Path $Common.CachePath "vmhost-esm-state.json"
$esmNeedsCheck = $true
if (Test-Path $esmCacheFile) {
    try {
        $esmCache = Get-Content $esmCacheFile -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($esmCache -and $esmCache.Enabled -eq $true) {
            $esmAge = ((Get-Date) - [DateTime]::Parse($esmCache.CheckedUtc)).TotalHours
            if ($esmAge -le 24) {
                $esmNeedsCheck = $false
                Write-Log "Post-init: Enhanced session mode already enabled (cached, age=$([Math]::Round($esmAge,1))h)." -LogOnly
            }
        }
    }
    catch {}
}
if ($esmNeedsCheck) {
    Write-Log "Post-init: Calling Get-VMHost (CIM — may be slow if vmms is busy)..." -LogOnly
    if (((Get-VMHost).EnableEnhancedSessionMode) -eq $false) {
        Set-VMHost -EnableEnhancedSessionMode $True
    }
    try {
        [PSCustomObject]@{
            CheckedUtc = (Get-Date).ToUniversalTime().ToString("o")
            Enabled    = $true
        } | ConvertTo-Json | Set-Content -Path $esmCacheFile -Encoding UTF8
    }
    catch {}
}
Write-Log "Post-init: VMHost check complete. Proceeding to window resize and config..." -LogOnly

if (-not $NoWindowResize.IsPresent) {
    try {
        Write-Log "Post-init: Window resize - loading System.Windows.Forms..." -LogOnly
        Flush-LogBuffer -All
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary -eq $true }

        # Target columns: fit the longest help text + 6 col prefix + buffer, minimum 170.
        $curCols = $host.UI.RawUI.WindowSize.Width
        $curRows = $host.UI.RawUI.WindowSize.Height
        $helpOverhead = 8   # 6 col prefix (` │🕮  `) + 2 buffer
        $minCols = 170
        # Scan help files for longest string literal to size the terminal dynamically
        $longestHelp = 0
        $helpFiles = @(
            (Join-Path $PSScriptRoot "common\Common.GenConfig.Help.ps1"),
            (Join-Path $PSScriptRoot "genconfig.ps1")
        )
        foreach ($helpFile in $helpFiles) {
            if (Test-Path $helpFile) {
                $helpLines = Get-Content $helpFile -ErrorAction SilentlyContinue
                foreach ($line in $helpLines) {
                    # Match "H..." = "help text" pattern (genconfig) or "text" } pattern (Help.ps1)
                    if ($line -match '"H\w+"\s*=\s*"([^"]+)"' -or $line -match '"([^"]+)"[^"]*\}') {
                        $len = $Matches[1].Length
                        if ($len -gt $longestHelp) { $longestHelp = $len }
                    }
                }
            }
        }
        $targetCols = [Math]::Max($minCols, $longestHelp + $helpOverhead)
        $targetRows = 65

        $screenW = $screen.Bounds.Width
        $screenH = $screen.Bounds.Height

        # Cap target chars so window won't exceed ~92% of screen.
        # Use conservative 10px/col and 20px/row (upper bound for typical fonts).
        # This only caps on very small screens; on 1920+ it won't trigger.
        $maxCols = [int][Math]::Floor(($screenW * 0.92) / 10)
        $maxRows = [int][Math]::Floor(($screenH * 0.92) / 20)
        $targetCols = [Math]::Min($targetCols, $maxCols)
        $targetRows = [Math]::Min($targetRows, $maxRows)

        Write-Log "Post-init: Window resize - screen ${screenW}x${screenH}, current ${curCols}x${curRows} chars, target ${targetCols}x${targetRows} chars" -LogOnly

        $isWT = [bool]$env:WT_SESSION
        $wtDetected = $isWT
        $wtProcessId = $null
        $resizeDone = $false
        $myProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        $myHandle = $myProc.MainWindowHandle
        $mySessionId = $myProc.SessionId
        Write-Log "Post-init: Window resize - WT_SESSION=$(if ($isWT) { 'yes' } else { 'no' }), PID=$PID, SessionId=$mySessionId, MainWindowHandle=$myHandle" -LogOnly

        # Walk ancestors ONLY looking for WindowsTerminal - never resize anything else
        $walker = $myProc
        for ($i = 0; $i -lt 5; $i++) {
            $walker = $walker.Parent
            if (-not $walker) { break }
            Write-Log "Post-init: Window resize - ancestor[$i]: $($walker.ProcessName) (PID $($walker.Id)) Handle=$($walker.MainWindowHandle)" -LogOnly
            if ($walker.ProcessName -match '^(WindowsTerminal|Terminal)$') {
                $wtDetected = $true
                $wtProcessId = $walker.Id
                break
            }
        }
        # Also check for WT process if not found in ancestors (default terminal routing)
        if (-not $wtDetected) {
            $wtProc = Get-Process -Name 'WindowsTerminal', 'Terminal' -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $mySessionId } |
                Sort-Object StartTime -Descending | Select-Object -First 1
            if ($wtProc) {
                $wtDetected = $true
                $wtProcessId = $wtProc.Id
                Write-Log "Post-init: Window resize - found $($wtProc.ProcessName) PID $($wtProc.Id) via process search (session $mySessionId)" -LogOnly
            }
            else {
                $termProcs = Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -match 'terminal|console|conhost' -and $_.SessionId -eq $mySessionId } |
                    Select-Object ProcessName, Id, MainWindowHandle
                $termList = ($termProcs | ForEach-Object { "$($_.ProcessName)($($_.Id))=$($_.MainWindowHandle)" }) -join ', '
                Write-Log "Post-init: Window resize - no WT found. Terminal-related in session ${mySessionId}: $termList" -LogOnly
            }
        }

        Write-Log "Post-init: Window resize - wtDetected=$wtDetected, wtProcessId=$wtProcessId" -LogOnly

        # --- Primary sizing: VT escape sets exact character dimensions ---
        # \e[8;rows;cols t tells the terminal to resize to fit those chars.
        # Works in WT and modern conhost. WT adjusts the window pixel size automatically.
        Write-Log "Post-init: Window resize - sending VT escape for ${targetCols}x${targetRows} chars" -LogOnly
        Write-Host -NoNewline "`e[8;${targetRows};${targetCols}t"

        # --- Positioning: MoveWindow to (20,20) after VT resize ---
        if ($wtDetected -and $wtProcessId) {
            $wtHandle = (Get-Process -Id $wtProcessId -ErrorAction SilentlyContinue).MainWindowHandle
            Write-Log "Post-init: Window resize - WT PID $wtProcessId MainWindowHandle=$wtHandle" -LogOnly
            if ($wtHandle -ne [IntPtr]::Zero) {
                # Ensure [Window] type is loaded
                try { Set-Window -ProcessID $PID -Passthru | Out-Null } catch {}
                # Read current WT window size (post-VT-resize) and reposition to (20,20)
                $wtRect = New-Object RECT
                $null = [Window]::GetWindowRect($wtHandle, [ref]$wtRect)
                $wtW = $wtRect.Right - $wtRect.Left
                $wtH = $wtRect.Bottom - $wtRect.Top
                Write-Log "Post-init: Window resize - WT window now ${wtW}x${wtH} at ($($wtRect.Left),$($wtRect.Top))" -LogOnly
                if ($wtW -gt 0 -and $wtH -gt 0) {
                    $null = [Window]::MoveWindow($wtHandle, 20, 20, $wtW, $wtH, $true)
                    Write-Log "Post-init: Window resize - repositioned WT to (20,20)" -LogOnly
                }
                $resizeDone = $true
            }
        }

        # === Fallback for non-WT (classic conhost) ===
        if (-not $resizeDone -and -not $wtDetected) {
            # VT escape already sent above; also try Set-Window for positioning
            Write-Log "Post-init: Window resize - classic conhost path, positioning via Set-Window" -LogOnly
            $fallbackW = [int]($targetCols * 10)  # conservative pixel estimate
            $fallbackH = [int]($targetRows * 20)
            Set-Window -ProcessID $PID -X 20 -Y 20 -Width $fallbackW -Height $fallbackH
            $parent = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Parent
            if ($parent -and $parent.ProcessName -eq 'cmd') {
                Set-Window -ProcessID $parent.Id -X 20 -Y 20 -Width $fallbackW -Height $fallbackH
            }
            $null = (New-Object -ComObject WScript.Shell).AppActivate($PID)
            $resizeDone = $true
        }

        if (-not $resizeDone) { $resizeDone = $true } # VT escape was sent regardless

        # Log final char dimensions
        $finalCols = $host.UI.RawUI.WindowSize.Width
        $finalRows = $host.UI.RawUI.WindowSize.Height
        Write-Log "Post-init: Window resize - resizeDone=$resizeDone, final ${finalCols}x${finalRows} chars" -LogOnly
    }
    catch {
        Write-Log "Failed to set window size. $_" -LogOnly -Warning
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
    }
}

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    exit 1
}

# Validate PS7
if (-not $Common.PS7) {
    Write-Log "You must use PowerShell version 7.4 or above. `n  Please use VMBuild.cmd to automatically install latest version of PowerShell or install manually from https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows.`n  If PowerShell 7.1 or above is already installed, run pwsh.exe to launch PowerShell and run the script again." -Failure
    exit 1
}

 if ([Environment]::OSVersion.Version -lt [System.version]"10.0.26100.0") {
          Write-Log "This version of MemLabs requires Server 2025 or greater." -Failure  
          Install-HostToServer2025
}

Write-Log "Post-init: Set-PS7ProgressWidth..." -LogOnly
Flush-LogBuffer -All
Set-PS7ProgressWidth

New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "WinREVersion" -PropertyType String -Value "10.0.20348.2201" -Force | Out-Null

Write-Log "Post-init: Setting background image and animation..." -LogOnly
Flush-LogBuffer -All
if (-not $Common.DevBranch) {
    $image = (Join-Path $PSScriptRoot "MemLabs.png")
    Set-BackgroundImage $image "right" 5 "uniform"
    Get-Animate
}
else {
    $image = (Join-Path $PSScriptRoot "DevLabs.png")
    Set-BackgroundImage $image "right" 5 "uniform"
    Get-Animate
}

function Write-Phase {

    param(
        [int]$Phase
    )

    switch ($Phase) {
        0 {
            Write-Log "Phase $Phase - Preparing existing Virtual Machines" -Activity
        }

        1 {
            Write-Log "Phase $Phase - Creating Virtual Machines" -Activity
        }

        2 {
            Write-Log "Phase $Phase - Setup and Join Domain" -Activity
        }

        3 {
            Write-Log "Phase $Phase - Configure Virtual Machine" -Activity
        }

        4 {
            Write-Log "Phase $Phase - Install SQL" -Activity
        }

        5 {
            Write-Log "Phase $Phase - Configuring SQL Always On" -Activity
        }

        6 {
            Write-Log "Phase $Phase - Install WSUS" -Activity
        }

        7 {
            Write-Log "Phase $Phase - Setup Reporting Services" -Activity
        }

        8 {
            Write-Log "Phase $Phase - Setup ConfigMgr" -Activity
        }

        9 {
            Write-Log "Phase $Phase - Setup Multi-Forest ConfigMgr" -Activity
        }
        10 {
            Write-Log "Phase $Phase - Run Maintenance" -Activity
        }
        11 {
            Write-Log "Phase $Phase - Functional Validation" -Activity
        }
    }
}

# Main script starts here
try {

    if ($Common.PS7) {
        Write-Host
    }
    else {
        Write-Host ("`r`n" * 6)
    }

    $global:SkipValidation = $false
    if ($SkipValidation.IsPresent) {
        $global:SkipValidation = $true
    }

    $principal = new-object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-RedX "MemLabs requires administrative rights to configure. Please run vmbuild.cmd as administrator." -ForegroundColor Red
        Write-Host
        Start-Sleep -seconds 60
        exit 1
    }

    Set-QuickEdit -DisableQuickEdit
    # $phasedRun = $Phase -or $SkipPhase -or $StopPhase -or $StartPhase

    # Automatically update DSC.Zip
    if ($Common.DevBranch) {
        Set-Location $PSScriptRoot  | Out-Null
        $psdLastWriteTime = (Get-ChildItem ".\DSC\TemplateHelpDSC\TemplateHelpDSC.psd1").LastWriteTime
        $psmLastWriteTime = (Get-ChildItem ".\DSC\TemplateHelpDSC\TemplateHelpDSC.psm1").LastWriteTime
        if (Test-Path ".\DSC\DSC.zip") {
            $zipLastWriteTime = (Get-ChildItem ".\DSC\DSC.zip").LastWriteTime + (New-TimeSpan -Minutes 1)
        }
        if (-not $zipLastWriteTime -or ($psdLastWriteTime -gt $zipLastWriteTime) -or ($psmLastWriteTime -gt $zipLastWriteTime)) {
            powershell .\dsc\createGuestDscZip.ps1 | Out-Host
            Set-Location $PSScriptRoot | Out-Null
            $exitcode = 55
            exit 55
        }
    }


    # Verify Hyper-V is installed
    Write-Log "Post-init: Calling Install-HyperV..." -LogOnly
    Flush-LogBuffer -All
    Install-HyperV
    Write-Log "Post-init: Install-HyperV complete." -LogOnly
    Flush-LogBuffer -All

    ### Run maintenance
    if (-not $Configuration) {
        Write-Log "Post-init: Starting maintenance..." -LogOnly
        Start-Maintenance
        Write-Log "Post-init: Maintenance complete." -LogOnly
    }

    # Get config
    if (-not $Configuration) {
        Write-Log "No Configuration specified. Calling genconfig." -Activity
        Set-Location $PSScriptRoot
        $result = ./genconfig.ps1 -InternalUseOnly -Verbose:$enableVerbose -Debug:$enableDebug

        # genconfig was called with -Debug true, and returned DeployConfig instead of ConfigFileName
        if ($result.DeployConfig) {
            exit 0
        }

        # genconfig specified not to deploy
        if (-not $($result.DeployNow)) {
            exit 0
        }

        $Configuration = $result.ConfigFileName
    }

    Write-Log "### VALIDATE" -Activity

    # Load config
    if ($Configuration) {       
        $Global:ConfigurationShort = Split-Path $Configuration -LeafBase
        Write-Log "Validating specified configuration: $Configuration"
        $configResult = Get-UserConfiguration -Configuration $Configuration  # Get user configuration
        if ($configResult.Loaded) {
            Write-GreenCheck "Loaded Configuration: $Configuration"
            $userConfig = $configResult.Config
            $Global:configfile = $configResult.ConfigPath
            Write-Log -LogOnly "Config file: $($configResult.ConfigPath)"
        }
        else {
            Write-Log $configResult.Message -Failure
            Write-Host
            exit 1
        }
    }
    else {
        Write-Host
        Write-Log "No Configuration was specified." -Failure
        Write-Host
        exit 1
    }

    # Determine if we need to run Phase 1
    $runPhase1 = $false
    Write-Log "Calling Get-List to determine existing VMs..." -LogOnly
    $existingVMs = Get-List -Type VM -SmartUpdate
    Write-Log "Get-List returned $($existingVMs.Count) existing VMs." -LogOnly
    $newVMs = @()
    $newVMs += $userConfig.virtualMachines | Where-Object { -not $_.Hidden -and ($userConfig.vmOptions.prefix + $_.vmName -notin $existingVMs.vmName) }
    $count = ($newVMs | Measure-Object).count
    if ($count -gt 0) {
        $runPhase1 = $true
        Write-Log -Verbose "Phase 1 is scheduled to run"
    }
    else {
        Write-Log -Verbose "Phase 1 is not scheduled to run: ExistingVMs = $($existingVMs.vmName -join ",") NewVMs = $($userConfig.virtualMachines.vmName -join ",")"
    }


    # Test Config
    try {
        $testConfigResult = Test-Configuration -InputObject $userConfig -Final -StartPhase ([int]$StartPhase)
        if ($runPhase1 -eq $false -or $SkipValidation.IsPresent) {
            # Skip validation in phased run or when asked to skip
            $deployConfig = $testConfigResult.DeployConfig
            if (-not $testConfigResult.Valid) {
                Write-Host
                Write-Log "Configuration validation failed." -Failure
                Write-Host
                Write-ValidationMessages -TestObject $testConfigResult

                if ($runPhase1 -eq $false -and -not $SkipValidation.IsPresent) {         
                    Write-Host       
                    $response = Read-YesOrNoWithTimeout -Prompt "Configuration failed to validate. Continue anyway? (Y/n)" -HideHelp -Default "y" -timeout 15
                    if (-not [String]::IsNullOrWhiteSpace($response)) {
                        if ($response.ToLowerInvariant() -eq "n" -or $response.ToLowerInvariant() -eq "no") {                           
                            write-host
                            Write-Log "Validation failed. If you want to continue bypassing the checks, run the following command" 
                            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
                            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
                            write-host
                            Write-Log "If you want to retry with validation, run the following command" 
                            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`""
                            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`""
                            write-host
                            exit 1
                        }
                    }
                }
                Write-ValidationMessages -TestObject $testConfigResult
                Write-OrangePoint "Configuration validation skipped."
            }
        }
        elseif ($testConfigResult.Valid) {
            $deployConfig = $testConfigResult.DeployConfig
            Write-GreenCheck "Configuration validated successfully." -ForeGroundColor SpringGreen
        }
        else {
            Write-Host
            Write-Log "Configuration validation failed." -Failure
            Write-Host
            Write-ValidationMessages -TestObject $testConfigResult
            write-host
            Write-Log "Validation failed. If you want to continue bypassing the checks, run the following command" 
            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`" -SkipValidation"
            write-host
            Write-Log "If you want to retry with validation, run the following command" 
            Write-Log "./New-Lab.ps1 -Configuration `"$Global:configfile`""
            Add-CmdHistory "./New-Lab.ps1 -Configuration `"$Global:configfile`""
            write-host
            exit 1
        }
    }
    catch {
        Write-Log "Failed to load $Configuration.json file. Review vmbuild.log. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        Write-Host
        exit 1
    }
    #Create VM Mutexes
    $global:mutexes = @()
    foreach ($vm in $deployConfig.virtualMachines) {
        $mtx = New-Object System.Threading.Mutex($false, $vm.vmName)
        write-log -Verbose "Created Mutex $($vm.vmName)"
        if ($mtx.WaitOne(1000)) {
            $global:mutexes += $mtx
            write-log -Verbose "Acquired Mutex $($vm.vmName)"
        }
        else {
            Write-RedX "Could not acquire mutex for $(vm.vmName).  A deployment for this VM may already be in progress"
            exit 1
        }
        
    }
    # Skip if any VM in progress
    if ($runPhase1 -and (Test-InProgress -DeployConfig $deployConfig)) {
        Write-Host
        exit 1
    }

    # Timer
    $timer = New-Object -TypeName System.Diagnostics.Stopwatch
    $timer.Start()

    # Build stats: accumulate per-phase and per-VM timing throughout the build
    $global:BuildStats = @{
        Phases = @{}   # keyed by phase number -> @{ Elapsed; Success; Warning; Failed; VMCount }
        VMs    = @{}   # keyed by vmName      -> @{ Role; Phases = @{ N -> @{ Elapsed } } }
    }

    # Change log location
    $domainName = $deployConfig.vmOptions.domainName
    $domainLogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainName.log"
    Write-Log "Starting deployment. Review log:"
    Write-Host2 "  $domainLogPath"
    try { Flush-LogBuffer -All } catch { }
    $Common.LogPath = $domainLogPath

    # The deploy config JSON is written to a sidecar file next to the log
    # (<logbase>.config.json) instead of a giant single line inside the log,
    # so the log stays readable/greppable while the deployment remains
    # self-contained.
    $configSidecar = [System.IO.Path]::ChangeExtension($Common.LogPath, ".config.json")
    $jsonlSidecar = [System.IO.Path]::ChangeExtension($Common.LogPath, ".jsonl")

    #Rename the old log (and its config/jsonl sidecars) with a shared timestamp so history is preserved and they stay matched.
    try {
        $rotateStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logStem = [System.IO.Path]::GetFileNameWithoutExtension($Common.LogPath)
        if (Test-Path $Common.LogPath) {
            $logItem = Get-Item $Common.LogPath
            Rename-Item -Path $logItem.FullName -NewName ($logItem.BaseName + $rotateStamp + $logItem.Extension) -ErrorAction SilentlyContinue
        }
        if (Test-Path $configSidecar) {
            # Match the rotated log's stem: VMBuild.<domain><stamp>.config.json
            Rename-Item -Path $configSidecar -NewName ($logStem + $rotateStamp + ".config.json") -ErrorAction SilentlyContinue
        }
        if (Test-Path $jsonlSidecar) {
            # Match the rotated log's stem: VMBuild.<domain><stamp>.jsonl
            Rename-Item -Path $jsonlSidecar -NewName ($logStem + $rotateStamp + ".jsonl") -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log -verbose "Could not rename existing $($Common.LogPath)"
    }

    # Banner: stamp the fresh log with session details and a copy of the config
    # so the deployment is self-contained even if the JSON on disk is removed.
    Write-Log "========================================" -LogOnly
    Write-Log "Deployment log started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -LogOnly
    Write-Log "Configuration: $Configuration" -LogOnly
    Write-Log "ConfigFile: $($Global:configfile)" -LogOnly
    Write-Log "Domain: $domainName" -LogOnly
    Write-Log "MemLabs Version: $($Common.MemLabsVersion)" -LogOnly
    # Guest and host timezones are independent (vmOptions.timeZone is free-form), and both
    # write their CMTrace logs into this same folder. State the relationship once so a
    # reader never has to infer it from the bias suffix on individual lines.
    try {
        # TimeSpan has no pos;neg format sections and 'hh\:mm' drops the sign, so format by hand.
        $fmtOff = { param($o) '{0}{1}' -f $(if ($o.Ticks -ge 0) { '+' } else { '-' }), $o.ToString('hh\:mm') }
        $hostTz = [TimeZoneInfo]::Local
        $hostOff = [DateTimeOffset]::Now.Offset
        # The bias stamped on every host log line claims local + bias == UTC. Check it here
        # rather than trusting the offset read, so a sign error or a DST-ambiguous read is
        # caught once at startup instead of silently mis-labelling the whole run.
        $biasErrSec = [int][math]::Abs((((Get-Date).AddMinutes(-$hostOff.TotalMinutes)) - [datetime]::UtcNow).TotalSeconds)
        if ($biasErrSec -gt 2) {
            Write-Log "Timezone: HOST SELF-CHECK FAILED -- local time plus the UTC bias does not equal UTC (off by ${biasErrSec}s). Every timestamp this run writes carries a wrong bias." -Warning
        }
        $labTzId = $deployConfig.vmOptions.timeZone
        if (-not $labTzId) { $labTzId = $hostTz.Id }
        $labOff = $null
        try { $labOff = ([TimeZoneInfo]::FindSystemTimeZoneById($labTzId)).GetUtcOffset([DateTime]::UtcNow) } catch { }
        if ($null -eq $labOff) {
            Write-Log "Timezone: host '$($hostTz.Id)' (UTC$(& $fmtOff $hostOff)); lab VMs '$labTzId' -- NOT a recognized timezone id on this host, so Phase 1 Set-TimeZone will fail and the guests will keep the base image's zone." -Warning
        }
        elseif ($labOff -eq $hostOff) {
            Write-Log "Timezone: host and lab VMs both '$labTzId' (UTC$(& $fmtOff $hostOff)); host and guest log timestamps line up directly." -LogOnly
        }
        else {
            $delta = $labOff - $hostOff
            Write-Log "Timezone: host '$($hostTz.Id)' (UTC$(& $fmtOff $hostOff)) but lab VMs run '$labTzId' (UTC$(& $fmtOff $labOff)). Guest-written timestamps are $(& $fmtOff $delta) versus host lines -- compare using the +bias suffix on each CMTrace time field, not the bare clock time." -LogOnly
        }
    }
    catch {
        # Canary for the same TimeZoneInfo API the log writers use: if it throws here it
        # throws there too, and there it degrades silently to an unbiased stamp.
        Write-Log "Timezone: could not determine the host/lab timezone relationship: $($_.Exception.Message). Log timestamps will carry no UTC bias, so host and guest lines cannot be aligned." -Warning
    }
    try {
        $gitBranch = git -C $PSScriptRoot rev-parse --abbrev-ref HEAD 2>$null
        $gitHash   = git -C $PSScriptRoot rev-parse --short HEAD 2>$null
        if ($gitBranch -and $gitHash) {
            Write-Log "Git: $gitBranch @ $gitHash" -LogOnly
        }
    } catch { }
    # The Git line above describes the working tree; this one describes the code this
    # process is actually running. They diverge whenever the launcher outlives a pull.
    try {
        $staleSource = @(Get-MemLabsStaleSourceFile)
        $loadedAt = $global:MemLabsCodeLoadStamp.LoadedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        if ($staleSource.Count -gt 0) {
            $names = ($staleSource | Select-Object -First 5 -ExpandProperty Name) -join ', '
            Write-Log "STALE LAUNCHER: this process (PID $PID) parsed its code at $loadedAt; $($staleSource.Count) source file(s) have changed since -- $names. Phase scriptblock bodies are frozen at load, so those edits are NOT running in this deployment. Restart New-Lab to pick them up." -Warning
        }
        else {
            Write-Log "Code loaded at $loadedAt (PID $PID); no source file has changed since." -LogOnly
        }
    } catch { }
    Write-Log "PowerShell: $($PSVersionTable.PSVersion) (PID $PID)" -LogOnly
    Write-Log "Host PID: $PID | Parent PID: $((Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId)" -LogOnly
    Write-Log "StartPhase: $StartPhase | Phase: $Phase" -LogOnly
    Write-Log "----------------------------------------" -LogOnly
    try {
        # Pretty-print (no -Compress) to the sidecar so it's readable + diffable.
        ($deployConfig | ConvertTo-Json -Depth 10) | Set-Content -Path $configSidecar -Encoding UTF8 -ErrorAction Stop
        Write-Log "Deploy config JSON written to: $configSidecar" -LogOnly
    }
    catch {
        # Fall back to inline if the sidecar can't be written, so the deployment stays self-contained.
        Write-Log "Deploy config JSON (sidecar write failed: $($_.Exception.Message)):" -LogOnly
        Write-Log ($deployConfig | ConvertTo-Json -Depth 10 -Compress) -LogOnly
    }
    Write-Log "========================================" -LogOnly
    try { Flush-LogBuffer -Path $Common.LogPath } catch { }

    if ($Restore) {
        Write-Log "### RESTORE SNAPSHOT (Configuration '$Configuration') [MemLabs Version $($Common.MemLabsVersion)]" -Activity
        select-RestoreSnapshotDomain -domain $domainName -auto:$true
    }

    Write-Log "### START DEPLOYMENT (Configuration '$Configuration') [MemLabs Version $($Common.MemLabsVersion)]" -Activity

    # Tools are injected in Phase 2. Skip download/verify when we won't run Phase 2.
    $needTools = $true
    if ($StartPhase -and $StartPhase -gt 2) { $needTools = $false }
    if ($Phase -and 2 -notin $Phase) { $needTools = $false }

    if ($needTools) {
        # Download tools
        $success = Get-Tools -WhatIf:$WhatIf
        if (-not $success) {
            Write-Log "Failed to download tools to inject inside Virtual Machines." -Warning
        }
    }

    # The downloaded artifacts (OS base images, SQL/OS ISOs, CM media) are consumed by
    # deploy phases 1-8. Historically the download/verify pass only ran when Phase 1 was
    # scheduled (new VMs to create), so a phased re-run (-StartPhase / -Phase) that skips
    # Phase 1 never verified the files -- a missing or on-disk-corrupt SQL ISO wasn't
    # caught here and the guest SQL install in Phase 4 would loop on the bad media forever
    # (MSI 1335 / setup exit -2068052681). Run the verify pass whenever ANY file-consuming
    # phase (1-8) will actually execute, honoring the same -Phase/-SkipPhase/-StartPhase/
    # -StopPhase filters the phase loop below uses. The pass is cheap on healthy files
    # (reads the .MD5 marker + a CRC edge-probe; only re-hashes/re-downloads corrupt or
    # missing files), so this adds no meaningful time to a healthy re-run.
    $needFiles = $false
    for ($fp = 1; $fp -le 8; $fp++) {
        if ($Phase -and $fp -notin $Phase) { continue }
        if ($SkipPhase -and $fp -in $SkipPhase) { continue }
        if ($StartPhase -and $fp -lt $StartPhase) { continue }
        if ($StopPhase -and $fp -gt $StopPhase) { continue }
        $needFiles = $true
        break
    }

    if ($runPhase1 -or $needFiles) {
        # Download required files
        $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
        if (-not $success) {
            Write-Host
            Write-Log "Failed to download all required files. Retrying download of missing files in 2 minutes... " -Warning
            Start-Sleep -Seconds 120
            $success = Get-FilesForConfiguration -InputObject $deployConfig -WhatIf:$WhatIf -UseCDN:$UseCDN -ForceDownloadFiles:$ForceDownloadFiles
            if (-not $success) {
                $timer.Stop()
                Write-Log "Failed to download all required files. Exiting." -Failure
                exit 1
            }
        }

        if ($DownloadFilesOnly.IsPresent) {
            $timer.Stop()
            Write-Host
            Write-Log "### SCRIPT FINISHED. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Success
            Write-Host
            exit 0
        }
    }

    # ── Pre-fetch network state for fast verification ───────────────────
    # On reruns every switch and DHCP scope already exists.  Querying each
    # one individually costs ~12 WMI calls per network (switch, adapter,
    # IPs, NAT, DHCP service ×5, scope, scope-options).  Bulk-fetch once
    # and check in-memory to short-circuit the common case.  Any network
    # that fails the fast check falls through to Add-SwitchAndDhcp which
    # has full retry/recovery logic (including DHCP service restarts).
    $_netCache = $null
    if (-not $WhatIf.IsPresent) {
        try {
            $_netCache = @{
                Switches = @(Get-VMSwitch -SwitchType Internal -ErrorAction SilentlyContinue)
                Scopes   = @(Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)
                Nats     = @(Get-NetNat -ErrorAction SilentlyContinue)
                Adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
                IPs      = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            }
            Write-Log "Pre-cached network state: $($_netCache.Switches.Count) switches, $($_netCache.Scopes.Count) DHCP scopes, $($_netCache.Nats.Count) NAT rules." -LogOnly
        }
        catch {
            Write-Log "Network state pre-fetch failed ($_); will verify each network individually." -LogOnly
            $_netCache = $null
        }
    }

    # The DC's address on its own subnet is the DNS server every scope in this
    # domain must hand out. Resolved once so the fast path can reject a scope
    # whose option 6 still points at a previous lab's DC.
    $DNSServer = $null
    $DC = get-list2 -deployConfig $deployConfig | Where-Object { $_.role -eq "DC" } | Select-Object -First 1
    if ($DC -and $DC.Network) {
        $DNSServer = ($DC.Network.Substring(0, $DC.Network.LastIndexOf(".")) + ".1")
    }

    # Test if hyper-v switch exists, if not create it
    $AddedScopes = @($deployConfig.vmOptions.network)
    if (-not (Test-NetworkFastPath -NetworkName $deployConfig.vmOptions.network -NetworkSubnet $deployConfig.vmOptions.network -Cache $_netCache -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer)) {
        $worked = Add-SwitchAndDhcp -NetworkName $deployConfig.vmOptions.network -NetworkSubnet $deployConfig.vmOptions.network -DomainName $deployConfig.vmOptions.domainName -WhatIf:$WhatIf
        if (-not $worked) {
            exit 1
        }
    }

    # Create additional switches
    foreach ($virtualMachine in $deployConfig.VirtualMachines) {
        if ($virtualMachine.network) {
            if ($AddedScopes -contains $virtualMachine.network) {
                continue
            }
            $AddedScopes += $virtualMachine.network
            if (-not (Test-NetworkFastPath -NetworkName $virtualMachine.network -NetworkSubnet $virtualMachine.network -Cache $_netCache -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer)) {
                $worked = Add-SwitchAndDhcp -NetworkName $virtualMachine.network -NetworkSubnet $virtualMachine.network -DomainName $deployConfig.vmOptions.domainName -DNSServer $DNSServer -WhatIf:$WhatIf
                if (-not $worked) {
                    exit 1
                }
            }
        }
    }

    # Internet Client VM Switch and DHCP Scope
    $containsIN = ($deployConfig.virtualMachines.role -contains "InternetClient") -or ($deployConfig.virtualMachines.role -contains "AADClient")
    if (-not (Test-NetworkFastPath -NetworkName "Internet" -NetworkSubnet "172.31.250.0" -Cache $_netCache)) {
        $worked = Add-SwitchAndDhcp -NetworkName "Internet" -NetworkSubnet "172.31.250.0" -WhatIf:$WhatIf
        if ($containsIN -and (-not $worked)) {
            exit 1
        }
    }

    # AO VM switch and DHCP scope
    $containsAO = ($deployConfig.virtualMachines.role -contains "SQLAO")

    # Legacy SQLAO VMs use DHCP on the Cluster network (10.250.250.0).
    # If any VMs are connected to the Cluster switch, ensure DHCP+NAT exist.
    # New-style SQLAO uses static IPs on ClusterV2 and does not need the
    # Cluster network at all.
    $clusterSwitch = Get-VMSwitch -Name 'Cluster' -ErrorAction SilentlyContinue
    if ($clusterSwitch) {
        $clusterVMs = @(Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.SwitchName -eq 'Cluster' })
        if ($clusterVMs.Count -gt 0) {
            Write-Log "Cluster switch has $($clusterVMs.Count) legacy VM(s). Verifying DHCP/NAT..."
            if (-not (Test-NetworkFastPath -NetworkName "Cluster" -NetworkSubnet "10.250.250.0" -Cache $_netCache)) {
                $worked = Add-SwitchAndDhcp -NetworkName "Cluster" -NetworkSubnet "10.250.250.0" -WhatIf:$WhatIf
                if (-not $worked) {
                    exit 1
                }
            }
        }
    }

    # New-style SQLAO: ClusterV2 with static IPs only (no DHCP, no NAT).
    if ($containsAO) {
        if (-not (Test-NetworkFastPath -NetworkName "ClusterV2" -NetworkSubnet "10.250.251.0" -Cache $_netCache)) {
            $worked = Add-SwitchNoDhcp -NetworkName "ClusterV2" -NetworkSubnet "10.250.251.0" -WhatIf:$WhatIf
            if (-not $worked) {
                exit 1
            }
        }
    }

    #Make sure DHCP is still running
    get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' } | start-service
    $service = get-service "DHCPServer" | Where-Object { $_.Status -eq 'Stopped' }
    if ($service) {
        Write-Log "DHCPServer Service could not be started." -Failure
        exit 1
    }

    # Remove existing jobs
    $existingJobs = Get-Job
    if ($existingJobs) {
        Write-Log "Stopping and removing existing jobs." -Verbose -LogOnly
        foreach ($job in $existingJobs) {
            Write-Log "Removing job $($job.Id) with name $($job.Name)" -Verbose -LogOnly
            try {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -ErrorAction SilentlyContinue
            }
            catch {
                write-log "Failed to remove jobs $_"
                exit 1
            }
        }
    }

    # Show summary
    Write-Log "Deployment Summary" -Activity -HostOnly
    Show-Summary -deployConfig $deployConfig

    # Return if debug enabled
    if ($enableDebug) {
        return $deployConfig
    }

    # Prepare existing VM - Phase 0
    $prepared = $true
    # Default true like $prepared: if every phase is skipped (-Phase / -SkipPhase /
    # -StartPhase past the end) the loop never assigns it, and the end-of-run gate
    # at "if (-not $prepared -or -not $configured)" would report a run where nothing
    # ran, and nothing failed, as FINISHED WITH FAILURES.
    $configured = $true
    $containsHidden = $deployConfig.virtualMachines | Where-Object { $_.hidden -eq $true }
    if ($containsHidden) {
        Write-Phase -Phase 0
        $prepared = Resolve-PhaseResult -Raw (Start-Phase -Phase 0 -deployConfig $deployConfig -WhatIf:$WhatIf) -Phase 0
    }

    # AADClient idempotency: if an AADClient VM exists from a prior interrupted
    # run but never reached oobeComplete, it is in an unrecoverable state
    # (partial DSC, half-sysprepped, etc.). Delete it now so Phase 1 can
    # re-create from a fresh VHDX. If -StartPhase would skip Phase 1, override
    # it so the AADClient gets rebuilt before Phase 2 runs.
    $forcePhase1ForAAD = $false
    $global:ForcePhase1VmNames = @()
    $needCacheFlush = $false
    foreach ($vm in $deployConfig.virtualMachines) {
        if ($vm.role -ne "AADClient" -or $vm.hidden) { continue }
        $existingVm = Get-VM2 -Fallback -Name $vm.vmName -ErrorAction SilentlyContinue
        if (-not $existingVm) {
            # VM doesn't exist — force Phase 1 so it gets created even with -StartPhase 2+
            $global:ForcePhase1VmNames += $vm.vmName
            $forcePhase1ForAAD = $true
            # Only warn if Phase 1 would have been skipped (otherwise it runs naturally)
            if ($StartPhase -and $StartPhase -gt 1) {
                Write-Log "[Phase 0] $($vm.vmName): AADClient does not exist. Forcing Phase 1 to create it." -Warning
            }
            continue
        }
        $note = Get-VMNote -VMName $vm.vmName
        if ($note -and $note.oobeComplete) { continue }
        Write-Log "[Phase 0] $($vm.vmName): AADClient exists but oobeComplete is not set (interrupted prior run). Deleting so Phase 1 can re-create." -Warning
        Remove-VirtualMachine -VmName $vm.vmName -Force -SkipProxyCleanup
        $global:ForcePhase1VmNames += $vm.vmName
        $forcePhase1ForAAD = $true
        $needCacheFlush = $true
    }
    if ($forcePhase1ForAAD) {
        $runPhase1 = $true
        if ($needCacheFlush) {
            # Flush the VM list cache so Phase 1 sees the deleted VM as missing
            Get-List -FlushCache
        }
    }

    # Define phases
    $start = 1
    $maxPhase = 11
    $global:StartPhase = $StartPhase

    # Pre-build the host download-cache ISO ONCE, before any phase fans out to
    # per-VM jobs. Building it here (single host process) instead of lazily inside
    # each VM's DSC step avoids N separate processes racing to build the same
    # content-addressed ISO (and leaking per-PID cache-build-* staging dirs on
    # contention). The per-VM step then just finds the already-built ISO and mounts
    # it. Pure optimization: any failure is logged and ignored (guests fall back to
    # direct download). Skipped under -WhatIf and when the cache is disabled.
    if (-not $WhatIf -and (Test-MemlabsDownloadCacheEnabled)) {
        try {
            Write-Log "Pre-building host download-cache ISO before phases..." -LogOnly
            $null = Get-MemlabsCacheIsoForDeploy -DeployConfig $deployConfig -StartPhase ([int]$StartPhase)
        }
        catch {
            Write-Log "Download-cache pre-build failed (non-fatal): $($_.Exception.Message)" -LogOnly
        }
    }

    if ($prepared) {

        for ($i = $start; $i -le $maxPhase; $i++) {
            Write-Phase -Phase $i

            if ($i -eq 1 -and -not $runPhase1) {
                Write-OrangePoint "[Phase $i] Not Applicable. Skipping." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($Phase -and $i -notin $Phase) {
                Write-OrangePoint "Skipped Phase $i because -Phase is $Phase." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($SkipPhase -and $i -in $SkipPhase) {
                Write-OrangePoint "Skipped Phase $i because -SkipPhase is $SkipPhase." -ForegroundColor Yellow -WriteLog
                continue
            }

            if ($StartPhase -and $i -lt $StartPhase) {
                # Don't skip Phase 1 if we deleted stuck AADClient VMs that need re-creation
                if ($i -eq 1 -and $forcePhase1ForAAD) {
                    Write-Log "[Phase 1] Forced by AADClient cleanup (overriding -StartPhase $StartPhase)." -Warning
                }
                else {
                    Write-OrangePoint "Skipped Phase $i because -StartPhase is $StartPhase." -ForegroundColor Yellow -WriteLog
                    continue
                }
            }

            if ($StopPhase -and $i -gt $StopPhase) {
                Write-OrangePoint "Skipped Phase $i because -StopPhase is $StopPhase." -ForegroundColor Yellow -WriteLog
                continue
            }
            $lastPhase = $currentPhase
            $currentPhase = $i
            $configured = Resolve-PhaseResult -Raw (Start-Phase -Phase $i -deployConfig $deployConfig -WhatIf:$WhatIf) -Phase $i
            if ($global:PhaseSkipped) {
                $currentPhase = $lastPhase
            }
            if (-not $configured) {
                break
            }
            else {
                if ($i -eq 1) {
                    $global:ForcePhase1VmNames = @()

                    # Clear out vm remove list
                    $global:vm_remove_list = @()

                    # Create RDCMan file
                    Start-Sleep -Seconds 5
                    New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false -NoActivity -WhatIf:$WhatIf
                    New-MRemoteNGFileFromHyperV -MRemoteNGFile $Global:Common.MRemoteNGFilePath -NoActivity -WhatIf:$WhatIf
                    Restore-TerminalFocus
                    #Refresh deployConfig to add any props that may have been added in New-VirtualMachine, eg ClusterIPAddress
                    $deployConfig = ConvertTo-DeployConfigEx -DeployConfig $deployConfig
                }
                if ($i -eq 2) {
                    # Linux DNS flip from bootstrap public DNS (1.1.1.1) to the
                    # DC happens inside Start-PhaseDeployment for Phase 2 -- it
                    # must run before the proxy client config / enforcement so
                    # the Proxy is fully configured before clients route to it.
                }
                if ($i -eq 3) {
                    # PKI: orchestrate CA installation post-Phase3 (single-tier or two-tier).
                    # Deliberately run AFTER Phase 3 (not immediately after Phase 2): the CA
                    # publish writes to the freshly-promoted DC's Configuration NC, which
                    # rejects writes with 0x80072082 ERROR_DS_RANGE_CONSTRAINT for a transient
                    # post-dcpromo window. Letting Phase 3 (media download/prep) run first gives
                    # the DC extra settle time so the common case installs on the first attempt;
                    # the in-guest write-probe gate + retry/remediation loop still wait the window
                    # out if it hasn't closed yet. Phase 3 consumes no PKI certs (the first cert
                    # consumer is the Phase 8 HTTPS flip), so deferring one phase costs no
                    # autoenrollment lead time in practice.
                    # Only trigger for NEW VMs (non-hidden). If only existing/hidden VMs have
                    # InstallCA, PKI is already deployed and should not be re-orchestrated.
                    $hasPKI = @($deployConfig.virtualMachines | Where-Object { $_.InstallCA -and -not $_.hidden }).Count -gt 0
                    if ($hasPKI) {
                        $pkiSuccess = Install-PKI -DeployConfig $deployConfig
                        if (-not $pkiSuccess) {
                            Write-Log "[PKI] PKI deployment failed." -Failure
                            $configured = $false
                            break
                        }
                    }
                }
                if ($i -eq 5) {
                    # Validate SQLAO health immediately after Phase 5 DSC so
                    # cluster/AG/listener problems surface now instead of
                    # waiting until Phase 8 (CAS install) or Phase 11.
                    $hasSQLAO = @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode -and -not $_.hidden }).Count -gt 0
                    if ($hasSQLAO) {
                        $sqlaoValid = Test-SQLAOPostPhase5 -DeployConfig $deployConfig
                        if (-not $sqlaoValid) {
                            Write-Log "[Phase 5] SQLAO validation failed. Stopping build." -Failure
                            $configured = $false
                            break
                        }
                    }
                }
                if ($i -eq 11) {
                    # Phase 11 passed: merge the Phase 8 auto-snapshot if it exists
                    if (-not $global:NoSnapshot) {
                        Merge-Phase8AutoSnapshot -DeployConfig $deployConfig
                    }
                    else {
                        Write-Log "[Phase 11] Skipping snapshot merge (-NoSnapshot was specified)" -LogOnly
                    }

                    # Cross-lab proxy ACL reconciliation. Uses fixed RFC 1918
                    # allow ranges so no subnet-union computation is needed.
                    try {
                        Set-VmProxyEnforcementForAllLabs | Out-Null
                    }
                    catch {
                        Write-Log "[Phase 11] Proxy cross-lab reconcile failed (non-fatal): $_" -Warning
                    }
                }
            }
        }
    }

    $timer.Stop()

    if (-not $prepared -or -not $configured) {
        Write-Host
        Set-TitleBar "SCRIPT FINISHED WITH FAILURES"
        $NewLabsuccess = $false
        Write-Log "### SCRIPT FINISHED WITH FAILURES (Configuration '$Configuration'). Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Failure -NoIndent
        Write-Log "Log file: $($Common.LogPath)" -Warning -NoIndent
        if ($currentPhase -ge 2) {
            $offerRestore = $false
            if ($currentPhase -eq 8 -and $deployConfig) {
                try { $offerRestore = Test-Phase8AutoSnapshotExists -DeployConfig $deployConfig }
                catch { $offerRestore = $false }
            }
            if ($offerRestore) {
                write-host
                Write-Log "This failed on phase 8, please restore the phase 8 auto snapshot using the -restore option below before retrying." 
                Write-NewLabResumeCommand -Configuration $Configuration -Phase $currentPhase -Restore

            }
            else {
                Write-Host
                Write-Log "To Retry from the current phase, Reboot the VMs and run the following command from the current powershell window: " -Failure -NoIndent
                Write-NewLabResumeCommand -Configuration $Configuration -Phase $currentPhase

            }


        }
        # Show build stats collected so far (partial build)
        Write-BuildSummary
        Save-BuildStats -Configuration $Configuration -TotalElapsed $timer.Elapsed -Success $false
        Write-Host
    }
    else {
        $currentPhase = 10
        foreach ($mutex in $global:mutexes) {
            try {
                [void]$mutex.ReleaseMutex()
            }
            catch {}
            try {
                [void]$mutex.Dispose()
            }
            catch {}

        }
        $global:mutexes = @()

        #This is now done in Phase 10
        # Start-Maintenance -DeployConfig $deployConfig

        $updateExistingRequired = $false
        foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
            $updateExistingRequired = $true                    
        }

        # Update Existing VMs
        if ($updateExistingRequired) {
            Write-Log "Update Existing Virtual Machine Properties" -Activity -HostOnly

            # Capture previous useProxy values from live VM notes BEFORE the
            # update loop overwrites them. The -Original properties are
            # stripped by Add-ModifiedExistingVMToDeployConfig, so we compare
            # against the actual VM note to detect changes.
            $previousUseProxy = @{}
            foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
                if ($null -ne $vm.useProxy) {
                    $note = Get-VMNote -VMName $vm.vmName
                    if ($note) {
                        $previousUseProxy[$vm.vmName] = if ($note.PSObject.Properties.Name -contains 'useProxy') { [bool]$note.useProxy } else { $false }
                    }
                }
            }

            foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
                Write-Host "Updating VM Notes on $($vm.VmName)"
                foreach ($updatableEntry in $Global:Common.Supported.PropsToUpdate) {
                    if ($null -ne $vm."$updatableEntry") {
                        Write-Host "Updating $($vm.vmName) $updatableEntry to $($vm."$updatableEntry")"
                        Update-VMNoteProperty -vmName $vm.VmName -PropertyName $updatableEntry -PropertyValue $vm."$updatableEntry"
                    }
                }
            }

            # Apply or remove Windows proxy settings on existing VMs whose
            # useProxy property was modified. This handles the host-side
            # configuration (in-guest proxy + Hyper-V ACLs) that Phase 8
            # can't do (Phase 8 only covers CM site-system proxy via
            # ConfigureCMProxy.ps1).
            foreach ($vm in $deployConfig.VirtualMachines | Where-Object { $_.ExistingVM }) {
                if ($null -eq $vm.useProxy) { continue }
                $prevValue = if ($previousUseProxy.ContainsKey($vm.vmName)) { $previousUseProxy[$vm.vmName] } else { $false }
                if ([bool]$vm.useProxy -eq $prevValue) { continue }

                if ($vm.useProxy -eq $true) {
                    # Enabling proxy: find the Proxy VM and configure
                    $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
                    if (-not $proxyVm) {
                        $existingProxyName = Get-ExistingForDomain -DomainName $deployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
                        if ($existingProxyName) {
                            $proxyVm = [pscustomobject]@{ vmName = $existingProxyName; role = 'Proxy' }
                        }
                    }
                    if ($proxyVm) {
                        $proxyFqdn = "$($proxyVm.vmName).$($deployConfig.vmOptions.domainName)"
                        Write-Log "[Proxy] Enabling proxy on existing VM $($vm.vmName) -> $proxyFqdn`:3128"
                        # Bypass the VM's OWN subnet (a VM on a secondary subnet must not
                        # proxy its local traffic); fall back to the deployment default.
                        $bypassNet = if ($vm.network) { $vm.network } else { $deployConfig.vmOptions.network }
                        Set-WindowsClientProxy -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName `
                            -ProxyFqdn $proxyFqdn -BypassNetwork $bypassNet
                        Set-VmProxyEnforcement -VmName $vm.vmName
                    }
                    else {
                        Write-Log "[Proxy] $($vm.vmName): useProxy=true but no Proxy VM found; skipping" -Warning
                    }
                }
                else {
                    # Disabling proxy: remove in-guest config and host ACLs
                    Write-Log "[Proxy] Removing proxy from existing VM $($vm.vmName)"
                    Remove-WindowsClientProxy -VmName $vm.vmName -Domain $deployConfig.vmOptions.domainName
                    Clear-VmProxyEnforcement -VmName $vm.vmName
                }
            }
        }

        # Retrieve guest-side component timing from ScriptWorkflow.json
        # Skip on partial-phase runs — VMs may not be running and timing is incomplete
        if (-not $Phase -and -not $SkipPhase) {
            Get-GuestTimingStats -deployConfig $deployConfig
        }

        # Show complete build stats
        Write-BuildSummary
        Save-BuildStats -Configuration $Configuration -TotalElapsed $timer.Elapsed -Success $true

        Write-Host
        Set-TitleBar "SCRIPT FINISHED"
        Write-Log "### SCRIPT FINISHED (Configuration '$Configuration'). Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Activity
        $NewLabsuccess = $true
    }

}
catch {
    Write-Exception -ExceptionInfo $_ -AdditionalInfo ($deployConfig | ConvertTo-Json)
    $NewLabsuccess = $false
}
finally {

    foreach ($mutex in $global:mutexes) {
        try {
            [void]$mutex.ReleaseMutex()
        }
        catch {}
        try {
            [void]$mutex.Dispose()
        }
        catch {}

    }
    $global:mutexes = @()
    $global:BuildStats = $null

    # Eject generated cache/DSC/tools media from THIS deployment's VMs and evict
    # stale payload ISOs. Per-VM and scoped to our own VMs only, so a concurrently-
    # running deployment's mounts are never disturbed. Eviction never deletes an
    # ISO any VM on the host still has mounted.
    if ($deployConfig -and $deployConfig.virtualMachines) {
        try {
            foreach ($cacheVm in $deployConfig.virtualMachines) {
                if ($cacheVm.vmName) {
                    Dismount-MemlabsCacheIsoFromVm -VmName $cacheVm.vmName
                    Dismount-MemlabsDscIsoFromVm -VmName $cacheVm.vmName
                    Dismount-MemlabsToolsIsoFromVm -VmName $cacheVm.vmName
                    # On a SUCCESSFUL build, also strip any SQL / CM / OS install
                    # media that a per-phase eject left behind (the per-phase ejects
                    # are gated on whole-phase success, so a sibling VM's failure can
                    # orphan media on the VMs that succeeded; a -StartPhase partial
                    # run can likewise leave it mounted). This guarantees a finished
                    # lab ends with a clean optical layout -- no host ISO path baked
                    # into checkpoints / .memlabs exports, and no leftover-ISO
                    # validator trip. On a FAILED build we intentionally skip this so
                    # the media stays mounted for inspection and an idempotent
                    # -StartPhase retry (whose eventual success then sweeps it).
                    if ($NewLabsuccess -eq $true) {
                        Dismount-AllManagedIsosFromVm -VmName $cacheVm.vmName
                    }
                }
            }
            Remove-StaleMemlabsCacheIso
            Remove-StaleMemlabsDscIso
            Remove-StaleMemlabsToolsIso
        }
        catch {
            Write-Log "Download cache cleanup failed (non-fatal): $_" -LogOnly
        }
    }

    if ($enableDebug) {
        Write-Host 'Config Stored in $global:DebugConfig'
        $global:DebugConfig = $deployConfig
    }
    # Ctrl + C brings us here :)
    if ($NewLabsuccess -ne $true) {
        Write-Log "Script exited unsuccessfully. Ctrl-C may have been pressed. Killing running jobs." -LogOnly
        Set-TitleBar "Script Cancelled"
        Write-Log "### $Configuration Terminated $currentPhase" -HostOnly
        Write-Log "Log file: $($Common.LogPath)" -Warning -NoIndent
        # 55 is a self-restart request (DSC.zip was just rebuilt), not a build failure --
        # don't clobber it, or the caller can't tell the two apart.
        if ($exitcode -ne 55) {
            $exitcode = 2
        }
        if ($currentPhase -ge 2 -and $currentPhase -le $maxPhase) {
            $offerRestore = $false
            if ($currentPhase -eq 8 -and $deployConfig) {
                try { $offerRestore = Test-Phase8AutoSnapshotExists -DeployConfig $deployConfig }
                catch { $offerRestore = $false }
            }
            if ($offerRestore) {
                write-host
                Write-Log "This failed on phase 8, please restore the phase 8 auto snapshot using the -restore option below before retrying." 
                Write-NewLabResumeCommand -Configuration $Configuration -Phase $currentPhase -Restore
            }
            else {
                write-host
                Write-Log "To Retry from the current phase, Reboot the VMs and run the following command from the current powershell window: " -Failure -NoIndent
                Write-NewLabResumeCommand -Configuration $Configuration -Phase $currentPhase
            }
        }
        Write-Host
    }
    # Restore dynamic memory settings (were pinned to max during deploy for performance).
    # Skip if we never made it past Phase 1 (VMs being created/removed there aren't
    # worth touching, and the noisy "[Phase 11] Restoring dynamic memory" line on
    # an early cancel is just confusing).
    if ($deployConfig -and $currentPhase -gt 1) {
        try { Restore-DynamicMemory -DeployConfig $deployConfig } catch {
            Write-Log "Restore-DynamicMemory failed: $_" -Warning
        }
    }

    # Stop running jobs with live progress. Kill child processes early to
    # avoid Remove-Job -Force blocking for 10+ seconds per stuck job.
    $null = Write-PowerShellJobLeakDiag -Context 'before end-of-run job cleanup' -Quiet
    # PSEventJob entries are engine-event subscriptions (the log flush-on-exit
    # handler), not build work. Stopping and force-removing them tears down the
    # exit flush and loses the last buffered log lines.
    $runningJobs = @(Get-Job | Where-Object { $_.State -eq 'Running' -and $_ -isnot [System.Management.Automation.PSEventJob] })
    $totalJobs = $runningJobs.Count
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $blankLine = " " * 100
    $showElapsed = { [math]::Floor($stopWatch.Elapsed.TotalSeconds) }
    # Only the single-line progress DISPLAY depends on verbosity. The cleanup
    # itself must not: this used to be `if ($totalJobs -gt 0 -and -not
    # $enableVerbose)` with an `elseif ($totalJobs -eq 0)`, so a -Verbose run that
    # still had running jobs matched NEITHER branch and did no cleanup at all --
    # no child kill, no stop, no Remove-Job. Start-Test runs New-Lab in its OWN
    # process, so those workers stayed alive under the harness for the rest of the
    # -All run and accumulated test after test (~300MB each once they have
    # dot-sourced Common.ps1).
    $showJobProgress = -not $enableVerbose

    if ($totalJobs -gt 0) {
        # 1) Kill child pwsh.exe processes immediately — this is what actually
        #    unblocks stuck PSDirect/WMI I/O. Do it before StopJobAsync so
        #    the async stop finds the process already gone.
        if ($showJobProgress) { Write-Host -NoNewline "`r${blankLine}`rStopping $totalJobs job(s): killing child processes... ($(& $showElapsed)s)" }
        try {
            $childProcs = Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID AND Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                          Where-Object { $_.CommandLine -match '-s\s+-NoLogo' }
            foreach ($proc in $childProcs) {
                Write-Log "Killing job child process PID $($proc.ProcessId)" -LogOnly
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }

        # 2) Signal all jobs to stop (fast — processes are already dead)
        foreach ($job in $runningJobs) {
            try { $job.StopJobAsync() } catch { }
        }

        # 3) Wait-Job actively checks child process status and transitions
        #    jobs out of Running once it detects the process exited. The
        #    manual Get-Job polling we had before only read cached state and
        #    never noticed the child was dead, leaving jobs stuck in Running.
        if ($showJobProgress) { Write-Host -NoNewline "`r${blankLine}`rWaiting for jobs to stop... ($(& $showElapsed)s)" }
        $null = $runningJobs | Wait-Job -Timeout 10 -ErrorAction SilentlyContinue
    }

    # 4) Remove EVERY job, running or not. Unconditional: a job left in the table
    #    keeps its output (and any PSDirect session objects in it) referenced.
    $remaining = @(Get-Job | Where-Object { $_ -isnot [System.Management.Automation.PSEventJob] })
    if ($remaining.Count -gt 0) {
        if ($showJobProgress -and $totalJobs -gt 0) { Write-Host -NoNewline "`r${blankLine}`rRemoving $($remaining.Count) job(s)... ($(& $showElapsed)s)" }
        foreach ($job in $remaining) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    $stopWatch.Stop()
    if ($totalJobs -gt 0 -and $showJobProgress) {
        $totalElapsed = & $showElapsed
        Write-Host "`r${blankLine}`rJobs stopped. (${totalElapsed}s)"
    }

    # Anything still standing after that is a genuine leak. Name it -- a worker
    # exits by itself when its scriptblock finishes, so a survivor is a job that
    # never finished, and the log is the only place we'll ever see which.
    $leak = @(Write-PowerShellJobLeakDiag -Context 'after end-of-run job cleanup') | Select-Object -Last 1
    if ($leak -and $leak.WorkerProcs -gt 0) {
        Write-Log "$($leak.WorkerProcs) PowerShell job worker process(es) survived cleanup, holding $($leak.WorkerMB)MB. They will keep that memory until this shell exits; see the [JobLeak] lines above for pids." -Warning
    }

    # Close PS Sessions. MUST be Remove-VmSession, not Remove-PSSession:
    # New-PSSessionWithTimeout deliberately keeps the runspace it created alive on
    # success (closing it would kill the PSSession whose transport runs through it)
    # and attaches it to the session as _OwnerRunspace for exactly this cleanup.
    # Remove-PSSession does not know about that property, so every cached PSDirect
    # session leaked a whole runspace -- and Start-Test keeps this shell for the
    # entire -All run. A 2.6GB dump of the harness showed 240 retained LocalRunspace
    # objects carrying 224,468 CmdletInfo, 352,257 FieldPropertyToken and 3,877,177
    # InternalScriptExtent: 1.94GB of the 1.94GB managed heap, ~8MB per runspace.
    foreach ($session in $global:ps_cache.Keys) {
        Write-Log "Closing PS Session $session" -Verbose
        try { Remove-VmSession $global:ps_cache.$session } catch {}
    }
    $global:ps_cache = @{}

    # Reclaim runspaces parked by an abandon path (connect timeout, or a session
    # evicted with -LeakSession). -Force because every job is gone by now, so the
    # late-transport-callback hazard that made immediate disposal unsafe is over.
    try { $null = Clear-OrphanRunspaces -Force } catch { }

    # Runspaces are the launcher's dominant memory cost (~8MB each, and the reason a
    # 5.5h build ended at 121 of them). Break down whatever is left by state so the
    # next leak names its own source instead of needing another dump.
    try {
        $rsLeft = @(Get-Runspace -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne 1 -and $_.RunspaceStateInfo.State -ne 'Closed' })
        if ($rsLeft.Count -gt 0) {
            $byState = ($rsLeft | Group-Object { "$($_.RunspaceStateInfo.State)/$($_.RunspaceAvailability)" } |
                    ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '

            # This block was the scaffold that found the Phase 11 session leak, and it
            # shouted because the counts were in the hundreds. Post-fix the launcher
            # still legitimately holds a small, stable population of runspaces, so
            # warning on it trains people to ignore the whole family. Warn only when the
            # numbers are actionable: disposal is demonstrably failing, something is
            # parked, or the undisposed share of sessions created is out of proportion.
            # Otherwise keep the full detail at LogOnly so a regression is still
            # reconstructable from the log.
            $ledger = $null
            try { $ledger = Get-VmSessionStats } catch { }
            $disposalFailing = $false
            $leakDisproportionate = $false
            if ($ledger) {
                $disposalFailing = ([int]$ledger['disposeLeftOpen'] -gt 0) -or
                                   ([int]$ledger['disposeThrew'] -gt 0) -or
                                   ([int]$ledger['disposeNoOwner'] -gt 0)

                # `$rsLeft.Count -gt 1` was meant to read "more than the one benign
                # log-flush runspace", but the launcher's real floor is 13 (two runspaces
                # per undisposed session), so the term was a constant $true: 118 of 118
                # runs over 5 days printed this whole block to the console and not one of
                # them was a growing leak -- leftOpen/noOwner/threw/parked were 0 every
                # time. Measure the leak against session TRAFFIC instead. Steady state is
                # 0.7-4.2% of sessions created (a fixed ~14 that did not grow across 600
                # further creations); the two genuine anomalies in the window were 40% and
                # 82%. Any cut between those silences the noise and keeps both.
                $created = [int]$ledger['created']
                $net = $created - [int]$ledger['disposeCalls']
                $leakDisproportionate = ($net -ge 10) -and ($created -gt 0) -and (($net / $created) -ge 0.25)
            }
            $parked = @($global:ps_orphanRunspaces).Count
            $actionable = $disposalFailing -or ($parked -gt 0) -or $leakDisproportionate
            $sev = if ($actionable) { @{ Warning = $true } } else { @{ LogOnly = $true } }

            Write-Log "[JobLeak] after session cleanup: $($rsLeft.Count) runspace(s) still open besides the default [$byState]; $parked parked awaiting reclaim. Each carries its own command + format tables (~8MB)." @sev

            # State alone was not enough: the count climbed 162 -> 182 -> 186 across
            # consecutive builds in one launcher while "parked" stayed 0, so these are
            # NOT the orphan-reclaim population. Kind+Origin separates a leaked local
            # transport runspace from a leaked PSDirect PSSession from a thread job
            # whose Remove-Job never ran -- three different bugs, three different fixes.
            $inv = @(Get-RunspaceInventory)
            if ($inv.Count -gt 0) {
                $byKind = ($inv | Group-Object { "$($_.Kind)/$($_.Origin)" } | Sort-Object Count -Descending |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
                Write-Log "[JobLeak] runspace owners: $byKind" @sev
                $byName = ($inv | Group-Object { ($_.Name -replace '\d+$', '#') } | Sort-Object Count -Descending |
                        Select-Object -First 8 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
                Write-Log "[JobLeak] runspace names: $byName" -LogOnly
                $topTargets = ($inv | Where-Object { $_.Target } | Group-Object Target | Sort-Object Count -Descending |
                        Select-Object -First 10 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
                if ($topTargets) { Write-Log "[JobLeak] runspace targets: $topTargets" @sev }
                $liveSessions = 0
                try { $liveSessions = @(Get-PSSession -ErrorAction SilentlyContinue).Count } catch { }
                $jobSummary = ''
                try {
                    $jobSummary = (@(Get-Job -ErrorAction SilentlyContinue) | Group-Object { "$($_.GetType().Name)/$($_.State)" } |
                            ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
                }
                catch { }
                Write-Log "[JobLeak] cross-check: Get-PSSession=$liveSessions ps_cache=$(@($global:ps_cache.Keys).Count) jobs=[$jobSummary]" @sev
                # created vs disposed separates the two remaining explanations:
                #   created >> disposeCalls          -> some path drops sessions without
                #                                       ever handing them to Remove-VmSession
                #   created ~= disposeCalls, but
                #   disposeLeftOpen/Threw > 0        -> disposal IS called and is failing
                # workerCleanups is the deployment signal for the ThreadJob fix: 0 means
                # the workers are not running Clear-VmSessionCache at all.
                try {
                    $st = Get-VmSessionStats
                    Write-Log "[JobLeak] session ledger: created=$($st['created']) disposeCalls=$($st['disposeCalls']) leftOpen=$($st['disposeLeftOpen']) noOwner=$($st['disposeNoOwner']) threw=$($st['disposeThrew']) raceLost=$($st['cacheRaceLost']) cacheEvicted=$($st['cacheEvicted']) workerCleanups=$($st['workerCleanups']) workerDisposed=$($st['workerDisposed'])" @sev
                    # Net undisposed per creating caller -- names the leaking path.
                    $bc = $st['byCaller']
                    $byCaller = @($bc.Keys | Where-Object { [int]$bc[$_] -gt 0 } | Sort-Object { - [int]$bc[$_] } | Select-Object -First 8 |
                            ForEach-Object { "$_=$([int]$bc[$_])" })
                    # @sev, not an unconditional -Warning: the same steady-state callers
                    # (Wait-Phase, Confirm-IsoVisibleInGuest, Remove-ForestTrust) named
                    # themselves on all 118 runs without the total ever moving.
                    if ($byCaller.Count -gt 0) { Write-Log "[JobLeak] undisposed by caller: $($byCaller -join ' ')" @sev }
                }
                catch { }
            }
        }
    }
    catch { }

    # Delete in progress or failed VM's
    if ($global:vm_remove_list.Count -gt 0) {
        if ($KeepFailedVMs) {
            Write-Log "Phase 1 did not complete cleanly, but -KeepFailedVMs was specified. NOT removing: $($global:vm_remove_list -join ', ')" -Warning
            Write-Log "Inspect VMs in Hyper-V Manager. Use the 'Delete Failed/In-Progress VMs' option in genconfig.ps1 to clean up when done." -Warning
            if ($NewLabsuccess) { $NewLabsuccess = $false }
        }
        else {
            if ($NewLabsuccess) {
                Write-Log "Phase 1 encountered failures. Removing all VMs created in Phase 1." -Warning
                $NewLabsuccess = $false
            }
            else {
                Write-Log "Script exited before Phase 1 completion. Removing all VMs created in Phase 1." -Warning
            }
            Write-Log "(Re-run with -KeepFailedVMs to preserve failed VMs for investigation.)" -Warning
            Write-Host

            foreach ($vmname in $global:vm_remove_list) {
                Remove-VirtualMachine -VmName $vmname -Migrate $Migrate -Force -SkipProxyCleanup
            }

            # Get-Job | Stop-Job
        }
    }

    # Clear vm remove list
    $global:vm_remove_list = @()

    # uninit common
    $Common.Initialized = $false

    # Set quick edit back
    Set-QuickEdit

    # Jobs and cached PSSessions can leave large, now-unreachable object graphs
    # resident in this long-lived launcher process. Collect and trim only this
    # process after cleanup, and log managed/private/working-set before/after so
    # persistent private growth can be distinguished from reclaimable residency.
    Invoke-HostMemoryReclaim -CurrentProcessOnly

    Write-Host
    if ($NewLabsuccess -ne $true) {
        if ($exitcode -ne 2) {
            Write-Host "Script exited (FAILED)."
            Set-TitleBar "SCRIPT FAILED"
        }
        if ($exitcode -gt 0) {
            exit $exitcode
        }
        else {
            exit 1
        }        
    }
    else {
        Write-Host "Script exited. SUCCESS"
        Set-TitleBar "SCRIPT FINISHED"
    }
    
}