#ECHO OFF
pushd "%~dp0"
git pull
powershell -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1"
popd
