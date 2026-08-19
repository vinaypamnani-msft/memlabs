<#
.SYNOPSIS
    Reports why a stale cluster AD object refuses to delete, then removes it.
.DESCRIPTION
    Run this ON the domain controller (RP1-DC1) in an elevated PowerShell session.
    "Access is denied." on its own is not actionable, so the report runs first and
    always prints: the owner, every Deny ACE, the accidental-deletion flag, and any
    children. That output is the diagnosis regardless of whether removal succeeds.

    Removal then walks the same ladder the build uses:
      1. Remove-ADObject -Recursive          (LDAP tree delete, needs Delete Subtree)
      2. strip Deny ACEs on the object, its subtree and its parent, then retry
      3. take ownership, restore Domain Admins full control, then retry
      4. Remove-ADObject without -Recursive  (needs only Delete)
.EXAMPLE
    .\Repair-StaleClusterAdObject.ps1 -Name RP1-SQLCLUSTER2,RP1-ALWAYSON2 -ReportOnly
.EXAMPLE
    # Delete only. Phase 2 prestages both names again on the next build.
    .\Repair-StaleClusterAdObject.ps1 -Name RP1-SQLCLUSTER2,RP1-ALWAYSON2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Name,

    # Print the diagnosis and change nothing.
    [switch]$ReportOnly,

    # Rarely needed: memlabs already prestages the CNO and VCO disabled in Phase 2
    # (Common.GenConfig.ps1 -> DomainComputers -> Phase2DC.ps1 EnabledOnCreation=$false).
    # Use it only to hand a cluster back its name without running a build.
    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory -ErrorAction Stop

$deleteMask = [System.DirectoryServices.ActiveDirectoryRights]::Delete -bor
[System.DirectoryServices.ActiveDirectoryRights]::DeleteTree -bor
[System.DirectoryServices.ActiveDirectoryRights]::DeleteChild -bor
[System.DirectoryServices.ActiveDirectoryRights]::GenericAll

function Get-ParentDn { param([string]$Dn) $Dn -replace '^.+?(?<!\\),', '' }

function Show-ObjectAcl {
    param([string]$Dn, [string]$Label)
    $o = Get-ADObject -Identity $Dn -Properties nTSecurityDescriptor, ProtectedFromAccidentalDeletion, objectClass
    $sd = $o.nTSecurityDescriptor
    "  $Label"
    "    class      : $($o.objectClass)"
    "    protected  : $($o.ProtectedFromAccidentalDeletion)"
    "    owner      : $($sd.Owner)"
    $deny = @($sd.Access | Where-Object { $_.AccessControlType -eq 'Deny' })
    if ($deny.Count -eq 0) {
        '    deny ACEs  : none'
    }
    else {
        foreach ($a in $deny) {
            $blocks = if (($a.ActiveDirectoryRights -band $deleteMask) -ne 0) { '  <-- BLOCKS DELETE' } else { '' }
            "    deny ACE   : $($a.IdentityReference) [$($a.ActiveDirectoryRights)]$blocks"
        }
    }
    $da = @($sd.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and "$($_.IdentityReference)" -match 'Domain Admins|Enterprise Admins|BUILTIN\\Administrators' })
    "    admin allow: $(if ($da.Count) { ($da | ForEach-Object { "$($_.IdentityReference) [$($_.ActiveDirectoryRights)]" }) -join ' ; ' } else { 'NONE FOUND -- this alone explains a denial' })"
}

function Clear-DeleteDeny {
    param([string]$Dn)
    $removed = @()
    $sd = (Get-ADObject -Identity $Dn -Properties nTSecurityDescriptor).nTSecurityDescriptor
    $deny = @($sd.Access | Where-Object { $_.AccessControlType -eq 'Deny' -and (($_.ActiveDirectoryRights -band $deleteMask) -ne 0) })
    if ($deny.Count -eq 0) { return @() }
    foreach ($a in $deny) {
        $sd.RemoveAccessRuleSpecific($a)
        $removed += "$($a.IdentityReference) [$($a.ActiveDirectoryRights)] on $Dn"
    }
    Set-Acl -Path "AD:\$Dn" -AclObject $sd
    @($removed)
}

