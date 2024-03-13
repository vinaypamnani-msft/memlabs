#Enable-LogMachine.ps1
$fixFlag = "EnableLogMachine.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag

if (-not (Test-Path $flagPath)) {
    $prg = "C:\tools\LogMachine\LogMachine.exe"
    $ext = '.log'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    $ext = '.lo_'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    $ext = '.errlog'
    & cmd /c "ftype LogMachine.LOG=`"$prg`" %1"
    & cmd /c "assoc $ext=LogMachine.LOG"
    "LogMachine Enabled" | Out-File $flagPath -Force
}