@ECHO OFF
REM VmBuild.cmd
pushd "%~dp0"

REM ============================================================
REM Register file association
REM (use ^" so embedded quotes are not seen as terminators by cmd /c)
REM ============================================================
cmd /c ftype MemLabs.Run=^"%~f0^" %%1
cmd /c assoc .memlabs=MemLabs.Run
cls

REM ============================================================
REM Check if running as a local account (not AAD)
REM ============================================================
FOR /F "tokens=*" %%A IN ('powershell -NoLogo -NonInteractive -Command "if ($env:USERDNSDOMAIN -or $env:USERNAME -match '@') { Write-Output AAD } else { Write-Output LOCAL }"') DO SET ACCOUNTTYPE=%%A

IF "%ACCOUNTTYPE%"=="AAD" (
    ECHO.
    ECHO ============================================================
    ECHO  WARNING: You are logged in with an AAD/domain account.
    ECHO  This may cause bearer token authentication to fail due
    ECHO  to Conditional Access policies.
    ECHO.
    ECHO  For best results, run this script as a local account
    ECHO  e.g. .\labadmin instead of your AAD account.
    ECHO ============================================================
    ECHO.
    ECHO Press any key to continue anyway, or Ctrl+C to exit...
    PAUSE > NUL
)

REM ============================================================
REM Git update
REM ============================================================
@ECHO ON
git config --global --add safe.directory E:\Memlabs
git config --global --add safe.directory E:/memlabs
git pull
@ECHO OFF
IF ERRORLEVEL 1 (
    ECHO.
    ECHO ============================================================
    ECHO  WARNING: git pull failed. You may be running an outdated version.
    ECHO ============================================================
    ECHO.
    ECHO  Run these commands in this directory:
    ECHO         %CD%
    ECHO.
    ECHO  How to fix:
    ECHO    1. Check your network/VPN connection.
    ECHO    2. Open a new terminal and cd to the directory above:
    ECHO         pushd "%CD%"
    ECHO    3. Resolve any local changes:
    ECHO         git status
    ECHO         git stash         ^(to set aside local edits^)
    ECHO         -- or --
    ECHO         git reset --hard  ^(WARNING: discards local edits^)
    ECHO    4. Verify the remote and credentials:
    ECHO         git remote -v
    ECHO         git fetch
    ECHO    5. If the repo is owned by another user, run:
    ECHO         git config --global --add safe.directory "%CD%"
    ECHO    6. Re-run:  git pull
    ECHO.
    ECHO  Fix the issue in another window, then return here.
    ECHO  Press any key to RESUME, or Ctrl+C to EXIT...
    PAUSE > NUL
    ECHO Resuming...
)

REM ============================================================
REM Check/install Windows Terminal
REM ============================================================
SET WT=0
where /q wt
IF ERRORLEVEL 1 (
    ECHO Windows Terminal not installed, attempting to install...
    choco install microsoft-ui-xaml -y
    IF ERRORLEVEL 1 ECHO WARNING: Failed to install microsoft-ui-xaml.
    choco install microsoft-windows-terminal -y
    IF ERRORLEVEL 1 ECHO WARNING: Failed to install Windows Terminal.
)
where /q wt
IF NOT ERRORLEVEL 1 SET WT=1

REM ============================================================
REM Use quoted %ProgramFiles% to avoid "C:\Program not found"
REM ============================================================
SET PS7="%ProgramFiles%\PowerShell\7\pwsh.exe"
SET PS7_FLAG=%TEMP%\memlabs_ps7_upgrade.flag
SET CHOCO_ALL_FLAG=%TEMP%\memlabs_choco_all_upgrade.flag

REM ============================================================
REM Weekly upgrades (PowerShell 7 and all Chocolatey packages)
REM ============================================================
SETLOCAL ENABLEDELAYEDEXPANSION

REM Get current week number
FOR /F "tokens=*" %%W IN ('powershell -NoLogo -NonInteractive -Command "Write-Output (Get-Date -UFormat '%%Y-%%V')"') DO SET CURRENT_WEEK=%%W

REM --- Upgrade PowerShell 7 (once per week) ---
SET DO_PS7_UPGRADE=1
IF EXIST "%PS7_FLAG%" (
    FOR /F "tokens=*" %%C IN ('type "%PS7_FLAG%"') DO SET LAST_WEEK=%%C
    IF "!LAST_WEEK!"=="!CURRENT_WEEK!" SET DO_PS7_UPGRADE=0
)

IF "!DO_PS7_UPGRADE!"=="1" (
    ECHO Upgrading PowerShell 7 ^(week !CURRENT_WEEK!^)...
    choco upgrade pwsh -y
    SET CHOCO_RC=!ERRORLEVEL!
    REM Treat 0, 1641 and 3010 as success ^(reboot codes^)
    IF "!CHOCO_RC!"=="0" (SET PS7_OK=1) ELSE IF "!CHOCO_RC!"=="1641" (SET PS7_OK=1) ELSE IF "!CHOCO_RC!"=="3010" (SET PS7_OK=1) ELSE (SET PS7_OK=0)
    IF "!PS7_OK!"=="1" (
        powershell -NoLogo -NonInteractive -Command "'!CURRENT_WEEK!' | Out-File '!PS7_FLAG!' -Encoding ascii -NoNewline"
    ) ELSE (
        ECHO WARNING: Failed to upgrade PowerShell 7 ^(exit !CHOCO_RC!^).
    )
) ELSE (
    ECHO PowerShell 7 upgrade skipped ^(already checked week !CURRENT_WEEK!^).
)

REM --- Upgrade all Chocolatey packages (once per week) ---
SET DO_CHOCO_UPGRADE=1
IF EXIST "%CHOCO_ALL_FLAG%" (
    FOR /F "tokens=*" %%C IN ('type "%CHOCO_ALL_FLAG%"') DO SET LAST_CHOCO_WEEK=%%C
    IF "!LAST_CHOCO_WEEK!"=="!CURRENT_WEEK!" SET DO_CHOCO_UPGRADE=0
)

IF "!DO_CHOCO_UPGRADE!"=="1" (
    ECHO Upgrading all Chocolatey packages ^(week !CURRENT_WEEK!^)...
    choco upgrade all -y --ignore-checksums
    SET CHOCO_RC=!ERRORLEVEL!
    REM Treat 0, 1641 and 3010 as success ^(reboot codes^)
    IF "!CHOCO_RC!"=="0" (SET CHOCO_OK=1) ELSE IF "!CHOCO_RC!"=="1641" (SET CHOCO_OK=1) ELSE IF "!CHOCO_RC!"=="3010" (SET CHOCO_OK=1) ELSE (SET CHOCO_OK=0)
    IF "!CHOCO_OK!"=="1" (
        powershell -NoLogo -NonInteractive -Command "'!CURRENT_WEEK!' | Out-File '!CHOCO_ALL_FLAG!' -Encoding ascii -NoNewline"
    ) ELSE (
        ECHO WARNING: choco upgrade all failed ^(exit !CHOCO_RC!^).
    )
) ELSE (
    ECHO Chocolatey upgrade all skipped ^(already checked week !CURRENT_WEEK!^).
)

ENDLOCAL

REM ============================================================
REM Check PowerShell 7 is available
REM ============================================================
IF NOT EXIST %PS7% (
    ECHO WARNING: PowerShell 7 not available, falling back to PowerShell 5.
    GOTO PS5
)

REM ============================================================
REM Launch with PowerShell 7
REM ============================================================
:PS7
timeout 1
IF "%~1"=="" (
    IF "%WT%"=="1" (
        wt -w 0 nt -d . %PS7% -NoExit -ExecutionPolicy Bypass -NoLogo -Command "./New-Lab.ps1"
        IF ERRORLEVEL 1 GOTO LAUNCHWT_FAILED
    ) ELSE (
        %PS7% -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
        IF ERRORLEVEL 1 GOTO LAUNCHPS7_FAILED
    )
) ELSE (
    IF "%WT%"=="1" (
        wt -w 0 nt -d . %PS7% -NoExit -ExecutionPolicy Bypass -NoLogo -Command "./New-Lab.ps1 -Configuration %1"
        IF ERRORLEVEL 1 GOTO LAUNCHWT_FAILED
    ) ELSE (
        %PS7% -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1 -Configuration %1"
        IF ERRORLEVEL 1 GOTO LAUNCHPS7_FAILED
    )
)
GOTO END

REM ============================================================
REM Launch with PowerShell 5 fallback
REM ============================================================
:PS5
ECHO WARNING: Launching with PowerShell 5. Some features may not work correctly.
powershell -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
IF ERRORLEVEL 1 (
    ECHO ERROR: Failed to launch with PowerShell 5.
    PAUSE
)
GOTO END

REM ============================================================
REM Error handlers
REM ============================================================
:LAUNCHWT_FAILED
ECHO ERROR: Failed to launch Windows Terminal.
ECHO Falling back to direct PowerShell 7 launch...
%PS7% -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
GOTO END

:LAUNCHPS7_FAILED
ECHO ERROR: Failed to launch PowerShell 7.
GOTO END

REM ============================================================
:END
REM ============================================================
popd
timeout 2