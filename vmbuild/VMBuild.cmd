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
@ECHO OFF

REM Prevent inline auto-gc during fetch/pull. On Windows gc.autoDetach
REM defaults to false (no fork), so gc runs synchronously and tries to
REM rewrite pack files while fetch still holds handles -- causing
REM "Unlink of file '.git/objects/pack/...' failed" hangs.
REM Explicit gc runs in Invoke-Maintenance.ps1 instead.
git config --local gc.auto 0 2>NUL

REM ------------------------------------------------------------
REM Move the user back to develop when their current branch is either
REM   (a) deleted from origin (a feature branch that was merged + pruned), or
REM   (b) RETIRED: still on origin (kept for history/reference) but no longer
REM       worked on. Add retired branch names to RETIRED_BRANCHES below,
REM       each wrapped in semicolons, so anyone still sitting on one is
REM       moved to develop without having to delete the branch from origin.
REM       e.g. SET "RETIRED_BRANCHES=;feature/foo;feature/bar;"
REM ------------------------------------------------------------
git fetch --prune origin 2>NUL
FOR /F "tokens=*" %%B IN ('git rev-parse --abbrev-ref HEAD 2^>NUL') DO SET CURBRANCH=%%B

SET "RETIRED_BRANCHES=;feature/mouse-menu-support;"

SET "SWITCHREASON="
IF "%CURBRANCH%"=="" GOTO AfterBranchRedirect
IF /I "%CURBRANCH%"=="develop" GOTO AfterBranchRedirect
IF /I "%CURBRANCH%"=="main" GOTO AfterBranchRedirect
IF /I "%CURBRANCH%"=="master" GOTO AfterBranchRedirect

REM (a) current branch deleted from origin
git ls-remote --exit-code --heads origin "%CURBRANCH%" >NUL 2>&1
IF ERRORLEVEL 1 SET "SWITCHREASON=no longer exists on origin"

REM (b) current branch retired but kept on origin
IF NOT DEFINED SWITCHREASON (
    ECHO %RETIRED_BRANCHES% | find /I ";%CURBRANCH%;" >NUL 2>&1
    IF NOT ERRORLEVEL 1 SET "SWITCHREASON=has been merged to develop and retired"
)

IF NOT DEFINED SWITCHREASON GOTO AfterBranchRedirect

ECHO.
ECHO ============================================================
ECHO  Branch "%CURBRANCH%" %SWITCHREASON%.
ECHO  Switching back to develop...
ECHO ============================================================
@ECHO ON
git checkout develop
@ECHO OFF
IF ERRORLEVEL 1 (
    ECHO.
    ECHO WARNING: Failed to checkout develop. You may have uncommitted
    ECHO changes on "%CURBRANCH%". Resolve manually then re-run.
    ECHO Press any key to continue with current branch...
    PAUSE > NUL
) ELSE (
    @ECHO ON
    git pull
    @ECHO OFF
)

:AfterBranchRedirect

REM ------------------------------------------------------------
REM Clean up local branches whose remote tracking branch was pruned
REM (merged + deleted on GitHub). Uses -d (not -D) so unmerged
REM work is never lost. Skips develop/main/master and current branch.
REM ------------------------------------------------------------
FOR /F "tokens=1,2" %%A IN ('git for-each-ref --format="%%(refname:short) %%(upstream:track)" refs/heads/ 2^>NUL') DO (
    IF "%%B"=="[gone]" (
        IF /I NOT "%%A"=="develop" (
            IF /I NOT "%%A"=="main" (
                IF /I NOT "%%A"=="master" (
                    ECHO  Removing stale branch: %%A
                    git branch -d "%%A" 2>NUL
                )
            )
        )
    )
)

@ECHO ON
git pull
@ECHO OFF
IF ERRORLEVEL 1 (
    ECHO  git pull failed -- running git gc and retrying...
    git gc 2>NUL
    timeout /t 5 /nobreak >NUL
    git pull
)
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
REM Run maintenance operations
REM ============================================================
powershell -NoLogo -NonInteractive -ExecutionPolicy Bypass -File ".\Invoke-Maintenance.ps1"
IF ERRORLEVEL 1 (
    ECHO WARNING: Maintenance script reported one or more errors.
)

