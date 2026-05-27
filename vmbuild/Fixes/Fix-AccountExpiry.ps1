# Fix-AccountExpiry: stop the secure-channel password from auto-rotating so
# long-suspended lab VMs don't lose their domain trust.

$Fix_AccountExpiry = {
    $RegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
    $Name  = 'DisablePasswordChange'
    $Value = 1
    try {
        New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force -ErrorAction Stop | Out-Null
        [pscustomobject]@{ Success = $true; Message = "Set $Name=$Value at $RegistryPath" }
    }
    catch {
        [pscustomobject]@{ Success = $false; Message = "Failed to write $Name"; Errors = @($_.Exception.Message) }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-AccountExpiry"
    FixVersion        = "230922"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("DC", "OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_AccountExpiry
}