function Grant-AdminControl {
    param([string]$Dn)
    $admins = New-Object System.Security.Principal.NTAccount((Get-ADDomain).NetBIOSName, 'Domain Admins')
    $sd = (Get-ADObject -Identity $Dn -Properties nTSecurityDescriptor).nTSecurityDescriptor
    $sd.SetOwner($admins)
    Set-Acl -Path "AD:\$Dn" -AclObject $sd
    $sd = (Get-ADObject -Identity $Dn -Properties nTSecurityDescriptor).nTSecurityDescriptor
    $sd.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $admins, [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
                [System.Security.AccessControl.AccessControlType]::Allow,
                [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All)))
    Set-Acl -Path "AD:\$Dn" -AclObject $sd
}

"Running as : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
"Elevated   : $((New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))"
"Domain     : $((Get-ADDomain).DNSRoot)"
''

foreach ($n in $Name) {
    "=== $n ==="
    $obj = $null
    try { $obj = Get-ADObject -LDAPFilter "(&(objectClass=computer)(cn=$n))" -Properties DistinguishedName }
    catch { "  lookup failed: $($_.Exception.Message)"; ''; continue }

    if (-not $obj) {
        # A tombstoned or CNF-mangled duplicate answers a wildcard when an exact match fails.
        $ghost = @(Get-ADObject -LDAPFilter "(cn=$n*)" -IncludeDeletedObjects -ErrorAction SilentlyContinue)
        "  not present as a live computer object."
        if ($ghost.Count) { foreach ($g in $ghost) { "    also found: $($g.DistinguishedName) (deleted=$($g.Deleted))" } }
        ''
        continue
    }

    foreach ($o in @($obj)) {
        $dn = $o.DistinguishedName
        "  dn         : $dn"
        Show-ObjectAcl -Dn $dn -Label 'object ACL:'
        $parent = Get-ParentDn -Dn $dn
        Show-ObjectAcl -Dn $parent -Label "parent ACL: ($parent)"
        $kids = @(Get-ADObject -SearchBase $dn -SearchScope OneLevel -Filter * -ErrorAction SilentlyContinue)
        "  children   : $(if ($kids.Count) { ($kids | ForEach-Object { $_.DistinguishedName }) -join ' ; ' } else { 'none' })"

        if ($ReportOnly) { ''; continue }

        $done = $false
        foreach ($step in 1..4) {
            try {
                switch ($step) {
                    2 {
                        $cleared = @()
                        # @($null).Count is 1, so an empty child list would inject a null DN here.
                        $targets = @($parent, $dn) + @($kids | ForEach-Object { $_.DistinguishedName })
                        foreach ($t in @($targets | Where-Object { $_ })) {
                            $cleared += Clear-DeleteDeny -Dn $t
                        }
                        "  step 2: cleared $($cleared.Count) deny ACE(s)$(if ($cleared.Count) { ": $($cleared -join ' ; ')" })"
                    }
                    3 { Grant-AdminControl -Dn $dn; '  step 3: took ownership and granted Domain Admins full control' }
                }
                $useRecursive = ($step -lt 4)
                Remove-ADObject -Identity $dn -Recursive:$useRecursive -Confirm:$false
                "  REMOVED on step $step (recursive=$useRecursive)"
                $done = $true
                break
            }
            catch {
                "  step $step failed: $($_.Exception.Message)"
            }
        }

        if (-not $done) { "  STILL PRESENT -- send the ACL block above, it names the reason." }
        elseif ($Recreate) {
            New-ADComputer -Name $n -Enabled $false -Path $parent
            "  recreated '$n' prestaged and disabled in $parent"
        }
    }
    ''
}
