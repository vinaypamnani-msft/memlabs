# Install RRAS
Install-WindowsFeature 'Routing', 'DirectAccess-VPN' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools

# External Hyper-V Switch name (created by Host DSC)
$externalInterface = "vEthernet (External)"

# Configure NAT
Install-RemoteAccess -VpnType RoutingOnly
cmd.exe /c netsh routing ip nat install
cmd.exe /c netsh routing ip nat add interface "$externalInterface"
cmd.exe /c netsh routing ip nat set interface "$externalInterface" mode=full
cmd.exe /c reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters /v ModernStackEnabled /t REG_DWORD /d 0 /f