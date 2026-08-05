. C:\memlabs\vmbuild\Common.ps1 -VerboseEnabled:$false 2>$null | Out-Null

"engine            : PS $($PSVersionTable.PSVersion)"
$cmd = Get-Command Test-VmIsLinux -ErrorAction SilentlyContinue
"Test-VmIsLinux    : $(if ($cmd) { 'defined' } else { 'MISSING' })"
if ($cmd) {
    $src = if ("$($cmd.Definition)".Length -gt 900) { 'Common.Linux.ps1 (full)' } else { 'Common.ps1 (PS5.1 stub)' }
    "   resolved from  : $src"
    "   linux osFamily : $(Test-VmIsLinux -Vm ([pscustomobject]@{ osFamily = 'Linux' }))"
    "   ubuntu deployed: $(Test-VmIsLinux -Vm ([pscustomobject]@{ deployedOS = 'Ubuntu 22.04' }))"
    "   windows        : $(Test-VmIsLinux -Vm ([pscustomobject]@{ operatingSystem = 'Server 2022' }))"
    "   null           : $(Test-VmIsLinux -Vm $null)"
}

$cmd2 = Get-Command Resolve-ConfigVmReference -ErrorAction SilentlyContinue
"Resolve-ConfigVmReference : $(if ($cmd2) { 'defined' } else { 'MISSING' })"
if ($cmd2) {
    "   plain          : '$(Resolve-ConfigVmReference -VmReference 'PS1SITE')'"
    "   bracketed+ansi : '$(Resolve-ConfigVmReference -VmReference "$([char]27)[32m[ PS1SITE ]$([char]27)[0m")'"
    "   prefix match   : '$(Resolve-ConfigVmReference -VmReference 'SITE1' -VmNames @('LAB-SITE1','LAB-SITE2') -Prefix 'LAB-')'"
}
