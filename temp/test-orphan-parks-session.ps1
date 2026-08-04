# Parking must release BOTH halves. Before the fix only the local runspace was
# parked, so a PSSession's RemoteRunspace stayed open for the life of the process.
. C:\memlabs\vmbuild\Common.ps1 -VerboseEnabled:$false 2>$null | Out-Null

function Get-RsCount { @(Get-Runspace | Where-Object { $_.Id -ne 1 -and $_.RunspaceStateInfo.State -ne 'Closed' }).Count }

"baseline runspaces: $(Get-RsCount)"

# Stand-in for a parked entry: a runspace we own, with a fake session attached.
$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.Open()
"after opening one : $(Get-RsCount)"

Add-OrphanRunspace -Runspace $rs -Session $null -Reason 'test' -VmName 'TESTVM'
"parked entries    : $(@($global:ps_orphanRunspaces).Count)"

$n = Clear-OrphanRunspaces -Force
"reclaimed         : $n"
"parked after      : $(@($global:ps_orphanRunspaces).Count)"
"runspaces after   : $(Get-RsCount)   (expect back to baseline)"
""
# The entry shape must carry Sess, or Clear-OrphanRunspaces silently skips the session.
$rs2 = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs2.Open()
Add-OrphanRunspace -Runspace $rs2 -Session ([pscustomobject]@{ _CallerTag = 'ProbeCaller' }) -Reason 'test2' -VmName 'TESTVM'
$e = @($global:ps_orphanRunspaces)[0]
"entry has Sess property : $($null -ne $e.PSObject.Properties['Sess'])"
"entry Sess CallerTag    : $($e.Sess._CallerTag)"
$null = Clear-OrphanRunspaces -Force
"runspaces at end        : $(Get-RsCount)"
