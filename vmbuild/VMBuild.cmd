@ECHO OFF
pushd "%~dp0"
@ECHO ON
git pull
powershell -ExecutionPolicy Bypass -NoLogo -NoExit -Command "./New-Lab.ps1 -ResizeWindow"
popd
