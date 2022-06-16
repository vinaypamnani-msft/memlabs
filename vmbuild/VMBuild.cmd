@ECHO OFF
pushd "%~dp0"

@ECHO ON
@git config --global --add safe.directory E:\Memlabs
git pull

@ECHO OFF
IF NOT EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO INSTALLPS7
IF EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO PS7

:INSTALLPS7
choco install pwsh -y
IF EXIST "C:\Program Files\PowerShell\7\pwsh.exe" GOTO PS7 ELSE GOTO PS5

:PS7
"C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
GOTO END

:PS5
powershell -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
GOTO END

:END
popd