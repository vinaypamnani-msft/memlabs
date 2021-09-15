REM This could be useful if you want to go through OOBE experience and AAD join a device.
REM Unattend file here has the CopyProfile switch to maintain user customization across profiles.
REM Run this batch file, start the VM and go through OOBE
C:\Windows\system32\sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:"C:\staging\UnattendAAD.xml"
