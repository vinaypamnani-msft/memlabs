#Activate-Windows.ps1
$fixFlag = "ActivateWindows.done"
$flagPath = Join-Path $env:USERPROFILE $fixFlag

if (-not (Test-Path $flagPath)) {
    $atkms = "azkms.core.windows.net:1688"
    $winp = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
    $wine =  "NPPR9-FWDCX-D2C8J-H872K-2YT43"
    $cosname = (Get-WmiObject -Class Win32_OperatingSystem).Name
    cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms azkms.core.windows.net:1688
    
    Start-Sleep -Seconds 5
    
    if ($cosname -like "Pro") {
       cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $winp
    }
    if ($cosname -like "Enterprise") {
       cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $wine
    }
    
    Start-Sleep -Seconds 5
    cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato
    "Windows Activated" | Out-File $flagPath -Force
}