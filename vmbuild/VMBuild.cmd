
@ECHO OFF
REM VmBuild.cmd
pushd "%~dp0"
cmd /c "ftype MemLabs.Run="%~f0" %%1"
cmd /c "assoc .memlabs=MemLabs.Run"
cls

@ECHO ON
git config --global --add safe.directory E:\Memlabs
git config --global --add safe.directory E:/memlabs

git pull

@ECHO OFF

where /q wt
IF ERRORLEVEL 1 (
    ECHO Windows Terminal not installed.
    choco install microsoft-ui-xaml -y
    choco install microsoft-windows-terminal -y    
) 
set WT=1
where /q wt
IF ERRORLEVEL 1 set WT=0

IF NOT EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO INSTALLPS7
IF EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO PS7



:INSTALLPS7
choco install pwsh -y
IF EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO PS7 ELSE GOTO PS5

:PS7
IF "%~1"=="" (
    if "%WT%"=="1" (
        wt -w 0 nt -d . "C:\Program Files\PowerShell\7\pwsh.exe" -NoExit -ExecutionPolicy Bypass -NoLogo -Command "./New-Lab.ps1"
    ) ELSE (
        "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
    )
) ELSE (
    if "%WT%"=="1" (
        wt -w 0 nt -d . "C:\Program Files\PowerShell\7\pwsh.exe" -NoExit -ExecutionPolicy Bypass -NoLogo -Command "./New-Lab.ps1 -Configuration %1"
    ) ELSE (
        "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1 -Configuration %1"
    )
)


GOTO END
:PS5
powershell -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
GOTO END

:END
popd
