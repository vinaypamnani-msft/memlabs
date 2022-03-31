$s1 = (Get-WmiObject -List Win32_ShadowCopy).Create("C:\", "ClientAccessible")
$s2 = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $s1.ShadowID }
$d = $s2.DeviceObject + "\"   #
cmd /c mklink /d C:\dsc_logs "$d" | Out-Null

Start-Sleep -Seconds 2

$scpath = 'C:\dsc_logs\Windows\System32\Configuration\ConfigurationStatus'
$logfile = Get-ChildItem $scpath -Filter *.json | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
$fullPath = Join-Path -Path $scpath -ChildPath $logfile

cmd /c notepad $fullPath

$folder = Get-Item -Path 'C:\dsc_logs'
$folder.Delete()

$s2.Delete()