REM RDCMan 3.21 prompts to trust a certificate for every lab VM, so MemLabs prefers
REM 3.12.0.0 from its own ProgramData copy. C:\tools belongs to the chocolatey
REM sysinternals package and is left alone so sysinternals can keep updating.
REM Falling back to that copy is supported, so this only reports -- it never blocks.
powershell -NoLogo -NonInteractive -ExecutionPolicy Bypass -Command "$pin=[version]'3.12.0.0'; $dir=Join-Path $env:ProgramData 'memlabs\RDCMan'; $exe=Join-Path $dir 'RDCMan.exe'; $sys='C:\tools\RDCMan.exe'; $cache=Join-Path (Get-Location).Path 'cache\RDCMan-3.12.0.0.exe'; function V($x){ if(-not (Test-Path -LiteralPath $x)){return $null}; try{ [version](Get-Item -LiteralPath $x).VersionInfo.ProductVersion }catch{ $null } }; if((V $cache) -ne $pin){ foreach($c in @($exe,$sys)){ if((V $c) -eq $pin){ try{ $cd=Split-Path -Parent $cache; if(-not (Test-Path $cd)){ New-Item -Path $cd -ItemType Directory -Force | Out-Null }; Copy-Item -LiteralPath $c -Destination $cache -Force -ErrorAction Stop; Write-Host ('  Rescued RDCMan ' + $pin + ' from ' + $c) }catch{}; break } } }; if((V $exe) -ne $pin -and (V $cache) -eq $pin){ try{ if(-not (Test-Path $dir)){ New-Item -Path $dir -ItemType Directory -Force | Out-Null }; Copy-Item -LiteralPath $cache -Destination $exe -Force -ErrorAction Stop }catch{} }; $use=if((V $exe) -eq $pin){ $exe }else{ $sys }; $uv=V $use; if(-not $uv){ Write-Host '  RDCMan: not found in ProgramData or C:\tools.' }elseif($uv -gt $pin){ Write-Host ('  RDCMan: using ' + $uv + ' from ' + $use + ' - MemLabs will pre-trust VM certificates in the .rdg.') }else{ Write-Host ('  RDCMan: using pinned ' + $uv + ' from ' + $use + '.') }"

REM ============================================================
REM Prune logs / temp / cache older than 7 days
REM ============================================================
powershell -NoLogo -NonInteractive -ExecutionPolicy Bypass -File ".\Clean-OldLogs.ps1"
IF ERRORLEVEL 1 (
    ECHO WARNING: Clean-OldLogs reported an error.
)

REM ============================================================
REM Remove the winget 'msstore' source to stop Microsoft Store
REM "This content is blocked by your IT admin" toast spam.
REM The msstore source background-refreshes against
REM storeedgefd/displaycatalog.mp.microsoft.com, which Defender
REM Network Protection blocks -- firing a toast each time. MemLabs
REM only ever uses the 'winget' source (New-LinuxBaseImage.ps1),
REM so removing msstore has no functional impact. Guarded so it
REM only runs when winget exists AND msstore is still present,
REM making it a silent no-op on every subsequent launch.
REM ============================================================
where winget >NUL 2>&1
IF NOT ERRORLEVEL 1 (
    winget source list 2>NUL | findstr /I "msstore" >NUL 2>&1
    IF NOT ERRORLEVEL 1 (
        ECHO Removing winget 'msstore' source to suppress Store block-page toasts...
        winget source remove msstore >NUL 2>&1
    )
)

REM ============================================================
REM Determine launch prerequisites after maintenance
REM ============================================================

REM Use quoted %ProgramFiles% to avoid "C:\Program not found"
SET PS7="%ProgramFiles%\PowerShell\7\pwsh.exe"

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
    IF DEFINED WT_SESSION (
        wt -w 0 nt -d . %PS7% -NoExit -ExecutionPolicy Bypass -NoLogo -Command "./New-Lab.ps1"
        IF ERRORLEVEL 1 GOTO LAUNCHWT_FAILED
    ) ELSE (
        %PS7% -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
        IF ERRORLEVEL 1 GOTO LAUNCHPS7_FAILED
    )
) ELSE (
    IF DEFINED WT_SESSION (
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